---
id: P1-3
title: Slash command state machine
phase: P1
status: done
depends_on: [P1-1, P1-2]
origin_plan: docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md
---

# P1-3 — Slash commands

## Goal

Implement `/buddy`, `/buddy hatch`, `/buddy reset` with the four-state state machine (NO_BUDDY / ACTIVE-enough-tokens / ACTIVE-low-tokens / CORRUPT). Destructive operations require `--confirm` because SKILL.md can't reliably do mid-execution interactive prompts.

## Tasks

- [ ] Expand `skills/buddy/SKILL.md` with instructions covering the full state machine (see Plan D5 for the matrix).
- [ ] `scripts/hatch.sh`:
  - [ ] NO_BUDDY → roll + persist (no confirmation needed, it's a first hatch).
  - [ ] ACTIVE + tokens >= 10 + no `--confirm` → print "Reroll will wipe your Lv.N form. Run `/buddy hatch --confirm` to continue."
  - [ ] ACTIVE + tokens >= 10 + `--confirm` → deduct 10, reset level/form/signals, preserve token balance, roll new species.
  - [ ] ACTIVE + tokens < 10 → reject with "Need N more tokens. Earn 1 per active session-hour."
- [ ] `scripts/status.sh`:
  - [ ] NO_BUDDY → "No buddy yet. Run `/buddy hatch` to hatch one."
  - [ ] ACTIVE → print name, species, rarity, form, level, XP progress, stats, token balance.
  - [ ] CORRUPT → "Buddy state needs repair. Run `/buddy reset` or restore from backup."
- [ ] `scripts/reset.sh`:
  - [ ] no `--confirm` → describe consequences ("All buddy data will be lost. Run `/buddy reset --confirm` to continue.").
  - [ ] `--confirm` → delete `buddy.json` atomically (via `.tmp` rename to a `.deleted` file + unlink, so interrupted resets don't leave half-state).
- [ ] SKILL.md parses args (`hatch`, `reset`, `--confirm`) from the free-text arguments and dispatches to scripts.
- [ ] Tests (manual + scripted):
  - [ ] First hatch flow end-to-end.
  - [ ] Reroll without `--confirm` (bounces with explanation).
  - [ ] Reroll with 0 tokens (bounces with message).
  - [ ] Reset without `--confirm` (bounces).
  - [ ] Two `/buddy hatch` invocations in rapid succession (flock prevents double-write).

## Exit criteria

- All three commands work across all four states.
- Destructive ops (reroll, reset) are impossible to trigger accidentally.
- `/buddy` is useful even pre-hatch (it tells you what to do next).

## Notes

- Token economy (earning, cap) comes in P5; for now, `tokens.balance` is always 0 at hatch, so reroll path is testable only after P5 or via manual token injection for testing.
- SKILL.md is LLM-interpreted; scripts do the real work. Keep SKILL.md short and unambiguous.
- Reroll never resets `tokens.balance` — only level, form, signals, XP. Plan D-series and Acceptance Criteria R8.

### Implementation notes

- **Plan**: [docs/plans/2026-04-19-001-feat-p1-3-slash-commands-plan.md](../plans/2026-04-19-001-feat-p1-3-slash-commands-plan.md).
- **Skill layout.** Ticket text says "expand skills/buddy/SKILL.md" but P0 deliberately chose per-command skills to avoid `/buddy:buddy`. P1-3 maps the ticket's three commands onto the P0 layout: `/buddy` → `/buddy:stats` (existing), `/buddy hatch` → `/buddy:hatch` (existing), `/buddy reset` → `/buddy:reset` (new). Creating `skills/reset/` triggers the P0 gotcha: end users on a fresh install are fine, but contributors mid-session need `claude --plugin-dir .` restart — `/reload-plugins` won't pick up a new skill directory.
- **Script exit convention.** Exit 0 on every user-visible outcome (including gentle rejections: missing `--confirm`, insufficient tokens, CORRUPT, FUTURE_VERSION). Non-zero only on internal errors (flock timeout, disk full, invalid envelope fields, unknown flag). SKILL.md relays stdout verbatim; exit 0 means "we handled it cleanly".
- **Envelope composition lives in `scripts/hatch.sh`.** P1-2's `roll_buddy` stays scoped to the inner `.buddy` object; `_hatch_compose_first_envelope` / `_hatch_compose_reroll_envelope` wrap it into the full envelope. Reroll jq filter is a single expression so the preserve-vs-reset split (preserve tokens.earnedToday / tokens.windowStartedAt, decrement balance, carry hatchedAt, set lastRerollAt, bump totalHatches, update pityCounter, swap .buddy) is auditable in one place.
- **No-subshell pattern held.** `roll_buddy "$pity" >/dev/null; local inner=$_RNG_ROLL` — never `local inner=$(roll_buddy "$pity")`, or `BUDDY_RNG_SEED` tests would get the same roll twice. The deterministic-seed test (`hatch: deterministic seed pins species and rarity`) is what would catch a regression here.
- **Reset atomic dance implemented as planned.** `reset.sh --confirm` flocks `buddy.json.lock`, `mv -f buddy.json → buddy.json.deleted` (atomic rename), then `rm -f` the `.deleted` marker. Crash between rename and unlink leaves NO_BUDDY (correct) plus a `.deleted` orphan; `state_cleanup_orphans` now unconditionally sweeps `buddy.json.deleted` on session start (new in this ticket). `reset.sh` deliberately skips `buddy_load` — CORRUPT buddy.json is still wipeable. Symlinked lock file is rejected to match `buddy_save`'s existing guard.
- **Placeholder XP ceiling.** `scripts/status.sh` uses `readonly NEXT_LEVEL_XP_PLACEHOLDER=100` for the XP line until P4-1 ships the real `xpForLevel(n) = 50 * n * (n + 1)` curve. Changing that's a one-line delete + call-site swap.
- **`${CLAUDE_PLUGIN_ROOT}` resolution.** SKILL.md invokes scripts as `bash "${CLAUDE_PLUGIN_ROOT}/scripts/<cmd>.sh"`, with a documented fallback instruction if the env var is unset. Live-plugin verification is a post-merge check; if `${CLAUDE_PLUGIN_ROOT}` turns out not to be exposed to LLM-invoked Bash, a `/ce:compound` entry will capture the finding.
- **Tests.** `tests/slash.bats` covers 28 scenarios: the full four-state matrix × 3 commands, reroll paid vs rejected vs gated, `tokens.earnedToday`/`windowStartedAt` preservation under reroll, deterministic-seed species/rarity pin, CORRUPT and FUTURE_VERSION variants, atomic reset (including the symlinked-lock-file FIFO guard wrapped in `timeout 3`), `state_cleanup_orphans` `.deleted` sweep, and two flock-race concurrency tests. Total suite: 146 tests green (state 64 + rng 54 + slash 28).

### Exit criteria check

- ✅ All three commands work across all four states (slash.bats matrix).
- ✅ Destructive ops (reroll, reset) are impossible to trigger accidentally — both require `--confirm`; without it, consequences are printed and no state mutates.
- ✅ `/buddy:stats` is useful pre-hatch — prints the hatch pointer.

### Review-driven changes (2026-04-19)

`/ce:review` at 9 reviewers (4 always-on + 2 CE + reliability, adversarial, cli-readiness) surfaced 17 findings. Applied the 11 `safe_auto` items:

- **Spec alignment (P1 — correctness COR-01):** Moved the token-balance check above the `--confirm` gate in `_hatch_reroll`. Plan R4 says insufficient-tokens rejection fires "with or without --confirm"; previous ordering printed the reroll-consequences message on 0 tokens + no `--confirm`. Added `hatch: ACTIVE + no --confirm + 0 tokens prints need-more message` test to pin the cell.
- **Envelope guard (COR-02):** `form` field now defaults to `base` when null/missing, so the reroll-gate message never reads "Lv.N null form".
- **Doc-comment fix (M-1):** `_hatch_compose_first_envelope` no longer documents a phantom third parameter.
- **Subshell asymmetry comment (REL-003/CR-04):** Added a comment explaining why `next_pity_counter` can safely use `$(...)` while `roll_buddy` cannot (pure arithmetic vs. LCG state).
- **XP placeholder derivation (M-4):** Inlined the `50*n*(n+1)` evaluation so the P4-1 hand-off is self-explanatory.
- **SKILL.md consistency (M-5):** Standardized Output-section wording across `hatch`, `stats`, `reset` ("verbatim, as the buddy's voice").
- **`--confirm` detection tightening (CR-03):** Replaced "inspect for literal token --confirm" with directive-vs-mention guidance + negative examples so "what does --confirm do?" doesn't accidentally dispatch with the flag.
- **Reset no-op wording (CR-05):** Distinct `"No buddy to reset. Run /buddy:hatch to hatch one."` for both the data-dir-missing and the buddy.json-missing paths so agents can tell no-op from destructive-wipe from stdout alone.
- **Actionable flock-timeout (REL-004):** `reset.sh`'s timeout message now tells the user what to do next.
- **Test coverage gaps (T-1, T-2, T-5/ADV-001, RR-2-testing):** Added `hatch: CORRUPT + --confirm`, `hatch: FUTURE_VERSION + --confirm`, envelope-guard regex trip test, reroll-paid pity-counter assertion, and `totalHatches == 1` assertion on the hatch-vs-reset race to pin the design intent.

Total suite: **151 tests green** (state 52 + rng 66 + slash 33, up from 146). Regression check passes.

Deferred and documented as known issues (not fixed in P1-3):

- **Lost-update race (REL-001 / ADV-001, P2):** `buddy_load` reads outside the flock; `buddy_save` acquires independently. Two racing rerolls can each decrement tokens with one losing its write. Currently theoretical (tokens start at 0 until P5). Full fix needs a `buddy_load_locked` helper or inlined flock-held read-modify-write in `hatch.sh` — deferred to P5 when token economy makes the race observable. The `totalHatches == 1` assertion in the hatch-vs-reset concurrency test pins the design intent now.
- **No `--json` mode on `status.sh` (CR-01, P3):** Agents parse human-readable output. Deferred until we hit a concrete need.
- **Usage vs internal exit codes share code 1 (CR-02, P3):** POSIX convention is 2 for arg errors. Contract change — defer.
- **No `--help` flag (CR-06, P3):** Agents read SKILL.md instead. Defer.
- **`${CLAUDE_PLUGIN_ROOT}` availability (advisory):** Still an open post-merge verification.

Advisory/informational findings (no action taken, logged for context):

- **PS-001:** Ticket status went `todo → done` without a recorded `in-progress` commit on this branch. Process gap, can't fix retroactively.
- **PS-002:** `_inject_tokens` test helper bypasses flock — test scaffolding, outside the runtime write discipline CLAUDE.md targets.
- **ADV-002, ADV-003, ADV-004, REL-002:** 100MB-JSON performance, unlocked `.deleted` sweep, SIGINT error message, and the P3-1 dependency for automatic orphan cleanup — all benign or explicitly scoped out.
