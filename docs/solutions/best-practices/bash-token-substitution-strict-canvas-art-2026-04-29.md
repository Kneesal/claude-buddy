---
title: Strict-canvas + {TOKEN} substitution for layered ASCII art
date: 2026-04-29
category: best-practices
module: scripts/lib/render.sh
problem_type: best_practice
component: tooling
severity: medium
applies_when:
  - Building per-character or per-row ASCII/Unicode art with per-instance variation
  - Mixing static template lines with runtime-substituted single-character tokens (eyes, mouths, accessories)
  - Stacking optional accessories (hats, frames, badges) above or beside a base sprite
  - Validating the rendered width of a templated line whose stored width is larger than its rendered width
tags:
  - bash
  - ascii-art
  - unicode-art
  - sprite
  - composition
  - parameter-substitution
  - column-grid
  - render-pipeline
---

# Strict-canvas + {TOKEN} substitution for layered ASCII art

## Context

Building a per-creature sprite system for the claude-buddy plugin surfaced
two coupled problems that any small ASCII-art renderer hits eventually:

1. **Per-instance variation without re-baking art.** Two same-species
   buddies should look distinct (different eye glyph, different optional
   hat) without storing 6×14 separate sprite variants per species.
2. **Visible alignment.** Hand-typed art at 12-char width is jank by
   default — every row picks its own indentation, eyes drift relative
   to the mouth, the chin centerpoint wobbles. The art looks "off"
   even when it's technically rendering.

The pattern that solved both: store sprite templates with `{TOKEN}`
markers on a strict column grid; substitute single-character tokens at
render time via shell parameter expansion; compose optional rows
(hats / overlays / effects) above the base sprite by emitting one extra
line.

## Guidance

### Strict column grid

Pick a fixed canvas width and freeze the column position of every
silhouette feature across the species roster. For 12-char-wide buddies:

```
col 1-2:  leading whitespace (always)
col 3:    head silhouette LEFT edge (paren / horn / dome point)
col 5:    LEFT EYE — the {EYE} token
col 7:    MOUTH center
col 9:    RIGHT EYE — the {EYE} token
col 11:   head silhouette RIGHT edge
col 12:   trailing whitespace
```

Every row's RENDERED width (after token substitution) is exactly 12.
Every species' eye row uses parens at cols 3 and 11. Every species'
mouth element sits at col 7. Top decorations (gills / horns / dome)
span cols 3-11. Chin can taper to cols 4-10.

The grid is the alignment guarantee. As long as you stay on it,
species look like they belong to the same family even when the silhouette
shapes differ wildly.

### {TOKEN} substitution

Store sprite templates with literal `{TOKEN}` markers. Substitute at
render time via bash parameter expansion (no sed fork):

```bash
# template line: "  ( {EYE}   {EYE} ) "
# eye glyph:     "o"
rendered="${line//\{EYE\}/$eye}"
# rendered:      "  ( o   o ) "
```

The `{EYE}` marker is 5 characters stored, 1 character rendered. Width
validators must measure post-substitution length — replace
`{EYE}` with a 1-char placeholder (`X`, `·`) before counting.

Composition extends naturally:

```bash
rendered="${line//\{EYE\}/$eye}"
rendered="${rendered//\{MOUTH\}/$mouth}"
rendered="${rendered//\{ACCESSORY\}/$accessory}"
```

### Bash 5.0+ has a sed-like trap in pattern substitution

In bash 5.0 and later, the replacement string in `${var//pat/repl}`
treats `&` as "the matched pattern" — same semantic as `sed
's/pat/&/'`. If your token pool ever contains `&` as a substituted
glyph, the substitution silently fails: the marker stays in the output
because `&` got expanded to the matched pattern (`{EYE}`) and re-inserted.

The escape is explicit `\&`:

```bash
local eye_safe="${eye//&/\\&}"
rendered="${line//\{EYE\}/$eye_safe}"
```

Apply the escape unconditionally — it's a no-op for non-`&` glyphs and
makes the substitution safe for arbitrary single-char inputs. This is
the kind of bug that surfaces only when a contributor adds a new glyph
to a pool months later, so build it in once and forget.

The bug doesn't reproduce on bash < 5.0, so it can sit unnoticed on any
developer's older-bash machine until it lands on someone running modern
bash.

### Optional accessory rows compose by prepending one line

Don't reserve a blank row for "where the hat would go" — it wastes
vertical space when there's no hat and the buddy looks like it's
floating. Emit the accessory row only when an accessory resolves:

```bash
if [[ -n "$hat_name" ]]; then
  hat_row="$(_lookup_hat "$hat_name")"
  [[ -n "$hat_row" ]] && printf '%s\n' "$hat_row"
fi
# Then emit the base sprite rows
```

Rendered height becomes: 4 rows for hatless, 5 rows when a hat resolves.
The visible height delta IS the "this one's special" signal — readers
notice the extra line above the head before they parse the glyph.

### Per-buddy randomization at hatch, not at render

Roll the token (eye glyph, accessory name) once at hatch time and store
it on the buddy state (`.buddy.cosmetics.eye`, `.buddy.cosmetics.hat`).
Render reads that field. Two reasons:

- **Stability across renders.** A buddy whose eye glyph rerolls every
  render doesn't feel like a creature — it feels like a slot machine.
- **Reroll semantics.** When the user pays to reroll their buddy
  identity, cosmetics roll too as part of the new identity.

The roll uses a uniform pick from the species' `eye_pool` array (and
the shared accessory pool). Rarity-gating belongs at the roll, not at
render: e.g., commons never roll a hat (40% chance for non-common, 0%
for common). Keep the rarity signal crisp by gating optional rows.

## Why This Matters

The composition + grid combo has compound benefits:

- **Variety per species scales multiplicatively.** Five species ×
  six eye glyphs × fourteen hat states = 420 distinct possible looks
  on a 12-char canvas. None of them required additional baked sprite
  variants.
- **Alignment is structural, not aesthetic.** "Looks aligned" became a
  validator test (every row's rendered length == 12, eye markers at
  fixed columns) rather than a property someone has to eyeball.
- **Layered changes don't compound risk.** Swapping a hat sprite, adding
  a new eye glyph to a species pool, or extending the canvas to a 6th
  row are all additive operations that don't touch the base templates.
- **One renderer, many surfaces.** The same `render_sprite_or_fallback`
  function powers `/buddy:stats`, `/buddy:interact`, and the future
  reactive-frames work — composition stays in the render layer, not
  scattered across callers.

## When to Apply

Use this pattern when:

- Your art has 3+ instances of the same template with single-character
  variation per instance (the eye-glyph case).
- You want optional accessories that may or may not appear (the hat case)
  without paying a per-state-combination storage cost.
- You're working on a fixed character canvas and alignment quality
  matters.

Skip when:

- You have one or two static sprites and no variation (just hardcode).
- Your canvas is too small for tokens to fit (sub-7-char width — the
  marker overhead crowds the glyph budget).
- You want pixel-density art rather than character art (use chafa or a
  PNG bake instead — see
  `docs/solutions/developer-experience/chafa-sextant-sprite-bake-pipeline-2026-04-23.md`).

## Examples

**Storage (`scripts/species/axolotl.json`):**

```json
{
  "sprite": {
    "base": [
      "  <vvv-vvv> ",
      "  ( {EYE}   {EYE} ) ",
      "  (   u   ) ",
      "   v_v_v_v  "
    ]
  },
  "eye_pool": ["o", "*", "u", "^", "O", "v"]
}
```

**Render (excerpt from `scripts/lib/render.sh`):**

```bash
local eye_safe="${eye//&/\\&}"
local count=0 line rendered
while IFS= read -r line; do
  (( count >= 10 )) && break
  rendered="${line//\{EYE\}/$eye_safe}"
  printf '%s\n' "$rendered"
  count=$(( count + 1 ))
done <<< "$sprite_lines"
```

**Width validator (substitutes the marker before counting):**

```python
for i, line in enumerate(sys.stdin.read().splitlines(), 1):
    rendered = line.replace("{EYE}", "X")  # 1-char eye stand-in
    if len(rendered) > 12:
        print(f"line {i}: {len(rendered)} chars")
```

## See Also

- `docs/solutions/best-practices/terminal-render-safety-three-traps-2026-04-23.md`
  — the per-character ANSI-rainbow byte-slice fix from the same render
  layer; combine with this doc for the full safety + composition story.
- `docs/solutions/developer-experience/chafa-sextant-sprite-bake-pipeline-2026-04-23.md`
  — when this pattern stops scaling and you want raster-derived art
  instead.
- `scripts/lib/render.sh` — the canonical implementation of
  `render_sprite_or_fallback` with `{EYE}` substitution and accessory
  composition.
