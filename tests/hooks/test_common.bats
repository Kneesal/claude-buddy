#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load ../test_helper

setup() {
  # Inherit CLAUDE_PLUGIN_DATA setup and source state.sh from the shared helper.
  export CLAUDE_PLUGIN_DATA="$BATS_TEST_TMPDIR/plugin-data"
  mkdir -p "$CLAUDE_PLUGIN_DATA"
  source "$REPO_ROOT/scripts/lib/state.sh"
  source "$REPO_ROOT/scripts/hooks/common.sh"
}

# ------------------------------------------------------------
# hook_log_error
# ------------------------------------------------------------

@test "hook_log_error: appends one tab-delimited line to error.log" {
  run hook_log_error "post-tool-use" "something broke"
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_PLUGIN_DATA/error.log" ]
  run cat "$CLAUDE_PLUGIN_DATA/error.log"
  [ "$status" -eq 0 ]
  # ISO-8601 UTC + TAB + hook-name + TAB + reason
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'\t'post-tool-use$'\t'something\ broke$ ]]
}

@test "hook_log_error: appending twice yields two lines" {
  hook_log_error "h1" "one"
  hook_log_error "h2" "two"
  run wc -l < "$CLAUDE_PLUGIN_DATA/error.log"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "2" ]
}

@test "hook_log_error: CLAUDE_PLUGIN_DATA unset is silent success" {
  unset CLAUDE_PLUGIN_DATA
  run hook_log_error "any" "any"
  [ "$status" -eq 0 ]
}

@test "hook_log_error: CLAUDE_PLUGIN_DATA missing dir is silent success" {
  export CLAUDE_PLUGIN_DATA="/nonexistent/$$/nope"
  run hook_log_error "any" "any"
  [ "$status" -eq 0 ]
}

@test "hook_log_error: embedded newlines are flattened to spaces" {
  printf -v reason 'multi\nline\rreason'
  hook_log_error "h" "$reason"
  run cat "$CLAUDE_PLUGIN_DATA/error.log"
  # Single line; the inner \n and \r have been replaced with spaces.
  [[ "$output" == *"multi line reason"* ]]
  # Exactly one trailing newline in the file.
  run wc -l < "$CLAUDE_PLUGIN_DATA/error.log"
  [ "${output// /}" = "1" ]
}

# ------------------------------------------------------------
# hook_drain_stdin
# ------------------------------------------------------------

@test "hook_drain_stdin: returns the piped payload" {
  run bash -c '
    source "'"$REPO_ROOT"'/scripts/lib/state.sh"
    source "'"$REPO_ROOT"'/scripts/hooks/common.sh"
    echo "{\"session_id\":\"abc\"}" | hook_drain_stdin
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'"session_id":"abc"'* ]]
}

@test "hook_drain_stdin: TTY stdin returns empty without hanging" {
  # bats runs with stdin attached; simulate by calling the function directly.
  # We cannot easily fake a TTY here, so just check that it returns quickly
  # when given a short pipe. The pipe path is covered above.
  run bash -c '
    source "'"$REPO_ROOT"'/scripts/lib/state.sh"
    source "'"$REPO_ROOT"'/scripts/hooks/common.sh"
    : | hook_drain_stdin
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ------------------------------------------------------------
# hook_extract_session_id
# ------------------------------------------------------------

@test "hook_extract_session_id: valid payload → session_id on stdout" {
  run hook_extract_session_id '{"session_id":"sess-abc123","hook_event_name":"SessionStart"}'
  [ "$status" -eq 0 ]
  [ "$output" = "sess-abc123" ]
}

@test "hook_extract_session_id: missing field → non-zero + empty" {
  run hook_extract_session_id '{"hook_event_name":"SessionStart"}'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "hook_extract_session_id: null field → non-zero + empty" {
  run hook_extract_session_id '{"session_id":null}'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "hook_extract_session_id: path-traversal id is rejected" {
  run hook_extract_session_id '{"session_id":"../etc/passwd"}'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "hook_extract_session_id: slash in id is rejected" {
  run hook_extract_session_id '{"session_id":"a/b"}'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "hook_extract_session_id: dot in id is rejected" {
  run hook_extract_session_id '{"session_id":"a.b"}'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "hook_extract_session_id: not valid JSON → non-zero" {
  run hook_extract_session_id 'not-json'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "hook_extract_session_id: empty payload → non-zero" {
  run hook_extract_session_id ''
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ------------------------------------------------------------
# hook_extract_tool_use_id
# ------------------------------------------------------------

@test "hook_extract_tool_use_id: prefers tool_use_id" {
  run hook_extract_tool_use_id '{"tool_use_id":"tu_1","tool_call_id":"tc_2"}'
  [ "$status" -eq 0 ]
  [ "$output" = "tu_1" ]
}

@test "hook_extract_tool_use_id: falls back to tool_call_id" {
  run hook_extract_tool_use_id '{"tool_call_id":"tc_2"}'
  [ "$status" -eq 0 ]
  [ "$output" = "tc_2" ]
}

@test "hook_extract_tool_use_id: missing both → non-zero" {
  run hook_extract_tool_use_id '{"session_id":"s"}'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "hook_extract_tool_use_id: shell metacharacters in id are opaque" {
  run hook_extract_tool_use_id '{"tool_use_id":"$(rm -rf /)"}'
  [ "$status" -eq 0 ]
  [ "$output" = '$(rm -rf /)' ]
}

@test "hook_extract_tool_use_id: >256 chars is rejected" {
  local long
  long="$(printf 'x%.0s' {1..300})"
  run hook_extract_tool_use_id "{\"tool_use_id\":\"$long\"}"
  [ "$status" -ne 0 ]
}

# ------------------------------------------------------------
# hook_initial_session_json
# ------------------------------------------------------------

@test "hook_initial_session_json: emits the canonical shape" {
  run hook_initial_session_json "sess-xyz"
  [ "$status" -eq 0 ]
  local v sid cd ring
  v="$(echo "$output" | jq -r '.schemaVersion')"
  sid="$(echo "$output" | jq -r '.sessionId')"
  cd="$(echo "$output" | jq -r '.cooldowns | type')"
  ring="$(echo "$output" | jq -r '.recentToolCallIds | type')"
  [ "$v" = "1" ]
  [ "$sid" = "sess-xyz" ]
  [ "$cd" = "object" ]
  [ "$ring" = "array" ]
  # startedAt is ISO-8601 Zulu
  local started
  started="$(echo "$output" | jq -r '.startedAt')"
  [[ "$started" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "hook_initial_session_json: P3-2 commentary fields present" {
  run hook_initial_session_json "sess-p32"
  [ "$status" -eq 0 ]
  # lastEventType starts null; commentsThisSession starts 0.
  [ "$(echo "$output" | jq -r '.lastEventType')" = "null" ]
  [ "$(echo "$output" | jq -r '.commentsThisSession')" = "0" ]
  # recentFailures is an empty array.
  [ "$(echo "$output" | jq -r '.recentFailures | type')" = "array" ]
  [ "$(echo "$output" | jq -r '.recentFailures | length')" = "0" ]
  # commentary.bags is an empty object; firstEditFired starts false.
  [ "$(echo "$output" | jq -r '.commentary.bags | type')" = "object" ]
  [ "$(echo "$output" | jq -r '.commentary.firstEditFired')" = "false" ]
}

# ------------------------------------------------------------
# hook_ring_push + hook_ring_contains
# ------------------------------------------------------------

@test "hook_ring_push: appends a new id" {
  local base out
  base="$(hook_initial_session_json "s1")"
  out="$(echo "$base" | hook_ring_push "id1")"
  run jq -r '.recentToolCallIds | length' <<< "$out"
  [ "$output" = "1" ]
  run jq -r '.recentToolCallIds[0]' <<< "$out"
  [ "$output" = "id1" ]
}

@test "hook_ring_push: duplicate id moves to tail without growing the ring" {
  local base step1 step2
  base="$(hook_initial_session_json "s1")"
  step1="$(echo "$base" | hook_ring_push "id1")"
  step1="$(echo "$step1" | hook_ring_push "id2")"
  step2="$(echo "$step1" | hook_ring_push "id1")"
  run jq -r '.recentToolCallIds | length' <<< "$step2"
  [ "$output" = "2" ]
  run jq -rc '.recentToolCallIds' <<< "$step2"
  [ "$output" = '["id2","id1"]' ]
}

@test "hook_ring_push: eviction keeps the last 20 in insertion order" {
  local cur
  cur="$(hook_initial_session_json "s1")"
  for i in $(seq 1 25); do
    cur="$(echo "$cur" | hook_ring_push "id$i")"
  done
  run jq -r '.recentToolCallIds | length' <<< "$cur"
  [ "$output" = "20" ]
  run jq -r '.recentToolCallIds[0]' <<< "$cur"
  [ "$output" = "id6" ]
  run jq -r '.recentToolCallIds[-1]' <<< "$cur"
  [ "$output" = "id25" ]
}

@test "hook_ring_contains: true when id is present" {
  local base out
  base="$(hook_initial_session_json "s1")"
  out="$(echo "$base" | hook_ring_push "id1")"
  run hook_ring_contains "$out" "id1"
  [ "$status" -eq 0 ]
}

@test "hook_ring_contains: false when id is absent" {
  local base
  base="$(hook_initial_session_json "s1")"
  run hook_ring_contains "$base" "id1"
  [ "$status" -ne 0 ]
}
