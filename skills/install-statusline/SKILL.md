---
description: Install (or uninstall) the ambient buddy segment in your Claude Code status line. Consent-gated, reversible, takes a timestamped backup before any write.
disable-model-invocation: true
---

# /buddy:install-statusline

**IMMEDIATELY run the Bash command below and print its stdout verbatim. No preamble, no summary, no commentary. The script's output IS the response.**

Forward any subcommand and flags through unchanged: `install` (default), `uninstall`, `--dry-run`, `--help`.

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install_statusline.sh" <args>
```

If `${CLAUDE_PLUGIN_ROOT}` is unset, find `scripts/install_statusline.sh` by walking up from this file's directory.

If the script exits non-zero, print stderr after stdout so the user sees the error.

The script writes to `~/.claude/`. It always asks for consent and always writes a timestamped backup before mutating. The user has already seen and accepted the consent prompt by the time their answer reaches the script.

Take no other action. Do not describe what the script does. Do not roleplay as the buddy. Just show them the output.
