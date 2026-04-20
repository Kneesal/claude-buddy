---
title: Concurrent load-modify-save in a bash state library — caller-held flock + split TTLs
date: 2026-04-20
category: best-practices
module: scripts/lib/state.sh
problem_type: best_practice
component: tooling
severity: high
applies_when:
  - A bash state library exposes atomic save via tmp+rename with no flock
  - A new caller becomes a load-modify-save consumer of an existing save primitive
  - Hook scripts, background jobs, or status-line scripts read/write the same JSON
  - A single age-based cleanup sweep reaps files with different lifecycles
  - A green unit-test suite provides false confidence that concurrency is safe
tags:
  - bash
  - state-management
  - concurrency
  - flock
  - atomic-writes
  - load-modify-save
  - ttl
  - adversarial-review
  - claude-code-plugin
---

# Concurrent load-modify-save in a bash state library — caller-held flock + split TTLs

## Context

`scripts/lib/state.sh` in the buddy plugin shipped an atomic `session_save` primitive via tmp+rename with the in-code comment "typically single-writer." The comment was true when the library was written — only slash commands wrote session state, one at a time, per user-invoked command. Rename atomicity was genuinely sufficient.

P3-1 added hooks that fire on every tool call, and two of them (`PostToolUse` + `PostToolUseFailure`) can fire concurrently for the same tool call. The hook pattern is load-modify-save: load the session JSON, push a tool-call ID onto the dedup ring, save the result. The "typically single-writer" assumption silently became false. Rename atomicity no longer protects the invariant — the race is **between** load and save, not during the write.

The failure was invisible:

- 243/243 bats tests green. Unit tests construct sequential payloads and cannot exercise a race.
- 9 independent code reviewers passed the diff. Only the **adversarial** reviewer — tasked with constructing failure scenarios — flagged it.
- `p95 < 100ms` was met. Performance budgets don't surface correctness bugs.
- The race is cosmetic in P3-1 (both writers push the same ID so content is identical), but **P3-2 cooldowns** and **P4-1 signal counts** land on the same path with event-specific fields. The first writer's fields would be silently dropped on every dual-fire.

A second, related learning surfaced in the same review: `state_cleanup_orphans` used a single `ORPHAN_MAX_AGE_MINUTES=60` constant to sweep both `.tmp` files and `session-*.json` files. 60 minutes is right for the ephemeral tmps but wrong for session files — Claude Code sessions routinely idle longer than that (user reading a long response, thinking, stepping away). A concurrent window's `SessionStart` would delete the other window's live-but-idle session file, causing the first window's next hook to silently re-init the ring.

Both learnings are facets of the same failure mode: **invariants that held for the original caller stop holding when a new caller with different access patterns arrives.**

## Guidance

### A. Caller-held flock around load-modify-save

When a save primitive is atomic in isolation but the caller does load-modify-save, acquire a per-resource flock in the **caller**, not the library. The library can't know whether the caller needs coverage across a read/modify cycle; only the caller knows.

The pattern mirrors what `buddy_save` already does internally, but hoisted to the caller:

```bash
# In each hook that does load-modify-save of session-<sid>.json:

local data_dir="${CLAUDE_PLUGIN_DATA:-}"
if [[ -z "$data_dir" || ! -d "$data_dir" ]]; then
  hook_log_error "$hook_name" "CLAUDE_PLUGIN_DATA missing; cannot lock session"
  return 0
fi

local lock_file="$data_dir/session-${sid}.json.lock"

# Reject symlinked lock files — `exec {fd}>file` with a regular-file
# symlink truncates the target; a FIFO symlink hangs past the timeout.
if [[ -L "$lock_file" ]]; then
  hook_log_error "$hook_name" "refusing symlinked session lock $lock_file"
  return 0
fi

local lock_fd
if ! exec {lock_fd}>"$lock_file"; then
  hook_log_error "$hook_name" "failed to open session lock for $sid"
  return 0
fi

# Non-blocking-ish with a tight timeout. Hooks must exit 0 under their
# p95 budget; blocking forever on contention breaks that.
if ! flock -x -w 0.2 "$lock_fd"; then
  exec {lock_fd}>&-
  hook_log_error "$hook_name" "flock timeout on session $sid"
  return 0
fi

# --- Critical section: load → modify → save, all under the lock ---
local session_json
session_json="$(session_load "$sid")"
if [[ -z "$session_json" || "$session_json" == "{}" ]]; then
  session_json="$(hook_initial_session_json "$sid")"
fi
local updated
updated="$(printf '%s' "$session_json" | hook_ring_update "$tcid")"
# ... handle DEDUP / empty / write ...
printf '%s' "$updated" | session_save "$sid"

exec {lock_fd}>&-   # Release the lock by closing the fd.
```

Key discipline points:

- Use `exec {fd}>file` (bash 4.1+). Releases automatically on `exec {fd}>&-` or process exit.
- Reject symlinked lock files before opening (mirrors `buddy_save`).
- Tight `-w` timeout bounds tail latency; log + exit 0 on timeout rather than blocking.
- Lock files are per-resource (one per session, not a global lock) so independent sessions don't serialize.
- The lock file is a sibling of the data file with a `.lock` suffix — clean up on the same sweep.

### B. Split TTL constants for heterogeneous file lifecycles

A single cleanup constant applied across file types with different semantic lifetimes is a silent interaction bug waiting to happen. Always split:

```bash
# Wrong: one constant for all files.
readonly ORPHAN_MAX_AGE_MINUTES=60

find "$data_dir" -name '.tmp.*'      -mmin "+$ORPHAN_MAX_AGE_MINUTES" -delete
find "$data_dir" -name 'session-*.json' -mmin "+$ORPHAN_MAX_AGE_MINUTES" -delete
# A live-but-idle session older than 60 min gets swept by a concurrent
# window's SessionStart. The first window's next hook silently re-inits.

# Right: one constant per semantic lifetime.
readonly ORPHAN_MAX_AGE_MINUTES=60               # tmp files — ephemeral
readonly SESSION_FILE_MAX_AGE_MINUTES=$((24*60)) # sessions — long-idle is normal

find "$data_dir" -name '.tmp.*'      -mmin "+$ORPHAN_MAX_AGE_MINUTES" -delete
find "$data_dir" -name 'session-*.json' -mmin "+$SESSION_FILE_MAX_AGE_MINUTES" -delete
find "$data_dir" -name 'session-*.json.lock' -mmin "+$SESSION_FILE_MAX_AGE_MINUTES" -delete
```

Default reasoning: the TTL ceiling should be the longest plausible legitimate idle period, not the shortest. For hook-written state in a Claude Code plugin that value is 24h — well past any realistic single-session duration.

### C. Adversarial review is not redundant with a green test suite

Unit tests verify logic under the inputs the author imagined. Adversarial review constructs inputs the author didn't imagine — concurrent fires of the same event, dual-fire on the same tool call, idle-then-resume across windows. Those are the scenarios where load-modify-save races live.

When a review diff introduces a new caller to an existing state primitive, the review must ask:

1. Does the new caller do load-modify-save?
2. Is the primitive's "atomic" guarantee actually sufficient across that cycle?
3. Can two instances of the new caller race with each other, or with the old callers?
4. Does any cleanup sweep over the primitive's data files assume single-caller timing?

Green bats means the logic works. Green adversarial review means the logic works when the world is hostile to it.

## Why This Matters

The race in P3-1 was silently corrupting only in hypothetical P3-2/P4-1 futures, so it would have shipped and landed in production before the first lost signal. The first lost signal would have looked like "the buddy's XP count is a bit off" — a phantom bug, unreproducible from unit tests, untraceable from logs because the hook exited 0 with no error. Correctness bugs that only manifest under concurrency and leave no trace are the most expensive class to debug retroactively.

The TTL interaction bug is cheaper in isolation (the dedup ring resets are cosmetic) but has the same shape: a silent, low-frequency, cross-session interaction that unit tests can't construct. Both patterns compound if they ship together — you get silent state corruption with no breadcrumb to follow.

The meta-lesson: **state libraries age.** A comment like "typically single-writer" is a load-bearing assumption that must be re-validated every time a new caller arrives. The review that matters is not "does this new caller work?" but "does this new caller invalidate assumptions the library had?"

## When to Apply

- When adding a new caller (hook, background job, status-line script) to a bash state library with a tmp+rename save primitive.
- When the new caller does load-modify-save on shared state rather than point-writes.
- When reviewing a diff that adds concurrent writers to a state file that was previously single-caller.
- When a single cleanup constant is being applied to files with different semantic lifetimes.
- When a unit-test suite is 100% green and the reviewer is inclined to trust it over adversarial construction.
- When the state library has a comment asserting a concurrency invariant that was true at write time — revisit it.

## Examples

### Before: the race that would have shipped

```bash
# hooks/post-tool-use.sh (P3-1 original)
local session_json
session_json="$(session_load "$sid")"
# ← window A and window B can both load '{}' here concurrently
local updated
updated="$(printf '%s' "$session_json" | hook_ring_update "$tcid")"
printf '%s' "$updated" | session_save "$sid"
# ← the second mv -f wins; the first writer's fields are silently lost
```

### After: caller-held lock

```bash
# hooks/post-tool-use.sh (P3-1 post-review)
local lock_file="$data_dir/session-${sid}.json.lock"
[[ -L "$lock_file" ]] && { hook_log_error ...; return 0; }
local lock_fd
exec {lock_fd}>"$lock_file" || { hook_log_error ...; return 0; }
flock -x -w 0.2 "$lock_fd" || { exec {lock_fd}>&-; hook_log_error ...; return 0; }

local session_json
session_json="$(session_load "$sid")"
[[ -z "$session_json" || "$session_json" == "{}" ]] && \
  session_json="$(hook_initial_session_json "$sid")"
local updated
updated="$(printf '%s' "$session_json" | hook_ring_update "$tcid")"
printf '%s' "$updated" | session_save "$sid"

exec {lock_fd}>&-
```

### Adversarial test scenario (the test that should exist)

```bash
@test "session_save under concurrent load-modify-save: no lost updates" {
  _seed_hatch 42
  local sid="sess-race"
  # Fire N concurrent hooks with distinct tool_use_ids.
  for i in $(seq 1 10); do
    jq -n --arg s "$sid" --arg t "tu_$i" \
      '{session_id: $s, tool_use_id: $t}' \
      | "$POST_SH" &
  done
  wait
  # Every distinct id must appear exactly once in the ring.
  local ring_len
  ring_len="$(jq -r '.recentToolCallIds | length' \
              "$CLAUDE_PLUGIN_DATA/session-$sid.json")"
  [ "$ring_len" = "10" ]
}
```

The test must **run** the hooks in parallel shells (backgrounded, then `wait`). Synthetic sequential bats assertions will not reproduce the race even when the bug is present.

## Related

- [bash-state-library-patterns-2026-04-18.md](./bash-state-library-patterns-2026-04-18.md) — the original state library discipline doc. Its guidance that `session_save` is "typically single-writer" was correct when written but is **no longer accurate** as of P3-1 — the hook layer is now a concurrent load-modify-save consumer. Candidate for `/ce:compound-refresh bash-state-library-patterns-2026-04-18`.
- [bash-subshell-state-patterns-2026-04-19.md](./bash-subshell-state-patterns-2026-04-19.md) — related "works in isolation, breaks under a different call pattern" family.
- [claude-code-plugin-hooks-json-schema-2026-04-20.md](../developer-experience/claude-code-plugin-hooks-json-schema-2026-04-20.md) — the sibling P3-1 learning about Claude Code's hooks.json schema.
- P3-1 ticket: [docs/roadmap/P3-1-hook-wiring.md](../../roadmap/P3-1-hook-wiring.md) — Notes section records the full post-review hardening.
- Review artifacts: `.context/compound-engineering/ce-review/20260420-214142-9d369192/` — the 10-reviewer parallel audit that surfaced this finding (specifically `adversarial.json` finding ADV-002 and `reliability.json` finding R-01).
