---
title: Returning (value, JSON) from a bash function through a command-substitution subshell
date: 2026-04-21
category: best-practices
module: scripts/hooks/commentary.sh
problem_type: best_practice
component: tooling
severity: high
applies_when:
  - A bash function needs to return two pieces of data per call — a scalar (line to emit) AND a structured payload (updated JSON) — from within a caller that uses `$(...)` command substitution
  - Writing an event-handler function whose callers must both print something to stdout AND persist an updated state blob atomically
  - Refactoring a function whose "set a global plus print stdout" contract silently fails under `out="$(fn ...)"` captures
  - Reviewing bash helpers that expose both `echo`-able results and internally-maintained out-params
related_components:
  - hooks
  - testing_framework
tags:
  - bash
  - subshell
  - command-substitution
  - stdout-contract
  - function-return
  - claude-code-plugin
---

# Returning (value, JSON) from a bash function through a command-substitution subshell

## Context

`scripts/hooks/commentary.sh` (P3-2) has a public function
`hook_commentary_select` whose job is to decide (a) whether buddy
should emit a line to the Claude Code transcript, and (b) to hand
back the updated session JSON that must be persisted atomically with
that decision. Both outputs are needed per call; both must reach
the caller.

The first implementation used a natural-looking pattern:

```bash
hook_commentary_select() {
  _BUDDY_COMMENT_LINE=""                       # reset global
  # ... decision logic ...
  _BUDDY_COMMENT_LINE="$emoji $name: \"$line\""
  printf '%s' "$updated_session_json"          # return payload on stdout
}

# Caller
updated="$(hook_commentary_select "$event" "$session" "$buddy")"
[[ -n "$_BUDDY_COMMENT_LINE" ]] && printf '%s\n' "$_BUDDY_COMMENT_LINE"
```

This looked clean. It passed unit tests that called
`hook_commentary_select` directly. It failed silently the moment the
hook script captured the payload into a variable: `_BUDDY_COMMENT_LINE`
read back as empty every time.

The failure mode is the same one documented in
[bash-subshell-state-patterns-2026-04-19.md](./bash-subshell-state-patterns-2026-04-19.md),
but the use case is different: that doc is about *carrying state
forward across calls*, where "move the state up into outer scope"
resolves it. Here we need to return two pieces of data from *one*
call, and the caller has already opted into a subshell by using
`$(...)`. The outer-scope fix doesn't apply.

## Guidance

### A. Multiplex both outputs onto stdout; caller splits

Emit the two values on stdout separated by a boundary the payload
can't contain. Since the session JSON is always compacted through
`jq -c`, a newline is a safe delimiter:

```bash
# Function — two lines: scalar first, JSON second
hook_commentary_select() {
  # ... decide ...
  local line=""                  # empty when no emit
  local updated_json
  updated_json="$(printf '%s' "$session" | jq -c '...' )"
  printf '%s\n%s' "$line" "$updated_json"
}

# Caller — parameter expansion, no fork
out="$(hook_commentary_select "$event" "$session" "$buddy")"
line="${out%%$'\n'*}"            # everything before first newline
updated_json="${out#*$'\n'}"     # everything after first newline
[[ -n "$line" ]] && printf '%s\n' "$line"
```

Key properties:

- **No globals cross the subshell boundary.** All state is in
  `out`, which `$(...)` returns cleanly.
- **Pure parameter expansion for the split.** No extra fork, no
  `cut`/`awk`/`sed`, no IFS gymnastics.
- **Delimiter is invariant.** The JSON payload is always
  single-line (emitted via `jq -c`); the scalar is stripped of
  embedded newlines before format; the split is unambiguous.

### B. Sanitize scalar output so the delimiter stays invariant

Any embedded `\n` in the scalar portion corrupts the split. If the
scalar comes from user/author-controlled content (species lines,
commit messages, tool output), strip control bytes *before*
assembling the two-line payload:

```bash
line="${line//$'\n'/ }"                      # or
line="$(printf '%s' "$line" | tr -d '[:cntrl:]')"  # stricter
```

### C. Fail the emit, not the save, if JSON compaction fails

The stdout payload contract is "scalar, newline, compact JSON." If
the JSON compaction step fails (jq crashes, input malformed), do
**not** fall back to emitting a pretty-printed multi-line JSON —
that will poison the caller's newline split and can write corrupted
state to disk. Prefer emitting an empty scalar + empty payload and
letting the caller's defensive fallback (`[[ -z "$final_session" ]]
&& final_session="$pre_call_session"`) persist the pre-call state
unchanged:

```bash
_emit() {
  local compact
  compact="$(printf '%s' "$_SESSION_OUT" | jq -c '.' 2>/dev/null)"
  if [[ -z "$compact" ]]; then
    printf '\n'                  # empty scalar, empty payload
    return
  fi
  printf '%s\n%s' "$_LINE_OUT" "$compact"
}
```

### D. Document the contract at the function's top

Two-line stdout contracts are unusual enough that a future reviewer
may not spot them. Put the contract in the function's docstring
block with the exact caller snippet a reader should copy:

```bash
# hook_commentary_select <event_type> <session_json> <buddy_json>
#   Emits TWO lines on stdout:
#     line 1: scalar result (empty string for no-op)
#     line 2: compact (jq -c) session JSON
#   Caller:
#     out="$(hook_commentary_select ...)"
#     scalar="${out%%$'\n'*}"
#     json="${out#*$'\n'}"
```

## Why This Matters

The naïve "global + stdout" pattern is the default reach for bash
function return values. A silent failure mode in that pattern —
one that doesn't show up until a caller introduces `$(...)` —
wastes debugging time and is easy to re-introduce.

Two-line stdout is not clever. It is the boring, composable fix:
it turns the return into a single string the caller owns, split
on a boundary the string can't contain. Every downstream concern
(atomicity, rollback, testability) gets easier once the two-value
return stops depending on side-effects.

## When to Apply

- A bash function must return both a scalar and a structured payload
  per call.
- The function's callers will use `$(...)` command substitution to
  capture one of those values.
- The caller sits on the hot path of a hook, critical section, or
  other place where a second invocation to "get the other value"
  isn't acceptable.
- State persistence and user-visible emission must happen atomically
  with respect to the decision — you cannot do the decide-then-call
  -again dance without a race.

## Examples

### Before — global + stdout (silently broken under `$(...)`)

```bash
decide() {
  _COMMENT=""
  # ...
  _COMMENT="hello"
  printf '%s' "$updated_json"
}

# Caller: _COMMENT reads back empty
json="$(decide ...)"; [[ -n "$_COMMENT" ]] && printf '%s\n' "$_COMMENT"
```

### After — two-line stdout

```bash
decide() {
  local comment=""
  # ...
  comment="hello"
  printf '%s\n%s' "$comment" "$updated_json"
}

# Caller
out="$(decide ...)"
comment="${out%%$'\n'*}"
json="${out#*$'\n'}"
[[ -n "$comment" ]] && printf '%s\n' "$comment"
```

### Bats-style assertion for the contract

```bash
@test "decide: returns exactly one newline between scalar and JSON" {
  out="$(decide "$input")"
  [ "$(printf '%s' "$out" | tr -cd '\n' | wc -c)" = "1" ]
  printf '%s' "${out#*$'\n'}" | jq -e '.' >/dev/null
}
```

## Related

- [bash-subshell-state-patterns-2026-04-19.md](./bash-subshell-state-patterns-2026-04-19.md)
  — same failure class (subshell eats mutation) but different use case
  and different fix. Read that doc first if the problem is "state
  doesn't advance across calls"; read this doc if the problem is
  "need two return values from one call."
- [bash-state-library-concurrent-load-modify-save-2026-04-20.md](./bash-state-library-concurrent-load-modify-save-2026-04-20.md)
  — the flock discipline the caller is holding when using this
  pattern. The two-line return makes the critical-section save
  straightforward.
- `scripts/hooks/commentary.sh` — canonical in-repo implementation of
  this pattern as of P3-2.
