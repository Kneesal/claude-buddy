---
title: Bash state library patterns for Claude Code plugins
date: 2026-04-18
last_updated: 2026-04-19
category: best-practices
module: scripts/lib/state.sh
problem_type: best_practice
component: tooling
severity: high
applies_when:
  - Building any persistent state layer for a Claude Code plugin (bash + JSON)
  - Writing a bash library that will be sourced by hook scripts
  - Any bash CLI using tmp+rename atomic writes with flock
  - Writing a destructive command that wipes a flock-protected state file
  - Writing bats tests for a sourced bash library
tags:
  - bash
  - state-management
  - atomic-writes
  - atomic-deletes
  - flock
  - json
  - claude-code-plugin
  - bats
  - schema-versioning
  - crash-recovery
---

# Bash state library patterns for Claude Code plugins

## Context

Plugin authors who need persistent state beyond what Claude Code's `${CLAUDE_PLUGIN_DATA}` directory alone provides must write a bash JSON state library from scratch. That library will be sourced by hook scripts (which must exit 0), called by concurrent status-line renders, and run on developer machines that may have bash 3.2. Without deliberate design, at least a dozen subtle failure modes lie in wait:

- `set -euo pipefail` at module scope silently breaks every hook that sources the library.
- bash 3.2 `exec {fd}>file` syntax silently creates a file named `{fd}` instead of assigning an fd number, causing the flock to be entirely skipped.
- A lock file that is the same as the data file is invalidated the moment `mv` renames the data file to a new inode — the lock is held on the old inode and provides no protection.
- A symlinked lock file, opened with `exec {fd}>file`, will truncate the symlink target (O_TRUNC) or hang forever on a FIFO symlink — no flock timeout can help.
- Empty stdin into `jq` produces empty output; `printf` then writes a bare newline to the data file — silent corruption.
- Two sentinels (present/absent) are not enough — a file written by a newer plugin version needs a third sentinel so a downgraded plugin doesn't clobber future-format data.
- `schemaVersion` validated with bash arithmetic silently accepts floats and strings, which then fail unpredictably in integer comparisons.
- Migration loops that forget to bump `.schemaVersion` in a case arm spin forever.
- Per-process one-time warning dedup via colon-joined strings collides on keys containing colons.
- PID-suffixed tmp files cleaned only by age will eventually be kept forever when a dead PID is recycled by a long-lived unrelated process.
- Session IDs passed in from callers may contain path traversal characters or exceed `NAME_MAX=255`.
- bats tests that source state.sh at the suite level pollute `set -e` into the test runner; stderr from sourced functions merges into `$output` without `--separate-stderr`.
- A destructive command that wipes the state file cannot use `rm` directly under the flock — an interrupt between the open and the unlink leaves the file partially replaced. And calling `buddy_load` to confirm the file is parseable before deleting means a CORRUPT state becomes un-wipeable.

These are the patterns the `scripts/lib/state.sh` library encodes after two full code-review cycles with 25 findings addressed, plus the atomic-delete extension added in the P1-3 reset command.

## Guidance

### A. Library structure

**No `set -euo pipefail` at module scope.** `set -e` propagates into the sourcing script's shell and causes any failing subcommand inside the library to abort the hook, violating the "hooks must exit 0" contract.

```bash
# BAD — module-level pipefail propagates into every sourcing hook
set -euo pipefail

# GOOD — explicit per-function error handling; library has no module-level flags.
# Document the decision in the file header so it doesn't regress.
```

**Enforce bash 4.1+ at source time.** On bash 3.x, `exec {fd}>file` silently creates a regular file named literally `{fd}` and leaves `$fd` unset — the flock is skipped entirely, with no error.

```bash
if [[ -z "${BASH_VERSINFO[0]:-}" ]] || (( BASH_VERSINFO[0] < 4 )) || \
   (( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 1 )); then
  echo "buddy-state: requires bash 4.1+ (got ${BASH_VERSION:-unknown})." >&2
  return 1 2>/dev/null || exit 1
fi
```

**Guard against re-sourcing with a sentinel variable.** Protects both `readonly` declarations and per-process dedup accumulators.

```bash
if [[ "${_STATE_SH_LOADED:-}" != "1" ]]; then
  _STATE_SH_LOADED=1
  readonly CURRENT_SCHEMA_VERSION=1
  readonly FLOCK_TIMEOUT=0.2
  declare -gA _state_warned_keys=()
fi
```

**Use `declare -gA` for per-process dedup** (associative array), not a colon-joined string. Colon-joined strings collide on keys that contain colons, such as file paths used as warning keys.

### B. Atomic writes + locking

**Keep the lock file separate from the data file.** `mv` changes the data file's inode; any fd open on the old inode becomes a lock on a file that no longer exists at that path.

```bash
# BAD — lock on the data file itself is invalidated by mv
exec {fd}>"$data_dir/buddy.json"

# GOOD — lock file is a permanent sibling; mv never touches it
local lock_file="$data_dir/buddy.json.lock"
exec {lock_fd}>"$lock_file"
```

The lock file is created implicitly when the fd is opened. Never clean it up alongside tmp files in orphan cleanup — it is permanent.

**Name tmp files with the owning PID** so cleanup can distinguish live writers from dead ones.

```bash
tmp="$(mktemp "$data_dir/.tmp.$$.XXXXXX")"
#                              ^^  PID embedded in name
```

**Explicitly `rm -f` the tmp file on every failure path**, not just on rename failure.

```bash
if ! printf '%s\n' "$content" > "$tmp"; then
  rm -f "$tmp"
  exec {lock_fd}>&-
  return 1
fi
if ! mv -f "$tmp" "$buddy_file"; then
  rm -f "$tmp"
  exec {lock_fd}>&-
  return 1
fi
```

**Reject symlinked lock files before opening them.** A regular-file symlink target gets truncated by `O_TRUNC`; a FIFO symlink hangs indefinitely before flock's timeout can fire.

```bash
if [[ -L "$lock_file" ]]; then
  _state_log "buddy_save: refusing to open symlinked lock file $lock_file"
  return 1
fi
exec {lock_fd}>"$lock_file"
```

**Guard empty stdin explicitly before writing.** `jq` produces empty output on empty stdin; `printf` then writes a bare newline — silent corruption.

```bash
if ! content="$(jq --argjson v "$CURRENT_SCHEMA_VERSION" '.schemaVersion = $v')"; then
  _state_log "buddy_save: invalid JSON input"
  return 1
fi
if [[ -z "$content" ]]; then
  _state_log "buddy_save: empty stdin"
  return 1
fi
```

**Atomic delete: rename to a marker, then unlink, under the same flock.** A destructive command cannot just `rm` the state file. The rename-then-unlink pattern mirrors the atomic-write dance and leaves a recoverable breadcrumb if the process dies mid-dance.

```bash
# Under flock -x on buddy.json.lock:
if [[ -f "$buddy_file" ]]; then
  mv -f "$buddy_file" "$buddy_file.deleted"   # atomic rename — buddy_load now sees NO_BUDDY
  rm -f "$buddy_file.deleted"                 # best-effort unlink; orphan sweep picks up crashes
fi
```

Why both steps matter: the `mv` is the atomic commit point — after it returns, `buddy_load` legitimately sees `NO_BUDDY`. The `rm` is cleanup. If the process is SIGKILL'd between the two, the next load is still `NO_BUDDY` (correct), and `state_cleanup_orphans` picks up the orphan `.deleted` file on next session start (see Section E).

**Hold the lock across both steps.** Release only after `rm -f`. A concurrent writer could otherwise see the rename, think the file is gone, and write a fresh state file that the later `rm` would *not* touch (different inode) — but a concurrent reader could race the intermediate state if the lock were released between the two.

**Do not call `buddy_load` before deleting.** The file may be `CORRUPT`; parsing it before wiping is both unnecessary and a way to make CORRUPT state un-recoverable. Reset must work regardless of the file's content.

**Apply the same symlink-rejection guard** as the write path. A destructive command that opens the lock file is an identical attack surface — symlink to a regular file truncates, symlink to a FIFO hangs past the flock timeout.

```bash
if [[ -L "$lock_file" ]]; then
  _state_log "reset: refusing to open symlinked lock file $lock_file"
  return 1
fi
exec {lock_fd}>"$lock_file"
```

**Timeout errors should be actionable.** A bare "flock timeout after 0.2s" is a diagnostic, not a user message. Tell the user what to do:

```bash
echo "reset: could not acquire lock within ${FLOCK_TIMEOUT}s — another operation may be in flight. Try again in a moment." >&2
```

### C. Sentinel-based state machine

**Use three sentinels, not two.** Two sentinels can't distinguish a corrupt file from one written by a newer plugin version. Returning `CORRUPT` for a future-version file would let a downgraded plugin clobber valid state.

```bash
readonly STATE_NO_BUDDY="NO_BUDDY"             # file absent — first run or post-reset
readonly STATE_CORRUPT="CORRUPT"               # file present but unparseable
readonly STATE_FUTURE_VERSION="FUTURE_VERSION" # newer plugin wrote this file
```

**Load functions always return exit code 0.** Never return non-zero from a load function — `set -e` callers (even in subshells) would abort on a legitimate CORRUPT or NO_BUDDY condition. Callers check the output string against the sentinel constants.

```bash
local state
state="$(buddy_load)"
case "$state" in
  "$STATE_NO_BUDDY")       ... ;;
  "$STATE_CORRUPT")        ... ;;
  "$STATE_FUTURE_VERSION") ... ;;
  *) # $state is valid JSON
esac
```

**Emit warnings once per process per key** using the associative array dedup. Status-line scripts call load every few seconds — without dedup, a stable CORRUPT state floods stderr.

### D. Schema versioning

**Stamp `schemaVersion` on every write via jq.** Never let callers write raw JSON without the version field.

```bash
content="$(jq --argjson v "$CURRENT_SCHEMA_VERSION" '.schemaVersion = $v')"
```

**Validate `schemaVersion` as a non-negative integer** with a regex, not bash arithmetic. Bash arithmetic silently accepts floats and non-numeric strings.

```bash
# BAD — bash arithmetic silently accepts "1.5" and "foo"
(( version >= 0 ))

# GOOD — regex rejects floats and non-numeric strings
if ! [[ "$version" =~ ^[0-9]+$ ]]; then
  printf '%s' "$STATE_CORRUPT"
  return 0
fi
```

**Migrate in memory on load; persist only on the next save.** Read-only callers (status line, inspection hooks) must never trigger writes.

**Include an iteration cap in the migration loop** to catch case arms that forget to bump `.schemaVersion`. The cap is a safety net, not a license to skip the version bump.

```bash
local iterations=0
while (( version < CURRENT_SCHEMA_VERSION )); do
  if (( ++iterations > MIGRATE_MAX_ITERATIONS )); then
    _state_log "migrate: exceeded max iterations — case arm likely forgot to bump .schemaVersion"
    return 1
  fi
  case "$version" in
    1) json="$(printf '%s' "$json" | jq '.schemaVersion = 2 | .newField //= "default"')" ;;
    *) _state_log "migrate: unknown version $version"; return 1 ;;
  esac
  version="$(printf '%s' "$json" | jq -r '.schemaVersion')"
done
```

### E. Cleanup and orphan handling

**Use a two-pass approach for tmp files.** Pass 1 is PID-aware: skip files whose embedded PID is still alive. Pass 2 is a hard-age unconditional pass at 24 hours, which bounds PID-reuse false positives — a dead writer's PID may be recycled by a long-lived unrelated process, which would cause pass 1 to keep the file indefinitely.

```bash
# Pass 1 — PID-aware
while IFS= read -r tmp_file; do
  pid="$(basename "$tmp_file" | awk -F. '{print $3}')"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    continue   # live process owns this file
  fi
  rm -f "$tmp_file"
done < <(find "$data_dir" -maxdepth 1 -name '.tmp.*' -mmin "+$ORPHAN_MAX_AGE_MINUTES")

# Pass 2 — hard-age upper bound
find "$data_dir" -maxdepth 1 -name '.tmp.*' -mmin "+$ORPHAN_HARD_AGE_MINUTES" -delete || true
```

**Sweep the atomic-delete marker unconditionally — no PID awareness, no age gate.** `.deleted` files (from the atomic-delete dance in Section B) are semantically different from `.tmp.*` files: they have no embedded PID, they represent a committed intent to wipe (not an in-flight write), and they can only exist if a prior reset was interrupted. The right policy is a single unconditional `rm`:

```bash
# Sweep any orphan buddy.json.deleted marker from a crashed reset.
rm -f "$data_dir/buddy.json.deleted" 2>/dev/null || true
```

The PID-aware logic from Pass 1 must not be applied: there's no PID in the filename to probe, and `kill -0` on a non-existent PID would leave the marker forever. The hard-age upper bound from Pass 2 is unnecessary because the marker should never coexist with a live reset — the reset dance holds the flock across both the `mv` and the `rm`, so a well-behaved reset never leaves a marker on disk.

**Never delete the `.lock` file** in cleanup. It's permanent and must survive across all writes.

### F. Session state (per-sessionId files)

**Use per-sessionId files**, not a single shared `session.json`. Multiple hooks firing in the same session could otherwise clobber each other's writes.

**Sanitize session IDs** before using them in file paths. A session ID from the environment may contain path traversal characters or be long enough to exceed `NAME_MAX=255`.

```bash
_state_valid_session_id() {
  local id="$1"
  [[ -n "$id" \
    && "${#id}" -le "$SESSION_ID_MAX_LEN" \
    && "$id" =~ ^[A-Za-z0-9_-]+$ ]]
}
```

**Still use tmp+rename for session files** even though flock is not needed. Rename is atomic; without it, a concurrent write to the same session ID (two hook firings racing) would produce a partial file.

### G. bats test patterns

**Source `state.sh` inside `bash -c` subshells** when testing functions in isolation, not at the top of the test file. Top-level sourcing carries the library's implicit behaviors (version check, dedup init) into the test runner's shell.

**Use `run --separate-stderr` for every `run` invocation** that calls library functions. Without it, stderr from the function under test merges into `$output` and assertion failures become confusing.

```bash
# BAD — stderr merged into $output
run buddy_load
[ "$output" = "CORRUPT" ]   # fails when log message is merged in

# GOOD — stderr goes to $stderr separately
run --separate-stderr buddy_load
[ "$output" = "CORRUPT" ]
```

**Test `set -e` pipeline pollution explicitly.** A vacuous test (`set +o pipefail; echo ok`) would pass even if the library regressed.

```bash
@test "sourcing state.sh does not pollute caller with pipefail" {
  run bash -c '
    source "$STATE_LIB"
    # With pipefail off, `false | true` exits 0. If state.sh leaked pipefail, this fails.
    false | true || exit 12
    echo "ok"
  '
  [ "$output" = "ok" ]
}
```

**Stress tests must invoke the library API**, not re-implement locking inline. A regression in `buddy_save`'s locking leaves an inline-reimplementation test green.

**Wrap symlink/FIFO attack tests in `timeout`** so a regression fails instead of hanging forever.

```bash
@test "buddy_save rejects FIFO symlink on lock file" {
  run timeout 3 bash -c '
    source "$STATE_LIB"
    mkfifo "$CLAUDE_PLUGIN_DATA/fifo"
    ln -sf "$CLAUDE_PLUGIN_DATA/fifo" "$CLAUDE_PLUGIN_DATA/buddy.json.lock"
    echo "{}" | buddy_save
  '
  [ "$status" -ne 0 ]
  [ "$status" -ne 124 ]   # 124 = timeout fired (regression)
}
```

## Why This Matters

These are not theoretical concerns. Every pattern above came from either an empirically-verified bug, a high-confidence code-review finding, or a latent trap confirmed to bite in production conditions. Specifically:

- **bash 3.x `exec {fd}` silent corruption** is a real macOS hazard — system bash on macOS is 3.2, and plugin authors develop locally before running in CI.
- **Lock-on-data-file inode invalidation** is the single most common mistake in atomic-write implementations; it makes the lock entirely ineffective under concurrent load.
- **Symlink attacks** were empirically verified: a regular-file symlink target was zeroed by a normal `buddy_save` call; a FIFO symlink hung past the flock timeout until killed externally.
- **Empty-stdin corruption** produces a file that passes `[[ -f ]]` but fails `jq` parse — `buddy_load` then returns `CORRUPT` permanently until manual intervention.
- **`set -e` pollution** is invisible in unit tests that run the library in isolation; it only manifests when a hook sources the library in a real Claude Code session and a subcommand fails for an unrelated reason, silently aborting the hook.
- **The atomic-delete dance** came out of building the P1-3 reset command: the first draft called `buddy_load` first to decide whether to wipe, which made CORRUPT state un-recoverable (the parse failed before the wipe could run). Switching to skip-parse-and-wipe made CORRUPT recoverable, but using a plain `rm` under the lock left a race window — a crash between the open and the unlink could leave a partially-wiped file. The rename-to-marker-then-unlink pattern closes both. The `.deleted` marker sweep is the crash-recovery net for the 1-in-N-million case where the process dies between `mv` and `rm`.

Getting these patterns right in the state library is foundational. Every hook, status-line script, and slash command in the plugin touches this code on every invocation. A bug here is a bug in everything.

## When to Apply

- Building any persistent state layer for a Claude Code plugin (bash + JSON).
- Writing any bash library that will be sourced by hook scripts subject to an "exit 0" contract.
- Any bash CLI using tmp+rename atomic writes where lock files, symlink attacks, or concurrent writers are a concern.
- Writing a destructive command (reset, clear, wipe) against a flock-protected state file — the atomic-delete dance in Section B + the `.deleted` sweep in Section E are the load-bearing pair.
- Writing bats tests for a sourced bash library where `set -e` pollution and stderr capture are non-obvious.

## Examples

**`set -e` at module scope vs. per-function handling**

```bash
# BAD — sourcing this library from a hook inherits set -e
set -euo pipefail

# GOOD — no module-level flags; each function handles errors explicitly
buddy_save() {
  local data_dir
  data_dir="$(_state_ensure_dir "buddy_save")" || return 1
  ...
}
```

**Lock file separate from data file**

```bash
# BAD — mv changes buddy.json's inode; lock on it becomes meaningless
exec {lock_fd}>"$data_dir/buddy.json"
flock -x "$lock_fd"
mv "$tmp" "$data_dir/buddy.json"   # lock_fd now points to old (unlinked) inode

# GOOD — lock file is a permanent sibling, never renamed
local lock_file="$data_dir/buddy.json.lock"
exec {lock_fd}>"$lock_file"
flock -x -w "$FLOCK_TIMEOUT" "$lock_fd"
mv -f "$tmp" "$data_dir/buddy.json"  # lock still held on lock_file
```

**Three sentinels vs. two**

```bash
# BAD — future-version file gets classified as CORRUPT; user wipes valid data
jq '.' "$buddy_file" || { echo "CORRUPT"; return 0; }

# GOOD — three sentinels distinguish "newer plugin wrote this" from "unparseable"
if (( version > CURRENT_SCHEMA_VERSION )); then
  printf '%s' "$STATE_FUTURE_VERSION"
  return 0
fi
```

**bash 3.x `exec {fd}` silent corruption vs. explicit version check**

```bash
# BAD — on bash 3.2: creates file named "{lock_fd}", $lock_fd is unset, no lock held
exec {lock_fd}>"$lock_file"

# GOOD — fail at source time on bash < 4.1
if (( BASH_VERSINFO[0] < 4 )) || \
   (( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 1 )); then
  echo "requires bash 4.1+" >&2
  return 1 2>/dev/null || exit 1
fi
```

**Colon-joined dedup vs. associative array**

```bash
# BAD — colon-joined string collides on keys that contain ':'
_warned="corrupt:/var/data/buddy.json"
[[ ":${_warned}:" == *":corrupt:/var/data/buddy.json:"* ]]

# GOOD — associative array, no separator issues
declare -gA _state_warned_keys=()
_state_warned_keys["corrupt:/var/data/buddy.json"]=1
[[ -v _state_warned_keys["corrupt:/var/data/buddy.json"] ]]
```

**Symlink check before `exec {fd}>`**

```bash
# BAD — symlink to regular file truncates target; symlink to FIFO hangs
exec {lock_fd}>"$lock_file"

# GOOD — reject symlinks before opening
if [[ -L "$lock_file" ]]; then
  _state_log "refusing to open symlinked lock file"
  return 1
fi
exec {lock_fd}>"$lock_file"
```

**Atomic delete under lock vs. plain `rm`**

```bash
# BAD — rm on state file under lock. Works in the happy path but:
#   - a crash between fd open and unlink is detectable only by inode absence
#   - calling buddy_load first makes CORRUPT state un-wipeable
if buddy_load >/dev/null; then
  rm -f "$buddy_file"
fi

# GOOD — rename to marker, then unlink, holding the lock across both.
# Skip buddy_load so CORRUPT state is still wipeable.
if [[ -f "$buddy_file" ]]; then
  mv -f "$buddy_file" "$buddy_file.deleted"
  rm -f "$buddy_file.deleted"
fi
# orphan sweep on next session start handles the SIGKILL-between-mv-and-rm case
```

**`.deleted` marker sweep: unconditional, not PID-aware**

```bash
# BAD — reusing the .tmp.* PID-aware policy on .deleted files
while IFS= read -r deleted_file; do
  pid="$(basename "$deleted_file" | awk -F. '{print $3}')"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    continue   # but there's no PID in .deleted filenames — this branch never fires
  fi
  rm -f "$deleted_file"
done < <(find "$data_dir" -maxdepth 1 -name 'buddy.json.deleted')

# GOOD — single unconditional rm. The marker represents a committed intent
# to wipe and cannot coexist with a live reset.
rm -f "$data_dir/buddy.json.deleted" 2>/dev/null || true
```

## Related

- [bash-state-library-concurrent-load-modify-save-2026-04-20.md](./bash-state-library-concurrent-load-modify-save-2026-04-20.md) — **partial update to this doc's guidance.** The `session_save` primitive here is documented as "typically single-writer" with no flock. P3-1 (hooks) made it a concurrent load-modify-save consumer; the new doc covers the caller-held flock pattern that must accompany this library when hooks are in play. If you're wiring hooks or background jobs to session state, read that doc alongside this one.
- [claude-code-plugin-scaffolding-gotchas-2026-04-16.md](../developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md) — establishes the "hooks must exit 0" plugin-system constraint that motivates this library's no-module-level-`set -e` design.
- [claude-code-skill-dispatcher-pattern-2026-04-19.md](../developer-experience/claude-code-skill-dispatcher-pattern-2026-04-19.md) — the SKILL.md-as-thin-dispatcher convention that invokes the backing bash scripts (including the reset command) which apply the atomic-delete dance documented here.
- [P1-1 state primitives plan](../../plans/2026-04-16-003-feat-p1-1-state-primitives-plan.md) — the plan document that produced this library.
- [P1-1 ticket](../../roadmap/P1-1-state-primitives.md) — the roadmap ticket, including the review findings Notes section.
- [P1-3 plan](../../plans/2026-04-19-001-feat-p1-3-slash-commands-plan.md) — origin of the atomic-delete extension (reset command + orphan-sweep update).
- [P1-3 ticket](../../roadmap/P1-3-slash-commands.md) — implementation notes including review-driven findings around the reset dance.
- [scripts/lib/state.sh](../../../scripts/lib/state.sh) — the reference implementation, including the `.deleted` sweep in `state_cleanup_orphans`.
- [scripts/reset.sh](../../../scripts/reset.sh) — the reference atomic-delete dance.
- [tests/state.bats](../../../tests/state.bats) — 52 tests exercising the library's write/read patterns.
- [tests/slash.bats](../../../tests/slash.bats) — 33 tests including atomic-delete dance, `.deleted` sweep, and flock-race coverage.
