---
id: P5
title: Reroll token economy
phase: P5
status: todo
depends_on: [P4-2]
origin_plan: docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md
---

# P5 — Reroll tokens

## Goal

Close the gacha loop. Tokens accrue from coding activity; rerolling costs tokens. Enough tension that a reroll is a real decision, not free spam.

## Tasks

- [ ] **Token accrual** in `hooks/stop.sh` (runs at end of each Claude response):
  - [ ] +1 token per active session-hour (sum of wall-clock between first-event-of-session and Stop, capped at 1 token per full hour).
  - [ ] Rolling 24h cap of 3 tokens/day from session activity (window starts at first token earn; resets on 24h expiry).
  - [ ] Store cap state in `buddy.tokens.windowStartedAt` + `earnedToday`.
- [ ] **Milestone bonuses** (bypass daily cap, fire once per milestone per buddy):
  - [ ] +2 on first evolution.
  - [ ] +5 on shiny hatch (once shiny exists in P7-2 — guard with feature flag until then).
- [ ] **Reroll cost**: 10 tokens (configurable via `userConfig.rerollCost`).
- [ ] Update `scripts/hatch.sh` (from P1-3):
  - [ ] Enforce token check before reroll.
  - [ ] Deduct 10 atomically on reroll via flock'd write.
  - [ ] Insufficient-token path: `"You have N tokens; reroll costs 10. Earn 1 per active session-hour, up to 3 per day."`
- [ ] Show token balance in `/buddy` status output with estimated time to next affordable reroll.
- [ ] `userConfig` additions:
  ```json
  "rerollCost":       { "type": "integer", "default": 10, "description": "Tokens required to reroll" },
  "tokensPerHour":    { "type": "integer", "default": 1,  "description": "Tokens earned per active session-hour" },
  "dailyTokenCap":    { "type": "integer", "default": 3,  "description": "Max tokens earned per rolling 24h" }
  ```
- [ ] Tests:
  - [ ] Simulate a 3-hour session → +3 tokens (at cap).
  - [ ] Simulate 2 sessions separated by 25h → window resets correctly.
  - [ ] Milestone bonus applied exactly once per buddy.
  - [ ] Reroll with exactly 10 tokens → new buddy + 0 tokens (drains correctly).
  - [ ] Reroll after reroll: evolution state resets; token balance reflects net deduction only.

## Exit criteria

- Token balance is visible, predictable, and matches expected earn rate for the user's activity.
- Reroll is gated correctly; insufficient-token message is helpful.
- A committed user can reroll after ~10 active session-hours.

## Notes

- Rolling 24h (not midnight local/UTC) because midnight resets create grind pressure ("let me just stay up till midnight to reroll"). Rolling windows respect the user's schedule.
- Max-level XP continues to accrue (from P4-1) but doesn't earn extra tokens — tokens are purely session-time-based. Prevents a "grind at max level forever" loop.
- Reroll never touches `tokens.balance` directly beyond the 10-token deduction. Rerolling is about getting a new buddy, not economy reset.
- Related: Plan Acceptance Criteria R8, Risk Matrix row "60/25/10/4/1 feels too stingy".
