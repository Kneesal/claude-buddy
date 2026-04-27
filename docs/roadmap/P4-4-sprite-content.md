---
id: P4-4
title: Sprite content (hand-authored ASCII)
phase: P4
status: done
depends_on: [P4-3]
origin_plan: docs/plans/2026-04-23-002-feat-p4-4-sprite-content-plan.md
---

# P4-4 — Sprite content

## Goal

Replace P4-3's placeholder 5-line ASCII sprites with per-species art of
higher craft. Two iterations landed in this ticket; the shipped form is
iteration 2.

## Iteration 1 (landed then reverted): chafa-baked Unicode sextant silhouettes

- `scripts/art/source-sprites.py` deterministically drew 64×64 pixel-art
  PNGs via PIL primitives.
- `scripts/bake-sprites.sh` wrapped chafa (`--symbols=sextant --fg-only
  --colors=256` + ANSI strip) and wrote Unicode-sextant silhouettes into
  `.sprite.base`.
- `assets/species/*.png` + `ATTRIBUTION.md` committed the CC0 source art.
- Passed all structural validators and tests.

**Reverted after user playtesting** — the sextant silhouettes lost too
much personality in the 14×10 cell downsample. Recognizable shapes, no
faces, no species voice. The pipeline worked; the aesthetic didn't.

The sextant-bake pipeline is documented in
`docs/solutions/developer-experience/chafa-sextant-sprite-bake-pipeline-2026-04-23.md`
and remains a valid technique for plugins that want photo-like terminal
art. This plugin opted out.

## Iteration 2 (shipped): hand-authored 5×12 straight ASCII

Each species in `scripts/species/<name>.json:.sprite.base` is a 5-line
ASCII portrait ≤12 chars wide. No emoji. No Unicode blocks. Plain
punctuation carrying every line:

- axolotl — gills as `~`, oval body with `\_/` smile, little feet
- dragon — wings flanking `(( >.< ))`, scales via `^^^^`
- owl — tufted ears, `(O_O)` eyes, book-stand feet
- ghost — rounded dome, wavy tail with `vvv`
- capybara — stocky rectangle, sleepy eyes, chunky legs

## Tasks

- [x] Hand-author 5 species portraits, each 5 lines × ≤12 chars.
- [x] Write into `scripts/species/<name>.json:.sprite.base`.
- [x] Remove chafa pipeline: `scripts/bake-sprites.sh`,
  `scripts/art/source-sprites.py`, `assets/`,
  `tests/integration/test_bake_sprites.bats`.
- [x] Update `tests/integration/slash.bats` + `test_interact.bats`
  sprite-content assertion from `█` (sextant marker) to
  `\ \_/ /` (axolotl's distinctive tummy seam).
- [x] `tests/unit/species_line_banks.bats` P4-4 assertions stay
  (non-empty, ≤10 lines, ≤20 chars, no embedded ANSI) — they're
  format-agnostic.

## Exit criteria

- All 5 species render recognizable ASCII portraits with distinct faces
  in `/buddy:stats` and `/buddy:interact`.
- Full test suite green.
- No chafa / PIL / pip dependency anywhere in the repo.

## Notes

- **Why straight ASCII over sextant bake:** playtesting the sextant art
  revealed that silhouettes without faces don't read as characters.
  ASCII + clear eye placement carries more personality per character
  than any pixel downsample at this cell budget.
- **Source of the style cue:** investigation of Anthropic's unshipped
  `/buddy` (leaked-source coverage only; not in the installed binary)
  described ~5-line × ~12-char ASCII-with-emoji compositions. We took
  the dimensions and tightness but dropped the emoji per user direction.
- **Deferred to separate tickets:**
  - Reactive / animated sprites → P4-5 (plan at
    `docs/plans/2026-04-23-003-feat-p4-5-reactive-sprites-plan.md`).
  - Hand-painted ANSI via Moebius for a future high-fidelity pass →
    suggested P7-2, only if the ASCII baseline feels thin after live use.
  - Teen / final form sprites → P4-2-form-transitions.

### Implementation notes (2026-04-24)

- **Plan:** [docs/plans/2026-04-23-002-feat-p4-4-sprite-content-plan.md](../plans/2026-04-23-002-feat-p4-4-sprite-content-plan.md).
  The plan's chafa-track is reflected in the reverted iteration 1; the
  shipped form is what the plan called "iteration-time tuning."
- **Branch:** `feat/p4-3-visible-buddy` — scope added to PR #8.
- **Tools used for iteration 1 (now deleted):** chafa 1.14.0, PIL 12.2.0.
- **Shipped art:** 100% hand-typed, no tooling required to reproduce.
