#!/usr/bin/env bash
# post-tool-use.sh — PostToolUse hook.
#
# Maintains the per-session dedup ring on recentToolCallIds (last 20).
# No commentary, no signal increments — P3-2 and P4-1 extend this file
# with those concerns (and will diverge from post-tool-use-failure.sh
# at that point).
#
# Contract: always exits 0, empty stdout, p95 < 100ms.

_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec 2>/dev/null

if ! source "$_HOOK_DIR/../scripts/lib/state.sh" 2>/dev/null; then
  exit 0
fi
if ! source "$_HOOK_DIR/../scripts/hooks/common.sh" 2>/dev/null; then
  exit 0
fi

_main() {
  local hook_name="post-tool-use"

  local payload
  payload="$(hook_drain_stdin)"

  local state
  state="$(buddy_load)"

  case "$state" in
    "$STATE_NO_BUDDY")
      return 0
      ;;
    "$STATE_CORRUPT"|"$STATE_FUTURE_VERSION")
      hook_log_error "$hook_name" "buddy state sentinel: $state"
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

  # Per-session flock around the whole load-modify-save cycle.
  # Mirrors buddy_save's exec-{fd} flock discipline. See P3-1 review #2.
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

  local updated
  updated="$(printf '%s' "$session_json" | hook_ring_update "$tcid")"
  if [[ -z "$updated" ]]; then
    exec {lock_fd}>&-
    hook_log_error "$hook_name" "ring_update emitted empty output"
    return 0
  fi
  if [[ "$updated" == "DEDUP" ]]; then
    exec {lock_fd}>&-
    return 0
  fi

  if ! printf '%s' "$updated" | session_save "$sid"; then
    exec {lock_fd}>&-
    hook_log_error "$hook_name" "session_save failed for $sid"
    return 0
  fi

  exec {lock_fd}>&-
  return 0
}

_main
exit 0
