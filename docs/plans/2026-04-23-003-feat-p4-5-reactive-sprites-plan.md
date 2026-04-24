---
title: P4-5 — Reactive sprites (mood-driven frames + transcript-animation spike)
type: feat
status: active
date: 2026-04-23
---

# P4-5 — Reactive sprites

## Overview

P4-3 shipped the render pipeline; P4-4 shipped real baked art. The sprite
is still static: every `/buddy:stats` and `/buddy:interact` render shows
the same picture regardless of what's happening in the session. This
ticket makes the sprite **react** to session state.

Two deliverables:

1. **Reactive frame selection** (shippable, low risk). Every species
   gets ~4 baked frames — idle, happy, concerned, sleepy. The sprite
   shown in `/buddy:stats` and `/buddy:interact` is chosen based on
   current signals. Same render pipeline; no new primitives. Biggest
   aliveness-per-day-of-work delta.

2. **Transcript-animation spike** (time-boxed investigation). Does
   Claude Code's transcript pane honor ANSI cursor-control codes
   (`\e[<N>A` to rewrite lines in place)? If yes, follow-up tickets
   can add real animation to `/buddy:interact` (wave on open, settle
   to idle). If no, we stop thinking about it and rely on
   per-invocation frame reactivity alone.

## Problem Frame

After P4-4 you see the same still portrait every time you run
`/buddy:stats`, regardless of whether your session is going great
(long streak, clean edits) or badly (error burst, failing tests).
Users told us they want the buddy to feel *present* — to notice what's
happening. A Tamagotchi that never changes its face isn't a companion,
it's a mascot.

The spike question matters because the answer gates an entire class
of future work. If Claude Code's transcript is a dumb stream (frames
stack as separate text blocks), animation is impossible; if it
respects cursor-control codes like a real terminal, we can do
breathing loops and wave-on-open.

## Requirements Trace

- **R1.** Each of the 5 species gets 4 baked frames under `sprite`:
  `idle` (current `base` content), `happy`, `concerned`, `sleepy`.
  Source PNGs live under `assets/species/<name>/<frame>.png` (moving
  away from the flat `assets/species/<name>.png`).
- **R2.** `render_sprite_or_fallback` accepts an optional frame name
  and reads `.sprite.<frame>` (default `base`). Falls back to `base`
  if the requested frame is missing. Falls back to the emoji box if
  both are missing. Third-party species with only `base` continue to
  work.
- **R3.** `/buddy:stats` and `/buddy:interact` pick a frame via a new
  `_mood_resolve` helper. Logic, in priority order:
  - `concerned` if `chaos.errors` increased in the last 10 minutes
    (requires a new `session.lastErrorsSample` rolling window) OR
    a level-up has NOT happened this session and errors >= 3.
  - `happy` if streak ≥ 3 days OR successfulEdits/totalEdits > 0.80
    AND ≥ 5 total edits.
  - `sleepy` if `session.lastActivityAt` is more than 20 minutes ago
    when the command is invoked (proxy for "you came back to
    check in after a break").
  - `idle` otherwise.
- **R4.** The `bake-sprites.sh` script gains a `--frame=<name>` flag
  and iterates over every `assets/species/<name>/<frame>.png` when
  invoked without `--frame`. Backward-compatible: if only the legacy
  flat `assets/species/<name>.png` exists, it bakes into `.sprite.base`
  as before.
- **R5.** Tests cover: every species ships all 4 frames; each frame
  satisfies the format constraints (≤10 lines, ≤20 chars, no embedded
  ANSI); `_mood_resolve` returns the right frame for each signal
  configuration; `/buddy:stats` renders the chosen frame.
- **R6.** Spike output — a written solution doc (docs/solutions/)
  that records: does Claude Code's transcript honor `\e[<N>A`
  cursor-up? What about `\e[2K` clear-line? Does `sleep 0.2` survive
  between prints? What's the minimum viable animation primitive?
  If yes, a follow-up P4-6 ticket plans animation; if no, this
  ticket's reactive frames are the whole answer.

## Scope Boundaries

- **No animation in this ticket.** Only static-per-invocation frame
  selection. The spike proves or disproves feasibility but does not
  ship animation itself.
- **No new render primitives.** `render_sprite_or_fallback` gets a
  frame-name arg; everything else stays the same.
- **No changes to `render.sh`'s color pipeline.** Rarity wrap,
  legendary rainbow single-color fallback for non-ASCII, `$NO_COLOR`
  strip — all unchanged.
- **No form transitions.** That's P4-2. We read `.sprite.base.<frame>`
  only; teen/final form keys are out of scope.
- **No status-line reactivity.** The ambient status line stays emoji
  + name + level only. Mood-driven emoji would be its own ticket if
  we want it; it lives in a different interaction register.
- **No commentary-engine coupling.** Mood selection reads signals
  directly, same way `status.sh` does today. We don't route through
  `hook_commentary_select`. Keeps the commentary budget sacred.

### Deferred to Separate Tasks

- **Transcript animation** — P4-6 (conditional on spike outcome):
  breathing loop at top of `/buddy:stats`, wave-on-open for
  `/buddy:interact`. Only if the spike says `\e[<N>A` works.
- **Mood-driven status-line emoji** — P4-7 (maybe). Reads the same
  mood signal as this ticket's frame picker, swaps the status-line
  emoji. Small add-on once the mood helper exists.
- **Interact.default bank routing by mood** — follow-up. Today the
  interact line is random from `Interact.default`. Mood-routed
  banks (`Interact.concerned`, `Interact.sleepy`, etc.) give
  contextual replies instead of random ones. Low-risk extension
  once we have frames and mood signals wired.
- **Per-event one-shot reactions** — e.g., buddy bounces on
  level-up. Requires transcript animation; defer until P4-6.

## Context & Research

### Relevant Code and Patterns

- `scripts/lib/render.sh:render_sprite_or_fallback` — today reads
  `.sprite.base`. This plan extends it to accept a frame name with
  `base` fallback.
- `scripts/status.sh` + `scripts/interact.sh` — both extract signal
  fields via jq already. Mood helper adds one more jq extraction
  per render and one case statement.
- `scripts/bake-sprites.sh` — already iterates per species; extends
  to iterate per frame per species.
- `scripts/art/source-sprites.py` — needs 3 new drawer funcs per
  species (4 total incl. existing idle/base), or a single drawer
  that takes a `mood` parameter.

### Institutional Learnings

- `docs/solutions/developer-experience/claude-code-plugin-transcript-emit-as-trust-boundary-2026-04-21.md`
  — the P4-3 control-byte strip applies to per-character emissions.
  Animation primitives (cursor-control codes) would need a
  deliberate escape hatch if the spike says yes; `render_animated`
  would be its own function that bypasses the strip for ANSI it
  controls.
- `docs/solutions/best-practices/bash-jq-fork-collapse-hot-path-2026-04-21.md`
  — stats/interact are NOT hot paths. Adding a jq extraction for
  mood signals is fine.

### External References

- Rough priors on transcript animation: most CLI/TUI tools rely on
  cursor-control codes (termcap-style). Claude Code's transcript is
  rendered by a web/electron surface, not a real TTY, so the answer
  is genuinely uncertain. That's why the spike exists.

## Key Technical Decisions

- **D1. Frame set: idle / happy / concerned / sleepy.** Four covers
  the signal space (neutral, positive streak, error burst, idle
  return) with minimal overlap. Not shipping `angry` / `proud` /
  `curious` yet — add later if playtesting surfaces a gap.

- **D2. Frames live under `assets/species/<name>/<frame>.png` (dir
  per species).** Not `assets/species/<name>-<frame>.png` (flat with
  hyphens). The dir scales to teen/final forms later (P4-2 can add
  `<name>/teen/<frame>.png`).

- **D3. `.sprite.<frame>` as the JSON shape.** So species JSON has
  `"sprite": { "base": [...], "happy": [...], "concerned": [...],
  "sleepy": [...] }`. Backward-compatible — `base` is still the
  default/idle frame. Name-clash with a future `sprite.teen`
  resolved by nesting: `sprite.base.idle`, `sprite.teen.idle`, etc.
  But we're not doing the teen nesting in this ticket.

- **D4. Mood logic is a pure function in `scripts/lib/mood.sh`,
  not duplicated across status.sh and interact.sh.** Takes a buddy
  envelope + a session envelope; emits a single-word mood on stdout.
  One jq extraction path; two callers. Same pattern as `render.sh`.

- **D5. `concerned` priority is recent activity, not absolute counts.**
  Rolling `session.lastErrorsSample` is a 10-minute sliding window
  keyed off a small epoch timestamp. Avoids "buddy is concerned
  forever because you had a rough session three hours ago".
  Implementation-time detail: add to `hook_signals_apply` so the
  sample updates atomically with `chaos.errors`.

- **D6. `sleepy` priority is session-gap, not time-of-day.** We
  don't know the user's timezone reliably. A 20-minute gap between
  activity and the next `/buddy:stats` call is a cleaner signal than
  "after 10pm."

- **D7. Spike lives under `docs/solutions/developer-experience/`
  as a dated investigation doc.** Title:
  `claude-code-transcript-animation-feasibility-YYYY-MM-DD.md`.
  Contains: the exact test script (3 frames, 200ms sleeps, cursor-up),
  screenshots or transcript captures of what landed, verdict +
  follow-up routing.

- **D8. Fallback chain for missing frames:** requested frame →
  `.sprite.base` → emoji-in-box. Third-party species without baked
  art still work. Test coverage pins this.

## Open Questions

### Resolved During Planning

- **How many frames per species?** Four (D1).
- **Where do source PNGs live?** Per-species directory (D2).
- **Mood helper location?** `scripts/lib/mood.sh`, shared (D4).
- **Concerned signal?** 10-min rolling window of errors (D5).
- **Sleepy signal?** 20-min session gap, not time-of-day (D6).
- **Animation in this ticket?** No — spike-only. P4-6 implements
  if spike says yes.

### Deferred to Implementation

- **`session.lastErrorsSample` shape.** Probably
  `[epoch_secs, epoch_secs, ...]` capped at 20 entries. Or a
  simpler `{windowStartedAt, count}` pair. Implementer picks
  during Unit 3.
- **Exact signal thresholds for `happy`.** 0.80 edit-success ratio
  + ≥5 total edits is a starting point; tune after playtesting.
- **Frame selection under legendary.** Rainbow wrap already falls
  back to single-color for non-ASCII per the P4-3 fix — no extra
  work needed as long as baked frames remain Unicode-sextant.

## Output Structure

```
assets/
  species/
    axolotl/
      idle.png               # NEW — was assets/species/axolotl.png
      happy.png              # NEW
      concerned.png          # NEW
      sleepy.png             # NEW
    capybara/                # same shape
    dragon/
    ghost/
    owl/
    ATTRIBUTION.md           # MODIFIED — per-frame rows

scripts/
  art/
    source-sprites.py        # MODIFIED — takes mood parameter, writes subdir
  bake-sprites.sh            # MODIFIED — iterates per-frame, --frame=<name>
  lib/
    mood.sh                  # NEW — mood_resolve helper
    render.sh                # MODIFIED — render_sprite_or_fallback accepts frame
  species/
    *.json                   # MODIFIED — .sprite.{base,happy,concerned,sleepy}
  status.sh                  # MODIFIED — pick frame via mood
  interact.sh                # MODIFIED — pick frame via mood

tests/
  unit/
    mood.bats                # NEW — mood_resolve for each signal configuration
    test_render.bats         # MODIFIED — render with explicit frame name
    species_line_banks.bats  # MODIFIED — assert all 4 frames present + valid
  integration/
    slash.bats               # MODIFIED — stats shows mood-appropriate frame
    test_interact.bats       # MODIFIED — interact shows mood-appropriate frame

docs/
  plans/
    2026-04-23-003-feat-p4-5-reactive-sprites-plan.md  # THIS FILE
  roadmap/
    P4-5-reactive-sprites.md                           # NEW
  solutions/
    developer-experience/
      claude-code-transcript-animation-feasibility-2026-04-23.md  # NEW (Unit 1)
```

## Implementation Units

- [ ] **Unit 1: Transcript-animation feasibility spike**

**Goal:** Answer the question "can we animate in Claude Code's
transcript?" with a written verdict. Time-boxed to 2 hours.

**Requirements:** R6.

**Dependencies:** None.

**Files:**
- Create: `docs/solutions/developer-experience/claude-code-transcript-animation-feasibility-2026-04-23.md`

**Approach:**
- Write a tiny test script that prints 3 frames separated by 200ms
  sleeps with `\e[4A` (cursor-up 4) + `\e[0J` (clear-to-end) between
  frames. Run it via a Claude Code dispatch (any skill that shells
  out, e.g., a throwaway `/buddy:_anim_spike` command scoped to this
  ticket and removed after).
- Capture what the transcript actually displays: one live-updating
  frame? Three stacked frames? Mangled output?
- Try 2-3 variations: `\e[<N>A`, `\r` + overwrite, `\e[2K` clear-line.
- Document the verdict: "yes, animate in follow-up P4-6" OR "no,
  reactive frames are the end state."
- Remove the throwaway spike command before merging this ticket.

**Execution note:** This unit blocks everything else's scope
decisions. Do it first; if the answer is yes, the plan's deferred
"transcript animation" becomes P4-6 and we don't over-invest in
workarounds here. If no, tune the mood logic harder because frame
selection is the whole story.

**Patterns to follow:**
- Existing `docs/solutions/` doc shape — frontmatter `module`,
  `tags`, `problem_type`, plus a dated title.

**Test scenarios:**
- Test expectation: none — investigation doc only. Verdict is
  captured in prose.

**Verification:**
- Solution doc exists with an unambiguous verdict section.
- If verdict is yes: P4-6 ticket created with the spike doc linked.
- If verdict is no: note added to this plan's Deferred section.

---

- [ ] **Unit 2: Per-species frame drawers + source PNGs**

**Goal:** Produce 4 PNGs per species (20 total) via an extended
`source-sprites.py`.

**Requirements:** R1.

**Dependencies:** None — can proceed in parallel with Unit 1.

**Files:**
- Modify: `scripts/art/source-sprites.py`
- Create: `assets/species/<name>/idle.png`, `happy.png`,
  `concerned.png`, `sleepy.png` for each of the 5 species (via the
  script).
- Modify: `assets/species/ATTRIBUTION.md` — add per-frame rows.
- Delete: the flat `assets/species/<name>.png` files.

**Approach:**
- Refactor each `draw_<species>` to take a `mood` parameter
  (one of idle/happy/concerned/sleepy). Shared base blob + mood-
  specific overlay (different eyes, mouth shape, cheek blush, etc.).
- Keep the script deterministic: same input, byte-identical output.
- Eyeball each frame during iteration — adjust pixel placement
  until the differences read clearly at 14×10 sextant output.
- Delete flat PNGs after the dir-per-species layout ships to avoid
  dead assets.

**Patterns to follow:**
- Existing `draw_axolotl` etc. in `source-sprites.py` for the per-
  species pixel primitives.

**Test scenarios:**
- Structural: a small bats test asserts every species has all 4
  frames in `assets/species/<name>/`.
- Manual: run `python3 scripts/art/source-sprites.py`, visually
  confirm each frame reads its mood.

**Verification:**
- 20 PNGs committed under `assets/species/<species>/<frame>.png`.
- ATTRIBUTION.md updated.
- Flat PNGs removed.

---

- [ ] **Unit 3: Mood helper + signal accumulation**

**Goal:** `scripts/lib/mood.sh` emits a single-word mood given
buddy + session JSON. Rolling error-sample window accumulates in
signals.

**Requirements:** R3, R5 (partial).

**Dependencies:** None — but Unit 5 won't compose without this.

**Files:**
- Create: `scripts/lib/mood.sh`
- Modify: `scripts/hooks/signals.sh` — extend `hook_signals_apply`
  to bump a `session.lastErrorsSample` rolling window alongside the
  existing `chaos.errors` increment. Implementation-time unknown:
  window shape (see Deferred).
- Create: `tests/unit/mood.bats`

**Approach:**
- `mood_resolve <buddy_json> <session_json>` emits exactly one of
  `idle happy concerned sleepy` on stdout. Pure function, no I/O
  beyond reading its arguments.
- Source-guard: `_MOOD_SH_LOADED`, matches `state.sh` pattern.
- Sleepy signal reads `session.lastActivityAt` (already tracked
  post-P4-1); compares against "now" from the caller (helper takes
  an optional `--now=<epoch>` arg so tests can mock).
- No jq forks inside the helper — let the caller extract fields
  and pass as args. Keeps the function testable without fixture
  JSON files.

**Execution note:** Test-first is a clean fit. Write one bats test
per signal configuration (happy streak, error burst, idle gap,
plain idle) before implementing.

**Patterns to follow:**
- `scripts/lib/evolution.sh` for pure-function + source-guard shape.
- `scripts/hooks/signals.sh` `hook_signals_apply` fusion pass for
  adding the rolling window without a second jq fork.

**Test scenarios:**
- Happy path: streak=5, otherwise neutral → `happy`.
- Happy path: 3 errors in last 10min → `concerned`.
- Happy path: lastActivityAt=30min ago → `sleepy`.
- Happy path: neutral envelope → `idle`.
- Edge case: tied signals (concerned + sleepy both true) →
  `concerned` wins per D5 priority.
- Edge case: malformed/missing fields → `idle` default.
- Integration (with signals.sh): rolling window evicts entries
  older than 10min on every bump.

**Verification:**
- `tests/unit/mood.bats` green.
- `scripts/hooks/signals.sh` extended without breaking any existing
  signals tests.

---

- [ ] **Unit 4: Extend bake + render for frame names**

**Goal:** `bake-sprites.sh` and `render.sh` accept frame names.

**Requirements:** R2, R4.

**Dependencies:** Unit 2 (source PNGs exist).

**Files:**
- Modify: `scripts/bake-sprites.sh`
- Modify: `scripts/lib/render.sh` — `render_sprite_or_fallback`
  accepts optional 4th arg `frame` (default "base").
- Modify: `tests/unit/test_render.bats`

**Approach:**
- `bake-sprites.sh`:
  - Without `--frame`: iterate every `assets/species/<name>/*.png`,
    bake into `.sprite.<frame>` in the species JSON (frame name
    from filename without `.png`).
  - With `--frame=<name>`: only bake that frame across all species.
  - Backward-compatible: if only flat `assets/species/<name>.png`
    exists (no subdir), bake into `.sprite.base` as today.
- `render_sprite_or_fallback <path> <rarity> <shiny> [frame]`:
  reads `.sprite.<frame>`; if empty or missing, falls back to
  `.sprite.base`; if both missing, emits the emoji-in-box fallback.
  Signature change is additive; existing callers keep working.

**Execution note:** Test-first on the render.sh change. Add a
bats scenario that renders a species JSON with only `base` and
asserts the frame fallback lands on base — proves the backward-
compatibility path didn't drift.

**Patterns to follow:**
- Existing `_bake_all` loop shape.
- Existing `_render_color_line` fallback-on-malformed discipline.

**Test scenarios:**
- Bake: species with 4 frames → all 4 land in JSON.
- Bake: species with only a flat PNG → `.sprite.base` populated.
- Bake: missing species PNG → exit 1 with clear message.
- Render: explicit `frame=happy` with happy populated → happy
  sprite emitted.
- Render: explicit `frame=happy` with happy missing → base sprite
  emitted (fallback).
- Render: both missing → emoji-in-box fallback.

**Verification:**
- New scenarios green.
- Existing P4-3/P4-4 render tests still pass (no signature break).

---

- [ ] **Unit 5: Wire mood into stats + interact**

**Goal:** `/buddy:stats` and `/buddy:interact` pick a frame via
`mood_resolve` and render the chosen frame.

**Requirements:** R3.

**Dependencies:** Units 3 and 4.

**Files:**
- Modify: `scripts/status.sh`
- Modify: `scripts/interact.sh`
- Modify: `tests/integration/slash.bats`
- Modify: `tests/integration/test_interact.bats`

**Approach:**
- Both scripts source `scripts/lib/mood.sh`.
- Before the sprite render call, extract the mood and pass as the
  4th arg to `render_sprite_or_fallback`.
- Guard: if `mood.sh` fails to source (shouldn't, but belt-and-braces),
  fall back to `base` frame. Keeps the exit-0 discipline from
  P4-3 review-fix round.

**Patterns to follow:**
- The P4-3 review-fix `source || { echo ""; exit 0; }` pattern
  for non-critical lib loads.

**Test scenarios:**
- Stats: seeded buddy with streak=5 → output contains happy-
  frame-distinctive substring.
- Stats: seeded buddy with 3 recent errors → output contains
  concerned-frame-distinctive substring.
- Stats: seeded buddy with 30min gap → output contains
  sleepy-frame-distinctive substring.
- Stats: neutral buddy → idle/base frame.
- Interact: same four scenarios.

**Verification:**
- `tests/run-all.sh` green.
- Manual eyeball: seed different states, confirm the buddy visibly
  changes portrait.

---

- [ ] **Unit 6: Roadmap ticket + backlog threading**

**Goal:** Roadmap ticket mirrors this plan; P4-6 is threaded
conditionally on Unit 1's verdict.

**Requirements:** Operational.

**Dependencies:** All prior units.

**Files:**
- Create: `docs/roadmap/P4-5-reactive-sprites.md`
- Create (conditional on Unit 1 verdict = yes):
  `docs/roadmap/P4-6-transcript-animation.md` — stub ticket
  referencing the spike doc.

**Approach:**
- Mirror `docs/roadmap/P4-4-sprite-content.md` shape.
- If spike verdict is no, update the Scope Boundaries section of
  this plan's roadmap ticket to reflect "animation not feasible."

**Test scenarios:**
- Test expectation: none — docs only.

**Verification:**
- Roadmap reflects what shipped.
- If spike said yes, P4-6 stub exists for follow-up.

## System-Wide Impact

- **Interaction graph:** `mood.sh` is a new pure helper. No
  hook/state writes beyond Unit 3's rolling window in
  `hook_signals_apply` (already atomic via the existing signals
  write path).
- **Error propagation:** Render surfaces stay exit-0. If `mood.sh`
  fails, Unit 5's fallback uses `base`. No new failure modes.
- **State lifecycle risks:** Rolling window in `session.lastErrorsSample`
  is session-scoped state; no persistence concerns, gets discarded
  at session end like any session field.
- **API surface parity:** `render_sprite_or_fallback` gains an
  optional 4th arg. Callers without it get today's behavior.
- **Unchanged invariants:** Hook latency budget, `$NO_COLOR` strip,
  legendary rainbow fallback, transcript-emit control-byte strip,
  `/buddy:interact` read-only invariant (mood helper reads signals;
  it does not write).
- **Integration coverage:** Unit 5's integration tests prove the
  end-to-end signal → mood → frame pipeline on real seeded buddies.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Spike answer is "no animation possible" and we pre-built hooks for it | Unit 1 runs first and writes the verdict before Units 2-6 scope expands. If no, we stop at frame reactivity — no rework. |
| Rolling-window signal in `hook_signals_apply` slows the hot path | The window is a tiny bounded array (≤20 entries) and updates via the existing signals jq fork, not a new one. Measure before/after in the existing perf harness. |
| Frame differences don't read clearly at 14×10 sextant resolution | Unit 2 iterates on source PNGs until differences land; if two frames look identical, they aren't shipping two frames — collapse to one. |
| Third-party species without frame content break post-Unit 4 | `render_sprite_or_fallback` falls back to `.sprite.base` then to the emoji box. Tests pin both fallbacks. |
| `mood_resolve` thresholds turn out to be wrong in practice (always happy, never sleepy) | Ship and tune. D5/D6 call out the starting values; a follow-up "tune mood thresholds" ticket is cheap once we have telemetry. |
| Tied signals produce ambiguous moods | D5 priority order is explicit: concerned > happy > sleepy > idle. Unit 3 has a test for the tied case. |

## Documentation / Operational Notes

- `scripts/bake-sprites.sh --help` gets a `--frame=<name>` note.
- `scripts/art/source-sprites.py`'s module docstring documents
  the per-mood drawer pattern.
- `README.md` "Viewing your buddy" section (if it exists by then)
  gets a paragraph about reactive frames.
- No migration. Users see the new reactive behavior after the PR
  merges; no action required.

## Sources & References

- Related plan: `docs/plans/2026-04-23-001-feat-p4-3-visible-buddy-plan.md`.
- Related plan: `docs/plans/2026-04-23-002-feat-p4-4-sprite-content-plan.md`.
- Related ticket: `docs/roadmap/P4-2-form-transitions.md` — consumer
  of the eventual nested sprite shape if/when we add teen/final.
- P4-3 review fix: commit 3a24f1f (non-ASCII legendary fallback) —
  unchanged by this plan; mood frames stay within its assumption.
