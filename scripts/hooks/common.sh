#!/usr/bin/env bash
# common.sh — Shared helpers for buddy plugin hook scripts.
#
# Hook scripts under hooks/ all share the same first ~20 lines of work:
# drain the stdin JSON payload Claude Code pipes in, pull out a session_id,
# sentinel-switch on buddy_load, and log any internal failures to a
# durable error.log rather than leaking stderr into the Claude transcript.
#
# This file centralizes that plumbing. Each exported function is safe to
# call from a sourcing script that does NOT set `set -euo pipefail` — we
# do not set it here either (same discipline as scripts/lib/state.sh).
# Callers check return values explicitly.
#
# Contract:
#   - Callers source scripts/lib/state.sh FIRST (it enforces the bash 4.1+
#     floor, defines sentinels, and exposes buddy_load / session_load /
#     session_save). This file then extends that surface with hook-specific
#     helpers.
#   - Every function exits 0 on logically-successful no-ops. Non-zero
#     return values indicate "caller should early-exit" rather than
#     "crash the hook."
#   - No function writes to stderr in a way Claude Code will surface.
#     Diagnostic text goes through hook_log_error to error.log.
#
# Hook entry-point discipline: every hooks/*.sh script runs
# `exec 2>/dev/null` BEFORE sourcing this file. It must come first
# because sourcing state.sh and common.sh themselves can trigger
# diagnostic stderr (bash 4.1 guard, re-source logging). Putting the
# redirect inside common.sh would miss those early writes, and any
# stderr that escapes lands in the Claude transcript. Durable logging
# still works — hook_log_error writes to error.log, not fd 2.

# Re-source guard — the state.sh pattern. Protects the readonlys below.
if [[ "${_BUDDY_HOOK_COMMON_LOADED:-}" != "1" ]]; then
  _BUDDY_HOOK_COMMON_LOADED=1

  # Bounded stdin drain. Claude Code hook payloads are small JSON blobs
  # (documented at https://code.claude.com/docs/en/hooks). 100ms is an
  # order of magnitude more than any legitimate payload takes to arrive.
  readonly HOOK_STDIN_TIMEOUT_SECS="0.1"

  # Ring-buffer size for recentToolCallIds. Matches the ticket spec
  # (last 20). Changing this is a downstream-visible contract so it lives
  # here rather than in each individual hook.
  readonly HOOK_RING_MAX=20
fi

# --- Logging ---

# Append a single ISO-8601 UTC line to ${CLAUDE_PLUGIN_DATA}/error.log.
# Silent success on write failure — the hook must never fail because
# logging failed. If CLAUDE_PLUGIN_DATA is unset or unwritable, the line
# is dropped.
#
# Usage: hook_log_error <hook-name> <reason>
hook_log_error() {
  local hook="$1"
  local reason="$2"
  local data_dir="${CLAUDE_PLUGIN_DATA:-}"
  [[ -z "$data_dir" ]] && return 0
  [[ ! -d "$data_dir" ]] && return 0
  [[ ! -w "$data_dir" ]] && return 0

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")"
  # Strip any embedded newlines from the reason so the log stays line-oriented.
  local safe_reason="${reason//$'\n'/ }"
  safe_reason="${safe_reason//$'\r'/ }"
  printf '%s\t%s\t%s\n' "$ts" "$hook" "$safe_reason" \
    >> "$data_dir/error.log" 2>/dev/null || true
  return 0
}

# --- Stdin drain ---

# Read the JSON payload Claude Code pipes to stdin. Emits the payload on
# stdout; callers capture via `payload="$(hook_drain_stdin)"`. Guarded
# with `timeout` so a parent that forgets to close the write end can't
# deadlock the hook. On timeout, emits whatever has arrived so far (which
# may be empty) — downstream jq will then fail the shape check and the
# hook will log + exit 0.
#
# Interactive (TTY) stdin is returned as empty — there is no payload to
# drain and `cat` would block forever on the terminal.
hook_drain_stdin() {
  if [[ -t 0 ]]; then
    return 0
  fi
  timeout "$HOOK_STDIN_TIMEOUT_SECS" cat 2>/dev/null || true
  return 0
}

# --- Payload field extraction ---

# Extract session_id from a JSON payload (passed as $1). Emits the
# validated session_id on stdout; returns 0 on success, 1 on any failure.
# Uses the validator from state.sh (_state_valid_session_id) so the
# character-class and length rules live in exactly one place.
#
# Returns 1 without stdout for: invalid JSON, missing field, null field,
# or a session_id that fails path/length validation.
hook_extract_session_id() {
  local payload="$1"
  [[ -z "$payload" ]] && return 1

  local sid
  # `// empty` collapses null and missing to the same empty-string case.
  sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
  [[ -z "$sid" ]] && return 1

  if ! _state_valid_session_id "$sid"; then
    return 1
  fi
  printf '%s' "$sid"
  return 0
}

# Extract the tool_use_id from a JSON payload. PostToolUse and
# PostToolUseFailure both carry `tool_use_id` (verified in the P3-1
# live-session smoke). The `tool_call_id` fallback is a defensive
# measure against payload-shape drift across Claude Code versions —
# some planning docs referred to it, though it is not what Claude Code
# actually sends. Emits the ID on stdout; returns 0 on success, 1 on
# failure.
#
# The ID is treated as an opaque string downstream — jq passes it as
# an --arg parameter, so shell-metacharacter content is inert.
hook_extract_tool_use_id() {
  local payload="$1"
  [[ -z "$payload" ]] && return 1

  local id
  id="$(printf '%s' "$payload" | jq -r '
    .tool_use_id // .tool_call_id // empty
  ' 2>/dev/null)"
  [[ -z "$id" ]] && return 1

  # Reject anything longer than 256 chars defensively; tool-call IDs are
  # short UUIDs in practice. This caps session-file growth from a hostile
  # or malformed payload.
  if (( ${#id} > 256 )); then
    return 1
  fi
  printf '%s' "$id"
  return 0
}

# --- Session-file shape ---

# Emit the canonical initial shape for session-<id>.json to stdout.
# Used by SessionStart (primary init) and by other hooks that find a
# missing session file (defensive re-init per D3 of the P3-1 plan).
#
# The shape (P3-2 + P4-1):
#   {
#     "schemaVersion": 1,
#     "sessionId": "<id>",
#     "startedAt": "<ISO-8601 UTC>",
#     "cooldowns": {},
#     "recentToolCallIds": [],
#     "lastEventType": null,
#     "commentsThisSession": 0,
#     "recentFailures": [],
#     "lastToolFilePath": "",
#     "commentary": {
#       "bags": {},
#       "firstEditFired": false
#     }
#   }
#
# schemaVersion is stamped here (not in session_save) because session
# files are the property of the hook layer; P3-1 owns their shape.
# The commentary/rate-limit fields are additive — older session files
# (pre-P3-2) that round-trip through session_load → modify → session_save
# pick up the new fields lazily via jq `// default` reads in
# commentary.sh, so mid-session plugin upgrades don't need a migration.
# lastToolFilePath (P4-1) is the same: additive, defaulted to "" on
# read. Feeds chaos.repeatedEditHits — see scripts/hooks/signals.sh.
hook_initial_session_json() {
  local session_id="$1"
  local started_at
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")"
  jq -n \
    --arg sid "$session_id" \
    --arg ts "$started_at" \
    '{
      schemaVersion: 1,
      sessionId: $sid,
      startedAt: $ts,
      cooldowns: {},
      recentToolCallIds: [],
      lastEventType: null,
      commentsThisSession: 0,
      recentFailures: [],
      lastToolFilePath: "",
      commentary: {
        bags: {},
        firstEditFired: false
      }
    }'
}

# --- Ring-buffer update ---

# Given a session JSON on stdin and a tool-call ID as $1, emit EITHER:
#   - the literal string "DEDUP" (caller must skip the session write), OR
#   - updated session JSON with the ID appended to recentToolCallIds and
#     the array truncated to HOOK_RING_MAX entries (keeping the most-
#     recent tail).
#
# Combining the dedup check and the push into one jq invocation saves
# a fork per PostToolUse / PostToolUseFailure — ~5ms on the measured
# p95 budget (perf-1 in the P3-1 review).
hook_ring_update() {
  local id="$1"
  jq -r --arg id "$id" --argjson max "$HOOK_RING_MAX" '
    if ((.recentToolCallIds // []) | any(. == $id)) then
      "DEDUP"
    else
      (.recentToolCallIds = (((.recentToolCallIds // []) + [$id]) | .[-($max):]))
      | tojson
    end
  '
}

# Raw ring-push without the dedup short-circuit. Kept for test isolation
# and for callers that have already performed their own membership check.
# Duplicate IDs are MOVED to the tail (remove-then-append); if "no-op on
# duplicate" is the intent, use hook_ring_update or gate this call behind
# hook_ring_contains.
hook_ring_push() {
  local id="$1"
  jq --arg id "$id" --argjson max "$HOOK_RING_MAX" '
    .recentToolCallIds = (
      ((.recentToolCallIds // []) | map(select(. != $id))) + [$id]
      | .[-($max):]
    )
  '
}

# Return 0 if the given tool-call ID is already present in the session
# JSON's recentToolCallIds array; 1 otherwise.
#
# Usage:
#   if hook_ring_contains "$session_json" "$id"; then
#     # dedup — skip further work
#   fi
hook_ring_contains() {
  local session_json="$1"
  local id="$2"
  local hit
  hit="$(printf '%s' "$session_json" | jq -r --arg id "$id" '
    (.recentToolCallIds // []) | any(. == $id)
  ' 2>/dev/null)"
  [[ "$hit" == "true" ]]
}
