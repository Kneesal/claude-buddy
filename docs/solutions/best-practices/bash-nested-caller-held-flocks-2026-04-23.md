---
title: Nested caller-held flocks across multiple state files — ordering, library escape hatch, per-open-file-description semantics
date: 2026-04-23
category: best-practices
module: scripts/lib/state.sh
problem_type: best_practice
component: tooling
severity: high
applies_when:
  - A hook or caller must hold flocks on two (or more) resource files across a single load-modify-save cycle
  - The underlying state library already takes a flock internally (so the caller + library both lock the same file)
  - A refactor extends the P3-1 caller-held-flock pattern from a single resource to multiple resources
  - A review asks "would inverting the order of these flocks deadlock?"
  - A silent-XP-loss bug is reported and you suspect flock contention in a hot path
related_components:
  - state-library
  - hooks
  - concurrency
tags:
  - bash
  - state-management
  - concurrency
  - flock
  - lock-ordering
  - load-modify-save
  - caller-held
  - per-open-file-description
  - claude-code-plugin
---

# Nested caller-held flocks across multiple state files

## Context

P3-1 established a single-resource pattern: hooks hold a flock on
`session-<id>.json.lock` across the load-modify-save cycle of
`session-<id>.json`. That worked because `session_save` had no
internal flock — rename atomicity plus the caller-held lock was
sufficient.

P4-1 added a second state file to the same hot path: every hook
fire now mutates **both** `session-<id>.json` and `buddy.json`.
Two new concerns surfaced that the single-resource doc did not
cover.

1. The buddy state library already holds an internal flock.
   `buddy_save` opens `buddy.json.lock` via `exec {fd}>` and calls
   `flock -x -w 0.2`. A hook that wraps `buddy_save` inside a
   caller-held flock on the same lock file opens a **second** fd
   against the same file in the same process, and calls `flock -x`
   again. Under Linux's per-open-file-description lock semantics
   the two fds are treated as distinct holders; the library's
   inner acquire blocks on the caller's outer hold, times out at
   0.2 s, logs, and returns non-zero. The hook then exits 0 with
   nothing saved. No user-visible signal, no partial state, no
   breadcrumb.

2. Holding two resource locks means there is now a **lock order**
   to get wrong. If one code path acquires session-then-buddy and
   another acquires buddy-then-session, two concurrent hooks can
   deadlock. With 0.2 s timeouts the deadlock degrades silently
   into a lost update rather than a visible hang, which is the
   worse failure mode because it leaves no diagnostic trail.

Both issues are single-process-family concerns: they bite
specifically because hooks run as subprocesses of the same
Claude Code process, not across separate shells. Both are also
invisible to the bats suite by default — unit tests construct
sequential payloads and cannot exercise contention.

## Guidance

### A. Library-held-lock escape hatch when caller holds the same file's lock

When a state library takes its own flock internally but a new
caller (hook, background job) needs to hold the same flock across
a load-modify-save cycle, give the library an explicit skip-the-
internal-flock knob. The cleanest form is an env-var override,
because bash functions invoked via pipe (`printf ... | buddy_save`)
run in a subshell that still inherits the caller's shell variables.

Pattern:

```bash
# In the library (state.sh):
buddy_save() {
  # ...validate input, compute paths...

  # Caller-held flock escape hatch. Hooks nest buddy.json.lock inside
  # the session lock; any other caller leaves this unset and gets the
  # library-level flock below.
  local caller_holds_lock=0
  if [[ "${_BUDDY_SAVE_LOCK_HELD:-}" == "1" ]]; then
    caller_holds_lock=1
  fi

  local lock_fd=""
  if (( caller_holds_lock == 0 )); then
    [[ -L "$lock_file" ]] && { _state_log "..."; return 1; }
    exec {lock_fd}>"$lock_file" || { _state_log "..."; return 1; }
    flock -x -w "$FLOCK_TIMEOUT" "$lock_fd" || {
      exec {lock_fd}>&-; _state_log "..."; return 1;
    }
  fi

  # tmp + rename, same on both paths.
  local tmp
  tmp="$(mktemp ...)" || { [[ -n "$lock_fd" ]] && exec {lock_fd}>&-; return 1; }
  printf '%s\n' "$content" > "$tmp" || { rm -f "$tmp"; [[ -n "$lock_fd" ]] && exec {lock_fd}>&-; return 1; }
  mv -f "$tmp" "$buddy_file" || { rm -f "$tmp"; [[ -n "$lock_fd" ]] && exec {lock_fd}>&-; return 1; }

  [[ -n "$lock_fd" ]] && exec {lock_fd}>&-
  return 0
}
```

The hook sets the variable as a **local**, then invokes the pipe:

```bash
# In the hook:
local _BUDDY_SAVE_LOCK_HELD=1
if ! printf '%s' "$buddy_after" | buddy_save; then
  _BUDDY_SAVE_LOCK_HELD=
  exec {buddy_lock_fd}>&-
  exec {session_lock_fd}>&-
  hook_log_error "$hook_name" "buddy_save failed"
  return 0
fi
_BUDDY_SAVE_LOCK_HELD=
```

Two subtleties worth calling out in code comments:

- **Why a local, not export?** A pipe spawns a subshell for the
  rightmost command, but the subshell still inherits *all* of the
  parent's shell variables (both `local`-scoped and globals).
  `export` would be unnecessary and would leak the variable into
  any non-pipe child the hook later spawns. `local` keeps the
  variable scoped to the function that sets it.
- **Why explicit `=` after the call?** Clearing the variable
  immediately after the guarded pipe limits the blast radius. If
  a later refactor ever adds a second `buddy_save` call in the
  same hook function without reacquiring the caller-held lock,
  the flag does not still be active from the prior call.

### B. Global, documented lock ordering when taking multiple resource flocks

Every site that takes both locks must take them in the same order.
For the buddy plugin the order is **session OUTER, buddy INNER**,
released in reverse. Document the rule in every acquisition site
so a reviewer can catch inversions without tracing through every
call path.

```bash
# Outer: per-session flock (P3-1 discipline)
exec {session_lock_fd}>"$session_lock_file"
flock -x -w 0.2 "$session_lock_fd" || { ...log, return 0... }

# ...load session state, dedup-ring update, etc...

# Inner: per-buddy flock (P4-1 addition)
# Session lock is already held. Order is session OUTER, buddy INNER.
exec {buddy_lock_fd}>"$buddy_lock_file"
flock -x -w 0.2 "$buddy_lock_fd" || {
  exec {session_lock_fd}>&-
  ...log, return 0...
}

# ...critical section: signals_apply, commentary, dual-save...

# Release in reverse order: buddy (inner) then session (outer)
exec {buddy_lock_fd}>&-
exec {session_lock_fd}>&-
```

Why the 0.2 s timeout makes getting this wrong especially bad:
under real contention a classic AB/BA deadlock would hang the
process visibly. With `flock -x -w 0.2`, each side times out after
200 ms and exits 0. The user sees nothing. The suite stays green.
Silent, low-frequency, leaves no trace in logs — the most
expensive class to debug retroactively.

Treat lock-order discipline as load-bearing: call it out in code
review checklists, in every acquisition-site comment, and in the
plan document before the implementation starts.

### C. Why Linux flock semantics bite here specifically

Linux `flock(2)` is advisory and scoped to the **open file
description**, not the file or the process. Two `open()` calls on
the same file — even from the same process — produce two
independent open file descriptions, and `flock` treats them as
independent holders. A process that already holds a lock via fd A
will **block** on its own lock when it tries to acquire via a new
fd B. This is not re-entrant.

`fcntl(F_SETLK)` has different semantics (per-process,
re-entrant) but is not what `flock(1)` or `flock(2)` use. Do not
assume re-entrancy unless you have verified the exact primitive.

This is what makes the library-plus-caller double-lock so
treacherous: everything lives in one bash process and looks like
it should be re-entrant, but the kernel disagrees.

### D. Adversarial test coverage for both failure modes

Neither failure mode is catchable by sequential bats assertions.
Add at least one test for each:

```bash
@test "buddy_save honors _BUDDY_SAVE_LOCK_HELD without deadlocking" {
  _seed_hatch

  # Open the buddy lock in this shell, then flock-wait it.
  local lock_fd
  exec {lock_fd}>"$CLAUDE_PLUGIN_DATA/buddy.json.lock"
  flock -x "$lock_fd"

  # buddy_save with the override must NOT deadlock against our held lock.
  local _BUDDY_SAVE_LOCK_HELD=1
  echo '{"buddy":{"xp":42,"level":1}}' | buddy_save

  flock -u "$lock_fd"
  exec {lock_fd}>&-

  # Write landed.
  [ "$(jq '.buddy.xp' "$CLAUDE_PLUGIN_DATA/buddy.json")" = "42" ]
}

@test "concurrent dual-fire does not lose XP among survivors" {
  # Background N PTU hooks in parallel; some will time out under
  # 0.2s flock contention and that is expected. Invariant: every
  # fire that made it into the session dedup ring ALSO landed its
  # buddy-side mutation. No lost updates for survivors.
  local i
  for i in $(seq 1 10); do
    _fire_with_tool "sess-cc" "tu_$i" "Bash" "" &
  done
  wait
  local ring_len xp expected
  ring_len="$(jq -r '.recentToolCallIds | length' session-file)"
  xp="$(jq -r '.buddy.xp' buddy-file)"
  expected=$(( first_fire_xp + (ring_len - 1) * subsequent_xp ))
  [ "$xp" = "$expected" ]
}
```

The second test is the right shape — it accepts that some hooks
will time out under real contention (that is the hook contract)
while asserting no lost writes for the ones that make it through.
A test that insists all N land would flake under legitimate
timeout behavior and encourage raising the timeout, which
breaks the p95 budget instead.

## Why This Matters

This doc exists because two failure modes inherited the same
invisibility pattern from P3-1:

- Silent lost writes under concurrency
- No user-visible error
- Bats green
- No breadcrumb in logs

P3-1 was saved by an adversarial reviewer constructing a dual-fire
scenario. P4-1 extended the surface to a second file and added two
new failure modes (library-caller double-lock, inverted-order
deadlock) that the P3-1 doc did not name. The combined discipline
— escape hatch + global ordering + explicit comments at each
acquisition site — is the contract that keeps the silent-lost-
write class bounded.

Secondarily: the more resources you lock, the more important it
becomes that the lock files themselves are cleaned up. The split-
TTL rule from the P3-1 doc applies to every new `.lock` file at
the same cadence as its data file.

## When to Apply

- Any new hook, background job, or status-line script that needs
  to mutate more than one state file in a single critical section.
- A state library that already self-locks gets a new caller that
  does load-modify-save. The library needs the escape-hatch knob.
- A review diff adds a second `exec {fd}>$lock_file` site. Verify
  the order matches every other site.
- Code review persona work: if the diff takes two locks, the
  always-on adversarial reviewer should construct the AB/BA case.

## Examples

### Before — naive nesting with library internal flock

```bash
# hooks/post-tool-use.sh (broken)
exec {session_fd}>"$session_lock"; flock -x "$session_fd"
# ...session mutations...
printf '%s' "$buddy_json" | buddy_save   # buddy_save's internal
                                         # flock blocks on our
                                         # external hold -> timeout
                                         # -> write silently dropped
exec {session_fd}>&-
```

### After — escape hatch + nested discipline

```bash
# hooks/post-tool-use.sh (correct)
exec {session_fd}>"$session_lock"; flock -x -w 0.2 "$session_fd" || return 0

# nested buddy lock (D1/D2 — session OUTER, buddy INNER)
exec {buddy_fd}>"$buddy_lock";     flock -x -w 0.2 "$buddy_fd" || {
  exec {session_fd}>&-; return 0
}

# ...compute updates, apply signals, select commentary...

local _BUDDY_SAVE_LOCK_HELD=1
printf '%s' "$buddy_after" | buddy_save || {
  _BUDDY_SAVE_LOCK_HELD=
  exec {buddy_fd}>&-; exec {session_fd}>&-
  return 0
}
_BUDDY_SAVE_LOCK_HELD=

printf '%s' "$session_after" | session_save "$sid" || {
  exec {buddy_fd}>&-; exec {session_fd}>&-
  return 0
}

# Release in reverse: buddy (inner) then session (outer)
exec {buddy_fd}>&-
exec {session_fd}>&-
```

## Related

- [bash-state-library-concurrent-load-modify-save-2026-04-20](./bash-state-library-concurrent-load-modify-save-2026-04-20.md)
  — the P3-1 doc that established the single-resource caller-held
  flock pattern. This doc extends the pattern to multi-resource
  critical sections. Neither obsoletes the other; this doc
  references and builds on it.
- [bash-state-library-patterns-2026-04-18](./bash-state-library-patterns-2026-04-18.md)
  — the original P1-1 state-library discipline doc. Its
  description of `buddy_save` self-locking was correct at write
  time and is still correct, but callers may now need the
  `_BUDDY_SAVE_LOCK_HELD=1` override when they hold the same
  lock externally.
- P4-1 ticket: [docs/roadmap/P4-1-xp-signals.md](../../roadmap/P4-1-xp-signals.md)
  — implementation notes record the review finding that surfaced
  both failure modes.
- P4-1 plan D1/D2: [docs/plans/2026-04-21-001-feat-p4-1-xp-signals-plan.md](../../plans/2026-04-21-001-feat-p4-1-xp-signals-plan.md)
  — the ordering and escape-hatch decisions in the plan.
