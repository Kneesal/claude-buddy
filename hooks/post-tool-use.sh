#!/usr/bin/env bash
# post-tool-use.sh — PostToolUse hook.
#
# Responsibilities per fire, all inside the per-session flock AND the
# nested per-buddy flock (P4-1 D1/D2 — session OUTER, buddy INNER):
#   1. Maintain the dedup ring on recentToolCallIds (last 20). If the
#      tool-call ID is already seen, skip the rest — the PTUF hook
#      has already processed this tool call.
#   2. Apply signal / XP / level-up mutations to buddy.json via
#      hook_signals_apply. Single fused jq per fire.
#   3. Update session.lastToolFilePath so the next fire's
#      repeatedEditHits detection has the prior file path to compare
#      against.
#   4. Consult the commentary engine. Level-up events override the
#      PTU commentary line (D10).
#   5. Persist: buddy_save first (inner lock), session_save next
#      (outer lock). Release locks in reverse order.
#   6. Emit the captured line to stdout AFTER both locks are released
#      and both saves have committed.
#
# Emit ordering is deliberate: printing after save-commit means a
# crash between the printf and the save can't leave buddy/session
# state out of sync with what the user saw. D11.
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

# Classify a tool name as "edit-like" (affects buddy.signals.quality
# and chaos.repeatedEditHits per P4-1 D8). Kept local to the hook
# layer rather than baked into signals.sh so the rule stays close to
# the PTU payload parsing.
_ptu_is_edit_tool() {
  case "$1" in
    Edit|Write|MultiEdit) return 0 ;;
    *)                    return 1 ;;
  esac
}

_main() {
  local hook_name="post-tool-use"

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

  # Extract tool_name + tool_input.file_path from the payload. The
  # live-smoke recipe in docs/solutions/developer-experience/
  # claude-code-plugin-hooks-json-schema-2026-04-20.md §B is the
  # authoritative shape — Claude Code PTU payloads carry tool_input
  # as an object with tool-specific keys. Edit/Write/MultiEdit put
  # the path at tool_input.file_path. Non-edit tools (Bash, Grep,
  # Glob, ...) don't carry a file_path and we treat it as empty.
  local tool_name tool_file
  tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // ""' 2>/dev/null)"
  tool_file="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""' 2>/dev/null)"

  # --- Outer critical section: per-session flock ---
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

  # --- Inside session lock: load session, update dedup ring ---
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
    # Duplicate tool-call ID — PTUF fired first. Skip commentary AND
    # signals: we don't want two fires for one logical event.
    exec {session_lock_fd}>&-
    return 0
  fi

  # --- Nested buddy lock (D1/D2 — session OUTER, buddy INNER) ---
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

  # Re-load buddy inside the lock. The load before the session lock was
  # for the NO_BUDDY/sentinel check — we use this authoritative read
  # for the mutation to avoid a torn write from any concurrent writer
  # that closed the gap between the first load and this point.
  local buddy_locked
  buddy_locked="$(buddy_load)"
  case "$buddy_locked" in
    "$STATE_NO_BUDDY"|"$STATE_CORRUPT"|"$STATE_FUTURE_VERSION")
      # State degraded between the first check and lock acquisition.
      # Skip cleanly.
      exec {buddy_lock_fd}>&-
      exec {session_lock_fd}>&-
      return 0
      ;;
  esac

  # --- Event inputs for hook_signals_apply ---
  local prior_file_path
  prior_file_path="$(printf '%s' "$session_json" | jq -r '.lastToolFilePath // ""' 2>/dev/null)"
  local matched="false"
  if [[ -n "$tool_file" && "$tool_file" == "$prior_file_path" ]]; then
    matched="true"
  fi
  local is_edit="false"
  _ptu_is_edit_tool "$tool_name" && is_edit="true"

  local now today today_epoch
  now="$(date +%s 2>/dev/null || echo 0)"
  today="$(date -u +%Y-%m-%d 2>/dev/null || echo "1970-01-01")"
  today_epoch="$(date -u -d "$today" +%s 2>/dev/null || echo 0)"

  local inputs_json
  inputs_json="$(jq -n -c \
    --arg tool "$tool_name" \
    --arg file "$tool_file" \
    --argjson matched "$matched" \
    --argjson isEdit "$is_edit" \
    --argjson now "$now" \
    --arg today "$today" \
    --argjson todayEpoch "$today_epoch" '
    { toolName: $tool, filePath: $file,
      filePathMatchedLast: $matched, isEditTool: $isEdit,
      now: $now, today: $today, todayEpoch: $todayEpoch,
      sessionActiveHours: 0 }' 2>/dev/null)"

  # --- Run signals + XP + level-up ---
  local signals_out level_up_sentinel buddy_after
  signals_out="$(hook_signals_apply PostToolUse "$buddy_locked" "$inputs_json")"
  level_up_sentinel="${signals_out%%$'\n'*}"
  buddy_after="${signals_out#*$'\n'}"
  # Defensive: if the fused filter failed, use the pre-call buddy JSON.
  if [[ -z "$buddy_after" ]]; then
    buddy_after="$buddy_locked"
    level_up_sentinel=""
  fi

  # Update session.lastToolFilePath BEFORE commentary (single-mutation
  # discipline — one write path per fire).
  local session_with_file
  session_with_file="$(printf '%s' "$ring_updated" | jq -c --arg p "$tool_file" '.lastToolFilePath = $p' 2>/dev/null)"
  [[ -z "$session_with_file" ]] && session_with_file="$ring_updated"

  # --- Commentary engine ---
  local commentary_out commentary_line final_session
  commentary_out="$(hook_commentary_select "PostToolUse" "$session_with_file" "$buddy_after")"
  commentary_line="${commentary_out%%$'\n'*}"
  final_session="${commentary_out#*$'\n'}"
  if [[ -z "$final_session" ]]; then
    final_session="$session_with_file"
    commentary_line=""
  fi

  # Level-up takes priority over the PTU commentary line (D10).
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

  # --- Persist: buddy first (inner lock), session next (outer lock) ---
  # Saves must both succeed before we emit — otherwise we'd show a line
  # that isn't backed by persisted state.
  #
  # _BUDDY_SAVE_LOCK_HELD=1 tells buddy_save to skip its own internal
  # flock. We're holding buddy_lock_fd; a second flock on the same file
  # from a different fd would deadlock the kernel's per-open-file-
  # description lock table and time out. See state.sh:buddy_save for
  # the escape-hatch contract.
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

  # Release in reverse acquisition order: buddy (inner) then session (outer).
  exec {buddy_lock_fd}>&-
  exec {session_lock_fd}>&-

  # Emit AFTER both lock releases + both saves committed. An interrupted
  # printf still leaves the buddy/session state matching what the user did
  # or didn't see (they didn't see it).
  if [[ -n "$commentary_line" ]]; then
    printf '%s\n' "$commentary_line"
  fi
  return 0
}

_main
exit 0
