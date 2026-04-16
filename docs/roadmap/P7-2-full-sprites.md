---
id: P7-2
title: 5-line animated sprites + shinies
phase: P7
status: todo
depends_on: [P2, P7-1]
origin_plan: docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md
---

# P7-2 — Full sprites

## Goal

Replace the 1-line status line with a full 5-line × 12-char ASCII sprite matching Anthropic's `/buddy` format. Three animation frames per sprite cycle at 0.5-2s. Shiny variants are rare treasures with rainbow ANSI.

## Tasks

- [ ] Design sprites for 18 species × ≥ 2 forms each = 36+ sprite sets. Each set:
  - [ ] 5 lines tall × 12 chars wide × 3 animation frames.
  - [ ] Graceful degradation: narrow terminals (< 12 wide) fall back to 1-line P2 rendering.
- [ ] Store sprites in `scripts/species/<name>.json` under `sprites.<form>.frames: [frame1, frame2, frame3]`.
- [ ] Update `statusline/buddy-line.sh`:
  - [ ] Detect terminal width; pick full or compact renderer.
  - [ ] Rotate frame based on a `time_seed = floor(unix_time / frame_duration_sec) % 3`.
  - [ ] Render name/level/tokens below the sprite on line 5.
- [ ] Change plugin `settings.json` `refreshInterval` from 5 → 1 for animation cadence. Guard with `userConfig.animateStatusLine: true` (default on).
- [ ] **Shiny variants**:
  - [ ] Add `shiny` flag to `roll_stats` (in P1-2) — ~1/256 post-rarity.
  - [ ] Shiny buddies get rainbow ANSI colors in sprite (cycle through colors per animation frame).
  - [ ] Shiny flag triggers the milestone bonus from P5 (+5 tokens).
- [ ] Tests:
  - [ ] Each sprite set renders correctly at terminal width 80, 120, 200.
  - [ ] Narrow terminal (width 40) falls back to compact line.
  - [ ] Animation cycles smoothly (no flicker on common terminal emulators: iTerm2, Terminal.app, alacritty, wezterm).
  - [ ] Shiny rendering: rainbow cycles without breaking ANSI resets on other status line segments.

## Exit criteria

- Sprites render crisply in a typical dev terminal.
- Rolling shiny feels genuinely special (both mechanically — tokens — and visually).
- Animation doesn't cause flicker or visual noise during active editing.

## Notes

- Sprite dimensions (5×12×3 frames) match Anthropic's format per [claudefa.st](https://claudefa.st/blog/guide/mechanics/claude-buddy) — adopting because the format is proven, not because we have to.
- **Flicker risk**: 1s refreshInterval is aggressive; test on slow terminals and SSH connections before shipping. Fallback: user can set `animateStatusLine: false`.
- Sprite design is content-heavy. Consider a `/ce:work` session focused purely on sprites, or solicit community contributions with a style guide.
- Shiny rate (1/256) is my starting estimate. Revisit based on how it feels after ~a month of real use — we might tune up or down.
- ANSI reset hygiene: always `\033[0m` at sprite end, or rainbow bleeds into the rest of the status line.
