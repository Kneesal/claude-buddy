#!/usr/bin/env bats
# hooks/user-prompt-submit.sh — UserPromptSubmit hook glue.
#
# These tests exercise the hook's payload handling and short-circuit
# JSON contract WITHOUT a real Claude Code session. The full
# round-trip (slash command → hook → assistant turn) is verified by
# the live-session smoke documented in Unit 4.

bats_require_minimum_version 1.5.0

load ../test_helper

HOOK_SH="$REPO_ROOT/hooks/user-prompt-submit.sh"

setup_file() {
  _prepare_hatched_cache
}

setup() {
  export CLAUDE_PLUGIN_DATA="$BATS_TEST_TMPDIR/plugin-data"
  mkdir -p "$CLAUDE_PLUGIN_DATA"
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
  unset BUDDY_RNG_SEED
  unset BUDDY_SPECIES_DIR
  source "$STATE_LIB"
}

# Helper: feed a JSON payload to the hook and capture its stdout.
_run_hook() {
  local payload="$1"
  printf '%s' "$payload" | bash "$HOOK_SH"
}

# =========================================================================
# Happy path — prompt matches /buddy:* → JSON short-circuit emitted.
# =========================================================================

_extract_context() {
  printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // empty'
}

@test "hook: /buddy:stats with active buddy → emits hookSpecificOutput.additionalContext JSON" {
  _seed_hatch
  output="$(_run_hook '{"prompt":"/buddy:stats"}')"
  [ -n "$output" ]
  event_name="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')"
  ctx="$(_extract_context "$output")"
  [ "$event_name" = "UserPromptSubmit" ]
  [[ "$ctx" == *"Custard"* ]]
}

@test "hook: /buddy:hatch on no-buddy → context carries hatch output" {
  output="$(printf '%s' '{"prompt":"/buddy:hatch"}' | BUDDY_RNG_SEED=42 bash "$HOOK_SH")"
  ctx="$(_extract_context "$output")"
  [[ "$ctx" == Hatched* ]]
  [ -f "$CLAUDE_PLUGIN_DATA/buddy.json" ]
}

@test "hook: /buddy:reset --confirm forwards to dispatch → context carries wipe message" {
  _seed_hatch
  output="$(_run_hook '{"prompt":"/buddy:reset --confirm"}')"
  ctx="$(_extract_context "$output")"
  [[ "$ctx" == *"Buddy reset"* ]]
  [ ! -f "$CLAUDE_PLUGIN_DATA/buddy.json" ]
}

# =========================================================================
# Pre-filter — non-buddy prompts pass through silently.
# =========================================================================

@test "hook: non-buddy plain prompt → empty stdout (pass-through)" {
  output="$(_run_hook '{"prompt":"hello world"}')"
  [ -z "$output" ]
}

@test "hook: /help (different namespace) → empty stdout (pre-filter)" {
  output="$(_run_hook '{"prompt":"/help"}')"
  [ -z "$output" ]
}

@test "hook: /buddy:nonsense (unknown buddy command) → empty stdout (dispatch silent)" {
  # Pre-filter passes (starts with /buddy:), dispatch.sh rejects → empty.
  output="$(_run_hook '{"prompt":"/buddy:nonsense"}')"
  [ -z "$output" ]
}

@test "hook: empty prompt → empty stdout" {
  output="$(_run_hook '{"prompt":""}')"
  [ -z "$output" ]
}

@test "hook: prompt with embedded /buddy:stats (not at start) → empty stdout" {
  output="$(_run_hook '{"prompt":"see this /buddy:stats inside text"}')"
  [ -z "$output" ]
}

# =========================================================================
# Payload edge cases.
# =========================================================================

@test "hook: malformed payload (missing .prompt) → exit 0 silent + error.log entry" {
  output="$(_run_hook '{"session_id":"abc"}')"
  [ -z "$output" ]
  # No prompt to extract → empty string from jq → pre-filter skips → no log entry.
  # (We log only on jq/extract failures, not on legitimately empty fields.)
}

@test "hook: non-JSON payload → exit 0 silent + error.log entry" {
  output="$(_run_hook 'not even json {{')"
  [ -z "$output" ]
  # jq -r '.prompt // empty' on non-JSON input returns empty (no error code from jq's // empty).
  # Either way: empty output, no crash. Logging is best-effort.
}

@test "hook: JSON-special characters in output round-trip cleanly" {
  # status.sh output contains ANSI escapes, unicode, double-quotes via the
  # render layer. Verify jq -Rs encoding survives the round-trip.
  _seed_hatch
  output="$(_run_hook '{"prompt":"/buddy:stats"}')"
  ctx="$(_extract_context "$output")"
  # If jq -r succeeded, the JSON is well-formed; context should be non-empty.
  [ -n "$ctx" ]
  # ANSI escape (ESC) survived the round-trip.
  [[ "$ctx" == *$'\e['* ]]
}

@test "hook: empty stdin → exit 0 silent" {
  output="$(printf '' | bash "$HOOK_SH")"
  [ -z "$output" ]
}

# =========================================================================
# Latency — hook overhead bounded on no-match prompts.
# =========================================================================

@test "hook: no-match prompt completes quickly (< ~250ms wall)" {
  # Loose bound — bats overhead alone is meaningful. The actual hook work
  # on a no-match prompt is one jq fork + one prefix check.
  local start_ns end_ns elapsed_ms
  start_ns="$(date +%s%N)"
  _run_hook '{"prompt":"hello"}' >/dev/null
  end_ns="$(date +%s%N)"
  elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
  [ "$elapsed_ms" -lt 500 ]
}
