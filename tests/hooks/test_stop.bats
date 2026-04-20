#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load ../test_helper

STOP_SH="$REPO_ROOT/hooks/stop.sh"

_count_session_files() {
  find "$CLAUDE_PLUGIN_DATA" -maxdepth 1 -name 'session-*.json' 2>/dev/null | wc -l | tr -d ' '
}

@test "stop: ACTIVE + valid payload → exit 0, no state writes" {
  _seed_hatch 42
  run bash -c 'echo "{\"session_id\":\"sess-a\",\"hook_event_name\":\"Stop\"}" | "'"$STOP_SH"'"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(_count_session_files)" = "0" ]
}

@test "stop: NO_BUDDY → exit 0, no error.log" {
  run bash -c 'echo "{\"session_id\":\"sess-a\"}" | "'"$STOP_SH"'"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/error.log" ]
}

@test "stop: CORRUPT → exit 0, no writes" {
  # Stop is an unconditional no-op in P3-1 (see hooks/stop.sh).
  # It doesn't inspect buddy state so it doesn't log sentinels either.
  _seed_corrupt
  run bash -c 'echo "{\"session_id\":\"sess-a\"}" | "'"$STOP_SH"'"'
  [ "$status" -eq 0 ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/error.log" ]
}

@test "stop: invalid session_id is tolerated silently (no log, no file)" {
  # Stop payloads sometimes omit session_id legitimately — tolerating
  # absence without logging prevents unbounded error.log growth (see
  # P3-1 review finding #4).
  _seed_hatch 42
  run bash -c 'echo "{\"session_id\":\"../evil\"}" | "'"$STOP_SH"'"'
  [ "$status" -eq 0 ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/error.log" ]
}

@test "stop: missing session_id is tolerated silently" {
  _seed_hatch 42
  run bash -c 'echo "{\"hook_event_name\":\"Stop\"}" | "'"$STOP_SH"'"'
  [ "$status" -eq 0 ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/error.log" ]
}

@test "stop: empty stdin → exit 0" {
  _seed_hatch 42
  run bash -c ': | "'"$STOP_SH"'"'
  [ "$status" -eq 0 ]
}

@test "stop: FUTURE_VERSION state → exit 0, no writes" {
  _seed_future_version
  run bash -c 'echo "{\"session_id\":\"sess-a\"}" | "'"$STOP_SH"'"'
  [ "$status" -eq 0 ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/error.log" ]
}

@test "stop: CLAUDE_PLUGIN_DATA unset → exit 0" {
  unset CLAUDE_PLUGIN_DATA
  run bash -c 'echo "{\"session_id\":\"sess-a\"}" | "'"$STOP_SH"'"'
  [ "$status" -eq 0 ]
}
