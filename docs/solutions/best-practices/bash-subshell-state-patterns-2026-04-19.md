---
title: Bash subshell state patterns for stateful library functions
date: 2026-04-19
category: best-practices
module: scripts/lib/rng.sh
problem_type: best_practice
component: tooling
severity: high
applies_when:
  - Writing any bash library function that maintains state across calls (counters, caches, PRNG sequences, pagination cursors)
  - Writing bats tests that loop over a stateful function and expect deterministic behaviour
  - Reviewing code that captures function output via command substitution `$(...)` where the function is also meant to advance internal state
tags:
  - bash
  - subshell
  - command-substitution
  - state-management
  - deterministic-rng
  - claude-code-plugin
  - testing
---

# Bash subshell state patterns for stateful library functions

## Context

`scripts/lib/rng.sh` ships a seeded linear congruential generator (LCG) keyed on `BUDDY_RNG_SEED` so that bats tests can pin distribution outcomes without depending on `/dev/urandom` or platform `$RANDOM` entropy. The LCG is stateful: each call to `_rng_int` mutates `_RNG_LCG_STATE`, so the next call produces the next value in the deterministic sequence.

The first working implementation looked natural:

```bash
_RNG_LCG_STATE=0

_rng_int() {
  _RNG_LCG_STATE=$(( (1664525 * _RNG_LCG_STATE + 1013904223) % 4294967296 ))
  printf '%d' "$_RNG_LCG_STATE"
}

# Caller
val=$(_rng_int)
```

The distribution test rolled 10,000 rarities and expected 60/25/10/4/1. Running it with `BUDDY_RNG_SEED=42` produced `common=0` — every single roll came out in the Uncommon/Rare band. Changing the LCG constants produced `common=10000` — every roll fell in Common.

The output **was** deterministic; it just was not advancing. Every call produced the same value.

## Guidance

### A. The failure mode

`$(...)` command substitution forks a subshell. The subshell is a full copy-on-write process image of the parent, so it can read parent variables but **cannot write back to them**. Any mutation of `_RNG_LCG_STATE` inside the subshell is discarded when the subshell exits.

A test that loops with `r=$(_rng_int 1 100)` therefore:

1. Forks subshell 1. Seeds LCG to 42 (lazy init). Advances state. Echoes value. Subshell exits. Parent's `_RNG_LCG_STATE` is still its pre-fork value.
2. Forks subshell 2. Sees the same pre-fork state as subshell 1. Advances. Echoes the same value.
3. Repeats forever. 10,000 rolls produce 10,000 identical outputs.

The test output showed `common=0` because the fixed seed happened to land in the uncommon band (`raw % 100 == 73` initially, later `37` after we swapped to high-bit extraction — a separate correctness fix documented in [bash-lcg-hotpath-patterns-2026-04-19.md](./bash-lcg-hotpath-patterns-2026-04-19.md), since Numerical Recipes LCG low bits have too short a period for small-range modulo). Either way, the distribution contract was broken because the library was stuck on one value.

### B. The correct pattern: result-via-global

Write the result to a global variable in the parent shell and redirect stdout. This avoids command substitution entirely:

```bash
_RNG_LCG_STATE=0
_RNG_RESULT=0

_rng_int() {
  _RNG_LCG_STATE=$(( (1664525 * _RNG_LCG_STATE + 1013904223) % 4294967296 ))
  _RNG_RESULT=$_RNG_LCG_STATE
  printf '%d' "$_RNG_RESULT"   # stdout kept for ad-hoc interactive use
}

# Caller (state-preserving)
_rng_int >/dev/null
val=$_RNG_RESULT
```

No subshell is forked. `_RNG_LCG_STATE` advances in the parent shell, so the next call sees the new state. Deterministic sequences now work.

The `printf` to stdout is retained only so that one-off interactive use (`_rng_int 1 100` at a terminal) still prints a value. Any caller that needs state persistence across multiple calls **must** use the `>/dev/null; val=$_RNG_RESULT` form.

### C. Apply this pattern transitively to every consumer

A function that maintains state loses that state whenever it is reached through a subshell boundary. Every caller in the chain must use the no-subshell pattern:

```bash
# BAD — roll_rarity internally calls _rng_int via $(..), so even if roll_rarity
# itself uses _RNG_RESULT, the subshell boundary inside it resets the LCG.
roll_rarity() {
  local r
  r=$(_rng_int 1 100)   # subshell — state lost
  ...
}

# GOOD — _rng_int's state persists because the caller stays in the same shell.
roll_rarity() {
  _rng_int 1 100 >/dev/null
  local r=$_RNG_RESULT
  ...
}
```

In `rng.sh`, every internal `_rng_int` call and every public `roll_*` call uses the no-subshell pattern. Public functions additionally expose `_RNG_ROLL` as their result global so tests can loop without losing state:

```bash
# In the test
for (( i = 0; i < 10000; i++ )); do
  roll_rarity 0 >/dev/null
  counts[$_RNG_ROLL]=$(( ${counts[$_RNG_ROLL]:-0} + 1 ))
done
```

### D. Document the contract at every public function

The pattern is not discoverable from a function signature. A caller reading `roll_rarity <pity_counter>` in a README has no structural hint that `$()` is unsafe. The only line of defence is documentation at the function boundary.

In `rng.sh` the `_rng_int` docstring explicitly walks through both forms:

```bash
# IMPORTANT: bash `$(..)` command substitution forks a subshell, which means
# any state changes inside the subshell — including LCG advancement — are lost
# when the subshell exits. For deterministic sequences via BUDDY_RNG_SEED, the
# caller MUST use the no-subshell pattern:
#     _rng_int 1 100; val=$_RNG_RESULT     ← state persists; deterministic
#     val=$(_rng_int 1 100)                 ← state resets each call; only first deterministic
```

Writers of new stateful bash libraries should put an equivalent block at the top of their library file and at the top of every public stateful function. Review checklists should flag any `val=$(stateful_fn ...)` pattern in call sites.

### E. Production vs. test boundary

In production, `rng.sh` is sourced once per hatch and each public function is called at most a handful of times in the same process. If a production caller used `$(roll_rarity 0)` it would still produce a correct value, because:

- `$RANDOM` is the production entropy source (no deterministic seed set), and
- A single `$RANDOM` draw inside a subshell still produces a kernel-seeded random value

Determinism is only a test concern. But the API must be consistent: callers that work correctly in tests must also work correctly in production. The right default is always the no-subshell pattern; `$()` is a shortcut that happens to be safe in some cases but is never required.

### F. What does not work

Three failed alternatives I considered before landing on the global-variable pattern:

1. **Re-seed from a shared seed + counter file.** Persist the LCG state in a tempfile and have each `_rng_int` invocation read, mutate, and rewrite it. Subshells can write to disk. **Rejected**: file I/O on every RNG call is ~10x slower than the no-subshell pattern, and it introduces locking concerns under concurrent tests.

2. **Derive each roll from seed + call-counter, no state at all.** Make the LCG stateless: `roll_k(seed, k) = seed_advance(seed, k)`. The caller tracks `k`. **Rejected**: pushes complexity onto every caller, and the call counter becomes a de-facto state variable that lives in the caller, so the subshell problem reappears one level up.

3. **Use bash namerefs (`declare -n`) to return by reference.** bash 4.3+ supports `declare -n result=$1` so `fn out_var` can write to a caller-named variable. Works, but requires every caller to pass an out-variable name and the namerefs do not survive subshell boundaries any better than plain globals. **Rejected**: cognitive overhead without a correctness benefit.

The global-result pattern is the simplest correct answer, and it is the same shape as C's `out` parameters — a well-understood idiom.

## Why This Matters

Empirically verified — this pattern was discovered during P1-2 implementation after a distribution test failed catastrophically. The fix was a mid-implementation refactor that touched every internal call site and the test helper. Catching it in review instead of in production saved:

- A confusing class of test failures in P1-3 (hatch wiring) that would have pinned `BUDDY_RNG_SEED` and seen "wrong distribution" despite correct math in every individual function.
- A harder-to-diagnose class of production near-misses where `$RANDOM` produces distinct values in each subshell, so things look fine — until a future maintainer tries to add a determinism feature and the whole call chain has to be refactored.
- A regression surface for any future bash library in the plugin. The fix pattern is now reusable; the trap is now named.

This also generalizes beyond RNG. Any bash library that accumulates state across calls — a cache that grows, a pagination cursor, a retry counter, a rate-limit window — has the same failure mode when called via `$()`. The naming convention (`_LIB_RESULT` for primitives, `_LIB_ROLL` / `_LIB_OUTPUT` for high-level returns) can be reused directly.

## When to Apply

- Writing any stateful bash function: counter increments, cache writes, PRNG advancement, pagination, retry tracking, lock management.
- Reviewing a bats test that loops over a library function and expects distribution, sequence, or rate-limit properties.
- Adding a new public API to an existing stateful bash library: follow the dual-output convention (`_RNG_RESULT` for internal primitives, `_RNG_ROLL` for public returns) and document the no-subshell requirement at the function docstring.
- Onboarding: if a new contributor files a bug report along the lines of "the RNG keeps producing the same value in my test," this pattern is almost always the cause.

## Examples

### Deterministic loop (state-preserving pattern)

```bash
# From tests/rng.bats — 10,000-roll distribution test
export BUDDY_RNG_SEED=42
source "$RNG_LIB"
declare -A counts=()
for (( i = 0; i < 10000; i++ )); do
  roll_rarity 0 >/dev/null           # state persists in current shell
  counts[$_RNG_ROLL]=$(( ${counts[$_RNG_ROLL]:-0} + 1 ))
done
# Distribution test passes: ~6000 common, ~2500 uncommon, ~1000 rare, etc.
```

### Broken loop (subshell resets state)

```bash
# Do not do this — every call resets the LCG to the seed's first value.
for (( i = 0; i < 10000; i++ )); do
  r=$(roll_rarity 0)                  # subshell — state lost after each call
  counts[$r]=$(( ${counts[$r]:-0} + 1 ))
done
# counts is: { common: 0, uncommon: 10000, rare: 0, epic: 0, legendary: 0 }
# or { common: 10000, ... } depending on where the fixed first value lands.
```

### Chain of stateful calls

```bash
# roll_buddy calls four stateful functions. Each must stay in the current shell.
roll_buddy() {
  roll_rarity "$pity" >/dev/null || return 1
  local rarity=$_RNG_ROLL

  roll_species >/dev/null || return 1
  local species=$_RNG_ROLL

  roll_stats "$rarity" "$species" >/dev/null || return 1
  local stats_json=$_RNG_ROLL

  roll_name "$species" >/dev/null || return 1
  local name=$_RNG_ROLL
  ...
}
```

## Related

- [bash-lcg-hotpath-patterns-2026-04-19.md](./bash-lcg-hotpath-patterns-2026-04-19.md) — the sibling correctness and performance story. The same test failure (all rolls in one rarity band) can come from either a subshell wiping LCG state (this doc) OR from LCG low-bit non-uniformity (that doc). Both were in play during P1-2 implementation; diagnosing each one required treating it as a separate bug with an independent fix.
- [bash-state-library-patterns-2026-04-18.md](./bash-state-library-patterns-2026-04-18.md) — structural conventions that `rng.sh` inherits (no module-scope `set -e`, bash 4.1+ guard, re-source sentinel, `declare -gA` for caches, explicit per-function error handling, bats `--separate-stderr` discipline). This pattern is a runtime sibling to those structural conventions.
- [P1-2 plan](../../plans/2026-04-18-001-feat-p1-2-hatch-roller-plan.md) — the plan document that specified `BUDDY_RNG_SEED` as a test seam. The subshell pattern was not anticipated in the plan; it was discovered during implementation and refactored in commit `2af6b1f`.
- [P1-2 ticket](../../roadmap/P1-2-hatch-roller.md) — Implementation Notes section flags the subshell gotcha as a `/ce:compound` candidate. This document is the fulfilment of that note.
- [scripts/lib/rng.sh](../../../scripts/lib/rng.sh) — the reference implementation. See `_rng_int`'s header comment for the in-file statement of the pattern.
- [tests/rng.bats](../../../tests/rng.bats) — 61 tests, of which the distribution test (line 337), pity tests (379-420), species bias tests (548, 563), and stat floor test (450) all exercise the no-subshell pattern under `BUDDY_RNG_SEED`.
