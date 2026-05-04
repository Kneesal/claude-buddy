#!/usr/bin/env bash
# dispatch.sh — Lexical router for /buddy:<cmd> [args] prompts.
#
# Single CLI entry point used by the UserPromptSubmit hook
# (hooks/user-prompt-submit.sh) to fan out to the five existing
# per-command scripts: hatch.sh, status.sh, interact.sh, reset.sh,
# install_statusline.sh. The router exists to centralize:
#
#   1. The regex match against the /buddy:* prefix.
#   2. The deterministic flag-forwarding rules — no model in the
#      loop, so token shapes are interpreted lexically.
#   3. The strict-arg rule for destructive commands (hatch, reset):
#      --confirm is honored ONLY when post-command args are exactly
#      the single token --confirm. This replaces the model-judged
#      "directive vs mention" rule the old SKILL.md prose carried,
#      with a simpler and stricter lexical rule.
#   4. The whitelist for /buddy:install-statusline subcommand+flag
#      shapes (install/install --dry-run/install --yes/uninstall/
#      uninstall --dry-run/--help). Anything outside the whitelist
#      falls through to a usage line — no underlying script call.
#
# Discipline:
#   - stats and interact ignore any post-command tokens (matches
#     the SKILL.md contract — both scripts take no args).
#   - Anything not matching ^/buddy:(hatch|stats|interact|reset|
#     install-statusline)\b → exit 0 silent. The caller (hook glue
#     or human) sees no output and the prompt is treated as
#     non-buddy.
#   - Internal failures (missing underlying script, broken plugin
#     root) → log to ${CLAUDE_PLUGIN_DATA}/error.log, emit a
#     short user-facing line, exit 0. Never break the user's
#     session.
#   - Underlying script's stderr is appended after its stdout when
#     the script exits non-zero (matches the old SKILL.md "print
#     stderr after stdout" contract).
#
# Usage:
#   dispatch.sh "<full prompt line including leading slash>"
#
# Returns:
#   - Exit 0 always (caller never differentiates internal vs
#     underlying-script failure via exit code; output is
#     authoritative).

set -uo pipefail

if [[ -n "${_DISPATCH_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
readonly _DISPATCH_SH_LOADED=1

# ---------------------------------------------------------------------------
# Path resolution. CLAUDE_PLUGIN_ROOT is set by Claude Code when the plugin
# is loaded; if it's missing (test direct invocation, etc.) we walk up from
# this script's location.
# ---------------------------------------------------------------------------

_dispatch_plugin_root() {
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -d "$CLAUDE_PLUGIN_ROOT/scripts" ]]; then
    printf '%s' "$CLAUDE_PLUGIN_ROOT"
    return 0
  fi
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # this script lives in <root>/scripts/dispatch.sh — root is the parent.
  printf '%s' "$(cd "$here/.." && pwd)"
}

_dispatch_log_error() {
  local reason="$1"
  local data_dir="${CLAUDE_PLUGIN_DATA:-}"
  [[ -z "$data_dir" ]] && return 0
  mkdir -p "$data_dir" 2>/dev/null || return 0
  local stamp
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)"
  printf '%s\tdispatch.sh\t%s\n' "$stamp" "$reason" \
    >> "$data_dir/error.log" 2>/dev/null || true
}

# Run the named script, forward stdout, and append stderr after stdout when
# exit code is non-zero (matches the SKILL.md "print stderr after stdout"
# contract that we preserve for parity with the fallback path).
_dispatch_exec() {
  local script="$1"; shift
  if [[ ! -f "$script" ]]; then
    _dispatch_log_error "missing script: $script"
    echo "buddy-dispatch: internal error — see ${CLAUDE_PLUGIN_DATA:-error.log} for details."
    return 0
  fi
  local stdout_file stderr_file rc
  stdout_file="$(mktemp 2>/dev/null)" || {
    _dispatch_log_error "mktemp failed"
    echo "buddy-dispatch: internal error — see ${CLAUDE_PLUGIN_DATA:-error.log} for details."
    return 0
  }
  stderr_file="$(mktemp 2>/dev/null)" || {
    rm -f "$stdout_file"
    _dispatch_log_error "mktemp failed"
    echo "buddy-dispatch: internal error — see ${CLAUDE_PLUGIN_DATA:-error.log} for details."
    return 0
  }
  bash "$script" "$@" >"$stdout_file" 2>"$stderr_file"
  rc=$?
  cat "$stdout_file"
  if (( rc != 0 )) && [[ -s "$stderr_file" ]]; then
    cat "$stderr_file"
  fi
  rm -f "$stdout_file" "$stderr_file"
  return 0
}

# ---------------------------------------------------------------------------
# Per-command routing.
# ---------------------------------------------------------------------------

# Strict --confirm: the post-command arg list must be EXACTLY a single token
# matching --confirm. Anything else (extra tokens, quoted variants, prose)
# yields no --confirm forwarding. This replaces the SKILL.md model-judged
# "directive vs mention" rule with a deterministic lexical rule.
_dispatch_route_destructive() {
  local script="$1" args="$2"
  # Trim whitespace.
  args="${args#"${args%%[![:space:]]*}"}"
  args="${args%"${args##*[![:space:]]}"}"
  if [[ "$args" == "--confirm" ]]; then
    _dispatch_exec "$script" --confirm
  else
    _dispatch_exec "$script"
  fi
}

# install-statusline whitelist. The SKILL.md table maps user intents to a
# fixed set of {subcommand, flag} shapes. Mirror that table here lexically
# (no fuzzy matching, no model judgment).
_dispatch_route_install_statusline() {
  local script="$1" args="$2"
  args="${args#"${args%%[![:space:]]*}"}"
  args="${args%"${args##*[![:space:]]}"}"
  case "$args" in
    "")                          _dispatch_exec "$script" install ;;
    "install")                   _dispatch_exec "$script" install ;;
    "install --dry-run")         _dispatch_exec "$script" install --dry-run ;;
    "--dry-run")                 _dispatch_exec "$script" install --dry-run ;;
    "install --yes" | "install -y") _dispatch_exec "$script" install --yes ;;
    "--yes" | "-y")              _dispatch_exec "$script" install --yes ;;
    "uninstall")                 _dispatch_exec "$script" uninstall ;;
    "uninstall --dry-run")       _dispatch_exec "$script" uninstall --dry-run ;;
    "--help" | "-h" | "help")    _dispatch_exec "$script" --help ;;
    *)
      cat <<EOF
Usage: /buddy:install-statusline [<subcommand>] [flags]
  (no args)                  install with consent prompt
  --yes                      install, skip consent (use in slash dispatch)
  --dry-run                  preview the install diff, no writes
  uninstall                  remove the buddy block from your statusline
  uninstall --dry-run        preview the uninstall diff
  --help                     this message
EOF
      ;;
  esac
}

_dispatch_main() {
  local prompt="${1:-}"
  # Trim leading/trailing whitespace.
  prompt="${prompt#"${prompt%%[![:space:]]*}"}"
  prompt="${prompt%"${prompt##*[![:space:]]}"}"
  [[ -z "$prompt" ]] && return 0

  # Anchored regex: only the start of the line is a /buddy:<cmd> trigger.
  # Word-boundary on cmd via [[:space:]] or end-of-string — prevents
  # /buddy:hatcher from triggering hatch.
  local cmd args
  if [[ "$prompt" =~ ^/buddy:(hatch|stats|interact|reset|install-statusline)([[:space:]]+(.*))?$ ]]; then
    cmd="${BASH_REMATCH[1]}"
    args="${BASH_REMATCH[3]:-}"
  else
    return 0
  fi

  local root
  root="$(_dispatch_plugin_root)"

  case "$cmd" in
    hatch)
      _dispatch_route_destructive "$root/scripts/hatch.sh" "$args"
      ;;
    reset)
      _dispatch_route_destructive "$root/scripts/reset.sh" "$args"
      ;;
    stats)
      # ignore extra tokens — script takes no args
      _dispatch_exec "$root/scripts/status.sh"
      ;;
    interact)
      # ignore extra tokens — script takes no args
      _dispatch_exec "$root/scripts/interact.sh"
      ;;
    install-statusline)
      _dispatch_route_install_statusline "$root/scripts/install_statusline.sh" "$args"
      ;;
  esac
  return 0
}

_dispatch_main "$@"
