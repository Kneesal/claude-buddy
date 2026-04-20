---
id: P7-2
title: ASCII portraits in chat output + shinies
phase: P7
status: todo
depends_on: [P1-3, P2, P7-1]
origin_plan: docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md
---

# P7-2 — Portraits

## Goal

Render the buddy as a 5-line × 12-char static ASCII portrait in slash-command chat output, for all 18 species × each of their forms. Shiny variants (~1/256 post-rarity) get rainbow ANSI treatment on the portrait plus a sparkle tell in the status line.

Portraits surface when the user asks for them (via slash commands) or at ceremony moments (hatch success, evolution). The status line stays the single-line ambient format from P2 — it does not grow a sprite.

## Tasks

- [ ] **Design portraits for 18 species × ≥ 2 forms each = 36+ portrait sets.** Each portrait is a single static frame:
  - [ ] 5 lines tall × 12 chars wide.
  - [ ] Pure ASCII (no Unicode box-drawing — safer across terminal fonts).
  - [ ] Rarity-agnostic (color framing comes from ANSI applied outside the portrait, not inside the glyphs).
- [ ] Store portraits in `scripts/species/<name>.json` under `portraits.<form>: "<5-line string>"` (newline-delimited; no frame array since there's no animation).
- [ ] Create `scripts/lib/portrait.sh` exposing `render_portrait <species> <form> <rarity> <shiny>` that prints the portrait plus a rarity-colored frame (or rainbow if shiny).
- [ ] **Wire portraits into chat output:**
  - [ ] `scripts/hatch.sh` — render on first-hatch success and on reroll success (celebrates the new buddy).
  - [ ] `scripts/status.sh` — render at the top of `/buddy:stats` output (shows the buddy the user just asked about).
  - [ ] Evolution ceremony (P4-2 handoff — when P4-2 fires a form-transition event, render the new form's portrait one-shot in chat).
- [ ] **Status line stays single-line.** `refreshInterval: 5` is permanent — no animation loop. The status-line change for shinies is a subtle sparkle emoji prepended to the rarity segment (`✨ 🦎 Pip (Legendary Axolotl · Lv.3) · 4 🪙`).
- [ ] **Shiny variants:**
  - [ ] `roll_buddy` / `roll_stats` already stub `shiny: false` in P1-2. P7-2 rolls `shiny = (rand % 256 == 0)` post-rarity and sets the flag.
  - [ ] Shiny portrait cycles ANSI colors by row (row 1 red, row 2 yellow, row 3 green, row 4 blue, row 5 magenta) — not per-frame animation, just a rainbow frame that stays put.
  - [ ] Shiny hatch triggers the milestone bonus from P5 (+5 tokens, once per buddy).
  - [ ] Status-line sparkle emoji appears whenever `.buddy.shiny == true`.
- [ ] **Graceful degradation:**
  - [ ] If terminal width < 12 cols (effectively never in practice, but be defensive), skip the portrait and render prose-only.
  - [ ] `NO_COLOR=1` → render the portrait without ANSI framing (plain monospace block).
- [ ] **Tests:**
  - [ ] `tests/portrait.bats` — each species × each form renders a 5-line × 12-char block, no ANSI bleed past the final reset.
  - [ ] Shiny rendering: rainbow row colors land in order, reset is emitted, no stray codes leak into subsequent output.
  - [ ] `render_portrait` with `NO_COLOR=1` produces plain ASCII only.
  - [ ] Integration: `/buddy:stats` output contains the portrait block above the prose stats.
  - [ ] Integration: `/buddy:hatch` success output contains the portrait of the rolled species/form.

## Exit criteria

- All 18 species × their forms have a portrait authored.
- `/buddy:stats` and `/buddy:hatch` chat output leads with the portrait; status line stays unchanged from P2.
- Shinies are real rare treats — visible both in the chat portrait (rainbow) and subtly in the status line (sparkle).
- No regression in status-line p95 latency (still < 50ms; no new work on that code path).

## Notes

- **Re-scoped 2026-04-20.** This ticket originally targeted the status line as the portrait surface, with 3-frame animation at `refreshInterval: 1`. It was re-scoped to chat-output portraits for three reasons:
  1. The status line is vertical real estate the terminal is stingy with; a permanent 5-line allocation is costly.
  2. Animation via `refreshInterval: 1` is a poll loop — every frame re-runs the script and re-reads state. Constant background cost.
  3. Chat output is unbounded, zero-recurring-cost, and surfaces the buddy at the moment the user asked. See the umbrella plan's P7-2 design-amendment block for the full rationale.
- Portrait design is content-heavy. Consider a dedicated `/ce:work` session for portraits alone, or accept community PRs against a published style guide. 36+ portraits is a lot of pixels to push.
- Portrait dimensions (5×12, single frame) borrow the spatial format from Anthropic's `/buddy` (per [claudefa.st](https://claudefa.st/blog/guide/mechanics/claude-buddy)) but drop the animation axis — we don't need it when portraits render once per command invocation instead of looping in the status line.
- Shiny rate (1/256) is the starting point. Revisit based on real-usage data — might tune up or down, or add a milestone so users know they rolled one.
- ANSI reset hygiene: always emit `\033[0m` at portrait end, otherwise rainbow bleeds into subsequent chat output.
- The status-line sparkle emoji is additive to the existing emoji (not a replacement) — so a shiny legendary axolotl reads `✨ 🦎 Pip ...` rather than just `✨ Pip ...`. Two emoji in a row is fine width-wise; if a future reviewer wants a single-character rarity indicator (e.g., `★` for shinies) that's a deferred polish.
