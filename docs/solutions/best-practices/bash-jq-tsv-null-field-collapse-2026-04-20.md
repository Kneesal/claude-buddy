---
title: bash jq @tsv + IFS-tab null-field collapse — use a validator or readarray
date: 2026-04-20
category: best-practices
module: shell-scripting
problem_type: best_practice
component: tooling
severity: high
applies_when:
  - Extracting multiple JSON fields in a single jq invocation via `@tsv`
  - Consuming jq output with `IFS=$'\t' read -r` in a bash script
  - Writing any renderer that accepts JSON envelopes where a field can be null, missing, or an empty string
  - Defensive scripts that must keep working on hand-edited or partially-migrated state files
tags:
  - bash
  - jq
  - tsv
  - ifs
  - readarray
  - field-split
  - null-safety
  - claude-code-plugin
---

# bash jq `@tsv` + IFS-tab null-field collapse — use a validator or readarray

## Context

`jq -r '... | @tsv'` piped into `IFS=$'\t' read -r a b c` is a common idiom for extracting multiple JSON fields in one fork. It's fast, compact, and reads well — right up until a field is `null` or empty. Then it silently produces the wrong answer.

The failure mode is a bash quirk: when `IFS` is set to a single whitespace character (tab is whitespace to bash), `read -r` collapses runs of that character into a single delimiter. `@tsv` emits a literal tab even for null/empty fields, so `["Alice", null, "axolotl"]` becomes `Alice\t\taxolotl` — two tabs for the null — and `read -r a b c` assigns `Alice` to `a`, `axolotl` to `b`, leaves `c` unset. Every field after the first empty one lands in the wrong variable.

This was discovered empirically during P2 (buddy-plugin status-line work). Two independent renderers — `scripts/status.sh` and `statusline/buddy-line.sh` — both consume a buddy.json envelope via jq multi-field extraction. When a schemaVersion=1 envelope has `.buddy = null` or `.buddy = {}` (parseable JSON, just structurally broken), it slips past the `buddy_load` sentinel check and reaches the extractor. Pre-fix output: `🐾 false (0 0 · Lv.) · 🪙` — scrambled, not crashed. Exit code 0. No stack trace to grep for.

The extraction path is the right idea; the `IFS=$'\t'` consumer is the landmine. Two fixes worked in practice, and the right one depends on what the caller can guarantee.

## Guidance

### Option A: upstream validator (keep `@tsv` on the happy path)

Add a first jq invocation that returns `"yes"` or `"no"` based on shape checks. Only run the `@tsv` extractor when validation passes; otherwise route to a corrupt/repair message.

```bash
_render_active() {
  local json="$1"

  # Validate shape upstream. Any structural failure routes to repair.
  local valid
  valid="$(printf '%s' "$json" | jq -r '
    if (.buddy | type) != "object" then "no"
    elif (.buddy.species // "" | length) == 0 then "no"
    elif (.buddy.name    // "" | length) == 0 then "no"
    elif (.buddy.rarity  // "" | length) == 0 then "no"
    else "yes"
    end' 2>/dev/null)"
  if [[ "$valid" != "yes" ]]; then
    _render_repair
    return 0
  fi

  # Envelope is now known-valid. The @tsv + IFS-tab split is safe because
  # every required string field is guaranteed non-empty.
  local fields
  fields="$(printf '%s' "$json" | jq -r '[
      .buddy.name,
      .buddy.species,
      .buddy.rarity,
      .buddy.level,
      .tokens.balance
    ] | @tsv')"

  local name species rarity level balance
  IFS=$'\t' read -r name species rarity level balance <<< "$fields"
  ...
}
```

Good when:
- The caller is the only source of the JSON and can enforce the shape contract upstream.
- The happy path is hot and you want one jq fork after the validator (cache-friendly, one allocation).
- The "validate once, trust the fields" narrative matches your error story — malformed envelopes become explicit CORRUPT outputs, not silent mis-renders.

### Option B: newline-delimited `readarray` (defensive extraction)

Replace `@tsv` with field-per-line jq output and `readarray -t`. Newlines aren't whitespace to bash's line-splitter, so empty lines survive as empty array slots rather than being collapsed away. Also `gsub` string fields to strip embedded newlines/tabs so a hand-edited value can't split across slots.

```bash
_render_active() {
  local json="$1"

  # Still validate upstream so null/missing .buddy routes to repair. The
  # readarray path handles empty fields correctly, but you still want a
  # clean error message rather than a blank-filled status line.
  local shape
  if ! shape="$(printf '%s' "$json" | jq -r '.buddy | type' 2>/dev/null)" \
      || [[ "$shape" != "object" ]]; then
    _render_repair
    return 0
  fi

  # One jq call, one line per field. gsub normalizes string fields so an
  # embedded newline in a value can't split across readarray slots.
  local fields_raw
  fields_raw="$(printf '%s' "$json" | jq -r '
    (.buddy.species | gsub("[\\n\\r\\t]"; " ")),
    (.buddy.name    | gsub("[\\n\\r\\t]"; " ")),
    (.buddy.rarity  | gsub("[\\n\\r\\t]"; " ")),
    (.buddy.level // 0 | tostring),
    (.tokens.balance // 0 | tostring)' 2>/dev/null)"
  local -a parts=()
  readarray -t parts <<< "$fields_raw"
  local species="${parts[0]:-}" name="${parts[1]:-}" rarity="${parts[2]:-}"
  local level="${parts[3]:-0}" balance="${parts[4]:-0}"
  ...
}
```

Good when:
- The extractor must survive more shape variance than an upstream guard can reasonably assert (e.g., migration in flight, hand-edited JSON).
- You want the split layer itself to be robust, not just the happy path.
- You need to accept values that might legitimately be empty strings (not null, just `""`) — `readarray` preserves them; `IFS=$'\t' read` does not.

### Choosing between them

| Signal | Preferred option |
|---|---|
| Caller owns the JSON producer and can enforce a shape contract | A (upstream validator) |
| Multiple producers write to the file (migrations, other agents, hand-edits) | B (readarray) |
| Hot render path, one call per second | A (fewer forks after the validator) |
| Fields can legitimately be empty strings | B (readarray preserves empties) |
| You want explicit "this envelope is invalid" messaging | A (the validator is the error seam) |
| You want defense-in-depth — even if validation ever regresses, the split can't silently scramble | B (the extraction layer is the last line of defense) |

Both options start with a shape check — that's load-bearing regardless. The difference is what the extraction layer does once the shape is believed-good. A trusts it; B defends anyway.

### What NOT to do

Do **not** assume `IFS=$'\t'` behaves like a non-whitespace delimiter. It does not. Consecutive tabs collapse.

Do **not** rely on "no field will ever be empty in practice" as a contract. JSON allows null, empty strings, and missing keys; jq surfaces all three as empty fields in `@tsv`. Any future migration, hand-edit, or upstream bug can introduce an empty field, and the consumer will silently mis-render rather than fail loud.

Do **not** switch to `IFS=|` or other single-char non-whitespace delimiters as a workaround. It works, but encodes a new invariant (no field can contain `|`) that's hard to enforce. Strings you don't control (species names, LLM-generated names, user-supplied labels) will eventually violate it.

Do **not** use `@csv` — it quotes strings, which then need `xargs` or a CSV parser to consume correctly in bash. The complexity exceeds the original problem.

## Why This Matters

The bug is quiet. Empirically from P2: an envelope with `.buddy = null` produced `🐾 false (0 0 · Lv.) · 🪙` instead of crashing or routing to "buddy state needs repair". Exit code 0. No stderr. A user would see garbled output on every assistant turn and have no obvious path to "this is broken — run reset". Tests that only assert on content presence (`[[ "$output" == *"axolotl"* ]]`) pass even when the fields are completely scrambled, because the rarity value ends up where species should be.

The same hazard hit twice in the same codebase, in two renderers written weeks apart, by the same author. Both would have shipped without the bug being noticed if the test suite hadn't specifically asserted the repair-path message for malformed envelopes. Empty fields in external data are ambient — they arrive eventually.

Catching it at the extraction layer (or gating it upstream) is a one-time cost per renderer. Every subsequent extraction in the same script is safe for free.

## When to Apply

- Any time a bash script runs `jq -r '... | @tsv'` piped into `read -r` or similar.
- Any time a bash script does field-parallel extraction across 3+ JSON fields.
- When reviewing a diff that adds a new renderer / consumer of an existing JSON envelope. Verify the fields the new consumer reads cannot be null or empty in any legitimate envelope, or that a shape check gates the extraction.
- When extending an existing `@tsv` consumer to read an additional field — the new field multiplies the collapse surface; re-audit upstream.

## Examples

### Anti-pattern: `@tsv` + `IFS=$'\t' read` with no shape guard

```bash
# BAD — consecutive empty fields collapse; downstream assignments shift left.
fields="$(jq -r '[.a, .b, .c, .d] | @tsv' <<< "$json")"
IFS=$'\t' read -r a b c d <<< "$fields"

# Input: {"a":"X","b":null,"c":null,"d":"Y"}
# @tsv emits: X\t\t\tY
# After read: a=X, b=Y, c="", d=""   ← b,c,d are WRONG
```

### Fix A: upstream validator + trusted `@tsv`

```bash
# GOOD — validate shape first, then the split is safe.
valid="$(jq -r '
  if (.a // "" | length) == 0 then "no"
  elif (.b // "" | length) == 0 then "no"
  elif (.c // "" | length) == 0 then "no"
  elif (.d // "" | length) == 0 then "no"
  else "yes"
  end' <<< "$json")"
[[ "$valid" != "yes" ]] && { _render_repair; return 0; }

fields="$(jq -r '[.a, .b, .c, .d] | @tsv' <<< "$json")"
IFS=$'\t' read -r a b c d <<< "$fields"
# All four fields are guaranteed non-empty; collapse cannot happen.
```

### Fix B: newline-delimited `readarray`

```bash
# GOOD — newlines are not whitespace to readarray; empties survive.
fields_raw="$(jq -r '
  (.a // ""), (.b // ""), (.c // ""), (.d // "")' <<< "$json")"
local -a parts=()
readarray -t parts <<< "$fields_raw"
local a="${parts[0]:-}" b="${parts[1]:-}" c="${parts[2]:-}" d="${parts[3]:-}"

# Input: {"a":"X","b":null,"c":null,"d":"Y"}
# jq emits: X\n\n\nY
# After readarray: parts=(X "" "" Y)
# a=X, b="", c="", d=Y   ← correct
```

### Test scenario that catches the bug

```bash
@test "renderer: envelope with null required field does not silently shift other fields" {
  echo '{"a":"X","b":null,"c":null,"d":"Y"}' > "$INPUT"
  run --separate-stderr bash "$RENDERER" < "$INPUT"
  [ "$status" -eq 0 ]
  # The key assertion: a scrambled render would put 'Y' where 'b' should be.
  # With either fix, the renderer routes to repair instead.
  [[ "$output" == *"Buddy state needs repair"* ]]
  [[ "$output" != *"X Y"* ]]   # prevents the scrambled output from passing
}
```

The "does NOT contain the scrambled form" assertion is load-bearing. Content-presence tests (`[[ "$output" == *"Y"* ]]`) accept the bug; content-absence catches the field shift.

## Related

- [bash-state-library-patterns-2026-04-18.md](./bash-state-library-patterns-2026-04-18.md) — structural conventions for bash libraries (no module-scope `set -e`, bash 4.1+, flock discipline). This pattern is a runtime companion to those structural conventions: even with perfect library hygiene, the consumer layer can still silently corrupt output if `@tsv` + `IFS=$'\t'` meets a null field.
- [bash-subshell-state-patterns-2026-04-19.md](./bash-subshell-state-patterns-2026-04-19.md) — the `$()` subshell gotcha has the same character as this one: works fine on the happy path, silently wrong on the edge case, not caught by naive tests. Same family of "bash is helpful in a way that hurts you."
- [bash-lcg-hotpath-patterns-2026-04-19.md](./bash-lcg-hotpath-patterns-2026-04-19.md) — uses `@tsv` for performance in the hot path. Those usages are safe because the fields are always present integers (stat rolls, never null). If that invariant ever changes, the validator or readarray pattern applies there too.
- Reference implementations: `/workspace/scripts/status.sh` (validator pattern — chose A because `buddy_load` is the only producer and shape can be enforced once at the seam) and `/workspace/statusline/buddy-line.sh` (readarray pattern — chose B because the status line runs on every turn and hand-edited envelopes are a realistic threat).
- Origin ticket: `docs/roadmap/P2-status-line.md`. Surfaced during P1-3 implementation and re-surfaced in P2; the review-round ce:review flagged it with high cross-reviewer agreement, which motivated this compound doc.
