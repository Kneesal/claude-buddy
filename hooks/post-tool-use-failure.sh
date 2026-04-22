#!/usr/bin/env bash
# post-tool-use-failure.sh — PostToolUseFailure hook.
#
# Structurally parallel to post-tool-use.sh with these differences:
#   - event_type = "PostToolUseFailure" (bumps chaos.errors, not
#     chaos.repeatedEditHits; bumps quality.totalEdits but not
#     successfulEdits).
#   - toolName is NOT passed to signals.sh — failures don't count
#     toward variety (a failed Edit didn't successfully exercise the
#     tool surface). See signals.sh for the gate.
#   - session.lastToolFilePath is NOT updated here — only PTU owns it
#     so the "consecutive same-file" detection runs against success
#     paths, not failure paths (D8).
#
# The shared dedup ring ensures a tool call that fires both events is
# counted once. Lock ordering identical to PTU: session OUTER, buddy
# INNER.
#
# Contract: always exits 0, p95 < 100ms.

_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec 2>/dev/null

if ! source "$_HOOK_DIR/../scripts/lib/state.sh" 2>/dev/null; then
  exit 0
fi
if ! source "$_HOOK_DIR/../scripts/hooks/common.sh" 2>/dev/null; then
  exit 0
fi
if ! source "$_HOOK_DIR/../scripts/hooks/commentary.sh" 2>/dev/null; then
  exit 0
fi
if ! source "$_HOOK_DIR/../scripts/hooks/signals.sh" 2>/dev/null; then
  exit 0
fi

_main() {
  local hook_name="post-tool-use-failure"

  local payload
  payload="$(hook_drain_stdin)"

  local buddy_json
  buddy_json="$(buddy_load)"

  case "$buddy_json" in
    "$STATE_NO_BUDDY")
      return 0
      ;;
    "$STATE_CORRUPT"|"$STATE_FUTURE_VERSION")
      hook_log_error "$hook_name" "buddy state sentinel: $buddy_json"
      return 0
      ;;
  esac

  local sid
  if ! sid="$(hook_extract_session_id "$payload")"; then
    hook_log_error "$hook_name" "missing or invalid session_id"
    return 0
  fi

  local tcid
  if ! tcid="$(hook_extract_tool_use_id "$payload")"; then
    hook_log_error "$hook_name" "missing tool_use_id"
    return 0
  fi

  local data_dir="${CLAUDE_PLUGIN_DATA:-}"
  if [[ -z "$data_dir" || ! -d "$data_dir" ]]; then
    hook_log_error "$hook_name" "CLAUDE_PLUGIN_DATA missing; cannot lock session"
    return 0
  fi
  local session_lock_file="$data_dir/session-${sid}.json.lock"
  if [[ -L "$session_lock_file" ]]; then
    hook_log_error "$hook_name" "refusing symlinked session lock $session_lock_file"
    return 0
  fi
  local session_lock_fd
  if ! exec {session_lock_fd}>"$session_lock_file"; then
    hook_log_error "$hook_name" "failed to open session lock for $sid"
    return 0
  fi
  if ! flock -x -w 0.2 "$session_lock_fd"; then
    exec {session_lock_fd}>&-
    hook_log_error "$hook_name" "flock timeout on session $sid"
    return 0
  fi

  # --- Inside session lock ---
  local session_json
  session_json="$(session_load "$sid" 2>/dev/null)"
  if [[ -z "$session_json" || "$session_json" == "{}" ]]; then
    session_json="$(hook_initial_session_json "$sid")"
  fi

  local ring_updated
  ring_updated="$(printf '%s' "$session_json" | hook_ring_update "$tcid")"
  if [[ -z "$ring_updated" ]]; then
    exec {session_lock_fd}>&-
    hook_log_error "$hook_name" "ring_update emitted empty output"
    return 0
  fi
  if [[ "$ring_updated" == "DEDUP" ]]; then
    exec {session_lock_fd}>&-
    return 0
  fi

  # --- Nested buddy lock ---
  local buddy_lock_file="$data_dir/buddy.json.lock"
  if [[ -L "$buddy_lock_file" ]]; then
    exec {session_lock_fd}>&-
    hook_log_error "$hook_name" "refusing symlinked buddy lock $buddy_lock_file"
    return 0
  fi
  local buddy_lock_fd
  if ! exec {buddy_lock_fd}>"$buddy_lock_file"; then
    exec {session_lock_fd}>&-
    hook_log_error "$hook_name" "failed to open buddy lock"
    return 0
  fi
  if ! flock -x -w 0.2 "$buddy_lock_fd"; then
    exec {buddy_lock_fd}>&-
    exec {session_lock_fd}>&-
    hook_log_error "$hook_name" "flock timeout on buddy.json"
    return 0
  fi

  local buddy_locked
  buddy_locked="$(buddy_load)"
  case "$buddy_locked" in
    "$STATE_NO_BUDDY"|"$STATE_CORRUPT"|"$STATE_FUTURE_VERSION")
      exec {buddy_lock_fd}>&-
      exec {session_lock_fd}>&-
      return 0
      ;;
  esac

  # --- Event inputs (failures: no toolName, no file-path work) ---
  local now today
  now="$(date +%s 2>/dev/null || echo 0)"
  today="$(date -u +%Y-%m-%d 2>/dev/null || echo "1970-01-01")"

  local inputs_json
  inputs_json="$(jq -n -c \
    --argjson now "$now" \
    --arg today "$today" '
    { toolName: "", filePath: "",
      filePathMatchedLast: false, isEditTool: false,
      now: $now, today: $today,
      sessionActiveHours: 0 }' 2>/dev/null)"

  local signals_out level_up_sentinel buddy_after
  signals_out="$(hook_signals_apply PostToolUseFailure "$buddy_locked" "$inputs_json")"
  level_up_sentinel="${signals_out%%$'\n'*}"
  buddy_after="${signals_out#*$'\n'}"
  if [[ -z "$buddy_after" ]]; then
    buddy_after="$buddy_locked"
    level_up_sentinel=""
  fi

  # --- Commentary engine ---
  local commentary_out commentary_line final_session
  commentary_out="$(hook_commentary_select "PostToolUseFailure" "$ring_updated" "$buddy_after")"
  commentary_line="${commentary_out%%$'\n'*}"
  final_session="${commentary_out#*$'\n'}"
  if [[ -z "$final_session" ]]; then
    final_session="$ring_updated"
    commentary_line=""
  fi

  if [[ -n "$level_up_sentinel" ]]; then
    local lu_out lu_line lu_session
    lu_out="$(hook_commentary_select "LevelUp" "$final_session" "$buddy_after")"
    lu_line="${lu_out%%$'\n'*}"
    lu_session="${lu_out#*$'\n'}"
    if [[ -n "$lu_line" && -n "$lu_session" ]]; then
      commentary_line="$lu_line"
      final_session="$lu_session"
    fi
  fi

  # --- Persist ---
  local _BUDDY_SAVE_LOCK_HELD=1
  if ! printf '%s' "$buddy_after" | buddy_save; then
    _BUDDY_SAVE_LOCK_HELD=
    exec {buddy_lock_fd}>&-
    exec {session_lock_fd}>&-
    hook_log_error "$hook_name" "buddy_save failed"
    return 0
  fi
  _BUDDY_SAVE_LOCK_HELD=

  if ! printf '%s' "$final_session" | session_save "$sid"; then
    exec {buddy_lock_fd}>&-
    exec {session_lock_fd}>&-
    hook_log_error "$hook_name" "session_save failed for $sid"
    return 0
  fi

  exec {buddy_lock_fd}>&-
  exec {session_lock_fd}>&-

  if [[ -n "$commentary_line" ]]; then
    printf '%s\n' "$commentary_line"
  fi
  return 0
}

_main
exit 0
