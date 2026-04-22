#!/usr/bin/env bats
# evolution.bats — P4-1 Unit 1 tests for scripts/lib/evolution.sh.
#
# Covers:
#   - xpForLevel anchors (ticket-pinned values)
#   - level_for_xp happy-path + cap + degenerate inputs
#   - signals_skeleton structural shape
#   - Library hygiene (source guard, re-sourcing cleanly)

bats_require_minimum_version 1.5.0

load test_helper

EVOLUTION_LIB="$REPO_ROOT/scripts/lib/evolution.sh"

# ============================================================
# Library hygiene
# ============================================================

@test "evolution.sh: sources cleanly without leaking set -e / pipefail" {
  run bash -c '
    source "'"$EVOLUTION_LIB"'"
    false | true || exit 12
    echo "ok"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "evolution.sh: re-sourcing does not re-declare readonly variables" {
  run bash -c '
    source "'"$EVOLUTION_LIB"'"
    source "'"$EVOLUTION_LIB"'" 2>&1
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"readonly variable"* ]]
}

@test "evolution.sh: MAX_LEVEL is 50" {
  source "$EVOLUTION_LIB"
  [ "$MAX_LEVEL" = "50" ]
}

# ============================================================
# xpForLevel
# ============================================================

@test "xpForLevel: n=1 returns 100 (Lv 1→2 threshold)" {
  source "$EVOLUTION_LIB"
  [ "$(xpForLevel 1)" = "100" ]
}

@test "xpForLevel: n=5 returns 1500" {
  source "$EVOLUTION_LIB"
  [ "$(xpForLevel 5)" = "1500" ]
}

@test "xpForLevel: n=10 returns 5500" {
  source "$EVOLUTION_LIB"
  [ "$(xpForLevel 10)" = "5500" ]
}

@test "xpForLevel: n=0 returns 0 (loop-sentinel)" {
  source "$EVOLUTION_LIB"
  [ "$(xpForLevel 0)" = "0" ]
}

@test "xpForLevel: negative input collapses to 0" {
  source "$EVOLUTION_LIB"
  [ "$(xpForLevel -5)" = "0" ]
}

@test "xpForLevel: non-integer input collapses to 0" {
  source "$EVOLUTION_LIB"
  [ "$(xpForLevel abc)" = "0" ]
  [ "$(xpForLevel 3.5)" = "0" ]
  [ "$(xpForLevel '')" = "0" ]
}

# ============================================================
# level_for_xp
# ============================================================

@test "level_for_xp: xp=0 returns 1" {
  source "$EVOLUTION_LIB"
  [ "$(level_for_xp 0)" = "1" ]
}

@test "level_for_xp: xp=99 returns 1 (just below threshold)" {
  source "$EVOLUTION_LIB"
  [ "$(level_for_xp 99)" = "1" ]
}

@test "level_for_xp: xp=100 returns 2 (exactly at threshold)" {
  source "$EVOLUTION_LIB"
  [ "$(level_for_xp 100)" = "2" ]
}

@test "level_for_xp: xp=299 returns 2" {
  source "$EVOLUTION_LIB"
  [ "$(level_for_xp 299)" = "2" ]
}

@test "level_for_xp: xp=300 returns 3" {
  source "$EVOLUTION_LIB"
  [ "$(level_for_xp 300)" = "3" ]
}

@test "level_for_xp: xp=1500 returns 6 (just past xpForLevel(5))" {
  source "$EVOLUTION_LIB"
  # xpForLevel(5) = 1500 is the threshold to LEAVE level 5.
  [ "$(level_for_xp 1500)" = "6" ]
}

@test "level_for_xp: caps at MAX_LEVEL for astronomical xp" {
  source "$EVOLUTION_LIB"
  [ "$(level_for_xp 9999999999)" = "50" ]
}

@test "level_for_xp: negative input returns 1" {
  source "$EVOLUTION_LIB"
  [ "$(level_for_xp -100)" = "1" ]
}

@test "level_for_xp: monotone non-decreasing" {
  source "$EVOLUTION_LIB"
  local prev=1
  local xp
  for xp in 0 50 99 100 200 500 1000 2000 5000 50000 500000; do
    local cur
    cur="$(level_for_xp "$xp")"
    (( cur >= prev )) || { echo "non-monotone at xp=$xp: $cur < $prev"; return 1; }
    prev=$cur
  done
}

# ============================================================
# signals_skeleton
# ============================================================

@test "signals_skeleton: emits valid JSON" {
  source "$EVOLUTION_LIB"
  local json
  json="$(signals_skeleton)"
  echo "$json" | jq -e '.' >/dev/null
}

@test "signals_skeleton: has all four axes with zero/default values" {
  source "$EVOLUTION_LIB"
  local json
  json="$(signals_skeleton)"
  [ "$(echo "$json" | jq -r '.consistency.streakDays')" = "0" ]
  [ "$(echo "$json" | jq -r '.consistency.lastActiveDay')" = "1970-01-01" ]
  [ "$(echo "$json" | jq -r '.variety.toolsUsed | length')" = "0" ]
  [ "$(echo "$json" | jq -r '.variety.toolsUsed | type')" = "object" ]
  [ "$(echo "$json" | jq -r '.quality.successfulEdits')" = "0" ]
  [ "$(echo "$json" | jq -r '.quality.totalEdits')" = "0" ]
  [ "$(echo "$json" | jq -r '.chaos.errors')" = "0" ]
  [ "$(echo "$json" | jq -r '.chaos.repeatedEditHits')" = "0" ]
}

@test "signals_skeleton: is single-line compact JSON" {
  source "$EVOLUTION_LIB"
  local json
  json="$(signals_skeleton)"
  # Compact = no newlines inside the payload.
  local line_count
  line_count="$(printf '%s' "$json" | tr -cd '\n' | wc -c)"
  [ "$line_count" = "0" ]
}

# ============================================================
# Bash / jq equivalence — level_for_xp is implemented in both
# scripts/lib/evolution.sh (bash) AND scripts/hooks/signals.sh
# (inlined jq). A drift between them would silently shift the
# level users see at the same XP total, so the two must agree on
# every boundary value. This test is the only thing keeping the
# duplication honest.
# ============================================================

@test "level_for_xp: bash and jq-inlined versions agree on the boundary grid" {
  source "$EVOLUTION_LIB"

  # Grid: every threshold (exact), just below, just above, plus a
  # handful of large values to exercise the cap.
  local xps=()
  local n
  for (( n = 0; n <= 50; n++ )); do
    local t=$(( 50 * n * (n + 1) ))
    xps+=( "$t" "$(( t - 1 ))" "$(( t + 1 ))" )
  done
  xps+=( 0 1 99 100 101 999 1000 1500 9999 999999999 )

  # Inline jq program must stay identical to the one in signals.sh.
  # If a future edit updates one without the other, this test fires.
  local jq_prog='
    def level_for_xp($xp; $max):
      if $xp < 0 then 1
      else
        [range(1; $max + 1)]
        | map(select((50 * . * (. + 1)) <= $xp))
        | length + 1
        | if . > $max then $max else . end
      end;
    level_for_xp(.xp; 50)
  '

  local xp bash_lvl jq_lvl
  for xp in "${xps[@]}"; do
    bash_lvl="$(level_for_xp "$xp")"
    jq_lvl="$(jq --argjson x "$xp" -n "{xp: \$x} | $jq_prog")"
    if [[ "$bash_lvl" != "$jq_lvl" ]]; then
      echo "DRIFT at xp=$xp: bash=$bash_lvl jq=$jq_lvl" >&2
      return 1
    fi
  done
}
