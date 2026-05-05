---
description: Hatch a new coding buddy — rolls a random species, rarity, stats, and personality. Rerolling requires --confirm.
disable-model-invocation: true
---

# /buddy:hatch

## Primary path — print the additionalContext verbatim

The buddy plugin's `UserPromptSubmit` hook has already run `scripts/dispatch.sh` for this prompt. The hook applied a strict lexical rule for `--confirm` (only the exact token `/buddy:hatch --confirm` triggers a reroll; extra tokens like `/buddy:hatch what does --confirm do` drop the flag and produce the consequences message instead). The dispatcher's plain-Unicode output is in your context as `additionalContext`.

**Print that text exactly as your response.** Critical rules:

- DO NOT wrap in markdown code fences. It's a UI render, not code.
- DO NOT add preamble, summary, commentary, or paraphrase.
- DO NOT run any Bash tool. The output is already computed.
- DO NOT roleplay as the buddy.
- Emit byte-for-byte.

If — and only if — there is no `additionalContext` from this hook in your context, fall through to the fallback path below.

## Fallback path — run the Bash command yourself

**Run the Bash command below and print its stdout verbatim.** No preamble, no summary, no commentary. The script's output IS the response.

## First decide whether the user is directing a reroll

`/buddy:hatch --confirm` is destructive — it wipes the existing buddy and rolls a new one. Pass `--confirm` ONLY if the user is unambiguously directing you to execute the destructive reroll. If you're not sure, omit it: the script's safer no-confirm path prints the consequences message and lets the user decide.

**Pass `--confirm`** when the user typed `/buddy:hatch --confirm`, said "go ahead and reroll with --confirm", "yes reroll", or otherwise unambiguously asked to proceed.

**Do NOT pass `--confirm`** in any of these cases — even when the literal token `--confirm` appears in the message:

- "what does --confirm do" / "explain the --confirm flag" — they're asking, not directing
- "don't reroll yet" / "don't use --confirm" — they're declining
- "should I --confirm?" / "i guess --confirm" — they're hesitating, not directing
- The token appears inside quoted documentation or example code
- You can't tell whether it's a directive or a mention — when in doubt, omit it

Treat any question about the command (any phrasing of "what does this do") as a request for the consequences message, NOT a directive to execute.

## Run

With `--confirm`:
```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/hatch.sh" --confirm
```

Without `--confirm`:
```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/hatch.sh"
```

If `${CLAUDE_PLUGIN_ROOT}` is unset or that path doesn't exist, find `scripts/hatch.sh` by walking up from this file's directory and run that path instead.

If the script exits non-zero, print stderr after stdout so the user sees the error.

Do not describe what the script does. Do not roleplay as the buddy. Just show them the output.
