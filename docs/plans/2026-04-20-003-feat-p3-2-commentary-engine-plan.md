---
title: P3-2 — Commentary engine (canned v1)
type: feat
status: complete
date: 2026-04-20
origin: docs/roadmap/P3-2-commentary-engine.md
---

# P3-2 — Commentary engine (canned v1)

## Overview

P3-1 plumbed hooks: `PostToolUse`, `PostToolUseFailure`, and `Stop` all
fire, write session state under a per-session flock, and dedup on
`tool_use_id`. But they emit nothing. P3-2 makes them *speak* —
species-voiced canned lines selected via shuffle-bag, gated by a
three-layer rate-limit stack (event-novelty → exponential backoff →
per-session budget), all under the flock the P3-1 review hardened.

LLM-generated commentary is deferred to P6. This ticket ships the
engine and the content.

## Problem Frame

Buddies that say nothing are wallpaper. The commentary loop is what
makes the plugin feel alive. But wrong-dialled commentary gets
disabled fast ("Clippy problem") — so the rate-limit stack is the
real feature here, not the content pipeline. Every line we emit has
to earn its spot. See [brainstorm R4](../brainstorms/2026-04-16-claude-buddy-plugin-requirements.md)
and [§D3 of the umbrella plan](2026-04-16-001-feat-claude-buddy-plugin-plan.md).

## Requirements Trace

- **R4** — buddy chimes in via hooks with in-character, rate-limited lines.
- **R7** — each species has a distinct, consistent voice; line banks are the v1 voice surface.
- **Ticket exit criteria** — ≤ 8 comments/session default, burst of 100 tool uses in 60s yields ≤ 3 comments.

## Scope Boundaries

- No LLM generation (P6).
- No XP or signal accumulation (P4-1).
- No new hook events beyond the four already wired in P3-1.
- No commentary in `NO_BUDDY` or `CORRUPT` state (already enforced by P3-1 sentinel checks).
- Status-line speech-bubble segment stays P2's static placeholder; no hook→statusline handoff in this ticket.

### Deferred to Separate Tasks

- Contextual commentary (LLM) — P6.
- First-evolution and shiny-hatch budget-bypass milestones — P4-2 and P7 own those events.

## Context & Research

### Relevant Code and Patterns

- `hooks/post-tool-use.sh`, `hooks/post-tool-use-failure.sh` — already hold the per-session flock across a load-modify-save cycle. Cooldown and budget writes MUST land in the same critical section as the dedup-ring update.
- `hooks/stop.sh` — currently a bare `exit 0`. P3-2 reinstates the body.
- `hooks/session-start.sh` — authoritative for session-file shape; `hook_initial_session_json` will need two new fields (`commentsThisSession`, `commentary`).
- `scripts/hooks/common.sh` — hook-layer helpers live here. New helpers (`hook_commentary_select`, `hook_emit_line`) extend this rather than spawning a new lib file.
- `scripts/lib/state.sh` — unchanged. `session_load`/`session_save` round-trip the fields transparently because they treat the JSON as opaque.
- `scripts/species/*.json` — five species stubs today with `line_banks: {}`. Content commitment lands here.
- `.claude-plugin/plugin.json` — gets one `userConfig` block.

### Institutional Learnings

- [bash-state-library-concurrent-load-modify-save-2026-04-20](../solutions/best-practices/bash-state-library-concurrent-load-modify-save-2026-04-20.md) — the flock discipline. Cooldown/budget updates are the exact scenario the doc warns about: new fields per event type on a shared load-modify-save path.
- [claude-code-plugin-hooks-json-schema-2026-04-20](../solutions/developer-experience/claude-code-plugin-hooks-json-schema-2026-04-20.md) — live-session smoke recipe. Re-run it in P3-2 to confirm commentary stdout actually surfaces in the transcript.
- [bash-jq-tsv-null-field-collapse-2026-04-20](../solutions/best-practices/bash-jq-tsv-null-field-collapse-2026-04-20.md) — relevant if we pack multi-return from jq via TSV.
- [bash-lcg-hotpath-patterns-2026-04-19](../solutions/best-practices/bash-lcg-hotpath-patterns-2026-04-19.md) — shuffle uses the existing RNG surface.

### External References

- Not needed. Local patterns + P3-1 precedent cover the engineering surface. Content authoring is an internal voice-review exercise.

## Key Technical Decisions

**D1. `commentary.sh` is a hook-layer module, not a lib-layer library.**
Lives at `scripts/hooks/commentary.sh` and is sourced by the three
relevant hooks. Extends `common.sh` conceptually (both are hook-only,
both depend on state.sh). Matches the kickoff directive: "Add new
helpers here rather than creating new lib files." `scripts/lib/` stays
for non-hook-aware primitives.

**D2. Rate-limit state lives inside the existing flock critical section.**
All three rate-limit checks read from and write to
`session-<id>.json`. Hooks already hold the per-session flock across
the dedup-ring update; the commentary decision runs inside that same
lock. Non-negotiable per the adversarial-review finding from P3-1 —
two concurrent writers that each pass the novelty gate on stale state
would each emit, silently blowing the budget. This is the exact
landmine the flock-discipline solutions doc documents.

**D3. Shuffle-bag as a session-scoped remaining-indexes array.**
`commentary.bags.<EventType>` is an array of integer indexes into the
species' line bank for that event type. Selection: if empty, refill
with `shuffled(0..len-1)` and pop head; else pop head. Bounded (max 50
ints per event type × ~5 milestone buckets = ~300 bytes per session).
Resets per session, which is a feature: users get fresh banter each
session, not the same one-third of the bag because the cursor carried
over.

Rejected the stateless "seed + cursor" design because deriving a
deterministic permutation from a seed in pure bash requires
Fisher-Yates anyway; there's no simplicity win and the state size is
trivial.

**D4. Cooldown shape: `{ fires: N, nextAllowedAt: <epoch-secs> }` per event type.**
Epoch seconds (`date +%s`) dodges ISO-parse overhead in jq — lets us
use a plain `<` comparison. `fires` counts gate-passes; maps to the
D3 cadence (fires=0 → immediate, fires=1 → +5min, fires≥2 → +15min).
Cleared to empty object by SessionStart (already authoritative).

**D5. Event-novelty gate keyed on last-observed (not last-emitted).**
Brainstorm R4 phrasing: "you did another Edit... and another" — the
user-visible failure mode is *consecutive same-type observations*,
whether or not the first was suppressed by cooldown or budget.
`session.lastEventType` is updated on every observed event,
regardless of emit outcome. This is the "silent but meaningful" class
of check: the user already knows they did two edits in a row, so
commenting on the second is redundant even if we skipped the first.

**D6. Budget counter `commentsThisSession: int`, incremented on every emit, checked before emit.**
Default cap read from `userConfig.commentsPerSession` (default 8). The
Stop-hook goodbye is the one exception and bypasses the cap (see D7).

**D7. `stop.sh` goodbye bypasses all three rate limits.**
It fires exactly once per session, so the budget concern doesn't
apply. Novelty gate is irrelevant (a final line landing the session
is never "another Stop... and another"). Cooldown is moot for the
same reason. Still held under the same flock to keep the shape
consistent, and still increments `commentsThisSession` for telemetry
accounting. Long-session (>1h since `startedAt`) selects from
`Stop.long_session` rather than `Stop.default`.

**D8. Milestone banks are bank-selection overrides, not rate-limit bypasses.**
- `PostToolUse.first_edit` — triggered when `commentsThisSession == 0` AND event is the first PostToolUse observed this session. Still gated by budget (trivially passes at count 0) and cooldown (trivially passes at fires 0). Counts against budget.
- `PostToolUseFailure.error_burst` — triggered when 3+ failures observed within the trailing 5 min. Tracked in `session.recentFailures: [epoch, epoch, ...]` (trimmed to entries within 5min window before check). Still budget/cooldown-gated.
- `Stop.long_session` — as in D7.

Milestones that bypass budget (first evolution, shiny hatch) belong
to P4-2 and P7; explicitly out of scope.

**D9. Commentary emission format: `<emoji> <name>: "<line>"`, plain stdout.**
Single line, newline-terminated, printed at the very end of the hook.
No ANSI (Claude Code renders the transcript and may strip/mangle
codes). Shape re-validated via the live-session smoke recipe before
the ticket closes — design-doc assumptions are not authoritative.

**D10. `hook_commentary_select` returns via stdout-JSON + out-param convention.**
Bash has no multi-return. The function takes `(event_type, session_json)`,
emits the updated session JSON on stdout, and sets a global
`_BUDDY_COMMENT_LINE` to the line to emit (or empty for no-emit).
Callers:

```bash
updated_json="$(hook_commentary_select "$event_type" "$session_json")"
# ...write updated_json back under flock...
[[ -n "${_BUDDY_COMMENT_LINE:-}" ]] && printf '%s\n' "$_BUDDY_COMMENT_LINE"
```

The line is emitted *after* the flock release, after `session_save`
has committed, so a crash mid-emit can't desync session state from
what the user saw.

## Open Questions

### Resolved During Planning

- **How do hooks emit commentary to the transcript?** Plain stdout + exit 0 per the hooks docs. Re-validated at implementation time via the live-smoke recipe (Unit 6). If the smoke shows the transcript strips or reformats, the format in D9 is the only knob to turn — logic is unaffected.
- **Where does shuffle-bag state live?** Session JSON, bounded array per event type (D3).
- **Budget tracking?** Counter in session JSON, incremented under flock (D6).
- **How does stop.sh clean up?** D7 — goodbye bypasses rate limits, state flows naturally out with session-file TTL sweep from P3-1.
- **Re-validate `hooks.json`?** No schema changes in this ticket — existing file already validated in P3-1 live smoke. Unit 6 re-runs the smoke purely to confirm stdout commentary surfaces, not to re-check schema.

### Deferred to Implementation

- Exact jq filter layout for `hook_commentary_select` — the decision-tree shape is known but the bash/jq factoring is an implementation micro-decision.
- Per-line content for the 5 species × 3 event types + milestone banks (Unit 4). Voice-review is a checkpoint before Unit 5 wires the selection.

## High-Level Technical Design

> *Directional guidance, not implementation specification.*

```
                hooks/post-tool-use.sh (same for failure, stop)
                         │
                         ▼
              [acquire per-session flock]
                         │
                         ▼
                   session_load ──► session_json (in memory)
                         │
                         ▼
             hook_ring_update  ──► dedup? exit
                         │
                         ▼
             hook_commentary_select(event_type, session_json)
                         │
                    ┌────┴────────────────────────┐
                    │  1. update lastEventType    │
                    │  2. novelty gate            │
                    │  3. cooldown gate           │
                    │  4. budget gate             │
                    │  5. pick bank (milestone?)  │
                    │  6. shuffle-bag draw        │
                    │  7. format line             │
                    │  8. bump cooldown + budget  │
                    │  9. set _BUDDY_COMMENT_LINE │
                    └────┬────────────────────────┘
                         │
                         ▼
                   session_save (persist everything, atomic)
                         │
                         ▼
              [release flock]
                         │
                         ▼
              printf "$_BUDDY_COMMENT_LINE"   (only here, post-lock)
                         │
                         ▼
                      exit 0
```

Session JSON shape after P3-2:

```json
{
  "schemaVersion": 1,
  "sessionId": "...",
  "startedAt": "2026-04-20T12:00:00Z",
  "recentToolCallIds": ["..."],
  "lastEventType": "PostToolUse",
  "commentsThisSession": 2,
  "cooldowns": {
    "PostToolUse":        { "fires": 1, "nextAllowedAt": 1745141234 },
    "PostToolUseFailure": { "fires": 0, "nextAllowedAt": 0 }
  },
  "recentFailures": [1745141100, 1745141150, 1745141200],
  "commentary": {
    "bags": {
      "PostToolUse":        [17, 3, 42, 8, ...],
      "PostToolUseFailure": [5, 11, ...],
      "Stop":               [...]
    },
    "firstEditFired": false
  }
}
```

## Implementation Units

- [x] **Unit 1: `userConfig` + plugin manifest**

**Goal:** Surface `commentsPerSession` (default 8) as a user knob.

**Requirements:** R4.

**Dependencies:** None.

**Files:**
- Modify: `.claude-plugin/plugin.json`

**Approach:**
- Add `userConfig.commentsPerSession` as an integer with default 8.
- Also add `commentary.stopLineOnExit` boolean default `true` — escape hatch for users who don't want a goodbye line. (D7 bypass is only meaningful if users can turn it off entirely.)
- Manifest schema is not validated by plugin load if an unknown key is added — stays forward-compatible with later knobs.

**Test scenarios:**
- Happy path: `jq '.userConfig.commentsPerSession.default' .claude-plugin/plugin.json` returns `8`.
- Edge case: `/reload-plugins` loads without error. (Smoke — manual.)

**Verification:**
- Manifest parses, live smoke loads the plugin, no new warnings in `--debug-to-stderr`.

---

- [x] **Unit 2: Session-file shape extension**

**Goal:** Add commentary/cooldown fields to the canonical initial shape, wired through `hook_initial_session_json`.

**Requirements:** R4.

**Dependencies:** None.

**Files:**
- Modify: `scripts/hooks/common.sh` — `hook_initial_session_json`
- Modify: `tests/hooks/test_common.bats`
- Modify: `tests/hooks/test_session_start.bats`

**Approach:**
- Extend the canonical shape emitted by `hook_initial_session_json` to include `lastEventType: null`, `commentsThisSession: 0`, `recentFailures: []`, `commentary: { bags: {}, firstEditFired: false }`.
- `cooldowns` already exists as `{}` — no shape change; keys are added lazily per event type.
- Keep `schemaVersion: 1` — the field additions are additive; session-file readers (jq filters) already tolerate missing fields with `// default` where it matters. Confirm `session_load` treats the new shape transparently.

**Test scenarios:**
- Happy path: `hook_initial_session_json "sess-abc"` emits JSON containing all new keys.
- Integration: session-start hook writes a file with all new keys present.
- Edge case: an older session file (no new keys) round-trips through `session_load` → commentary decision → `session_save` without crashing. (Resilience: a user mid-session when the plugin updates.)

**Verification:**
- All test_common.bats and test_session_start.bats cases pass.

---

- [x] **Unit 3: `scripts/hooks/commentary.sh` — rate-limit + selection logic**

**Goal:** Ship the pure decision/selection logic, no hook wiring yet.

**Requirements:** R4, R7.

**Dependencies:** Unit 2 (shape).

**Files:**
- Create: `scripts/hooks/commentary.sh`
- Create: `tests/hooks/test_commentary.bats`

**Approach:**
- Source-guard like `common.sh`.
- Exports: `hook_commentary_select <event_type> <session_json>`.
  - Reads species JSON via `$CLAUDE_PLUGIN_ROOT` + active species pulled from `buddy_load`. (Species selection: jq `.buddy.species` on the buddy JSON passed in as a second arg, OR re-load inside — prefer pass-in to keep the hook's one-load discipline.)
  - Signature update: `hook_commentary_select <event_type> <session_json> <buddy_json>`.
  - Emits updated session JSON on stdout. Sets `_BUDDY_COMMENT_LINE` global.
- Internal helpers (private, underscore-prefixed):
  - `_commentary_select_bank` — resolve milestone bank name or `.default`.
  - `_commentary_shuffle_draw` — pop head of bag; refill+shuffle when empty. Shuffle uses `$RANDOM` sequence (state.sh already depends on bash 4.1+).
  - `_commentary_check_cooldown` — returns 0 (emit) or 1 (skip).
  - `_commentary_check_budget` — returns 0 or 1.
  - `_commentary_check_novelty` — returns 0 or 1. Always updates `lastEventType` regardless of outcome.
  - `_commentary_bump_cooldown` — computes next cadence from `fires`.
- Stop-hook bypass: `event_type="Stop"` skips novelty + cooldown + budget gates but still runs bank selection (long_session override) + bag draw + line format + `commentsThisSession++`.

**Patterns to follow:**
- `hook_ring_update` in `common.sh` — single-jq invocation returning updated JSON or a sentinel.
- `exec 2>/dev/null` discipline at source time; no stderr surfaced.

**Test scenarios:**
- Happy path: fresh session, first PostToolUse → emits first_edit bank line; cooldowns/budget advance.
- Edge case (novelty gate): two consecutive PostToolUse events → second is silenced; `lastEventType` updated both times.
- Edge case (backoff): three PostToolUse events spaced 10s apart with novelty alternating (e.g., interleaved with Stop fakes) → fire 1 immediate, fire 2 blocked if <5min from fire 1, fire 3 blocked if <15min from fire 2.
- Edge case (budget): after 8 emits, 9th returns empty `_BUDDY_COMMENT_LINE` (unless event_type=Stop).
- Edge case (error burst): 3 failures within 5min → `error_burst` bank selected.
- Edge case (long session): `startedAt` 70 min ago + Stop event → `long_session` bank selected.
- Edge case (shuffle refill): 51 emissions over a 50-line bank → no repeats within any consecutive 50.
- Edge case (empty bank): species with `line_banks.<EventType>.default: []` → no emit, hook does not crash. Error path, not happy path.
- Integration: calling `hook_commentary_select` mutates the JSON idempotently (running twice with the same inputs yields identical decisions on a stable clock — note: `date +%s` resolution means the second call can legitimately differ; tests freeze time via an override env var).
- Error path: malformed `line_banks` (wrong type) → no emit, no crash, log via `hook_log_error`.
- Time mocking: `_commentary_now_epoch` indirection allows bats to inject `_BUDDY_COMMENTARY_NOW=<epoch>` for deterministic cooldown tests.

**Verification:**
- bats suite covers all scenarios above; green.

---

- [x] **Unit 4: Line-bank content for 5 species × 3 event types + milestone banks**

**Goal:** 50+ lines per species per major event (`PostToolUse`, `PostToolUseFailure`, `Stop`), plus shared milestone banks where it makes the voice richer.

**Requirements:** R7.

**Dependencies:** None — this is a content unit, runs in parallel with Unit 3.

**Files:**
- Modify: `scripts/species/axolotl.json`
- Modify: `scripts/species/dragon.json`
- Modify: `scripts/species/owl.json`
- Modify: `scripts/species/ghost.json`
- Modify: `scripts/species/capybara.json`

**Approach:**
- Each species fills `line_banks`:
  ```
  {
    "PostToolUse":        { "default": [50+ lines], "first_edit": [10+ lines] },
    "PostToolUseFailure": { "default": [50+ lines], "error_burst": [10+ lines] },
    "Stop":               { "default": [50+ lines], "long_session": [10+ lines] }
  }
  ```
- Voice cues per species (locked here to avoid drift during authoring):
  - Axolotl — wholesome-cheerleader, gentle, slightly kawaii.
  - Dragon — chaotic-gremlin, gleeful, fire-adjacent metaphors.
  - Owl — dry-scholar, pedantic, Latin-adjacent.
  - Ghost — deadpan-night, understated, present-but-drifting.
  - Capybara — chill-zen, unbothered, nature metaphors.
- Voice-review checkpoint: before Unit 5, read each species' full bank end-to-end. Target: a reader picking 5 random lines per species can identify the archetype 5/5 times. If any species fails, rewrite before wiring.

**Test scenarios:**
- Structural: each species JSON parses; `line_banks.PostToolUse.default | length >= 50` for all 5 species; same for PostToolUseFailure.default, Stop.default.
- Structural: milestone banks are non-empty if present.
- Structural: no duplicate lines within a single bank (jq `length == unique | length`).

**Test expectation:** include a `test_species_line_banks.bats` (or extend `tests/rng.bats`) to assert structure — not voice. Voice stays a manual review gate.

**Verification:**
- bats structural tests green; voice-review manual pass recorded in the ticket notes before Unit 5 merges.

---

- [x] **Unit 5: Wire commentary into the three hook scripts**

**Goal:** Every hook emits (or silently skips) a line per the decision in Unit 3.

**Requirements:** R4.

**Dependencies:** Units 2, 3, 4.

**Files:**
- Modify: `hooks/post-tool-use.sh`
- Modify: `hooks/post-tool-use-failure.sh`
- Modify: `hooks/stop.sh`
- Modify: `tests/hooks/test_post_tool_use.bats`
- Modify: `tests/hooks/test_post_tool_use_failure.bats`
- Modify: `tests/hooks/test_stop.bats`

**Approach:**
- Source `scripts/hooks/commentary.sh` alongside `common.sh`.
- Inside each hook's existing flock critical section, after `hook_ring_update` returns a non-DEDUP updated JSON:
  1. Call `hook_commentary_select <event> <updated_json> <buddy_json>`.
  2. Capture new updated JSON on stdout; `_BUDDY_COMMENT_LINE` on global.
  3. `session_save` the final JSON (once per critical section — don't save twice).
  4. Release flock.
  5. If `_BUDDY_COMMENT_LINE` non-empty, `printf '%s\n'`.
- Stop hook body (currently `exit 0`): full load-modify-save under flock, calls `hook_commentary_select` with `event_type=Stop`, commits updated session JSON. Sanity-check: Stop also needs `buddy_load` guard for NO_BUDDY/CORRUPT, mirroring the other hooks.
- Preserve the p95 < 100ms contract — budget for `hook_commentary_select` is ~30-40ms. Unit 3 tests assert bounds via the existing `tests/hooks/perf_hook_p95.sh` harness, extended to cover stop.sh.

**Test scenarios:**
- Happy path (PostToolUse): first call in a NO_BUDDY→ACTIVE session emits a first_edit line; subsequent same-type call suppressed by novelty.
- Happy path (PostToolUseFailure): first error emits; third error within 5min emits from error_burst bank.
- Happy path (Stop): always emits, bypasses all gates; long_session bank fires when startedAt > 1h ago.
- Integration (flock): concurrent PostToolUse + PostToolUseFailure for the same session — both writes land, budget reflects both increments, no lost update. Re-uses the P3-1 concurrency test harness from the solutions doc.
- Integration (burst): 100 PostToolUse events in 60s simulated via backgrounded hook invocations → ≤ 3 comments emitted (counted via captured stdout).
- Edge case (budget exhaustion): 8 passing emissions, 9th same type within same session → no stdout line, session.commentsThisSession == 8.
- Edge case (Stop bypass): budget at 8, Stop fires → stdout non-empty, commentsThisSession == 9.
- Edge case (NO_BUDDY stop): Stop with no buddy → silent, no session file write.
- Perf: p95 of each hook < 100ms, including commentary.

**Verification:**
- All three hook bats suites green; perf harness green; burst integration test passes (≤ 3 comments in 60s).

---

- [x] **Unit 6: Live-session smoke — confirm commentary surfaces in transcript**

**Goal:** Verify empirically that the stdout commentary actually lands in the Claude Code transcript as a user-visible line.

**Requirements:** R4 (functional-in-production).

**Dependencies:** Units 1-5.

**Files:**
- No file changes. If the smoke uncovers a format issue, Unit 5 hotfix.
- Document the smoke result in the ticket's Notes section.

**Approach:**
- Follow `docs/solutions/developer-experience/claude-code-plugin-hooks-json-schema-2026-04-20.md` §B recipe.
- Hatch a buddy in a scratch workspace, run a prompt that exercises Bash + Edit tools, grep transcript output for the `<emoji> <name>:` prefix.
- Confirm goodbye line on session stop.
- Capture the transcript snippet and attach to the ticket's Notes.

**Test scenarios:**
- Not bats. Manual smoke, result pasted into ticket Notes.

**Verification:**
- Transcript visibly contains commentary lines from at least one PostToolUse and one Stop event.

---

- [x] **Unit 7: Solutions / Notes pass**

**Goal:** Update roadmap ticket Notes; write a solutions doc only if something surprises.

**Requirements:** Process.

**Dependencies:** Units 1-6.

**Files:**
- Modify: `docs/roadmap/P3-2-commentary-engine.md` — status `done`, Notes section.
- Possibly create: `docs/solutions/<category>/<narrow-topic>-2026-04-20.md` — only if a new learning emerged that isn't already covered by the two P3-1 solutions docs.

**Approach:**
- Default assumption: no new solutions doc needed — P3-1 already documented the flock discipline and the hooks.json smoke. A P3-2 learning qualifies only if it's narrower (e.g., Claude Code trimming whitespace from hook stdout, or jq nesting quirks in shuffle-bag refill).
- Ticket Notes: record the voice-review outcome, the smoke transcript, any perf adjustments.

## System-Wide Impact

- **Interaction graph:** Hooks → `hook_commentary_select` → session JSON (in-flock) → post-lock stdout emit. No new hooks, no new state files.
- **Error propagation:** Every failure path early-exits 0 with `hook_log_error`. A broken species JSON produces silence, not a session-breaking error.
- **State lifecycle risks:** Shuffle-bag state is session-scoped, cleaned by P3-1's 24h session-file TTL sweep. Budget counter and cooldowns likewise.
- **API surface parity:** `userConfig.commentsPerSession` is new, additive; no breaking change. Session-file shape is additive with defaulted missing-field reads.
- **Integration coverage:** The two flock-contention scenarios from the solutions doc (dual-fire on same tool call, concurrent PostToolUse + PostToolUseFailure) both extend naturally — budget and cooldown increments must not be lost.
- **Unchanged invariants:** Hooks still exit 0 on internal failure. `session_load`/`session_save` semantics unchanged. Dedup ring behavior unchanged. P2 status line untouched.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Commentary format gets stripped or reformatted by Claude Code transcript rendering | Unit 6 live smoke is the gate — fails the ticket if commentary doesn't surface legibly. |
| Shuffle-bag jq filter too slow under p95 budget | Bags are small (≤50 ints). Single-jq invocation pattern from `hook_ring_update`. Unit 5 perf test catches regressions. |
| Voice inconsistency within a species across 50+ lines | Voice-review checkpoint in Unit 4 before wiring. Author one species end-to-end, voice-check, then fan out — mistakes compound otherwise. |
| Stop hook body re-introduces the P3-1 class of bugs (flock gap) | Copy-paste discipline: Stop hook flock block mirrors post-tool-use.sh verbatim where structurally possible. Review checklist item. |
| LLM-generated false sense of bank quality (placeholder slop) | Don't ship placeholder lines. Voice-review rejects "smells like Claude wrote it" lines. Hard bar: each line should plausibly have come from a human writer pretending to be the species. |

## Documentation / Operational Notes

- README gets a snippet showing `commentsPerSession` in `userConfig` once the manifest lands — deferred to P8 unless it materially confuses installers.
- No migration step for existing users — additive session-file shape, default-read tolerant.

## Sources & References

- **Ticket:** [docs/roadmap/P3-2-commentary-engine.md](../roadmap/P3-2-commentary-engine.md)
- **Umbrella plan:** [docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md](./2026-04-16-001-feat-claude-buddy-plugin-plan.md) — §P3.2, §Interaction Graph, §D3
- **Brainstorm:** [docs/brainstorms/2026-04-16-claude-buddy-plugin-requirements.md](../brainstorms/2026-04-16-claude-buddy-plugin-requirements.md) — R4, R7
- **Prior plan:** [docs/plans/2026-04-20-002-feat-p3-1-hook-wiring-plan.md](./2026-04-20-002-feat-p3-1-hook-wiring-plan.md)
- **Solutions:**
  - [bash-state-library-concurrent-load-modify-save-2026-04-20.md](../solutions/best-practices/bash-state-library-concurrent-load-modify-save-2026-04-20.md)
  - [claude-code-plugin-hooks-json-schema-2026-04-20.md](../solutions/developer-experience/claude-code-plugin-hooks-json-schema-2026-04-20.md)
