---
title: chafa sextant bake pipeline for plugin sprite content
date: 2026-04-23
category: developer-experience
module: scripts/bake-sprites.sh
problem_type: developer_experience
component: tooling
severity: medium
applies_when:
  - A plugin wants higher-fidelity terminal art than hand-typed ASCII without adding a runtime dependency on image-rendering tools
  - Committing pre-rendered Unicode art to a repo and rendering at runtime via `cat` / `printf`
  - Separating contributor-time tooling (PIL, chafa) from runtime tooling (bash, jq only)
  - Mixing any kind of baked terminal output with an existing per-rarity / per-theme color layer
tags:
  - chafa
  - terminal-art
  - sextant
  - unicode-block
  - ansi
  - pixel-art
  - contributor-time
  - runtime-separation
  - bake-pipeline
  - claude-code-plugin
  - deterministic-output
---

# chafa sextant bake pipeline for plugin sprite content

## Context

P4-3 of claude-buddy shipped a sprite render pipeline that read an array of
strings from `scripts/species/*.json:.sprite.base` and wrapped each line in
rarity color. Initial content was five lines of hand-typed ASCII per species
— functional but visibly low-effort. P4-4 needed higher-fidelity portraits
without:

- Adding a runtime dependency (end users wouldn't install chafa).
- Shipping binary art that fights our rarity-color layer.
- Losing the legendary rainbow or `$NO_COLOR` paths.
- Losing reproducibility — the committed art needs to diff cleanly.

The pipeline that solved all four constraints: bake at contributor-time
from source PNGs into Unicode-sextant silhouettes, strip all ANSI, commit
Unicode-only, apply rarity color at render time as before.

## Guidance

**End-to-end pipeline:**

```
assets/species/<name>.png                contributor-authored pixel art (PIL, CC0)
       ↓
python3 scripts/art/source-sprites.py    deterministic drawer (committed script)
       ↓
assets/species/<name>.png                (committed alongside the script)
       ↓
bash scripts/bake-sprites.sh             chafa wrapper (contributor-time only)
       ↓
chafa --size=14x10 --symbols=sextant \
      --fg-only --colors=256 \
      --format=symbols --dither=none \
      --color-space=din99d <src>
       ↓
sed -E 's/\x1b\[[?0-9;]*[A-Za-z]//g'     strip ANSI (defense in depth)
       ↓
jq --argjson sprite "$arr" \
   '.sprite.base = $sprite' <json> | mv  atomic write into species JSON
       ↓
scripts/species/<name>.json:.sprite.base Unicode-only strings, committed
       ↓  (runtime, zero deps)
scripts/lib/render.sh _render_color_line rarity color applied per line
```

**Flag decisions (locked for reproducibility):**

- `--size=14x10` — matches the sprite contract (≤10 lines, ≤20 chars). A
  14-char-wide sextant canvas gives ~28×30 effective "pixels" — ample
  for small portraits.
- `--symbols=sextant` — 2×3 sub-pixel packing via Unicode U+1FB00 range.
  Available in any terminal with a decent Unicode font. Massive fidelity
  win over half-blocks.
- `--fg-only --colors=256` — the critical pair. `--fg-only` tells chafa
  to leave background cells untouched (honors source PNG transparency);
  `--colors=256` keeps fg color information so transparency is preserved
  correctly. Then the downstream sed strips the colors, leaving Unicode
  glyphs only.
- `--colors=none` does **not** do what you want: chafa fills transparent
  areas with "sparse" sextant glyphs like U+1FB03, producing speckled
  backgrounds instead of proper whitespace.
- `--format=symbols` — layout mode (no fancy framing).
- `--dither=none --color-space=din99d` — deterministic output across chafa
  invocations. Essential for idempotent re-bakes.

**Validation at bake time:**

- Line count ≤ 10 (render.sh truncates beyond this anyway).
- Width ≤ 20 **codepoints** per line — bash `${#s}` is byte-count and
  over-reports 4-byte sextant glyphs by 4×. Use `python3`:

  ```bash
  overflow="$(printf '%s\n' "$content" | python3 -c '
  import sys
  for i, line in enumerate(sys.stdin.read().splitlines(), 1):
      if len(line) > 20:
          print(f"{i}: {len(line)}")
  ')"
  ```

- No embedded ANSI escape (defense in depth post-strip):
  `grep -q $'\x1b'`.
- No tab or CR (use `LC_ALL=C grep -q $'[\t\r]'` — don't use `grep -P`,
  it's not portable to BSD grep / macOS default).
- **Non-whitespace content** — `[[ -z "${content//[$' \t\n']/}" ]]`. A
  fully-transparent source PNG yields rows of spaces that pass every
  other validator; without this check, the committed sprite renders as
  an invisible buddy. This is the one validation users feel.

**Idempotence:**

Re-running the bake against an unchanged source PNG must produce a
byte-identical JSON diff. Pin with:

```bash
before="$(md5sum scripts/species/<name>.json | awk '{print $1}')"
bash scripts/bake-sprites.sh
after="$(md5sum scripts/species/<name>.json | awk '{print $1}')"
[ "$before" = "$after" ]
```

Non-idempotence almost always means chafa version drift (pin the version
in the bake script's header and `--version`-check) or a non-deterministic
source PNG generator.

**Contributor-time vs runtime-time boundary:**

- `scripts/art/source-sprites.py` + `scripts/bake-sprites.sh` + `assets/`
  are contributor-time only. They require chafa + python3 + pillow.
- `scripts/lib/render.sh` + `scripts/species/*.json` + everything in
  `statusline/` are runtime. They require bash + jq only.
- The commit is the seam. End users pull the repo and get the baked
  output; they never run the bake.

## Why This Matters

The pipeline lets you ship:

- **Higher fidelity art** — 28×30 effective pixels vs 14 chars of ASCII
  is a 60× information density delta.
- **Zero runtime dependency on image tooling** — `cat <file>` is the
  render path. Works on any Unicode-capable terminal.
- **Clean layer separation** — baked art is monochrome Unicode; rarity
  color stays in `render.sh` so you don't have to re-bake every time
  you tweak the rarity palette.
- **Reproducible diffs** — updating a source PNG produces a predictable,
  reviewable diff in the committed JSON.
- **Hackability** — a contributor can replace the baked output manually
  (e.g., hand-polish one species, commit the result) and the pipeline
  still works. The bake overwrites, but if a contributor doesn't re-run
  it, their polish survives.

## When to Apply

Use this pipeline when:

- You have 3+ pre-rendered pieces of terminal art (sprites, icons,
  badges, headers).
- Hand-typed ASCII art looks thin and you want an upgrade without
  runtime cost.
- You already have a source-of-truth artistic tool (PIL, Aseprite,
  Inkscape→PNG) and want to turn its output into committable terminal
  text.

Skip this pipeline when:

- You have 1-2 pieces of art that a human can type by hand.
- Your art needs animation, in which case read the P4-5 plan
  (`docs/plans/2026-04-23-003-feat-p4-5-reactive-sprites-plan.md`)
  for the spike-before-animate approach.
- You need cross-rendering-protocol support (Kitty graphics, Sixel,
  iTerm2 image) — those are a different engineering problem; use
  `viu` or `timg` instead.

## Examples

**Minimal bake script skeleton:**

```bash
CHAFA_FLAGS=(
  --size=14x10
  --symbols=sextant
  --fg-only
  --colors=256
  --format=symbols
  --dither=none
  --color-space=din99d
)

_bake_one() {
  local src="$1"
  chafa "${CHAFA_FLAGS[@]}" "$src" \
    | sed -E $'s/\x1b\\[[?0-9;]*[A-Za-z]//g' \
    | awk 'NR==1 && /^[[:space:]]*$/ {next} {print}'
}

_validate() {
  local name="$1" content="$2"
  # line count
  (( $(printf '%s\n' "$content" | wc -l) <= 10 )) || return 1
  # width (codepoint-accurate)
  ! printf '%s\n' "$content" | python3 -c 'import sys; sys.exit(any(len(l) > 20 for l in sys.stdin.read().splitlines()))' || return 1
  # no ANSI
  ! printf '%s' "$content" | grep -q $'\x1b' || return 1
  # non-whitespace
  [[ -n "${content//[$' \t\n']/}" ]] || return 1
}

_write_back() {
  local json="$1" content="$2"
  local arr; arr="$(printf '%s\n' "$content" | jq -R -s 'split("\n") | map(select(length > 0))')"
  local tmp; tmp="$(mktemp "$json.XXXXXX")" || return 1
  jq --argjson sprite "$arr" '.sprite.base = $sprite' "$json" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$json"
}
```

**Source-side drawer (deterministic PIL):**

```python
from PIL import Image, ImageDraw

def draw_species(name: str) -> Image.Image:
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # ... deliberate pixel placement, no randomness, no PIL defaults
    #     that vary across versions
    return img

if __name__ == "__main__":
    # sorted() for stable iteration order across Python implementations
    for name in sorted(SPECIES):
        img = draw_species(name)
        img.save(f"assets/species/{name}.png", format="PNG", optimize=True)
```

**Attribution file (first binary assets in the repo establishes precedent):**

```markdown
# Species Sprite Attribution

All PNGs here are released into the public domain under CC0 1.0.
Generated deterministically by `scripts/art/source-sprites.py`.

| File | Source | License | Date | Author |
|---|---|---|---|---|
| `axolotl.png` | `scripts/art/source-sprites.py::draw_axolotl` | CC0 | 2026-04-23 | contributors |
...
```

## Known Gotchas

- **Locale-sensitive width check**: `python3 -c 'len(line)'` counts
  codepoints correctly in UTF-8 mode (Python 3.7+), but a CI container
  with `PYTHONUTF8=0 LC_ALL=C` loses that and over-reports by 4×.
  Require `en_US.UTF-8` / `C.UTF-8` / PYTHONUTF8=1 on build boxes.
- **chafa version drift**: output differs across chafa major versions.
  Record the tested version in the bake script header and check
  `chafa --version` at startup.
- **PIL version drift**: `optimize=True` on `Image.save` can produce
  byte-different PNGs across Pillow major versions. Pin Pillow in
  contributor setup docs or accept PNG-byte drift while trusting the
  chafa-layer diff.
- **Symlinked source PNG**: chafa follows it without complaint; if
  the symlink target is outside the repo, you bake out-of-tree content.
  Validate source paths if this matters.

## See Also

- `docs/solutions/developer-experience/claude-code-plugin-transcript-emit-as-trust-boundary-2026-04-21.md`
  — the control-byte strip applied at render time composes with this
  pipeline (baked sprite is Unicode-only, but buddy.name isn't).
- `docs/solutions/best-practices/bash-jq-fork-collapse-hot-path-2026-04-21.md`
  — the bake is NOT hot-path, so readability > fork budget here.
- `scripts/bake-sprites.sh`, `scripts/art/source-sprites.py`,
  `assets/species/ATTRIBUTION.md`, `tests/integration/test_bake_sprites.bats`
  — the canonical implementation in this repo.
