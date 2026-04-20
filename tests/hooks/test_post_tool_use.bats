#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load ../test_helper

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

@test "post-tool-use: ACTIVE + fresh session creates ring with first id" {
  _seed_hatch 42
  run _fire "sess-a" "tu_1"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
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
