---
description: Wipe your current buddy and all its progress. Requires --confirm.
disable-model-invocation: true
---

# /buddy:reset

## Primary path — print the additionalContext verbatim

The buddy plugin's `UserPromptSubmit` hook has already run `scripts/dispatch.sh` for this prompt. The hook applied a strict lexical rule for `--confirm` (only the exact token `/buddy:reset --confirm` triggers a wipe; anything else gets the consequences message instead). The dispatcher's full output is in your context as `additionalContext` — see the system-reminder injected above this prompt.

**Print that text exactly as your response.** Critical rules:

- DO NOT wrap the output in markdown code fences (no triple backticks). The output already contains ANSI escape sequences and box-drawing characters; it is NOT code and must NOT be presented as a code block.
- DO NOT strip ANSI escape codes (sequences like \033[90m, \e[0m, ESC-bracket-digits-m). They control colors. The user's terminal interprets them. They look like garbage in the source — preserve them anyway.
- DO NOT add preamble, summary, commentary, or trailing decoration.
- DO NOT paraphrase, reformat, re-indent, or "clean up" the layout.
- DO NOT run any Bash tool. The output is already computed.
- DO NOT roleplay as the buddy.
- Emit the text byte-for-byte.

If — and only if — there is no `additionalContext` from this hook in your context (older Claude Code, hook crashed silently), fall through to the fallback path below. **Reset is irreversibly destructive and writes no backup — when in doubt, omit `--confirm`.**

## Fallback path — run the Bash command yourself

**Run the Bash command below and print its stdout verbatim.** No preamble, no summary, no commentary. The script's output IS the response.

## First decide whether the user is directing a wipe

`/buddy:reset --confirm` is **irreversibly destructive** — the script writes no backup. A misread `--confirm` deletes the user's buddy with no recovery path. Pass `--confirm` ONLY if the user is unambiguously directing you to execute the wipe. If you're not sure, omit it: the no-confirm path prints the consequences message and lets the user decide.

**Pass `--confirm`** when the user typed `/buddy:reset --confirm`, said "yes wipe it with --confirm", "yes reset", or otherwise unambiguously asked to proceed.

**Do NOT pass `--confirm`** in any of these cases — even when the literal token `--confirm` appears in the message:

- "what does --confirm do" / "explain the --confirm flag" — they're asking, not directing
- "don't reset yet" / "don't use --confirm" — they're declining
- "should I --confirm?" / "i guess --confirm" — they're hesitating, not directing
- The token appears inside quoted documentation or example code
- You can't tell whether it's a directive or a mention — when in doubt, omit it

Treat any question about the command (any phrasing of "what does this do") as a request for the consequences message, NOT a directive to execute.

## Run

With `--confirm`:
```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/reset.sh" --confirm
```

Without `--confirm`:
```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/reset.sh"
```

If `${CLAUDE_PLUGIN_ROOT}` is unset or that path doesn't exist, find `scripts/reset.sh` by walking up from this file's directory and run that path instead.

If the script exits non-zero, print stderr after stdout so the user sees the error.

Do not describe what the script does. Do not roleplay as the buddy. Just show them the output.
