---
id: P4-4
title: Sprite content (chafa-baked portraits)
phase: P4
status: done
depends_on: [P4-3]
origin_plan: docs/plans/2026-04-23-002-feat-p4-4-sprite-content-plan.md
---

# P4-4 — Sprite content

## Goal

Replace P4-3's placeholder hand-typed 5-line ASCII sprites with higher-fidelity
Unicode-sextant portraits baked at contributor-time from per-species source
PNGs via chafa, committed back into `scripts/species/*.json`.

## Tasks

- [x] `scripts/art/source-sprites.py` — deterministic pixel-art generator,
  one drawer per species. Contributor-authored via PIL primitives; CC0.
- [x] `assets/species/*.png` — 5 × 64×64 pixel-art PNGs produced by the
  generator, plus `assets/species/ATTRIBUTION.md`.
- [x] `scripts/bake-sprites.sh` — chafa wrapper with locked flags, ANSI-strip
  post-process, width/height/control-byte validation, atomic jq+rename
  write-back into species JSONs. `--check` dry-run mode.
- [x] `scripts/species/*.json` — `.sprite.base` arrays replaced with baked
  Unicode-sextant silhouettes. Unicode-only (no embedded ANSI). Idempotent.
- [x] `tests/unit/species_line_banks.bats` — new assertions: sprite.base
  non-empty (≥3 lines), ≤10 lines, ≤20 visible chars per line, no embedded
  ANSI escape sequences.
- [x] `tests/integration/slash.bats` + `test_interact.bats` — assertions
  retargeted from the old hand-typed "o v o" substring to the `█` full-block
  glyph that appears in every baked sprite.

## Exit criteria

- All 5 species render visibly distinct Unicode-sextant silhouettes in
  `/buddy:stats` and `/buddy:interact`.
- Running `bash scripts/bake-sprites.sh` twice against unchanged source
  PNGs produces no git diff.
- Full test suite passes.

## Notes

- **Why contributor-authored PIL art, not AI-generated:** no `GEMINI_API_KEY`
  available in the session; swapping the source at build time doesn't change
  the shape of the artifact (the baked sextant strings) so an AI-generated
  upgrade can drop in as a follow-up by replacing `scripts/art/source-sprites.py`
  with a downloader. The license trail is cleanest with fully contributor-
  authored CC0 pixel art.
- **Locked chafa flag set (D5):** `--size=14x10 --symbols=sextant --fg-only
  --colors=256 --format=symbols --dither=none --color-space=din99d`. We emit
  with `--colors=256` (not `--colors=none`) because that path correctly honors
  source PNG transparency; the downstream sed strips ANSI so the committed
  output is Unicode-only per D2.
- **On-disk format (D2):** Unicode block characters only. `render.sh` applies
  rarity color at render time on top of the silhouette. Preserves the
  legendary-rainbow single-color fallback (P4-3 commit 3a24f1f) and the
  `$NO_COLOR` strip.
- **Validation is python3-backed** for codepoint-accurate width counting —
  bash `${#s}` is byte-count and would over-report UTF-8 sextant glyphs.

### Implementation notes (2026-04-23)

- **Plan:** [docs/plans/2026-04-23-002-feat-p4-4-sprite-content-plan.md](../plans/2026-04-23-002-feat-p4-4-sprite-content-plan.md).
- **Branch:** same as P4-3 (`feat/p4-3-visible-buddy`) — scope added to PR #8
  per user request, rather than a separate PR.
- **Tools installed:** chafa 1.14.0 (`apt install chafa`), PIL 12.2.0
  (`pip install pillow --break-system-packages`).
- **Deferred to separate tickets:**
  - Moebius hand-painted ANSI track → P7-2-full-sprites if chafa output
    proves too algorithmic after live use.
  - Teen / final form sprites → P4-2-form-transitions.
  - Reactive / animated sprites → P4-5 (plan written in parallel with this
    ticket).
