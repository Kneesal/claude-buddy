---
description: View your coding buddy as a full menu — sprite, XP bar, the five rarity stat bars, the four signal counters, token balance, and pointers to related commands.
disable-model-invocation: true
---

# /buddy:stats

**IMMEDIATELY run this Bash command and print its stdout verbatim. No preamble, no summary, no commentary. The script's output IS the response.**

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
```

If `${CLAUDE_PLUGIN_ROOT}` is unset or that path doesn't exist, find `scripts/status.sh` by walking up from this file's directory and run that path instead.

If the script exits non-zero, print stderr after stdout so the user sees the error.

This command takes no arguments — ignore any extra tokens in the user's message.

Do not describe what the script does. Do not roleplay as the buddy. Just show them the output.

## Debugging silent hook failures

Hooks log internal failures to `${CLAUDE_PLUGIN_DATA}/error.log` — tab-separated lines of `ISO-timestamp\thook-name\treason`. If the user asks why the buddy isn't reacting or evolving, that file is the first place to look. Hooks intentionally never surface stderr to the Claude transcript; silence in the chat does not mean silence in the log.
