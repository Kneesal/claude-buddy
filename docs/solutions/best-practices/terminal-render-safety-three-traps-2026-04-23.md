---
title: Three terminal-render safety traps caught by paired ce:review rounds
date: 2026-04-23
category: best-practices
module: scripts/lib/render.sh
problem_type: best_practice
component: tooling
severity: high
applies_when:
  - Any bash renderer that wraps user-controllable strings in ANSI escapes
  - Any code that does per-character ANSI coloring via `${var:i:1}` byte-indexing
  - Any pipeline that writes content into committed files where "non-empty" ≠ "non-whitespace"
  - Any plugin renderer that already trusts its inputs from one layer but receives them from another
tags:
  - ansi
  - unicode
  - utf8
  - byte-vs-codepoint
  - control-bytes
  - transcript-safety
  - whitespace-content
  - rainbow-coloring
  - render-library
  - claude-code-plugin
---

# Three terminal-render safety traps caught by paired ce:review rounds

## Context

The P4-3 + P4-4 review rounds on claude-buddy surfaced three distinct render-
safety bugs that a naive bash renderer will hit if it isn't deliberately
defended. All three are "silently wrong output" bugs — no crash, no error,
no failing test — where the renderer produces something that looks like it
works until you check closely.

Documenting them together because they travel in a pack: any time you're
building a renderer that composes user-controllable content with controlled
ANSI decoration, you need all three defenses.

## Guidance

### Trap 1: Per-character ANSI rainbow byte-slices UTF-8 codepoints

**The setup.** Legendary-rarity sprites in render.sh were supposed to cycle
6 rainbow colors per character via:

```bash
local len=${#text}
while (( i < len )); do
  ch="${text:$i:1}"
  printf '%s%s%s' "$(_rainbow_at $(( seed + i )))" "$ch" "$_RESET"
  i=$(( i + 1 ))
done
```

**The trap.** Bash's `${var:i:1}` is byte-indexed, not codepoint-indexed. A
4-byte UTF-8 codepoint (emoji, sextant block character, box-drawing glyph)
gets sliced into four single-byte "characters" with ANSI escapes wedged
between them. The terminal renders garbage — broken multi-byte sequences,
replacement characters, sometimes literal `🬉` split across colors.

**The fix.** Detect any non-ASCII byte in the input and fall back to a
single-color wrap for the whole string:

```bash
if LC_ALL=C printf '%s' "$text" | LC_ALL=C grep -q '[^[:print:][:space:]]'; then
  local color; color="$(_rainbow_at $(( RANDOM % 6 )))"
  printf '%s%s%s' "$color" "$text" "$_RESET"
  return 0
fi
```

`LC_ALL=C` + `[:print:]` in POSIX character class matches only ASCII
printable bytes 0x20-0x7E, so any byte ≥ 0x80 (UTF-8 continuation or lead)
falls into the negation. `[:space:]` preserves spaces/tabs/newlines in the
ASCII path.

Shimmer is preserved (re-rolled per render) while the glyph stream stays
intact. The cycle effect is lost for non-ASCII strings, but a single color
cycling per invocation is visually acceptable.

### Trap 2: Transcript trust boundary extended to the render seam

**The setup.** The plugin had `tr -d '[:cntrl:]'` sanitization on hook-emit
paths (documented in `claude-code-plugin-transcript-emit-as-trust-boundary-2026-04-21.md`).
Render surfaces (`/buddy:stats`, `/buddy:interact`, statusline) were assumed
safe because buddy.json is plugin-written.

**The trap.** Buddy.json is a JSON file in a user-writable directory. A
user can (accidentally or deliberately) hand-edit `.buddy.name` to contain
ESC bytes, BEL, or OSC sequences. Species JSONs are even more exposed — any
contributor can add a species with control bytes in its line banks. Either
route reaches the transcript via `render_name` / `render_sprite_or_fallback`.
A tampered buddy could clear the user's screen, set the window title, or
plant clickable OSC-8 hyperlinks.

**The fix.** Make the render library a second choke point. The first
emit-time line of `_render_color_line` strips every control byte:

```bash
_render_color_line() {
  local text="$1" rarity="$2"
  # User-controllable strings (buddy name, species, sprite lines) reach here.
  # Strip control bytes before emit so a hand-edited buddy.json / species.json
  # can't plant OSC escapes, clear the screen, or forge ANSI codes we didn't
  # inject ourselves.
  text="$(printf '%s' "$text" | tr -d '[:cntrl:]')"
  # ...color-wrap and return
}
```

Why at the render layer and not each caller: there are three callers
(`status.sh`, `interact.sh`, `buddy-line.sh`) and they keep growing (P4-5
plans a 4th). A choke point in the shared library is a single assertion
per lifecycle; a per-caller strip would be three-plus assertions that
drift out of sync.

This is additive to the hook-emit strip, not a replacement. Depth in
defense: the same content passes two filters, one at production and one
at render.

### Trap 3: "Non-empty" is not "non-whitespace"

**The setup.** P4-4's bake-sprites.sh pipeline produced an array of
strings per species, then wrote them into `.sprite.base`. The validation
included:

```bash
[[ "$nlines" -le 10 ]]
[[ ! printf '%s' "$content" | grep -q $'\x1b' ]]
[[ ! printf '%s' "$content" | grep -Pq '[\t\r]' ]]
[[ "$overflow_check" -eq 0 ]]
```

The jq write used `map(select(length > 0))` to drop empty strings.

**The trap.** A fully-transparent source PNG produces N rows of 14-space
strings. They pass every validator (line count, no ANSI, no tab/CR, width
OK) and the `length > 0` filter keeps them (spaces count toward length).
`.sprite.base` ends up with 6 whitespace strings. `render.sh` sees
`length > 0` and skips the emoji-in-box fallback. Result: **invisible
buddy**. No error, no warning, silently bad committed content.

**The fix.** Add a whitespace-only rejection to the validator:

```bash
if [[ -z "${content//[$' \t\n']/}" ]]; then
  echo "bake-sprites: $name is whitespace-only — source PNG is probably fully transparent" >&2
  return 1
fi
```

General principle: **if content is supposed to render visibly, the
validator must assert visible content, not just non-empty content.** The
`${var//pat/}` parameter expansion is the cheapest way to test whitespace-
only in bash — it's faster than spawning `tr` / `sed` / `grep`.

This trap generalizes: any pipeline that writes content for later display
should validate that the content has at least one non-whitespace character
before committing. Empty-string filters aren't enough.

## Why This Matters

All three traps share a shape: **code that appears to be working because
the tests assert properties that are technically true but practically
wrong.**

- Trap 1's tests asserted "legendary output contains 2+ distinct ANSI
  codes." True — the per-byte slicer happily produces many distinct codes.
  The terminal-visible correctness (codepoint-intact output) was unasserted.
- Trap 2's tests asserted "render emits rarity-colored output." True — and
  also silently passes any ESC bytes planted in the input through to the
  terminal.
- Trap 3's tests asserted "bake produces a non-empty sprite.base array."
  True for both a good sprite and for rows of whitespace.

The fix in every case was to add a second assertion that tests the
human-visible property: codepoints intact, no control bytes beyond those
we injected, some glyph has ink.

## When to Apply

- Any renderer that does per-character decoration (rainbow, pulse, gradient)
  must detect non-ASCII and either use a grapheme-aware iterator (rare in
  shell) or fall back to whole-string decoration for non-ASCII content.
- Any renderer that receives strings from user-writable state must strip
  control bytes at the render seam, even if the state is "internal" —
  internal state today becomes external state the moment someone edits
  a JSON file.
- Any pipeline that writes content into committed files must validate
  the content is visibly meaningful, not just syntactically present.

## Examples

**Trap 1 fixed:**

```bash
@test "legendary rainbow: emoji input is not byte-sliced" {
  out="$(render_name "🦎" legendary)"
  # The raw emoji must survive intact — not byte-sliced into 4 color-wrapped pieces.
  [[ "$out" == *"🦎"* ]]
}
```

**Trap 2 fixed:**

```bash
@test "render: ESC bytes in input are stripped" {
  out="$(render_name $'mal\x1b[31micious' rare)"
  # Raw ESC must not appear anywhere in the output.
  ! [[ "$out" == *$'\x1b[31m'* ]]
}
```

**Trap 3 fixed:**

```bash
@test "bake: whitespace-only chafa output is rejected" {
  # Fully transparent 64x64 source PNG.
  python3 -c "
from PIL import Image
Image.new('RGBA', (64, 64), (0,0,0,0)).save('$scratch/src.png')"
  run bash "$bake_script"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"whitespace-only"* ]]
}
```

## See Also

- `docs/solutions/developer-experience/claude-code-plugin-transcript-emit-as-trust-boundary-2026-04-21.md`
  — the original trust-boundary learning; this doc extends it to the
  render layer.
- `scripts/lib/render.sh` — the library that implements all three fixes.
- ce:review run id 20260423-032944-a1d73030 (P4-3) and 20260423-233451-6690ec13
  (P4-4) — the review rounds that surfaced these traps.
