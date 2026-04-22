#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load ../../test_helper

# Pre-compute seed-42 hatch once per file (see test_helper.bash).
setup_file() {
  _prepare_hatched_cache
}

STOP_SH="$REPO_ROOT/hooks/stop.sh"

_count_session_files() {
  find "$CLAUDE_PLUGIN_DATA" -maxdepth 1 -name 'session-*.json' 2>/dev/null | wc -l | tr -d ' '
}

@test "stop: ACTIVE + valid payload → exit 0, emits goodbye, writes session" {
  _seed_hatch 42
  run bash -c 'echo "{\"session_id\":\"sess-a\",\"hook_event_name\":\"Stop\"}" | "'"$STOP_SH"'"'
  [ "$status" -eq 0 ]
  # Stop always emits (bypasses all three gates).
  [ -n "$output" ]
  # Emit format: "<emoji> <name>: \"...\""
  [[ "$output" =~ :\ \".+\"$ ]]
  # Session file written with commentsThisSession == 1.
  [ -f "$CLAUDE_PLUGIN_DATA/session-sess-a.json" ]
  run jq -r '.commentsThisSession' "$CLAUDE_PLUGIN_DATA/session-sess-a.json"
  [ "$output" = "1" ]
}

@test "stop: ACTIVE + BUDDY_STOP_LINE_ON_EXIT=0 → silent, no goodbye" {
  _seed_hatch 42
  run bash -c 'BUDDY_STOP_LINE_ON_EXIT=0 bash -c "echo \"{\\\"session_id\\\":\\\"sess-b\\\",\\\"hook_event_name\\\":\\\"Stop\\\"}\" | \"'"$STOP_SH"'\""'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stop: NO_BUDDY → exit 0, no emit, no writes, no error.log" {
  run bash -c 'echo "{\"session_id\":\"sess-a\"}" | "'"$STOP_SH"'"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/error.log" ]
  [ "$(_count_session_files)" = "0" ]
}

@test "stop: CORRUPT → exit 0, logs sentinel, no emit" {
  _seed_corrupt
  run bash -c 'echo "{\"session_id\":\"sess-a\"}" | "'"$STOP_SH"'"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$CLAUDE_PLUGIN_DATA/error.log" ]
}

@test "stop: invalid session_id logs and exits 0" {
  _seed_hatch 42
  run bash -c 'echo "{\"session_id\":\"../evil\"}" | "'"$STOP_SH"'"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$CLAUDE_PLUGIN_DATA/error.log" ]
}

@test "stop: missing session_id logs and exits 0" {
  _seed_hatch 42
  run bash -c 'echo "{\"hook_event_name\":\"Stop\"}" | "'"$STOP_SH"'"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$CLAUDE_PLUGIN_DATA/error.log" ]
}

@test "stop: empty stdin → exit 0" {
  _seed_hatch 42
  run bash -c ': | "'"$STOP_SH"'"'
  [ "$status" -eq 0 ]
}

@test "stop: FUTURE_VERSION state → exit 0, logs, no emit" {
  _seed_future_version
  run bash -c 'echo "{\"session_id\":\"sess-a\"}" | "'"$STOP_SH"'"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$CLAUDE_PLUGIN_DATA/error.log" ]
}

@test "stop: CLAUDE_PLUGIN_DATA unset → exit 0" {
  unset CLAUDE_PLUGIN_DATA
  run bash -c 'echo "{\"session_id\":\"sess-a\"}" | "'"$STOP_SH"'"'
  [ "$status" -eq 0 ]
}

@test "stop: long-session startedAt triggers long_session bank" {
  _seed_hatch 42
  # Pre-stamp a session file with startedAt set 2h in the past so the
  # long_session milestone fires. The hook uses the session file's
  # startedAt, not a fresh one (the file exists, so it won't re-init).
  local two_hours_ago
  two_hours_ago="$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                   || date -u -r $(($(date +%s) - 7200)) +%Y-%m-%dT%H:%M:%SZ)"
  jq -n \
    --arg sid "sess-long" \
    --arg ts "$two_hours_ago" \
    '{schemaVersion:1, sessionId:$sid, startedAt:$ts, cooldowns:{}, recentToolCallIds:[], lastEventType:null, commentsThisSession:0, recentFailures:[], commentary:{bags:{}, firstEditFired:false}}' \
    > "$CLAUDE_PLUGIN_DATA/session-sess-long.json"

  run bash -c 'echo "{\"session_id\":\"sess-long\",\"hook_event_name\":\"Stop\"}" | "'"$STOP_SH"'"'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # Long-session bank selected — we can tell because the Stop.long_session
  # bag gets consumed. The Stop.default bag does NOT.
  run jq -r '.commentary.bags["Stop.long_session"] | length' "$CLAUDE_PLUGIN_DATA/session-sess-long.json"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
  run jq -r '.commentary.bags["Stop.default"] // empty' "$CLAUDE_PLUGIN_DATA/session-sess-long.json"
  [ -z "$output" ]
}
