#!/usr/bin/env bash
# stop.sh — Stop hook. Fires once per session at session end.
#
# Dual-duty per P4-1:
#   1. XP + streak + (possibly) level-up via hook_signals_apply with
#      sessionActiveHours derived from session.startedAt.
#   2. Goodbye commentary (bypasses per-session budget, novelty gate,
#      and cooldown per P3-2 D7). Level-up events still override the
#      goodbye line when both fire.
#
# No tool_use_id in the Stop payload → no dedup-ring work. Still held
# under the per-session flock so any concurrent late-fire from PTU
# can't race this handler's session write.
#
# Lock ordering identical to PTU/PTUF: session OUTER, buddy INNER.
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

# Convert "2026-04-21T13:45:00Z" → epoch-seconds. Falls back to empty
# string on parse failure. Mirrors scripts/hooks/commentary.sh's
# _commentary_iso_to_epoch so Stop doesn't need to source commentary
# internals.
_stop_iso_to_epoch() {
  local ts="$1"
  [[ -z "$ts" ]] && return 0
  local epoch
  epoch="$(date -u -d "$ts" +%s 2>/dev/null)"
  if [[ -z "$epoch" ]]; then
    epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null)"
  fi
  [[ "$epoch" =~ ^[0-9]+$ ]] && printf '%s' "$epoch"
}

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
    hook_log_error "$hook_name" "missing or invalid session_id"
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

  # --- Compute sessionActiveHours from session.startedAt ---
  local now started_at started_epoch hours_str
  now="$(date +%s 2>/dev/null || echo 0)"
  started_at="$(printf '%s' "$session_json" | jq -r '.startedAt // ""' 2>/dev/null)"
  started_epoch="$(_stop_iso_to_epoch "$started_at")"
  if [[ "$started_epoch" =~ ^[0-9]+$ ]]; then
    # floor( (now - started_epoch) / 3600 ). Passed as a JSON number
    # (integer) into signals.sh — the filter does another floor()
    # internally but integer input is a no-op there.
    hours_str=$(( (now - started_epoch) / 3600 ))
  else
    hours_str=0
  fi

  local today today_epoch
  today="$(date -u +%Y-%m-%d 2>/dev/null || echo "1970-01-01")"
  today_epoch="$(date -u -d "$today" +%s 2>/dev/null || echo 0)"

  local inputs_json
  inputs_json="$(jq -n -c \
    --argjson now "$now" \
    --arg today "$today" \
    --argjson todayEpoch "$today_epoch" \
    --argjson hours "$hours_str" '
    { toolName: "", filePath: "",
      filePathMatchedLast: false, isEditTool: false,
      now: $now, today: $today, todayEpoch: $todayEpoch,
      sessionActiveHours: $hours }' 2>/dev/null)"

  local signals_out level_up_sentinel buddy_after
  signals_out="$(hook_signals_apply Stop "$buddy_locked" "$inputs_json")"
  level_up_sentinel="${signals_out%%$'\n'*}"
  buddy_after="${signals_out#*$'\n'}"
  if [[ -z "$buddy_after" ]]; then
    buddy_after="$buddy_locked"
    level_up_sentinel=""
  fi

  # --- Commentary: Stop goodbye (bypass gates) ---
  local commentary_out commentary_line final_session
  commentary_out="$(hook_commentary_select "Stop" "$session_json" "$buddy_after")"
  commentary_line="${commentary_out%%$'\n'*}"
  final_session="${commentary_out#*$'\n'}"
  if [[ -z "$final_session" ]]; then
    final_session="$session_json"
    commentary_line=""
  fi

  # Level-up overrides the Stop goodbye (D10).
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
