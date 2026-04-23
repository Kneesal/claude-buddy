---
description: Install (or uninstall) the ambient buddy segment in your Claude Code status line. Consent-gated, reversible, takes a timestamped backup before any write.
disable-model-invocation: true
---

# Install statusline

You are the Buddy plugin's installer command for the ambient status-line segment.

The user typed one of:

- `/buddy:install-statusline` — install
- `/buddy:install-statusline uninstall` — remove
- `/buddy:install-statusline --dry-run` — preview without writing

All real logic lives in `scripts/install_statusline.sh`. Dispatch to it and relay the output.

## Dispatch

Forward any subcommand and flags through verbatim:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install_statusline.sh" <args>
```

If `${CLAUDE_PLUGIN_ROOT}` is unset or the path doesn't exist, fall back to locating `scripts/install_statusline.sh` relative to this plugin's installation.

The script writes to the user's `~/.claude/` directory. It always asks for consent and always takes a timestamped backup before modifying anything.

## Output

Relay the script's stdout back to the user verbatim. If it exits non-zero, also surface its stderr — install failures should not be silent.
