---
title: Bash LCG and hot-path performance patterns for Claude Code plugins
date: 2026-04-19
category: best-practices
module: scripts/lib/rng.sh
problem_type: best_practice
component: tooling
severity: medium
applies_when:
  - Implementing a pure-bash LCG with a power-of-two modulus (e.g. Numerical Recipes constants) where small-range modulo feeds into a sampling decision
  - Writing bash library hot paths called in tight bats loops or production hook scripts subject to a p95 < 100 ms budget
  - Building per-species / per-config JSON lookup in a bash library where jq-per-call would dominate wall time
  - Emitting fixed-schema JSON (integers, booleans, enum literals) from a function called thousands of times
  - Using test-seam env vars (`BUDDY_SPECIES_DIR` etc.) that can change the data source within a single process lifetime
tags:
  - bash
  - rng
  - lcg
  - performance
  - jq
  - claude-code-plugin
  - caching
  - hot-path
---

# Bash LCG and hot-path performance patterns for Claude Code plugins

## Context

During P1-2 (the buddy hatch roller), `scripts/lib/rng.sh` was built around a seeded linear congruential generator so that bats tests could pin distribution outcomes deterministically. Two separate failures emerged during implementation, each requiring a mid-stream refactor. The first was a catastrophic distribution-test result — 10,000 rolls in one rarity bucket — caused by using low-order bits of a Numerical Recipes LCG for modulo operations. The second, a subshell state-loss issue, is covered in the sibling doc [bash-subshell-state-patterns-2026-04-19.md](./bash-subshell-state-patterns-2026-04-19.md) and is not repeated here.

After the first green test run, wall time for the test suite was ~10 minutes. Profiling identified jq process spawns as the dominant cost: each spawn is ~20 ms, and the stat-rolling hot path called jq three times per roll. The refactor that followed — per-process `declare -gA` caches with centralized invalidation, `printf` JSON assembly for fixed integer schemas, and `mapfile` splitting of cached name pools — cut wall time to ~2:25. These patterns generalize to any bash library where hook scripts must meet a tight latency budget under realistic call volumes.

**Scope clarification:** This guidance applies to tight loops and test helpers where jq spawn cost dominates. It does NOT contradict [bash-state-library-patterns-2026-04-18.md](./bash-state-library-patterns-2026-04-18.md)'s use of jq for schema migration, schemaVersion stamping, and other infrequent structured operations on `state.sh`. Those are correct uses of jq in their context and should not be changed.

## Guidance

### A. Numerical Recipes LCG low-bit pitfall

The Numerical Recipes LCG uses constants `a=1664525`, `c=1013904223`, `m=2^32`:

```
state = (1664525 * state + 1013904223) % 4294967296
```

The low-order bit of this sequence has period 2 — it alternates 0, 1, 0, 1. For any LCG with modulus `2^k`, the low `j` bits form a period-`2^j` sub-LCG. At `m = 2^32`: bit 0 has period 2, bit 1 has period 4, bit 2 has period 8, and so on. Using `state % 100` pulls directly from these short-period low bits — the result is deeply non-uniform.

**Before (broken distribution):**

```bash
_RNG_LCG_STATE=$(( (_RNG_LCG_A * _RNG_LCG_STATE + _RNG_LCG_C) % _RNG_LCG_M ))
raw=$_RNG_LCG_STATE
_RNG_RESULT=$(( min + (raw % range) ))
# Distribution test, seed 42, 10,000 rolls, range 1..100:
#   common=0 (every roll fell in the uncommon band)
```

**After (uniform distribution):**

```bash
_RNG_LCG_STATE=$(( (_RNG_LCG_A * _RNG_LCG_STATE + _RNG_LCG_C) % _RNG_LCG_M ))
# High 16 bits have full period and pass uniformity for small ranges.
raw=$(( _RNG_LCG_STATE >> 16 ))
_RNG_RESULT=$(( min + (raw % range) ))
# Distribution test, seed 42, 10,000 rolls, range 1..100:
#   ~6000 common, ~2500 uncommon, ~1000 rare, ~400 epic, ~100 legendary
```

This applies to **any** LCG where the modulus is `2^k`, regardless of specific constants. Shifting right 16 produces 16 bits of output from a 32-bit state. That is sufficient for ranges up to ~1000 (15-bit-plus max value = 65535, worst-case modulo bias ~0.3% at range=100). If the roll range grows past ~1000, the modulo bias becomes material — switch to rejection sampling or a stronger generator at that point.

**Diagnostic signal:** if a seeded distribution test returns all-or-nothing bucket counts (every roll in one bucket, or an impossibly precise ratio that moves in lockstep with seed changes), suspect low-bit modulo before suspecting the LCG constants or the seed itself.

### B. Per-process caches for hot-path jq

A jq process spawn costs ~20 ms. A test loop calling `roll_stats` 1000 times, with three jq calls per invocation (species data, peak-prefer, dump-prefer), accumulates 60 seconds of jq overhead on its own. The fix: load species data once per species per process and cache it in `declare -gA` associative arrays.

**The cache declarations (inside the re-source sentinel):**

```bash
# Declared inside the re-source guard — initialized once per process,
# preserved across repeated `source` calls from the same shell.
if [[ "${_RNG_SH_LOADED:-}" != "1" ]]; then
  _RNG_SH_LOADED=1

  declare -gA _RNG_SPECIES_CACHE=()   # full JSON per species
  declare -gA _RNG_SPECIES_PEAK=()    # peak-prefer stat name per species
  declare -gA _RNG_SPECIES_DUMP=()    # dump-prefer stat name per species
  declare -gA _RNG_SPECIES_NAMES=()   # name_pool as newline-separated string
  declare -ga _RNG_SPECIES_LIST=()    # indexed array of all species names
  _RNG_CACHED_DIR=""                  # dir the caches were populated from
fi
```

**Lazy population (one jq call per species per process):**

```bash
_rng_load_species() {
  local species="$1"
  if [[ -n "${_RNG_SPECIES_CACHE[$species]:-}" ]]; then
    printf '%s' "${_RNG_SPECIES_CACHE[$species]}"   # cache hit: zero spawns
    return 0
  fi
  local json
  json="$(jq -c '.' "$dir/$species.json" 2>/dev/null)" || return 1
  _RNG_SPECIES_CACHE[$species]="$json"
  printf '%s' "$json"
}
```

**Centralized invalidation when a test seam changes mid-process:**

Tests swap `BUDDY_SPECIES_DIR` between fixture directories to verify edge cases. Without invalidation, the second fixture reads stale entries from the first. The right place to detect this is at the dir-resolution seam:

```bash
_rng_check_dir_change() {
  local dir
  dir="$(_rng_species_dir)" || return 1
  if [[ "${_RNG_CACHED_DIR:-}" != "$dir" ]]; then
    _RNG_CACHED_DIR="$dir"
    _RNG_SPECIES_CACHE=()
    _RNG_SPECIES_PEAK=()
    _RNG_SPECIES_DUMP=()
    _RNG_SPECIES_NAMES=()
    _RNG_SPECIES_LIST=()
  fi
  return 0
}
```

Every public function that reads species data calls `_rng_check_dir_change` first. All caches are invalidated **together** — partial invalidation would leave inconsistent cross-references (a stale peak-prefer from fixture A alongside a fresh JSON body from fixture B). The single invalidation seam makes cache coherency an always-true property rather than a per-cache discipline.

### C. printf JSON assembly for fixed-schema hot paths

jq is the right tool for assembling JSON when string fields could contain metacharacters (quotes, backslashes, control characters). It is the wrong tool when every field is a validated integer and the schema is fixed.

**When printf is safe — validated integers, fixed schema:**

```bash
# roll_stats: all five values went through _rng_int (integer arithmetic only).
# Direct printf avoids a jq spawn on the hottest path — tests loop thousands
# of times through roll_stats.
printf -v _RNG_ROLL '{"debugging":%d,"patience":%d,"chaos":%d,"wisdom":%d,"snark":%d}' \
  "${stat_values[debugging]}" "${stat_values[patience]}" "${stat_values[chaos]}" \
  "${stat_values[wisdom]}" "${stat_values[snark]}"
```

**Before (jq on every call):**

```bash
# BAD — spawns jq for each of thousands of stat rolls in tests.
_RNG_ROLL="$(jq -n \
  --argjson d "${stat_values[debugging]}" \
  --argjson p "${stat_values[patience]}" \
  ... \
  '{debugging:$d, patience:$p, ...}')"
```

**When to stay on jq — any string field:**

`roll_buddy`'s final assembly uses jq because its output includes `name` (freeform string from the species name pool) and `species` (a filename). Manual escaping of JSON metacharacters in bash is fragile; jq's `--arg` handles it correctly:

```bash
# roll_buddy stays on jq because name and species are strings that could
# theoretically contain problematic characters.
_RNG_ROLL="$(jq -n -c \
  --arg id "$id" \
  --arg name "$name" \
  --arg species "$species" \
  --arg rarity "$rarity" \
  --argjson stats "$stats_json" \
  '{id:$id, name:$name, species:$species, rarity:$rarity,
    shiny:false, stats:$stats, form:"base", level:1, xp:0}')"
```

**Decision rule:** if every value going into the JSON is a validated integer, boolean, or fixed enum string, `printf` is safe and faster. If any value is a string that was not produced entirely by your own code using only known-safe characters, use jq.

### D. mapfile for cached-array splitting

Storing an array as a newline-separated string in an associative cache, then splitting it with `mapfile`, costs zero process forks. Calling `jq -r '.array[N]'` per element costs one jq spawn per element.

**The pattern:**

```bash
# Load time: one jq call per species, ever. Filter edge cases here
# (null, empty) so callers never see the literal string "null" leak through
# from jq's raw output mode.
_rng_load_species_names() {
  local species="$1"
  [[ -v _RNG_SPECIES_NAMES[$species] ]] && return 0   # already cached
  local json
  json="$(_rng_load_species "$species")" || return 1
  _RNG_SPECIES_NAMES[$species]="$(printf '%s' "$json" | \
    jq -r '.name_pool[] | select(. != null and . != "")' 2>/dev/null)"
}

# Use time: bash builtin, no fork.
roll_name() {
  _rng_load_species_names "$species" || return 1
  local -a names
  mapfile -t names <<< "${_RNG_SPECIES_NAMES[$species]}"
  local count="${#names[@]}"
  _rng_int 1 "$count" >/dev/null || return 1
  _RNG_ROLL="${names[$((_RNG_RESULT - 1))]}"
  printf '%s' "$_RNG_ROLL"
}
```

Edge-case filtering (null, empty) runs at cache-load time, once per species per process. After warm-up, `roll_name` spawns zero processes.

## Why This Matters

- Hook scripts in Claude Code plugins target p95 < 100 ms per invocation (CLAUDE.md constraint). jq at ~20 ms per spawn means five jq calls per roll consumes the entire budget before any real logic runs. The combined patterns here drop a cold `roll_buddy` from ~100 ms critical path to ~60 ms, and warm `roll_name` / `roll_stats` to essentially zero-fork paths.
- Empirical impact: `tests/rng.bats` wall time went from ~10 minutes to ~2:25 (a 4× improvement) after the caching + printf + mapfile refactor. Four minutes of that gain came from jq elimination; the rest came from right-sizing test volumes to match statistical needs.
- The LCG low-bit bug is **invisible without a distribution test**. Every individual roll looks plausible, the arithmetic is correct, and the seed is being consumed — only a statistical test over a large sample catches the non-uniformity. Without the distribution test this would have shipped silently and broken any future gameplay-balance tuning.
- Cache-invalidation coherency (all-or-nothing flush on seam change) prevents a class of subtle test bugs where one fixture leaks into another. It is cheaper to implement once than to diagnose once.

## When to Apply

- **Every time** you implement a pure-bash LCG with a power-of-two modulus — high-bit extraction is a prerequisite, not an optimization.
- Any bash library function called in a tight loop (bats test or production hook) that currently spawns jq per call.
- Any bash hook script reading per-species or per-config JSON: cache on first read, invalidate on known seam changes, never re-parse on repeated calls in the same process.
- Any function assembling a JSON object from values that are validated integers, booleans, or enum literals — prefer `printf '%d' / '%s'` over jq.
- Any function iterating over a cached list of strings — store as newline-separated, split with `mapfile -t`, skip jq index calls entirely.

## Examples

### LCG: before and after high-bit extraction

```bash
# BEFORE — low bits have short period; small-range modulo is non-uniform.
_RNG_LCG_STATE=$(( (_RNG_LCG_A * _RNG_LCG_STATE + _RNG_LCG_C) % _RNG_LCG_M ))
raw=$_RNG_LCG_STATE
_RNG_RESULT=$(( min + (raw % range) ))
# 10,000 rolls at range 1..100: every result in the same band.

# AFTER — shift right 16 to use the high bits (full period for small ranges).
_RNG_LCG_STATE=$(( (_RNG_LCG_A * _RNG_LCG_STATE + _RNG_LCG_C) % _RNG_LCG_M ))
raw=$(( _RNG_LCG_STATE >> 16 ))
_RNG_RESULT=$(( min + (raw % range) ))
# 10,000 rolls at range 1..100: distribution matches 60/25/10/4/1 within ±2%.
```

### Per-process cache: before vs after

```bash
# BEFORE — one jq spawn per roll_stats call (3 per roll).
roll_stats() {
  local peak
  peak="$(jq -r '.base_stats_weights | to_entries
    | map(select(.value == "peak-prefer"))[0].key' "$species_file")"
  local dump
  dump="$(jq -r '.base_stats_weights | to_entries
    | map(select(.value == "dump-prefer"))[0].key' "$species_file")"
  ...
}

# AFTER — one jq spawn per species per process; O(1) on warm cache.
_rng_load_species_weights() {
  local species="$1"
  if [[ -n "${_RNG_SPECIES_PEAK[$species]:-}" ]]; then
    _RNG_STAT_PEAK="${_RNG_SPECIES_PEAK[$species]}"
    _RNG_STAT_DUMP="${_RNG_SPECIES_DUMP[$species]}"
    return 0
  fi
  local json both
  json="$(_rng_load_species "$species")" || return 1
  # Single jq invocation extracts both fields as "peak\tdump".
  both="$(printf '%s' "$json" | jq -r '
    (.base_stats_weights | to_entries | map(select(.value == "peak-prefer"))[0].key)
    + "\t" +
    (.base_stats_weights | to_entries | map(select(.value == "dump-prefer"))[0].key)
  ')"
  _RNG_SPECIES_PEAK[$species]="${both%$'\t'*}"
  _RNG_SPECIES_DUMP[$species]="${both#*$'\t'}"
  _RNG_STAT_PEAK="${_RNG_SPECIES_PEAK[$species]}"
  _RNG_STAT_DUMP="${_RNG_SPECIES_DUMP[$species]}"
}
```

Note: even the cache-miss path runs jq exactly once and pulls both fields via tab-separated output.

### printf JSON: before vs after

```bash
# BEFORE — spawns jq for every roll_stats call.
_RNG_ROLL="$(jq -n \
  --argjson debugging "${stat_values[debugging]}" \
  --argjson patience  "${stat_values[patience]}" \
  --argjson chaos     "${stat_values[chaos]}" \
  --argjson wisdom    "${stat_values[wisdom]}" \
  --argjson snark     "${stat_values[snark]}" \
  '{debugging:$debugging,patience:$patience,chaos:$chaos,wisdom:$wisdom,snark:$snark}')"

# AFTER — zero process spawns; values are validated integers.
printf -v _RNG_ROLL '{"debugging":%d,"patience":%d,"chaos":%d,"wisdom":%d,"snark":%d}' \
  "${stat_values[debugging]}" "${stat_values[patience]}" "${stat_values[chaos]}" \
  "${stat_values[wisdom]}" "${stat_values[snark]}"
```

### mapfile: before vs after

```bash
# BEFORE — jq spawn per roll_name call.
roll_name() {
  local count
  count="$(jq '.name_pool | length' "$species_file")"
  _rng_int 1 "$count" >/dev/null || return 1
  _RNG_ROLL="$(jq -r ".name_pool[$((_RNG_RESULT - 1))]" "$species_file")"
}

# AFTER — warm cache: zero process spawns; mapfile is a bash builtin.
roll_name() {
  _rng_load_species_names "$species" || return 1   # jq once per species, ever
  local -a names
  mapfile -t names <<< "${_RNG_SPECIES_NAMES[$species]}"
  _rng_int 1 "${#names[@]}" >/dev/null || return 1
  _RNG_ROLL="${names[$((_RNG_RESULT - 1))]}"
  printf '%s' "$_RNG_ROLL"
}
```

## Related

- [bash-state-library-patterns-2026-04-18.md](./bash-state-library-patterns-2026-04-18.md) — structural conventions `rng.sh` inherits: no module-scope `set -e`, bash 4.1+ guard, re-source sentinel, `declare -gA` for per-process accumulators, explicit per-function error handling. That doc's jq usage is for infrequent schema operations and is not in tension with this doc's hot-path guidance.
- [bash-subshell-state-patterns-2026-04-19.md](./bash-subshell-state-patterns-2026-04-19.md) — the complementary runtime pattern: why `$()` wipes LCG state and how the `>/dev/null; val=$_RNG_RESULT` idiom preserves it. **Do not conflate the two**: the LCG low-bit issue (this doc) and the subshell issue (sibling doc) produce superficially identical test failures (stuck distribution) but have independent root causes and fixes.
- [scripts/lib/rng.sh](../../../scripts/lib/rng.sh) — reference implementation. High-bit extraction in `_rng_int`; `_rng_check_dir_change` invalidator; `_rng_load_species_weights` cache pattern; `roll_stats` printf assembly; `_rng_load_species_names` + `roll_name` mapfile pattern.
- [tests/rng.bats](../../../tests/rng.bats) — the empirical benchmark: 61 tests, ~2:25 wall time. The distribution test (seed-pinned, 10,000 rolls) and the stat floor test (25 × 20 rolls with caching) are the primary hot-path exercisers.
- [P1-2 plan](../../plans/2026-04-18-001-feat-p1-2-hatch-roller-plan.md) — the plan document that led to rng.sh. The perf refactor (commit `663c59c`) and the gated_auto fixes from `/ce:review` (commit `63c2c4f`) produced the final shape of these patterns.
- [P1-2 ticket](../../roadmap/P1-2-hatch-roller.md) — Implementation Notes section for additional context on the gotchas surfaced during implementation.
