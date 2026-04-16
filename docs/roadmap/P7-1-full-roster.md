---
id: P7-1
title: Scale roster to 18 species
phase: P7
status: todo
depends_on: [P4-2]
origin_plan: docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md
---

# P7-1 — Full roster

## Goal

Expand from 5 launch species to the full 18 matching Anthropic's `/buddy` roster. Each new species gets a distinct voice, ≥ 2 evolution paths, 50+ canned lines per event bank, and a default sprite (full animated sprite in P7-2).

## Tasks

- [ ] Add new species (13 total, in addition to the 5 from P1-2):
  - [ ] Duck
  - [ ] Goose
  - [ ] Cat
  - [ ] Rabbit
  - [ ] Penguin
  - [ ] Turtle
  - [ ] Snail
  - [ ] Octopus
  - [ ] Robot
  - [ ] Blob
  - [ ] Cactus
  - [ ] Mushroom
  - [ ] Chonk
- [ ] For each: create `scripts/species/<name>.json` with:
  - [ ] `voice` archetype (must be distinct — avoid duplicates of existing voices).
  - [ ] `preferred_axis` (for tiebreaking in form selection).
  - [ ] `base_stats_weights` (peak/dump bias).
  - [ ] `evolution_paths` (≥ 2 forms reachable).
  - [ ] `line_banks` with ≥ 50 lines per major event type per form.
  - [ ] Placeholder sprite (single emoji acceptable; full 5-line sprite in P7-2).
- [ ] **Voice diversity review**: map each species's voice against the others — no two species should feel interchangeable. If two collide, rewrite one.
- [ ] **Hatch distribution sanity check**: 10,000-roll test — all 18 species appear at expected rates (each species roughly 1/18 per rarity tier).
- [ ] Update README rarity/species table.

## Exit criteria

- All 18 species hatchable.
- Each has a distinct voice on blind-taste-test (pick 3 random lines from one species, user can identify which).
- No species is obviously under-polished (line bank parity).

## Notes

- Species roster from [findskill.ai](https://findskill.ai/blog/claude-code-buddy-guide/) and [claudefa.st](https://claudefa.st/blog/guide/mechanics/claude-buddy).
- **Content commitment**: 13 new species × 50 lines × 3 event types × 2 forms = 3,900 lines to write. This ticket is large — expect to spread it across several passes or solicit contributions.
- Consider an `/scripts/contrib/` review template for community PRs to species files.
- Voice diversity is the test — if a Chonk's line bank could be swapped into a Penguin and no one notices, rewrite.
