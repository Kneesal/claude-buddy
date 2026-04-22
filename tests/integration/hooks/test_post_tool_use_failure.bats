#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load ../../test_helper

# Pre-compute seed-42 hatch once per file (see test_helper.bash).
setup_file() {
  _prepare_hatched_cache
}

POST_SH="$REPO_ROOT/hooks/post-tool-use.sh"
FAIL_SH="$REPO_ROOT/hooks/post-tool-use-failure.sh"

_fire() {
  local script="$1" sid="$2" tcid="$3"
  jq -n --arg s "$sid" --arg t "$tcid" \
    '{session_id: $s, tool_use_id: $t}' \
    | "$script"
}

# ------------------------------------------------------------
# Happy path — identical shape to PostToolUse
# ------------------------------------------------------------

@test "failure: ACTIVE + valid payload pushes id and emits commentary" {
  _seed_hatch 42
  run _fire "$FAIL_SH" "sess-f" "tu_1"
  [ "$status" -eq 0 ]
  # P3-2: first failure emits a default-bank line.
  [ -n "$output" ]
  [[ "$output" =~ :\ \".+\"$ ]]
  run jq -rc '.recentToolCallIds' "$CLAUDE_PLUGIN_DATA/session-sess-f.json"
  [ "$output" = '["tu_1"]' ]
}

# ------------------------------------------------------------
# Cross-event dedup — the main reason both scripts exist
# ------------------------------------------------------------

@test "failure: same tool_use_id from PostToolUse then failure is deduped" {
  _seed_hatch 42
  _fire "$POST_SH" "sess-x" "tu_1"
  run jq -rc '.recentToolCallIds' "$CLAUDE_PLUGIN_DATA/session-sess-x.json"
  [ "$output" = '["tu_1"]' ]

  run _fire "$FAIL_SH" "sess-x" "tu_1"
  [ "$status" -eq 0 ]
  run jq -rc '.recentToolCallIds' "$CLAUDE_PLUGIN_DATA/session-sess-x.json"
  [ "$output" = '["tu_1"]' ]
  run jq -r '.recentToolCallIds | length' "$CLAUDE_PLUGIN_DATA/session-sess-x.json"
  [ "$output" = "1" ]
}

@test "failure: novel id after PostToolUse grows the ring" {
  _seed_hatch 42
  _fire "$POST_SH" "sess-y" "tu_1"
  _fire "$FAIL_SH" "sess-y" "tu_2"
  run jq -rc '.recentToolCallIds' "$CLAUDE_PLUGIN_DATA/session-sess-y.json"
  [ "$output" = '["tu_1","tu_2"]' ]
}

# ------------------------------------------------------------
# NO_BUDDY / error paths
# ------------------------------------------------------------

@test "failure: NO_BUDDY writes no file + no error.log" {
  run _fire "$FAIL_SH" "sess-np" "tu_1"
  [ "$status" -eq 0 ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/session-sess-np.json" ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/error.log" ]
}

@test "failure: missing tool_use_id logs under post-tool-use-failure name" {
  _seed_hatch 42
  run bash -c 'echo "{\"session_id\":\"sess-nf\"}" | "'"$FAIL_SH"'"'
  [ "$status" -eq 0 ]
  run grep "post-tool-use-failure" "$CLAUDE_PLUGIN_DATA/error.log"
  [ "$status" -eq 0 ]
}

@test "failure: FUTURE_VERSION state logs + no session write" {
  _seed_future_version
  run _fire "$FAIL_SH" "sess-fv" "tu_1"
  [ "$status" -eq 0 ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/session-sess-fv.json" ]
  [ -f "$CLAUDE_PLUGIN_DATA/error.log" ]
}

@test "failure: CLAUDE_PLUGIN_DATA unset → exits 0" {
  unset CLAUDE_PLUGIN_DATA
  run _fire "$FAIL_SH" "sess-u" "tu_1"
  [ "$status" -eq 0 ]
}
