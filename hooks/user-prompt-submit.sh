#!/usr/bin/env bash
# user-prompt-submit.sh — UserPromptSubmit hook glue.
#
# When the user types /buddy:<cmd> [args] in Claude Code, this hook fires
# before the prompt reaches the model. We:
#   1. Read the payload JSON from stdin (Claude Code pipes it).
#   2. Extract the user's typed line from .prompt.
#   3. Cheap pre-filter: prompts that don't start with /buddy: pass
#      through to the model (silent exit).
#   4. Call scripts/dispatch.sh to do the lexical routing + script
#      invocation. Capture combined stdout+stderr.
#   5. Encode the captured output as JSON and emit
#      `{"decision":"block","reason":"<output>"}` — Claude Code
#      short-circuits the model and shows the reason text to the user.
#
# Internal-failure discipline (matches the rest of the plugin):
#   - Any failure (jq missing, dispatch.sh missing, malformed payload)
#     is logged to ${CLAUDE_PLUGIN_DATA}/error.log via hook_log_error
#     and the hook exits 0 silent. The user's prompt then passes
#     through to the model, which falls back to the SKILL.md path.
#   - Empty dispatcher output is also a fall-through — defense in
#     depth in case dispatch.sh's regex rejects something we matched
#     in the pre-filter.
#
# Short-circuit shape verified by the spike at
# docs/solutions/developer-experience/claude-code-userpromptsubmit-shortcircuit-2026-04-30.md.

_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec 2>/dev/null

if ! source "$_HOOK_DIR/../scripts/lib/state.sh" 2>/dev/null; then
  exit 0
fi
if ! source "$_HOOK_DIR/../scripts/hooks/common.sh" 2>/dev/null; then
  exit 0
fi

_main() {
  local payload prompt output
  payload="$(hook_drain_stdin)" || {
    hook_log_error "user-prompt-submit" "drain-stdin-failed"
    return 0
  }
  [[ -z "$payload" ]] && return 0

  if ! command -v jq >/dev/null 2>&1; then
    hook_log_error "user-prompt-submit" "jq-not-found"
    return 0
  fi

  prompt="$(printf '%s' "$payload" | jq -r '.prompt // empty' 2>/dev/null)" || {
    hook_log_error "user-prompt-submit" "jq-extract-prompt-failed"
    return 0
  }

  # Cheap pre-filter — non-buddy prompts are 99% of traffic.
  [[ "$prompt" == /buddy:* ]] || return 0

  local dispatch_sh="$_HOOK_DIR/../scripts/dispatch.sh"
  if [[ ! -f "$dispatch_sh" ]]; then
    hook_log_error "user-prompt-submit" "dispatch-script-missing"
    return 0
  fi

  output="$(bash "$dispatch_sh" "$prompt" 2>&1)" || true

  # Empty output → fall through to model + SKILL.md fallback path.
  [[ -z "$output" ]] && return 0

  # Encode output as JSON; inject as additionalContext (NOT decision:block).
  #
  # Why not decision:block: it stamps "Operation blocked by a hook" on the
  # response and paints the text in a yellow warning color, overriding the
  # ANSI rarity coloring. The systemMessage variant has the same chrome.
  #
  # Architecture (P4-7 hybrid render):
  #   1. dispatch.sh wrote the ANSI-rich output to /dev/tty already
  #      (terminal user sees full color sprite immediately).
  #   2. dispatch.sh emitted ANSI-stripped plain Unicode on stdout — that's
  #      the $output we have here. No ANSI escapes means no code-fence
  #      triggers, and the model relays plain Unicode byte-for-byte (5/5
  #      verbatim in the spike; matches dcastro12/claude-buddy-mcp's
  #      proven-in-the-wild approach).
  #   3. SKILL.md tells the model "print the additionalContext verbatim,
  #      no code fences, no commentary."
  #
  # The model is back in the loop (api_ms > 0) so this is not 100%
  # deterministic — but the relay reliability for plain Unicode is high
  # enough that the no-chrome UX is worth it.
  local json_msg
  if ! json_msg="$(printf '%s' "$output" | jq -Rs '.' 2>/dev/null)"; then
    hook_log_error "user-prompt-submit" "jq-encode-message-failed"
    return 0
  fi

  printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}' "$json_msg"
  return 0
}

_main
exit 0
