---
description: View your coding buddy as a full menu — sprite, XP bar, the five rarity stat bars, the four signal counters, token balance, and pointers to related commands.
disable-model-invocation: true
---

# /buddy:stats

## Primary path — print the additionalContext verbatim

The buddy plugin's `UserPromptSubmit` hook has already run `scripts/dispatch.sh` and placed the rendered buddy menu in your context as `additionalContext` (see the system-reminder injected above this prompt). The text is plain Unicode (no ANSI escape codes — those went to `/dev/tty` directly for terminal users).

**Print that text exactly as your response.** Critical rules:

- DO NOT wrap the output in markdown code fences (no triple backticks). It's a UI render, not code.
- DO NOT add preamble, summary, commentary, or trailing decoration.
- DO NOT paraphrase, reformat, or "clean up" the layout.
- DO NOT run any Bash tool. The output is already computed.
- DO NOT roleplay as the buddy.
- Emit the text byte-for-byte.

If — and only if — there is no `additionalContext` from this hook in your context (older Claude Code, hook crashed silently), fall through to the fallback below.

## Fallback path — run the Bash command yourself

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
