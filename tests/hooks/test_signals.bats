#!/usr/bin/env bats
# test_signals.bats — P4-1 Unit 3 tests for scripts/hooks/signals.sh.
#
# hook_signals_apply is the fused signals/XP/level-up evaluator. Tests
# exercise every XP rule, every signal axis, the streak boundary logic,
# level-up sentinel emission, lazy-init of the signals skeleton, and
# the error-path two-line contract.

bats_require_minimum_version 1.5.0

load ../test_helper

SIGNALS_LIB="$REPO_ROOT/scripts/hooks/signals.sh"
EVOLUTION_LIB="$REPO_ROOT/scripts/lib/evolution.sh"

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------

# Build a minimal buddy envelope JSON with the given xp, level, and
# optional signals block (pass "" for lazy-init testing).
_mk_buddy() {
  local xp="${1:-0}"
  local level="${2:-1}"
  local signals="${3:-}"
  if [[ -n "$signals" ]]; then
    jq -n -c --argjson xp "$xp" --argjson lvl "$level" --argjson sig "$signals" '
      { schemaVersion: 1,
        buddy: { id:"abc", name:"Test", species:"axolotl", rarity:"common",
                 stats:{}, form:"base", level: $lvl, xp: $xp, signals: $sig } }'
  else
    jq -n -c --argjson xp "$xp" --argjson lvl "$level" '
      { schemaVersion: 1,
        buddy: { id:"abc", name:"Test", species:"axolotl", rarity:"common",
                 stats:{}, form:"base", level: $lvl, xp: $xp } }'
  fi
}

# Build an event_inputs JSON object with the given named overrides.
# Defaults are "no-op": empty toolName, no file match, Bash-like tool,
# now = a fixed reference epoch, today = the matching UTC date.
_mk_inputs() {
  # Defaults
  local toolName="" filePath="" matchedLast="false" isEditTool="false"
  local now="1745193600"                  # 2026-04-21 00:00:00 UTC
  local today="2026-04-21" todayEpoch="1745193600"
  local hours="0"
  # Parse named overrides
  while (( $# )); do
    case "$1" in
      tool=*)        toolName="${1#tool=}" ;;
      file=*)        filePath="${1#file=}" ;;
      matched=*)     matchedLast="${1#matched=}" ;;
      isEdit=*)      isEditTool="${1#isEdit=}" ;;
      now=*)         now="${1#now=}" ;;
      today=*)       today="${1#today=}" ;;
      todayEpoch=*)  todayEpoch="${1#todayEpoch=}" ;;
      hours=*)       hours="${1#hours=}" ;;
      *) echo "bad _mk_inputs arg: $1" >&2; return 1 ;;
    esac
    shift
  done
  jq -n -c \
    --arg tool "$toolName" \
    --arg file "$filePath" \
    --argjson matched "$matchedLast" \
    --argjson isEdit "$isEditTool" \
    --argjson now "$now" \
    --arg today "$today" \
    --argjson todayEpoch "$todayEpoch" \
    --argjson hours "$hours" '
    { toolName: $tool, filePath: $file,
      filePathMatchedLast: $matched, isEditTool: $isEdit,
      now: $now, today: $today, todayEpoch: $todayEpoch,
      sessionActiveHours: $hours }'
}

# Split hook_signals_apply two-line stdout into sentinel + buddy.
_split_signals_out() {
  local out="$1"
  sentinel="${out%%$'\n'*}"
  buddy_out="${out#*$'\n'}"
}

_invoke_signals() {
  source "$SIGNALS_LIB"
  hook_signals_apply "$@"
}

# -------------------------------------------------------------------
# Library hygiene
# -------------------------------------------------------------------

@test "signals.sh: sources cleanly without leaking set -e" {
  run bash -c 'source "'"$SIGNALS_LIB"'"; false | true || exit 13; echo ok'
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "signals.sh: re-sourcing does not redeclare readonly" {
  run bash -c '
    source "'"$SIGNALS_LIB"'"
    source "'"$SIGNALS_LIB"'" 2>&1
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"readonly variable"* ]]
}

# -------------------------------------------------------------------
# PTU happy path — Bash tool, first-of-day
# -------------------------------------------------------------------

@test "PTU + Bash, first-of-day: tool recorded, streakDays=1, XP=2+10 bonus" {
  local buddy inputs out
  buddy="$(_mk_buddy 0 1)"
  inputs="$(_mk_inputs tool=Bash now=1745193600 today=2026-04-21 todayEpoch=1745193600)"
  out="$(_invoke_signals PostToolUse "$buddy" "$inputs")"
  _split_signals_out "$out"
  [ "$sentinel" = "" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.xp')" = "12" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.level')" = "1" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.consistency.streakDays')" = "1" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.consistency.lastActiveDay')" = "2026-04-21" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.variety.toolsUsed.Bash')" = "1745193600" ]
  # Bash isn't an edit tool: quality counters unchanged.
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.quality.successfulEdits')" = "0" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.quality.totalEdits')" = "0" ]
  # No match: chaos unchanged.
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.chaos.repeatedEditHits')" = "0" ]
}

@test "PTU + Edit, same-day (no streak bonus): quality bumps, XP=2" {
  local sig buddy inputs out
  # Signals already show a streak today — no bonus this fire.
  sig='{"consistency":{"streakDays":3,"lastActiveDay":"2026-04-21"},"variety":{"toolsUsed":{}},"quality":{"successfulEdits":5,"totalEdits":5},"chaos":{"errors":0,"repeatedEditHits":0}}'
  buddy="$(_mk_buddy 0 1 "$sig")"
  inputs="$(_mk_inputs tool=Edit isEdit=true)"
  out="$(_invoke_signals PostToolUse "$buddy" "$inputs")"
  _split_signals_out "$out"
  [ "$(echo "$buddy_out" | jq -r '.buddy.xp')" = "2" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.consistency.streakDays')" = "3" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.quality.successfulEdits')" = "6" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.quality.totalEdits')" = "6" ]
}

@test "PTU + Edit with filePathMatchedLast: repeatedEditHits++" {
  local buddy inputs out
  buddy="$(_mk_buddy 0 1)"
  inputs="$(_mk_inputs tool=Edit isEdit=true file=/a.txt matched=true)"
  out="$(_invoke_signals PostToolUse "$buddy" "$inputs")"
  _split_signals_out "$out"
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.chaos.repeatedEditHits')" = "1" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.quality.successfulEdits')" = "1" ]
}

@test "PTU + Edit without match: repeatedEditHits unchanged" {
  local buddy inputs out
  buddy="$(_mk_buddy 0 1)"
  inputs="$(_mk_inputs tool=Edit isEdit=true file=/a.txt matched=false)"
  out="$(_invoke_signals PostToolUse "$buddy" "$inputs")"
  _split_signals_out "$out"
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.chaos.repeatedEditHits')" = "0" ]
}

# -------------------------------------------------------------------
# PTUF — errors
# -------------------------------------------------------------------

@test "PTUF: errors++, totalEdits++, XP=1 (+streak bonus first-of-day)" {
  local buddy inputs out
  buddy="$(_mk_buddy 0 1)"
  inputs="$(_mk_inputs tool=Bash)"
  out="$(_invoke_signals PostToolUseFailure "$buddy" "$inputs")"
  _split_signals_out "$out"
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.chaos.errors')" = "1" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.quality.totalEdits')" = "1" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.quality.successfulEdits')" = "0" ]
  # 1 base + 10 streak bonus = 11 (first-of-day lazy-init sentinel resets to bonus path)
  [ "$(echo "$buddy_out" | jq -r '.buddy.xp')" = "11" ]
}

@test "PTUF: same-day fire pays +1 XP alone, no streak bonus" {
  # Isolates the PTUF XP delta from the streak bonus so a regression
  # that misapplies +10 to same-day PTUF would fail this test but pass
  # the first-of-day variant above.
  local sig buddy inputs out
  sig='{"consistency":{"streakDays":2,"lastActiveDay":"2026-04-21"},"variety":{"toolsUsed":{}},"quality":{"successfulEdits":0,"totalEdits":0},"chaos":{"errors":0,"repeatedEditHits":0}}'
  buddy="$(_mk_buddy 0 1 "$sig")"
  inputs="$(_mk_inputs today=2026-04-21 todayEpoch=1745193600)"
  out="$(_invoke_signals PostToolUseFailure "$buddy" "$inputs")"
  _split_signals_out "$out"
  [ "$(echo "$buddy_out" | jq -r '.buddy.xp')" = "1" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.consistency.streakDays')" = "2" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.chaos.errors')" = "1" ]
}

# -------------------------------------------------------------------
# Stop — base + per-hour XP
# -------------------------------------------------------------------

@test "Stop + 65min session: XP = 5 base + 2*1 per-hour + 10 streak = 17" {
  local buddy inputs out
  buddy="$(_mk_buddy 0 1)"
  inputs="$(_mk_inputs hours=1.0833)"
  out="$(_invoke_signals Stop "$buddy" "$inputs")"
  _split_signals_out "$out"
  # 5 base + 2*floor(1.0833)=2 + 10 streak (first-of-day) = 17
  [ "$(echo "$buddy_out" | jq -r '.buddy.xp')" = "17" ]
}

@test "Stop + sub-hour session: per-hour term is zero" {
  local sig buddy inputs out
  sig='{"consistency":{"streakDays":1,"lastActiveDay":"2026-04-21"},"variety":{"toolsUsed":{}},"quality":{"successfulEdits":0,"totalEdits":0},"chaos":{"errors":0,"repeatedEditHits":0}}'
  buddy="$(_mk_buddy 0 1 "$sig")"
  inputs="$(_mk_inputs hours=0.5)"
  out="$(_invoke_signals Stop "$buddy" "$inputs")"
  _split_signals_out "$out"
  [ "$(echo "$buddy_out" | jq -r '.buddy.xp')" = "5" ]  # no streak bonus, no per-hour
}

@test "Stop: quality/chaos/variety unchanged (only XP + streak)" {
  local sig buddy inputs out
  sig='{"consistency":{"streakDays":1,"lastActiveDay":"2026-04-21"},"variety":{"toolsUsed":{"Edit":1000}},"quality":{"successfulEdits":10,"totalEdits":10},"chaos":{"errors":2,"repeatedEditHits":1}}'
  buddy="$(_mk_buddy 0 1 "$sig")"
  # Same-day so no streak bonus — isolates Stop from streak logic.
  inputs="$(_mk_inputs today=2026-04-21 todayEpoch=1745193600)"
  out="$(_invoke_signals Stop "$buddy" "$inputs")"
  _split_signals_out "$out"
  # Edit entry may or may not be pruned depending on now vs 1000 epoch
  # (it's far older than 7 days). Just assert the counters we care about.
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.quality.successfulEdits')" = "10" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.quality.totalEdits')" = "10" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.chaos.errors')" = "2" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.chaos.repeatedEditHits')" = "1" ]
}

# -------------------------------------------------------------------
# Streak boundary
# -------------------------------------------------------------------

@test "Streak: continuation (yesterday → today) increments and pays bonus" {
  local sig buddy inputs out
  sig='{"consistency":{"streakDays":3,"lastActiveDay":"2026-04-20"},"variety":{"toolsUsed":{}},"quality":{"successfulEdits":0,"totalEdits":0},"chaos":{"errors":0,"repeatedEditHits":0}}'
  buddy="$(_mk_buddy 0 1 "$sig")"
  inputs="$(_mk_inputs today=2026-04-21 todayEpoch=1745193600)"
  out="$(_invoke_signals PostToolUse "$buddy" "$inputs")"
  _split_signals_out "$out"
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.consistency.streakDays')" = "4" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.consistency.lastActiveDay')" = "2026-04-21" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.xp')" = "12" ]  # 2 PTU + 10 streak
}

@test "Streak: gap > 1 day resets to 1 and pays bonus" {
  local sig buddy inputs out
  sig='{"consistency":{"streakDays":9,"lastActiveDay":"2026-04-18"},"variety":{"toolsUsed":{}},"quality":{"successfulEdits":0,"totalEdits":0},"chaos":{"errors":0,"repeatedEditHits":0}}'
  buddy="$(_mk_buddy 0 1 "$sig")"
  inputs="$(_mk_inputs today=2026-04-21 todayEpoch=1745193600)"
  out="$(_invoke_signals PostToolUse "$buddy" "$inputs")"
  _split_signals_out "$out"
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.consistency.streakDays')" = "1" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.consistency.lastActiveDay')" = "2026-04-21" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.xp')" = "12" ]  # bonus applies
}

@test "Streak: same-day no-op leaves streak unchanged, no bonus" {
  local sig buddy inputs out
  sig='{"consistency":{"streakDays":7,"lastActiveDay":"2026-04-21"},"variety":{"toolsUsed":{}},"quality":{"successfulEdits":0,"totalEdits":0},"chaos":{"errors":0,"repeatedEditHits":0}}'
  buddy="$(_mk_buddy 0 1 "$sig")"
  inputs="$(_mk_inputs today=2026-04-21 todayEpoch=1745193600)"
  out="$(_invoke_signals PostToolUse "$buddy" "$inputs")"
  _split_signals_out "$out"
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.consistency.streakDays')" = "7" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.xp')" = "2" ]
}

@test "Streak: sentinel 1970-01-01 on first-ever fire resets to 1 with bonus" {
  local buddy inputs out
  buddy="$(_mk_buddy 0 1)"  # lazy-init
  inputs="$(_mk_inputs today=2026-04-21 todayEpoch=1745193600)"
  out="$(_invoke_signals PostToolUse "$buddy" "$inputs")"
  _split_signals_out "$out"
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.consistency.streakDays')" = "1" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.consistency.lastActiveDay')" = "2026-04-21" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.xp')" = "12" ]
}

@test "Streak: crossing midnight UTC within the same real session advances the streak" {
  # Two consecutive fires with today strings on adjacent calendar days
  # (what the hook derives from `date -u +%Y-%m-%d`). Proves the day
  # boundary is UTC-coherent end-to-end, not just inside the filter.
  local buddy inputs_day1 out1 buddy_mid inputs_day2 out2
  buddy="$(_mk_buddy 0 1)"
  inputs_day1="$(_mk_inputs today=2026-04-21)"
  out1="$(_invoke_signals PostToolUse "$buddy" "$inputs_day1")"
  _split_signals_out "$out1"
  buddy_mid="$buddy_out"
  [ "$(echo "$buddy_mid" | jq -r '.buddy.signals.consistency.streakDays')" = "1" ]

  # Second fire is the very next UTC day.
  inputs_day2="$(_mk_inputs today=2026-04-22)"
  out2="$(_invoke_signals PostToolUse "$buddy_mid" "$inputs_day2")"
  _split_signals_out "$out2"
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.consistency.streakDays')" = "2" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.consistency.lastActiveDay')" = "2026-04-22" ]
  # First fire: 0 + 2 PTU + 10 streak = 12.
  # Second fire: 12 + 2 PTU + 10 streak (day advance) = 24.
  [ "$(echo "$buddy_out" | jq -r '.buddy.xp')" = "24" ]
}

# -------------------------------------------------------------------
# Level-up
# -------------------------------------------------------------------

@test "Level-up: xp=98 + PTU +2 crosses Lv 2 threshold, sentinel fires" {
  local sig buddy inputs out
  sig='{"consistency":{"streakDays":1,"lastActiveDay":"2026-04-21"},"variety":{"toolsUsed":{}},"quality":{"successfulEdits":0,"totalEdits":0},"chaos":{"errors":0,"repeatedEditHits":0}}'
  buddy="$(_mk_buddy 98 1 "$sig")"
  inputs="$(_mk_inputs tool=Bash today=2026-04-21 todayEpoch=1745193600)"
  out="$(_invoke_signals PostToolUse "$buddy" "$inputs")"
  _split_signals_out "$out"
  [ "$sentinel" = "LEVEL_UP:2" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.xp')" = "100" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.level')" = "2" ]
}

@test "Level-up: streak bonus alone can cross threshold" {
  local sig buddy inputs out
  # xp=89; PTU +2 + streak +10 = 101 → Lv 2
  sig='{"consistency":{"streakDays":3,"lastActiveDay":"2026-04-20"},"variety":{"toolsUsed":{}},"quality":{"successfulEdits":0,"totalEdits":0},"chaos":{"errors":0,"repeatedEditHits":0}}'
  buddy="$(_mk_buddy 89 1 "$sig")"
  inputs="$(_mk_inputs tool=Bash today=2026-04-21 todayEpoch=1745193600)"
  out="$(_invoke_signals PostToolUse "$buddy" "$inputs")"
  _split_signals_out "$out"
  [ "$sentinel" = "LEVEL_UP:2" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.xp')" = "101" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.level')" = "2" ]
}

@test "Level-up: no sentinel when xp stays in same level" {
  local sig buddy inputs out
  sig='{"consistency":{"streakDays":1,"lastActiveDay":"2026-04-21"},"variety":{"toolsUsed":{}},"quality":{"successfulEdits":0,"totalEdits":0},"chaos":{"errors":0,"repeatedEditHits":0}}'
  buddy="$(_mk_buddy 50 1 "$sig")"
  inputs="$(_mk_inputs tool=Bash today=2026-04-21 todayEpoch=1745193600)"
  out="$(_invoke_signals PostToolUse "$buddy" "$inputs")"
  _split_signals_out "$out"
  [ "$sentinel" = "" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.level')" = "1" ]
}

@test "Level-up: MAX_LEVEL cap — xp past cap does not advance level" {
  local sig buddy inputs out
  sig='{"consistency":{"streakDays":1,"lastActiveDay":"2026-04-21"},"variety":{"toolsUsed":{}},"quality":{"successfulEdits":0,"totalEdits":0},"chaos":{"errors":0,"repeatedEditHits":0}}'
  buddy="$(_mk_buddy 9999999 50 "$sig")"  # already at cap
  inputs="$(_mk_inputs tool=Bash today=2026-04-21 todayEpoch=1745193600)"
  out="$(_invoke_signals PostToolUse "$buddy" "$inputs")"
  _split_signals_out "$out"
  [ "$sentinel" = "" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.level')" = "50" ]
  # XP still accrues even at cap.
  [ "$(echo "$buddy_out" | jq -r '.buddy.xp')" = "10000001" ]
}

# -------------------------------------------------------------------
# Variety toolsUsed: set + prune
# -------------------------------------------------------------------

@test "Variety: entry older than 7 days is pruned on next write" {
  local sig buddy inputs out
  # Seeded with an ancient entry and a recent one; new fire with Edit.
  sig='{"consistency":{"streakDays":1,"lastActiveDay":"2026-04-21"},"variety":{"toolsUsed":{"AncientTool":1000,"Grep":1745193500}},"quality":{"successfulEdits":0,"totalEdits":0},"chaos":{"errors":0,"repeatedEditHits":0}}'
  buddy="$(_mk_buddy 0 1 "$sig")"
  inputs="$(_mk_inputs tool=Edit isEdit=true now=1745193600 today=2026-04-21 todayEpoch=1745193600)"
  out="$(_invoke_signals PostToolUse "$buddy" "$inputs")"
  _split_signals_out "$out"
  # Only AncientTool (epoch 1000 — ~1970) is older than 7 days; it's pruned.
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.variety.toolsUsed.AncientTool // "missing"')" = "missing" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.variety.toolsUsed.Grep')" = "1745193500" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.variety.toolsUsed.Edit')" = "1745193600" ]
}

@test "Variety: empty toolName does not create an empty-string key" {
  local buddy inputs out
  buddy="$(_mk_buddy 0 1)"
  inputs="$(_mk_inputs tool="")"
  out="$(_invoke_signals PostToolUse "$buddy" "$inputs")"
  _split_signals_out "$out"
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.variety.toolsUsed | length')" = "0" ]
}

# -------------------------------------------------------------------
# Lazy-init
# -------------------------------------------------------------------

@test "Lazy-init: buddy without .signals gets the skeleton populated" {
  local buddy inputs out
  buddy="$(_mk_buddy 0 1)"  # no signals field
  inputs="$(_mk_inputs tool=Bash today=2026-04-21 todayEpoch=1745193600)"
  out="$(_invoke_signals PostToolUse "$buddy" "$inputs")"
  _split_signals_out "$out"
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.consistency.streakDays')" = "1" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.quality.successfulEdits')" = "0" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.chaos.errors')" = "0" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.signals.variety.toolsUsed.Bash')" = "1745193600" ]
}

# -------------------------------------------------------------------
# Error paths
# -------------------------------------------------------------------

@test "Missing args: returns empty scalar + empty JSON, exit 1" {
  source "$SIGNALS_LIB"
  run hook_signals_apply
  [ "$status" -eq 1 ]
  # First line empty; no second line (just a trailing \n).
  [ "$output" = "" ]
}

@test "Malformed buddy JSON: returns empty sentinel + empty JSON" {
  local out sentinel buddy_out
  source "$SIGNALS_LIB"
  local inputs
  inputs="$(_mk_inputs tool=Bash)"
  out="$(hook_signals_apply PostToolUse "not-json" "$inputs")"
  _split_signals_out "$out"
  [ "$sentinel" = "" ]
  # buddy_out may be empty (jq failed) — caller's fallback handles it.
  [ -z "$buddy_out" ]
}

@test "Unknown event type: pass-through, no mutation" {
  local buddy inputs out
  buddy="$(_mk_buddy 0 1)"
  inputs="$(_mk_inputs tool=Bash)"
  out="$(_invoke_signals SomeUnknownEvent "$buddy" "$inputs")"
  _split_signals_out "$out"
  [ "$sentinel" = "" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.xp')" = "0" ]
  [ "$(echo "$buddy_out" | jq -r '.buddy.level')" = "1" ]
}

# -------------------------------------------------------------------
# Stdout contract
# -------------------------------------------------------------------

@test "Stdout contract: exactly one newline between sentinel and buddy JSON" {
  local buddy inputs out
  buddy="$(_mk_buddy 0 1)"
  inputs="$(_mk_inputs tool=Bash)"
  out="$(_invoke_signals PostToolUse "$buddy" "$inputs")"
  local nl_count
  nl_count="$(printf '%s' "$out" | tr -cd '\n' | wc -c)"
  [ "$nl_count" = "1" ]
}

@test "Stdout contract: buddy JSON (line 2) is valid JSON" {
  local buddy inputs out
  buddy="$(_mk_buddy 0 1)"
  inputs="$(_mk_inputs tool=Bash)"
  out="$(_invoke_signals PostToolUse "$buddy" "$inputs")"
  _split_signals_out "$out"
  echo "$buddy_out" | jq -e '.' >/dev/null
}

# -------------------------------------------------------------------
# Integration: chained PTU fires accumulate level + XP correctly
# -------------------------------------------------------------------

@test "Integration: 20 PTU fires same day reach expected XP" {
  source "$SIGNALS_LIB"
  local buddy inputs out
  buddy="$(_mk_buddy 0 1)"
  # First fire pays streak bonus; subsequent fires (same day) do not.
  inputs="$(_mk_inputs tool=Bash today=2026-04-21 todayEpoch=1745193600)"
  local i
  for (( i = 0; i < 20; i++ )); do
    out="$(hook_signals_apply PostToolUse "$buddy" "$inputs")"
    _split_signals_out "$out"
    buddy="$buddy_out"
  done
  # First fire: +12 (2 PTU + 10 streak). 19 same-day fires: +2 each = 38. Total = 50.
  [ "$(echo "$buddy" | jq -r '.buddy.xp')" = "50" ]
  [ "$(echo "$buddy" | jq -r '.buddy.level')" = "1" ]
  [ "$(echo "$buddy" | jq -r '.buddy.signals.consistency.streakDays')" = "1" ]
  [ "$(echo "$buddy" | jq -r '.buddy.signals.variety.toolsUsed.Bash')" = "1745193600" ]
}
