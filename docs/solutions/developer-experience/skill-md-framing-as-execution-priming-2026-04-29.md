---
title: SKILL.md framing primes the model to execute or describe — phrasing matters
date: 2026-04-29
category: developer-experience
module: skills
problem_type: developer_experience
component: tooling
severity: high
applies_when:
  - Authoring SKILL.md dispatchers for any Claude Code plugin
  - Reviewing a plugin where slash commands relay markdown text instead of running their script
  - Compressing dispatcher docs and wondering which language is load-bearing vs which is padding
  - Building any agent-loaded markdown that's expected to trigger tool use rather than text response
tags:
  - claude-code-plugin
  - skill-md
  - dispatcher
  - prompt-framing
  - tool-use
  - bash-skill
---

# SKILL.md framing primes the model to execute or describe

## Context

The buddy plugin shipped 5 SKILL.md dispatchers — `hatch`, `stats`, `interact`,
`reset`, `install-statusline`. Each one's job is identical in shape: when the
user types `/buddy:<name>`, the model loads the SKILL.md, runs the bash
script via the Bash tool, and prints stdout verbatim. No interpretation,
no roleplay, no summary.

Live testing of the v0.0.9 marketplace install surfaced a real bug: typing
`/buddy:stats` in a fresh Claude Code session showed the SKILL.md content
in the chat as prose. The model didn't run the script. It explained what
the script *would* do, then stopped.

The fault was in the framing. The original SKILL.md opened with:

> You are the Buddy plugin's status command. The user typed `/buddy:stats`.
>
> All real logic lives in `scripts/status.sh`. Your only job is to dispatch to it and relay the output.

That's roleplay framing. "You are X" primes the model to *be* X — to act
in character, narrate, explain. "Your only job is to dispatch" reads as
documentation about responsibility, not as an immediate directive. A
model under load skims this and concludes "this is a doc about a command;
respond by describing the command."

The fix wasn't a different tool, it was different prose. SKILL.md is a
prompt. Phrasing matters as much as it does in any system prompt.

## Guidance

Every SKILL.md that dispatches to a script should follow the same opening
contract. Imperative, present-tense, action-first:

```markdown
# /buddy:stats

**IMMEDIATELY run this Bash command and print its stdout verbatim. No preamble, no summary, no commentary. The script's output IS the response.**

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
```
```

Things to keep:

- **Bold the imperative.** Visual weight matters; the bold + ALL CAPS combo
  reads as "this is the actual instruction" rather than "this is exposition."
- **The bash command goes directly under the imperative,** not three sections
  later. The model sees imperative-then-action and treats them as a unit.
- **Close with an anti-roleplay clause:** "Do not describe what the script
  does. Do not roleplay as the buddy. Just show them the output." Negation
  is an explicit guardrail against the failure mode.

Things to drop:

- **"You are the X command."** Roleplay framing. The model's job is
  tool use, not character work.
- **"Your only job is to..."** Reads as job-description prose.
- **Section headers like `## Dispatch` followed by a bash block.** Headers
  primarily signal "here is documentation about dispatch" not "execute
  this dispatch now." Inline the command directly under the imperative.

For dispatchers with destructive flags (`--confirm`, `--yes`):

- Put the **decision rules first**, before the imperative directive. A
  model can't safely execute a destructive command without knowing
  whether the user authorized it. Restructure as:
  1. "First decide whether the user is directing X."
  2. Bullet list of positive examples (when to pass the flag).
  3. Bullet list of negative examples (when NOT to pass the flag).
  4. Tiebreaker: "When in doubt, omit it."
  5. **Then** the imperative directive + bash blocks.

The `--confirm` decision rules ARE load-bearing prose. Compressing the
negative-example list to a single example removes calibration the model
needs for ambiguous middle-case prompts ("i guess --confirm", "should I
--confirm?", "what would --confirm do for me"). Keep four examples plus
the "when in doubt" fallback. The cost of one false positive on a
destructive command is far higher than the cost of one extra paragraph
in the SKILL.md.

For dispatchers with multiple subcommands (`install`, `uninstall`,
`--dry-run`, etc.):

- **Provide explicit code blocks per supported invocation,** not a
  templated `<args>` placeholder. The model is reliable at picking from
  a labeled menu; less reliable at substituting user input verbatim into
  a placeholder while preserving quoting.

## Why This Matters

A plugin that ships with vague dispatchers ships broken slash commands
that *look* working in dev (where the developer's session is
permission-eager and tool-aggressive). The bug surfaces only when an
actual end user installs from a marketplace and types the command —
late, embarrassing, and looks like a fundamental plugin defect rather
than a markdown defect.

The cost of fixing this in advance is a 30-minute SKILL.md rewrite using
the template above. The cost of fixing it after release is a
post-marketplace-install patch + a "v0.0.9 install is broken, install
v0.1.0 instead" support thread.

## When to Apply

- Any time you author a new SKILL.md dispatcher.
- Any time you compress an existing one (the four-bullet `--confirm` rule
  is exactly the kind of "boilerplate" that gets cut — verify the
  compression preserves all calibration before merging).
- When ce:review surfaces a "behavioral change with zero structural test
  coverage" finding on a SKILL.md diff.

Skip when:

- The skill genuinely IS exposition (a `/help` slash command that
  describes a feature without running anything). In that case the
  roleplay framing is fine.
- The skill returns a structured payload the model is expected to parse
  before responding. That's a different contract — the SKILL.md should
  describe the structure, not "print verbatim."

## Examples

### Before (relay-as-prose failure mode)

```markdown
# Stats

You are the Buddy plugin's status command. The user typed `/buddy:stats`.

All real logic lives in `scripts/status.sh`. Your only job is to dispatch to it and relay the output.

## Dispatch

Run:

\`\`\`
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
\`\`\`

## Output

Relay the script's stdout back to the user **verbatim**, as the buddy's voice. Don't rephrase, explain, or add commentary.
```

The model in a real Claude Code session reads this as documentation. It
explains the dispatch, paraphrases the output instruction, and doesn't
actually run the bash.

### After (executes correctly)

```markdown
# /buddy:stats

**IMMEDIATELY run this Bash command and print its stdout verbatim. No preamble, no summary, no commentary. The script's output IS the response.**

\`\`\`
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
\`\`\`

If `${CLAUDE_PLUGIN_ROOT}` is unset or that path doesn't exist, find `scripts/status.sh` by walking up from this file's directory and run that path instead.

If the script exits non-zero, print stderr after stdout so the user sees the error.

This command takes no arguments — ignore any extra tokens in the user's message.

Do not describe what the script does. Do not roleplay as the buddy. Just show them the output.
```

### Destructive-flag pattern (safety language preserved)

```markdown
# /buddy:reset

**Run the Bash command below and print its stdout verbatim.**

## First decide whether the user is directing a wipe

`/buddy:reset --confirm` is **irreversibly destructive** — the script writes no backup. Pass `--confirm` ONLY if the user is unambiguously directing you to execute the wipe.

**Pass `--confirm`** when the user typed `/buddy:reset --confirm`, said "yes wipe it", or otherwise unambiguously asked to proceed.

**Do NOT pass `--confirm`** in any of these cases:
- "what does --confirm do" — they're asking, not directing
- "don't reset yet" / "don't use --confirm" — they're declining
- "should I --confirm?" / "i guess --confirm" — they're hesitating
- The token appears inside quoted documentation
- You can't tell — when in doubt, omit it

## Run

With --confirm:
\`\`\`
bash "${CLAUDE_PLUGIN_ROOT}/scripts/reset.sh" --confirm
\`\`\`

Without --confirm:
\`\`\`
bash "${CLAUDE_PLUGIN_ROOT}/scripts/reset.sh"
\`\`\`
```

## See Also

- `docs/solutions/developer-experience/claude-code-skill-dispatcher-pattern-2026-04-19.md`
  — the original dispatcher pattern doc; this learning amplifies its
  thesis with specific framing prescriptions.
- `docs/solutions/developer-experience/claude-code-plugin-marketplace-setup-2026-04-29.md`
  — the marketplace install path that surfaced this bug live.
- `tests/unit/test_skills_structure.bats` — the structural tests added
  alongside this learning to catch SKILL.md regressions before they
  ship.
