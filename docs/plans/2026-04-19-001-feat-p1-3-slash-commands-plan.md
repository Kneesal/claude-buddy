---
title: P1-3 — Slash command state machine
type: feat
status: complete
date: 2026-04-19
origin: docs/roadmap/P1-3-slash-commands.md
---

# P1-3 — Slash command state machine

## Overview

Wire the P1-1 state primitives and the P1-2 hatch roller into three user-facing shell scripts that power three slash commands:

- `scripts/hatch.sh` — first hatch (NO_BUDDY) + reroll state machine (ACTIVE with/without enough tokens, `--confirm` gate), writes new buddy.json envelope.
- `scripts/status.sh` — renders a human-readable status report from current state (NO_BUDDY / ACTIVE / CORRUPT / FUTURE_VERSION).
- `scripts/reset.sh` — destructive wipe of buddy.json with `--confirm` gate, using an atomic `.tmp` → `.deleted` → `unlink` dance so an interrupted reset never leaves half-state.

Then expand the three skill `SKILL.md` files so Claude parses free-text args (`hatch`, `reset`, `--confirm`) and dispatches to the right script. Destructive operations (reroll, reset) require an explicit `--confirm` flag because `SKILL.md` cannot reliably do mid-execution interactive prompts.

Ship a `tests/slash.bats` suite covering the four-state matrix, the atomic reset dance, and flock-backed concurrent-hatch safety.

## Problem Frame

P1-1 shipped `buddy_load` / `buddy_save` with sentinels (`NO_BUDDY` / `CORRUPT` / `FUTURE_VERSION`) and flock-protected atomic writes. P1-2 shipped `roll_buddy` / `next_pity_counter` as pure functions that produce the inner `.buddy` object but know nothing about the full envelope (`tokens`, `meta.pityCounter`, `meta.totalHatches`, `hatchedAt`, `lastRerollAt`).

P1-3 is where these two layers meet. It's the first ticket that:
- Composes the full `buddy.json` envelope from a freshly-rolled inner buddy plus persisted/fresh metadata.
- Decides the reroll economics at the I/O boundary (token deduction, pity-counter carry, what to reset, what to preserve).
- Speaks to the user directly through three slash commands, with error messages that tell the user what to do next.

The four-state machine in the origin plan D5 is the contract. Each command's output in each state is specified in the ticket Tasks section. Destructive confirmation is flag-based (per D5) rather than interactive because `SKILL.md` is LLM-interpreted markdown — it can't reliably do mid-session `read` prompts.

## Requirements Trace

- **R1 (hatch, NO_BUDDY)** — `scripts/hatch.sh` on NO_BUDDY rolls a buddy, composes the full envelope with `tokens.balance: 0`, `meta.totalHatches: 1`, `meta.pityCounter` carried from the roll, `hatchedAt` set to now, `lastRerollAt: null`, and persists via `buddy_save`. No `--confirm` required (first hatch can't be destructive).
- **R2 (reroll gate)** — `scripts/hatch.sh` on ACTIVE without `--confirm` prints the reroll-consequences message and exits 0 without mutating state. Message wording matches the ticket: `"Reroll will wipe your Lv.N form. Run /buddy:hatch --confirm to continue."` (Lv.N pulled from current state.)
- **R3 (reroll paid)** — `scripts/hatch.sh` on ACTIVE with `--confirm` and `tokens.balance >= 10`: deducts 10 tokens, rolls a new buddy, resets `level/form/xp/signals`, preserves `tokens.balance - 10`, increments `meta.totalHatches`, updates `lastRerollAt`, persists atomically. Uses P1-2's `roll_buddy` and `next_pity_counter`.
- **R4 (reroll rejected — insufficient tokens)** — `scripts/hatch.sh` on ACTIVE with `tokens.balance < 10` (with or without `--confirm`): prints `"Need N more tokens. Earn 1 per active session-hour."` where N = 10 − balance. Exit 0, no mutation.
- **R5 (status NO_BUDDY)** — `scripts/status.sh` on NO_BUDDY prints `"No buddy yet. Run /buddy:hatch to hatch one."`. Exit 0.
- **R6 (status ACTIVE)** — `scripts/status.sh` on ACTIVE prints a multi-line report: name, species, rarity, form, level, XP progress (`xp / next_level_xp` — use a P1-3-local constant for `next_level_xp` since the XP curve is P4-1; flag this in Notes), 5 stats, token balance. Exit 0.
- **R7 (status CORRUPT)** — `scripts/status.sh` on CORRUPT prints `"Buddy state needs repair. Run /buddy:reset or restore from backup."`. On FUTURE_VERSION, prints the future-version message from state.sh's warning text and suggests updating the plugin. Exit 0.
- **R8 (reset gate)** — `scripts/reset.sh` without `--confirm` prints `"All buddy data will be lost. Run /buddy:reset --confirm to continue."`. Exit 0, no mutation.
- **R9 (reset paid)** — `scripts/reset.sh --confirm` on any state (even CORRUPT) deletes `buddy.json` via atomic rename + unlink:
  1. Acquire flock on `buddy.json.lock` (the persistent sibling from P1-1).
  2. If `buddy.json` exists, `mv -f buddy.json buddy.json.deleted` (atomic on POSIX).
  3. `rm -f buddy.json.deleted`.
  4. Release flock.

  If the process is killed between steps 2 and 3, the next `buddy_load` sees no `buddy.json` → `NO_BUDDY` state, and the orphan `.deleted` file is swept by `state_cleanup_orphans` on next session start (needs a small extension — see Unit 3).
- **R10 (SKILL.md dispatch)** — the three `SKILL.md` files parse the user's free-text message for the keywords `hatch` / `reset` / `--confirm`, invoke the right `scripts/*.sh` with the right args via Claude's Bash tool, and relay stdout back to the user verbatim. No script logic in SKILL.md itself — it's a thin dispatcher.
- **R11 (no hook-contract regression)** — every `scripts/*.sh` sources `scripts/lib/state.sh` and `scripts/lib/rng.sh` following the same discipline as future hooks: no module-level `set -euo pipefail`, explicit per-function error handling, never crash on internal failure. Though these scripts are invoked from SKILL.md (not hooks), keeping the convention consistent means the libraries stay sourcing-safe for P3+ hook authors. See `docs/solutions/best-practices/bash-state-library-patterns-2026-04-18.md`.
- **R12 (tests)** — `tests/slash.bats` covers the four-state matrix (12 cells minus CORRUPT-hatch-reject + CORRUPT-status-message + CORRUPT-reset-confirm + hatch-happy-path-NO_BUDDY + reroll-with-tokens + reroll-no-tokens + reroll-no-confirm + reset-no-confirm + reset-confirm-atomic + concurrent-hatch-flock). Uses `BUDDY_RNG_SEED` for deterministic rolls so assertions can pin species/rarity.

## Scope Boundaries

- **Not** earning tokens — token accrual, daily cap, and milestone bonuses are P5. For P1-3, `tokens.balance` starts at 0 on first hatch and stays 0 unless a test or manual edit injects tokens. This means the paid-reroll path (`R3`) is only fully exercisable with test injection. The ticket Notes section already flags this.
- **Not** XP math — `status.sh` displays `xp` and a placeholder `next_level_xp` constant. The real curve is P4-1. The placeholder is a local `const NEXT_LEVEL_XP_PLACEHOLDER=100` so changing it in P4-1 is a one-line edit.
- **Not** signal accumulation — `signals` is reset on reroll to the zeroed shape that P1-2 already emits. P4-1 owns the signal schema evolution.
- **Not** the evolution ceremony or form transitions — P4-2.
- **Not** the status line — P2. This is plain stdout for a slash command, no ANSI required.
- **Not** commentary or hooks — P3.
- **Not** the `/buddy:interact` skill — it was P0 scaffolding and is not in P1-3 scope. Leave `skills/interact/SKILL.md` untouched.

### Deferred to Separate Tasks

- **Token injection helper for manual testing** — a `scripts/dev/grant-tokens.sh` would help exercise the reroll-paid path pre-P5. Not worth a unit here; if we want to test reroll-paid in `slash.bats`, we inject tokens by direct JSON edit inside the test (see Unit 5).
- **`--verbose` / `--export` flags** — P8 polish.

## Context & Research

### Relevant Code and Patterns

- `scripts/lib/state.sh` — provides `buddy_load` (returns JSON or one of three sentinels, always exit 0), `buddy_save` (reads JSON from stdin, stamps schemaVersion, flock-protected atomic write), `session_load` / `session_save`, `state_cleanup_orphans`. The sentinel-as-output convention is load-bearing: scripts must compare `$state_output` to `"$STATE_NO_BUDDY"` / `"$STATE_CORRUPT"` / `"$STATE_FUTURE_VERSION"` before treating output as JSON.
- `scripts/lib/rng.sh` — provides `roll_buddy <pity_counter>` (produces inner buddy JSON with `id/name/species/rarity/shiny/stats/form/level/xp`, sets `_RNG_ROLL`) and `next_pity_counter <current> <rarity>`. **Critical:** both must be called without command substitution to preserve LCG state under `BUDDY_RNG_SEED` — see `docs/solutions/best-practices/bash-subshell-state-patterns-2026-04-19.md`.
- `tests/test_helper.bash` — setup/teardown already isolates `CLAUDE_PLUGIN_DATA` per test via `BATS_TEST_TMPDIR`, unsets `BUDDY_RNG_SEED` / `BUDDY_SPECIES_DIR`, and sources `state.sh`. Reuse this for `slash.bats`.
- `tests/state.bats` + `tests/rng.bats` — template for bats conventions: `run --separate-stderr` every time, wrap timing-sensitive attacks in `timeout`, use `BUDDY_RNG_SEED` for deterministic assertions.
- `skills/hatch/SKILL.md` + `skills/stats/SKILL.md` — current P0 stub bodies. Pattern: short directive prose that tells Claude what to do in each state, referencing `${CLAUDE_PLUGIN_DATA}/buddy.json` for state inspection. P1-3 rewrites the bodies to instruct Claude to invoke the corresponding `scripts/*.sh` via Bash.

### Institutional Learnings

- `docs/solutions/best-practices/bash-state-library-patterns-2026-04-18.md` — the A/B/C/D/E/F/G pattern list. Items directly relevant to P1-3:
  - **A**: `scripts/*.sh` source `state.sh` and `rng.sh`; they must also avoid module-level `set -euo pipefail` so the sourced libraries stay sourcing-safe. Keep sourcing scripts disciplined per-function.
  - **B**: the reset dance re-uses state.sh's lock file (`buddy.json.lock`) — never delete the lock. Use `mv -f` for atomic rename, not `rm`.
  - **C**: every branch must check for all three sentinels before reading JSON. Missing `FUTURE_VERSION` handling is an easy mistake.
  - **G**: `run --separate-stderr` and `BATS_TEST_TMPDIR` isolation.
- `docs/solutions/best-practices/bash-subshell-state-patterns-2026-04-19.md` — when hatch.sh calls `roll_buddy`, it must use the no-subshell pattern: `roll_buddy "$pity" >/dev/null; local new_inner=$_RNG_ROLL`, not `local new_inner=$(roll_buddy "$pity")`. Without this, `BUDDY_RNG_SEED` tests would see the same roll on every reroll.
- `docs/solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md` — (1) plugin skills are always namespaced as `/<plugin>:<skill>`, so the ticket's `/buddy`, `/buddy hatch`, `/buddy reset` map to `/buddy:stats`, `/buddy:hatch`, `/buddy:reset` respectively (keeping `stats` since that's already the P0 scaffolded skill). (2) new skill dirs created mid-session need a full restart — we'll add `skills/reset/` which triggers this; document in Notes. (3) `disable-model-invocation: true` only blocks auto-invocation, not explicit user invocation — so it stays on all three skills.

### External References

None required. The command shapes and message wording are fully specified by the origin plan D5 and the P1-3 ticket.

## Key Technical Decisions

- **Keep the per-command skill layout from P0, not a single `skills/buddy/`.** The ticket text says "expand skills/buddy/SKILL.md", but P0 deliberately chose per-command skills to avoid `/buddy:buddy`. The P0 gotcha doc records this decision. P1-3 maps the ticket's three commands onto the P0 layout: `/buddy` → `/buddy:stats` (uses existing `skills/stats/`), `/buddy hatch` → `/buddy:hatch` (existing `skills/hatch/`), `/buddy reset` → `/buddy:reset` (new `skills/reset/`). Surfacing this explicitly in Notes + README so future readers aren't confused by the ticket wording.
- **SKILL.md is the dispatcher; scripts do the work.** Each `SKILL.md` body is ≤15 lines of LLM-directive prose that tells Claude exactly which `scripts/*.sh` to run via Bash and how to parse the user's free-text args for `--confirm`. No business logic lives in SKILL.md. This keeps the LLM interpretation surface small and predictable.
- **Script exit-code convention: exit 0 on user-visible states (even rejections); exit non-zero only on internal errors.** Insufficient tokens, missing `--confirm`, NO_BUDDY-on-reset — all exit 0 with a stdout message. flock timeout, disk full, invalid JSON in state — exit non-zero with stderr message. Rationale: SKILL.md's dispatch just relays stdout; exit 0 means "we handled this cleanly, show the user the message". This mirrors the CLAUDE.md hook contract (hooks exit 0 on internal failure) even though these aren't hooks — it keeps the convention uniform.
- **Scripts source `state.sh` and `rng.sh` directly, not via a wrapper.** Hooks (P3+) will source them the same way. One less abstraction, one more occurrence pattern for the bash-4.1+ guard / no-`set -e` discipline.
- **`${CLAUDE_PLUGIN_ROOT}` for script discovery, falling back to SKILL.md location.** Claude Code exposes `${CLAUDE_PLUGIN_ROOT}` to plugin-invoked commands (per plugin docs). SKILL.md instructs Claude to run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/hatch.sh"` etc. **Open question, see below** — if this env var isn't exposed to LLM-invoked Bash tool calls in practice, we fall back to having SKILL.md instruct Claude to locate the scripts relative to the plugin manifest (or use a relative path from the default working directory).
- **Reset dance: `mv` to `.deleted`, then `rm`, under flock.** Atomicity is from `mv`; the `.deleted` intermediate exists only to make crash-recovery cheap. If the process dies after `mv` but before `rm`, the next `buddy_load` sees no `buddy.json` (NO_BUDDY — correct), and `state_cleanup_orphans` sweeps the `.deleted` file. **Extension to state.sh:** `state_cleanup_orphans` currently sweeps `.tmp.*` and `session-*.json`; we add a `buddy.json.deleted` sweep (unconditional — if it exists at session start, it's leftover from a crashed reset). Small, documented change.
- **Envelope composition lives in `scripts/hatch.sh`, not in `rng.sh`.** P1-2 deliberately kept `roll_buddy` scoped to the inner `.buddy` object. hatch.sh composes `{schemaVersion, hatchedAt, lastRerollAt, buddy: $inner, tokens: {...}, meta: {...}}` via jq, which keeps the envelope schema in one place and makes future schema migrations auditable.
- **Reroll envelope math (what's preserved vs reset) is in one jq filter in hatch.sh.** Preserved: `tokens.balance - rerollCost`, `tokens.earnedToday`, `tokens.windowStartedAt`, `meta.totalHatches + 1`, `meta.pityCounter` (carried into `roll_buddy` then updated). Reset: everything else (new inner buddy, `hatchedAt` → now, `lastRerollAt` → now). Single jq filter is easier to audit than multiple mutations.
- **`REROLL_COST=10` is a `readonly` constant in hatch.sh, not an env knob.** P5 will expose it via `userConfig.rerollCost`. For P1-3 we don't need the knob yet.

## Open Questions

### Resolved During Planning

- **Skill layout**: keep P0's per-command layout (`skills/hatch/`, `skills/stats/`, new `skills/reset/`). Ticket wording that says "expand skills/buddy/SKILL.md" is resolved to mean "expand the three per-command skills in aggregate"; documented in Notes.
- **`stats` vs `status` naming**: keep P0's `skills/stats/` — don't rename. The ticket's `/buddy` status command is served by `/buddy:stats`. Rationale: rename would require updating P0 docs, README, and the P1-2 tests that reference `/buddy:hatch`. Keeping `stats` is lower-churn; the word "stats" still accurately describes the command since the output includes stats.
- **Script exit codes**: exit 0 on rejections (gentle user-visible outcomes); non-zero only on internal errors. See Key Technical Decisions.
- **Reroll cost source**: `readonly REROLL_COST=10` in hatch.sh; move to `userConfig` in P5.
- **Placeholder XP curve**: `readonly NEXT_LEVEL_XP_PLACEHOLDER=100` in status.sh; replaced by P4-1's real curve.

### Deferred to Implementation

- **`${CLAUDE_PLUGIN_ROOT}` env var availability in LLM-invoked Bash calls.** The plugin docs reference this variable. Verify empirically by having the expanded `SKILL.md` instruct Claude to `echo "${CLAUDE_PLUGIN_ROOT}"` first, and confirming the expected path resolves. If it doesn't: the fallback is to have `SKILL.md` tell Claude to use the path from `${CLAUDE_PLUGIN_DATA}` (plugin data dir is predictable) or to have Claude `cd` to a known-relative location before invoking the script. Document the final approach in `docs/solutions/` regardless.
- **Exact stdout wording for ACTIVE status**: the ticket says "name, species, rarity, form, level, XP progress, stats, token balance". The per-line layout (multi-line block vs single-line summary) is a phrasing decision best made while writing the script — pick what reads cleanly in a terminal.
- **CORRUPT reset path subtlety**: `buddy_load` returns the CORRUPT sentinel, but `buddy.json` still exists on disk. `reset.sh --confirm` must not read or parse the file before deleting — it just acquires flock and renames. Make sure the implementation doesn't accidentally call `buddy_load` first.

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

### Command → state → action matrix

| Command invocation | NO_BUDDY | ACTIVE (tokens ≥ cost) | ACTIVE (tokens < cost) | CORRUPT | FUTURE_VERSION |
|---|---|---|---|---|---|
| `hatch.sh` | roll + persist envelope; exit 0 | print reroll-consequences msg; exit 0 | print "need N more tokens"; exit 0 | print CORRUPT msg (pointer to reset); exit 0 | print FUTURE_VERSION msg (suggest update); exit 0 |
| `hatch.sh --confirm` | same as above (first hatch ignores flag) | deduct, roll, write reroll envelope; exit 0 | print "need N more tokens"; exit 0 | print CORRUPT msg; exit 0 | print FUTURE_VERSION msg; exit 0 |
| `status.sh` | "No buddy yet…" | full status block | full status block (token balance shows 0) | "Buddy state needs repair…" | future-version msg | 
| `reset.sh` | print reset-consequences msg; exit 0 | print reset-consequences msg | print reset-consequences msg | print reset-consequences msg | print reset-consequences msg |
| `reset.sh --confirm` | no-op (nothing to delete); exit 0 | atomic wipe; exit 0 | atomic wipe | atomic wipe (skips buddy_load) | atomic wipe |

### Reset dance (sequence)

```
reset.sh --confirm
  │
  ├── open flock on $DATA/buddy.json.lock (existing lock from state.sh)
  │
  ├── if $DATA/buddy.json exists:
  │     mv -f $DATA/buddy.json $DATA/buddy.json.deleted   ← atomic rename
  │     rm -f $DATA/buddy.json.deleted
  │     (crash between mv and rm: next load = NO_BUDDY,
  │      orphan sweep removes .deleted on next session start)
  │
  ├── close flock
  │
  └── print "Buddy reset. Run /buddy:hatch to start over." ; exit 0
```

### SKILL.md dispatch shape

```
SKILL.md (for each of hatch / stats / reset):
  ├── frontmatter: description, disable-model-invocation: true (from P0)
  ├── directive:
  │     "The user typed /buddy:<cmd>. If their message contains '--confirm',
  │      run: bash \"${CLAUDE_PLUGIN_ROOT}/scripts/<cmd>.sh\" --confirm
  │      Otherwise: bash \"${CLAUDE_PLUGIN_ROOT}/scripts/<cmd>.sh\"
  │      Relay the stdout back to the user verbatim."
  └── (no business logic here)
```

## Implementation Units

- [x] **Unit 1: `scripts/hatch.sh` — hatch state machine + envelope composition**

**Goal:** Produce a shell script that handles first-hatch, reroll-gate, reroll-paid, reroll-insufficient-tokens, CORRUPT, and FUTURE_VERSION cases per R1–R4.

**Requirements:** R1, R2, R3, R4, R11

**Dependencies:** P1-1 (`scripts/lib/state.sh`), P1-2 (`scripts/lib/rng.sh`)

**Files:**
- Create: `scripts/hatch.sh`
- Test: `tests/slash.bats` (Unit 5)

**Approach:**
- `#!/usr/bin/env bash`, no `set -euo pipefail` at script top (keep sourcing-safe for future hook-shared libraries). Script-level errexit is fine inside a subshell-guarded main; easiest is to keep explicit `|| return 1` style like the libraries.
- Source `scripts/lib/state.sh` and `scripts/lib/rng.sh` using `${BASH_SOURCE[0]}`-relative resolution so the script works from any CWD.
- Parse args: single optional flag `--confirm`. Any other arg → exit 0 with usage message.
- Call `buddy_load`; branch on output:
  - `$STATE_NO_BUDDY` → roll a fresh buddy and persist (`_hatch_first`).
  - `$STATE_CORRUPT` → print CORRUPT pointer message, exit 0.
  - `$STATE_FUTURE_VERSION` → print FUTURE_VERSION message, exit 0.
  - valid JSON → reroll path:
    - if no `--confirm`: print reroll-consequences message (include current Lv and form), exit 0.
    - if `--confirm`:
      - read `tokens.balance` and `meta.pityCounter` via jq.
      - if balance < `REROLL_COST`: print "Need N more tokens…", exit 0.
      - otherwise: call `roll_buddy "$pityCounter"` using the no-subshell pattern (`roll_buddy "$p" >/dev/null; local inner=$_RNG_ROLL`), then `next_pity_counter "$pityCounter" "<rolled_rarity>"` → new pity; compose reroll envelope via a single jq filter; pipe to `buddy_save`.
- Compose first-hatch envelope with `hatchedAt = $(date -u +%FT%TZ)`, `lastRerollAt = null`, `tokens = {balance: 0, earnedToday: 0, windowStartedAt: now}`, `meta = {totalHatches: 1, pityCounter: <next from roll>}`.
- Compose reroll envelope preserving `tokens.earnedToday`, `tokens.windowStartedAt`, incrementing `meta.totalHatches`, updating `lastRerollAt: now`, overwriting `.buddy`.
- Print a terse confirmation on success: `"Hatched a $rarity $species named $name! Run /buddy:stats to see more."` on first hatch; `"Rerolled into a $rarity $species named $name. $balance tokens remaining."` on reroll.
- `NEXT_LEVEL_XP_PLACEHOLDER` lives here too as a comment-only forward-reference — not used in hatch.sh.

**Patterns to follow:**
- `scripts/lib/state.sh` header discipline (no module-level `set -e`, bash 4.1+ check not needed in the caller but keeping the convention).
- `scripts/lib/rng.sh` no-subshell pattern when chaining `roll_*` calls.
- jq pipelines for envelope composition (mirrors how `buddy_save` stamps `schemaVersion`).

**Test scenarios:**
- Happy path — NO_BUDDY + no args → `buddy.json` exists after run with `.schemaVersion == 1`, `.buddy.level == 1`, `.tokens.balance == 0`, `.meta.totalHatches == 1`.
- Happy path — NO_BUDDY + `--confirm` → same outcome as no args (flag ignored on first hatch).
- Edge — ACTIVE with 0 tokens + no `--confirm` → prints reroll-consequences message, `buddy.json` unchanged.
- Edge — ACTIVE with 0 tokens + `--confirm` → prints "Need 10 more tokens…", `buddy.json` unchanged.
- Happy path — ACTIVE with 15 tokens injected + `--confirm` → new `.buddy.id`, `.tokens.balance == 5`, `.meta.totalHatches == 2`, `lastRerollAt` set.
- Error path — CORRUPT state → prints CORRUPT pointer message, `buddy.json` unchanged.
- Error path — FUTURE_VERSION state → prints update-plugin message, `buddy.json` unchanged.
- Integration — `BUDDY_RNG_SEED=42` → first hatch produces a pinned species/rarity (assertable).
- Integration — two first-hatch attempts racing (background + foreground) under flock → exactly one succeeds with matching state, no partial write. (Uses `state.sh` flock, not extra logic here.)

**Verification:**
- `bats tests/slash.bats` passes all hatch-related scenarios.
- Running `bash scripts/hatch.sh` manually against a fresh `CLAUDE_PLUGIN_DATA` persists a valid `buddy.json`.

---

- [x] **Unit 2: `scripts/status.sh` — state renderer**

**Goal:** Print a clear human-readable status report for each of NO_BUDDY / ACTIVE / CORRUPT / FUTURE_VERSION per R5–R7.

**Requirements:** R5, R6, R7, R11

**Dependencies:** P1-1. Does not need rng.sh.

**Files:**
- Create: `scripts/status.sh`
- Test: `tests/slash.bats` (Unit 5)

**Approach:**
- Source `scripts/lib/state.sh`.
- Call `buddy_load`; branch on the three sentinels and the JSON-valid case.
- For ACTIVE, use jq to extract name / species / rarity / form / level / xp / stats / tokens.balance, then format a multi-line block. Shape (indicative):
  ```
  Pip — Rare Axolotl (Lv.1 base form)
    XP: 0 / 100
    Stats: debugging 31, patience 88, chaos 14, wisdom 52, snark 44
    Tokens: 0 🪙
  ```
- For NO_BUDDY: `"No buddy yet. Run /buddy:hatch to hatch one."`.
- For CORRUPT: `"Buddy state needs repair. Run /buddy:reset or restore from backup."`.
- For FUTURE_VERSION: `"Your buddy.json was written by a newer plugin version. Update the plugin to read it."`.
- `readonly NEXT_LEVEL_XP_PLACEHOLDER=100` used in the XP line; add a one-line comment pointing to P4-1.

**Patterns to follow:**
- Sentinel-switch pattern from `tests/state.bats` assertions.
- No-`set -e` discipline matching libraries.

**Test scenarios:**
- Happy path — NO_BUDDY → stdout matches expected no-buddy message.
- Happy path — ACTIVE (after hatch.sh produced a seeded buddy) → stdout contains the buddy name, species, rarity, level `Lv.1`, and `Tokens: 0`.
- Edge — ACTIVE with manually-injected `tokens.balance = 7` → stdout shows `Tokens: 7`.
- Error path — CORRUPT (seed buddy.json with `"schemaVersion": 1, "buddy": "}`) → stdout matches CORRUPT message, exit 0.
- Error path — FUTURE_VERSION (seed `{"schemaVersion": 999}`) → stdout matches future-version message, exit 0.

**Verification:**
- All five scenarios pass in `tests/slash.bats`.
- Manual `bash scripts/status.sh` post-hatch renders readable output in a 80-column terminal.

---

- [x] **Unit 3: `scripts/reset.sh` + `state_cleanup_orphans` `.deleted` sweep**

**Goal:** Destructive wipe with `--confirm` gate and atomic `.tmp` → `.deleted` → unlink dance. Extend `state_cleanup_orphans` to sweep orphaned `buddy.json.deleted` files.

**Requirements:** R8, R9, R11

**Dependencies:** P1-1.

**Files:**
- Create: `scripts/reset.sh`
- Modify: `scripts/lib/state.sh` (add `.deleted` sweep to `state_cleanup_orphans`)
- Test: `tests/slash.bats` (Unit 5), extend `tests/state.bats` with a sweep test (small addition, not a new file)

**Approach:**
- `reset.sh` parses optional `--confirm`.
- Without `--confirm`: print `"All buddy data will be lost. Run /buddy:reset --confirm to continue."`, exit 0.
- With `--confirm`:
  - Acquire flock on `$CLAUDE_PLUGIN_DATA/buddy.json.lock` using the same `exec {fd}>$lock` + `flock -x -w $FLOCK_TIMEOUT` pattern from `buddy_save`. Reject symlinked lock file (same guard as `buddy_save`).
  - If `buddy.json` exists: `mv -f buddy.json buddy.json.deleted`, then `rm -f buddy.json.deleted`. If the file doesn't exist (NO_BUDDY state), silently succeed.
  - Release flock. Print `"Buddy reset. Run /buddy:hatch to start over."` and exit 0.
  - On flock timeout or any internal failure: print stderr message, exit 1.
- **Do not call `buddy_load` first.** The file may be CORRUPT — we still want to wipe it. Parsing before deleting is unnecessary and error-prone.
- **state.sh change:** in `state_cleanup_orphans`, after the `.tmp.*` sweep, unconditionally `rm -f "$data_dir/buddy.json.deleted"`. Document that `.deleted` can only be an orphan from a crashed reset; never a live file.

**Patterns to follow:**
- `buddy_save` locking/error-cleanup sequence (open fd, flock, on failure close fd + error).
- Symlink rejection from `buddy_save`.

**Test scenarios:**
- Happy path — NO_BUDDY + `--confirm` → no-op, exit 0, no file created.
- Happy path — ACTIVE + `--confirm` → `buddy.json` is gone, no `.deleted` left, exit 0.
- Edge — missing `--confirm` → prints consequences message, `buddy.json` intact, exit 0.
- Edge — CORRUPT + `--confirm` → `buddy.json` is gone (no parse attempted), exit 0.
- Integration — simulate crash mid-reset by placing a `buddy.json.deleted` file, then call `state_cleanup_orphans` → `.deleted` file is removed.
- Integration — concurrent `reset.sh --confirm` + `hatch.sh` (one writes, the other deletes; under flock only one wins, and the final on-disk state is either a valid `buddy.json` or NO_BUDDY, never a partial file).
- Error — symlinked lock file → exit 1, no mutation. Wrap in `timeout 3`.

**Verification:**
- All scenarios pass in `tests/slash.bats` + `tests/state.bats`.
- Manual: hatch, reset `--confirm`, hatch again → second hatch succeeds cleanly.

---

- [x] **Unit 4: Expand `SKILL.md` dispatch for hatch / stats / reset**

**Goal:** Replace the three P0 stub `SKILL.md` bodies with thin dispatcher prose that invokes the right script with the right args, and add a new `skills/reset/SKILL.md`.

**Requirements:** R10, R12 (to the extent tests exercise the dispatch path)

**Dependencies:** Units 1, 2, 3.

**Files:**
- Modify: `skills/hatch/SKILL.md`
- Modify: `skills/stats/SKILL.md`
- Create: `skills/reset/SKILL.md`
- Modify: `README.md` (add slash-command reference section — the three commands, the `--confirm` convention, the namespacing note)

**Approach:**
- Each SKILL.md keeps its P0 frontmatter (`description`, `disable-model-invocation: true`).
- Body (indicative for hatch; stats and reset mirror the shape):
  ```
  # Hatch

  You are the Buddy plugin's hatch command. The user typed /buddy:hatch.

  - If the user's message (the current turn's prompt) contains `--confirm`, run:
      bash "${CLAUDE_PLUGIN_ROOT}/scripts/hatch.sh" --confirm
  - Otherwise, run:
      bash "${CLAUDE_PLUGIN_ROOT}/scripts/hatch.sh"

  Relay the script's stdout back to the user verbatim. If the script exited non-zero,
  also surface its stderr so the user knows what went wrong.
  ```
- `stats`: never takes `--confirm`, always runs `bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"`.
- `reset`: same `--confirm` detection as hatch, invokes `reset.sh`.
- README gets a short "Commands" section listing the three namespaced commands, the `--confirm` requirement for destructive ops, and a note that bare `/buddy` is reserved for Anthropic's built-in (see P0 gotcha doc).
- Verify `${CLAUDE_PLUGIN_ROOT}` is actually available to LLM-invoked Bash calls during implementation; if not, document and switch to the fallback approach (see Deferred open question). Whatever the answer, write it up in `docs/solutions/developer-experience/` via `/ce:compound`.

**Patterns to follow:**
- Existing P0 SKILL.md frontmatter (carry verbatim).

**Test scenarios:**
- `Test expectation: none — SKILL.md is LLM-interpreted prose, not shell. Dispatch-level correctness is verified manually via plugin restart + /buddy:hatch in a live session. The scripts themselves are covered by Unit 5.`

**Verification:**
- After full plugin restart (`claude --plugin-dir .`), all three commands dispatch correctly:
  - `/buddy:hatch` on fresh state → hatches.
  - `/buddy:hatch` on existing state → prints reroll-consequences.
  - `/buddy:hatch --confirm` on existing state with 0 tokens → prints "Need 10 more…".
  - `/buddy:stats` on fresh state → "No buddy yet…".
  - `/buddy:reset --confirm` on existing state → wipes.
- README renders readable; the namespacing and `--confirm` conventions are documented.

---

- [x] **Unit 5: `tests/slash.bats` — four-state matrix + concurrency**

**Goal:** Automated coverage of the state machine, reset atomicity, and concurrent-hatch safety.

**Requirements:** R12

**Dependencies:** Units 1, 2, 3.

**Files:**
- Create: `tests/slash.bats`

**Approach:**
- Reuse `tests/test_helper.bash` setup/teardown for per-test `CLAUDE_PLUGIN_DATA` isolation.
- Helper function in the bats file: `_inject_tokens <n>` — edits the current `buddy.json` via jq to set `tokens.balance = $n` (for reroll-paid tests, since P5 isn't built yet).
- Helper: `_corrupt_state` — writes a deliberately broken JSON string to `buddy.json`.
- Helper: `_future_version_state` — writes `{"schemaVersion": 999}`.
- Use `BUDDY_RNG_SEED=42` for tests that assert on specific rolled species/rarity. Unseeded for flock-race and general state-machine tests.
- `run --separate-stderr` for every `run` per `bash-state-library-patterns` G.
- Wrap the symlink/lock-file attack tests in `timeout 3`.

**Patterns to follow:**
- `tests/state.bats` → flock race and orphan-sweep test patterns.
- `tests/rng.bats` → `BUDDY_RNG_SEED` usage.

**Test scenarios** (the full slash-command matrix):

Hatch:
- Happy path — `hatch.sh` on fresh state creates valid `buddy.json` with expected envelope fields.
- Happy path — `hatch.sh --confirm` on fresh state behaves identically (flag ignored).
- Edge — `hatch.sh` on ACTIVE (after a prior hatch) prints reroll-consequences, state unchanged.
- Edge — `hatch.sh --confirm` on ACTIVE with 0 tokens prints "Need 10 more tokens…", state unchanged.
- Happy path — `hatch.sh --confirm` on ACTIVE with 15 tokens injected rerolls: `buddy.id` changes, `tokens.balance == 5`, `meta.totalHatches == 2`, `lastRerollAt` set.
- Error path — `hatch.sh` on CORRUPT prints pointer-to-reset message.
- Error path — `hatch.sh` on FUTURE_VERSION prints update message.
- Integration — `BUDDY_RNG_SEED=42` pins the rolled species/rarity across a first hatch.

Status:
- Happy path — `status.sh` on fresh state prints "No buddy yet…".
- Happy path — `status.sh` after hatch prints name, species, rarity, level, stats line, `Tokens: 0`.
- Edge — `status.sh` with injected `tokens.balance=7` shows `Tokens: 7`.
- Error path — `status.sh` on CORRUPT prints repair-pointer.
- Error path — `status.sh` on FUTURE_VERSION prints update-pointer.

Reset:
- Happy path — `reset.sh --confirm` on NO_BUDDY is a no-op success.
- Happy path — `reset.sh --confirm` on ACTIVE removes `buddy.json` and leaves no `.deleted` behind.
- Edge — `reset.sh` without `--confirm` prints consequences, state unchanged.
- Edge — `reset.sh --confirm` on CORRUPT removes the file cleanly (no parse).
- Integration — after leaving a `buddy.json.deleted` orphan, `state_cleanup_orphans` (from session-start) removes it.
- Error path — symlinked lock file → `reset.sh --confirm` exits 1 without hanging. Wrap in `timeout 3`.

Concurrency:
- Integration — two rapid `hatch.sh` invocations (one in background, one in foreground) under a shared `CLAUDE_PLUGIN_DATA` end with exactly one valid `buddy.json`. flock correctness.

**Verification:**
- `bats tests/slash.bats` green on 20+ scenarios.
- Coverage note in ticket Notes section mentioning any scenarios deferred (e.g., concurrency on macOS system bash — since we enforce bash 4.1+, this is in scope for CI but may be stubbed locally).

## System-Wide Impact

- **Interaction graph:** `SKILL.md` (LLM-interpreted) → Claude's Bash tool → `scripts/*.sh` → `scripts/lib/state.sh` + `scripts/lib/rng.sh` → `${CLAUDE_PLUGIN_DATA}/buddy.json`. No new hooks, no status line yet. Reset adds `buddy.json.deleted` as a transient filename under `$CLAUDE_PLUGIN_DATA`.
- **Error propagation:** scripts exit 0 on user-visible states; non-zero only on internal errors (flock timeout, disk full, etc.). `SKILL.md` relays stdout verbatim; Claude sees the exit code and can mention stderr if it's non-empty.
- **State lifecycle risks:** the reset dance deliberately introduces a `.deleted` intermediate. If a reset crashes between rename and unlink, next session sees NO_BUDDY (correct) and `state_cleanup_orphans` (extended in Unit 3) removes the orphan. This is an explicit risk + mitigation.
- **API surface parity:** three new slash commands (`/buddy:hatch` expanded from stub, `/buddy:stats` expanded from stub, `/buddy:reset` new). README + plugin manifest stay internally consistent. `skills/interact/` is untouched. The new `skills/reset/` directory triggers the P0 gotcha — **a full Claude Code restart is required after merging**; document this in the ticket Notes and commit message.
- **Integration coverage:** flock-backed concurrent hatch is covered by Unit 5. flock-backed reset vs hatch concurrency is covered by Unit 5.
- **Unchanged invariants:** `state.sh`'s public API (sentinels, function signatures) is unchanged except for the internal extension of `state_cleanup_orphans` (one additional sweep, same signature). `rng.sh` is unchanged. The hooks-must-exit-0 contract is not yet in play (no hooks in P1-3) but is preserved for P3+ by keeping the libraries sourcing-safe.

## Risks & Dependencies

| Risk | Mitigation |
|---|---|
| `${CLAUDE_PLUGIN_ROOT}` not available to LLM-invoked Bash calls | Empirical verification in Unit 4; fallback path documented. `/ce:compound` the finding. |
| SKILL.md LLM interpretation occasionally misses `--confirm` in user's message and invokes the wrong branch | Scripts fail safely — if `--confirm` is missed, the gate message is shown and no mutation happens; user simply retries. Not a correctness hole, just a UX retry. |
| Reset dance's `.deleted` intermediate accumulates if a bug prevents `rm -f` | `state_cleanup_orphans` sweep added in Unit 3 removes orphans on next session start. |
| New `skills/reset/` directory requires full Claude Code restart (P0 gotcha) | Documented in Notes + PR description. Contributor-facing only; end users installing from a release won't hit it. |
| Reroll-paid path hard to exercise without token injection | Unit 5 tests inject via jq edit; manual testing can use the same helper or grant-tokens dev script if we build one later. |
| Concurrent hatch via flock on macOS system bash (3.2) fails silently | Out of scope — P1-1 already enforces bash 4.1+; macOS users install via `brew install bash` per the state.sh header message. |

## Documentation / Operational Notes

- README gets a "Commands" section (Unit 4) listing the three commands, `--confirm` convention, namespacing caveat.
- Ticket Notes section gets appended with: (1) per-command skill layout rationale (ticket's "expand skills/buddy/" interpretation), (2) `${CLAUDE_PLUGIN_ROOT}` verification result, (3) any surprises worth a `/ce:compound`.
- Candidate `/ce:compound` targets: the slash-command dispatch pattern (`SKILL.md` as thin dispatcher → script), the reset atomic-rename dance, and the `${CLAUDE_PLUGIN_ROOT}` resolution outcome. Promote only the ones that are genuinely non-obvious and would save future authors time.

## Sources & References

- **Origin ticket:** [docs/roadmap/P1-3-slash-commands.md](../roadmap/P1-3-slash-commands.md)
- **Umbrella plan:** [docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md](./2026-04-16-001-feat-claude-buddy-plugin-plan.md) (D5 state machine, D7 atomic writes, D8 pity)
- **Brainstorm:** [docs/brainstorms/2026-04-16-claude-buddy-plugin-requirements.md](../brainstorms/2026-04-16-claude-buddy-plugin-requirements.md) (R8 reroll semantics, R9 slash commands)
- **State primitives:** [scripts/lib/state.sh](../../scripts/lib/state.sh), [docs/plans/2026-04-16-003-feat-p1-1-state-primitives-plan.md](./2026-04-16-003-feat-p1-1-state-primitives-plan.md)
- **Hatch roller:** [scripts/lib/rng.sh](../../scripts/lib/rng.sh), [docs/plans/2026-04-18-001-feat-p1-2-hatch-roller-plan.md](./2026-04-18-001-feat-p1-2-hatch-roller-plan.md)
- **Bash state library patterns:** [docs/solutions/best-practices/bash-state-library-patterns-2026-04-18.md](../solutions/best-practices/bash-state-library-patterns-2026-04-18.md)
- **Bash subshell state patterns:** [docs/solutions/best-practices/bash-subshell-state-patterns-2026-04-19.md](../solutions/best-practices/bash-subshell-state-patterns-2026-04-19.md)
- **Plugin scaffolding gotchas:** [docs/solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md](../solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md)
