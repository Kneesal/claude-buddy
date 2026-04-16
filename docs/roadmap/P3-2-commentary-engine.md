---
id: P3-2
title: Commentary engine (canned v1)
phase: P3
status: todo
depends_on: [P3-1]
origin_plan: docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md
---

# P3-2 — Commentary engine (canned)

## Goal

Buddy chimes in ≤ 8 times per session with on-brand, species-specific lines. Three-layer rate limit prevents spam. No LLM yet (P6); all lines are pre-written and selected via shuffle-bag.

## Tasks

- [ ] Create `scripts/lib/commentary.sh` exposing `maybe_comment <event_type> <payload_json>`.
- [ ] **Rate-limit stack** (in order):
  - [ ] **Event-novelty gate**: skip if `event_type == session.lastEventType` (suppresses "you did another Edit... and another...").
  - [ ] **Exponential backoff per event type**: 1st fire immediate, 2nd after 5min cooldown, 3rd+ flat 15min.
  - [ ] **Per-session budget**: default 8 comments/session, capped via `userConfig.commentsPerSession` in `plugin.json`.
- [ ] **Line selection** via shuffle-bag (no repeats until bag exhausted) keyed by `species.line_banks.<EventType>`.
- [ ] **Line banks** in `scripts/species/<name>.json`:
  - [ ] 50+ lines per species per major event type (`PostToolUse`, `PostToolUseFailure`, `Stop`).
  - [ ] Rare "milestone" banks: first edit of session, long session (>1h), burst of errors (3+ in 5min).
- [ ] Voice review: each species's line bank is read end-to-end to confirm consistent archetype voice before merge.
- [ ] Wire `maybe_comment` calls into `hooks/post-tool-use.sh`, `hooks/post-tool-use-failure.sh`, `hooks/stop.sh`.
- [ ] Output format: single-line speech bubble with species icon + speech: `🦎 Pip: "ooh a green test, i'm so proud"`.
- [ ] Stress test: 100 tool uses in 60 seconds → ≤ 3 comments (novelty gate + backoff).
- [ ] `userConfig` additions in `plugin.json`:
  ```json
  "userConfig": {
    "commentsPerSession": { "type": "integer", "default": 8, "description": "Max comments per session" }
  }
  ```

## Exit criteria

- Buddy comments contextually across event types.
- Burst behavior is controlled (stress test passes).
- Each species has a voice distinct enough to be recognizable from 5 random lines.

## Notes

- Line bank size (50+) is a content commitment — plan to iterate on these, they're the biggest quality lever pre-P6.
- Surprise budget exemption: milestone events (first evolution, shiny hatch) bypass the per-session cap. This keeps rare moments feeling rare.
- Keep line banks in species JSON (not inline in shell) so non-technical contributors can PR voice improvements.
- Rate-limit reference patterns from Clippy retrospectives and Discord rate-limit docs are captured in Plan D3.
