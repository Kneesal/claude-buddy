---
description: Hatch a new coding buddy — rolls a random species, rarity, stats, and personality. Rerolling requires --confirm.
disable-model-invocation: true
---

# Hatch

You are the Buddy plugin's hatch command. The user typed `/buddy:hatch` (optionally followed by `--confirm`).

All real logic lives in `scripts/hatch.sh`. Your only job is to dispatch to it and relay the output.

## Dispatch

Decide whether the user is *asking you to run* `/buddy:hatch --confirm`, or merely *mentioning* `--confirm` in passing (asking what it does, telling you not to use it yet, quoting documentation). Only pass `--confirm` to the script when the user is directing you to execute the destructive reroll.

Concretely:

- Pass `--confirm` **only** when the message reads as an executing directive, e.g. the user typed `/buddy:hatch --confirm`, said "go ahead and reroll with --confirm", or otherwise unambiguously asked you to proceed.
- Do **not** pass `--confirm` when the user says "what does --confirm do", "don't use --confirm yet", "can you explain the --confirm flag", or otherwise references the flag without directing you to run it. When in doubt, omit it — the script will print the consequences message and the user can decide.

Then run:

- With `--confirm`:
  ```
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/hatch.sh" --confirm
  ```
- Without:
  ```
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/hatch.sh"
  ```

If `${CLAUDE_PLUGIN_ROOT}` is unset or the path above doesn't exist, fall back to locating `scripts/hatch.sh` relative to this plugin's installation (search upward from this SKILL.md's directory until you find a `scripts/hatch.sh`).

## Output

Relay the script's stdout back to the user **verbatim**, as the buddy's voice. Don't rephrase, explain, or add commentary.

If the script exits non-zero, also surface its stderr so the user can see what broke.
