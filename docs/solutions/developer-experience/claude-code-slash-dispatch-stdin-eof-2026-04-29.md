---
title: Slash-command dispatch closes stdin — interactive `read` prompts always EOF
date: 2026-04-29
category: developer-experience
module: scripts
problem_type: developer_experience
component: tooling
severity: high
applies_when:
  - Writing a Claude Code plugin script that prompts for confirmation via `read -r` from stdin
  - Adding a "are you sure" gate to any destructive operation in a plugin
  - Wondering why a plugin command silently cancels when invoked from a slash command but works from a real terminal
tags:
  - claude-code-plugin
  - slash-command
  - stdin
  - interactive-prompt
  - consent
  - tool-dispatch
  - bash
---

# Slash-command dispatch closes stdin — interactive `read` prompts always EOF

## Context

The `/buddy:install-statusline` command has a consent prompt before
mutating the user's `~/.claude/statusline-command.sh`:

```bash
_install_consent() {
  local prompt="$1" reply
  printf '%s [y/N] ' "$prompt" >&2
  if ! IFS= read -r reply; then
    return 1
  fi
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}
```

This works perfectly from a real terminal: prompt prints, user types `y`,
the install proceeds. It also works in tests via the
`BUDDY_INSTALL_ASSUME_YES=1` env var that bypasses the read.

It does NOT work from a slash command in a Claude Code session.

When a user types `/buddy:install-statusline`, the model loads the
SKILL.md and runs the bash via the Bash tool. The Bash tool spawns the
script with **stdin closed** (or empty / non-interactive). The `read -r`
returns immediately with EOF (status 1). The function returns 1. The
script prints "Cancelled — no changes made." and exits.

The user sees: the install command silently cancelled. No
prompt appeared. No clear error. The plugin looks broken — the SKILL.md
might even be telling the model that consent has already been given,
deepening the confusion.

This is structural. Any plugin script that uses `read -r` for
confirmation will hit this when invoked from a slash command.

## Guidance

**Don't rely on interactive `read` prompts inside plugin scripts.** Slash
dispatch closes stdin. The prompt will EOF every time and your
destructive-op gate becomes a "no, every time" gate.

Three ways to handle confirmation in a slash-dispatchable plugin:

### 1. `--yes` / `-y` flag (preferred for non-destructive consent)

Public CLI flag the user can pass to skip the interactive consent path.
Document it in `--help`. Tell the SKILL.md to suggest the flag when the
user gets a "Cancelled" message.

```bash
_install_main() {
  local subcmd="" passthrough=()
  for arg in "$@"; do
    case "$arg" in
      --yes|-y) export BUDDY_INSTALL_ASSUME_YES=1 ;;
      install|uninstall) [[ -z "$subcmd" ]] && subcmd="$arg" ;;
      *) passthrough+=("$arg") ;;
    esac
  done
  [[ -z "$subcmd" ]] && subcmd="install"
  case "$subcmd" in
    install) _install_run "${passthrough[@]}" ;;
    ...
  esac
}

_install_consent() {
  if [[ "${BUDDY_INSTALL_ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi
  # ... the read-from-stdin path stays for terminal users
}
```

The user typing `/buddy:install-statusline --yes` gets the install
without the prompt; the user typing it on a real terminal still gets
the y/N prompt.

### 2. Required explicit flag (for irreversibly destructive ops)

For operations like `/buddy:reset --confirm`, drop interactive `read`
entirely. Require the user to pass the destructive flag in their slash
command. The slash command's argument shape becomes the consent gate;
the script just checks the flag.

```bash
_main() {
  if [[ "$1" != "--confirm" ]]; then
    echo "All buddy data will be lost. Run /buddy:reset --confirm to continue."
    return 0
  fi
  _do_wipe
}
```

This is what `/buddy:reset` does. It works perfectly under slash
dispatch because there's no `read` involved — the consent is encoded in
the message text itself.

### 3. Two-step confirmation token (for very destructive ops)

Print a one-time confirmation phrase the user must paste back. This
crosses two messages: first invocation prints "to confirm, run /buddy:X
--token=ABC123"; second invocation with that token executes. Higher
friction but suitable for actions that would be catastrophic if
mis-triggered.

We don't use this pattern in buddy yet but it's the right shape for
plugins that touch shared infra (plugins that delete remote state, push
changes, hit external APIs, etc.).

### Anti-pattern: relying on EOF == "no"

The buddy installer originally treated the EOF case as "user said no".
That's incorrect. EOF means "stdin was never connected" — the user
neither said yes nor no, they just don't have a way to answer.
Surfacing this as "Cancelled" looks like the user said no when actually
the prompt was unreachable. Add a stdin-availability check and surface
the actual issue:

```bash
_install_consent() {
  if [[ "${BUDDY_INSTALL_ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi
  # Can we even prompt? If not, tell the user how to escape.
  if [[ ! -t 0 ]]; then
    echo "Interactive consent prompt isn't available in this dispatch context." >&2
    echo "Re-run with --yes (or -y) to bypass: install-statusline.sh install --yes" >&2
    return 1
  fi
  printf '%s [y/N] ' "$1" >&2
  read -r reply
  ...
}
```

This is defense in depth — the `--yes` flag is the primary path, the
stdin-tty check is the fallback that gives the user a clear next step
when they didn't pass the flag.

## Why This Matters

The failure mode is silent. The user types a command, the script
"runs", nothing happens. There's no error. There's no useful diagnostic.
The script even prints "Cancelled" as if the user made an active choice.
A plugin author can ship this and never notice — their dev workflow
runs the script directly in a terminal where stdin works fine, and CI
mocks consent via the test env var.

Worst case: the SKILL.md compounds the confusion by claiming the user
"has already accepted consent" — sending the model into an even deeper
confidence-but-wrong loop where it believes the install succeeded
because the SKILL.md says it did.

## When to Apply

Apply this learning when:

- Building any plugin script with a destructive or non-idempotent
  operation that needs user confirmation.
- Reviewing a plugin where users report "the command runs but nothing
  happens" or "it always says Cancelled."
- Adding any `read -r` prompt to a script that's intended to be invoked
  from a slash command.

Skip when:

- The script is genuinely terminal-only (a developer-tool that's never
  meant to be slash-dispatched).
- The script's only "read" is for parsing structured input from
  upstream pipelines (those are tool-friendly by design).

## Examples

**Test that proves the failure:**

```bash
# Empty stdin emulates slash-command dispatch context.
@test "install: --yes flag bypasses interactive consent under empty stdin" {
  echo "#!/usr/bin/env bash" > "$HOME/.claude/statusline-command.sh"
  unset BUDDY_INSTALL_ASSUME_YES

  run --separate-stderr bash -c \
    'bash "$0" install --yes </dev/null' "$INSTALL_SH"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Installed"* ]]
}

@test "install: WITHOUT --yes, empty stdin produces Cancelled (the slash-dispatch failure mode)" {
  echo "#!/usr/bin/env bash" > "$HOME/.claude/statusline-command.sh"
  unset BUDDY_INSTALL_ASSUME_YES

  run --separate-stderr bash -c \
    'bash "$0" install </dev/null' "$INSTALL_SH"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Cancelled"* ]]
}
```

The first test pins the working path (`--yes` flag bypasses). The second
test pins the failure mode itself, so a future "fix" that breaks `--yes`
will surface clearly.

## See Also

- `docs/solutions/developer-experience/skill-md-framing-as-execution-priming-2026-04-29.md`
  — the SKILL.md side of this story; the dispatcher must tell the user
  about `--yes` when they hit a "Cancelled" message.
- `scripts/install_statusline.sh` — the canonical implementation with
  `--yes` flag + flag-anywhere position handling.
- `scripts/reset.sh` — the alternative pattern (required `--confirm` flag,
  no `read` prompt).
