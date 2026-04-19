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
