---
title: P4-4 — Sprite content (chafa-baked portraits)
type: feat
status: active
date: 2026-04-23
---

# P4-4 — Sprite content

## Overview

P4-3 shipped the sprite render pipeline plus hand-typed 5-line ASCII art
as a stand-in. This ticket replaces the hand-typed sprites with
higher-fidelity portraits baked at build-time from per-species source
images via **chafa**, committed back into `scripts/species/*.json`
under `sprite.base`.

Net change for users: the same `/buddy:stats` and `/buddy:interact`
surfaces render visibly nicer portraits. Render-time has zero new
dependencies (we `cat` pre-baked strings). Reproducible in git diff.

## Problem Frame

The P4-3 sprites are functional but minimal — five lines of ASCII at
~14 chars wide. Every species looks stylistically similar because a
single person typed five lines per species in ten minutes. The research
digest (best-practices-researcher, this session) identified chafa with
sextant symbols + 256-color fg-only output as the strongest path to
higher fidelity without shipping runtime tooling: ~28×30 effective
"pixels" inside a 14×10 character box, plain Unicode + ANSI that
degrades cleanly under `$NO_COLOR`, pre-rendered once and committed.

The alternative artistic track (hand-painted ANSI in Moebius) is
aesthetically superior but blocks on having an artist and trades
reproducibility for soul. This plan picks the chafa track as the
baseline; a future P7-2-full-sprites ticket can replace selective
species with Moebius-authored portraits without changing the render
contract.

## Requirements Trace

- **R1.** Each of the 5 launch species (axolotl, dragon, owl, ghost,
  capybara) gets a higher-fidelity sprite in
  `scripts/species/<name>.json:sprite.base` rendered from a committed
  source PNG under `assets/species/<name>.png`.
- **R2.** Baked sprites contain Unicode block characters (sextants)
  only — **no embedded ANSI color codes**. Rarity coloring is applied
  by `scripts/lib/render.sh:_render_color_line` at render time, same
  as today. This preserves the legendary rainbow path, the `$NO_COLOR`
  strip, and the existing rarity palette.
- **R3.** A reproducible `scripts/bake-sprites.sh` regenerates every
  species sprite from its source PNG with locked chafa flags. Running
  the script twice produces byte-identical output (pinned flags +
  pinned chafa version check).
- **R4.** Each sprite fits the existing `render.sh` contract: ≤10
  lines, ≤20 characters wide per line, no tabs / newlines / other
  control bytes.
- **R5.** Source art lives under `assets/species/` with an
  `assets/species/ATTRIBUTION.md` documenting per-species license +
  source. No source art ships without clean attribution.
- **R6.** Tests cover: (a) every species `sprite.base` is non-empty
  and structurally valid (extend the existing `species_line_banks.bats`
  assertions), (b) legendary render on a non-ASCII-only sprite
  falls back to single-color wrap (path already exists post-P4-3), (c)
  `$NO_COLOR` strips all ANSI from a baked sprite render, (d) the
  fallback-box path still works when `sprite.base` is empty (regression
  guard — the box path isn't used by any shipped species after this
  lands, but the code remains for third-party species).

## Scope Boundaries

- **No teen / final forms.** P4-2-form-transitions owns those. This
  plan only writes `sprite.base`, not `sprite.teen` or `sprite.final`.
- **No shiny variants beyond what P4-3 already handles.** Shiny still
  means "prepend ✨" via `render_sprite_or_fallback`; we do not bake
  separate shiny sprites.
- **No Moebius / hand-painted track in this ticket.** That's a
  follow-up. This ticket explicitly picks the reproducible chafa
  track.
- **No runtime chafa dependency.** The bake is a contributor-time tool;
  end users never need chafa installed. The script checks for chafa at
  build time and fails loudly if it's missing.
- **No interactive preview tooling.** `scripts/bake-sprites.sh
  --preview` or similar is out of scope. Contributors can
  `bash scripts/status.sh` against a seeded buddy to eyeball results.
- **No changes to `render.sh` public API.** The renderer already
  handles non-ASCII correctly (byte-slice fallback for legendary
  shipped in P4-3 commit 3a24f1f). This ticket proves that and writes
  regression coverage; it does not expand the API.
- **No P4-3 review residuals.** Scope-adjacent but separate:
  species-dir triplication, installer atomic-write refactor,
  `render_name` rename. Those belong in a P4-3-followups ticket.

### Deferred to Separate Tasks

- **Moebius hand-painted portraits** — suggested P7-2-full-sprites,
  only if chafa output proves insufficiently distinctive after a
  few weeks of use. Trades reproducibility for artist-authored soul.
- **Teen / final forms** — P4-2-form-transitions. The sprite JSON
  shape already reserves `sprite.teen` and `sprite.final` alongside
  `base`.
- **Third-party species sprite submissions** — if users ship their
  own species JSONs, they can bake or hand-author sprites. A
  contributor guide is a docs task, not this ticket.

## Context & Research

### Relevant Code and Patterns

- `scripts/lib/render.sh:render_sprite_or_fallback` — reads
  `.sprite.base` from the species JSON, caps at 10 lines, pads and
  color-wraps per line. No changes required; validates our format
  choice.
- `scripts/lib/render.sh:_render_color_line` — ASCII-only check at
  the top of the legendary branch, falls back to single-color wrap
  for non-ASCII input. Shipped in P4-3 commit 3a24f1f specifically
  to make baked sextant art safe.
- `scripts/species/*.json` — current shape: `"sprite": { "base": [...] }`.
  Every species already has this field with 5 lines of hand-typed art.
  This ticket overwrites those arrays.
- `tests/unit/species_line_banks.bats` — structural asserts on
  species JSON. This plan adds a non-empty-check for `sprite.base`.
- `tests/unit/test_render.bats` — render.sh unit tests. Extend with
  a baked-sprite round-trip test.

### Institutional Learnings

- `docs/solutions/developer-experience/claude-code-plugin-transcript-emit-as-trust-boundary-2026-04-21.md`
  — all emitted strings pass through `tr -d '[:cntrl:]'` before
  printf. chafa sextant-symbols output is Unicode block chars only,
  but we still post-process to be certain no stray control bytes
  leaked in.
- `docs/solutions/best-practices/bash-jq-fork-collapse-hot-path-2026-04-21.md`
  — the bake script is NOT hot-path (contributor-time only). jq
  readability > fusion.

### External References

- **Research digest, this session:** chafa wins on 14×10 sextant
  output, plain Unicode + ANSI, deterministic given pinned flags,
  zero runtime deps when pre-baked. ascii-image-converter is the
  runner-up for pure-ASCII aesthetic. viu/timg/jp2a/catimg all
  outclassed for this use case.
- **chafa docs:** `chafa --help` for symbol sets, dithering,
  color-space options. Pinned-version flags in the bake script.

## Key Technical Decisions

- **D1. Track: chafa-baked at build time.** Not Moebius. Not runtime.
  Rationale: reproducibility + zero runtime deps + "good enough"
  fidelity at small sizes. Moebius is deferred because it needs an
  artist and trades diff-friendliness for soul.

- **D2. On-disk format: Unicode block characters only, no embedded
  ANSI.** chafa flag set is `--symbols=sextant --colors=256 --fg-only
  --format=symbols` and we **additionally strip any ANSI escapes**
  with `sed 's/\x1b\[[0-9;]*m//g'` as a defense-in-depth post-process.
  Rarity color is applied by `render.sh` at render time, same as
  today. Legendary rainbow goes through the single-color fallback
  because baked sprites contain non-ASCII sextant glyphs — that path
  already works post-P4-3.

  *Why not commit baked ANSI?* Three reasons. (a) Rarity should
  override the baked color so common/uncommon/rare/epic visibly
  differ — baked ANSI would fight the rarity wrap. (b) Legendary
  rainbow per-char would need to compose with per-char baked colors
  and the math gets gnarly. (c) `$NO_COLOR` strip stays trivially
  correct when we never emit ANSI we didn't inject ourselves.

- **D3. Source art lives under `assets/species/`.** Per-species PNG
  at a consistent base resolution (suggested 48×48 or 64×64, pixel
  art style). `assets/species/ATTRIBUTION.md` tracks license + source
  per file. Initial source art is a **planning-time unknown** deferred
  to implementation — either CC0 pixel-art from OpenGameArt, a
  commissioned set, or AI-generated art from a license-clean model
  (document the choice in ATTRIBUTION.md).

- **D4. Bake script is `scripts/bake-sprites.sh`, not a Makefile
  target.** Follows the repo's "bash scripts, no build system"
  convention from `CLAUDE.md`. Exits 1 if chafa is missing; prints
  an install-hint per-OS (`brew install chafa` /
  `apt install chafa`).

- **D5. Locked chafa flags:**
  `chafa --size=14x10 --symbols=sextant --colors=256 --fg-only
  --format=symbols --dither=none --color-space=din99d`.
  Pinned for reproducibility. If a chafa version bump changes
  output, the PR diff will surface it.

- **D6. Baked output replaces hand-typed sprites atomically.** The
  bake script writes each species JSON via `jq ... > tmp && mv -f`
  (matches the project's state-write discipline, even though this is
  contributor-state not user-state). Running against committed source
  art should produce byte-identical output to what's already
  committed — the bake is idempotent.

- **D7. Fallback-box path preserved.** `render_sprite_or_fallback`
  still handles empty `sprite.base`. Third-party species without
  baked sprites continue to get the emoji-in-box fallback. This
  ticket does not delete that code path.

## Open Questions

### Resolved During Planning

- **Track choice (chafa vs Moebius vs hybrid)?** chafa (D1).
  Moebius deferred to P7-2.
- **ANSI-in-sprite.base or Unicode-only?** Unicode-only (D2).
- **Runtime chafa install required?** No — build-time only.
- **Update render.sh?** No API changes. Rely on the P4-3 non-ASCII
  fallback already shipped (commit 3a24f1f).
- **Does the fallback-box path stay?** Yes (D7).

### Deferred to Implementation

- **Source art provenance.** CC0 pixel-art vs commissioned vs AI-
  generated. The implementer picks and documents in
  `assets/species/ATTRIBUTION.md`. Whatever is chosen must pass a
  license check — no "maybe CC" or ambiguous attribution.
- **Exact chafa version pin.** The implementer verifies
  `chafa --version` on their build box and records the version in
  the bake script's usage docstring. Cross-version drift is the
  main re-bake trigger.
- **Source PNG size.** 48×48 vs 64×64 vs larger. Pick once, document
  in ATTRIBUTION.md alongside each file. Sextant output size is
  locked at 14×10 chars regardless.
- **Box symbol removal.** If chafa emits trailing spaces or residual
  box-drawing chars that don't belong, post-process as needed. This
  is execution-time tuning.

## Output Structure

```
assets/
  species/
    axolotl.png                # NEW — 48×48 or 64×64 pixel art
    capybara.png               # NEW
    dragon.png                 # NEW
    ghost.png                  # NEW
    owl.png                    # NEW
    ATTRIBUTION.md             # NEW — license + source per file

scripts/
  bake-sprites.sh              # NEW — chafa wrapper, writes back into species JSONs
  species/
    *.json                     # MODIFIED — .sprite.base arrays replaced with baked output

tests/
  unit/
    species_line_banks.bats    # MODIFIED — assert sprite.base non-empty, line limits
    test_render.bats           # MODIFIED — regression: baked sprite renders + NO_COLOR + legendary fallback

docs/
  roadmap/
    P4-4-sprite-content.md     # NEW — ticket mirror of this plan
```

## Implementation Units

- [ ] **Unit 1: Source-art acquisition + attribution**

**Goal:** Land five per-species source PNGs plus clean attribution, so
the bake has reproducible inputs.

**Requirements:** R5.

**Dependencies:** None.

**Files:**
- Create: `assets/species/axolotl.png`, `capybara.png`, `dragon.png`,
  `ghost.png`, `owl.png`
- Create: `assets/species/ATTRIBUTION.md`

**Approach:**
- Pick one source-art path per the deferred-to-implementation note:
  CC0 pixel-art from OpenGameArt, commissioned set, or AI-generated
  from a license-clean model. **No ambiguous licenses** — if the
  license isn't clearly permissive (CC0, MIT, CC-BY with attribution
  recorded, commissioned with transfer), find a different source.
- Every file gets an entry in `ATTRIBUTION.md` with: source URL,
  license, author, date acquired, any required attribution text.
- Target resolution: 48×48 or 64×64 pixel art. Consistent across
  species so chafa output looks like one set.
- Aesthetic: match the P4-3 species voice (axolotl=soft, dragon=
  fierce, owl=wise, ghost=whimsical, capybara=chill).

**Patterns to follow:**
- No direct repo precedent for licensed assets — establish the
  attribution-per-file convention cleanly this first time.

**Test scenarios:**
- Structural: CI or a simple bats test asserts every species has a
  matching PNG in `assets/species/` and every PNG has an entry in
  `ATTRIBUTION.md`.
- `file assets/species/*.png` confirms each is a valid PNG image.

**Verification:**
- `assets/species/` contains 5 PNGs + `ATTRIBUTION.md`.
- License review: a reviewer (or you) can confirm each file's
  provenance from ATTRIBUTION.md alone.

---

- [ ] **Unit 2: `scripts/bake-sprites.sh` bake script**

**Goal:** Reproducible chafa wrapper that turns each
`assets/species/<name>.png` into a `sprite.base` array in the
corresponding `scripts/species/<name>.json`.

**Requirements:** R3, R4, R2.

**Dependencies:** Unit 1 (source PNGs exist).

**Files:**
- Create: `scripts/bake-sprites.sh`

**Approach:**
- Top-of-file usage block: purpose, required tools, pinned chafa
  version (`chafa --version` check).
- Per species: run chafa with the locked flag set (D5), capture
  stdout, post-process: (a) `sed 's/\x1b\[[0-9;]*m//g'` strip any
  residual ANSI (defense-in-depth), (b) `tr -d '\r'` normalize line
  endings, (c) split on newlines into a JSON array.
- Validate: each output line is ≤20 chars, total lines ≤10 (D4 from
  P4-3 render.sh contract). Fail loudly if violated — a failed bake
  is a contributor-time problem, not a runtime-time one.
- Write back via `jq --argjson sprite '<array>' '.sprite.base = $sprite'
  species.json > tmp && mv -f tmp species.json` — atomic per-file.
- Script exit codes: 0 on success, 1 on missing chafa / invalid PNG /
  validation failure.
- Help flag: `scripts/bake-sprites.sh --help` prints usage + chafa
  install hint.

**Patterns to follow:**
- `scripts/install_statusline.sh` subcommand + help-flag dispatch
  style.
- `scripts/lib/state.sh` atomic tmp+rename pattern (conceptually — we
  don't need flock here since this is contributor-state).

**Test scenarios:**
- Manual: run `bash scripts/bake-sprites.sh` against a repo with the
  source PNGs present; confirm it writes sensible content into every
  species JSON and exits 0.
- Manual: run with `chafa` intentionally unavailable (`PATH=/bin
  bash scripts/bake-sprites.sh`); confirm exit 1 with a clear
  message + install hint.
- Manual: run twice in a row; the second run produces no diff
  (idempotent).
- Structural (optional): a small bats test that stubs `chafa` with
  a known-output script and asserts the species JSON is updated
  correctly.

**Verification:**
- Script runs successfully against Unit 1's source PNGs.
- Output is idempotent across runs.
- `git diff scripts/species/*.json` shows the expected
  hand-typed-to-baked transition.

---

- [ ] **Unit 3: Bake + commit the 5 species sprites**

**Goal:** Run the bake and commit the generated `sprite.base` arrays.

**Requirements:** R1, R2, R4.

**Dependencies:** Units 1 and 2.

**Files:**
- Modify: `scripts/species/axolotl.json`, `capybara.json`,
  `dragon.json`, `ghost.json`, `owl.json`

**Approach:**
- Run `bash scripts/bake-sprites.sh`.
- Review the diff: each species' `sprite.base` array went from 5
  hand-typed lines to chafa's baked sextant output.
- Eyeball each sprite via `CLAUDE_PLUGIN_DATA=/tmp/buddy-preview`
  + seeded hatches for all 5 species (see the preview pattern used
  during P4-3 art authoring).
- If a sprite reads poorly (unrecognizable, muddy), iterate on the
  source PNG — don't tweak chafa flags per-species, keep the bake
  reproducible.

**Execution note:** This is the first real use of the bake script.
Expect 1-2 iterations per species on source-art quality. Re-running
the bake on a tweaked PNG must produce clean diffs (idempotent).

**Patterns to follow:**
- The P4-3 art-authoring iteration loop: bake, preview via
  `/buddy:status`, tweak, re-bake.

**Test scenarios:**
- Integration: the `/buddy:stats` and `/buddy:interact` renders
  still match the test assertions from P4-3 that check for
  species-specific sprite content (the "o v o" axolotl assertion in
  `tests/integration/slash.bats` and `test_interact.bats` will need
  updating to a new distinctive substring from the baked axolotl
  sprite).

**Verification:**
- All 5 species render recognizable portraits in `/buddy:stats`.
- `git diff` shows every species' `sprite.base` replaced with
  baked content.
- Existing integration tests updated to new sprite-content
  substrings; full suite stays green.

---

- [ ] **Unit 4: Test coverage for baked sprite format**

**Goal:** Regression-guard the format decisions locked in this plan.

**Requirements:** R6.

**Dependencies:** Unit 3.

**Files:**
- Modify: `tests/unit/species_line_banks.bats`
- Modify: `tests/unit/test_render.bats`
- Modify: `tests/integration/slash.bats` (update axolotl substring)
- Modify: `tests/integration/test_interact.bats` (update axolotl
  substring)

**Approach:**
- `species_line_banks.bats`: add assertions that every species'
  `sprite.base` is a non-empty array (new — today's test only asserts
  array-of-strings, which allows empty).
- `species_line_banks.bats`: assert every line is ≤20 chars (matches
  D4 render.sh contract).
- `species_line_banks.bats`: assert no embedded ANSI in `sprite.base`
  strings (regex `\x1b\[`). Defense in depth for D2.
- `test_render.bats`: add a test that baked-sprite rendering under
  `NO_COLOR=1` contains no ANSI escapes.
- `test_render.bats`: add a test that the legendary rainbow path on
  a non-ASCII sprite (take a real baked species) falls back to a
  single-color wrap (proves the P4-3 commit 3a24f1f safety net works
  on real data, not just synthetic fixtures).
- `slash.bats` + `test_interact.bats`: the existing axolotl-specific
  sprite-content substring check (`"o v o"` today) needs updating
  to whatever distinctive substring the baked axolotl sprite
  contains. Do this as part of Unit 3's iteration.

**Patterns to follow:**
- Existing structural-check style in `species_line_banks.bats`.
- The P4-3 non-ASCII/legendary test in `test_render.bats`.

**Test scenarios:**
- Structural: `sprite.base` non-empty (happy path) — fails if any
  species ships with `"base": []`.
- Structural: no embedded ANSI in any `sprite.base` string — fails
  if the bake post-process regresses.
- Structural: every line ≤20 chars — fails if a bake produces a
  wider line.
- Happy path: baked sprite + `NO_COLOR=1` → no ANSI in output.
- Happy path: baked sprite + legendary → at least one color code
  wrapping (single-color fallback path), not byte-sliced.
- Integration: `/buddy:stats` output contains a distinctive
  substring from the baked axolotl (seed 42) sprite.

**Verification:**
- `tests/run-all.sh` green, including the new assertions.
- Deleting the ANSI-strip sed in `scripts/bake-sprites.sh` and
  re-baking causes `species_line_banks.bats` to fail — the
  regression-guard actually guards.

---

- [ ] **Unit 5: Roadmap ticket + README note**

**Goal:** Document the ticket and update user-facing docs.

**Requirements:** Operational.

**Dependencies:** Units 1-4.

**Files:**
- Create: `docs/roadmap/P4-4-sprite-content.md`
- Modify: `README.md` (if a "species / art" section exists; otherwise
  skip — this is a contributor concern, not user-facing copy).

**Approach:**
- Roadmap ticket mirrors this plan's Overview + Implementation-Units
  summary, same pattern as `docs/roadmap/P4-3-visible-buddy.md`.
- Frontmatter: `id: P4-4`, `phase: P4`, `depends_on: [P4-3]`,
  `origin_plan: docs/plans/2026-04-23-002-feat-p4-4-sprite-content-plan.md`.
- README update is optional — only if the project already has a
  "how the art works" section. Skip if not, to avoid adding doc
  scope to this ticket.

**Patterns to follow:**
- `docs/roadmap/P4-3-visible-buddy.md` for the shape.

**Test scenarios:**
- Test expectation: none — docs-only.

**Verification:**
- Roadmap ticket exists and mirrors the plan.

## System-Wide Impact

- **Interaction graph:** `render_sprite_or_fallback` already handles
  non-ASCII via the P4-3 ASCII-only check. No code changes to
  render.sh. Status/interact commands work unchanged — they `cat`
  the new strings via the existing pipeline.
- **Error propagation:** The bake script is contributor-time and
  exits 1 on failure. Runtime render stays exit-0 per project
  discipline — if a species JSON has a malformed `sprite.base`,
  `render_sprite_or_fallback`'s jq-parse error branch emits the
  fallback box.
- **API surface parity:** No API changes. `/buddy:stats`,
  `/buddy:interact`, and the ambient statusline all continue to
  read `.sprite.base` identically.
- **Unchanged invariants:** `render.sh` public function signatures,
  the fallback-box code path for empty `sprite.base`, the
  rarity-color wrap, the legendary rainbow path, the `$NO_COLOR`
  strip, the P4-3 control-byte strip on all emits.
- **Integration coverage:** Unit 4's new test scenarios prove the
  baked format doesn't regress the P4-3 safety nets on real (not
  synthetic) data.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Source-art license turns out to be ambiguous post-merge | Unit 1 gate: no file lands without a clean entry in `ATTRIBUTION.md`. Reviewer can spot-check any entry. |
| chafa version drift produces different output on different contributor boxes | Unit 2 pins the version check in the bake script; PR diff surfaces any drift. Worst case: bump the pin and re-bake in a follow-up commit. |
| Baked sprites look worse than the hand-typed 5-liners | Unit 3 allows 1-2 iterations per species on source-art quality. If chafa-of-source-PNG still reads poorly, this is the signal to escalate to the Moebius track (P7-2). |
| Tests for distinctive sprite substrings become brittle across rebakes | Pick substrings that are structurally part of the sprite (e.g., a known row of sextant chars) rather than transient-looking content. Accept that a source-art change breaks the test — that's the correct signal. |
| chafa isn't installed on a contributor's box | Bake script exits 1 with per-OS install hints. Contributors without chafa can still review and test with the existing sprites; only re-baking requires chafa. |
| Baked output accidentally embeds ANSI despite `--fg-only` | D2 defense-in-depth: post-process strips ANSI via sed. Unit 4 adds a regression test. |

## Documentation / Operational Notes

- `scripts/bake-sprites.sh --help` is the contributor entry point —
  it should be self-documenting for anyone who wants to re-bake.
- No migration. Users see visibly nicer sprites after the PR merges;
  no action required.
- If a future P7-2 Moebius track ships, it replaces selected
  `sprite.base` arrays with hand-authored content and the bake
  script skips those species (pattern: `.sprite.bake_source == "manual"`
  flag in the species JSON). That's a P7-2 design decision, not a
  P4-4 one — flag here so nobody paints the bake script into a
  corner.

## Sources & References

- Related plan: `docs/plans/2026-04-23-001-feat-p4-3-visible-buddy-plan.md` —
  the pipeline this ticket feeds real art into.
- Related ticket: `docs/roadmap/P4-3-visible-buddy.md`.
- P4-3 PR: #8 (shipped the render pipeline + placeholder sprites).
- Research digest: best-practices-researcher, this session —
  chafa vs alternatives for small-sprite terminal rendering.
- Institutional learning:
  `docs/solutions/developer-experience/claude-code-plugin-transcript-emit-as-trust-boundary-2026-04-21.md`.
- chafa project: https://hpjansson.org/chafa/.
