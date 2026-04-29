---
description: Install (or uninstall) the ambient buddy segment in your Claude Code status line. Consent-gated, reversible, takes a timestamped backup before any write.
disable-model-invocation: true
---

# /buddy:install-statusline

**Run the Bash command below for the chosen subcommand and print its stdout verbatim.** No preamble, no summary, no commentary. The script's output IS the response.

## Decide the subcommand

Read the user's message. Pick the matching code block from the Run section.

| User intent | Subcommand to run |
|---|---|
| `/buddy:install-statusline` (no args) or "install" | `install` |
| "preview" / "dry run" / "--dry-run" | `install --dry-run` |
| "uninstall" / "remove" | `uninstall` |
| "uninstall, dry run" | `uninstall --dry-run` |
| Explicit "yes, install with --yes" or first install was cancelled and user wants to skip the consent prompt | `install --yes` |
| "help" / "--help" | `--help` |

## Important: consent prompt EOFs in slash-command dispatch

The script's interactive consent prompt reads from stdin via `read -r`. When invoked through this slash command, stdin is empty, so the read EOFs and the script cancels with "Cancelled — no changes made." That's safe (no mutation), but the install will appear to do nothing.

If the user runs `install` and gets a "Cancelled" message, tell them they can pass `--yes` to skip the consent prompt: `/buddy:install-statusline --yes`. Don't pass `--yes` on their behalf unless they explicitly asked for it.

## Run

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install_statusline.sh" install
```

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install_statusline.sh" install --dry-run
```

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install_statusline.sh" install --yes
```

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install_statusline.sh" uninstall
```

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install_statusline.sh" uninstall --dry-run
```

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install_statusline.sh" --help
```

If `${CLAUDE_PLUGIN_ROOT}` is unset or that path doesn't exist, find `scripts/install_statusline.sh` by walking up from this file's directory and run that path instead.

If the script exits non-zero, print stderr after stdout so the user sees the error.

Do not describe what the script does. Do not roleplay as the buddy. Just show them the output.
