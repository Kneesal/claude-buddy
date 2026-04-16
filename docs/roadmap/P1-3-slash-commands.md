---
id: P1-3
title: Slash command state machine
phase: P1
status: todo
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
