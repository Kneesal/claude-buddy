---
id: P4-1
title: XP + evolution signal accumulation
phase: P4
status: in-progress
depends_on: [P3-1]
origin_plan: docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md
---

# P4-1 — XP + signals

## Goal

Accumulate XP and the four behavior-axis signals (consistency, variety, quality, chaos) that drive evolution in P4-2. Every hook contributes to `buddy.json.signals` atomically.

## Tasks

- [ ] XP curve: `xpForLevel(n) = 50 * n * (n + 1)` — Lv 2 at 100 XP, Lv 5 at 750, Lv 10 at 2750. Store formula in `scripts/lib/evolution.sh`.
- [ ] **XP sources** (all flow through `buddy_save` with flock):
  - [ ] `PostToolUse` → +2 XP.
  - [ ] `PostToolUseFailure` → +1 XP (failure still counts — no punishment).
  - [ ] `Stop` → +5 XP (completion bonus), +2 per active-session-hour in session.
  - [ ] Streak bonus: +10 XP on the first event of a day that extends `consistency.streakDays`.
- [ ] **Signal accumulation** (same hooks, different fields):
  - [ ] `PostToolUse`:
    - Append tool name to `variety.toolsUsed` (dedup, retain last 7 active days).
    - If tool ∈ {Edit, Write, MultiEdit}: `quality.successfulEdits++`, `quality.totalEdits++`.
    - If same file as last tool call: `chaos.repeatedEditHits++`.
    - Update `consistency.lastActiveDay` and bump `streakDays` if new calendar day and <= 1 day gap from last.
  - [ ] `PostToolUseFailure`:
    - `chaos.errors++`, `quality.totalEdits++`.
- [ ] **Level-up event**: when `xp >= xpForLevel(level+1)`, increment level and fire a surprise-budget-exempt level-up comment via `commentary.sh`.
- [ ] **Max-level handling**: level 50 cap initially. XP over cap accrues to `xp` field (visible via `/buddy`) but no further level transitions. No capping weirdness.
- [ ] Tests:
  - [ ] Simulate 1 week of 20 tool uses/day → expected level (~5-6), expected signals.
  - [ ] Streak days increments correctly across day boundaries.
  - [ ] `chaos.errors` and `quality.successfulEdits` diverge under mixed success/failure.

## Exit criteria

- A realistic session produces level + signal increments visible in `/buddy`.
- Streak logic handles day boundaries, UTC vs local, gap tolerance.
- No hook ever blocks > 100ms from signal accumulation.

## Notes

- **Why four axes**: single-axis signals (Pokémon friendship) are trivial to grind. Four axes create cross-axis tension — optimizing one means neglecting another. Plan D2 and Digimon-V-Pet prior-art reference.
- All writes must go through the flock'd state API from P1-1. Never write directly.
- Retention of `variety.toolsUsed`: keep a 7-active-day window so variety reflects *recent* exploration, not tool types used once months ago.
- This ticket does NOT yet implement the form transition — that's P4-2. We only accumulate here.
