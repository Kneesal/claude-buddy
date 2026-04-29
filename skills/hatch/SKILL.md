---
description: Hatch a new coding buddy — rolls a random species, rarity, stats, and personality. Rerolling requires --confirm.
disable-model-invocation: true
---

# /buddy:hatch

**IMMEDIATELY run the Bash command below and print its stdout verbatim. No preamble, no summary, no commentary. The script's output IS the response.**

## Decide whether to pass `--confirm`

- Pass `--confirm` ONLY if the user explicitly directed execution — typed `/buddy:hatch --confirm`, said "go ahead and reroll with --confirm", or otherwise unambiguously asked you to reroll.
- Otherwise, omit it. The script will print the consequences message and let the user decide.
- Asking "what does --confirm do" is NOT a directive to use it.

## Run

With `--confirm`:
```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/hatch.sh" --confirm
```

Without:
```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/hatch.sh"
```

If `${CLAUDE_PLUGIN_ROOT}` is unset, find `scripts/hatch.sh` by walking up from this file's directory.

If the script exits non-zero, print stderr after stdout so the user sees the error.

Take no other action. Do not describe what the script does. Do not roleplay as the buddy. Just show them the output.
