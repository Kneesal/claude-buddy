#!/usr/bin/env bash
# post-tool-use-failure.sh — PostToolUseFailure hook.
#
# Structurally parallel to post-tool-use.sh; only the event type
# passed to hook_commentary_select differs. The shared dedup ring
# ensures a tool call that fires both events is counted once.
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
  local lock_file="$data_dir/session-${sid}.json.lock"
  if [[ -L "$lock_file" ]]; then
    hook_log_error "$hook_name" "refusing symlinked session lock $lock_file"
    return 0
  fi
  local lock_fd
  if ! exec {lock_fd}>"$lock_file"; then
    hook_log_error "$hook_name" "failed to open session lock for $sid"
    return 0
  fi
  if ! flock -x -w 0.2 "$lock_fd"; then
    exec {lock_fd}>&-
    hook_log_error "$hook_name" "flock timeout on session $sid"
    return 0
  fi

  # --- Critical section: load → modify → save under lock ---
  local session_json
  session_json="$(session_load "$sid" 2>/dev/null)"
  if [[ -z "$session_json" || "$session_json" == "{}" ]]; then
    session_json="$(hook_initial_session_json "$sid")"
  fi

  local ring_updated
  ring_updated="$(printf '%s' "$session_json" | hook_ring_update "$tcid")"
  if [[ -z "$ring_updated" ]]; then
    exec {lock_fd}>&-
    hook_log_error "$hook_name" "ring_update emitted empty output"
    return 0
  fi
  if [[ "$ring_updated" == "DEDUP" ]]; then
    exec {lock_fd}>&-
    return 0
  fi

  local commentary_out commentary_line final_session
  commentary_out="$(hook_commentary_select "PostToolUseFailure" "$ring_updated" "$buddy_json")"
  commentary_line="${commentary_out%%$'\n'*}"
  final_session="${commentary_out#*$'\n'}"
  if [[ -z "$final_session" ]]; then
    final_session="$ring_updated"
    commentary_line=""
  fi

  if ! printf '%s' "$final_session" | session_save "$sid"; then
    exec {lock_fd}>&-
    hook_log_error "$hook_name" "session_save failed for $sid"
    return 0
  fi

  exec {lock_fd}>&-

  if [[ -n "$commentary_line" ]]; then
    printf '%s\n' "$commentary_line"
  fi
  return 0
}

_main
exit 0
