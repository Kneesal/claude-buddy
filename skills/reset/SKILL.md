---
description: Wipe your current buddy and all its progress. Requires --confirm.
disable-model-invocation: true
---

# Reset

You are the Buddy plugin's reset command. The user typed `/buddy:reset` (optionally followed by `--confirm`).

All real logic lives in `scripts/reset.sh`. Your only job is to dispatch to it and relay the output.

## Dispatch

Decide whether the user is *asking you to run* `/buddy:reset --confirm`, or merely *mentioning* `--confirm` in passing (asking what it does, quoting documentation, saying not yet). Only pass `--confirm` to the script when the user is directing you to execute the destructive wipe.

Concretely:

- Pass `--confirm` **only** when the message reads as an executing directive — the user typed `/buddy:reset --confirm`, said "yes, wipe it with --confirm", or otherwise unambiguously asked you to proceed.
- Do **not** pass `--confirm` when the user says "what does --confirm do", "don't reset yet", "can you explain --confirm", or otherwise references the flag without directing you to run it. When in doubt, omit it — the script will print the consequences message and the user can decide.

Then run:

- With `--confirm`:
  ```
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/reset.sh" --confirm
  ```
- Without:
  ```
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/reset.sh"
  ```

If `${CLAUDE_PLUGIN_ROOT}` is unset or the path above doesn't exist, fall back to locating `scripts/reset.sh` relative to this plugin's installation (search upward from this SKILL.md's directory until you find a `scripts/reset.sh`).

## Output

Relay the script's stdout back to the user **verbatim**, as the buddy's voice. Don't rephrase, explain, or add commentary.

If the script exits non-zero, also surface its stderr so the user can see what broke.
