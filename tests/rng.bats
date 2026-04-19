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
  local i
  declare -A counts=()
  for (( i = 0; i < 500; i++ )); do
    roll_species >/dev/null
    counts[$_RNG_ROLL]=$(( ${counts[$_RNG_ROLL]:-0} + 1 ))
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
    roll_name axolotl >/dev/null
    seen["$_RNG_ROLL"]=1
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

# ============================================================
# roll_rarity — Unit 4
# ============================================================

@test "roll_rarity: returns one of 5 valid rarities" {
  source "$RNG_LIB"
  local r
  r=$(roll_rarity 0)
  case "$r" in
    common|uncommon|rare|epic|legendary) ;;
    *) echo "unexpected: $r"; return 1 ;;
  esac
}

@test "roll_rarity: non-integer pity returns error" {
  source "$RNG_LIB"
  run --separate-stderr roll_rarity foo
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"invalid pity_counter"* ]]
}

@test "roll_rarity: negative pity returns error" {
  source "$RNG_LIB"
  run --separate-stderr roll_rarity -5
  [ "$status" -ne 0 ]
}

@test "roll_rarity: distribution over 10k rolls matches 60/25/10/4/1 within tolerance (seed 42)" {
  export BUDDY_RNG_SEED=42
  source "$RNG_LIB"
  local i
  declare -A counts=()
  for (( i = 0; i < 10000; i++ )); do
    roll_rarity 0 >/dev/null
    counts[$_RNG_ROLL]=$(( ${counts[$_RNG_ROLL]:-0} + 1 ))
  done
  # ±2% absolute bands for well-populated tiers
  local c="${counts[common]:-0}"       ; (( c >= 5800 && c <= 6200 )) || { echo "common=$c"; return 1; }
  local u="${counts[uncommon]:-0}"     ; (( u >= 2300 && u <= 2700 )) || { echo "uncommon=$u"; return 1; }
  local rare_c="${counts[rare]:-0}"    ; (( rare_c >= 800 && rare_c <= 1200 )) || { echo "rare=$rare_c"; return 1; }
  # Absolute bands for low-pop tiers (σ≈20 at n=400 for epic, σ≈10 at n=100 for legendary)
  local e="${counts[epic]:-0}"         ; (( e >= 200 && e <= 600 )) || { echo "epic=$e"; return 1; }
  local l="${counts[legendary]:-0}"    ; (( l >= 40 && l <= 200 )) || { echo "legendary=$l"; return 1; }
}

@test "roll_rarity: distribution holds across 3 different seeds" {
  local seed
  for seed in 1 99 12345; do
    export BUDDY_RNG_SEED=$seed
    run bash -c '
      source "'"$RNG_LIB"'"
      declare -A counts=()
      for (( i = 0; i < 10000; i++ )); do
        roll_rarity 0 >/dev/null
        counts[$_RNG_ROLL]=$(( ${counts[$_RNG_ROLL]:-0} + 1 ))
      done
      c="${counts[common]:-0}"
      u="${counts[uncommon]:-0}"
      rare_c="${counts[rare]:-0}"
      e="${counts[epic]:-0}"
      l="${counts[legendary]:-0}"
      (( c >= 5800 && c <= 6200 )) || { echo "common=$c"; exit 1; }
      (( u >= 2300 && u <= 2700 )) || { echo "uncommon=$u"; exit 2; }
      (( rare_c >= 800 && rare_c <= 1200 )) || { echo "rare=$rare_c"; exit 3; }
      (( e >= 200 && e <= 600 )) || { echo "epic=$e"; exit 4; }
      (( l >= 40 && l <= 200 )) || { echo "legendary=$l"; exit 5; }
    '
    [ "$status" -eq 0 ] || { echo "seed $seed: $output"; return 1; }
  done
}

@test "roll_rarity: pity trigger at 10 never returns common or uncommon over 1000 rolls" {
  source "$RNG_LIB"
  local i
  for (( i = 0; i < 1000; i++ )); do
    roll_rarity 10 >/dev/null
    case "$_RNG_ROLL" in
      rare|epic|legendary) ;;
      *) echo "pity leaked $_RNG_ROLL at i=$i"; return 1 ;;
    esac
  done
}

@test "roll_rarity: pity trigger at 11 also forces Rare+" {
  source "$RNG_LIB"
  local i
  for (( i = 0; i < 500; i++ )); do
    roll_rarity 11 >/dev/null
    case "$_RNG_ROLL" in
      rare|epic|legendary) ;;
      *) echo "pity leaked $_RNG_ROLL at i=$i"; return 1 ;;
    esac
  done
}

@test "roll_rarity: pity at 9 is still normal distribution (can roll common)" {
  source "$RNG_LIB"
  local i common_seen=0
  for (( i = 0; i < 500; i++ )); do
    roll_rarity 9 >/dev/null
    [ "$_RNG_ROLL" = "common" ] && common_seen=1
  done
  [ "$common_seen" -eq 1 ] || { echo "never rolled common at pity=9"; return 1; }
}

@test "roll_rarity: pity forced distribution hits all 3 Rare+ tiers over 1500 rolls" {
  source "$RNG_LIB"
  local i
  declare -A counts=()
  for (( i = 0; i < 1500; i++ )); do
    roll_rarity 10 >/dev/null
    counts[$_RNG_ROLL]=$(( ${counts[$_RNG_ROLL]:-0} + 1 ))
  done
  (( ${counts[rare]:-0} > 0 )) || { echo "no rare"; return 1; }
  (( ${counts[epic]:-0} > 0 )) || { echo "no epic"; return 1; }
  (( ${counts[legendary]:-0} > 0 )) || { echo "no legendary"; return 1; }
}

# ============================================================
# next_pity_counter — Unit 4
# ============================================================

@test "next_pity_counter: common increments" {
  source "$RNG_LIB"
  [ "$(next_pity_counter 0 common)" = "1" ]
  [ "$(next_pity_counter 5 common)" = "6" ]
  [ "$(next_pity_counter 9 common)" = "10" ]
  [ "$(next_pity_counter 10 common)" = "11" ]
}

@test "next_pity_counter: uncommon leaves counter unchanged" {
  source "$RNG_LIB"
  [ "$(next_pity_counter 0 uncommon)" = "0" ]
  [ "$(next_pity_counter 3 uncommon)" = "3" ]
  [ "$(next_pity_counter 9 uncommon)" = "9" ]
}

@test "next_pity_counter: rare/epic/legendary reset to 0" {
  source "$RNG_LIB"
  [ "$(next_pity_counter 10 rare)" = "0" ]
  [ "$(next_pity_counter 7 epic)" = "0" ]
  [ "$(next_pity_counter 5 legendary)" = "0" ]
  [ "$(next_pity_counter 0 rare)" = "0" ]
}

@test "next_pity_counter: invalid rarity returns error" {
  source "$RNG_LIB"
  run --separate-stderr next_pity_counter 0 puddle
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"unknown rarity"* ]]
}

@test "next_pity_counter: non-integer current returns error" {
  source "$RNG_LIB"
  run --separate-stderr next_pity_counter abc common
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"invalid current"* ]]
}

# ============================================================
# roll_stats — Unit 5
# ============================================================

@test "roll_stats: output has exactly the 5 stat keys" {
  source "$RNG_LIB"
  roll_stats common axolotl >/dev/null
  run jq -e '
    (keys | sort) == ["chaos", "debugging", "patience", "snark", "wisdom"]
  ' <<< "$_RNG_ROLL"
  [ "$status" -eq 0 ]
}

@test "roll_stats: all values are integers in [0, 100]" {
  source "$RNG_LIB"
  roll_stats common axolotl >/dev/null
  run jq -e '
    [.debugging, .patience, .chaos, .wisdom, .snark]
    | all(type == "number" and . >= 0 and . <= 100)
  ' <<< "$_RNG_ROLL"
  [ "$status" -eq 0 ]
}

@test "roll_stats: floor enforcement — legendary across all species, 200 rolls each, every stat >= 50" {
  source "$RNG_LIB"
  local species i
  for species in axolotl dragon owl ghost capybara; do
    for (( i = 0; i < 200; i++ )); do
      roll_stats legendary "$species" >/dev/null
      local min
      min="$(jq -r '[.debugging, .patience, .chaos, .wisdom, .snark] | min' <<< "$_RNG_ROLL")"
      (( min >= 50 )) || { echo "$species roll $i: min=$min, json=$_RNG_ROLL"; return 1; }
    done
  done
}

@test "roll_stats: floor enforcement — 50 rolls × 25 (rarity,species) combos, every stat >= rarity floor" {
  source "$RNG_LIB"
  declare -A floor=([common]=5 [uncommon]=15 [rare]=25 [epic]=35 [legendary]=50)
  local rarity species i
  for rarity in common uncommon rare epic legendary; do
    for species in axolotl dragon owl ghost capybara; do
      for (( i = 0; i < 50; i++ )); do
        roll_stats "$rarity" "$species" >/dev/null
        local min
        min="$(jq -r '[.debugging, .patience, .chaos, .wisdom, .snark] | min' <<< "$_RNG_ROLL")"
        (( min >= ${floor[$rarity]} )) || {
          echo "$rarity $species roll $i: min=$min, floor=${floor[$rarity]}, json=$_RNG_ROLL"
          return 1
        }
      done
    done
  done
}

@test "roll_stats: shape — exactly one peak (>= floor+41), one dump (<= floor+14), three mids" {
  source "$RNG_LIB"
  local i
  for (( i = 0; i < 100; i++ )); do
    roll_stats legendary axolotl >/dev/null
    # floor=50; peak in [91,100]; dump in [50,64]; mid in [65,90]
    run jq -e '
      [.debugging, .patience, .chaos, .wisdom, .snark] as $stats
      | ([$stats[] | select(. >= 91)] | length) == 1
      and ([$stats[] | select(. <= 64)] | length) == 1
      and ([$stats[] | select(. >= 65 and . <= 90)] | length) == 3
    ' <<< "$_RNG_ROLL"
    [ "$status" -eq 0 ] || { echo "bad shape at i=$i: $_RNG_ROLL"; return 1; }
  done
}

@test "roll_stats: species bias — patience is the peak for axolotl in > 55% of 1000 rolls" {
  export BUDDY_RNG_SEED=777
  source "$RNG_LIB"
  local i peak_count=0
  for (( i = 0; i < 1000; i++ )); do
    roll_stats legendary axolotl >/dev/null
    local peak_stat
    peak_stat="$(jq -r 'to_entries | max_by(.value).key' <<< "$_RNG_ROLL")"
    if [ "$peak_stat" = "patience" ]; then
      peak_count=$(( peak_count + 1 ))
    fi
  done
  # Expected ~680 (0.68 × 1000); threshold 550 gives plenty of headroom
  (( peak_count > 550 )) || { echo "patience peaked only $peak_count/1000 times"; return 1; }
}

@test "roll_stats: species bias — chaos is the dump for axolotl in > 55% of 1000 rolls" {
  export BUDDY_RNG_SEED=333
  source "$RNG_LIB"
  local i dump_count=0
  for (( i = 0; i < 1000; i++ )); do
    roll_stats legendary axolotl >/dev/null
    local dump_stat
    dump_stat="$(jq -r 'to_entries | min_by(.value).key' <<< "$_RNG_ROLL")"
    if [ "$dump_stat" = "chaos" ]; then
      dump_count=$(( dump_count + 1 ))
    fi
  done
  (( dump_count > 550 )) || { echo "chaos dumped only $dump_count/1000 times"; return 1; }
}

@test "roll_stats: invalid rarity returns error" {
  source "$RNG_LIB"
  run --separate-stderr roll_stats not-a-rarity axolotl
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"invalid rarity"* ]]
}

@test "roll_stats: invalid species name returns error" {
  source "$RNG_LIB"
  run --separate-stderr roll_stats common "../etc/passwd"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"invalid species name"* ]]
}

@test "roll_stats: nonexistent species returns error" {
  source "$RNG_LIB"
  run --separate-stderr roll_stats common nonexistent-species
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"not found"* ]]
}

@test "roll_stats: legendary never produces a value > 100 (peak clamp)" {
  source "$RNG_LIB"
  local i
  for (( i = 0; i < 200; i++ )); do
    roll_stats legendary axolotl >/dev/null
    local max
    max="$(jq -r '[.debugging, .patience, .chaos, .wisdom, .snark] | max' <<< "$_RNG_ROLL")"
    (( max <= 100 )) || { echo "overflow at i=$i: max=$max json=$_RNG_ROLL"; return 1; }
  done
}

# ============================================================
# roll_buddy — Unit 6
# ============================================================

@test "roll_buddy: emits valid JSON with exactly the expected top-level keys" {
  source "$RNG_LIB"
  roll_buddy 0 >/dev/null
  run jq -e '
    (keys | sort) == ["form", "id", "level", "name", "rarity", "shiny", "species", "stats", "xp"]
  ' <<< "$_RNG_ROLL"
  [ "$status" -eq 0 ]
}

@test "roll_buddy: signals is deliberately absent (owned by P4-1)" {
  source "$RNG_LIB"
  roll_buddy 0 >/dev/null
  run jq -e 'has("signals") | not' <<< "$_RNG_ROLL"
  [ "$status" -eq 0 ]
}

@test "roll_buddy: form=base, level=1, xp=0, shiny=false" {
  source "$RNG_LIB"
  roll_buddy 0 >/dev/null
  [ "$(jq -r '.form' <<< "$_RNG_ROLL")" = "base" ]
  [ "$(jq -r '.level' <<< "$_RNG_ROLL")" = "1" ]
  [ "$(jq -r '.xp' <<< "$_RNG_ROLL")" = "0" ]
  [ "$(jq -r '.shiny' <<< "$_RNG_ROLL")" = "false" ]
}

@test "roll_buddy: id is 32 hex chars" {
  source "$RNG_LIB"
  roll_buddy 0 >/dev/null
  local id
  id="$(jq -r '.id' <<< "$_RNG_ROLL")"
  [[ "$id" =~ ^[0-9a-f]{32}$ ]] || { echo "bad id: $id"; return 1; }
}

@test "roll_buddy: species is one of the 5 launch species" {
  source "$RNG_LIB"
  roll_buddy 0 >/dev/null
  local species
  species="$(jq -r '.species' <<< "$_RNG_ROLL")"
  case "$species" in
    axolotl|dragon|owl|ghost|capybara) ;;
    *) echo "unexpected species: $species"; return 1 ;;
  esac
}

@test "roll_buddy: rarity and stats floor are internally consistent" {
  source "$RNG_LIB"
  declare -A floor=([common]=5 [uncommon]=15 [rare]=25 [epic]=35 [legendary]=50)
  local i
  for (( i = 0; i < 100; i++ )); do
    roll_buddy 0 >/dev/null
    local rarity min
    rarity="$(jq -r '.rarity' <<< "$_RNG_ROLL")"
    min="$(jq -r '[.stats.debugging, .stats.patience, .stats.chaos, .stats.wisdom, .stats.snark] | min' <<< "$_RNG_ROLL")"
    (( min >= ${floor[$rarity]} )) || {
      echo "mismatch at i=$i: rarity=$rarity min=$min floor=${floor[$rarity]} json=$_RNG_ROLL"
      return 1
    }
  done
}

@test "roll_buddy: pity propagates — pity=10 produces Rare+ 200/200 times" {
  source "$RNG_LIB"
  local i
  for (( i = 0; i < 200; i++ )); do
    roll_buddy 10 >/dev/null
    local rarity
    rarity="$(jq -r '.rarity' <<< "$_RNG_ROLL")"
    case "$rarity" in
      rare|epic|legendary) ;;
      *) echo "pity leaked $rarity at i=$i"; return 1 ;;
    esac
  done
}

@test "roll_buddy: name is from the rolled species' name_pool" {
  source "$RNG_LIB"
  roll_buddy 0 >/dev/null
  local species name
  species="$(jq -r '.species' <<< "$_RNG_ROLL")"
  name="$(jq -r '.name' <<< "$_RNG_ROLL")"
  run jq -e --arg n "$name" '.name_pool | index($n) != null' "$SPECIES_DIR/$species.json"
  [ "$status" -eq 0 ]
}

@test "roll_buddy: invalid pity returns error" {
  source "$RNG_LIB"
  run --separate-stderr roll_buddy foo
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"invalid pity_counter"* ]]
}

@test "roll_buddy: missing species dir causes failure before stdout emission" {
  export BUDDY_SPECIES_DIR="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$BUDDY_SPECIES_DIR"
  source "$RNG_LIB"
  run --separate-stderr roll_buddy 0
  [ "$status" -ne 0 ]
  [ -z "$output" ] || { echo "leaked partial output: $output"; return 1; }
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
