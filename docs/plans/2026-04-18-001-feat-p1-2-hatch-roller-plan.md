---
title: P1-2 — Hatch roller (rarity, stats, species)
type: feat
status: active
date: 2026-04-18
deepened: 2026-04-18
origin: docs/roadmap/P1-2-hatch-roller.md
---

# P1-2 — Hatch roller (rarity, stats, species)

## Overview

Build the non-deterministic hatch logic for the buddy plugin: a bash library (`scripts/lib/rng.sh`) that rolls a rarity, picks a species, generates rarity-floored stats, assigns a canned name, and assembles a complete new-buddy JSON object ready to persist via `buddy_save`. Ship the 5 launch species (axolotl, dragon, owl, ghost, capybara) as per-species JSON data files containing voice, stat weights, name pool, and stubbed fields for later phases. Include a pseudo-pity counter that rescues unlucky streaks after 10 consecutive Commons.

No slash-command wiring, line banks, evolution paths, or sprites — those are downstream tickets (P1-3, P3-2, P4-2, P7-2).

## Problem Frame

The plugin needs randomness to matter. The built-in `/buddy` is deterministic on user ID; this plugin explicitly trades determinism for a gacha loop (see origin plan D4). P1-1 established the state substrate; P1-2 provides the math and content that produces a freshly-hatched buddy. P1-3 will wire this into `/buddy:hatch` once both primitives exist.

The 60/25/10/4/1 rarity distribution, stat-floor scheme, and "one peak, one dump, three mid" stat pattern are all borrowed from Anthropic's proven `/buddy` implementation (see origin plan references). The pity counter is this plugin's addition — Anthropic's stateless model can't support it, but since we already persist state for evolution, the cost is negligible and the payoff is a better tail experience.

## Requirements Trace

- **R1** — `roll_rarity` returns one of `common / uncommon / rare / epic / legendary`; across 10,000 rolls the empirical distribution is within ±2% of 60/25/10/4/1.
- **R2** — `roll_species` returns one of the 5 launch species; each species has a distinct archetype voice recorded in `scripts/species/<name>.json`.
- **R3** — `roll_stats <rarity> <species>` returns a 5-stat JSON object (`debugging / patience / chaos / wisdom / snark`) in which every stat is ≥ the rarity floor (C=5 / U=15 / R=25 / E=35 / L=50) and follows the one-peak / one-dump / three-mid shape. Peak and dump slot selection is biased ~60% toward the species' preferred stat (see Unit 5 Approach); the remaining ~40% is uniform-random over the five stats. Expected P(peak = species peak-prefer) ≈ 0.68 (0.6 direct + 0.4 × 0.2 uniform hit).
- **R4** — `roll_name <species>` returns a name from the species' canned pool (≥ 20 per species).
- **R5** — `roll_buddy <pity_counter>` returns a complete new-buddy JSON object with `id`, `name`, `species`, `rarity`, `shiny: false`, `stats`, `form: "base"`, `level: 1`, `xp: 0`, and zeroed `signals`, ready to slot under `.buddy` and persist via `buddy_save`.
- **R6** — Pity counter: after 10 Commons accumulate without an intervening Rare+ reset, the next `roll_rarity` is forced to Rare+ regardless of the underlying roll. Per the origin ticket and umbrella plan D8, Common *increments* and Rare+ (rare/epic/legendary) *resets*; Uncommon is a neutral outcome and leaves the counter unchanged.
- **R6a** — `next_pity_counter(current, rarity)` is a pure helper function that projects R6's state machine: common → current+1, uncommon → current (unchanged), rare/epic/legendary → 0. Exposed separately from `roll_rarity` so P1-3 owns the atomic buddy.json read-roll-write cycle without coupling to rng.sh internals.
- **R7** — RNG is seeded from `/dev/urandom` in normal operation, and deterministically seedable via a `BUDDY_RNG_SEED` environment variable for tests.
- **R8** — The library adheres to the patterns established in `scripts/lib/state.sh`: no module-level `set -euo pipefail`, bash 4.1+ guard, re-source sentinel, explicit per-function error handling, stderr logging, never crash the caller.
- **R9** — bats tests cover distribution (±2% over 10k rolls), stat floor enforcement, pity trigger, and species data integrity.

## Scope Boundaries

- **Not** wiring the roll into `/buddy:hatch` — that is P1-3 and includes the slash-command state machine (`NO_BUDDY` / `ACTIVE` / `CORRUPT`), reroll confirmation flags, and token deduction.
- **Not** filling in `line_banks` content — P3-2 ships 50+ canned lines per event bank. This plan writes the empty-but-well-shaped stub.
- **Not** filling in `evolution_paths` — P4-2 defines form transition logic and signal-driven path selection. This plan writes the stub.
- **Not** ASCII sprites or shiny rendering — P7-2. `shiny: false` is hardcoded in the buddy output for now.
- **Not** LLM-generated names — P6 replaces the canned pool. We write ≥ 20 names per species in this ticket and that pool stays as the P6 fallback.
- **Not** XP curve or level thresholds — P4-1. `level: 1` and `xp: 0` are hardcoded in the output.

### Deferred to Separate Tasks

- **Wiring pity counter increments on save** → P1-3 is the first place that persists a freshly-hatched buddy. This plan exposes a pure `next_pity_counter` helper; P1-3 calls it when writing `meta.pityCounter`.
- **Signal tracking semantics** → P4-1 owns the shape and update semantics of `signals.consistency / variety / quality / chaos`. This plan freezes the initial zeroed shape as a literal JSON fragment that matches the plan's data model.

## Context & Research

### Relevant Code and Patterns

- `scripts/lib/state.sh` — reference for library structure. Key patterns to mirror: bash 4.1+ version guard at top of file; re-source sentinel `_RNG_SH_LOADED` guarding `readonly` declarations and dedup state; no `set -euo pipefail` at module scope (would break the hooks-must-exit-0 contract via P3-1's future sourcing); internal helpers prefixed `_rng_`; stderr-only logging via a `_rng_log` helper; all public functions explicitly return 0 or non-zero and never rely on ambient `set -e`.
- `tests/state.bats` + `tests/test_helper.bash` — template for rng.bats. Reuse the `BATS_TEST_TMPDIR`-based isolation pattern and `run --separate-stderr` for every `run` that calls library functions (so stderr warnings don't merge into `$output`).
- `docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md` — the umbrella plan. D1 (stats are LLM prompt dimensions, not gameplay levers), D4 (non-deterministic hatch from `/dev/urandom`), D8 (pseudo-pity from day one) are load-bearing for this ticket.

### Institutional Learnings

- `docs/solutions/best-practices/bash-state-library-patterns-2026-04-18.md` — the full canonical list of traps. Items that apply directly to rng.sh:
  - **A. Library structure**: no module-scope `set -euo pipefail`; bash 4.1+ check; re-source sentinel; `declare -gA` for any per-process state.
  - **B. Atomic writes**: not directly relevant (rng.sh doesn't write), but if we ever expose a helper that writes, it must go through `buddy_save`.
  - **G. bats test patterns**: `run --separate-stderr` for every invocation; wrap timing-sensitive attacks in `timeout`; avoid vacuous tests (distribution test must actually exercise the RNG, not a stub).
- Plugin-scaffolding gotchas (`docs/solutions/developer-experience/`) — not directly relevant since this ticket only touches bash library code, not plugin surfaces, but the "hooks must exit 0" contract motivates the no-`set -e` discipline.

### External References

None required — the rarity distribution and stat-floor scheme are specified directly in the umbrella plan. The `/buddy` reverse-engineering references are historical context, not implementation dependencies.

## Key Technical Decisions

- **Testability via `BUDDY_RNG_SEED` env var.** Override hook: when `BUDDY_RNG_SEED` is set to a non-empty integer, `_rng_seed` uses it directly and `_rng_int` runs against a deterministic sequence derived from `$RANDOM` with the seed wired in. When unset, seed fresh bytes from `/dev/urandom`. This is the only non-obvious piece of test scaffolding — without it, the distribution and pity tests must run 10k+ rolls against true randomness, which is fine but slow; with it, tests can also pin specific outcomes for unit-level assertions.
- **Seed derivation: `/dev/urandom` → `od -An -N4 -tu4`.** Read 4 bytes as an unsigned 32-bit integer and assign to `RANDOM` (bash 5.1+ supports writing to `RANDOM` to seed the PRNG; on bash 4.1–5.0 we fall back to `$RANDOM`'s own per-process seeding which is already adequate and the `/dev/urandom` read only guarantees *entropy at startup*, not per-call unpredictability — acceptable for a gacha, not for crypto). The ticket's `xxd`/`od` suggestion is consistent with this; we use `od` because it's more portable than `xxd` on minimal Linux images.
- **`_rng_int min max` is the only randomness primitive.** Everything else (rarity, species index, stat bands, name index) composes over it. This collapses the surface area that tests must verify.
- **Rarity buckets live in a single `readonly` associative array** (`_RNG_RARITY_CUMULATIVE`) so that changing the distribution is a one-line edit. Cumulative thresholds, not per-bucket percentages, so the roll is one integer compare chain, not a loop with accumulator.
- **Pity counter math is a pure helper: `next_pity_counter <current> <rarity>`.** No side effects, no state reads. The caller (P1-3) is responsible for loading `meta.pityCounter` from buddy.json, passing it into `roll_rarity`, computing the new counter via `next_pity_counter`, and writing it back atomically.
- **Pity forcing picks uniformly from Rare / Epic / Legendary weighted by their natural ratio (10/4/1 → 10/15ths / 4/15ths / 1/15th).** All three tiers scale by the same ~6.67x factor under pity (Legendary from 1% → 6.67%, Epic from 4% → 26.67%, Rare from 10% → 66.67%). Preserves the feel that Epic and Legendary are still rare even under pity, while guaranteeing at least Rare. This is a uniform scaling rather than a soft-pity concentration at higher tiers (the umbrella plan's Genshin reference is cited as *not* adopted); chosen for simplicity. Revisit after P5 playtesting if the felt generosity is off.
- **Stat algorithm: deterministic roles (peak, dump, 3×mid) drawn per rarity band, with species weights used only to break ties when selecting which stat gets the peak / dump assignment.** The origin doc mentions "base_stats_weights (for peak/dump bias)" — this is the cleanest interpretation. Species weights are not a naive multiplier (which would violate the "stats don't affect gameplay" invariant D1 across hatches of the same species); they are a *preference* over the peak/dump slot, with a roughly 60/40 chance of honoring the preference vs. rolling fully randomly.
- **Species data in JSON, loaded on demand, never cached in a bash variable.** Each call to `roll_species` / `roll_stats` / `roll_name` reads the relevant `scripts/species/<name>.json`. jq is already a dependency from state.sh. This keeps the authoring workflow simple (edit JSON, reload) and avoids stale-cache bugs.
- **`roll_buddy` returns the inner buddy object, not a full buddy.json envelope.** The caller (P1-3) wraps it with `hatchedAt`, `lastRerollAt`, `tokens`, `meta` before calling `buddy_save`. Keeps this library focused on rolling; keeps the envelope shape owned by the slash-command layer.
- **ID generation: 32 hex chars from `/dev/urandom` via `od`.** Not a strict RFC 4122 UUID — we don't need the format promise, and `uuidgen` isn't guaranteed on all targets. A plain random hex string is unambiguous and collision-free in practice. Field name stays `id`.
- **No trailing newline in `stdout` for scalar-returning functions** (`roll_rarity`, `roll_name`, `roll_species`). JSON-returning functions (`roll_stats`, `roll_buddy`) emit jq-formatted JSON without trailing newline. Matches state.sh's `printf '%s'` convention.

## Open Questions

### Resolved During Planning

- **Should `roll_buddy` own the pity-counter write?** No — separated into a pure `next_pity_counter` helper so P1-3 owns the atomic read-roll-write cycle against buddy.json. Keeps rng.sh stateless.
- **UUID library or random hex?** Random hex via `od`. See decisions.
- **How do species weights interact with the "stats don't affect gameplay" invariant (D1)?** Resolved: weights only bias peak/dump *slot selection* within a roll, not the absolute stat values. Two Axolotls of the same rarity still have different absolute stats, but are both more likely to peak in `patience` than in `chaos`.

### Deferred to Implementation

- **Exact `base_stats_weights` values per species** — noted as "one positive-preferred stat, one negative-preferred stat" in the data file; the specific mapping (axolotl: patience+, chaos−; dragon: chaos+, patience−; etc.) can be tuned at authoring time since the plan pins the archetype voices but not the exact stat-pref vector.
- **Exact 20-name pool per species** — the canned pool is authoring work inside the species JSON; the plan guarantees count and fingerprints-per-species but doesn't enumerate names. Implementer picks on-brand names.
- **Whether to seed `RANDOM` directly (bash 5.1+ feature) or rely on per-process `$RANDOM` defaults** — can be decided at implementation time based on what bash version the test environment exposes. Both approaches satisfy the distribution test; the env-var test override (`BUDDY_RNG_SEED`) is the same either way.

## Output Structure

    scripts/
    ├── lib/
    │   ├── state.sh             # existing (P1-1)
    │   └── rng.sh               # new — roll_rarity / roll_species / roll_stats / roll_name / roll_buddy / next_pity_counter
    └── species/
        ├── axolotl.json         # new
        ├── dragon.json          # new
        ├── owl.json             # new
        ├── ghost.json           # new
        └── capybara.json        # new

    tests/
    ├── state.bats               # existing (P1-1)
    ├── test_helper.bash         # existing — extend with rng helpers
    └── rng.bats                 # new

    README.md                    # modified (Unit 7 — brief Randomness section)
    docs/roadmap/P1-2-hatch-roller.md  # modified (Unit 7 — status + Notes)

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

**Library layering.** `rng.sh` depends on nothing except `jq` and bash 4.1+. State is not touched. The caller in P1-3 owns the read-roll-write cycle:

```
P1-3 hatch handler
  ├─ buddy_load            → existing pity value (or 0 if NO_BUDDY)
  ├─ roll_buddy <pity>     → inner buddy JSON
  ├─ next_pity_counter     → new pity value
  └─ buddy_save            → envelope { hatchedAt, buddy: <inner>, tokens, meta: { pityCounter: <new> } }
```

**`roll_buddy` composition.**

    roll_buddy(pity_counter):
      rarity   ← roll_rarity(pity_counter)
      species  ← roll_species()
      stats    ← roll_stats(rarity, species)
      name     ← roll_name(species)
      id       ← hex(16)
      return JSON {
        id, name, species, rarity,
        shiny: false,
        stats,
        form: "base",
        level: 1,
        xp: 0,
        signals: { consistency: {...zero}, variety: {...zero}, quality: {...zero}, chaos: {...zero} }
      }

**Rarity roll (with pity).**

    roll_rarity(pity):
      if pity >= 10:
        # forced Rare+ — weighted pick across rare/epic/legendary by natural 10:4:1
        r ← _rng_int(1, 15)
        return legendary if r == 1
        return epic       if r <= 5
        return rare
      r ← _rng_int(1, 100)
      return common     if r <= 60
      return uncommon   if r <= 85
      return rare       if r <= 95
      return epic       if r <= 99
      return legendary

**Stat roll.**

    roll_stats(rarity, species):
      floor   ← { common: 5, uncommon: 15, rare: 25, epic: 35, legendary: 50 }[rarity]
      peaked  ← pick_stat(species.base_stats_weights, bias: positive)   # honor pref ~60% of time
      dumped  ← pick_stat(species.base_stats_weights, bias: negative,
                          excluding: peaked)
      mids    ← remaining three stats
      return {
        peaked:  _rng_int(floor + 40, 100),    # peak_offset_lo = 40
        dumped:  _rng_int(floor,      floor + 15),  # dump_offset_hi = 15
        mids:    _rng_int(floor + 15, floor + 40) each  # mid window = 15..40
      }

    Concrete offsets (peak +40, dump +15, mid 15..40) pin the shape across rarities;
    ranges are clamped to [0, 100] at the top. See Unit 5 Approach for the full spec.

## Implementation Units

- [ ] **Unit 1: Library scaffolding + RNG primitives**

**Goal:** Lay down `scripts/lib/rng.sh` with the bash-4.1+ guard, re-source sentinel, error helpers, and the two core RNG primitives (`_rng_seed`, `_rng_int`). Establish the `BUDDY_RNG_SEED` test-override hook.

**Requirements:** R7, R8.

**Dependencies:** None.

**Files:**
- Create: `scripts/lib/rng.sh`
- Modify: `tests/test_helper.bash` (add `RNG_LIB` path and a reset helper for `BUDDY_RNG_SEED` between tests)
- Test: `tests/rng.bats`

**Approach:**
- Header comment matches state.sh's tone: purpose, the no-`set -e` note, bash 4.1+ rationale.
- Bash 4.1+ guard is a verbatim copy of state.sh's pattern.
- `_RNG_SH_LOADED=1` sentinel guards `readonly` declarations and the rarity-bucket associative array.
- `_rng_log` writes to stderr, prefixed `buddy-rng:`.
- `_rng_seed` reads 4 bytes from `/dev/urandom` via `od -An -N4 -tu4` and trims whitespace. On systems without `/dev/urandom`, it logs a warning and falls back to a composite of `${EPOCHREALTIME:-$(date +%s%N)}` + `$BASHPID` + `$$` + a per-source-increment counter, hashed to 32 bits. Single `date +%s` is **not** sufficient: a reroll within the same second would produce identical seeds. The composite guarantees divergent seeds for back-to-back invocations on the urandom fallback path, at the cost of slightly weaker unpredictability than urandom.
- When `BUDDY_RNG_SEED` is a non-empty integer, `_rng_seed` returns it directly and skips `/dev/urandom`.
- `_rng_seed` is called **lazily** on the first `_rng_int` invocation (gated by a `_RNG_SEEDED` flag inside the re-source sentinel block), not unconditionally at module source. This has two consequences: (a) re-sourcing `rng.sh` in the same process does not re-seed mid-session (production entropy is preserved across repeated hook invocations that source the library); (b) `BUDDY_RNG_SEED` takes effect the first time a public function runs after the env var is set, not at source time. Document this in the header so the determinism tests build the right mental model.
- Check `command -v jq >/dev/null` at source time; if jq is absent, emit a single stderr warning (`buddy-rng: jq not found — rolls will fail`) and set an internal `_RNG_JQ_MISSING=1` flag that all public functions check and short-circuit-return-nonzero on. Mirrors state.sh's log-and-return-nonzero discipline and avoids a silent failure mode if a hook sources the library in a minimal environment.
- `_rng_int min max` (integers, inclusive both ends) uses modulo over `$RANDOM`. `$RANDOM` spans 0–32767, which is not a multiple of 100, so there is a small per-bucket modulo bias. Arithmetic: 32768 mod 100 = 68, so 68 buckets get 328 hits and 32 get 327 — a per-bucket relative skew of ~0.3%, well within the ±2% distribution-test tolerance. Rule of thumb for future maintainers widening the range: worst-case relative bias ≈ `N / 32768` where `N` is the range size. If `N` grows past ~1000 this stops being negligible and `_rng_int` must switch to a rejection-sampling loop.

**Patterns to follow:**
- `scripts/lib/state.sh` header + guard + sentinel pattern.
- `_state_log` → `_rng_log` (same shape, different prefix).
- `declare -gA` for rarity cumulative buckets (future-proofs against re-sourcing).

**Test scenarios:**
- Happy path: sourcing `rng.sh` in a bash shell with bash 4.1+ succeeds without emitting to stderr.
- Happy path: `_rng_int 1 100` called 1000 times produces only values in `[1, 100]` and both boundaries hit at least once.
- Edge case: `_rng_int 5 5` always returns 5.
- Edge case: `_rng_int 1 2` over 1000 rolls produces both 1 and 2, with neither count < 400 (sanity, not a chi-square).
- Error path: `_rng_int 10 5` (inverted bounds) logs an error to stderr and returns non-zero.
- Determinism: with `BUDDY_RNG_SEED=42`, two independent bash processes that source `rng.sh` and call `_rng_int 1 100` ten times produce identical sequences. *(Bash-version caveat: the mechanism by which BUDDY_RNG_SEED actually pins the PRNG is a present finding for the user — see document-review output. This test's validity depends on that choice.)*
- Non-determinism: without `BUDDY_RNG_SEED`, 10 independent bash processes that source `rng.sh` and call `_rng_int 1 1000000` produce 10 distinct values. (Using a wide range rather than 1–100 makes birthday collisions effectively impossible, so the test is cheap and non-flaky.)
- Library hygiene: sourcing `rng.sh` does not leak `set -e` / `pipefail` into the caller (replicate the state.bats `false | true || exit 12` pattern).
- Library hygiene: re-sourcing `rng.sh` in the same shell does not re-assign `readonly` variables (no stderr noise).

**Verification:**
- `tests/bats-core/bin/bats tests/rng.bats` runs the scaffolding tests above and passes.
- Running `bash -c 'source scripts/lib/rng.sh && _rng_int 1 100'` prints a single integer in range and exits 0.

---

- [ ] **Unit 2: Species data files**

**Goal:** Author five JSON data files in `scripts/species/` — axolotl, dragon, owl, ghost, capybara — with the shape required by P1-2 (voice, base_stats_weights, name_pool) plus stubs for fields other phases own (line_banks, evolution_paths, sprite).

**Requirements:** R2, R4.

**Dependencies:** None.

**Files:**
- Create: `scripts/species/axolotl.json`
- Create: `scripts/species/dragon.json`
- Create: `scripts/species/owl.json`
- Create: `scripts/species/ghost.json`
- Create: `scripts/species/capybara.json`

**Approach:**
- Shared top-level shape:
  - `species` (redundant with filename but makes files self-describing for later loading)
  - `voice` — archetype label from the umbrella plan (e.g., `"wholesome-cheerleader"`)
  - `base_stats_weights` — object mapping the 5 stat names to one of `"peak-prefer" / "dump-prefer" / "neutral"`. Each species has exactly one peak-prefer and one dump-prefer stat; remaining three are neutral.
  - `name_pool` — array of ≥ 20 strings, on-brand for the species voice (e.g., axolotl cute-short names; dragon edgy-nerd names).
  - `evolution_paths` — `{}` stub. P4-2 fills in.
  - `line_banks` — `{}` stub. P3-2 fills in.
  - `sprite` — `null` stub. P7-2 fills in.
  - `schemaVersion` — `1` so that species files follow the same migration discipline as buddy.json (we may evolve the shape when we add evolution_paths etc.).
- Archetype mapping (all five locked by the umbrella plan):
  - axolotl → wholesome-cheerleader → peak `patience`, dump `chaos`
  - dragon → chaotic-gremlin → peak `chaos`, dump `patience`
  - owl → dry-scholar → peak `wisdom`, dump `snark`
  - ghost → deadpan-night → peak `snark`, dump `debugging`
  - capybara → chill-zen → peak `patience`, dump `debugging`
- Keep each file compact enough to scan in a terminal. Names should be short (≤ 10 chars) since P2 will render them in the status line.

**Patterns to follow:**
- `scripts/lib/state.sh`'s `schemaVersion: 1` convention — mirrors it so that species data also gets migration discipline later.
- The umbrella plan's species voice labels are authoritative.

**Test scenarios:**
- Data integrity (one test per file): each file is valid JSON and parses with `jq '.'`.
- Data integrity: each file has `voice`, `base_stats_weights`, `name_pool`, `schemaVersion`, plus the stub fields.
- Data integrity: `base_stats_weights` has exactly one `peak-prefer` key, one `dump-prefer` key, and three `neutral` keys, and covers all 5 stat names.
- Data integrity: `name_pool` has at least 20 entries, all non-empty strings, all unique within the file.
- Data integrity: no accidental capybara↔axolotl copy-paste — `species` field matches the filename for every file.

**Verification:**
- `ls scripts/species/*.json | wc -l` returns 5.
- `jq '.' scripts/species/*.json > /dev/null` completes without error.
- bats data-integrity tests pass.

---

- [ ] **Unit 3: `roll_species` and `roll_name`**

**Goal:** Implement the two simplest public roll functions — `roll_species` (uniform over the 5 species files) and `roll_name <species>` (uniform over the species' `name_pool`).

**Requirements:** R2, R4.

**Dependencies:** Unit 1, Unit 2.

**Files:**
- Modify: `scripts/lib/rng.sh` (add both functions)
- Test: `tests/rng.bats`

**Approach:**
- `roll_species` resolves the species directory by walking up from `${BASH_SOURCE[0]}` to find `scripts/species/`. Uses `find scripts/species -maxdepth 1 -name '*.json' -type f` then picks by `_rng_int 1 N`. Returns the species name (filename minus `.json`). Exposes the species-dir lookup as `_rng_species_dir` so tests can override via a `BUDDY_SPECIES_DIR` env var if needed — optional; default path walk is fine for production.
- `roll_name <species>` reads `scripts/species/<species>.json`, extracts `.name_pool` via jq, picks one element by `_rng_int 1 N`. Rejects species names containing `/`, `.`, or `..` to prevent path traversal via caller error.
- Both functions log-and-return-nonzero on missing files or empty pools, never crash the caller.

**Patterns to follow:**
- state.sh's `_state_valid_session_id` sanitization pattern for the species-name check in `roll_name`.

**Test scenarios:**
- Happy path: `roll_species` returns one of {axolotl, dragon, owl, ghost, capybara}.
- Happy path: `roll_species` called 500 times produces all five species with each count > 50 (sanity that distribution is roughly uniform, not precise).
- Happy path: `roll_name axolotl` returns a non-empty string that is present in axolotl's `name_pool`.
- Happy path: `roll_name <each of 5 species>` returns a valid pool entry for each.
- Error path: `roll_name nonexistent` logs an error to stderr and returns non-zero without crashing.
- Error path: `roll_name ../../etc/passwd` logs a path-traversal error and returns non-zero.
- Error path: `roll_name ""` logs an error and returns non-zero.

**Verification:**
- bats tests above pass.
- Manual: `source scripts/lib/rng.sh && roll_species && roll_name axolotl` prints two lines (species, name).

---

- [ ] **Unit 4: `roll_rarity` + `next_pity_counter`**

**Goal:** Implement the rarity roll with the 60/25/10/4/1 cumulative distribution and the pseudo-pity override, plus the pure `next_pity_counter` helper.

**Requirements:** R1, R6.

**Dependencies:** Unit 1.

**Files:**
- Modify: `scripts/lib/rng.sh`
- Test: `tests/rng.bats`

**Approach:**
- `roll_rarity <pity_counter>`:
  - Arg validation: pity_counter must match `^[0-9]+$`; non-numeric logs and returns non-zero.
  - If pity_counter ≥ 10: roll `_rng_int 1 15`; 1 → legendary, 2–5 → epic, 6–15 → rare. (10:4:1 natural ratio preserved.)
  - Else: roll `_rng_int 1 100`; ≤60 → common, ≤85 → uncommon, ≤95 → rare, ≤99 → epic, =100 → legendary.
- `next_pity_counter <current> <rarity>`:
  - common → current + 1
  - uncommon → current (unchanged — Uncommon is a neutral outcome per origin ticket and umbrella plan D8, which specify "increment on Common, reset on Rare+")
  - rare / epic / legendary → 0
  - any other string → logs and returns non-zero.
- Pity threshold is a `readonly PITY_THRESHOLD=10`. Not exposed via `userConfig` — this is a content decision, not an economy tunable, matching how the 60/25/10/4/1 distribution itself is hardcoded. Revisit if playtesting after P5 surfaces generosity issues.
- Use `declare -gA _RNG_RARITY_THRESHOLDS=([60]=common [85]=uncommon [95]=rare [99]=epic [100]=legendary)` — documented as an *ordered* config; the implementation iterates in numeric order. This mirrors the Key Technical Decisions bullet ("Rarity buckets live in a single `readonly` associative array"). Keeping a single representation avoids two sources of truth for the distribution.

**Patterns to follow:**
- state.sh's explicit `[[ "$var" =~ ^[0-9]+$ ]]` validation for numeric args.

**Test scenarios:**
- Happy path: `roll_rarity 0` returns one of {common, uncommon, rare, epic, legendary}.
- Distribution (the headline test): inside a **single bats test body** (not via `run` per call), source `rng.sh` once with a pinned `BUDDY_RNG_SEED`, loop 10,000 times calling `roll_rarity 0` directly, and accumulate counts into a `declare -A` bucket map. Only the final bucket assertions use `run`. Assert: common ∈ [5800, 6200] (±2%); uncommon ∈ [2300, 2700] (±2%); rare ∈ [800, 1200] (±2%); epic ∈ [200, 600] (absolute band, broader than ±2% because n=400 has σ≈20); legendary ∈ [40, 200] (absolute band, n=100 has σ≈10 so ±6σ ≈ [40, 160]; upper padded to 200 for the binomial right tail). *(Note: "±2%" in R1 applies literally only to the three most-populated buckets; epic and legendary use absolute tolerance bands because ±2% of 10k is much larger than their natural σ and would be trivially satisfied.)* Rerun the whole test under 3 different pinned seeds to surface seed-specific pathologies.
- Pity trigger: `roll_rarity 10` and `roll_rarity 11` return only rare/epic/legendary (never common or uncommon) over 1000 rolls.
- Pity boundary: `roll_rarity 9` can return common; `roll_rarity 10` never returns common. Test 500 rolls at each boundary.
- Pity distribution: under pity ≥ 10 with a **single pinned `BUDDY_RNG_SEED`**, assert exact bucket counts over 1500 rolls (snapshot test). This is a regression guard against the pity-forcing probability table changing silently — it is not a statistical test. A separate smoke test (no seed) asserts all three Rare+ buckets receive at least one hit over 1500 rolls.
- `next_pity_counter 0 common` → 1.
- `next_pity_counter 5 common` → 6.
- `next_pity_counter 9 common` → 10.
- `next_pity_counter 10 common` → 11 *(pity does not self-cap; it's the roll that forces Rare+ which then resets).*
- `next_pity_counter 10 rare` → 0.
- `next_pity_counter 7 legendary` → 0.
- `next_pity_counter 3 uncommon` → 3 *(Uncommon is neutral per origin ticket + umbrella plan D8 — neither increments nor resets).*
- `next_pity_counter 0 uncommon` → 0 *(neutral at zero too — not negative).*
- Error path: `roll_rarity foo` → logs error, returns non-zero.
- Error path: `roll_rarity -5` → logs error, returns non-zero.
- Error path: `next_pity_counter 0 puddle` → logs error, returns non-zero.

**Verification:**
- Distribution test passes on at least 3 different `BUDDY_RNG_SEED` values (documented in test).
- Pity tests pass.

---

- [ ] **Unit 5: `roll_stats`**

**Goal:** Implement rarity-floored stat generation with the "one peak, one dump, three mid" shape, species-weight-biased slot selection.

**Requirements:** R3.

**Dependencies:** Unit 1, Unit 2.

**Files:**
- Modify: `scripts/lib/rng.sh`
- Test: `tests/rng.bats`

**Approach:**
- `roll_stats <rarity> <species>`:
  - Validate `rarity` in {common, uncommon, rare, epic, legendary} and `species` against species-name regex. Fail fast with stderr + non-zero otherwise.
  - Load `base_stats_weights` from `scripts/species/<species>.json` via jq.
  - Constants (tuned once):
    - floors: common=5, uncommon=15, rare=25, epic=35, legendary=50
    - peak range: `[floor + 40, 100]` clamped to 100
    - dump range: `[floor, floor + 15]` clamped to 100
    - mid range: `[floor + 15, floor + 40]` clamped to 100
  - Slot selection:
    - With probability ~0.6 (a `_rng_int 1 100 <= 60` roll), the peak slot goes to the species' `peak-prefer` stat. Otherwise peak is one of the 5 stats, picked uniformly (including the preferred stat — so total P(peak = preferred) ≈ 0.68).
    - Dump slot is assigned the same way from the species' `dump-prefer` stat. If the random-draw branch picks the stat already chosen as peak, fall back to the species' `dump-prefer` stat unless it equals the peak; in that edge case (which Unit 2 prevents by validation — peak-prefer ≠ dump-prefer per species), fall back to a uniform draw over the four remaining stats.
    - Remaining 3 stats are mid.
  - Validate at species-load time that `base_stats_weights` has exactly one `peak-prefer` and one `dump-prefer` stat and that they differ. Fail loudly (stderr + non-zero) if violated.
  - Roll each slot's value via `_rng_int` within its range.
  - Emit a compact JSON object with keys in a stable order (debugging, patience, chaos, wisdom, snark) for diff-ability.

**Technical design:** *(optional — illustrates slot assignment; directional guidance, not implementation specification.)*

    assign_slots(species_weights):
      stats = [debugging, patience, chaos, wisdom, snark]

      peak_stat = (roll 1..100 <= 60)
        ? species_weights.peak_prefer
        : sample_uniform(stats)

      dump_candidate = (roll 1..100 <= 60)
        ? species_weights.dump_prefer
        : sample_uniform(stats, exclude=peak_stat)

      if dump_candidate == peak_stat:
        dump_stat = species_weights.dump_prefer
          if species_weights.dump_prefer != peak_stat
          else sample_uniform(stats, exclude=peak_stat)
      else:
        dump_stat = dump_candidate

      mid_stats = stats - {peak_stat, dump_stat}

      return { peak: peak_stat, dump: dump_stat, mids: mid_stats }

**Patterns to follow:**
- Single jq invocation to emit the final JSON object (same style as state.sh's `jq --argjson v ... '.schemaVersion = $v'`).

**Test scenarios:**
- Happy path: `roll_stats common axolotl | jq .` is valid JSON with exactly the 5 stat keys.
- Happy path: values for each stat are integers in `[0, 100]`.
- Floor enforcement (the headline test): across 200 `roll_stats legendary <species>` calls for every species, every stat value is ≥ 50 (1000 rolls total — still far above the ~5 rolls needed to catch a broken floor, well within a snappy bats run).
- Floor enforcement: across 50 `roll_stats <rarity> <species>` calls for each of the 5 rarities and 5 species, every stat value is ≥ the rarity floor. *(25 combinations × 50 rolls = 1,250 total — fast.)* Floor enforcement is a never-violated property: an implementation bug fails on the first bad roll, so large N adds no confidence. The exhaustive 12,500-roll variant is gated behind `BUDDY_RNG_SLOW_TESTS=1` for paranoid runs.
- Shape enforcement: across 500 calls of `roll_stats legendary axolotl`, exactly one stat per call has a value > floor + 40 (the peak); exactly one has a value ≤ floor + 15 (the dump); the other three are in between. Use a helper `_count_peak_dump_mid` to assert the shape.
- Species bias: across 2000 `roll_stats legendary axolotl` calls with a pinned seed, `patience` is the peak slot in > 55% of rolls (expected ~68% = 0.6 direct + 0.4 × 0.2 uniform hit; 55% leaves generous headroom against σ ≈ 0.01 at 2000 trials).
- Species bias: across 2000 `roll_stats legendary axolotl` calls, `chaos` is the dump slot in > 55% of rolls (same expected-value math as the peak bias).
- Error path: `roll_stats invalid-rarity axolotl` → stderr error, non-zero.
- Error path: `roll_stats common nonexistent-species` → stderr error, non-zero.
- Edge case: `roll_stats legendary axolotl` never produces a value > 100 (clamping works at the peak-range top).
- Edge case: `roll_stats common dragon` — a dump stat of `patience` (dragon's dump-prefer) can land at exactly `floor`, which is 5. Assert such a roll appears at least once in 500 tries.

**Verification:**
- Floor test runs under 30s on a typical dev machine (10k+ invocations of `roll_stats` via a single bash loop) — if slower, add a BATS skip with `$BUDDY_RNG_FAST_TESTS` opt-in and document.
- Manual: `source scripts/lib/rng.sh && roll_stats rare owl | jq` shows a well-formed stat block.

---

- [ ] **Unit 6: `roll_buddy` assembler**

**Goal:** Compose the four roll primitives into a single buddy-object emitter. This is the function P1-3 will actually call.

**Requirements:** R5.

**Dependencies:** Units 3, 4, 5.

**Files:**
- Modify: `scripts/lib/rng.sh`
- Modify: `README.md` (add a short "Randomness (P1-2)" section listing rng.sh's public functions and pointing at tests/rng.bats)
- Test: `tests/rng.bats`

**Approach:**
- `roll_buddy <pity_counter>`:
  - Validate pity_counter is a non-negative integer.
  - `rarity ← roll_rarity $pity_counter`
  - `species ← roll_species`
  - `stats ← roll_stats $rarity $species`
  - `name ← roll_name $species`
  - `id ← _rng_id` (new helper: 32-char hex from `od -An -N16 -tx1 /dev/urandom | tr -d ' \n'`; falls back to timestamp+hex if urandom is unavailable)
  - Assemble via a single jq invocation using `--arg` / `--argjson` so there's no JSON string concatenation in bash:
    ```
    jq -n --arg id "$id" --arg name "$name" --arg species "$species" \
          --arg rarity "$rarity" --argjson stats "$stats" \
          '{id:$id, name:$name, species:$species, rarity:$rarity,
            shiny:false, stats:$stats, form:"base", level:1, xp:0,
            signals:{...zero...}}'
    ```
  - The zeroed signals block is a literal — no caller configurability here; P4-1 owns signal semantics.
- If any sub-roll fails, `roll_buddy` logs which step failed and returns non-zero without emitting partial JSON.

**Patterns to follow:**
- state.sh's pattern of composing a single jq invocation rather than building JSON with `printf`/`cat <<EOF`.

**Test scenarios:**
- Happy path: `roll_buddy 0` emits valid JSON with exactly these top-level keys: `id`, `name`, `species`, `rarity`, `shiny`, `stats`, `form`, `level`, `xp`. `signals` is deliberately absent — P4-1 owns that field (see resolved decision 2).
- Happy path: `form` is `"base"`, `level` is `1`, `xp` is `0`, `shiny` is `false`.
- Happy path: `id` is 32 hex chars matching `^[0-9a-f]{32}$`.
- Happy path: rarity and species are internally consistent — stat floors match the rolled rarity (sanity-check the integration of Units 4 + 5).
- Integration: `roll_buddy 10` returns a buddy with rarity in {rare, epic, legendary} across 500 trials (pity propagates through the assembler).
- Integration: output of `roll_buddy` piped directly into a mock `buddy_save` envelope and `buddy_load` round-trips cleanly — *deferred to P1-3's integration tests; optional here but recommended if it's a cheap smoke test*.
- Error path: `roll_buddy foo` → stderr error, non-zero, no stdout.
- Error path: simulate a missing species file (move `scripts/species/ghost.json` in a test's teardown-safe way) — `roll_buddy 0` either returns a different species cleanly, or returns non-zero if all species lookup fails. *(In practice `roll_species` skips missing files via the filesystem scan, so this tests graceful degradation.)*

**Verification:**
- `source scripts/lib/rng.sh && roll_buddy 0 | jq` shows a well-formed buddy.
- `roll_buddy 0 | jq -e '. | has("id") and has("name") and has("species") and has("rarity") and has("stats") and (.level == 1)'` returns 0.

---

<!-- Unit 7 folded into Unit 6 per resolved decision 7. README update is in Unit 6 Files list; roadmap status flip is handled by /ce:work completion. -->

## System-Wide Impact

- **Interaction graph:** rng.sh is a pure-function library with no state reads/writes. It is sourced by P1-3's hatch handler (not yet written), and — via future hook scripts — nowhere else. Species JSON files are read by rng.sh only; P2 (status line) and P3-2 (commentary) will load species files independently with their own jq reads.
- **Error propagation:** All public functions log to stderr and return non-zero on failure. No function ever exits the shell or sets `$?` ambiguously. Callers (P1-3 when written) must check return codes.
- **State lifecycle risks:** None — this library does not touch `${CLAUDE_PLUGIN_DATA}`. Pity counter persistence is the caller's responsibility.
- **API surface parity:** None — rng.sh has no peer implementations to keep in sync. Species JSON shape is shared between rng.sh (P1-2), commentary.sh (P3-2), and evolution.sh (P4-2); those phases will add keys to the existing shape rather than fork. `schemaVersion: 1` in each species file establishes the migration discipline up front.
- **Integration coverage:** `roll_buddy` + `buddy_save` round-trip is not covered in this ticket (no caller yet); it is covered in P1-3 once the slash command is wired.
- **Unchanged invariants:** state.sh is not modified; existing 52 bats tests in tests/state.bats continue to pass untouched. `${CLAUDE_PLUGIN_DATA}/buddy.json` schema is not modified (P1-2 only *produces* content destined for the `.buddy` field, doesn't change the envelope).

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Distribution test is flaky at ±2% due to RNG variance, especially on the 1% legendary bucket. | Pin `BUDDY_RNG_SEED` in the distribution test; run against 3 different seeds. Use ±2% absolute bands for common/uncommon/rare, but absolute tolerance bands for epic (n=400, σ≈20) and legendary (n=100, σ≈10). See Unit 4 test scenarios for the specific bands; rationale is that ±2% of the *whole distribution* (±200 rolls) is much larger than the low-population buckets' natural σ, so expressing tolerance as absolute counts is the honest thing to do. |
| `$RANDOM` modulo bias skews distribution on boundary cases. | Our largest range is 1–100; worst-case relative per-bucket bias is ~0.3% (32768 mod 100 = 68 → 68 buckets get 328 hits, 32 get 327). Well within the ±2% distribution-test tolerance. Documented in the header comment so a future maintainer who widens ranges past ~1000 knows to switch `_rng_int` to rejection sampling. |
| `/dev/urandom` unavailable in some test/CI environments. | `_rng_seed` falls back to `date +%s` with a stderr warning. Tests use `BUDDY_RNG_SEED` so they don't depend on urandom anyway. |
| Species base_stats_weights authoring bikeshed — "is chaos really axolotl's dump?" | Lock the five archetype → peak/dump mappings in this plan (see Unit 2). Implementer doesn't re-decide. Tuning is a post-P8 concern (`/ce:compound` an adjustment if playtesting wants different). |
| Stat-floor test is slow if naively implemented. | Default bats run uses 50 rolls per (rarity, species) combo = 1,250 rolls (catches any broken floor on the first violation). Exhaustive 12,500-roll variant is gated behind `BUDDY_RNG_SLOW_TESTS=1`. Additionally, species JSON can be cached in a per-process `declare -gA` in `_rng_species_data[<name>]` to avoid repeated jq reads — breaks the "no caching" guideline but is safe inside a single rng.sh invocation and eliminates the biggest I/O cost. |
| Species file structure conflicts with what P3-2 or P4-2 will need. | Ship `schemaVersion: 1` in species files so the shape can be migrated when those phases add keys. The stub fields (`line_banks`, `evolution_paths`, `sprite`) explicitly reserve the key names. |
| Pity semantics for Uncommon ambiguous in source docs. | Resolved per document review: origin ticket + umbrella plan D8 both explicitly say "increment on Common, reset on Rare+" — Uncommon is neutral (neither increments nor resets). Encoded in `next_pity_counter`, R6, R6a, and Unit 4 test scenarios. |

## Open Decisions — Resolved (2026-04-19)

All 7 open decisions surfaced during the document review have been resolved before Unit 1 begins.

1. **`BUDDY_RNG_SEED` determinism mechanism → pure-bash LCG.** rng.sh stays at bash 4.1+ (matching state.sh). When `BUDDY_RNG_SEED` is set to a non-empty integer, `_rng_int` runs against a small linear congruential generator seeded from that value, independent of `$RANDOM`. When unset, `_rng_int` uses `$RANDOM`. Gives deterministic tests on any supported bash version.
2. **Signals zero-shape ownership → `roll_buddy` omits `signals` entirely.** P4-1 owns the `signals` field, its schema, and its first persistence. Neither P1-2 nor P1-3 synthesizes it — the field simply does not appear on a buddy.json until the phase that populates it lands. P1-2 stays entirely ignorant of P4-1's schema.
3. **`schemaVersion: 1` on species JSON files → keep.** Low cost, establishes migration discipline before the first species-file reader in P3-2/P4-2 ships.
4. **`_rng_id` → inline.** The `od` invocation for 32-hex ID generation lives directly inside `roll_buddy`. Extract only if a second consumer appears later.
5. **`BUDDY_SPECIES_DIR` → first-class seam in Unit 1.** Promoted out of the "optional" note. Tests use it to point at fixture directories without mutating `scripts/species/`. Production code reads the env var with a default walk-up from `${BASH_SOURCE[0]}`.
6. **`roll_buddy` scope → inner object.** Returns only the `.buddy` field contents (id, name, species, rarity, shiny, stats, form, level, xp — note: `signals` is excluded per decision 2). Envelope assembly belongs to P1-3.
7. **Unit 7 → folded into Unit 6.** README update moves to Unit 6's Files list. Roadmap status flip is handled by the `/ce:work` completion pass, not a numbered implementation unit.

## Documentation / Operational Notes

- `README.md` gets a short Randomness section listing the library's public functions and pointing at `tests/rng.bats` for usage examples.
- `docs/roadmap/P1-2-hatch-roller.md` is updated with status and Notes.
- If the implementation surfaces a notable learning (the `BUDDY_RNG_SEED` testing pattern is a candidate), promote it via `/ce:compound` into `docs/solutions/best-practices/`.
- No hooks, status-line scripts, or user-facing commands change in this ticket — nothing to operationalize yet.

## Sources & References

- **Origin ticket:** [docs/roadmap/P1-2-hatch-roller.md](../roadmap/P1-2-hatch-roller.md)
- **Umbrella plan (source of truth for scope):** [docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md](./2026-04-16-001-feat-claude-buddy-plugin-plan.md)
- **Precedent library:** [scripts/lib/state.sh](../../scripts/lib/state.sh)
- **Precedent tests:** [tests/state.bats](../../tests/state.bats), [tests/test_helper.bash](../../tests/test_helper.bash)
- **Institutional learnings applied:** [docs/solutions/best-practices/bash-state-library-patterns-2026-04-18.md](../solutions/best-practices/bash-state-library-patterns-2026-04-18.md)
- **External design references (from origin plan, design-only):** `/buddy` rarity distribution and stat-floor scheme per [findskill.ai](https://findskill.ai/blog/claude-code-buddy-guide/) and [claudefa.st](https://claudefa.st/blog/guide/mechanics/claude-buddy)
