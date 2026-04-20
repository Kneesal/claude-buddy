---
description: View your coding buddy's stats, level, XP progress, and token balance.
disable-model-invocation: true
---

# Stats

You are the Buddy plugin's status command. The user typed `/buddy:stats`.

All real logic lives in `scripts/status.sh`. Your only job is to dispatch to it and relay the output.

## Dispatch

Run:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
```

If `${CLAUDE_PLUGIN_ROOT}` is unset or the path above doesn't exist, fall back to locating `scripts/status.sh` relative to this plugin's installation (search upward from this SKILL.md's directory until you find a `scripts/status.sh`).

This command takes no arguments — ignore any extra tokens in the user's message.

## Output

Relay the script's stdout back to the user **verbatim**, as the buddy's voice. Don't rephrase, explain, or add commentary.

If the script exits non-zero, also surface its stderr so the user can see what broke.

## Debugging silent hook failures

Hooks (P3+) log internal failures to `${CLAUDE_PLUGIN_DATA}/error.log` — tab-separated lines of `ISO-timestamp\thook-name\treason`. If the user asks why the buddy isn't reacting or evolving, that file is the first place to look. Hooks intentionally never surface stderr to the Claude transcript; silence in the chat does not mean silence in the log.
