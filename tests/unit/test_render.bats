#!/usr/bin/env bats
# Unit tests for scripts/lib/render.sh — shared visible-buddy helpers.
# All public functions must honor $NO_COLOR and degrade gracefully on
# malformed inputs (exit 0 with a sensible fallback).

bats_require_minimum_version 1.5.0

load ../test_helper

setup() {
  export CLAUDE_PLUGIN_DATA="$BATS_TEST_TMPDIR/plugin-data"
  mkdir -p "$CLAUDE_PLUGIN_DATA"
  unset NO_COLOR
  # shellcheck source=../../scripts/lib/render.sh
  source "$REPO_ROOT/scripts/lib/render.sh"
}

# --- render_bar ----------------------------------------------------------

@test "render_bar: half-full at 50/100 width 20 → 10 fill + 10 empty" {
  run render_bar 50 100 20
  [ "$status" -eq 0 ]
  # 10 ▓ followed by 10 ░ (each 3 bytes in UTF-8)
  expected="$(printf '▓%.0s' {1..10})$(printf '░%.0s' {1..10})"
  [ "$output" = "$expected" ]
}

@test "render_bar: 0/100 → all empty" {
  run render_bar 0 100 20
  expected="$(printf '░%.0s' {1..20})"
  [ "$output" = "$expected" ]
}

@test "render_bar: 100/100 → all filled" {
  run render_bar 100 100 20
  expected="$(printf '▓%.0s' {1..20})"
  [ "$output" = "$expected" ]
}

@test "render_bar: clamps overflow (150/100 → all filled)" {
  run render_bar 150 100 20
  expected="$(printf '▓%.0s' {1..20})"
  [ "$output" = "$expected" ]
}

@test "render_bar: clamps negative (-5/100 → all empty)" {
  run render_bar -5 100 20
  expected="$(printf '░%.0s' {1..20})"
  [ "$output" = "$expected" ]
}

@test "render_bar: divide-by-zero (max=0) → all empty, exit 0" {
  run render_bar 50 0 20
  [ "$status" -eq 0 ]
  expected="$(printf '░%.0s' {1..20})"
  [ "$output" = "$expected" ]
}

@test "render_bar: non-numeric input → all empty, exit 0" {
  run render_bar abc 100 20
  [ "$status" -eq 0 ]
  expected="$(printf '░%.0s' {1..20})"
  [ "$output" = "$expected" ]
}

# --- render_rarity_color_open / close ------------------------------------

@test "render_rarity_color_open: common emits grey ANSI" {
  run render_rarity_color_open common
  [ "$status" -eq 0 ]
  [ "$output" = $'\033[90m' ]
}

@test "render_rarity_color_open: rare emits bright blue ANSI" {
  run render_rarity_color_open rare
  [ "$output" = $'\033[94m' ]
}

@test "render_rarity_color_close emits reset" {
  run render_rarity_color_close
  [ "$output" = $'\033[0m' ]
}

@test "render_rarity_color_open: NO_COLOR=1 yields empty output" {
  NO_COLOR=1 run render_rarity_color_open legendary
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "render_rarity_color_close: NO_COLOR=1 yields empty output" {
  NO_COLOR=1 run render_rarity_color_close
  [ -z "$output" ]
}

@test "render_rarity_color_open: legendary cycles palette across calls" {
  # Re-seeded each call, so running in a tight loop should produce at
  # least 2 distinct outputs out of 20 invocations (very high probability).
  declare -A seen=()
  for _ in {1..20}; do
    out="$(render_rarity_color_open legendary)"
    seen["$out"]=1
  done
  [ "${#seen[@]}" -ge 2 ]
}

@test "render_rarity_color_open: unknown rarity falls back to empty" {
  run render_rarity_color_open totally-not-a-rarity
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- render_stat_line ----------------------------------------------------

@test "render_stat_line: composes label + bar + value" {
  NO_COLOR=1 run render_stat_line "patience" 7 10 20
  [ "$status" -eq 0 ]
  [[ "$output" == *"patience"* ]]
  [[ "$output" == *"7"* ]]
  [[ "$output" == *"10"* ]]
  [[ "$output" == *"▓"* ]]
}

# --- render_name ---------------------------------------------------------

@test "render_name: wraps in rarity color (rare)" {
  run render_name "Custard" rare
  [ "$status" -eq 0 ]
  [[ "$output" == *"Custard"* ]]
  [[ "$output" == *$'\033[94m'* ]]
  [[ "$output" == *$'\033[0m'* ]]
}

@test "render_name: NO_COLOR strips ANSI" {
  NO_COLOR=1 run render_name "Custard" rare
  [ "$output" = "Custard" ]
}

@test "render_name: legendary uses 2+ distinct ANSI codes (rainbow)" {
  out="$(render_name "Custard" legendary)"
  # Count distinct ESC[XYm prefixes
  count="$(printf '%s' "$out" | grep -oE $'\033\\[[0-9;]+m' | sort -u | wc -l)"
  [ "$count" -ge 2 ]
}

# --- render_sprite_or_fallback -------------------------------------------

_make_species_fixture() {
  local path="$1"; shift
  local emoji="$1"; shift
  local sprite_json="$1"; shift  # JSON array literal e.g. '[]' or '["aa","bb"]'
  cat > "$path" <<EOF
{
  "schemaVersion": 1,
  "species": "fixture",
  "emoji": "$emoji",
  "sprite": { "base": $sprite_json }
}
EOF
}

@test "render_sprite_or_fallback: empty sprite renders 3-line fallback box with emoji" {
  fixture="$BATS_TEST_TMPDIR/empty.json"
  _make_species_fixture "$fixture" "🦎" "[]"
  NO_COLOR=1 run render_sprite_or_fallback "$fixture" common 0
  [ "$status" -eq 0 ]
  lines="$(printf '%s\n' "$output" | wc -l)"
  [ "$lines" -ge 3 ]
  [[ "$output" == *"🦎"* ]]
}

@test "render_sprite_or_fallback: malformed sprite → fallback, exit 0" {
  fixture="$BATS_TEST_TMPDIR/bad.json"
  echo "{bad json" > "$fixture"
  run render_sprite_or_fallback "$fixture" common 0
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "render_sprite_or_fallback: missing file → fallback, exit 0" {
  run render_sprite_or_fallback "$BATS_TEST_TMPDIR/nope.json" common 0
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "render_sprite_or_fallback: valid sprite wraps each line in rarity color" {
  fixture="$BATS_TEST_TMPDIR/dragon.json"
  _make_species_fixture "$fixture" "🐉" '["  /\\_/\\  ", " ( o.o ) "]'
  run render_sprite_or_fallback "$fixture" rare 0
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033[94m'* ]]
  [[ "$output" == *"o.o"* ]]
}

@test "render_sprite_or_fallback: legendary sprite uses 2+ distinct ANSI codes" {
  fixture="$BATS_TEST_TMPDIR/leg.json"
  _make_species_fixture "$fixture" "🐉" '["abcdefgh"]'
  out="$(render_sprite_or_fallback "$fixture" legendary 0)"
  count="$(printf '%s' "$out" | grep -oE $'\033\\[[0-9;]+m' | sort -u | wc -l)"
  [ "$count" -ge 2 ]
}

@test "render_sprite_or_fallback: NO_COLOR strips ANSI from fallback box" {
  fixture="$BATS_TEST_TMPDIR/empty.json"
  _make_species_fixture "$fixture" "🦎" "[]"
  NO_COLOR=1 run render_sprite_or_fallback "$fixture" rare 0
  ! [[ "$output" == *$'\033'* ]]
}

@test "render_sprite_or_fallback: no-hat renders the face directly (no blank top row)" {
  # P4-4d post-tighten — hatless buddies render as a tight 4-row face.
  # The hat row is only emitted when a hat resolves; the visible height
  # delta IS the 'this buddy has a hat' signal.
  fixture="$BATS_TEST_TMPDIR/face.json"
  _make_species_fixture "$fixture" "🦎" '["row2","row3","row4","row5"]'
  NO_COLOR=1 run render_sprite_or_fallback "$fixture" common 0 ""
  [ "$status" -eq 0 ]
  # First emitted line is the first face row, NOT a 12-space placeholder.
  first="$(printf '%s\n' "$output" | head -1)"
  [ "$first" = "row2" ]
  lines="$(printf '%s\n' "$output" | wc -l)"
  [ "$lines" -eq 4 ]
}

@test "render_sprite_or_fallback: {EYE} marker is substituted with provided eye glyph" {
  fixture_dir="$BATS_TEST_TMPDIR/eye-fx"
  mkdir -p "$fixture_dir"
  cat > "$fixture_dir/widget.json" <<'JSON'
{"schemaVersion":1,"species":"widget","emoji":"🤖","sprite":{"base":["( {EYE} {EYE} )","row3","row4","row5"]}}
JSON
  BUDDY_SPECIES_DIR="$fixture_dir" NO_COLOR=1 run render_sprite_or_fallback \
    "$fixture_dir/widget.json" common 0 "" "*"
  [ "$status" -eq 0 ]
  [[ "$output" == *'( * * )'* ]]
  ! [[ "$output" == *'{EYE}'* ]]
}

@test "render_sprite_or_fallback: missing eye arg defaults to · marker" {
  fixture_dir="$BATS_TEST_TMPDIR/eye-default"
  mkdir -p "$fixture_dir"
  cat > "$fixture_dir/widget.json" <<'JSON'
{"schemaVersion":1,"species":"widget","emoji":"🤖","sprite":{"base":["{EYE}{EYE}","row3","row4","row5"]}}
JSON
  BUDDY_SPECIES_DIR="$fixture_dir" NO_COLOR=1 run render_sprite_or_fallback \
    "$fixture_dir/widget.json" common 0
  [ "$status" -eq 0 ]
  [[ "$output" == *'··'* ]]
}

@test "render_sprite_or_fallback: hat name prepends the hat sprite on row 1" {
  # Write a fixture hat library and point BUDDY_SPECIES_DIR at it.
  fixture_dir="$BATS_TEST_TMPDIR/hat-fx"
  mkdir -p "$fixture_dir"
  cat > "$fixture_dir/_hats.json" <<'JSON'
{"schemaVersion":1,"hats":{"crown":"   \\^^^/    ","tophat":"   [___]    "}}
JSON
  cat > "$fixture_dir/widget.json" <<'JSON'
{"schemaVersion":1,"species":"widget","emoji":"🤖","sprite":{"base":["A","B","C","D"]}}
JSON
  BUDDY_SPECIES_DIR="$fixture_dir" NO_COLOR=1 run render_sprite_or_fallback \
    "$fixture_dir/widget.json" common 0 crown
  [ "$status" -eq 0 ]
  first="$(printf '%s\n' "$output" | head -1)"
  [[ "$first" == *'\^^^/'* ]]
}

@test "render_sprite_or_fallback: unknown hat name falls back to face only (no blank row)" {
  # Same tightened contract as the no-hat case — a missing hat does not
  # waste a blank line; the face renders directly.
  fixture_dir="$BATS_TEST_TMPDIR/hat-miss"
  mkdir -p "$fixture_dir"
  cat > "$fixture_dir/_hats.json" <<'JSON'
{"schemaVersion":1,"hats":{"crown":"   \\^^^/    "}}
JSON
  cat > "$fixture_dir/widget.json" <<'JSON'
{"schemaVersion":1,"species":"widget","emoji":"🤖","sprite":{"base":["A","B","C","D"]}}
JSON
  BUDDY_SPECIES_DIR="$fixture_dir" NO_COLOR=1 run render_sprite_or_fallback \
    "$fixture_dir/widget.json" common 0 "totally-not-a-hat"
  [ "$status" -eq 0 ]
  first="$(printf '%s\n' "$output" | head -1)"
  [ "$first" = "A" ]
  lines="$(printf '%s\n' "$output" | wc -l)"
  [ "$lines" -eq 4 ]
}

@test "render_sprite_or_fallback: shiny prepends sparkle glyph" {
  fixture="$BATS_TEST_TMPDIR/empty.json"
  _make_species_fixture "$fixture" "🦎" "[]"
  NO_COLOR=1 run render_sprite_or_fallback "$fixture" common 1
  [[ "$output" == *"✨"* ]]
}

# --- render_speech_bubble ------------------------------------------------

@test "render_speech_bubble: short text renders 3-line bubble" {
  NO_COLOR=1 run render_speech_bubble "hi there" 20
  [ "$status" -eq 0 ]
  lines="$(printf '%s\n' "$output" | wc -l)"
  [ "$lines" -eq 3 ]
  [[ "$output" == *"hi there"* ]]
}

@test "render_speech_bubble: empty input emits no output" {
  run render_speech_bubble "" 20
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "render_speech_bubble: long text wraps to multiple bubble body lines" {
  NO_COLOR=1 run render_speech_bubble "this text is definitely longer than ten characters indeed yes" 12
  [ "$status" -eq 0 ]
  # 2 wrapped lines + top + bottom => >= 4 total
  lines="$(printf '%s\n' "$output" | wc -l)"
  [ "$lines" -ge 4 ]
}

@test "render_name: ESC bytes in input are stripped before color wrap" {
  # Hand-edited buddy.json could plant ESC sequences in the name field; the
  # render layer must not emit user-controllable control bytes verbatim.
  # The ESC (0x1b) is stripped; printable bytes from the attempted escape
  # remain (so the user sees what was tampered) but cannot drive the terminal.
  out="$(render_name $'mal\x1b[31micious' rare)"
  ! [[ "$out" == *$'\x1b[31m'* ]]
  ! [[ "$out" == *$'\x1b[31'* ]]
}

@test "render_color (legendary): emoji input is not byte-sliced" {
  # Per-char rainbow on a string containing a multi-byte glyph would inject
  # ANSI escapes between the bytes of that codepoint, shredding the emoji.
  # Detect that the emoji 🦎 (4 UTF-8 bytes) survives intact.
  out="$(render_name "🦎" legendary)"
  [[ "$out" == *"🦎"* ]]
}

@test "render_speech_bubble: control bytes are stripped" {
  NO_COLOR=1 run render_speech_bubble $'hello\tworld' 20
  [ "$status" -eq 0 ]
  # tab gone — the substring "helloworld" or "hello world" should appear
  ! [[ "$output" == *$'\t'* ]]
}
