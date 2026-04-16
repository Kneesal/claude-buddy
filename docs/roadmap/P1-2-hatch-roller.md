---
id: P1-2
title: Hatch roller (rarity, stats, species)
phase: P1
status: todo
depends_on: [P1-1]
origin_plan: docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md
---

# P1-2 — Hatch roller

## Goal

Non-deterministic hatch logic — seed from `/dev/urandom`, roll a rarity from Anthropic's proven 60/25/10/4/1 distribution, pick a species from the 5-species starting roster, generate stats with rarity-based floors, and assign a name from a canned pool.

## Tasks

- [ ] Create `scripts/lib/rng.sh` exposing: `roll_rarity`, `roll_species`, `roll_stats`, `roll_name`.
- [ ] Seed RNG from `/dev/urandom` (16 bytes, derive 32-bit seed via `xxd` or `od`).
- [ ] Rarity distribution: Common 60% / Uncommon 25% / Rare 10% / Epic 4% / Legendary 1%. Integer rolls against cumulative buckets.
- [ ] Stat floors per rarity: Common 5 · Uncommon 15 · Rare 25 · Epic 35 · Legendary 50. Remaining 0-100 filled with "one peak, one dump, three mid" pattern matching `/buddy` ([claudefa.st reference](https://claudefa.st/blog/guide/mechanics/claude-buddy)).
- [ ] Starting roster (5 species), each with distinct archetype voice:
  - [ ] **Axolotl** — wholesome-cheerleader
  - [ ] **Dragon** — chaotic-gremlin
  - [ ] **Owl** — dry-scholar
  - [ ] **Ghost** — deadpan-night
  - [ ] **Capybara** — chill-zen
- [ ] Per-species data file `scripts/species/<name>.json` with: `voice`, `base_stats_weights` (for peak/dump bias), `evolution_paths` (stub — filled in P4-2), `line_banks` (stub — filled in P3-2), placeholders for sprite (P7-2).
- [ ] Name pool: 20 canned names per species at minimum (e.g., Pip, Bean, Spud, Mochi…). Upgraded to LLM-generated in P6.
- [ ] **Pseudo-pity counter** (`meta.pityCounter`): increment on Common, reset on Rare+. At `pityCounter >= 10`, force next hatch to Rare+.
- [ ] Tests:
  - [ ] Distribution test: 10,000 rolls → rarities within ±2% of target.
  - [ ] Stat floor enforcement: every Legendary roll has all stats ≥ 50.
  - [ ] Pity trigger: 10 forced Common rolls → 11th rolls Rare+.

## Exit criteria

- `roll_buddy` returns a complete new-buddy object ready to persist via `buddy_save`.
- Distribution matches target within statistical tolerance.
- Pseudo-pity never fires for a "normal" user but rescues unlucky streaks.

## Notes

- Why non-deterministic (not user-ID-hashed like `/buddy`): the gacha loop *needs* randomness. We're already storing state (required for evolution), so the "zero-state" argument that justifies `/buddy`'s determinism doesn't apply.
- Stats are LLM prompt dimensions + line-bank lookup keys — they don't mechanically affect XP or token rates. See Plan D1.
- Keep each `species/<name>.json` small and scannable — species are the canonical place content work lives.
