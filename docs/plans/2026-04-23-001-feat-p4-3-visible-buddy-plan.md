---
title: P4-3 — Visible buddy (stats menu + interact + emoji statusline + installer)
type: feat
status: active
date: 2026-04-23
---

# P4-3 — Visible buddy

## Overview

P4-1 shipped XP and four-axis signals to `buddy.json`. Users can't
see any of it. This plan ships the visibility layer across four
user-facing surfaces:

- **`/buddy:stats`** — a rich menu-style panel: sprite on top,
  full stats + signals as bars, footer lists related commands.
  The primary "where's my buddy" answer.
- **`/buddy:interact`** — a focused moment: sprite + speech bubble
  with one commentary line drawn from the species' banks. A
  lightweight alternative to the full stats menu when the user
  just wants to "check in" on the buddy.
- **Ambient status line** — just the species emoji + name +
  level. Single glyph. No sprite, no bars. Status line is too
  cramped to carry more, and users want an at-a-glance "yep,
  she's there" signal while they code.
- **`/buddy:install-statusline`** — consent-gated helper that
  patches the user's `~/.claude/statusline-command.sh` (the only
  way to get the ambient segment in; plugins cannot register
  `statusLine` themselves per the platform constraint documented
  in our solutions docs).

Design decisions carried forward from the session that planned
this (rarity-based ANSI coloring, rainbow-on-legendary, shiny
overlay, `$NO_COLOR` honor) are locked. **Sprite art content
itself is explicitly deferred** — this plan ships the sprite
*schema* and *render contract*, not the ASCII drawings. Content
passes cleanly in its own ticket once the render pipeline is
proven.

## Problem Frame

Concrete symptom from the post-P4-1 session: the user hatched
Custard the axolotl, her XP accumulated to 98/100 across a
conversation, and there was no way to see any of it without
shelling into `~/.claude/plugins/data/buddy-inline/buddy.json`
with jq. Current `/buddy:stats` prints 4 lines of cramped text
(no emoji, no bars, no signals). `/buddy:interact` exists as a
stub from P0 scaffolding. Ambient status line is unreachable
because plugin `settings.json` does not support the `statusLine`
key (documented in
`docs/solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md`).

Product decisions from the planning session:

- **Primary surface is in-chat**, not ambient. The rich stats
  menu and the interact-speech-bubble view both render into the
  transcript where layout can breathe.
- **Ambient status line is minimal** — species emoji + name +
  level. Fits in 25 chars, survives any terminal width, doesn't
  fight other plugins' status-line segments.
- **Sprite art is an open art problem.** Style and per-species
  identity matter more than we can resolve inside a
  single-session plan. This plan ships the render contract; a
  follow-up content ticket authors the actual sprites.

## Requirements Trace

- **R1.** `/buddy:stats` renders a menu-style panel containing:
  the species sprite (with graceful fallback when missing), the
  name + rarity + species + level header, an XP bar with
  `current / xpForLevel(level)` and a "Lv.N+1 in K" hint, the
  five rarity stats as bars (debugging, patience, chaos, wisdom,
  snark), the four P4-1 signal counters (streak, variety
  toolsUsed, quality ratio, chaos errors + repeats), the token
  balance, and a footer line listing related commands
  (`/buddy:interact`, `/buddy:hatch --confirm`).
- **R2.** `/buddy:interact` renders the species sprite with a
  short speech bubble above or beside it. The line comes from
  the species' `line_banks.PostToolUse.default` or a new
  `line_banks.Interact.default` bank (decision deferred to Unit
  4). The command does NOT mutate state — no XP, no shuffle-bag
  consumption, no rate-limit cost.
- **R3.** Rarity-based ANSI coloring is applied to the sprite +
  name in both `/buddy:stats` and `/buddy:interact`:
  common=grey, uncommon=bright white, rare=bright blue,
  epic=bright magenta, legendary=rainbow per-character cycle.
  Shiny adds `✨` corners + gold accents on top of the rarity
  color. Every surface honors `$NO_COLOR`.
- **R4.** The ambient status-line segment (produced by
  `statusline/buddy-line.sh`) is a single line containing the
  species emoji + name + level, colored per rarity. No sprite,
  no bars. Max 30 chars at `$COLUMNS >= 30`; degrades to just
  emoji + level at narrower widths.
- **R5.** `/buddy:install-statusline` patches the user's
  `~/.claude/statusline-command.sh` to include a call to
  `statusline/buddy-line.sh`. Must: detect an existing custom
  script, show a dry-run diff, ask for consent, take a
  timestamped backup, use guarded-block markers for clean
  uninstall, and support `uninstall` as a reversal subcommand.
- **R6.** Every render surface exits 0 on any internal failure
  (matches the rest of the plugin's discipline). A broken
  species JSON, missing sprite, or corrupt buddy file degrades
  gracefully — the render shows a fallback glyph and a short
  message, never a shell error.
- **R7.** Sprite *content* (specific ASCII drawings per
  species) is out of scope. The plan ships the JSON schema, the
  render contract, and a temporary fallback (species emoji
  centered in a small box) that ships as the visible render
  until the content ticket lands.

## Scope Boundaries

- **No sprite art authored.** The sprite JSON field exists and
  is read by the renderer, but its contents are empty strings
  or omitted on every shipped species until the content pass.
  The fallback (emoji in a box) is what users see.
- **No teen / final forms.** P4-2 owns form transitions. The
  sprite JSON shape leaves room for `teen` and `final` keys
  alongside `base`; this plan only reads `base` and does not
  enforce other keys.
- **No buddy-state mutations.** `/buddy:stats` and
  `/buddy:interact` are read-only — no XP, no signal mutation,
  no shuffle-bag consumption, no cooldown advance.
- **No changes to hook scripts.** Hooks are p95-bounded;
  rendering work stays in `scripts/status.sh` +
  `statusline/buddy-line.sh` + the new helpers.
- **No changes to commentary engine's live-fire behavior.**
  `/buddy:interact` may draw a line from the species bank but
  does so through a read-only helper — it does not go through
  `hook_commentary_select` and does not increment
  `commentsThisSession`.
- **Ambient installer is opt-in.** Never runs without consent.
  Every write gets a timestamped backup.

### Deferred to Separate Tasks

- **Sprite art content** — follow-up ticket (suggested:
  P4-4-sprite-content or merged into P7-2-full-sprites if that
  scope matches). Ships actual kawaii portraits for all 5
  species base forms.
- **Teen and final sprite forms** — P4-2-form-transitions
  ticket. Additive to the sprite JSON shape this plan
  introduces.
- **True-color rainbow gradient** — polish follow-up if
  256-color cycle reads as muddy on some terminals.
- **Interactive stat menu navigation** — `/buddy:stats` is a
  single static render. No arrow-key navigation, no sub-pages.
  If a user wants signals-only or stats-only views, that is a
  future subcommand (`/buddy:stats --signals`, etc.) and out of
  scope here.

## Context & Research

### Relevant Code and Patterns

- `scripts/status.sh` — current `/buddy:stats` render. Lines 29-89
  hold `_status_render_active`. This plan rewrites that function.
  State-machine shape (`NO_BUDDY` / `CORRUPT` / `FUTURE_VERSION`
  sentinels + happy-path renderer) stays.
- `skills/interact/SKILL.md` — current stub from P0 scaffolding.
  This plan rewrites it to dispatch to a real script.
- `statusline/buddy-line.sh` — parallel ambient renderer. Already
  honors `$NO_COLOR` and `$COLUMNS`. Already has a rarity color
  map. This plan simplifies it to emoji-only.
- `scripts/species/*.json` — five species files, each with an
  `emoji` field. This plan adds a `sprite` object with a `base`
  array-of-strings; every file can ship with `base: []` (empty)
  and render via the emoji fallback until the content ticket.
- `skills/stats/SKILL.md` — thin dispatcher, stays thin.
- `scripts/lib/state.sh` — `buddy_load` returns the envelope
  JSON or a sentinel. Unchanged.
- `scripts/lib/evolution.sh` — `xpForLevel(level)` for the XP
  bar's "Lv.N+1 in K" hint. Already shipped in P4-1.
- `scripts/hooks/commentary.sh` — the `_commentary_resolve_bank`
  helper is a good read-only reference for `/buddy:interact`'s
  line draw. The interact script does NOT call
  `hook_commentary_select` (that's the mutating path); it picks
  a line directly without touching session state.

### Institutional Learnings

- [claude-code-plugin-scaffolding-gotchas-2026-04-16](../solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md)
  — plugin `settings.json` only supports `agent` and
  `subagentStatusLine` keys. Forces the installer to patch the
  user's `~/.claude/` rather than auto-registering.
- [claude-code-plugin-data-path-inline-suffix-2026-04-23](../solutions/developer-experience/claude-code-plugin-data-path-inline-suffix-2026-04-23.md)
  — `${CLAUDE_PLUGIN_DATA}` resolves to
  `~/.claude/plugins/data/<plugin>-inline/` under `--plugin-dir`
  loads. The installer's generated snippet must set this
  fallback.
- [claude-code-plugin-transcript-emit-as-trust-boundary-2026-04-21](../solutions/developer-experience/claude-code-plugin-transcript-emit-as-trust-boundary-2026-04-21.md)
  — sanitize with `tr -d '[:cntrl:]'` any buddy name / species
  text before emitting. Same discipline applies to sprite lines
  (user-controllable via hand-edit of `scripts/species/*.json`).
- [bash-jq-fork-collapse-hot-path-2026-04-21](../solutions/best-practices/bash-jq-fork-collapse-hot-path-2026-04-21.md)
  — `/buddy:stats` is NOT hot-path. Per-call latency can be
  higher than hook p95 budget. Readability > fusion for the
  render helpers.
- [claude-code-skill-dispatcher-pattern-2026-04-19](../solutions/developer-experience/claude-code-skill-dispatcher-pattern-2026-04-19.md)
  — SKILL.md as a thin layer that dispatches to a tested bash
  helper. Every new skill in this plan follows this shape.

### External References

None required. Patterns exist locally for every surface.

## Key Technical Decisions

**D1. Sprite JSON field has a `base` array-of-strings, nested under a `sprite` object, on every species file.** Shape: `"sprite": { "base": ["line1", "line2", ...] }`. P4-2 adds `teen` and `final` keys alongside. Empty array `"base": []` is legal and triggers the fallback-to-emoji render. Width is not enforced in the schema — the renderer pads short lines with spaces at render time; long lines (>20 chars) trigger a fallback, not a layout break.

**D2. Sprite content is deferred; every species ships with `"base": []` for now.** The plan does not author ASCII art. The render pipeline ships with a tested fallback: when `base` is empty or malformed, render a 3-line box showing the species emoji centered (`🦎`, `🐉`, `🦉`, `👻`, `🦫`). This is the user-visible buddy-portrait in the launch until the content pass ships real sprites.

**D3. Rendering helpers live in `scripts/lib/render.sh`, shared by `status.sh`, the new `interact.sh`, and `buddy-line.sh`.** Pure-function library. Exposes: `render_rarity_color_open`, `render_rarity_color_close`, `render_bar`, `render_stat_line`, `render_sprite_or_fallback`, `render_speech_bubble`. Each function honors `$NO_COLOR`. Rainbow (legendary) is a 256-color ANSI cycle over 6 colors, re-seeded per render.

**D4. `/buddy:interact` is read-only and does NOT go through the commentary engine.** A new `scripts/interact.sh` loads the buddy, loads the species bank, picks a line (round-robin via a new `session.interact.cursor` field, OR purely random — see deferred question), renders sprite + speech bubble. The existing `hook_commentary_select` is the *mutating* engine used by hooks; `/buddy:interact` is user-initiated and deliberately does not bump cooldowns, budgets, or shuffle-bag state. Keeps the commentary budget sacred for the hook-driven reactions.

**D5. Status-line segment is species emoji + name + level only.** No sprite, no XP bar. Format: `<emoji> <name> Lv.<N>` with rarity color wrapping the whole segment. Degrades to `<emoji> Lv.<N>` under `$COLUMNS < 25`. The sprite is for transcript surfaces where multi-line breathes; the status-line is a single glyph sentence for at-a-glance awareness.

**D6. `/buddy:install-statusline` appends a guarded block to `~/.claude/statusline-command.sh`.** Never replaces. Markers: `# >>> buddy-plugin >>>` / `# <<< buddy-plugin <<<`. If the user has no existing statusline script, installer offers to create a minimal one and wire `~/.claude/settings.json` to point at it. Always takes a timestamped backup. `uninstall` removes the guarded block cleanly.

**D7. Rainbow implementation is ANSI 256-color per-character cycle.** Same as the previous plan iteration. 6 colors (red/yellow/green/cyan/blue/magenta) cycled by character position, re-seeded per render for shimmer. Promote to true-color only if a user reports the 256-color cycle reading as muddy.

**D8. The stats menu's footer line lists related commands, not interactive options.** Example footer: `━ /buddy:interact · /buddy:install-statusline · /buddy:hatch --confirm to reroll ━`. Not interactive (no arrow-key navigation); just discoverability for the other commands. Static, one-line.

**D9. `/buddy:interact` line source: new `line_banks.Interact.default` bank per species, not a shuffle-bag.** The existing `PostToolUse.default` banks are written in the "reacting to tool use" register. Interact is a different moment — user explicitly asking the buddy to say something. Add a new bank name; content pass authors the lines when it authors the sprites. Until content lands, fallback: concatenate the species's `voice` field description as a placeholder (`"<name> looks at you curiously."` for every species). Not exciting, but ships the render path.

**D10. Every render surface exits 0 on failure.** Broken species JSON, missing sprite, unreadable buddy state — the render emits a graceful fallback and exits 0. Installer is the exception: it exits non-zero on failed writes so the user sees the problem rather than a silently broken status line.

**D11. No `/buddy` bare alias in this plan.** Deferred. The Anthropic built-in `/buddy` likely shadows a plugin-registered bare alias, and verifying the resolution order needs a live-session smoke that is its own work item. Users get `/buddy:stats` + `/buddy:interact` + `/buddy:hatch` + `/buddy:reset` + `/buddy:install-statusline` as explicit paths.

## Open Questions

### Resolved During Planning

- **Sprite content in this plan?** No (D2). Schema only, fallback to emoji.
- **Sprite location?** JSON field on each species file (D1).
- **Rainbow impl?** 256-color per-char cycle (D7).
- **Interact line source?** New `Interact.default` bank per species (D9), with voice-field fallback placeholder until content pass.
- **Status-line verbosity?** Emoji + name + level (D5), not sprite.
- **Installer default?** Append to existing `statusline-command.sh` with guarded markers (D6).
- **Bare `/buddy` alias?** Deferred (D11).
- **Does `/buddy:interact` mutate state?** No (D4) — read-only.
- **Does the stats menu have interactive navigation?** No (D8) — static footer listing related commands.

### Deferred to Implementation

- **Interact line rotation:** purely random per invocation, or
  round-robin via a `session.interact.cursor` field? Either is
  acceptable; pure random is simpler and fine for a read-only
  low-frequency surface. Default to random unless a user
  complaint surfaces during content-pass review.
- **Speech bubble layout** (sprite-left + bubble-right vs
  bubble-above + sprite-below). Try both during Unit 4; pick
  whichever reads cleaner in an 80-col terminal.
- **Stats menu footer glyph style** — `━`, `─`, or `═`.
  Cosmetic; pick the one that matches the terminal's general
  box-drawing weight.
- **Fallback box dimensions.** Schema-defined as 3 lines + 20
  chars wide. Specific box-drawing chars picked during
  implementation.

## Output Structure

```
scripts/
  lib/
    render.sh                   # NEW — shared render helpers
  interact.sh                   # NEW — /buddy:interact dispatch target
  install_statusline.sh         # NEW — consent-gated statusline patcher
  status.sh                     # MODIFIED — rewritten menu render
  species/
    *.json                      # MODIFIED — add sprite.base + Interact.default (empty)

statusline/
  buddy-line.sh                 # MODIFIED — simplified emoji+name+level

skills/
  interact/
    SKILL.md                    # MODIFIED — dispatch to scripts/interact.sh
  install-statusline/
    SKILL.md                    # NEW — dispatch to scripts/install_statusline.sh
  stats/
    SKILL.md                    # MODIFIED — description only; dispatcher body unchanged

tests/
  unit/
    species_line_banks.bats     # MODIFIED — assert sprite field + Interact.default shape
    test_render.bats            # NEW — render.sh happy + edge + NO_COLOR
  integration/
    slash.bats                  # MODIFIED — new /buddy:stats menu assertions
    statusline.bats             # MODIFIED — new single-line emoji render
    test_interact.bats          # NEW — /buddy:interact renders sprite + bubble
    test_install_statusline.bats # NEW — installer dry-run + backup + uninstall

docs/
  roadmap/
    P4-3-visible-buddy.md       # NEW — ticket mirror of this plan
```

## Implementation Units

- [ ] **Unit 1: Sprite JSON schema + species-file extension + fallback render contract**

**Goal:** Define the sprite JSON shape on every species file and prove the fallback-to-emoji path. Does not author ASCII art.

**Requirements:** R7, R6.

**Dependencies:** None.

**Files:**
- Modify: `scripts/species/axolotl.json`, `dragon.json`, `owl.json`, `ghost.json`, `capybara.json` — add `"sprite": { "base": [] }` and `"line_banks"."Interact": { "default": [] }` to each.
- Modify: `tests/unit/species_line_banks.bats` — assert the new fields exist with the expected shape; assert empty-array case renders fallback (integration-lite).

**Approach:**
- Every species JSON gets an additive sprite object and a new `Interact.default` empty-array bank. Existing line-bank keys (`PostToolUse`, `PostToolUseFailure`, `Stop`, `LevelUp`) stay untouched.
- Structural test asserts: `sprite.base` is an array of strings; `line_banks.Interact.default` is an array of strings; neither contains tabs, newlines, or control bytes.
- Content (actual ASCII art + real interact lines) is the next ticket. This unit just locks the shape.

**Patterns to follow:**
- Existing line-bank structural pattern in `tests/unit/species_line_banks.bats`.

**Test scenarios:**
- Structural: every species file parses; `sprite.base` is an array (can be empty); `line_banks.Interact.default` is an array (can be empty).
- Structural: no tabs / newlines / control bytes in any sprite string OR interact line, even though both are empty today.
- Integration-lite: mark this unit's completion by shipping a `_sprite_or_fallback` test in Unit 2 that exercises the empty-array path.

**Verification:**
- `tests/unit/species_line_banks.bats` green.
- `jq` parses every species file without error.

---

- [ ] **Unit 2: `scripts/lib/render.sh` — shared render helpers**

**Goal:** Rarity coloring, bar rendering, sprite-or-fallback, and speech-bubble rendering as pure functions. Shared by all visible surfaces.

**Requirements:** R1, R2, R3, R4, R6.

**Dependencies:** Unit 1 (sprite shape).

**Files:**
- Create: `scripts/lib/render.sh`
- Create: `tests/unit/test_render.bats`

**Approach:**
- Public API (all honor `$NO_COLOR`):
  - `render_rarity_color_open <rarity>` / `render_rarity_color_close` — ANSI open/close. Rainbow (legendary) is handled per-character via `render_sprite_or_fallback` and `render_name`; the plain open/close returns a sensible single color for legendary (cycles one of the 6 palette choices on each invocation) so callers that can't do per-char cycling still get *some* color.
  - `render_bar <value> <max> [width=20] [fill="▓"] [empty="░"]` — renders a single bar string; clamps; integer math.
  - `render_stat_line <label> <value> <max> [width=20]` — composes a full padded-label + bar + trailing-value line.
  - `render_sprite_or_fallback <species_json> <rarity> [shiny=0]` — reads `species.sprite.base`; if empty or malformed, renders a 3-line fallback box with the species emoji centered. Applies rarity color per-line (rainbow per-char for legendary). Shiny prepends `✨` glyphs.
  - `render_name <name> <rarity>` — rarity-wrapped name text; rainbow per-char for legendary.
  - `render_speech_bubble <text> <width=40>` — a simple ASCII bubble `  _____________  ` / `<  text goes here  >` / `  '------v------' `. Word-wraps at `<width>`. Trailing pointer (`v`) aligns under the bubble's center.
- Rarity palette matches `scripts/hooks/commentary.sh` and the existing `statusline/buddy-line.sh`:
  common=`\e[90m`, uncommon=`\e[97m`, rare=`\e[94m`, epic=`\e[95m`,
  legendary-cycle=`\e[91m \e[93m \e[92m \e[96m \e[94m \e[95m`.
- Every error path (malformed sprite JSON, bad rarity, divide-by-zero in bars) returns an uncolored fallback and exits 0.

**Execution note:** Test-first is the right posture. Bar rendering + NO_COLOR behavior + fallback-on-malformed are all assertion-friendly. Write one red test per public function before implementing.

**Patterns to follow:**
- Source-guard (`_RENDER_SH_LOADED`) from `scripts/lib/state.sh`.
- Bash 4.1+ floor check from the same.
- `tr -d '[:cntrl:]'` sanitization from `scripts/hooks/commentary.sh:_commentary_format`.
- `statusline/buddy-line.sh` existing rarity color map as the reference palette.

**Test scenarios:**
- Happy path: `render_bar 50 100 20` → 10 `▓` + 10 `░`.
- Happy path: `render_bar 0 100` → all empty; `render_bar 100 100` → all filled; `render_bar 150 100` clamps to all filled; `render_bar -5 100` clamps to all empty.
- Happy path: `render_rarity_color_open common` emits `\e[90m`; close emits `\e[0m`.
- Edge case: `NO_COLOR=1 render_rarity_color_open legendary` emits empty.
- Happy path: `render_sprite_or_fallback <valid_sprite_json> rare 0` wraps each line in `\e[94m...`.
- Happy path: `render_sprite_or_fallback <empty_sprite_json> common 0` emits the 3-line fallback box with the species emoji.
- Edge case: `render_sprite_or_fallback <malformed_sprite_json> common 0` emits fallback, exits 0.
- Happy path: `render_sprite_or_fallback <valid_sprite_json> legendary 0` produces sprite where line 1's characters use at least 2 different ANSI codes (rainbow cycle evidence).
- Happy path: `render_speech_bubble "hi there" 20` returns a 3-line bubble with the text centered.
- Edge case: `render_speech_bubble "" 20` emits empty output and exits 0 (no empty bubble rendered).
- Edge case: `render_speech_bubble` with text longer than width wraps to 2 lines in the bubble.
- Integration: pipe each helper's output to `wc -l` to assert expected line counts.

**Verification:**
- `tests/unit/test_render.bats` green.
- Manual eyeball: run render_sprite_or_fallback for each rarity with an empty-sprite species; fallback boxes look consistent.

---

- [ ] **Unit 3: `/buddy:stats` menu render rewrite**

**Goal:** Replace `scripts/status.sh`'s `_status_render_active` with the full menu panel: sprite + header + XP bar + 5 stat bars + signals strip + command footer.

**Requirements:** R1, R3, R6.

**Dependencies:** Units 1 and 2.

**Files:**
- Modify: `scripts/status.sh`
- Modify: `skills/stats/SKILL.md` — bump the `description:` line to reflect the richer menu output; body stays as a thin dispatcher.
- Modify: `tests/integration/slash.bats` — new menu assertions.

**Approach:**
- Source `scripts/lib/render.sh` from `scripts/status.sh`.
- Pipeline:
  1. `buddy_load` → envelope JSON or sentinel.
  2. If ACTIVE: load species JSON (with path-traversal guard from existing `buddy-line.sh`).
  3. `render_sprite_or_fallback` → multi-line sprite block.
  4. Header line: `render_name` + ` — Rarity species (Lv.N form form)`.
  5. XP bar: `render_stat_line "XP" $xp $(xpForLevel $level) 20` + suffix `  <xp>/<ceiling>   (Lv.<N+1> in <K>)`.
  6. Five rarity-stat bars via `render_stat_line` (debugging, patience, chaos, wisdom, snark).
  7. Signals glyph strip: `🔥 <streak>-day · 🧰 <N> tools · ✓ <s>/<t> edits · ⚡ <repeats> repeats · 🪙 <tokens>`. Missing signals use `// 0` lazy defaults.
  8. Footer line: `━ /buddy:interact · /buddy:install-statusline · /buddy:hatch --confirm to reroll ━` (centered to the card's visible width; pad with `━` to fill).
- Keep `_status_render_repair` (CORRUPT) and FUTURE_VERSION paths unchanged.
- NO_BUDDY path: a short "no buddy yet" message with `/buddy:hatch` hint, unchanged.

**Execution note:** Start with a failing integration test in `slash.bats` that greps the ACTIVE output for the sprite fallback box characters, the `XP` bar label, each of the 5 stat labels, the 🔥/🧰/✓/⚡/🪙 signal glyphs, and the `/buddy:interact` footer link. Then implement until the assertion passes.

**Patterns to follow:**
- Existing `_status_render_active` single-jq `@tsv` extraction — extend it to also pull sprite JSON, signals, and form.
- `statusline/buddy-line.sh` species-file loading + path-traversal guard.

**Test scenarios:**
- Happy path: `_seed_hatch` at seed 42 produces output containing the fallback box (sprite empty today), "Custard", "Common axolotl", "Lv.1", the XP label + bar glyphs, each of the 5 stat labels, the 5 signal glyphs, and the footer containing `/buddy:interact`.
- Edge case: buddy with lazy-init signals (no `.buddy.signals` field) renders with all-zero signal counters, no error.
- Edge case: `NO_COLOR=1` strips every ANSI escape; bars and labels still render.
- Edge case: legendary rarity produces a sprite with 2+ distinct ANSI codes per line (rainbow cycle evidence).
- Edge case: species JSON's sprite.base is empty → fallback box visible; emoji centered.
- Edge case: `COLUMNS=40` → narrower bars, no wrapping.
- Error path: CORRUPT envelope → `_status_render_repair`, unchanged output.
- Error path: FUTURE_VERSION → unchanged message.
- Integration: NO_BUDDY path still shows the hatch hint.

**Verification:**
- `tests/integration/slash.bats` green on new assertions; existing CORRUPT / NO_BUDDY / FUTURE_VERSION tests unchanged.
- Live eyeball: `bash scripts/status.sh` against a hatched buddy renders the menu.

---

- [ ] **Unit 4: `/buddy:interact` — sprite + speech bubble**

**Goal:** A read-only "check in with your buddy" command that renders the sprite alongside a speech bubble line drawn from the species's Interact bank.

**Requirements:** R2, R3, R6.

**Dependencies:** Units 1 and 2.

**Files:**
- Create: `scripts/interact.sh`
- Modify: `skills/interact/SKILL.md` — replace the P0 stub with a thin dispatcher invoking `scripts/interact.sh`.
- Create: `tests/integration/test_interact.bats`

**Approach:**
- `scripts/interact.sh` pipeline:
  1. `buddy_load` → envelope or sentinel.
  2. If NO_BUDDY: short "no buddy yet — `/buddy:hatch`" message, exit 0.
  3. If CORRUPT / FUTURE_VERSION: same short error message `status.sh` uses.
  4. If ACTIVE: load species JSON; pick one line from `species.line_banks.Interact.default`. If bank is empty (which it is today — deferred to content pass), use a deterministic placeholder: `"<name> looks at you curiously."`.
  5. Render:
     ```
         _________________________
        <  first edit feels like   >
         '---------v-------------'
                   |
        <sprite here, rendered via render_sprite_or_fallback>
     ```
     (Speech bubble on top, pointer down, sprite below. Specific layout details — sprite left vs top — picked during implementation per deferred question.)
  6. Print, exit 0. No state mutation.
- Line selection: purely random via `$RANDOM` (not through shuffle-bag state, not round-robin). `/buddy:interact` is user-initiated and cheap; no cooldown, no budget.

**Execution note:** Since sprite content is empty today, the command's user-visible output is the fallback box + speech bubble with the placeholder voice-field line. That is a shippable minimum. The content pass upgrades both the sprite and the line bank in a later ticket.

**Patterns to follow:**
- `skills/stats/SKILL.md` dispatcher shape.
- `scripts/hooks/commentary.sh:_commentary_resolve_bank` for reading a species bank (but without session-state mutation).
- `scripts/status.sh` early-exit pattern for NO_BUDDY / CORRUPT / FUTURE_VERSION.

**Test scenarios:**
- Happy path: ACTIVE buddy → output contains the sprite fallback (or real sprite when content ships), a speech bubble with non-empty text, exit 0.
- Happy path: `_seed_hatch` at seed 42 → placeholder voice line "Custard looks at you curiously." visible in the bubble.
- Edge case: `NO_COLOR=1` strips ANSI; bubble and sprite fallback still render.
- Edge case: species Interact bank non-empty → one of the bank lines appears in the bubble (requires a test fixture species with a populated bank).
- Edge case: species Interact bank empty → placeholder `"<name> looks at you curiously."` appears.
- Error path: NO_BUDDY → hatch hint, exit 0.
- Error path: CORRUPT → repair pointer, exit 0.
- Invariant: running `/buddy:interact` twice does NOT mutate `buddy.json` (byte-compare before/after) AND does NOT mutate any `session-*.json` (no shuffle-bag advance, no `commentsThisSession` bump).

**Verification:**
- `tests/integration/test_interact.bats` green.
- Invariant test (no state mutation) passes.
- Live eyeball: `bash scripts/interact.sh` renders sprite + bubble cleanly.

---

- [ ] **Unit 5: Ambient status-line simplification (`statusline/buddy-line.sh`)**

**Goal:** Reduce the ambient renderer to emoji + name + level, colored per rarity. Shares `render.sh` helpers so visual language matches the stats menu.

**Requirements:** R4, R3, R6.

**Dependencies:** Unit 2.

**Files:**
- Modify: `statusline/buddy-line.sh`
- Modify: `tests/integration/statusline.bats`

**Approach:**
- Source `scripts/lib/render.sh`.
- Remove the XP bar, tokens, and any other segment from the current render.
- New format: `<emoji> <name> Lv.<N>` with the whole segment wrapped in rarity color (rainbow per-char for legendary; applied via `render_name` + emoji concat).
- Width tiers:
  - `$COLUMNS >= 30`: full `<emoji> <name> Lv.<N>`.
  - `$COLUMNS < 30`: `<emoji> Lv.<N>` (drop name).
- Shiny prepends `✨` before the emoji.
- Existing NO_BUDDY / CORRUPT render paths preserved exactly.

**Patterns to follow:**
- Existing `buddy-line.sh` width-tier degradation and `$NO_COLOR` handling.

**Test scenarios:**
- Happy path: ACTIVE buddy at 80 cols → output contains emoji, name, `Lv.1`, no bar, no tokens.
- Edge case: `COLUMNS=25` → output contains emoji and level; name is dropped.
- Edge case: `NO_COLOR=1` strips ANSI on both width tiers.
- Edge case: legendary → rainbow visible (multiple ANSI codes).
- Edge case: shiny=true → `✨` prefix.
- Error path: NO_BUDDY → unchanged hatch prompt.
- Error path: CORRUPT → unchanged repair pointer.

**Verification:**
- `tests/integration/statusline.bats` green.
- Live eyeball under two widths: narrow and wide.

---

- [ ] **Unit 6: `/buddy:install-statusline` helper**

**Goal:** Consent-gated, reversible installer that wires the ambient buddy segment into the user's `~/.claude/statusline-command.sh`.

**Requirements:** R5, R6.

**Dependencies:** Unit 5 (ambient renderer is what gets installed).

**Files:**
- Create: `skills/install-statusline/SKILL.md`
- Create: `scripts/install_statusline.sh`
- Create: `tests/integration/test_install_statusline.bats`

**Approach:**
- `skills/install-statusline/SKILL.md`: thin dispatcher. `disable-model-invocation: true`. Description: "Install (or uninstall) the buddy segment in your Claude Code status line."
- `scripts/install_statusline.sh` subcommands:
  - `install` (default):
    1. Check for existing `~/.claude/statusline-command.sh`.
    2. If exists and already contains the buddy guarded block, report "already installed" and exit 0.
    3. If exists without block: show a dry-run diff (the appended block), ask for consent on stdin (`y/N`), on yes create a timestamped backup and append the block.
    4. If no existing file: offer to create a minimal one with the buddy segment AND offer to update `~/.claude/settings.json`'s `statusLine.command` field to point at it. Ask consent separately for each of those two writes.
  - `uninstall`: find the guarded block markers and remove the block. Write a new backup first. If the resulting file is empty (installer was the only thing in it), offer to remove it entirely.
  - `--dry-run` flag: print the diff, do not write.
- Guarded block content:
  ```
  # >>> buddy-plugin >>> (managed by /buddy:install-statusline)
  _BUDDY_ROOT="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/cache/buddy/current}"
  _BUDDY_DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/buddy-inline}"
  if [ -x "$_BUDDY_ROOT/statusline/buddy-line.sh" ]; then
    buddy_part=$(CLAUDE_PLUGIN_DATA="$_BUDDY_DATA" bash "$_BUDDY_ROOT/statusline/buddy-line.sh" </dev/null 2>/dev/null)
    [ -n "$buddy_part" ] && printf ' %s' "$buddy_part"
  fi
  # <<< buddy-plugin <<<
  ```
- Backup path: `~/.claude/statusline-command.sh.buddy-bak.<YYYYmmddTHHMMSSZ>`.
- Installer honors `$NO_COLOR` for its own diff output.
- All failure paths log to stderr (surfaced via the SKILL.md relay), exit non-zero. A failed install never leaves a partial write.

**Execution note:** Start with detection + diff generation tests against a fixture `$HOME/.claude/` directory override (`$HOME` override is the standard trick for this kind of test). Consent prompt comes last — the rest of the logic is testable without stdin interaction.

**Patterns to follow:**
- `scripts/reset.sh` atomic-delete-with-marker dance.
- `scripts/hatch.sh` subcommand dispatch style.
- Fixture-dir override env-var pattern from `scripts/hooks/commentary.sh` (`BUDDY_SPECIES_DIR`).

**Test scenarios:**
- Happy path (append): existing `statusline-command.sh` without buddy block → `install --dry-run` shows the block; `install` with consent "y" writes the block and a timestamped backup.
- Happy path (create): no existing `statusline-command.sh` → installer offers to create one; consent "y" creates minimal script AND updates `~/.claude/settings.json` to point at it.
- Idempotent: running `install` twice → second run sees existing block, reports "already installed", no-op.
- Reversal: `install` then `uninstall` → file byte-identical to pre-install state (verify via fingerprint).
- No consent: user answers "n" → no writes, exit 0 with a clear message.
- `--dry-run`: no writes, diff printed to stdout.
- Edge case: `NO_COLOR=1` → diff renders without ANSI.
- Error path: target file read-only → installer logs to stderr, exits 1, no partial write.
- Error path: malformed `~/.claude/settings.json` → installer refuses to touch settings, surfaces the parse error, exits 1.
- Integration: full round-trip test with a fixture `$HOME`.

**Verification:**
- `tests/integration/test_install_statusline.bats` green.
- Manual: run `/buddy:install-statusline` in a real Claude Code session; observe the ambient buddy segment after the next status-line refresh; run `/buddy:install-statusline uninstall` and confirm removal.

## System-Wide Impact

- **Interaction graph:** Four user-facing skills dispatch to four scripts, three of which call `scripts/lib/render.sh`. No hook changes; no state mutations in any render surface. `/buddy:install-statusline` is the only path that touches `~/.claude/` user state, and only with explicit consent.
- **Error propagation:** Every render exits 0 on failure (graceful degrade). Installer exits non-zero on failed writes (intentional — wants user visibility).
- **State lifecycle risks:** `scripts/lib/render.sh` is pure. `scripts/interact.sh` is read-only. Installer's backup files accumulate in `~/.claude/` and are user-owned; document in help text.
- **API surface parity:** `/buddy:stats`, `/buddy:interact`, and the ambient statusline all share the same rarity color palette and sprite-or-fallback logic via `render.sh`. Visual consistency by construction.
- **Integration coverage:** Installer's full install → uninstall → install round-trip can only be proven by writing actual files. The integration test does exactly that against a fixture `$HOME`.
- **Unchanged invariants:** Hook scripts, commentary engine (hook-driven), `buddy_save`/`buddy_load`, signals accumulation, perf harness. Existing P3-2 and P4-1 tests stay green.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Sprite content pass ships and breaks an assumption baked into `render_sprite_or_fallback` (e.g., every sprite is 7 lines tall, or every line is exactly 20 chars) | `render_sprite_or_fallback` does not assume fixed height or width. Short lines are padded at render time; tall sprites are truncated to a configurable max (default 10); empty arrays use the fallback box. Unit 2 tests cover each case. |
| Rainbow ANSI cycle on legendary looks muddy on low-contrast terminals | 256-color palette (6 bright colors) is chosen for contrast. If a user complaint surfaces, promote to true-color in a polish follow-up. |
| `/buddy:install-statusline` corrupts the user's existing script | Timestamped backup before every write; guarded markers for clean removal; dry-run preview; uninstall restores from backup. Fixture-based integration test covers the full round trip. |
| `/buddy:interact` accidentally mutates session state via a wrong import | Explicit invariant test: `buddy.json` and all `session-*.json` files are byte-identical before and after the command. |
| Users parse the old `/buddy:stats` output and we break their pipeline | Old output was 4 lines of text; no reasonable pipeline parses it. Document the format change in the PR description; the output shape is intentionally not a stable contract. |
| Status-line segment conflicts with the user's existing layout or color scheme | Installer appends rather than replaces; segments are space-separated; `$NO_COLOR` still works. Users who want the buddy elsewhere in their status line can manually move the guarded block. |
| Empty Interact bank + placeholder voice line reads as thin on ship day | Unit 4 ships with the placeholder; content pass follows up with real lines. Known and acceptable for this plan's scope. |

## Documentation / Operational Notes

- README gets a "Viewing your buddy" section after Unit 3 lands — how to run `/buddy:stats`, what the bars mean, the relationship to `/buddy:interact`, and a pointer to `/buddy:install-statusline` for ambient display.
- Installer prints a one-liner on successful install or uninstall so the user knows the next step.
- No migration. All changes are additive to user state; removable via `uninstall`.
- Sprite content ticket (follow-up, suggested P4-4) is referenced in the roadmap ticket's Notes section so the handoff is visible.

## Sources & References

- Related plan: [docs/plans/2026-04-21-001-feat-p4-1-xp-signals-plan.md](./2026-04-21-001-feat-p4-1-xp-signals-plan.md) — the signals this card surfaces.
- Related plan: [docs/plans/2026-04-22-001-perf-test-suite-speed-plan.md](./2026-04-22-001-perf-test-suite-speed-plan.md) — tier split the new test files fit into.
- Related ticket: [docs/roadmap/P4-2-form-transitions.md](../roadmap/P4-2-form-transitions.md) — teen/final forms extend the sprite JSON shape.
- Solutions:
  - [claude-code-plugin-scaffolding-gotchas-2026-04-16.md](../solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md)
  - [claude-code-plugin-data-path-inline-suffix-2026-04-23.md](../solutions/developer-experience/claude-code-plugin-data-path-inline-suffix-2026-04-23.md)
  - [claude-code-plugin-transcript-emit-as-trust-boundary-2026-04-21.md](../solutions/developer-experience/claude-code-plugin-transcript-emit-as-trust-boundary-2026-04-21.md)
  - [bash-jq-fork-collapse-hot-path-2026-04-21.md](../solutions/best-practices/bash-jq-fork-collapse-hot-path-2026-04-21.md)
  - [claude-code-skill-dispatcher-pattern-2026-04-19.md](../solutions/developer-experience/claude-code-skill-dispatcher-pattern-2026-04-19.md)
- Product decisions: conversation on feat/p4-1-xp-signals post-merge (menu framing for stats, speech bubble for interact, emoji-only status line, installer-over-auto-register, sprite content deferred, rarity coloring + rainbow-on-legendary, `$NO_COLOR` honor across surfaces).
