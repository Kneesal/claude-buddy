---
title: P4-1 — XP + evolution signal accumulation
type: feat
status: complete
date: 2026-04-21
origin: docs/roadmap/P4-1-xp-signals.md
---

# P4-1 — XP + evolution signal accumulation

## Overview

P3-2 made the hooks *speak*. P4-1 makes them *count*. Every
`PostToolUse`, `PostToolUseFailure`, and `Stop` event now accumulates
XP on `buddy.json.xp` and advances the four behaviour-axis signals
(`consistency`, `variety`, `quality`, `chaos`) that P4-2 will consume
to pick an evolution path. Level-ups fire a budget-exempt `LevelUp`
commentary line so the growth loop is visible.

This ticket is where the concurrency discipline P3-1 established on
`session-<id>.json` gets extended to `buddy.json`. Hooks are now a
concurrent load-modify-save consumer of the buddy file — the exact
shape the flock-discipline solutions doc warns about — so the
caller-held-flock pattern has to work on a second file, under a
strict lock ordering to avoid deadlock with the session lock the
hooks already hold.

## Problem Frame

P3-2 shipped the engine. Users see buddy talking, but the buddy
never changes. Level and XP are still zero from the hatch. The
visible Tamagotchi promise (R5 — *the buddy reflects how you
coded*) isn't met until signals accumulate and level-ups happen.
P4-1 is the atomic prerequisite: P4-2 cannot pick a form without
signal totals, and the reroll economy (P5) doesn't feel earned
without levels to reroll away. See
[brainstorm R5/R6](../brainstorms/2026-04-16-claude-buddy-plugin-requirements.md)
and [umbrella plan §P4.1 + D1/D2](2026-04-16-001-feat-claude-buddy-plugin-plan.md).

The secondary frame is a performance one. PostToolUse p95 is already
85 ms against a 100 ms budget after P3-2
([perf harness](../../tests/hooks/perf_hook_p95.sh)). P4-1 adds
another pass of jq work per fire — signals mutation, XP add,
level-up check — on top of the P3-2 commentary chain. Without
proactive fusion we blow the budget, which cascades into the
0.2 s flock timeout and real lost updates. Fusion is on the critical
path, not a footnote.

## Requirements Trace

- **R5** — buddy evolves based on behaviour across four axes.
  Ticket accumulates all four; P4-2 consumes them.
- **R6** — pure-growth progression. Signals are monotone (never
  decremented), level is monotone (no devolve).
- **Ticket exit criteria** —
  1. A realistic session produces level + signal increments visible
     in `/buddy:stats`.
  2. Streak logic handles UTC day boundaries with a documented
     gap-tolerance rule.
  3. No hook ever blocks > 100 ms from signal accumulation
     (perf harness green).

## Scope Boundaries

- No form transition / evolution path selection — that is P4-2.
- No new hook events. PTU/PTUF/Stop plus an internal `LevelUp`
  commentary case, dispatched from inside Stop/PTU when threshold
  crossed.
- No schemaVersion bump. Signals field is lazily initialised on
  first write via `// default` in jq; existing hatched buddies
  migrate silently on their next hook fire.
- No change to P2 status line text. The `xp / xpForLevel(level)`
  placeholder in `scripts/status.sh` gets a one-line swap to call
  the real helper, but no new lines are surfaced yet.
- No Stop-double-fire dedup. P3-2 flagged this on the residual
  list; it remains its own follow-up ticket (see Deferred to
  Separate Tasks).
- No telemetry / metrics surface for signals beyond what
  `/buddy:stats` shows.

### Deferred to Separate Tasks

- **Stop-double-fire dedup** — inherited from the P3-2 residual
  list. A follow-up ticket that adds a cheap `lastStopAt` check
  on the Stop hook. Deferred because it is orthogonal to P4-1's
  shape and would only widen review surface. The P4-1 Stop body
  increments XP once per fire and debouncing is left to the
  follow-up.
- **P3-2 residual: jq-fork collapse on `commentary.sh`** — **not
  deferred**. Absorbed by Unit 2 of this plan. The p95 headroom
  this ticket needs makes it load-bearing here; splitting it into
  its own ticket would leave P4-1 shipping over budget.
- **Evolution form selection (P4-2)** — signal *accumulation* is
  P4-1; signal *evaluation* is P4-2.

## Context & Research

### Relevant Code and Patterns

- `hooks/post-tool-use.sh`, `hooks/post-tool-use-failure.sh`,
  `hooks/stop.sh` — already hold the per-session flock across a
  load-modify-save cycle of `session-<id>.json`. P4-1 nests a
  second flock inside that critical section for `buddy.json`.
- `scripts/hooks/commentary.sh` — two-line stdout contract
  (`_BUDDY_SESSION_UPDATED` + `_BUDDY_COMMENT_LINE` marshalled via
  `_commentary_emit`). P4-1 adds a `LevelUp` event case alongside
  the existing PTU/PTUF/Stop handlers, bypassing all three rate-limit
  gates (same shape as Stop's D7 bypass).
- `scripts/hooks/common.sh` — hook-layer helpers. `hook_initial_session_json`
  owns the canonical session-file shape; P4-1 adds `lastToolFilePath`
  to it. `hook_ring_update` is the canonical in-repo fusion pattern
  (single jq, sentinel return) — the new `hook_signals_apply` helper
  mirrors it.
- `scripts/lib/state.sh` — `buddy_save` already holds flock **internally**.
  The solutions doc is explicit: internal flock is not sufficient
  when the caller does load-modify-save. Hooks will acquire their
  own flock on `buddy.json.lock` across the full cycle; `buddy_save`'s
  internal flock on the same file is re-entrant-safe on Linux
  (same fd, same process), but the **caller-held** lock is what
  provides the load→save invariant.
- `scripts/lib/rng.sh:587` — explicit deferral comment pointing at
  P4-1 as owner of the `signals` schema. No schemaVersion bump is
  required because `hook_signals_apply` reads signals via `// default`.
- `scripts/hatch.sh:_hatch_compose_first_envelope` — bakes the
  initial buddy envelope. P4-1 adds the signals skeleton here so
  new hatches start with the full shape; existing hatches get the
  same skeleton lazily on first hook fire.
- `scripts/status.sh` — contains a `NEXT_LEVEL_XP_PLACEHOLDER=100`
  constant explicitly marked for P4-1 replacement. Gets a real
  `xpForLevel(level)` call.
- `tests/hooks/perf_hook_p95.sh` — measurement harness. 100
  iterations per hook with a 100 ms ceiling. PTU baseline: 85 ms,
  Stop: 67 ms.

### Institutional Learnings

- [bash-state-library-concurrent-load-modify-save-2026-04-20](../solutions/best-practices/bash-state-library-concurrent-load-modify-save-2026-04-20.md)
  — the caller-held flock pattern, the split-TTL lesson, the
  adversarial-review lesson. P4-1 is the second application of the
  pattern (now `buddy.json` joins `session-<id>.json` as a
  load-modify-save target from hooks). The relevant section here
  is §A plus the hint that the per-resource lock file lives
  alongside the data file — `buddy.json.lock`, already created
  and flock'd by `buddy_save`, now caller-held across the full
  load-modify-save cycle.
- [bash-jq-fork-collapse-hot-path-2026-04-21](../solutions/best-practices/bash-jq-fork-collapse-hot-path-2026-04-21.md)
  — fusion-not-caching. P4-1's new `hook_signals_apply` is authored
  fused from the start (one jq, all signal mutations + XP add in
  a single filter), and Unit 2 retrofits fusion into the existing
  `commentary.sh` handlers to reclaim the headroom P4-1 is about
  to spend. §D's fork-cost table sets the budget.
- [bash-subshell-value-plus-json-return-2026-04-21](../solutions/best-practices/bash-subshell-value-plus-json-return-2026-04-21.md)
  — two-line stdout contract. `hook_signals_apply` follows the
  same shape: line 1 is a `LEVEL_UP:<n>` sentinel (or empty),
  line 2 is the updated buddy JSON (jq -c compacted). The caller
  splits on the first newline, just like the commentary caller
  pattern. Also relevant when the Stop hook marshals three signals:
  (level-up sentinel, updated buddy JSON, updated session JSON) —
  the plan uses two sequential two-line returns rather than a
  three-line contract, because sequential two-line returns compose
  and a three-line contract doesn't add value.
- [claude-code-plugin-hooks-json-schema-2026-04-20](../solutions/developer-experience/claude-code-plugin-hooks-json-schema-2026-04-20.md)
  — payload shape recipe. §C confirms PostToolUse carries
  `tool_input`. The `file_path` sub-field is what Edit/Write/MultiEdit
  put there; the live-smoke recipe in §B is reused in Unit 6 to
  verify it empirically before trusting it. No design-doc schema
  is authoritative until it has loaded in a real session.

### External References

- Not needed. All four solutions docs above were written in the
  last 48h specifically to feed this ticket; the engineering
  surface is covered.

## Key Technical Decisions

**D1. `buddy.json` gets a caller-held flock from hooks, nested INSIDE
the session lock.** Exact same discipline P3-1 applied to
`session-<id>.json`. Lock file is `${CLAUDE_PLUGIN_DATA}/buddy.json.lock`
(shared with `buddy_save`'s internal flock — the kernel permits a
process that already holds a write lock to re-acquire it). The
caller-held lock is what guarantees load→save atomicity; the
internal lock in `buddy_save` stays as a library-level safety net
for non-hook callers.

**D2. Lock ordering is fixed, deadlock-prevention load-bearing: session
FIRST, buddy INSIDE.** Hooks enter holding the session lock (from P3-2).
They acquire `buddy.json.lock` after. They release in reverse order.
Any code path that ever takes both locks MUST follow this order.
Documented in-line at every acquisition site and asserted by a bats
test that fires two hooks with inverted order through a mock and
observes the deadlock (caught by flock timeout → error-logged →
hook exits 0). The inversion is rejected in review, not permitted
at runtime.

**D3. Signals schema lives at `.buddy.signals`; lazy-init via `// default`; no schemaVersion bump.**
Shape mirrors the hatch skeleton documented in the umbrella plan:

```json
{
  "signals": {
    "consistency": { "streakDays": 0, "lastActiveDay": "1970-01-01" },
    "variety":     { "toolsUsed": {} },
    "quality":     { "successfulEdits": 0, "totalEdits": 0 },
    "chaos":       { "errors": 0, "repeatedEditHits": 0 }
  }
}
```

New fields (`lastActiveDay` as ISO date, `toolsUsed` as flat map —
see D6) are readable with `// default` in jq, so mid-session plugin
upgrades don't need a migration. `hatch.sh` bakes the skeleton on
first hatch so new buddies start with the exact shape; existing
buddies pick it up transparently on their next hook fire. This
mirrors the additive-shape discipline P3-2 used for the session
file.

**D4. XP curve and level function live in `scripts/lib/evolution.sh`.**
New file. Hosts `xpForLevel(n) = 50 * n * (n + 1)` as a pure bash
arithmetic function, plus `level_for_xp(xp)` (iterate until next
threshold exceeds xp, capped at `MAX_LEVEL=50`). Both are O(level)
which is cheap — at Lv 50 that's 50 iterations of integer arith.
Placed in `scripts/lib/` (not `scripts/hooks/`) because the
helpers are pure math with no state-lib dependency, and
`scripts/status.sh` (non-hook caller) needs `xpForLevel` too.
`MAX_LEVEL` is declared here; XP over the Lv 50 threshold accrues
to `xp` but no further level transitions occur.

**D5. `hook_signals_apply` is ONE fused jq per event, returning level-up sentinel + updated buddy JSON via two-line stdout.**
Signature:

```
hook_signals_apply <event_type> <buddy_json> <event_inputs_json>
  event_inputs_json: { "toolName": "...", "filePath": "...",
                       "filePathMatchedLast": true|false,
                       "now": <epoch>, "today": "YYYY-MM-DD",
                       "sessionActiveHours": 0.0 }
Emits:
  line 1: "LEVEL_UP:<new_level>" or empty
  line 2: compact updated buddy JSON (jq -c)
```

One jq invocation does the full mutation: streak bump, toolsUsed
prune+write, quality counters, chaos counters, XP add, level check.
The caller (hook) computes inputs cheaply (`date`, payload parse),
then hands them over as `--argjson`. This is the fusion pattern
from §B of the jq-fork-collapse doc; in isolation it is one jq
fork per hook fire against the buddy file, replacing a naive 6-8
sequential jqs. Level-up detection is built into the same filter:
the filter computes the new XP, derives the target level, and
emits the sentinel on stdout line 1 if it advanced. No separate
pass.

**D6. `variety.toolsUsed` is a flat map `{ "<tool>": <epoch_last_seen> }`, prune-on-write > 7 days.**
Chosen over the alternative (array of day-bucket objects) because
(a) jq mutation is one-liner `.toolsUsed[$t] = $now` vs nested
array-find-and-modify, (b) the prune step is a one-liner
`with_entries(select(.value > ($now - 604800)))`, (c) map size is
strictly bounded by the tool roster (~10-20 tools max), so no
unbounded growth. Readers that need a *count* of distinct tools
run `length` on the map — same cost as array length, no
normalisation. Retention is measured from last-seen rather than
first-seen so a tool used daily always stays in.

**D7. Streak boundary: UTC calendar day, gap tolerance ≤ 1 day.**
`lastActiveDay` is stored as a `YYYY-MM-DD` string in UTC
(matching `state.sh`'s other timestamps, which are UTC ISO-8601).
On each hook fire:
- if `today == lastActiveDay` → no streak change;
- if `today == lastActiveDay + 1 day` → `streakDays++`, bump
  `lastActiveDay`;
- if `today > lastActiveDay + 1 day` OR `lastActiveDay == "1970-01-01"`
  → reset `streakDays = 1`, bump `lastActiveDay`.

The `1970-01-01` sentinel is the signals-skeleton default, so a
first-ever signal write reliably lands in the "reset to 1" branch
without a special case. Boundary correctness is exercised in Unit 5
with time-mocked hook fires straddling 00:00 UTC.

**D8. `repeatedEditHits` is detected via `session.lastToolFilePath`, set on every PTU, bumped on match AND Edit/Write/MultiEdit tool.**
New session-file field, added to `hook_initial_session_json`. PTU
reads `tool_input.file_path` from the payload (verified empirically
in Unit 6 per the hooks-schema doc's §B smoke recipe); compares to
the session's `lastToolFilePath`; if equal AND the tool is in
{Edit, Write, MultiEdit}, bumps `chaos.repeatedEditHits`. Always
updates the field regardless of match. Tools that don't carry a
`file_path` (e.g. Bash, Grep) set it to empty string, which cannot
match a prior non-empty value, so they naturally don't contribute
to the counter. This keeps the rule pure-data — no tool allow-list
beyond the Edit/Write/MultiEdit set.

**D9. Level-up commentary is a new event type routed through `hook_commentary_select`, bypassing all three gates.**
Same shape as Stop (D7 from P3-2): no novelty/cooldown/budget
gates, still held inside whatever flock is active. Species line
banks get a new `LevelUp.default` bank of 10+ lines per species.
Selection uses the existing shuffle-bag. This keeps the voice
layer the single owner of anything user-visible; P4-1 doesn't
grow a second commentary path.

**D10. Stop-hook body gains XP + streak + level-up work, explicitly interleaved with P3-2's commentary path and all under both locks.**
Stop ordering inside the critical section (session lock + buddy
lock, in that order):
1. `session_load` + init defaults (existing).
2. `buddy_load` + signals lazy-init.
3. Compute event inputs (`sessionActiveHours` from `startedAt`).
4. `hook_signals_apply "Stop" $buddy $inputs` → captures level-up
   sentinel + updated buddy JSON.
5. `hook_commentary_select "Stop" $session $buddy_updated` →
   captures commentary line + updated session JSON.
6. If level-up sentinel was set, run a second
   `hook_commentary_select "LevelUp" $session_after_stop $buddy_updated`
   → overwrites the Stop commentary line with the level-up line
   (the level-up is the more informative message; the Stop line is
   deliberately suppressed this fire).
7. `buddy_save` under buddy lock; `session_save` under session lock.
8. Release buddy lock; release session lock; emit the line.

PTU/PTUF ordering is the same shape, minus the `sessionActiveHours`
computation (N/A for tool events). Level-up + commentary collision:
PTU can also trigger level-up (XP +2 per fire; at the threshold
the level-up line takes priority over any PTU commentary this
fire).

**D11. Emit ordering: the single `printf` at end of hook stays after BOTH lock releases and BOTH saves commit.**
Preserves the P3-2 guarantee that an interrupted printf cannot
desync state from what the user saw. For Stop's dual-write case
(buddy + session), both saves must succeed before the printf; a
failure on either save clears the captured line and exits 0 so
the user sees nothing when the state didn't commit.

**D12. `MAX_LEVEL = 50`. Over-cap XP accrues; no level transitions fire.**
Per the ticket. The level check in `hook_signals_apply` computes
`min(new_level, MAX_LEVEL)`. The level-up sentinel fires only when
the capped value strictly exceeds the prior level. Once at 50,
never again.

## Open Questions

### Resolved During Planning

- **Flock scope on `buddy.json`?** Caller-held across the hook's
  load-modify-save, same pattern as session lock (D1).
- **Lock ordering?** Session FIRST, buddy INSIDE, release reverse.
  Documented in-line, tested adversarially (D2).
- **Schema migration?** Lazy-init via jq `// default`. No
  schemaVersion bump (D3).
- **`toolsUsed` retention shape?** Flat map `{ "<tool>": <epoch> }`
  with prune-on-write > 7 days (D6).
- **Streak day boundary?** UTC calendar day, gap tolerance ≤ 1 day,
  `1970-01-01` sentinel as reset default (D7).
- **Level-up commentary delivery?** New `LevelUp` case in
  `hook_commentary_select`, bypasses all three gates, draws from
  `species.line_banks.LevelUp.default` (D9).
- **`repeatedEditHits` detection?** Session-scoped
  `lastToolFilePath`; bump on match + Edit/Write/MultiEdit; always
  update field (D8).
- **P3-2 residual "jq-fork collapse on commentary.sh"?** Absorbed
  into this ticket as Unit 2 (required for budget headroom).
- **P3-2 residual "Stop-double-fire dedup"?** Deferred to its own
  follow-up ticket. The P4-1 Stop body does not debounce.
- **Concurrency harness scope?** In-ticket. Covers both session
  and buddy files in one bats file (back-fills the P3-2 review
  gap).

### Deferred to Implementation

- Exact jq filter layout for `hook_signals_apply` — the decision
  tree is known (D5) but the `--argjson` layout and the inline
  sub-branches are a micro-decision best made against the real
  signals blob.
- Per-line content for `LevelUp.default` across 5 species (Unit 5).
  Voice-review checkpoint mirrors the P3-2 approach before Unit 5
  wires selection.
- Whether `_commentary_format` handles the level-up line as a
  plain string or gets a `LevelUp`-specific decoration (e.g.,
  `✨ <emoji> <name>: "…"`). Default to the existing format;
  revisit only if the voice review wants it.

## High-Level Technical Design

> *Directional guidance, not implementation specification.*

Hook (e.g., post-tool-use.sh) flow with P4-1 layered on P3-2:

```
post-tool-use.sh
        │
        ▼
 [acquire session flock]                         ← P3-1
        │
        ▼
 session_load → ring_update → dedup? exit
        │
        ▼
 [acquire buddy flock]   ← NEW: nested inside session flock (D1/D2)
        │
        ▼
 buddy_load → signals lazy-init
        │
        ▼
 compute inputs: {toolName, filePath, filePathMatchedLast,
                  now, today, sessionActiveHours}
        │
        ▼
 hook_signals_apply PostToolUse $buddy $inputs   ← ONE fused jq (D5)
        │
        ├── line 1: "LEVEL_UP:<n>" or ""
        └── line 2: updated buddy JSON (jq -c)
        │
        ▼
 hook_commentary_select PostToolUse $session $buddy
        │
        ▼ (if level_up) hook_commentary_select LevelUp $session $buddy
        │                ── overwrites previous commentary_line
        │
        ▼
 buddy_save  ← under buddy flock
 session_save← under session flock (unchanged; update lastToolFilePath in session before save)
        │
        ▼
 [release buddy flock]
        │
        ▼
 [release session flock]
        │
        ▼
 printf "$commentary_line"   (only here, post-lock, post-save)
        │
        ▼
 exit 0
```

Buddy JSON shape after P4-1 (additive; fields below are **new**):

```json
{
  "schemaVersion": 1,
  "buddy": {
    "level": 3,
    "xp": 420,
    "signals": {
      "consistency": { "streakDays": 4, "lastActiveDay": "2026-04-21" },
      "variety":     { "toolsUsed": { "Edit": 1745270100, "Bash": 1745269900 } },
      "quality":     { "successfulEdits": 42, "totalEdits": 45 },
      "chaos":       { "errors": 3, "repeatedEditHits": 2 }
    }
  }
}
```

Session JSON gains exactly one field: `lastToolFilePath: "<path>"`
(empty string at init).

## Implementation Units

- [x] **Unit 1: `scripts/lib/evolution.sh` + signals skeleton + session extension**

**Goal:** Ship the pure library primitives and the shape-additive
plumbing. No hook behaviour changes yet.

**Requirements:** R5, R6.

**Dependencies:** None.

**Files:**
- Create: `scripts/lib/evolution.sh` — pure helpers:
  `xpForLevel`, `level_for_xp`, `signals_skeleton` (emits the D3
  JSON fragment on stdout), `MAX_LEVEL=50` readonly.
- Modify: `scripts/hatch.sh` — bake `signals_skeleton` into the
  first-hatch envelope alongside existing `xp: 0`, `level: 1`.
- Modify: `scripts/hooks/common.sh` —
  `hook_initial_session_json` gains `lastToolFilePath: ""`.
- Modify: `scripts/status.sh` — swap `NEXT_LEVEL_XP_PLACEHOLDER`
  for `xpForLevel(level)`. One-line cosmetic change.
- Create: `tests/lib/test_evolution.bats`.
- Modify: `tests/hooks/test_common.bats` —
  assert the new session field.
- Modify: `tests/test_hatch.bats` (if present) or
  `tests/lib/test_rng.bats` — assert the hatch envelope contains
  the signals skeleton.

**Approach:**
- `xpForLevel(n)`: arithmetic, caps at `MAX_LEVEL + 1` threshold
  (so level_for_xp loops up to 50 then stops).
- `level_for_xp(xp)`: loop `n` from 1 upward while
  `xp >= xpForLevel(n+1)` and `n < MAX_LEVEL`.
- `signals_skeleton`: emits compact JSON via `jq -n -c`; takes
  no args. `lastActiveDay` defaults to `"1970-01-01"` (the
  sentinel per D7).
- Source guard mirrors `state.sh`'s `_STATE_SH_LOADED` pattern.

**Patterns to follow:**
- `scripts/lib/state.sh` source guard + bash 4.1 check at top.
- `scripts/lib/rng.sh` pure-function style — no hidden state
  beyond readonly constants.

**Test scenarios:**
- Happy path: `xpForLevel 1` → 100; `xpForLevel 5` → 1500;
  `xpForLevel 10` → 5500. (Values: 50 * n * (n+1). Ticket lists
  Lv 2 at 100 XP, Lv 5 at 750, Lv 10 at 2750 — those are
  *cumulative* thresholds; verify `level_for_xp 100 → 2`,
  `level_for_xp 750 → 5`, `level_for_xp 2750 → 10`. The
  implementation unit decides the exact formula branching; plan
  pins the public values.)
- Happy path: `level_for_xp 99 → 1`, `level_for_xp 100 → 2`.
- Edge case: `level_for_xp 999999999 → 50` (cap).
- Edge case: `level_for_xp 0 → 1`.
- Structural: `signals_skeleton | jq -e '.consistency.streakDays == 0 and .chaos.errors == 0'` passes.
- Integration (hatch): a freshly hatched envelope contains all four
  signal sub-objects with zero/default values; a status-line read
  of `.buddy.signals.consistency.streakDays` returns 0.
- Integration (session): `hook_initial_session_json` output has
  `lastToolFilePath == ""`.

**Verification:**
- All bats files pass. `/buddy:hatch` in a scratch workspace
  produces `buddy.json` with the signals block present.

---

- [x] **Unit 2: jq-fork collapse on `commentary.sh` hot paths**

**Goal:** Reclaim p95 headroom before Unit 4 adds new work. Fuse
the sequential jq mutations in `_commentary_handle_ptu`,
`_commentary_handle_ptuf`, and `_commentary_handle_stop` into
single jq invocations per event.

**Requirements:** Ticket exit criterion 3 (p95 < 100 ms).

**Dependencies:** None (purely in-place refactor of P3-2 code).

**Files:**
- Modify: `scripts/hooks/commentary.sh` — fuse
  `_commentary_handle_ptu` mutations (lastEventType set + cooldown
  bump + budget bump + optional firstEditFired toggle) into ONE
  jq per successful emit path; similarly for PTUF and Stop.
- Modify: `scripts/hooks/commentary.sh` — `_commentary_draw` is
  already three jqs (bank resolve, bag read, bag update); collapse
  the bag-read-and-update pair into one filter returning
  `[line_index, new_bag_json]` via `@tsv` per pattern B.3 of the
  fork-collapse doc.
- Modify: `tests/hooks/test_commentary.bats` — existing scenarios
  must stay green (black-box behavioural tests; fusion is
  internal).
- Modify: `tests/hooks/perf_hook_p95.sh` — no code change;
  baseline re-recorded in the ticket Notes.

**Approach:**
- PTU handler: consolidate the three `printf '%s' | jq …` mutation
  pipes (lastEventType, cooldown, budget, optional firstEditFired)
  into one jq with `--arg e`, `--argjson fires`, `--argjson next`,
  `--argjson incr_budget`, `--argjson set_first`. Use `//= false`
  default read semantics so "don't set firstEditFired" is a no-op
  branch inside the same filter.
- PTUF handler: same consolidation plus fold the `recentFailures`
  trim into the same jq (it's already one pipe but separate from
  lastEventType mutation).
- Stop handler: consolidate `_commentary_bump_budget` into the
  draw-update jq.
- `_commentary_draw`: fuse bag read + write (pattern B.3 in the
  fork-collapse doc — return `[line, updated_json]` via tsv).
- Measure with `tests/hooks/perf_hook_p95.sh` before and after.
  Target: PTU ≤ 75 ms p95 (leave ≥ 25 ms headroom for Unit 4 add).

**Patterns to follow:**
- `scripts/hooks/common.sh:hook_ring_update` — canonical single-jq
  fusion with sentinel return.
- Pattern B.3 from
  [bash-jq-fork-collapse-hot-path-2026-04-21.md](../solutions/best-practices/bash-jq-fork-collapse-hot-path-2026-04-21.md)
  for "emit scalar + updated JSON from one jq".

**Test scenarios:**
- All existing P3-2 bats scenarios pass unchanged. Fusion is a
  refactor; observable behaviour does not change.
- Perf: before-and-after numbers recorded in ticket Notes; PTU
  p95 drops from 85 ms to ≤ 75 ms on the 100-iteration harness.
- Edge case (jq failure): malformed session JSON still exits via
  the `_commentary_emit` empty-pass-through fallback — verify
  one scenario where a fused jq is fed bad input and the
  function returns empty scalar + empty JSON (not a crash).

**Verification:**
- `test_commentary.bats` green.
- Perf harness runs at the new baseline; numbers logged in ticket
  Notes for future reference.

---

- [x] **Unit 3: `hook_signals_apply` — fused signals + XP + level-up evaluator**

**Goal:** Add the single-entry helper that hooks call to mutate
`buddy.json.signals`, add XP, and detect level-ups — all in one
jq invocation. Pure function in a new hook-layer module; no
filesystem I/O.

**Requirements:** R5, R6, ticket exit criterion 1.

**Dependencies:** Unit 1 (evolution.sh pure lib is callable
from this filter's helpers).

**Files:**
- Create: `scripts/hooks/signals.sh` — sourced by the three hooks.
  Exports `hook_signals_apply`.
- Create: `tests/hooks/test_signals.bats`.

**Approach:**
- Source-guard mirroring `commentary.sh` (`_BUDDY_SIGNALS_LOADED`).
- Public function:
  ```
  hook_signals_apply <event_type> <buddy_json> <event_inputs_json>
    event_inputs_json: { toolName, filePath, filePathMatchedLast,
                         now, today, sessionActiveHours }
    Stdout line 1: "LEVEL_UP:<n>" or empty
    Stdout line 2: compact updated buddy JSON (jq -c)
    Return 0 on success; 1 only on caller-programming errors
    (missing inputs). On any internal jq failure, emit
    empty-scalar + empty-blob; caller falls back to pre-call
    buddy JSON and skips emit (D11).
  ```
- Single jq invocation per call. `--arg event`, `--argjson in`
  (event_inputs), plus `--argjson xp_add` (hook-computed per D10
  rules below).
- XP rules inside the filter (tracing ticket task list):
  - PTU → +2
  - PTUF → +1
  - Stop → +5 base + 2 × floor(sessionActiveHours)
  - Streak-extend bonus → +10 (added inside the filter when the
    streak branch fires; not passed in, so it can't be
    double-counted).
- Signal rules (four axes):
  - **consistency**: apply D7 streak rule; update
    `lastActiveDay` unconditionally to the later of `today` and
    current value; bump `streakDays` or reset as per D7.
  - **variety.toolsUsed**: set `[$toolName] = $now`; then
    `with_entries(select(.value > ($now - 604800)))`. Skip set
    if `toolName` is empty.
  - **quality**:
    - PTU with toolName ∈ {Edit, Write, MultiEdit}:
      `successfulEdits++`, `totalEdits++`.
    - PTUF: `totalEdits++`.
    - Stop: no change.
  - **chaos**:
    - PTUF: `errors++`.
    - PTU with `filePathMatchedLast == true` AND toolName ∈
      {Edit, Write, MultiEdit}: `repeatedEditHits++`.
    - Stop: no change.
- Level evaluation inside the same filter: compute
  `new_xp = current_xp + $xp_add + streak_bonus`; derive
  `target_level = min(level_for_xp(new_xp), MAX_LEVEL)`. Because
  jq has no function for the loop, `level_for_xp` is inlined as
  a jq function (`def level_for_xp`) — level_for_xp is O(level),
  bounded to 50 steps, cheap. `LEVEL_UP:<n>` is emitted on
  stdout line 1 iff `target_level > current_level`; buddy JSON
  on line 2 sets `level = target_level`, `xp = new_xp`.
- Lazy-init: the filter reads signals via
  `.buddy.signals // $skel` where `$skel` is the D3 skeleton
  passed in as `--argjson skel`. This keeps the signals-skeleton
  JSON out of the jq program text.

**Patterns to follow:**
- `scripts/hooks/common.sh:hook_ring_update` — single-jq fusion
  returning (sentinel | JSON) on stdout.
- Two-line stdout contract from
  [bash-subshell-value-plus-json-return-2026-04-21.md](../solutions/best-practices/bash-subshell-value-plus-json-return-2026-04-21.md).
- `scripts/hooks/commentary.sh:_commentary_emit` defensive empty
  fallback on jq failure.

**Test scenarios:**
- Happy path (PTU + Edit): toolsUsed gets the tool with now;
  quality counters advance; XP += 2; no level-up at low XP.
- Happy path (PTU + Bash, first fire of the day):
  streakDays becomes 1 from the `1970-01-01` sentinel;
  lastActiveDay updates to today; XP += 2 + 10 (streak bonus)
  = 12.
- Happy path (PTU + Edit, same file as last call):
  repeatedEditHits += 1; quality.successfulEdits += 1.
- Happy path (PTUF): errors += 1; totalEdits += 1; XP += 1.
- Happy path (Stop, 65 min session): XP += 5 + 2×1 = 7;
  sessionActiveHours propagates.
- Edge case (streak continuation): today = lastActiveDay + 1 day
  → streakDays += 1; streak bonus applied once.
- Edge case (streak reset): today > lastActiveDay + 1 day →
  streakDays = 1; streak bonus applied (it's a new active day).
- Edge case (streak no-op): today == lastActiveDay →
  streakDays unchanged; streak bonus NOT applied.
- Edge case (level-up fires on PTU): current xp=98, PTU adds 2 →
  xp=100 → level_for_xp(100)=2 → sentinel `LEVEL_UP:2`.
- Edge case (level-up on streak bonus alone): xp=89 + 10 (streak)
  + 2 (PTU) = 101 → sentinel fires.
- Edge case (Lv 50 cap): xp=9_999_999 + any → level stays 50, no
  sentinel emitted.
- Edge case (toolsUsed prune): seed with a tool last-seen 8 days
  ago → filter drops it; same-call tool write lands as only key.
- Edge case (empty toolName, e.g. malformed payload): variety
  map unchanged.
- Edge case (lazy-init): buddy JSON without `.signals` field →
  filter substitutes the skeleton, completes without error,
  emits buddy JSON with signals populated.
- Error path (malformed buddy JSON): jq fails → empty line 1 +
  empty line 2 → caller skips emit. No crash.
- Integration: chain 20 PTU fires at 2 XP/each → final level
  matches `level_for_xp(40 + streak_bonuses)`.

**Verification:**
- `test_signals.bats` green.
- A targeted bats scenario invokes the function 1,000 times and
  confirms `EPOCHREALTIME` median ≤ 10 ms per call (single-jq
  fusion budget).

---

- [x] **Unit 4: Wire buddy-lock + signals into PTU/PTUF/Stop hooks**

**Goal:** Every hook now opens `buddy.json.lock` inside the
session-lock critical section, calls `hook_signals_apply`,
persists via `buddy_save`, and routes level-ups through
`hook_commentary_select "LevelUp"`.

**Requirements:** R5, R6.

**Dependencies:** Units 1, 2, 3.

**Files:**
- Modify: `hooks/post-tool-use.sh`
- Modify: `hooks/post-tool-use-failure.sh`
- Modify: `hooks/stop.sh`
- Modify: `tests/hooks/test_post_tool_use.bats`
- Modify: `tests/hooks/test_post_tool_use_failure.bats`
- Modify: `tests/hooks/test_stop.bats`

**Approach:**
- Inside each hook, after the dedup early-return but before
  `hook_commentary_select`, acquire `buddy.json.lock` via the
  same `exec {fd}>` + `flock -x -w 0.2` idiom the session lock
  uses. Reject symlinked lock file. On timeout: log, release
  session lock, exit 0. Lock ordering per D2 enforced by code
  layout (session already held on entry; buddy acquired next;
  releases reversed at exit).
- Compute event inputs:
  - `today = date -u +%Y-%m-%d`
  - `now = date +%s`
  - For PTU: `toolName = payload.tool_name`,
    `filePath = payload.tool_input.file_path // ""`,
    `filePathMatchedLast = (filePath == session.lastToolFilePath && filePath != "")`.
  - For PTUF: `toolName = payload.tool_name`; no file-path work
    (failures don't bump repeated-edit counter). `filePath`
    input to `hook_signals_apply` left empty.
  - For Stop: compute
    `sessionActiveHours = (now - iso_to_epoch(session.startedAt)) / 3600.0`
    as a float string; passed verbatim into the jq filter.
- Call `hook_signals_apply <event> $buddy $inputs` → split the
  two-line stdout; capture `LEVEL_UP:<n>` sentinel into
  `level_up_level` (empty if none) and updated buddy JSON into
  `buddy_updated`.
- Always update `session.lastToolFilePath` to the current
  `filePath` BEFORE calling `hook_commentary_select` (so the
  session write path is a single mutation set per fire, not
  two interleaved).
- Call `hook_commentary_select "<Event>" $session_after $buddy_updated`
  as today.
- If `level_up_level` non-empty AND `commentary_line` came from
  the event (not Stop's bypass), discard it and call
  `hook_commentary_select "LevelUp" $session_after $buddy_updated`
  to get the level-up line. The LevelUp call bypasses gates
  (D9); it runs against the post-Stop/post-PTU session JSON so
  any bag consumption is recorded.
- Persist under both locks:
  `printf '%s' "$buddy_updated" | buddy_save`
  then `printf '%s' "$final_session" | session_save "$sid"`.
  Release buddy lock; release session lock.
- Emit line last (D11). If either save failed, clear the line
  first.

**Execution note:** The lock-ordering change is the riskiest
seam in the ticket. Consider writing the "inverted order
deadlocks, hook exits 0" bats scenario first (test-first) so the
assertion constrains the implementation.

**Patterns to follow:**
- P3-2 PTU hook flock block — copy-paste the session-lock
  stanza verbatim, then duplicate with `buddy.json.lock` variable
  substitution. Nested, NOT interleaved.
- P3-2 PTU hook two-line stdout capture via
  `"${out%%$'\n'*}"` / `"${out#*$'\n'}"` — use the same idiom
  for the signals helper's return.

**Test scenarios:**
- Happy path (PTU): fires on a live buddy; after the fire,
  `buddy.json.signals.variety.toolsUsed[$tool]` is set;
  `.xp` advanced by 2 (or 12 on first-of-day); session file
  has `lastToolFilePath` updated.
- Happy path (PTUF): `chaos.errors += 1`; `quality.totalEdits += 1`;
  buddy JSON written.
- Happy path (PTU + level-up): xp preset to 98, PTU fires,
  `buddy.json.level` becomes 2, stdout contains the
  `LevelUp`-bank line (not a `PostToolUse`-bank line).
- Happy path (Stop + level-up): xp preset to 95, Stop fires with
  +5 base + 2×2 active-hours = 9 gain → level 2, stdout contains
  LevelUp line instead of Stop line.
- Edge case (repeated edit): two consecutive PTU fires on the
  same `file_path` with `Edit` → `chaos.repeatedEditHits == 1`
  after the second fire (first fire sets `lastToolFilePath`;
  second matches).
- Edge case (tool without file_path): Bash PTU fires set
  `lastToolFilePath == ""`; a subsequent Edit with a real path
  does NOT trigger repeatedEditHits (`filePathMatchedLast`
  false because last was empty).
- Integration (flock ordering): concurrent PTU + PTUF for the
  same session → both writes land, no lost XP, no lost signal
  increments. Extends the P3-1 concurrency harness to cover
  buddy.json.
- Integration (flock inversion): a mock hook that takes buddy
  lock before session lock is run concurrently with a normal
  hook; one times out, logs to `error.log`, exits 0. Neither
  corrupts state. This test asserts the deadlock-prevention
  invariant at runtime.
- Integration (NO_BUDDY): Stop with no buddy → silent, no
  buddy.json.lock created.
- Perf: p95 per hook < 100 ms on `perf_hook_p95.sh`. PTU
  target ≤ 95 ms (budget gained in Unit 2, spent here).

**Verification:**
- All three hook bats suites green.
- Perf harness green at 100-iteration ceiling.
- Flock inversion bats scenario exits 0 with an `error.log`
  entry and no on-disk corruption.

---

- [x] **Unit 5: `LevelUp` commentary event + species line banks + concurrency + boundary tests**

**Goal:** Ship the `LevelUp` event case in `hook_commentary_select`,
write 10+ level-up lines per species, and land the test harness
that proves the two-file concurrency + streak-boundary invariants.

**Requirements:** R5, R7 (voice), ticket exit criterion 2 (streak
boundary).

**Dependencies:** Units 1-4.

**Files:**
- Modify: `scripts/hooks/commentary.sh` — new `LevelUp` case in
  `hook_commentary_select` and a `_commentary_handle_level_up`
  handler that skips all three gates (same shape as current Stop
  handler, minus the `stop_enabled` gate) and selects from
  `species.line_banks.LevelUp.default`.
- Modify: `scripts/species/{axolotl,dragon,owl,ghost,capybara}.json`
  — add `line_banks.LevelUp.default` with 10+ lines each.
- Create: `tests/hooks/test_concurrency.bats` — two-file
  concurrency harness (session + buddy). Covers P3-2 review gap
  and P4-1's new buddy-file write surface.
- Create: `tests/hooks/test_streak_boundary.bats` — UTC day
  boundary tests using `_BUDDY_COMMENTARY_NOW` / a parallel
  `_BUDDY_SIGNALS_NOW` + `_BUDDY_SIGNALS_TODAY` override pair.
- Create: `tests/hooks/test_week_simulation.bats` — simulates
  1 week × 20 tool uses/day (ticket task) and asserts end-state
  level is 5 or 6, all four signal axes show growth.
- Modify: `tests/species/test_species_line_banks.bats` (or the
  P3-2 equivalent) — structural check for LevelUp banks.

**Approach:**
- `LevelUp` handler mirrors the Stop handler (bypass gates, draw
  from bank, bump budget counter — ticket-optional; recommended
  off so level-ups never contribute to the 8-comment budget).
  The `commentsThisSession` increment is omitted here because
  level-up events are rare and should never be silenced by
  budget. Stop's telemetry increment stays in.
- Add `_BUDDY_SIGNALS_NOW` and `_BUDDY_SIGNALS_TODAY` env-var
  overrides in `signals.sh` (mirrors `_BUDDY_COMMENTARY_NOW` +
  `_BUDDY_COMMENTARY_TEST_MODE` pattern from commentary.sh).
  These are the test seams for Unit 5's boundary and simulation
  tests.
- `test_concurrency.bats` runs N backgrounded hook invocations
  against the same session + buddy pair, `wait`s, and asserts:
  - total XP == N × (expected per-event gain)
  - all tool_use_ids unique
  - all signal counters monotonic and sum to expected totals
  - the P3-1 adversarial pattern (PTU + PTUF same tool_use_id)
    still dedups and bumps nothing twice.
- `test_streak_boundary.bats` fires the signals helper at
  `today = 2026-04-21, lastActiveDay = 2026-04-20` → streakDays
  +1; then at `today = 2026-04-23, lastActiveDay = 2026-04-21`
  → reset to 1; then at `today = 2026-04-21` from init sentinel
  → reset to 1. Also exercises a fire at `23:59:59Z` followed by
  `00:00:05Z` the next day.
- `test_week_simulation.bats` runs 140 fires (7 days × 20) with
  mocked clock; asserts final `buddy.json.level ∈ {5, 6}`,
  `streakDays == 7`, `variety.toolsUsed` has the 3-4 tools the
  sim uses, `chaos.repeatedEditHits > 0` (sim includes repeats),
  `quality.successfulEdits > 100`.

**Patterns to follow:**
- P3-2 `test_commentary.bats` env-var clock injection.
- P3-1 concurrency harness sketch (embedded in the flock
  solutions doc §Examples, "Adversarial test scenario").
- P3-2 species content voice-review — same voice cues per
  species, level-up lines should feel celebratory for axolotl,
  gleeful for dragon, pedantic-pleased for owl, quietly-proud
  for ghost, chill-smug for capybara.

**Test scenarios:**
- Structural: each species has `LevelUp.default | length >= 10`
  and no duplicates within a bank.
- Structural: no line contains `\t` or control bytes (mirrors
  P3-2 discipline).
- Happy path (commentary): a forced `LevelUp` event-type call
  emits a line from the bank; budget counter NOT incremented;
  commentary cooldown NOT bumped; shuffle-bag consumed.
- Happy path (hook): see Unit 4 level-up tests.
- Concurrency (session + buddy): 20 backgrounded PTU fires with
  distinct `tool_use_id` on the same session → final XP = 40,
  all increments accounted for, no lost writes on either file.
- Concurrency (PTU + PTUF dual-fire same id): dedup holds;
  signals bumped exactly once; no double level-up.
- Streak boundary: cases enumerated in Approach above —
  continuation, one-day-gap reset, multi-day-gap reset, same-day
  no-op, midnight-UTC crossing.
- Integration (week simulation): final level ∈ {5, 6}; four
  axes all non-zero; `quality.successfulEdits / totalEdits` in
  a plausible range (~0.85-0.95 given sim error rate).

**Verification:**
- All three new bats files green.
- Species structural tests green.
- Manual voice-review pass for level-up banks recorded in ticket
  Notes before this unit merges.

---

- [x] **Unit 6: Live-session smoke + perf re-baseline + notes**

**Goal:** Empirically confirm `tool_input.file_path` shape, confirm
level-up lines surface in the transcript, re-record perf baselines,
update the roadmap ticket.

**Requirements:** Ticket exit criterion 3 (perf).

**Dependencies:** Units 1-5.

**Files:**
- No code changes expected. Hotfix allowed if the smoke uncovers
  a payload-shape mismatch or transcript-formatting issue.
- Modify: `docs/roadmap/P4-1-xp-signals.md` — status `done`,
  Notes section updated.
- Possibly create: `docs/solutions/<category>/<topic>-2026-04-21.md`
  — only if a genuinely new learning emerges (e.g., quirk in
  nested-lock behaviour on macOS, unexpected jq cost curve for
  the fused signals filter).

**Approach:**
- Follow the §B smoke recipe from the hooks-schema solutions
  doc. Hatch a buddy in a scratch workspace, run a prompt that
  exercises Edit + Bash tools, grep the transcript.
- Confirm `tool_input.file_path` arrives for Edit/Write and
  NOT for Bash — if the shape differs from the design-doc
  assumption in D8, file a hotfix under this unit before closing.
- Force a level-up by pre-seeding `buddy.json.xp` close to
  threshold, running Edits until the PTU threshold crosses.
  Confirm the level-up line appears in the transcript.
- Re-run `tests/hooks/perf_hook_p95.sh` with 100 iterations.
  Record numbers alongside the pre-P4-1 baseline (PTU: 85 ms,
  Stop: 67 ms) and the post-Unit-2 intermediate baseline.
  Target: PTU ≤ 95 ms, Stop ≤ 85 ms (all under 100 ms ceiling).

**Test scenarios:**
- Not bats. Manual smoke, result pasted into ticket Notes along
  with the perf numbers and the voice-review checkpoint result.

**Verification:**
- Transcript visibly contains a level-up line on the forced-level
  run.
- `tool_input.file_path` shape verified against the real Claude
  Code binary.
- Perf harness green; numbers logged.
- Ticket flipped to `done`.

## System-Wide Impact

- **Interaction graph:** Hooks now write BOTH `session-<id>.json`
  AND `buddy.json` inside one entry. New in-memory call chain:
  `hook_signals_apply` + `hook_commentary_select` + (optional)
  `hook_commentary_select "LevelUp"`. No new hook events; no new
  state files; no new entry points.
- **Error propagation:** Every failure path early-exits 0.
  `hook_signals_apply` returns empty line 1 + empty line 2 on
  internal jq failure → caller uses pre-call buddy JSON. A save
  failure on either file clears the captured commentary line
  before emit so the user never sees a level-up the state did not
  record.
- **State lifecycle risks:**
  - `buddy.json` is the first shared-across-sessions file that
    hooks now write. The `buddy.json.lock` TTL is already covered
    by `state_cleanup_orphans`'s existing sweep for buddy-adjacent
    files; no TTL split needed. Re-verify in Unit 5.
  - `variety.toolsUsed` has bounded size (≤ tool roster count)
    because entries are keyed by tool name, not timestamp. No
    unbounded growth even with high activity.
  - `chaos.repeatedEditHits` has no bound per session; this is
    intentional — P4-2 will threshold on the accumulated value.
  - `session.lastToolFilePath` grows to whatever the longest
    file path is per session; bounded to session lifetime; no
    new TTL concern.
- **API surface parity:** `/buddy:stats` output is unchanged in
  layout; the XP-over-threshold line now shows the real
  `xpForLevel(level)`. No flag changes, no manifest changes.
- **Integration coverage:** Two-file concurrency (session +
  buddy) is the class of scenario unit tests alone cannot prove
  — covered in `test_concurrency.bats` (Unit 5) with backgrounded
  shell fires. Streak boundary is a real-clock concern — covered
  by `test_streak_boundary.bats` with injected time.
- **Unchanged invariants:** P3-2 commentary gates, shuffle-bag
  behaviour, dedup-ring behaviour, and all non-`LevelUp` event
  paths are unchanged. `session_save` / `buddy_save` / `buddy_load`
  semantics unchanged. Hooks still exit 0 on internal failure.
  `schemaVersion` remains at 1.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Nested flock acquisition inverts ordering somewhere in review, causing deadlock under real concurrency. | D2 is explicit. Every acquisition site gets an in-line comment restating the order. Unit 4 includes a runtime test that inverts the order and asserts the flock timeout fires cleanly. The P3-2 adversarial-review persona is flagged explicitly in the /ce:review pass. |
| Performance regression pushes PTU p95 past 100 ms despite Unit 2 fusion. | Unit 2 buys ≥ 10 ms before Unit 4 spends. Unit 6 re-baselines. If the measured p95 > 95 ms after Unit 4, treat as a blocker; additional fusion on `hook_signals_apply` (inline the `level_for_xp` loop more tightly, or batch the signals-apply and commentary calls) is the next lever. Do not ship past budget. |
| `tool_input.file_path` shape differs from design-doc assumption — repeatedEditHits stays zero. | Unit 6 smoke is the gate. Pre-smoke, add a one-time debug log in PTU that captures the real tool_input shape; remove before closing. The hooks-schema solutions doc explicitly warns that design-doc assumptions are not authoritative. |
| Streak reset logic wrong on DST or timezone-skewed hosts → user sees streak collapse on a day they did work. | UTC-only (D7) sidesteps local-time ambiguity. `test_streak_boundary.bats` exercises the midnight-UTC crossing. Document the UTC choice in the ticket Notes so a future user report ("my streak broke at 7 pm PDT") is easy to diagnose. |
| Level-up commentary collides with a same-fire Stop goodbye — user sees two lines or the wrong one. | D10 is explicit: level-up line takes priority and the Stop line is suppressed this fire. Unit 4 test `Stop + level-up` asserts the LevelUp bank fired, not the Stop bank. |
| Concurrency harness in Unit 5 becomes flaky on CI (backgrounded shells race non-deterministically). | Harness uses `wait` on all PIDs before asserting; assertions are on final state invariants (monotone sum), not ordering. If CI still flakes, reduce N from 20 to 10 and document. The test is sanity, not a perf benchmark. |
| Fusion refactor in Unit 2 silently breaks a P3-2 behavioural edge case (e.g., the jq `// default` reads interacting with the new `--argjson` inputs). | Unit 2 is a refactor-with-same-tests discipline. P3-2 bats suite runs unchanged after Unit 2 lands. Any behavioural change is a bug. Perf numbers alone are not sufficient evidence the refactor is safe. |

## Documentation / Operational Notes

- README update deferred to P8 (surface the signals block and the
  XP curve once P4-2 also lands and the evolution loop is visible
  end-to-end). P4-1 alone doesn't change user-facing docs.
- No migration step for existing users — additive buddy-file
  shape, lazy-init via `// default`.
- The "streak is UTC" choice should be captured in README at P8
  so user reports are cheap to triage.

## Sources & References

- **Ticket:** [docs/roadmap/P4-1-xp-signals.md](../roadmap/P4-1-xp-signals.md)
- **Umbrella plan:** [docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md](./2026-04-16-001-feat-claude-buddy-plugin-plan.md) — §P4.1, D1, D2
- **Brainstorm:** [docs/brainstorms/2026-04-16-claude-buddy-plugin-requirements.md](../brainstorms/2026-04-16-claude-buddy-plugin-requirements.md) — R5, R6
- **Prior plan:** [docs/plans/2026-04-20-003-feat-p3-2-commentary-engine-plan.md](./2026-04-20-003-feat-p3-2-commentary-engine-plan.md) — house-style reference + Stop/commentary code that Unit 2 refactors and Unit 4 extends
- **Solutions:**
  - [bash-state-library-concurrent-load-modify-save-2026-04-20.md](../solutions/best-practices/bash-state-library-concurrent-load-modify-save-2026-04-20.md)
  - [bash-jq-fork-collapse-hot-path-2026-04-21.md](../solutions/best-practices/bash-jq-fork-collapse-hot-path-2026-04-21.md)
  - [bash-subshell-value-plus-json-return-2026-04-21.md](../solutions/best-practices/bash-subshell-value-plus-json-return-2026-04-21.md)
  - [claude-code-plugin-hooks-json-schema-2026-04-20.md](../solutions/developer-experience/claude-code-plugin-hooks-json-schema-2026-04-20.md)
