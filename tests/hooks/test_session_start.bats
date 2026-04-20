#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load ../test_helper

SESSION_START_SH="$REPO_ROOT/hooks/session-start.sh"

# Helper: emit a well-formed SessionStart payload.
_payload() {
  local sid="${1:-sess-abc}"
  jq -n --arg sid "$sid" '{hook_event_name: "SessionStart", session_id: $sid}'
}

# Helper: count session-*.json files in the data dir.
_count_session_files() {
  find "$CLAUDE_PLUGIN_DATA" -maxdepth 1 -name 'session-*.json' 2>/dev/null | wc -l | tr -d ' '
}

# ------------------------------------------------------------
# Happy path
# ------------------------------------------------------------

@test "session-start: ACTIVE buddy + valid sid creates session file with canonical shape" {
  _seed_hatch 42
  run bash -c '_payload() { jq -n --arg sid "$1" "{hook_event_name: \"SessionStart\", session_id: \$sid}"; }; _payload "sess-one" | "'"$SESSION_START_SH"'"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$CLAUDE_PLUGIN_DATA/session-sess-one.json" ]
  local v sid cd_type ring_type
  v="$(jq -r '.schemaVersion' "$CLAUDE_PLUGIN_DATA/session-sess-one.json")"
  sid="$(jq -r '.sessionId' "$CLAUDE_PLUGIN_DATA/session-sess-one.json")"
  cd_type="$(jq -r '.cooldowns | type' "$CLAUDE_PLUGIN_DATA/session-sess-one.json")"
  ring_type="$(jq -r '.recentToolCallIds | type' "$CLAUDE_PLUGIN_DATA/session-sess-one.json")"
  [ "$v" = "1" ]
  [ "$sid" = "sess-one" ]
  [ "$cd_type" = "object" ]
  [ "$ring_type" = "array" ]
}

@test "session-start: re-init overwrites stale state" {
  _seed_hatch 42
  # Pre-existing stale session file with a populated ring.
  echo '{"schemaVersion":1,"sessionId":"sess-two","startedAt":"1999-01-01T00:00:00Z","cooldowns":{"x":"y"},"recentToolCallIds":["old1","old2"]}' \
    > "$CLAUDE_PLUGIN_DATA/session-sess-two.json"

  run bash -c '_payload() { jq -n --arg sid "$1" "{hook_event_name: \"SessionStart\", session_id: \$sid}"; }; _payload "sess-two" | "'"$SESSION_START_SH"'"'
  [ "$status" -eq 0 ]

  run jq -rc '.cooldowns' "$CLAUDE_PLUGIN_DATA/session-sess-two.json"
  [ "$output" = "{}" ]
  run jq -rc '.recentToolCallIds' "$CLAUDE_PLUGIN_DATA/session-sess-two.json"
  [ "$output" = "[]" ]
  run jq -r '.startedAt' "$CLAUDE_PLUGIN_DATA/session-sess-two.json"
  [ "$output" != "1999-01-01T00:00:00Z" ]
}

# ------------------------------------------------------------
# NO_BUDDY — fully passive per D6
# ------------------------------------------------------------

@test "session-start: NO_BUDDY creates no session file and no error log" {
  run bash -c '_p() { jq -n --arg s "$1" "{hook_event_name: \"SessionStart\", session_id: \$s}"; }; _p "sess-np" | "'"$SESSION_START_SH"'"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(_count_session_files)" = "0" ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/error.log" ]
}

@test "session-start: NO_BUDDY does NOT run orphan sweep" {
  # Drop a .tmp file well past the hard-age threshold; it should survive
  # pre-hatch. Using -A to set atime is belt-and-braces; mtime is the
  # important one for find's -mmin logic.
  local stale="$CLAUDE_PLUGIN_DATA/.tmp.9999.survivor"
  echo "stale" > "$stale"
  # Make it 25 hours old (past the 24h hard-age cap).
  touch -t "$(date -u -d '25 hours ago' '+%Y%m%d%H%M' 2>/dev/null || date -v-25H '+%Y%m%d%H%M')" "$stale"

  run bash -c '_p() { jq -n --arg s "$1" "{hook_event_name: \"SessionStart\", session_id: \$s}"; }; _p "sess-np" | "'"$SESSION_START_SH"'"'
  [ "$status" -eq 0 ]
  # Survivor must still be there because NO_BUDDY short-circuits before cleanup.
  [ -f "$stale" ]
}

# ------------------------------------------------------------
# CORRUPT / FUTURE_VERSION — log + bail
# ------------------------------------------------------------

@test "session-start: CORRUPT logs and creates no session file" {
  _seed_corrupt
  run bash -c '_p() { jq -n --arg s "$1" "{hook_event_name: \"SessionStart\", session_id: \$s}"; }; _p "sess-corr" | "'"$SESSION_START_SH"'"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(_count_session_files)" = "0" ]
  [ -f "$CLAUDE_PLUGIN_DATA/error.log" ]
  run grep "session-start" "$CLAUDE_PLUGIN_DATA/error.log"
  [ "$status" -eq 0 ]
}

@test "session-start: FUTURE_VERSION logs and creates no session file" {
  _seed_future_version
  run bash -c '_p() { jq -n --arg s "$1" "{hook_event_name: \"SessionStart\", session_id: \$s}"; }; _p "sess-fv" | "'"$SESSION_START_SH"'"'
  [ "$status" -eq 0 ]
  [ "$(_count_session_files)" = "0" ]
  [ -f "$CLAUDE_PLUGIN_DATA/error.log" ]
}

# ------------------------------------------------------------
# Payload failure paths
# ------------------------------------------------------------

@test "session-start: invalid session_id logs + no file" {
  _seed_hatch 42
  run bash -c 'echo "{\"session_id\":\"../etc/passwd\"}" | "'"$SESSION_START_SH"'"'
  [ "$status" -eq 0 ]
  [ "$(_count_session_files)" = "0" ]
  [ -f "$CLAUDE_PLUGIN_DATA/error.log" ]
}

@test "session-start: missing session_id logs + no file" {
  _seed_hatch 42
  run bash -c 'echo "{\"hook_event_name\":\"SessionStart\"}" | "'"$SESSION_START_SH"'"'
  [ "$status" -eq 0 ]
  [ "$(_count_session_files)" = "0" ]
  [ -f "$CLAUDE_PLUGIN_DATA/error.log" ]
}

@test "session-start: empty stdin → exits 0 (logs, no file)" {
  _seed_hatch 42
  run bash -c ': | "'"$SESSION_START_SH"'"'
  [ "$status" -eq 0 ]
  [ "$(_count_session_files)" = "0" ]
  # Empty stdin means no session_id extraction is possible; the hook
  # must log the failure so operators can tell silent-success from
  # silent-failure. Absent this assertion the test would pass even
  # if hook_log_error were removed from the missing-sid path.
  [ -f "$CLAUDE_PLUGIN_DATA/error.log" ]
}

# ------------------------------------------------------------
# Orphan sweep gated on ACTIVE
# ------------------------------------------------------------

@test "session-start: ACTIVE + stale .tmp → sweeps orphans" {
  _seed_hatch 42
  local stale="$CLAUDE_PLUGIN_DATA/.tmp.9999.stale"
  echo "stale" > "$stale"
  touch -t "$(date -u -d '25 hours ago' '+%Y%m%d%H%M' 2>/dev/null || date -v-25H '+%Y%m%d%H%M')" "$stale"

  run bash -c '_p() { jq -n --arg s "$1" "{hook_event_name: \"SessionStart\", session_id: \$s}"; }; _p "sess-sweep" | "'"$SESSION_START_SH"'"'
  [ "$status" -eq 0 ]
  [ ! -f "$stale" ]
}

# ------------------------------------------------------------
# Hard safety — unwritable data dir does not crash
# ------------------------------------------------------------

@test "session-start: CLAUDE_PLUGIN_DATA unset → exits 0" {
  unset CLAUDE_PLUGIN_DATA
  run bash -c '_p() { jq -n --arg s "$1" "{hook_event_name: \"SessionStart\", session_id: \$s}"; }; _p "sess-x" | "'"$SESSION_START_SH"'"'
  [ "$status" -eq 0 ]
}
