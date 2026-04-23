---
title: "`declare -gA` when a bash library is sourced from inside a function"
date: 2026-04-23
category: best-practices
module: scripts/lib
problem_type: best_practice
component: tooling
severity: high
applies_when:
  - Writing a bash library that declares module-level associative/indexed arrays
  - Any library that is sourced from a function (bats `setup()`, `setup_file()`, or a wrapper function in another script)
  - Any library that uses `declare -A name=(...)` at what looks like "file scope"
tags:
  - bash
  - declare
  - source
  - function-scope
  - associative-array
  - bats
  - gotcha
  - claude-code-plugin
---

# `declare -gA` when a bash library is sourced from inside a function

## Context

While building `scripts/lib/render.sh` for the P4-3 "visible buddy" feature, a
bats test that called `render_rarity_color_open common` kept returning an empty
string. The function's code was correct — `printf '%s' "${_RENDER_RARITY_COLOR[$rarity]:-}"`
— and interactive shell testing worked fine. But when the test file sourced
`render.sh` inside `setup()`, every test that touched the associative color map
silently saw an empty array, producing no output and triggering the `:-` default.

The gotcha: **when you source a bash file from inside a function, any `declare -A`
or `declare -a` in that file becomes local to the calling function.** The array
still gets declared, but it vanishes the moment `setup()` returns. The library's
function (defined at file scope) then tries to read a global that no longer exists.

This is documented in the bash manual's `declare` entry — "When used in a function,
declare and typeset make each name local, as with the local command, unless the
-g option is used" — but easy to miss because:

1. The declaration **looks** like it's at file scope (no enclosing function in the library).
2. Most test-helper patterns (bats `setup()`, rspec-style wrappers, fixture helpers) hide the fact that the source is happening inside a function.
3. The failure is silent — functions still return 0, `$output` is just empty, and the `:-` default hides the missing key.

## Guidance

**Any module-level array in a bash library must be declared with `-g`:**

```bash
declare -gA _MY_COLOR_MAP=(
  [common]=$'\033[90m'
  [rare]=$'\033[94m'
  ...
)

declare -ga _MY_PALETTE=(
  $'\033[91m'
  $'\033[93m'
  ...
)
```

Apply this unconditionally to libraries that will ever be sourced from a test
helper or another script's function. Scalars assigned with plain `VAR=value`
are unaffected (they become environment-like globals by default); only
`declare` / `typeset` / `local` care about this.

For a library that should survive being sourced repeatedly (common pattern —
a source-guard using `_LIB_LOADED=1`), put the `declare -g` inside the guard
block:

```bash
if [[ "${_MYLIB_LOADED:-}" != "1" ]]; then
  _MYLIB_LOADED=1

  declare -gA _MY_COLOR_MAP=(...)
  declare -ga _MY_PALETTE=(...)
  readonly _MY_RESET=$'\033[0m'
fi
```

## Why This Matters

Without `-g`, the failure is silent:

- The library sources cleanly (no error, no warning).
- The library's public functions are defined at the right scope (file scope, global).
- The functions read from the array via `${arr[$key]:-}` which returns empty for a missing key.
- All tests pass the "function exists and returns 0" check.
- Behavior-asserting tests (`[ "$output" = $'\033[94m' ]`) fail, but the error message gives you no clue why — the array is just empty.

Debug path that works: run `declare -p _MY_COLOR_MAP` inside the test to see
whether the array exists in scope. If bash reports `declare: _MY_COLOR_MAP:
not found`, you've hit this.

Debug path that doesn't work: running the library via `bash -c 'source lib && ...'`
(looks correct because `source` is at top level there), interactive shell
(ditto), or `bats` without tracing into the setup. They all make the problem
vanish because they don't involve a sourcing function.

## When to Apply

- Any bash library that declares state at what looks like module scope.
- Any bash library that will be loaded by bats tests — bats always calls
  `setup()` or `setup_file()` as a function, so library sources inside those
  are function-scoped unless you opt into `-g`.
- Any bash library loaded from a wrapper like `bash <(cat setup.sh lib.sh)` or
  a dispatch script that sources inside its own function.

Safe to skip: small scripts that define all state and functions in the same
file with no anticipation of being sourced. If it's only ever executed, not
sourced, `declare -A` is fine.

## Examples

**Broken (silent failure when sourced from `setup()`):**

```bash
# lib/render.sh
declare -A _COLORS=( [red]=$'\033[31m' [green]=$'\033[32m' )
color_for() { printf '%s' "${_COLORS[$1]:-}"; }
```

```bash
# tests/test_render.bats
setup() {
  source "$REPO_ROOT/lib/render.sh"
}
@test "red" {
  run color_for red
  [ "$output" = $'\033[31m' ]   # FAILS: output is empty
}
```

**Fixed:**

```bash
# lib/render.sh
declare -gA _COLORS=( [red]=$'\033[31m' [green]=$'\033[32m' )
color_for() { printf '%s' "${_COLORS[$1]:-}"; }
```

Same test now passes — the array is a true global and survives `setup()` returning.

## See Also

- `scripts/lib/render.sh` — the P4-3 library where this was debugged.
- bash manual, `declare` section: "When used in a function, declare and typeset
  make each name local."
- Related plugin library: `scripts/lib/state.sh` — uses plain readonly scalars
  (no arrays) and escapes this entirely; read alongside as a contrast.
