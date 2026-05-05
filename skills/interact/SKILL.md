---
description: Check in with your buddy — renders the sprite plus a short speech bubble line. Read-only; no XP, no cooldowns, no commentary-budget cost.
disable-model-invocation: true
---

# /buddy:interact

## Primary path — print the additionalContext verbatim

The buddy plugin's `UserPromptSubmit` hook has already run `scripts/dispatch.sh` and placed the rendered buddy speech-bubble output in your context as `additionalContext` (see the system-reminder injected above this prompt).

**Print that text exactly as your response.** Critical rules:

- DO NOT wrap the output in markdown code fences (no triple backticks). The output already contains ANSI escape sequences and box-drawing characters; it is NOT code and must NOT be presented as a code block.
- DO NOT strip ANSI escape codes (sequences like `\033[90m`, `\e[0m`, ESC-bracket-digits-m). They control colors. The user's terminal interprets them. They look like garbage in the source — preserve them anyway.
- DO NOT add preamble, summary, commentary, or trailing decoration.
- DO NOT paraphrase, reformat, re-indent, or "clean up" the ASCII art.
- DO NOT run any Bash tool. The output is already computed.
- DO NOT roleplay as the buddy.
- Emit the text byte-for-byte.

If — and only if — there is no `additionalContext` from this hook in your context, fall through to the fallback below.

## Fallback path — run the Bash command yourself

**IMMEDIATELY run this Bash command and print its stdout verbatim. No preamble, no summary, no commentary. The script's output IS the response.**

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/interact.sh"
```

If `${CLAUDE_PLUGIN_ROOT}` is unset or that path doesn't exist, find `scripts/interact.sh` by walking up from this file's directory and run that path instead.

If the script exits non-zero, print stderr after stdout so the user sees the error.

This command takes no arguments — ignore any extra tokens in the user's message.

Do not describe what the script does. Do not roleplay as the buddy. Just show them the output.
