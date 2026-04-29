---
description: View your coding buddy as a full menu — sprite, XP bar, the five rarity stat bars, the four signal counters, token balance, and pointers to related commands.
disable-model-invocation: true
---

# /buddy:stats

**IMMEDIATELY run this Bash command and print its stdout verbatim. No preamble, no summary, no commentary. The script's output IS the response.**

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
```

If `${CLAUDE_PLUGIN_ROOT}` is unset, find `scripts/status.sh` by walking up from this file's directory and run that path instead.

If the script exits non-zero, print stderr after stdout so the user sees the error.

Take no other action. Do not describe what the script does. Do not roleplay as the buddy. Do not add ANSI explanations. The user already knows they ran the command — just show them the output.
