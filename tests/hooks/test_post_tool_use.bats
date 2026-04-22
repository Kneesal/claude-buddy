#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load ../test_helper

# Pre-compute seed-42 hatch once per file (see test_helper.bash).
setup_file() {
  _prepare_hatched_cache
}

POST_SH="$REPO_ROOT/hooks/post-tool-use.sh"

_payload() {
  local sid="$1" tcid="$2"
  jq -n --arg s "$sid" --arg t "$tcid" \
    '{hook_event_name: "PostToolUse", session_id: $s, tool_use_id: $t}'
}

_fire() {
  local sid="$1" tcid="$2"
  _payload "$sid" "$tcid" | "$POST_SH"
}

_ring() {
  local sid="$1"
  jq -rc '.recentToolCallIds' "$CLAUDE_PLUGIN_DATA/session-$sid.json"
}

# ------------------------------------------------------------
# Happy path
# ------------------------------------------------------------

@test "post-tool-use: ACTIVE + fresh session creates ring and emits first_edit" {
  _seed_hatch 42
  run _fire "sess-a" "tu_1"
  [ "$status" -eq 0 ]
  # First PTU of the session emits a first_edit-bank line (P3-2).
  [ -n "$output" ]
  [[ "$output" =~ :\ \".+\"$ ]]
  [ -f "$CLAUDE_PLUGIN_DATA/session-sess-a.json" ]
  run _ring "sess-a"
  [ "$output" = '["tu_1"]' ]
}

@test "post-tool-use: duplicate id is a no-op (ring unchanged)" {
  _seed_hatch 42
  _fire "sess-a" "tu_1"
  run _fire "sess-a" "tu_1"
  [ "$status" -eq 0 ]
  # Behavioral assertion: ring content + length unchanged after the
  # duplicate fire. hook_ring_update returns "DEDUP" internally so no
  # session_save is issued, but the user-observable contract is the
  # ring itself — which this assertion proves directly.
  run _ring "sess-a"
  [ "$output" = '["tu_1"]' ]
  run jq -r '.recentToolCallIds | length' "$CLAUDE_PLUGIN_DATA/session-sess-a.json"
  [ "$output" = "1" ]
}

@test "post-tool-use: eviction keeps last 20 in insertion order" {
  _seed_hatch 42
  for i in $(seq 1 25); do
    _fire "sess-b" "tu_$i"
  done
  run jq -r '.recentToolCallIds | length' "$CLAUDE_PLUGIN_DATA/session-sess-b.json"
  [ "$output" = "20" ]
  run jq -r '.recentToolCallIds[0]' "$CLAUDE_PLUGIN_DATA/session-sess-b.json"
  [ "$output" = "tu_6" ]
  run jq -r '.recentToolCallIds[-1]' "$CLAUDE_PLUGIN_DATA/session-sess-b.json"
  [ "$output" = "tu_25" ]
}

@test "post-tool-use: missing session file is re-initialized (defensive)" {
  _seed_hatch 42
  [ ! -f "$CLAUDE_PLUGIN_DATA/session-sess-d.json" ]
  run _fire "sess-d" "tu_1"
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_PLUGIN_DATA/session-sess-d.json" ]
  run jq -r '.schemaVersion' "$CLAUDE_PLUGIN_DATA/session-sess-d.json"
  [ "$output" = "1" ]
  run jq -r '.sessionId' "$CLAUDE_PLUGIN_DATA/session-sess-d.json"
  [ "$output" = "sess-d" ]
}

# ------------------------------------------------------------
# NO_BUDDY — pre-hatch passive
# ------------------------------------------------------------

@test "post-tool-use: NO_BUDDY writes no session file" {
  run _fire "sess-np" "tu_1"
  [ "$status" -eq 0 ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/session-sess-np.json" ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/error.log" ]
}

# ------------------------------------------------------------
# Payload failure paths — always exit 0
# ------------------------------------------------------------

@test "post-tool-use: missing tool_use_id logs + exits 0" {
  _seed_hatch 42
  run bash -c 'echo "{\"session_id\":\"sess-z\"}" | "'"$POST_SH"'"'
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_PLUGIN_DATA/error.log" ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/session-sess-z.json" ]
}

@test "post-tool-use: missing session_id logs + exits 0" {
  _seed_hatch 42
  run bash -c 'echo "{\"tool_use_id\":\"tu_1\"}" | "'"$POST_SH"'"'
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_PLUGIN_DATA/error.log" ]
}

@test "post-tool-use: shell-metachar tool_use_id is opaque (no injection)" {
  _seed_hatch 42
  run _fire "sess-m" '$(rm -rf /)'
  [ "$status" -eq 0 ]
  run jq -rc '.recentToolCallIds' "$CLAUDE_PLUGIN_DATA/session-sess-m.json"
  [ "$output" = '["$(rm -rf /)"]' ]
}

@test "post-tool-use: CORRUPT state logs + no session write" {
  _seed_corrupt
  run _fire "sess-c" "tu_1"
  [ "$status" -eq 0 ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/session-sess-c.json" ]
  [ -f "$CLAUDE_PLUGIN_DATA/error.log" ]
}

# ------------------------------------------------------------
# Falls back to legacy field name
# ------------------------------------------------------------

@test "post-tool-use: CLAUDE_PLUGIN_DATA unset → exits 0" {
  unset CLAUDE_PLUGIN_DATA
  run _fire "sess-u" "tu_1"
  [ "$status" -eq 0 ]
}

@test "post-tool-use: FUTURE_VERSION state logs + no session write" {
  _seed_future_version
  run _fire "sess-fv" "tu_1"
  [ "$status" -eq 0 ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/session-sess-fv.json" ]
  [ -f "$CLAUDE_PLUGIN_DATA/error.log" ]
}

@test "post-tool-use: session_save failure (unwritable dir) logs + exits 0" {
  _seed_hatch 42
  chmod 555 "$CLAUDE_PLUGIN_DATA"
  run _fire "sess-sf" "tu_1"
  # Restore so bats teardown can clean up.
  chmod 755 "$CLAUDE_PLUGIN_DATA"
  [ "$status" -eq 0 ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/session-sess-sf.json" ]
}

@test "post-tool-use: pre-seeded future-versioned session file is tolerated" {
  _seed_hatch 42
  # A session file with schemaVersion:2 written by a hypothetical future
  # plugin. session_load has no schema check; tool-event should tolerate
  # the envelope and push onto the ring. The upgrade seam is load-bearing.
  echo '{"schemaVersion":2,"sessionId":"sess-v2","startedAt":"2030-01-01T00:00:00Z","cooldowns":{},"recentToolCallIds":["keep1"]}' \
    > "$CLAUDE_PLUGIN_DATA/session-sess-v2.json"
  run _fire "sess-v2" "tu_new"
  [ "$status" -eq 0 ]
  run jq -rc '.recentToolCallIds' "$CLAUDE_PLUGIN_DATA/session-sess-v2.json"
  # Existing entry preserved + new one appended.
  [ "$output" = '["keep1","tu_new"]' ]
}

@test "post-tool-use: accepts legacy tool_call_id field" {
  _seed_hatch 42
  run bash -c 'jq -n "{hook_event_name: \"PostToolUse\", session_id: \"sess-l\", tool_call_id: \"tc_1\"}" | "'"$POST_SH"'"'
  [ "$status" -eq 0 ]
  run jq -rc '.recentToolCallIds' "$CLAUDE_PLUGIN_DATA/session-sess-l.json"
  [ "$output" = '["tc_1"]' ]
}

# ------------------------------------------------------------
# Commentary wiring (P3-2)
# ------------------------------------------------------------

@test "post-tool-use: novelty gate silences the second consecutive emit" {
  _seed_hatch 42
  # First fire emits.
  run _fire "sess-nv" "tu_1"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # Second fire same event type → silenced, budget unchanged.
  run _fire "sess-nv" "tu_2"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -r '.commentsThisSession' "$CLAUDE_PLUGIN_DATA/session-sess-nv.json"
  [ "$output" = "1" ]
}

@test "post-tool-use: burst 100 fires in 1 second yields ≤3 emits" {
  _seed_hatch 42
  # Precondition match: exit criterion from the ticket. 100 tool uses
  # in <60s must produce ≤3 comments. We run 100 fires back-to-back
  # with unique IDs so dedup doesn't mask the rate-limit behavior.
  local emits=0 i
  for i in $(seq 1 100); do
    local line
    line="$(_fire "sess-burst" "tu_$i")"
    [[ -n "$line" ]] && emits=$((emits + 1))
  done
  # Cooldown math: fire 1 immediate, fire 2 blocked (<5min), so even
  # 100 fires within seconds should produce exactly 1. The ≤3 ticket
  # target is an upper bound.
  [ "$emits" -le 3 ]
  # And the ring still holds 20, not 100.
  run jq -r '.recentToolCallIds | length' "$CLAUDE_PLUGIN_DATA/session-sess-burst.json"
  [ "$output" = "20" ]
}

@test "post-tool-use: NO_BUDDY suppresses commentary too" {
  run _fire "sess-nb" "tu_1"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ------------------------------------------------------------
# P4-1: signals + XP + level-up + repeated-edit + lock nesting
# ------------------------------------------------------------

# Fire with a richer payload that carries tool_name and file_path so
# the signals / repeatedEditHits code paths can be exercised.
_fire_with_tool() {
  local sid="$1" tcid="$2" tool="$3" file="$4"
  jq -n --arg s "$sid" --arg t "$tcid" --arg n "$tool" --arg f "$file" '
    { hook_event_name: "PostToolUse",
      session_id: $s,
      tool_use_id: $t,
      tool_name: $n,
      tool_input: { file_path: $f }
    }' | "$POST_SH"
}

@test "post-tool-use: P4-1 signals land on buddy.json after a successful fire" {
  _seed_hatch 42
  _fire_with_tool "sess-sig" "tu_1" "Edit" "/workspace/a.txt" >/dev/null
  local buddy_file="$CLAUDE_PLUGIN_DATA/buddy.json"
  # XP advanced: first-of-day → 2 PTU + 10 streak = 12.
  [ "$(jq -r '.buddy.xp' "$buddy_file")" = "12" ]
  # Streak reset + bumped to 1 (sentinel 1970-01-01 → 1).
  [ "$(jq -r '.buddy.signals.consistency.streakDays' "$buddy_file")" = "1" ]
  # Tool recorded in variety.toolsUsed.
  [ "$(jq -r '.buddy.signals.variety.toolsUsed.Edit | type' "$buddy_file")" = "number" ]
  # quality.successfulEdits and totalEdits both bumped (Edit is an edit tool).
  [ "$(jq -r '.buddy.signals.quality.successfulEdits' "$buddy_file")" = "1" ]
  [ "$(jq -r '.buddy.signals.quality.totalEdits' "$buddy_file")" = "1" ]
  # Session's lastToolFilePath captured.
  [ "$(jq -r '.lastToolFilePath' "$CLAUDE_PLUGIN_DATA/session-sess-sig.json")" = "/workspace/a.txt" ]
}

@test "post-tool-use: P4-1 repeatedEditHits bumps on consecutive same-file Edits" {
  _seed_hatch 42
  _fire_with_tool "sess-rep" "tu_1" "Edit" "/workspace/foo.txt" >/dev/null
  local buddy_file="$CLAUDE_PLUGIN_DATA/buddy.json"
  # First fire: no prior path → no match.
  [ "$(jq -r '.buddy.signals.chaos.repeatedEditHits' "$buddy_file")" = "0" ]
  _fire_with_tool "sess-rep" "tu_2" "Edit" "/workspace/foo.txt" >/dev/null
  # Second fire on same file: repeatedEditHits bumps.
  [ "$(jq -r '.buddy.signals.chaos.repeatedEditHits' "$buddy_file")" = "1" ]
}

@test "post-tool-use: P4-1 Bash (non-edit) does not bump quality or chaos" {
  _seed_hatch 42
  _fire_with_tool "sess-b" "tu_1" "Bash" "" >/dev/null
  local buddy_file="$CLAUDE_PLUGIN_DATA/buddy.json"
  [ "$(jq -r '.buddy.signals.quality.successfulEdits' "$buddy_file")" = "0" ]
  [ "$(jq -r '.buddy.signals.chaos.repeatedEditHits' "$buddy_file")" = "0" ]
  # Bash is still recorded in variety.toolsUsed.
  [ "$(jq -r '.buddy.signals.variety.toolsUsed.Bash | type' "$buddy_file")" = "number" ]
}

@test "post-tool-use: P4-1 level-up fires a LevelUp commentary line" {
  _seed_hatch 42
  local buddy_file="$CLAUDE_PLUGIN_DATA/buddy.json"
  # Pre-seed XP close to threshold AND lastActiveDay = today so no
  # streak bonus is paid; +2 PTU carries xp from 99 to 101 → Lv 2.
  local today
  today="$(date -u +%Y-%m-%d)"
  local signals
  signals='{"consistency":{"streakDays":1,"lastActiveDay":"'"$today"'"},"variety":{"toolsUsed":{}},"quality":{"successfulEdits":0,"totalEdits":0},"chaos":{"errors":0,"repeatedEditHits":0}}'
  local tmp
  tmp="$(mktemp "$CLAUDE_PLUGIN_DATA/.seed.XXX")"
  jq --argjson sig "$signals" '.buddy.xp = 99 | .buddy.level = 1 | .buddy.signals = $sig' "$buddy_file" > "$tmp"
  mv -f "$tmp" "$buddy_file"

  # Synthesize a minimal LevelUp bank via BUDDY_SPECIES_DIR override
  # so the real species files stay untouched (Unit 5 ships the real
  # content).
  local species_dir="$BATS_TEST_TMPDIR/species"
  mkdir -p "$species_dir"
  jq '.line_banks.LevelUp = { default: ["level up line"] }' "$REPO_ROOT/scripts/species/axolotl.json" > "$species_dir/axolotl.json"
  local s
  for s in dragon owl ghost capybara; do
    cp "$REPO_ROOT/scripts/species/${s}.json" "$species_dir/${s}.json"
  done
  export BUDDY_SPECIES_DIR="$species_dir"

  run _fire_with_tool "sess-lu" "tu_1" "Bash" ""
  [ "$status" -eq 0 ]
  # Output is the LevelUp line, not the PTU default-bank line.
  [[ "$output" == *"level up line"* ]]
  # Buddy advanced.
  [ "$(jq -r '.buddy.level' "$buddy_file")" = "2" ]
  [ "$(jq -r '.buddy.xp' "$buddy_file")" = "101" ]

  unset BUDDY_SPECIES_DIR
}

@test "post-tool-use: P4-1 lock ordering — buddy.json.lock exists after a fire" {
  _seed_hatch 42
  _fire_with_tool "sess-lk" "tu_1" "Bash" "" >/dev/null
  # Both lock files should exist after the fire (released but not unlinked).
  [ -f "$CLAUDE_PLUGIN_DATA/session-sess-lk.json.lock" ]
  [ -f "$CLAUDE_PLUGIN_DATA/buddy.json.lock" ]
}

@test "post-tool-use: P4-1 concurrent dual-fire does not lose XP among survivors" {
  _seed_hatch 42
  local buddy_file="$CLAUDE_PLUGIN_DATA/buddy.json"
  # Ten concurrent PTU fires with unique tool_use_ids. The flock
  # timeout is 0.2s; under contention some tail fires may time out
  # cleanly and log without writing state. The invariant we enforce
  # is that EVERY fire that made it into the ring ALSO landed its
  # XP delta — no lost updates for the survivors.
  local i
  for i in $(seq 1 10); do
    _fire_with_tool "sess-cc" "tu_$i" "Bash" "" &
  done
  wait
  local ring_len xp
  ring_len="$(jq -r '.recentToolCallIds | length' "$CLAUDE_PLUGIN_DATA/session-sess-cc.json")"
  xp="$(jq -r '.buddy.xp' "$buddy_file")"
  # Expected: first survivor pays +12 (streak bonus), rest pay +2 each.
  local expected=$(( 12 + (ring_len - 1) * 2 ))
  [ "$xp" = "$expected" ]
  # At least a few survivors — if ALL timed out, something is
  # structurally wrong beyond contention.
  (( ring_len >= 3 ))
}
