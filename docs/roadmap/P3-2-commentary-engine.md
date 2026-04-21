---
id: P3-2
title: Commentary engine (canned v1)
phase: P3
status: done
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

### Implementation notes (2026-04-21)

- Plan: [docs/plans/2026-04-20-003-feat-p3-2-commentary-engine-plan.md](../plans/2026-04-20-003-feat-p3-2-commentary-engine-plan.md).
- Engine lives at `scripts/hooks/commentary.sh` (hook-layer, parallels `common.sh`). `scripts/lib/` reserved for non-hook-aware primitives per D1 of the plan.
- `hook_commentary_select` returns a two-line stdout payload — line 1 = comment (or empty), line 2 = compact session JSON. This dodges the `$(...)` subshell scope problem that eats global variables written inside the substitution.
- All rate-limit state (cooldowns, budget, shuffle-bag, lastEventType, recentFailures) persists in `session-<id>.json` and is written inside the existing per-session flock, satisfying the adversarial-review finding from P3-1.
- Stop hook body restored (bare `exit 0` in P3-1). Bypasses all three gates per D7; still runs under the flock for consistency. Gated by `BUDDY_STOP_LINE_ON_EXIT` (default true).
- 5 species × 50+ lines × 3 event types + 10+ lines per milestone bank (first_edit, error_burst, long_session) shipped in `scripts/species/*.json`. Structural tests in `tests/species_line_banks.bats` assert size, uniqueness-within-bank, no tabs, no newlines. Voice consistency remains a manual review gate.
- 286 bats tests green; perf p95 under 100ms across all four hooks (PTU 87ms, PTUF 23ms, Stop 57ms, SessionStart 23ms on 100 iterations).

### Live-session smoke (2026-04-21)

Ran the recipe from [docs/solutions/developer-experience/claude-code-plugin-hooks-json-schema-2026-04-20.md](../solutions/developer-experience/claude-code-plugin-hooks-json-schema-2026-04-20.md) §B. Two findings:

1. **`userConfig` manifest schema**. Design-doc example used `"type": "integer"` and omitted `title`. Claude Code rejected the manifest with an `[ERROR]` line only visible in `--debug-to-stderr`. Valid types are `"string"|"number"|"boolean"|"directory"|"file"`; `title` is required. Fixed in this ticket. Documented in [docs/solutions/developer-experience/claude-code-plugin-userconfig-manifest-schema-2026-04-21.md](../solutions/developer-experience/claude-code-plugin-userconfig-manifest-schema-2026-04-21.md) — same trap-shape as the hooks.json schema doc.
2. **Commentary surfaces as plain text**. Post-fix, hook stdout surfaces in the transcript as a plain-text system message. Claude Code's debug log: `Hook output does not start with {, treating as plain text`. Captured lines from the smoke run:
   - PTU first_edit: `🦎 Custard: "one small step for the buddy..."`
   - Stop default: `🦎 Custard: "close your laptop like a book, a good book"`
   Both lines verified in the hook process's stdout via a temporary tee; the `claude -p` headless interface only surfaces the assistant's final message, so confirming transcript visibility in an interactive session is a follow-up smoke for P4+ (no regression in this ticket).
