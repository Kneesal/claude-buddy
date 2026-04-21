#!/usr/bin/env bash
# stop.sh — Stop hook. Fires once per session at session end.
#
# Emits the "goodbye" commentary line (bypasses the per-session
# budget, novelty gate, and cooldown per D7 of the P3-2 plan).
# Still held under the per-session flock so the session JSON update
# (commentsThisSession increment, shuffle-bag consumption) is atomic
# with any concurrent late-fire from another hook.
#
# A missing tool_use_id is fine here — Stop's payload does not carry
# one. The dedup ring isn't touched.
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
  local hook_name="stop"

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
    # Stop with no session_id — can't safely update session file.
    # Log and exit; the goodbye is best-effort.
    hook_log_error "$hook_name" "missing or invalid session_id"
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

  # --- Critical section ---
  local session_json
  session_json="$(session_load "$sid" 2>/dev/null)"
  if [[ -z "$session_json" || "$session_json" == "{}" ]]; then
    session_json="$(hook_initial_session_json "$sid")"
  fi

  local commentary_out commentary_line final_session
  commentary_out="$(hook_commentary_select "Stop" "$session_json" "$buddy_json")"
  commentary_line="${commentary_out%%$'\n'*}"
  final_session="${commentary_out#*$'\n'}"
  if [[ -z "$final_session" ]]; then
    final_session="$session_json"
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
