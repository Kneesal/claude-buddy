#!/usr/bin/env bash
# session-start.sh — SessionStart hook.
#
# Initializes (or resets) ${CLAUDE_PLUGIN_DATA}/session-<id>.json to the
# canonical initial shape, then sweeps orphan tmp files. Runs ONLY when
# the user has an active buddy (per D6 of the P3-1 plan): pre-hatch the
# hook stays fully passive — no session file is written, no cleanup is
# run, no signals accumulate.
#
# Contract:
#   - Always exits 0. An internal failure must never break the Claude
#     Code session.
#   - Empty stdout. P3-1 has no commentary; P3-2 extends this later.
#   - p95 runtime target < 100ms.

_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Swallow stderr from sourced libraries — `state.sh` logs diagnostics
# there, and we do not want anything surfaced to the Claude transcript.
# Durable logging goes through hook_log_error (→ error.log).
exec 2>/dev/null

if ! source "$_HOOK_DIR/../scripts/lib/state.sh" 2>/dev/null; then
  exit 0
fi
if ! source "$_HOOK_DIR/../scripts/hooks/common.sh" 2>/dev/null; then
  exit 0
fi

_main() {
  local payload
  payload="$(hook_drain_stdin)"

  local state
  state="$(buddy_load)"

  case "$state" in
    "$STATE_NO_BUDDY")
      # Pre-hatch: fully passive. No session file, no orphan sweep.
      # D6 says sweeps begin once a buddy exists.
      return 0
      ;;
    "$STATE_CORRUPT"|"$STATE_FUTURE_VERSION")
      hook_log_error "session-start" "buddy state sentinel: $state"
      return 0
      ;;
  esac

  local sid
  if ! sid="$(hook_extract_session_id "$payload")"; then
    hook_log_error "session-start" "missing or invalid session_id in payload"
    return 0
  fi

  # Write the fresh session shape. We intentionally overwrite whatever
  # was there — SessionStart is authoritative per D3.
  if ! hook_initial_session_json "$sid" | session_save "$sid"; then
    hook_log_error "session-start" "session_save failed for $sid"
    return 0
  fi

  # Sweep orphan tmps AFTER the write so a cleanup stumble can't delay
  # session init. Wall-clock-bounded to 80ms via a background + watchdog
  # pair — a data dir with thousands of stale .tmp files can blow the
  # 100ms budget on the per-file kill -0 loop inside
  # state_cleanup_orphans. `timeout` can't wrap an in-process bash
  # function, hence the manual pattern.
  state_cleanup_orphans >/dev/null 2>&1 &
  local _cleanup_pid=$!
  ( sleep 0.08 && kill -KILL "$_cleanup_pid" 2>/dev/null ) >/dev/null 2>&1 &
  local _watchdog_pid=$!
  wait "$_cleanup_pid" 2>/dev/null || true
  kill "$_watchdog_pid" 2>/dev/null || true
  wait "$_watchdog_pid" 2>/dev/null || true

  return 0
}

_main
exit 0
