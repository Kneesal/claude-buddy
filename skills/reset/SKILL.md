---
description: Wipe your current buddy and all its progress. Requires --confirm.
disable-model-invocation: true
---

# /buddy:reset

> **Fallback path.** The canonical dispatch is the buddy plugin's `UserPromptSubmit` hook (`hooks/user-prompt-submit.sh` → `scripts/dispatch.sh` → `scripts/reset.sh`). The hook applies a strict rule: `--confirm` is forwarded ONLY when the user's prompt is exactly `/buddy:reset --confirm` — extra tokens (e.g. `/buddy:reset what does --confirm do`) drop the flag automatically. If you (the model) are reading this body, the hook didn't fire and you must apply the directive-vs-mention rule below by hand. Reset is irreversibly destructive and writes no backup.

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
