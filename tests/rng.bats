#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load test_helper

# ============================================================
# Library hygiene — Unit 1 scaffolding
# ============================================================

@test "rng.sh: sources cleanly without leaking set -e / pipefail into caller" {
  # If rng.sh leaked pipefail, `false | true` would exit non-zero and the
  # script would hit `|| exit 12` before echoing 'ok'.
  run bash -c '
    source "'"$RNG_LIB"'"
    false | true || exit 12
    echo "ok"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rng.sh: re-sourcing in same shell does not re-declare readonly variables" {
  # A regression here would emit 'readonly: variable: readonly variable'
  # messages to stderr. _RNG_SH_LOADED sentinel prevents that.
  run bash -c '
    source "'"$RNG_LIB"'"
    source "'"$RNG_LIB"'" 2>&1
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"readonly variable"* ]]
}

# ============================================================
# _rng_int — core primitive
# ============================================================

@test "_rng_int: returns values in [min, max] inclusive over 1000 rolls" {
  source "$RNG_LIB"
  local i value min_seen=100 max_seen=0
  for (( i = 0; i < 1000; i++ )); do
    value=$(_rng_int 1 100)
    (( value < 1 || value > 100 )) && { echo "out-of-range: $value"; return 1; }
    (( value < min_seen )) && min_seen=$value
    (( value > max_seen )) && max_seen=$value
  done
  # Sanity: both boundaries should be reachable within 1000 rolls on a 100-wide range
  (( min_seen <= 5 )) || { echo "min_seen too high: $min_seen"; return 1; }
  (( max_seen >= 96 )) || { echo "max_seen too low: $max_seen"; return 1; }
}

@test "_rng_int: degenerate range (min == max) always returns that value" {
  source "$RNG_LIB"
  local i value
  for (( i = 0; i < 20; i++ )); do
    value=$(_rng_int 5 5)
    [ "$value" = "5" ]
  done
}

@test "_rng_int: binary range (1..2) hits both values over 1000 rolls" {
  source "$RNG_LIB"
  local i ones=0 twos=0 value
  for (( i = 0; i < 1000; i++ )); do
    value=$(_rng_int 1 2)
    case "$value" in
      1) (( ++ones )) ;;
      2) (( ++twos )) ;;
      *) echo "unexpected: $value"; return 1 ;;
    esac
  done
  (( ones >= 400 )) || { echo "ones=$ones"; return 1; }
  (( twos >= 400 )) || { echo "twos=$twos"; return 1; }
}

@test "_rng_int: inverted bounds logs error and returns non-zero" {
  source "$RNG_LIB"
  run --separate-stderr _rng_int 10 5
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"inverted bounds"* ]]
}

@test "_rng_int: non-integer bounds log error and return non-zero" {
  source "$RNG_LIB"
  run --separate-stderr _rng_int foo bar
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"non-integer bounds"* ]]
}

# ============================================================
# BUDDY_RNG_SEED — deterministic LCG path
# ============================================================

@test "BUDDY_RNG_SEED: two independent shells produce identical sequences" {
  local seq1 seq2
  seq1=$(BUDDY_RNG_SEED=42 bash -c '
    source "'"$RNG_LIB"'"
    for (( i = 0; i < 10; i++ )); do _rng_int 1 100; echo; done
  ')
  seq2=$(BUDDY_RNG_SEED=42 bash -c '
    source "'"$RNG_LIB"'"
    for (( i = 0; i < 10; i++ )); do _rng_int 1 100; echo; done
  ')
  [ "$seq1" = "$seq2" ]
}

@test "BUDDY_RNG_SEED: different seeds produce different sequences" {
  local seq1 seq2
  seq1=$(BUDDY_RNG_SEED=1 bash -c '
    source "'"$RNG_LIB"'"
    for (( i = 0; i < 10; i++ )); do _rng_int 1 100; echo; done
  ')
  seq2=$(BUDDY_RNG_SEED=2 bash -c '
    source "'"$RNG_LIB"'"
    for (( i = 0; i < 10; i++ )); do _rng_int 1 100; echo; done
  ')
  [ "$seq1" != "$seq2" ]
}

@test "non-determinism: 10 independent shells on wide range produce 10 distinct values" {
  # Using _rng_int 1 1000000 makes birthday collisions effectively impossible.
  # If /dev/urandom (or the fallback) wires through, all 10 shells diverge.
  local i value
  declare -A seen=()
  for (( i = 0; i < 10; i++ )); do
    value=$(bash -c 'source "'"$RNG_LIB"'"; _rng_int 1 1000000')
    seen[$value]=1
  done
  [ "${#seen[@]}" -eq 10 ]
}

# ============================================================
# Species data integrity — Unit 2
# ============================================================

@test "species data: all 5 species files exist" {
  [ -f "$SPECIES_DIR/axolotl.json" ]
  [ -f "$SPECIES_DIR/dragon.json" ]
  [ -f "$SPECIES_DIR/owl.json" ]
  [ -f "$SPECIES_DIR/ghost.json" ]
  [ -f "$SPECIES_DIR/capybara.json" ]
  local count
  count=$(find "$SPECIES_DIR" -maxdepth 1 -name '*.json' -type f | wc -l)
  [ "$count" -eq 5 ]
}

@test "species data: each file is valid JSON" {
  for f in "$SPECIES_DIR"/*.json; do
    run jq -e '.' "$f"
    [ "$status" -eq 0 ] || { echo "invalid JSON: $f"; return 1; }
  done
}

@test "species data: each file has required top-level keys" {
  for f in "$SPECIES_DIR"/*.json; do
    run jq -e '
      has("schemaVersion") and
      has("species") and
      has("voice") and
      has("base_stats_weights") and
      has("name_pool") and
      has("evolution_paths") and
      has("line_banks") and
      has("sprite")
    ' "$f"
    [ "$status" -eq 0 ] || { echo "missing keys in: $f"; return 1; }
  done
}

@test "species data: species field matches filename for every file" {
  for f in "$SPECIES_DIR"/*.json; do
    local basename species_field
    basename=$(basename "$f" .json)
    species_field=$(jq -r '.species' "$f")
    [ "$basename" = "$species_field" ] || { echo "mismatch in $f: $basename vs $species_field"; return 1; }
  done
}

@test "species data: base_stats_weights covers all 5 stats with exactly one peak-prefer and one dump-prefer" {
  for f in "$SPECIES_DIR"/*.json; do
    run jq -e '
      .base_stats_weights
      | (has("debugging") and has("patience") and has("chaos") and has("wisdom") and has("snark"))
      and (to_entries | length == 5)
      and ([.[] | select(. == "peak-prefer")] | length == 1)
      and ([.[] | select(. == "dump-prefer")] | length == 1)
      and ([.[] | select(. == "neutral")] | length == 3)
    ' "$f"
    [ "$status" -eq 0 ] || { echo "bad base_stats_weights in $f"; return 1; }
  done
}

@test "species data: peak-prefer stat differs from dump-prefer stat" {
  for f in "$SPECIES_DIR"/*.json; do
    local peak dump
    peak=$(jq -r '.base_stats_weights | to_entries | map(select(.value == "peak-prefer"))[0].key' "$f")
    dump=$(jq -r '.base_stats_weights | to_entries | map(select(.value == "dump-prefer"))[0].key' "$f")
    [ "$peak" != "$dump" ] || { echo "peak == dump in $f"; return 1; }
  done
}

@test "species data: name_pool has >= 20 unique non-empty strings per file" {
  for f in "$SPECIES_DIR"/*.json; do
    run jq -e '
      (.name_pool | length) >= 20
      and (.name_pool | all(type == "string" and length > 0))
      and ((.name_pool | length) == (.name_pool | unique | length))
    ' "$f"
    [ "$status" -eq 0 ] || { echo "bad name_pool in $f"; return 1; }
  done
}

# ============================================================
# roll_species — Unit 3
# ============================================================

@test "roll_species: returns one of the 5 launch species" {
  source "$RNG_LIB"
  run --separate-stderr roll_species
  [ "$status" -eq 0 ]
  case "$output" in
    axolotl|dragon|owl|ghost|capybara) ;;
    *) echo "unexpected species: $output"; return 1 ;;
  esac
}

@test "roll_species: 500 rolls hit every species at least 50 times" {
  source "$RNG_LIB"
  local i species
  declare -A counts=()
  for (( i = 0; i < 500; i++ )); do
    species=$(roll_species)
    counts[$species]=$(( ${counts[$species]:-0} + 1 ))
  done
  [ "${#counts[@]}" -eq 5 ] || { echo "only hit ${#counts[@]} species"; return 1; }
  for s in axolotl dragon owl ghost capybara; do
    local c="${counts[$s]:-0}"
    (( c >= 50 )) || { echo "$s only rolled $c/500 times"; return 1; }
  done
}

@test "roll_species: empty species dir returns error" {
  export BUDDY_SPECIES_DIR="$BATS_TEST_TMPDIR/empty-species"
  mkdir -p "$BUDDY_SPECIES_DIR"
  source "$RNG_LIB"
  run --separate-stderr roll_species
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"no species files"* ]]
}

@test "roll_species: missing species dir returns error" {
  export BUDDY_SPECIES_DIR="$BATS_TEST_TMPDIR/does-not-exist"
  source "$RNG_LIB"
  run --separate-stderr roll_species
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"not a directory"* ]]
}

# ============================================================
# roll_name — Unit 3
# ============================================================

@test "roll_name: returns a name from the species' name_pool" {
  source "$RNG_LIB"
  local species
  for species in axolotl dragon owl ghost capybara; do
    local name
    name=$(roll_name "$species")
    [ -n "$name" ] || { echo "empty name for $species"; return 1; }
    # Verify the returned name is actually in the pool
    run jq -e --arg n "$name" '.name_pool | index($n) != null' "$SPECIES_DIR/$species.json"
    [ "$status" -eq 0 ] || { echo "$name not in $species pool"; return 1; }
  done
}

@test "roll_name: 200 rolls for one species produce at least 10 distinct names" {
  source "$RNG_LIB"
  local i
  declare -A seen=()
  for (( i = 0; i < 200; i++ )); do
    seen["$(roll_name axolotl)"]=1
  done
  (( ${#seen[@]} >= 10 )) || { echo "only ${#seen[@]} distinct names"; return 1; }
}

@test "roll_name: nonexistent species returns error" {
  source "$RNG_LIB"
  run --separate-stderr roll_name nonexistent
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"not found"* ]]
}

@test "roll_name: path traversal attempt is rejected" {
  source "$RNG_LIB"
  run --separate-stderr roll_name "../../etc/passwd"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"invalid species name"* ]]
}

@test "roll_name: empty species arg returns error" {
  source "$RNG_LIB"
  run --separate-stderr roll_name ""
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"invalid species name"* ]]
}

@test "species data: voice matches umbrella plan archetype mapping" {
  local expected=(
    "axolotl:wholesome-cheerleader"
    "dragon:chaotic-gremlin"
    "owl:dry-scholar"
    "ghost:deadpan-night"
    "capybara:chill-zen"
  )
  for entry in "${expected[@]}"; do
    local species="${entry%%:*}"
    local want="${entry#*:}"
    local got
    got=$(jq -r '.voice' "$SPECIES_DIR/$species.json")
    [ "$got" = "$want" ] || { echo "$species voice: got '$got', want '$want'"; return 1; }
  done
}
