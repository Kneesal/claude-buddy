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

  # Stat-shape offsets relative to floor. Ranges are disjoint so peak/dump/mid
  # counts are unambiguous: dump [floor, floor+14], mid [floor+15, floor+40],
  # peak [floor+41, 100]. At legendary floor=50: dump [50,64], mid [65,90], peak [91,100].
  readonly _RNG_PEAK_OFFSET_LO=41
  readonly _RNG_DUMP_OFFSET_HI=14
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

  # Globals used by the no-subshell API (see _rng_int docstring).
  # _rng_int sets _RNG_RESULT; public roll_* functions set _RNG_ROLL for
  # callers that want state persistence via the no-subshell pattern.
  _RNG_RESULT=0
  _RNG_ROLL=""

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

# Generate a random integer in [min, max], inclusive both ends.
# Writes the result to the global _RNG_RESULT and echoes it to stdout.
#
# IMPORTANT: bash `$(..)` command substitution forks a subshell, which means
# any state changes inside the subshell — including LCG advancement — are lost
# when the subshell exits. For deterministic sequences via BUDDY_RNG_SEED, the
# caller MUST use the no-subshell pattern:
#     _rng_int 1 100; val=$_RNG_RESULT     ← state persists; deterministic
#     val=$(_rng_int 1 100)                 ← state resets each call; only first deterministic
#
# This pattern is used by every internal _rng_int consumer (roll_rarity,
# roll_stats, roll_species, roll_name, roll_buddy). The stdout echo exists
# only for ad-hoc interactive use where determinism doesn't matter.
#
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
    # Numerical Recipes LCG has short-period low-order bits; shift right 16 to
    # use the high bits, which have full period and pass uniformity tests for
    # the small ranges this library uses.
    raw=$(( _RNG_LCG_STATE >> 16 ))
  else
    raw=$RANDOM
  fi
  _RNG_RESULT=$(( min + (raw % range) ))
  printf '%d' "$_RNG_RESULT"
}

# Guard used at the top of every public function: fail fast if jq is missing.
_rng_check_jq() {
  if (( _RNG_JQ_MISSING )); then
    _rng_log "$1: jq is not available"
    return 1
  fi
  return 0
}

# Load a species JSON file into the per-process cache and echo its contents.
# Caches by species name on first read; subsequent reads are O(1).
_rng_load_species() {
  local species="$1"
  if ! _rng_valid_species_name "$species"; then
    _rng_log "_rng_load_species: invalid species name"
    return 1
  fi
  if [[ -n "${_RNG_SPECIES_CACHE[$species]:-}" ]]; then
    printf '%s' "${_RNG_SPECIES_CACHE[$species]}"
    return 0
  fi
  local dir
  dir="$(_rng_species_dir)" || return 1
  local file="$dir/$species.json"
  if [[ ! -f "$file" ]]; then
    _rng_log "_rng_load_species: $file not found"
    return 1
  fi
  local json
  if ! json="$(jq -c '.' "$file" 2>/dev/null)"; then
    _rng_log "_rng_load_species: failed to parse $file"
    return 1
  fi
  _RNG_SPECIES_CACHE[$species]="$json"
  printf '%s' "$json"
}

# Public: pick a species uniformly from the available species JSON files.
# Honors BUDDY_SPECIES_DIR for test fixtures.
# Sets _RNG_ROLL and echoes to stdout (see _rng_int docstring re: subshell state).
roll_species() {
  _rng_check_jq "roll_species" || return 1
  local dir
  dir="$(_rng_species_dir)" || { _rng_log "roll_species: could not resolve species dir"; return 1; }
  if [[ ! -d "$dir" ]]; then
    _rng_log "roll_species: $dir is not a directory"
    return 1
  fi
  # Collect species filenames (without .json) into an array.
  local files=()
  local f
  while IFS= read -r f; do
    files+=("$(basename "$f" .json)")
  done < <(find "$dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null | sort)
  local count="${#files[@]}"
  if (( count == 0 )); then
    _rng_log "roll_species: no species files in $dir"
    return 1
  fi
  _rng_int 1 "$count" >/dev/null || return 1
  _RNG_ROLL="${files[$((_RNG_RESULT - 1))]}"
  printf '%s' "$_RNG_ROLL"
}

# Public: pick a random name from the given species' name_pool.
# Sets _RNG_ROLL and echoes to stdout.
roll_name() {
  _rng_check_jq "roll_name" || return 1
  local species="${1:-}"
  if ! _rng_valid_species_name "$species"; then
    _rng_log "roll_name: invalid species name '$species'"
    return 1
  fi
  local json
  json="$(_rng_load_species "$species")" || return 1
  local count
  count="$(printf '%s' "$json" | jq -r '.name_pool | length' 2>/dev/null)"
  if ! [[ "$count" =~ ^[0-9]+$ ]] || (( count == 0 )); then
    _rng_log "roll_name: empty or invalid name_pool for $species"
    return 1
  fi
  _rng_int 1 "$count" >/dev/null || return 1
  _RNG_ROLL="$(printf '%s' "$json" | jq -r ".name_pool[$((_RNG_RESULT - 1))]")"
  printf '%s' "$_RNG_ROLL"
}

# Public: roll a rarity. Distribution is 60/25/10/4/1 (Common/Uncommon/Rare/
# Epic/Legendary). When pity_counter >= PITY_THRESHOLD, the roll is forced to
# Rare+ with a 10:4:1 internal split that preserves the natural ratio.
# Sets _RNG_ROLL and echoes to stdout.
roll_rarity() {
  local pity="${1:-}"
  if ! [[ "$pity" =~ ^[0-9]+$ ]]; then
    _rng_log "roll_rarity: invalid pity_counter '$pity' (must be non-negative integer)"
    return 1
  fi

  local r
  if (( pity >= PITY_THRESHOLD )); then
    # Forced Rare+: 1/15 legendary, 4/15 epic, 10/15 rare.
    _rng_int 1 "$PITY_WEIGHT_TOTAL" >/dev/null || return 1
    r=$_RNG_RESULT
    if (( r <= PITY_CUT_LEGENDARY )); then
      _RNG_ROLL="legendary"
    elif (( r <= PITY_CUT_EPIC )); then
      _RNG_ROLL="epic"
    else
      _RNG_ROLL="rare"
    fi
    printf '%s' "$_RNG_ROLL"
    return 0
  fi

  _rng_int 1 100 >/dev/null || return 1
  r=$_RNG_RESULT
  if   (( r <= RARITY_CUT_COMMON ));   then _RNG_ROLL="common"
  elif (( r <= RARITY_CUT_UNCOMMON )); then _RNG_ROLL="uncommon"
  elif (( r <= RARITY_CUT_RARE ));     then _RNG_ROLL="rare"
  elif (( r <= RARITY_CUT_EPIC ));     then _RNG_ROLL="epic"
  else                                      _RNG_ROLL="legendary"
  fi
  printf '%s' "$_RNG_ROLL"
}

# Public: compute the next pity counter given the current value and the
# rarity that was just rolled.
#   common    → current + 1
#   uncommon  → current (unchanged — neutral per origin ticket + umbrella D8)
#   rare/epic/legendary → 0
next_pity_counter() {
  local current="${1:-}"
  local rarity="${2:-}"
  if ! [[ "$current" =~ ^[0-9]+$ ]]; then
    _rng_log "next_pity_counter: invalid current '$current'"
    return 1
  fi
  case "$rarity" in
    common)                    printf '%d' $(( current + 1 )) ;;
    uncommon)                  printf '%d' "$current" ;;
    rare|epic|legendary)       printf '%d' 0 ;;
    *)
      _rng_log "next_pity_counter: unknown rarity '$rarity'"
      return 1
      ;;
  esac
}

# Internal: extract the peak-prefer stat name from a species JSON blob.
# Echoes to stdout. Sets _RNG_STAT_PEAK.
_rng_species_peak() {
  local json="$1"
  _RNG_STAT_PEAK="$(printf '%s' "$json" | jq -r '
    .base_stats_weights | to_entries | map(select(.value == "peak-prefer"))[0].key
  ')"
  [[ -n "$_RNG_STAT_PEAK" && "$_RNG_STAT_PEAK" != "null" ]] || return 1
  printf '%s' "$_RNG_STAT_PEAK"
}

# Internal: extract the dump-prefer stat name from a species JSON blob.
_rng_species_dump() {
  local json="$1"
  _RNG_STAT_DUMP="$(printf '%s' "$json" | jq -r '
    .base_stats_weights | to_entries | map(select(.value == "dump-prefer"))[0].key
  ')"
  [[ -n "$_RNG_STAT_DUMP" && "$_RNG_STAT_DUMP" != "null" ]] || return 1
  printf '%s' "$_RNG_STAT_DUMP"
}

# Public: generate a 5-stat object with rarity floor + one-peak/one-dump/
# three-mid shape, ~60% species-weight bias on peak and dump slot selection.
# Sets _RNG_ROLL to the JSON and echoes it.
roll_stats() {
  _rng_check_jq "roll_stats" || return 1
  local rarity="${1:-}"
  local species="${2:-}"

  if [[ -z "${_RNG_FLOORS[$rarity]:-}" ]]; then
    _rng_log "roll_stats: invalid rarity '$rarity'"
    return 1
  fi
  if ! _rng_valid_species_name "$species"; then
    _rng_log "roll_stats: invalid species name '$species'"
    return 1
  fi

  local json
  json="$(_rng_load_species "$species")" || return 1

  local peak_pref dump_pref
  peak_pref="$(_rng_species_peak "$json")" || {
    _rng_log "roll_stats: $species has no peak-prefer stat"
    return 1
  }
  dump_pref="$(_rng_species_dump "$json")" || {
    _rng_log "roll_stats: $species has no dump-prefer stat"
    return 1
  }
  if [[ "$peak_pref" == "$dump_pref" ]]; then
    _rng_log "roll_stats: $species has peak-prefer == dump-prefer ($peak_pref); species data is malformed"
    return 1
  fi

  local floor="${_RNG_FLOORS[$rarity]}"
  # Clamp range ceilings to 100 so peak cannot exceed the stat cap.
  local peak_lo=$(( floor + _RNG_PEAK_OFFSET_LO ))
  local peak_hi=100
  local dump_lo=$floor
  local dump_hi=$(( floor + _RNG_DUMP_OFFSET_HI ))
  local mid_lo=$(( floor + _RNG_MID_OFFSET_LO ))
  local mid_hi=$(( floor + _RNG_MID_OFFSET_HI ))
  (( peak_lo > peak_hi )) && peak_lo=$peak_hi   # defensive; floor 50 + 40 = 90, fine
  (( dump_hi > 100 )) && dump_hi=100
  (( mid_hi > 100 )) && mid_hi=100

  # Pick peak slot: 60% species-preferred, else uniform over all 5 stats.
  _rng_int 1 100 >/dev/null || return 1
  local peak_stat
  if (( _RNG_RESULT <= _RNG_SPECIES_BIAS )); then
    peak_stat="$peak_pref"
  else
    _rng_int 1 5 >/dev/null || return 1
    peak_stat="${_RNG_STATS[$((_RNG_RESULT - 1))]}"
  fi

  # Pick dump slot: 60% species-preferred, else uniform over all 5 stats.
  # On collision with peak, fall back to the species' dump_pref (guaranteed
  # != peak by prior check above if species was sane; if the uniform draw
  # happened to hit peak_stat and peak_stat == peak_pref, dump_pref is still
  # safe). If that still collides (peak chose the non-preferred uniform path
  # and landed on dump_pref), pick uniformly over the remaining 4 stats.
  _rng_int 1 100 >/dev/null || return 1
  local dump_stat
  if (( _RNG_RESULT <= _RNG_SPECIES_BIAS )); then
    dump_stat="$dump_pref"
  else
    _rng_int 1 5 >/dev/null || return 1
    dump_stat="${_RNG_STATS[$((_RNG_RESULT - 1))]}"
  fi
  if [[ "$dump_stat" == "$peak_stat" ]]; then
    if [[ "$dump_pref" != "$peak_stat" ]]; then
      dump_stat="$dump_pref"
    else
      # Uniform over 4 non-peak stats
      local pool=()
      local s
      for s in "${_RNG_STATS[@]}"; do
        [[ "$s" != "$peak_stat" ]] && pool+=("$s")
      done
      _rng_int 1 "${#pool[@]}" >/dev/null || return 1
      dump_stat="${pool[$((_RNG_RESULT - 1))]}"
    fi
  fi

  # Roll each stat in canonical order.
  local -A stat_values=()
  local s
  for s in "${_RNG_STATS[@]}"; do
    if [[ "$s" == "$peak_stat" ]]; then
      _rng_int "$peak_lo" "$peak_hi" >/dev/null || return 1
    elif [[ "$s" == "$dump_stat" ]]; then
      _rng_int "$dump_lo" "$dump_hi" >/dev/null || return 1
    else
      _rng_int "$mid_lo" "$mid_hi" >/dev/null || return 1
    fi
    stat_values[$s]=$_RNG_RESULT
  done

  # Emit compact JSON in canonical stat order via a single jq invocation.
  _RNG_ROLL="$(jq -n -c \
    --argjson debugging "${stat_values[debugging]}" \
    --argjson patience  "${stat_values[patience]}" \
    --argjson chaos     "${stat_values[chaos]}" \
    --argjson wisdom    "${stat_values[wisdom]}" \
    --argjson snark     "${stat_values[snark]}" \
    '{debugging:$debugging, patience:$patience, chaos:$chaos, wisdom:$wisdom, snark:$snark}'
  )" || { _rng_log "roll_stats: jq assembly failed"; return 1; }
  printf '%s' "$_RNG_ROLL"
}

# Public: compose roll_rarity + roll_species + roll_stats + roll_name into a
# complete inner-buddy JSON object. The caller (P1-3's /buddy:hatch handler)
# wraps this under a .buddy field inside the buddy.json envelope.
#
# Note: `signals` is deliberately absent from the output. Per resolved
# design decision, P4-1 owns the signals field and its schema — this phase
# stays ignorant of P4-1's data model.
#
# Sets _RNG_ROLL to the JSON and echoes it.
roll_buddy() {
  _rng_check_jq "roll_buddy" || return 1
  local pity="${1:-}"
  if ! [[ "$pity" =~ ^[0-9]+$ ]]; then
    _rng_log "roll_buddy: invalid pity_counter '$pity' (must be non-negative integer)"
    return 1
  fi

  roll_rarity "$pity" >/dev/null || { _rng_log "roll_buddy: roll_rarity failed"; return 1; }
  local rarity="$_RNG_ROLL"

  roll_species >/dev/null || { _rng_log "roll_buddy: roll_species failed"; return 1; }
  local species="$_RNG_ROLL"

  roll_stats "$rarity" "$species" >/dev/null || { _rng_log "roll_buddy: roll_stats failed"; return 1; }
  local stats_json="$_RNG_ROLL"

  roll_name "$species" >/dev/null || { _rng_log "roll_buddy: roll_name failed"; return 1; }
  local name="$_RNG_ROLL"

  # Generate 32-char hex ID. Prefer /dev/urandom; fall back to the LCG when
  # unavailable (weaker but still collision-resistant at realistic use).
  local id=""
  if [[ -r /dev/urandom ]]; then
    id="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \t\n')"
  fi
  if [[ -z "$id" || ! "$id" =~ ^[0-9a-f]{32}$ ]]; then
    # Fallback: four 32-bit LCG pulls → 32 hex chars.
    local h1 h2 h3 h4
    _rng_int 0 4294967295 >/dev/null || return 1; h1=$_RNG_RESULT
    _rng_int 0 4294967295 >/dev/null || return 1; h2=$_RNG_RESULT
    _rng_int 0 4294967295 >/dev/null || return 1; h3=$_RNG_RESULT
    _rng_int 0 4294967295 >/dev/null || return 1; h4=$_RNG_RESULT
    id=$(printf '%08x%08x%08x%08x' "$h1" "$h2" "$h3" "$h4")
  fi

  _RNG_ROLL="$(jq -n -c \
    --arg id "$id" \
    --arg name "$name" \
    --arg species "$species" \
    --arg rarity "$rarity" \
    --argjson stats "$stats_json" \
    '{
      id: $id,
      name: $name,
      species: $species,
      rarity: $rarity,
      shiny: false,
      stats: $stats,
      form: "base",
      level: 1,
      xp: 0
    }'
  )" || { _rng_log "roll_buddy: jq assembly failed"; return 1; }
  printf '%s' "$_RNG_ROLL"
}
