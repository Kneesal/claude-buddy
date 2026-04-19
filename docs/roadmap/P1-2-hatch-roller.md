---
id: P1-2
title: Hatch roller (rarity, stats, species)
phase: P1
status: done
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

### Implementation notes (2026-04-19)

Resolved during implementation (see [plan](../plans/2026-04-18-001-feat-p1-2-hatch-roller-plan.md) for full rationale):

- **Uncommon is neutral for pity** — origin roadmap + umbrella plan D8 both specify "Common increments, Rare+ resets." Uncommon neither increments nor resets. Encoded in `next_pity_counter`.
- **`roll_buddy` returns the inner buddy** (no envelope). P1-3 wraps it with `hatchedAt`/`tokens`/`meta`.
- **`signals` is deliberately absent from `roll_buddy` output** — P4-1 owns that field and its schema.
- **`BUDDY_RNG_SEED` uses a pure-bash LCG** (Numerical Recipes constants, high-16-bit output to avoid short-period low bits). Lazy-seeded once per process.
- **Subshell trap discovered during implementation**: `$()` forks a subshell, wiping LCG state changes. Refactored all internal state-preserving call sites to use the no-subshell pattern (`fn arg >/dev/null; val=$_RNG_ROLL`). Documented in `_rng_int`'s header. **Candidate for `/ce:compound`** — this is a bash library gotcha worth promoting into `docs/solutions/best-practices/`.
- **`base_stats_weights` bias is ~60% slot preference** (not a value multiplier). Expected P(peak = preferred) ≈ 0.68. Preserves D1's "stats don't affect gameplay" invariant across hatches of the same species.
- **Species JSON ships `schemaVersion: 1`** — establishes migration discipline before the first species-file reader in P3-2 / P4-2.
- **`BUDDY_SPECIES_DIR` env override** is a first-class test seam (tests point at fixture dirs without mutating `scripts/species/`).
- **Stat-shape ranges are disjoint** (`[floor, floor+14]` / `[floor+15, floor+40]` / `[floor+41, 100]`) so peak/dump/mid classification is unambiguous at boundaries 64/65 and 90/91.
- **Performance**: cached species weight lookups + printf-based stat-JSON assembly cut `tests/rng.bats` wall time from ~10min to ~2:25. Exhaustive floor test (200 × 25 combos) is gated behind `BUDDY_RNG_SLOW_TESTS=1`.

All 61 rng tests pass; 52 existing state tests continue to pass untouched.
