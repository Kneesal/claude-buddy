---
description: Check in with your buddy — renders the sprite plus a short speech bubble line. Read-only; no XP, no cooldowns, no commentary-budget cost.
disable-model-invocation: true
---

# /buddy:interact

> **Fallback path.** The canonical dispatch is the buddy plugin's `UserPromptSubmit` hook (`hooks/user-prompt-submit.sh` → `scripts/dispatch.sh` → `scripts/interact.sh`). If the hook fires, this body never reaches you. You're seeing it only when the hook didn't run.

**IMMEDIATELY run this Bash command and print its stdout verbatim. No preamble, no summary, no commentary. The script's output IS the response.**

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/interact.sh"
```

If `${CLAUDE_PLUGIN_ROOT}` is unset or that path doesn't exist, find `scripts/interact.sh` by walking up from this file's directory and run that path instead.

If the script exits non-zero, print stderr after stdout so the user sees the error.

This command takes no arguments — ignore any extra tokens in the user's message.

Do not describe what the script does. Do not roleplay as the buddy. Just show them the output.
