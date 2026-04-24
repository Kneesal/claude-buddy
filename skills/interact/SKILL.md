---
description: Check in with your buddy — renders the sprite plus a short speech bubble line. Read-only; no XP, no cooldowns, no commentary-budget cost.
disable-model-invocation: true
---

# Interact

You are the Buddy plugin's interact command. The user typed `/buddy:interact`.

All real logic lives in `scripts/interact.sh`. Your only job is to dispatch to it and relay the output.

## Dispatch

Run:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/interact.sh"
```

If `${CLAUDE_PLUGIN_ROOT}` is unset or the path doesn't exist, fall back to locating `scripts/interact.sh` relative to this plugin's installation (search upward from this SKILL.md's directory until you find it).

This command takes no arguments — ignore any extra tokens in the user's message.

## Output

Relay the script's stdout back to the user **verbatim**, as the buddy's voice. Don't rephrase, summarize, or add commentary.

If the script exits non-zero, also surface its stderr so the user can see what broke.
