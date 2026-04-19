---
title: Claude Code SKILL.md as thin dispatcher to bash scripts
date: 2026-04-19
category: developer-experience
module: claude-code-plugin-skills
problem_type: developer_experience
component: tooling
severity: medium
applies_when:
  - Designing slash-command surfaces for a Claude Code plugin
  - Deciding what logic belongs in SKILL.md vs a backing script
  - Adding a destructive slash command that needs a confirmation gate
  - Writing SKILL.md prose that instructs the model to parse free-text user messages for flags
  - Reviewing agent-native parity between slash commands and programmatic invocation
tags:
  - claude-code
  - plugin-skills
  - skill-dispatch
  - slash-commands
  - llm-interpretation
  - confirmation-flags
  - agent-native
  - exit-codes
---

# Claude Code SKILL.md as thin dispatcher to bash scripts

## Context

A Claude Code plugin exposes slash commands as `SKILL.md` files. SKILL.md is LLM-interpreted markdown — the model reads the body as natural-language instructions and acts on them. That makes it tempting to put business logic directly in SKILL.md: "if the user has a buddy, show their stats; if not, suggest hatching." It runs. It looks like code. It is not code.

The problem surfaces on the second command: once two SKILL.md files reach into `${CLAUDE_PLUGIN_DATA}/buddy.json`, branch on state, and emit user-facing text, you have two LLM interpretations of the same contract. They drift. Error-wording diverges. Argument parsing subtly differs. A conditional the model reads correctly on a clean session gets paraphrased on a noisy one. And none of it is unit-testable — you cannot `bats` a SKILL.md.

The resolution is mechanical: treat each `SKILL.md` as a **thin dispatcher** to a backing bash script under `scripts/`. SKILL.md decides which script to run and which flags to pass based on free-text args; the script does all the work. This gives you one canonical implementation per command, a test suite that exercises it, and an agent-native surface that works identically whether invoked through the slash command or through a direct `bash scripts/<cmd>.sh` call.

This doc captures the conventions that hold the pattern together. It complements [`claude-code-plugin-scaffolding-gotchas-2026-04-16.md`](./claude-code-plugin-scaffolding-gotchas-2026-04-16.md), which covers the namespacing constraint (`/<plugin>:<skill>`) that forces the per-command layout this pattern relies on.

## Guidance

### A. One SKILL.md per user-facing command

Plugin skills are namespaced `/<plugin>:<skill-name>` — there is no way to expose a bare `/<plugin>`. The natural consequence: each user-facing verb is its own skill directory.

```text
skills/
  hatch/SKILL.md   -> /buddy:hatch
  stats/SKILL.md   -> /buddy:stats
  reset/SKILL.md   -> /buddy:reset
```

Do not try to cram multiple commands into a single SKILL.md with LLM-based routing on the first word of the user's message. You lose discoverability (no separate `--help` per command), confuse the model's auto-invocation, and merge unrelated error surfaces.

### B. SKILL.md dispatches; the script decides

Each SKILL.md is ~20 lines: frontmatter, one paragraph of context, the dispatch rule, and the output rule. No business logic.

```markdown
---
description: Hatch a new coding buddy. Rerolling requires --confirm.
disable-model-invocation: true
---

# Hatch

The user typed `/buddy:hatch` (optionally with `--confirm`). All logic lives in
`scripts/hatch.sh`. Dispatch to it and relay stdout verbatim.

## Dispatch

[directive-vs-mention rule for --confirm goes here; see Section C]

Then run one of:
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/hatch.sh" --confirm
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/hatch.sh"

## Output

Relay the script's stdout back to the user verbatim, as the buddy's voice.
Don't rephrase, explain, or add commentary. If the script exits non-zero,
also surface its stderr.
```

**Use `${CLAUDE_PLUGIN_ROOT}` for the script path.** This env var is exposed to Bash invocations made inside a plugin context and resolves to the plugin's installation directory. It is the only portable way to locate `scripts/` — relative paths break because the Bash tool's working directory is wherever the user invoked Claude from, not the plugin root.

If `${CLAUDE_PLUGIN_ROOT}` turns out to be unset in a given deployment, add a fallback instruction in the SKILL.md telling the model to search upward from the SKILL.md's directory — but verify empirically before relying on the fallback.

### C. Directive-vs-mention rule for destructive flags

The obvious dispatch rule — "if the user's message contains `--confirm`, pass `--confirm` to the script" — is a landmine. Users can say:

- "what does `--confirm` do?"
- "don't use `--confirm` yet"
- "can you explain `--confirm`?"

All three contain the literal token and will dispatch a destructive operation the user did not intend. The fix is a directive-vs-mention rule in the SKILL.md prose:

```markdown
## Dispatch

Decide whether the user is *asking you to run* `/buddy:hatch --confirm`, or
merely *mentioning* `--confirm` in passing (asking what it does, telling you
not to use it yet, quoting documentation). Only pass `--confirm` to the script
when the user is directing you to execute the destructive reroll.

Concretely:

- Pass `--confirm` **only** when the message reads as an executing directive —
  the user typed `/buddy:hatch --confirm`, said "go ahead and reroll with
  --confirm", or otherwise unambiguously asked you to proceed.
- Do **not** pass `--confirm` when the user says "what does --confirm do",
  "don't use --confirm yet", "can you explain --confirm", or otherwise
  references the flag without directing you to run it. When in doubt, omit
  it — the script will print the consequences message and the user can decide.
```

The negative examples matter. Prose without them gets paraphrased ("inspect the user's message for --confirm") and the landmine comes back.

### D. Script exit-code convention: 0 on every user-visible outcome

Scripts invoked from SKILL.md should exit 0 whenever the outcome is something the user is meant to see — **including gentle rejections**:

- `0` — user-visible outcome handled cleanly:
  - success ("Hatched a Rare Axolotl named Pip!")
  - soft rejection without state mutation ("Need 10 more tokens", "All buddy data will be lost. Run /buddy:reset --confirm.")
  - degraded-state message ("Buddy state needs repair. Run /buddy:reset.")
- `1` (or higher) — **internal error only**: flock timeout, disk full, missing dependency, malformed envelope, or any outcome the user cannot act on directly

Rationale: SKILL.md relays stdout verbatim. If a gentle rejection exits non-zero, the model treats it like a tool failure and may retry, escalate, or add apologetic commentary. Exit 0 means "we handled this cleanly — show the message as-is."

This mirrors the hook-exit-0 discipline documented for Claude Code hooks (hooks must exit 0 on internal failure so a plugin bug never breaks the session). The dispatch scripts aren't hooks, but following the same convention keeps the libraries they source (e.g., state.sh) sourcing-safe for future hook authors — no module-level `set -euo pipefail`.

### E. stdout is for the user; stderr is for diagnostics

Stdout goes into the transcript verbatim via the SKILL.md relay. Stderr is surfaced only on non-zero exit, and only as diagnostic context. This bifurcation means:

- Every user-facing string — success, rejection, degraded-state message — goes to stdout with a helpful next-step pointer
- Diagnostic lines (timeout messages, path failures, jq parse errors) go to stderr so they surface alongside an exit 1 when something genuinely breaks

Keep the user-facing strings actionable. `"could not acquire lock within 0.2s"` is a diagnostic. `"could not acquire lock within 0.2s — another buddy operation may be in flight. Try /buddy:reset --confirm again in a moment."` is what the user should see on exit 1.

### F. Agent-native parity falls out for free

Because the script is the real implementation and SKILL.md is a relay, an agent (or a bats test, or a hook) can invoke the script directly:

```bash
CLAUDE_PLUGIN_DATA=/tmp/test-dir bash scripts/hatch.sh --confirm
```

...and get identical behavior to the slash command path. The `--confirm` flag is a literal argument, not free-text LLM interpretation. The `CLAUDE_PLUGIN_DATA` env var is the only contract the script needs. Tests can isolate via `BATS_TEST_TMPDIR`; hooks (once P3 ships) can invoke the same scripts with the same contract.

This is what makes the pattern agent-native: the slash-command path and the direct-invocation path converge on one entry point. There is no LLM-only logic that an agent can't reach.

### G. What the script can trust about its environment

The script sources shared libraries via `BASH_SOURCE`-relative resolution:

```bash
_HATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_HATCH_DIR/lib/state.sh" || exit 1
source "$_HATCH_DIR/lib/rng.sh" || exit 1
```

Because the script is invoked via `bash scripts/hatch.sh` (not sourced), `BASH_SOURCE[0]` is the script path regardless of the caller's working directory. This works under `${CLAUDE_PLUGIN_ROOT}` dispatch, direct CLI invocation, and bats `run` — all three land at the same directory resolution.

Do not rely on `$PWD` or relative paths in the script. The plugin's working directory at dispatch time is not predictable.

## Why This Matters

LLM-interpreted markdown is the most fragile layer in a plugin. Every rule baked into SKILL.md prose is a rule the model re-derives on every invocation, across model versions, context lengths, and user framings. The more logic you push into SKILL.md, the more ways it silently drifts.

Keeping SKILL.md to dispatch + relay turns the drift surface into a single decision: "is the user directing me to run `--confirm` or not?" That one decision is testable through prompt review and tightenable through negative examples. Everything else — state branching, envelope composition, error handling, exit codes — lives in bash where it has a test suite.

The payoff compounds as the plugin grows. Each new command is a fresh `skills/<cmd>/SKILL.md` plus `scripts/<cmd>.sh`, with the conventions already named:

- Dispatch directive-vs-mention for any flag
- Relay stdout verbatim, stderr on non-zero
- Exit 0 on every user-visible outcome, non-zero for internal errors
- Source shared libs via `BASH_SOURCE`-relative resolution
- Test via bats with `BATS_TEST_TMPDIR` isolation

An author adding `/buddy:feed` or `/buddy:evolve` later follows the template without re-deriving these decisions.

## When to Apply

- Designing any new slash command in a Claude Code plugin
- Adding a confirmation gate to a destructive command (the `--confirm` directive-vs-mention rule is the load-bearing piece)
- Deciding whether to embed logic in SKILL.md or extract to a script — **default to extraction** once the command has more than one state branch or any I/O
- Reviewing agent-native parity: if the slash-command path relies on LLM interpretation the direct-invocation path cannot reproduce, the logic is in the wrong place

## Examples

### Unsafe SKILL.md prose (landmine)

```markdown
## Dispatch

Inspect the user's message for the literal token --confirm.

- If present, run: bash "${CLAUDE_PLUGIN_ROOT}/scripts/reset.sh" --confirm
- Otherwise, run: bash "${CLAUDE_PLUGIN_ROOT}/scripts/reset.sh"
```

User: "what does --confirm do?" → model dispatches with `--confirm` → destructive wipe.

### Safe SKILL.md prose

```markdown
## Dispatch

Decide whether the user is *asking you to run* `/buddy:reset --confirm`, or
merely *mentioning* `--confirm` in passing. Only pass `--confirm` when the
user is directing you to execute the destructive wipe.

Pass `--confirm` only when the message reads as an executing directive —
the user typed `/buddy:reset --confirm`, said "yes, wipe it with --confirm",
or otherwise unambiguously asked you to proceed.

Do not pass `--confirm` when the user says "what does --confirm do",
"don't reset yet", or otherwise references the flag without directing you
to run it. When in doubt, omit it — the script prints the consequences
message and the user can decide.
```

User: "what does --confirm do?" → model omits the flag → script prints the consequences message → user gets the explanation without losing their buddy.

### Script contract a SKILL.md can rely on

```bash
# Exit 0 on user-visible outcomes, including gentle rejections.
if (( balance < REROLL_COST )); then
  printf 'Need %d more tokens. Earn 1 per active session-hour.\n' \
    "$(( REROLL_COST - balance ))"
  return 0                           # user-visible rejection: exit 0
fi

# Non-zero only on internal errors the user cannot act on directly.
if ! flock -x -w "$FLOCK_TIMEOUT" "$lock_fd"; then
  echo "buddy-reset: could not acquire lock within ${FLOCK_TIMEOUT}s — another buddy operation may be in flight. Try /buddy:reset --confirm again in a moment." >&2
  return 1                           # internal error: exit 1 with actionable stderr
fi
```

### Bats test invoking the script directly (agent-native parity)

```bash
@test "hatch: ACTIVE + no --confirm + 0 tokens prints need-more message" {
  _seed_hatch
  run --separate-stderr bash "$HATCH_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Need 10 more tokens"* ]]
}
```

The bats test invokes `scripts/hatch.sh` the same way SKILL.md does. Both paths converge on one implementation.

## Related

- [`claude-code-plugin-scaffolding-gotchas-2026-04-16.md`](./claude-code-plugin-scaffolding-gotchas-2026-04-16.md) — the namespacing constraint that forces the per-command layout, plus the mid-session skill-directory reload caveat (relevant when adding a new dispatcher — a fresh `skills/<cmd>/` directory needs a full `claude --plugin-dir .` restart before `/<plugin>:<cmd>` resolves).
- [`bash-state-library-patterns-2026-04-18.md`](../best-practices/bash-state-library-patterns-2026-04-18.md) — the atomic-write and flock discipline the dispatch scripts inherit when they source shared state libraries. Notably the no-module-level-`set -e` rule, which is what keeps dispatch scripts (and future hook scripts) sourcing-safe.
- [`bash-subshell-state-patterns-2026-04-19.md`](../best-practices/bash-subshell-state-patterns-2026-04-19.md) — the no-subshell pattern for stateful library calls that dispatch scripts must honor when chaining through `roll_*` functions or similar.
- Reference implementation: `scripts/hatch.sh`, `scripts/status.sh`, `scripts/reset.sh`, `skills/hatch/SKILL.md`, `skills/stats/SKILL.md`, `skills/reset/SKILL.md` (all shipped with P1-3).
- P1-3 plan: [`docs/plans/2026-04-19-001-feat-p1-3-slash-commands-plan.md`](../../plans/2026-04-19-001-feat-p1-3-slash-commands-plan.md) — the full context for this pattern's first use.
- ce:review CR-03 finding — the directive-vs-mention rule came from a code review that flagged "inspect for literal --confirm" as too permissive. The negative examples in Section C are load-bearing.
