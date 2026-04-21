#!/usr/bin/env bash
# post-tool-use.sh — PostToolUse hook.
#
# Two jobs per fire, both inside the per-session flock:
#   1. Maintain the dedup ring on recentToolCallIds (last 20). If the
#      tool-call ID is already seen, skip the rest — the PTUF hook
#      has already processed this tool call.
#   2. Consult the commentary engine (P3-2). If it decides to emit,
#      save the updated session JSON under the same lock, release
#      the lock, then print the line to stdout AFTER the lock is
#      released and the save has committed.
#
# Emit ordering is deliberate: the line appears in the Claude Code
# transcript via stdout on hook exit 0 (per the hooks docs). Printing
# after session_save means a crash between the printf and the save
# can't leave the budget/cooldown state out of sync with what the
# user saw.
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

  # Per-session flock around the whole load-modify-save cycle.
  # Mirrors buddy_save's exec-{fd} flock discipline. See P3-1 review #2
  # and docs/solutions/best-practices/bash-state-library-concurrent-
  # load-modify-save-2026-04-20.md.
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
    # Duplicate tool-call ID — PTUF fired first. Skip commentary too:
    # we don't want two fires for one logical event.
    exec {lock_fd}>&-
    return 0
  fi

  # Consult the commentary engine. Returns two-line stdout:
  #   line 1: comment line (empty if no emit)
  #   line 2: updated session JSON (jq -c compacted)
  local commentary_out commentary_line final_session
  commentary_out="$(hook_commentary_select "PostToolUse" "$ring_updated" "$buddy_json")"
  commentary_line="${commentary_out%%$'\n'*}"
  final_session="${commentary_out#*$'\n'}"
  if [[ -z "$final_session" ]]; then
    # Defensive — commentary engine should always emit a session JSON.
    # If it didn't, persist the ring update alone.
    final_session="$ring_updated"
    commentary_line=""
  fi

  if ! printf '%s' "$final_session" | session_save "$sid"; then
    exec {lock_fd}>&-
    hook_log_error "$hook_name" "session_save failed for $sid"
    return 0
  fi

  exec {lock_fd}>&-

  # Emit AFTER lock release + save commit. If this printf is ever
  # interrupted, the budget/cooldown state still matches what the
  # user did or didn't see (they didn't see it).
  if [[ -n "$commentary_line" ]]; then
    printf '%s\n' "$commentary_line"
  fi
  return 0
}

_main
exit 0
