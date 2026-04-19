#!/usr/bin/env bash
# rng.sh — Buddy plugin hatch roller
# Provides roll_rarity, roll_species, roll_stats, roll_name, roll_buddy, and
# next_pity_counter. Pure functions — no state reads or writes. Callers
# (P1-3's /buddy:hatch handler) are responsible for loading meta.pityCounter
# from buddy.json, passing it in, and writing the new counter back atomically.
#
# Public API:
#   roll_rarity <pity_counter>          → stdout: common|uncommon|rare|epic|legendary
#   roll_species                         → stdout: species name (filename sans .json)
#   roll_stats <rarity> <species>        → stdout: JSON {debugging, patience, chaos, wisdom, snark}
#   roll_name <species>                  → stdout: name string from species name_pool
#   roll_buddy <pity_counter>            → stdout: inner buddy JSON (id/name/species/rarity/shiny/stats/form/level/xp)
#   next_pity_counter <current> <rarity> → stdout: integer new pity value
#
# Testability:
#   BUDDY_RNG_SEED     — if set to a non-empty integer, _rng_int runs against a
#                        deterministic pure-bash LCG. When unset, uses $RANDOM.
#                        Lets distribution/pity tests pin outcomes on any bash 4.1+.
#   BUDDY_SPECIES_DIR  — overrides the default scripts/species/ location. Tests
#                        point this at a fixture dir to avoid mutating real data.
#
# NOTE: This library does NOT set `set -euo pipefail` at module scope. Doing so
# would pollute any hook script that sources this library and break the
# CLAUDE.md "hooks must exit 0" contract. Error handling is explicit per function.

# Require bash 4.1+ for the auto-fd-assignment exec syntax used elsewhere and
# for `declare -gA`. Matches state.sh's floor.
if [[ -z "${BASH_VERSINFO[0]:-}" ]] || (( BASH_VERSINFO[0] < 4 )) || \
   (( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 1 )); then
  echo "buddy-rng: requires bash 4.1+ (got ${BASH_VERSION:-unknown}). On macOS, install via: brew install bash" >&2
  return 1 2>/dev/null || exit 1
fi

# Guard against re-sourcing — readonly declarations, per-process caches, and
# the seed/LCG state all belong here. Anything that must survive re-source in
# the same process goes inside this block.
if [[ "${_RNG_SH_LOADED:-}" != "1" ]]; then
  _RNG_SH_LOADED=1

  # Pity threshold is a content decision, not a tunable. Matches umbrella plan D8.
  readonly PITY_THRESHOLD=10

  # Rarity thresholds, cumulative. _rng_int 1 100 <= 60 → common, <= 85 → uncommon, etc.
  # Changing the distribution is a one-line edit to these constants.
  readonly RARITY_CUT_COMMON=60
  readonly RARITY_CUT_UNCOMMON=85
  readonly RARITY_CUT_RARE=95
  readonly RARITY_CUT_EPIC=99
  # legendary = rest (100)

  # Under pity, forced Rare+ weights preserve the natural 10:4:1 ratio.
  # _rng_int 1 15: 1 → legendary, 2–5 → epic, 6–15 → rare.
  readonly PITY_WEIGHT_TOTAL=15
  readonly PITY_CUT_LEGENDARY=1
  readonly PITY_CUT_EPIC=5
  # rare = rest (15)

  # Rarity floors per tier. Remaining headroom filled with peak/dump/mid shape.
  declare -gA _RNG_FLOORS=(
    [common]=5
    [uncommon]=15
    [rare]=25
    [epic]=35
    [legendary]=50
  )

  # Stat-shape offsets relative to floor. Peak lands high (floor+40 to 100),
  # dump lands low (floor to floor+15), mids split the middle.
  readonly _RNG_PEAK_OFFSET_LO=40
  readonly _RNG_DUMP_OFFSET_HI=15
  readonly _RNG_MID_OFFSET_LO=15
  readonly _RNG_MID_OFFSET_HI=40

  # Slot-selection species-preference bias: 60% chance the peak/dump slot goes
  # to the species' peak-prefer/dump-prefer stat; otherwise uniform random.
  readonly _RNG_SPECIES_BIAS=60

  # Canonical stat order for output JSON. Stable for diff-ability.
  readonly -a _RNG_STATS=(debugging patience chaos wisdom snark)

  # LCG constants — Numerical Recipes' classic. Sufficient for a gacha; not
  # cryptographic. Kept inside the re-source guard so the state variable
  # (_RNG_LCG_STATE) survives re-sourcing within the same process.
  readonly _RNG_LCG_A=1664525
  readonly _RNG_LCG_C=1013904223
  readonly _RNG_LCG_M=4294967296   # 2^32

  # Per-process species JSON cache. Keyed by species name. Safe inside a single
  # rng.sh invocation — species files don't change mid-process.
  declare -gA _RNG_SPECIES_CACHE=()

  # Per-process flags
  _RNG_SEEDED=0
  _RNG_JQ_MISSING=0
  _RNG_LCG_STATE=0

  # Check jq presence once at source. Missing jq → every public function
  # short-circuits with an error, mirroring state.sh's log-and-return discipline.
  if ! command -v jq >/dev/null 2>&1; then
    _RNG_JQ_MISSING=1
    echo "buddy-rng: jq not found in PATH — rolls will fail" >&2
  fi
fi

# --- Internal helpers ---

_rng_log() {
  echo "buddy-rng: $*" >&2
}

# Validate species name against path-traversal and shell-injection.
# Allowed: letters, digits, hyphen, underscore. No slashes, no dots.
_rng_valid_species_name() {
  local name="$1"
  [[ -n "$name" && "$name" =~ ^[A-Za-z0-9_-]+$ ]]
}

# Resolve the species directory. Honors BUDDY_SPECIES_DIR override (for tests);
# otherwise walks up from rng.sh's own location to find scripts/species/.
_rng_species_dir() {
  if [[ -n "${BUDDY_SPECIES_DIR:-}" ]]; then
    printf '%s' "$BUDDY_SPECIES_DIR"
    return 0
  fi
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  # lib_dir is scripts/lib; walk up one to scripts/, then into species/
  printf '%s/../species' "$lib_dir"
}

# Lazy-seed the LCG from /dev/urandom or a fallback composite. Runs at most
# once per process (gated by _RNG_SEEDED). Callers that need deterministic
# sequences set BUDDY_RNG_SEED before the first _rng_int call.
_rng_seed() {
  if (( _RNG_SEEDED )); then
    return 0
  fi
  _RNG_SEEDED=1

  if [[ -n "${BUDDY_RNG_SEED:-}" && "${BUDDY_RNG_SEED}" =~ ^[0-9]+$ ]]; then
    _RNG_LCG_STATE=$(( BUDDY_RNG_SEED % _RNG_LCG_M ))
    return 0
  fi

  local seed=""
  if [[ -r /dev/urandom ]]; then
    seed="$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' \t\n')"
  fi

  if [[ -z "$seed" || ! "$seed" =~ ^[0-9]+$ ]]; then
    # Fallback composite: high-res time + pid + bashpid + a counter byte.
    # Single `date +%s` alone would collide on back-to-back invocations in the
    # same second. Composite diverges even on rapid hatches.
    local now="${EPOCHREALTIME:-}"
    [[ -z "$now" ]] && now="$(date +%s%N 2>/dev/null || date +%s)"
    now="${now//./}"
    seed="${now}${$}${BASHPID:-$$}"
    # Reduce to 32 bits via modulo
    seed=$(( ${seed: -10} % _RNG_LCG_M ))
    _rng_log "_rng_seed: /dev/urandom unavailable, using time+pid composite (weaker entropy)"
  fi

  _RNG_LCG_STATE=$(( seed % _RNG_LCG_M ))
}

# Return a random integer in [min, max], inclusive both ends.
# Uses the LCG when BUDDY_RNG_SEED is set (deterministic), otherwise $RANDOM.
# Modulo bias on range 1..100 against $RANDOM (span 32768) is ~0.3% per bucket,
# well within the ±2% distribution-test tolerance. For ranges > ~1000 this
# function would need rejection sampling — not currently needed.
_rng_int() {
  local min="$1"
  local max="$2"
  if ! [[ "$min" =~ ^-?[0-9]+$ && "$max" =~ ^-?[0-9]+$ ]]; then
    _rng_log "_rng_int: non-integer bounds ($min, $max)"
    return 1
  fi
  if (( min > max )); then
    _rng_log "_rng_int: inverted bounds ($min > $max)"
    return 1
  fi
  _rng_seed
  local range=$(( max - min + 1 ))
  local raw
  if [[ -n "${BUDDY_RNG_SEED:-}" ]]; then
    # LCG step: state = (a * state + c) mod m
    _RNG_LCG_STATE=$(( (_RNG_LCG_A * _RNG_LCG_STATE + _RNG_LCG_C) % _RNG_LCG_M ))
    raw=$_RNG_LCG_STATE
  else
    raw=$RANDOM
  fi
  printf '%d' $(( min + (raw % range) ))
}

# Guard used at the top of every public function: fail fast if jq is missing.
_rng_check_jq() {
  if (( _RNG_JQ_MISSING )); then
    _rng_log "$1: jq is not available"
    return 1
  fi
  return 0
}

# Placeholders — implemented in Units 3–6.
# They return non-zero so tests for later units fail loudly until implemented.
roll_rarity() {
  _rng_log "roll_rarity: not yet implemented (Unit 4)"
  return 2
}

roll_species() {
  _rng_log "roll_species: not yet implemented (Unit 3)"
  return 2
}

roll_stats() {
  _rng_log "roll_stats: not yet implemented (Unit 5)"
  return 2
}

roll_name() {
  _rng_log "roll_name: not yet implemented (Unit 3)"
  return 2
}

roll_buddy() {
  _rng_log "roll_buddy: not yet implemented (Unit 6)"
  return 2
}

next_pity_counter() {
  _rng_log "next_pity_counter: not yet implemented (Unit 4)"
  return 2
}
