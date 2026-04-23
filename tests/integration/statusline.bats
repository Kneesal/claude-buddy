#!/usr/bin/env bats
# statusline/buddy-line.sh — P4-3 simplified ambient renderer.
# Format: "<emoji> <name> Lv.<N>" (rarity-colored). No sprite, no XP bar.

bats_require_minimum_version 1.5.0

load ../test_helper

setup_file() {
  _prepare_hatched_cache
}

# Overwrite the rarity on the current envelope so color tests can exercise
# all five bands without chasing RNG.
_set_rarity() {
  local r="$1"
  local buddy_file="$CLAUDE_PLUGIN_DATA/buddy.json"
  local tmp
  tmp="$(mktemp "$CLAUDE_PLUGIN_DATA/.inject.XXXXXX")"
  jq --arg r "$r" '.buddy.rarity = $r' "$buddy_file" > "$tmp"
  mv -f "$tmp" "$buddy_file"
}

# ============================================================
# Sentinel matrix
# ============================================================

@test "statusline: NO_BUDDY renders the hatch prompt" {
  run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"🥚"* ]]
  [[ "$output" == *"No buddy"* ]]
  [[ "$output" == *"/buddy:hatch"* ]]
}

@test "statusline: unset CLAUDE_PLUGIN_DATA renders NO_BUDDY" {
  unset CLAUDE_PLUGIN_DATA
  run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"🥚"* ]]
  [[ "$output" == *"No buddy"* ]]
}

@test "statusline: ACTIVE width 80 renders emoji + name + level (no sprite, no XP, no tokens)" {
  _seed_hatch
  COLUMNS=80 NO_COLOR=1 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"🦎"* ]]
  [[ "$output" == *"Custard"* ]]
  [[ "$output" == *"Lv.1"* ]]
  # No tokens, no XP bar, no sprite box
  [[ "$output" != *"🪙"* ]]
  [[ "$output" != *"▓"* ]]
  [[ "$output" != *"┌"* ]]
  [[ "$output" != *"axolotl"* ]]
  # Default buddies are not shiny
  [[ "$output" != *"✨"* ]]
}

@test "statusline: ACTIVE width 25 drops name, keeps emoji + level" {
  _seed_hatch
  COLUMNS=25 NO_COLOR=1 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"🦎"* ]]
  [[ "$output" == *"Lv.1"* ]]
  [[ "$output" != *"Custard"* ]]
}

@test "statusline: width 30 boundary keeps the name (>= 30)" {
  _seed_hatch
  COLUMNS=30 NO_COLOR=1 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Custard"* ]]
}

@test "statusline: CORRUPT prints repair pointer" {
  _seed_corrupt
  run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠️"* ]]
  [[ "$output" == *"/buddy:reset"* ]]
}

@test "statusline: FUTURE_VERSION prints update-plugin pointer" {
  _seed_future_version
  run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠️"* ]]
  [[ "$output" == *"newer buddy.json"* ]]
}

# ============================================================
# Rarity coloring
# ============================================================

@test "statusline: common rarity emits bright-black ANSI" {
  _seed_hatch
  _set_rarity common
  COLUMNS=80 NO_COLOR= run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033[90m'* ]]
  [[ "$output" == *$'\033[0m'* ]]
}

@test "statusline: rare rarity emits bright-blue ANSI" {
  _seed_hatch
  _set_rarity rare
  COLUMNS=80 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033[94m'* ]]
}

@test "statusline: epic rarity emits bright-magenta ANSI" {
  _seed_hatch
  _set_rarity epic
  COLUMNS=80 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033[95m'* ]]
}

@test "statusline: legendary rarity uses 2+ distinct ANSI codes (rainbow per-char)" {
  _seed_hatch
  _set_rarity legendary
  COLUMNS=80 out="$(bash "$STATUSLINE_SH" </dev/null)"
  count="$(printf '%s' "$out" | grep -oE $'\033\\[[0-9;]+m' | sort -u | wc -l)"
  [ "$count" -ge 2 ]
}

@test "statusline: NO_COLOR=1 strips all ANSI escapes" {
  _seed_hatch
  _set_rarity legendary
  COLUMNS=80 NO_COLOR=1 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033['* ]]
  [[ "$output" == *"Custard"* ]]
}

@test "statusline: NO_COLOR=1 at narrow width still strips ANSI" {
  _seed_hatch
  _set_rarity epic
  COLUMNS=25 NO_COLOR=1 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033['* ]]
}

@test "statusline: shiny buddy prepends ✨ glyph" {
  _seed_hatch
  local tmp
  tmp="$(mktemp "$CLAUDE_PLUGIN_DATA/.inject.XXXXXX")"
  jq '.buddy.shiny = true' "$CLAUDE_PLUGIN_DATA/buddy.json" > "$tmp"
  mv -f "$tmp" "$CLAUDE_PLUGIN_DATA/buddy.json"

  COLUMNS=80 NO_COLOR=1 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"✨"* ]]
  [[ "$output" == *"Custard"* ]]
}

@test "statusline: unset COLUMNS falls back to 80 → wide rendering" {
  _seed_hatch
  unset COLUMNS
  NO_COLOR=1 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Custard"* ]]
}

# ============================================================
# Stdin handling
# ============================================================

@test "statusline: empty stdin renders correctly" {
  _seed_hatch
  COLUMNS=80 NO_COLOR=1 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Custard"* ]]
}

@test "statusline: malformed JSON on stdin is discarded" {
  _seed_hatch
  COLUMNS=80 NO_COLOR=1 run --separate-stderr bash -c 'echo "not { valid json :" | bash "$0"' "$STATUSLINE_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Custard"* ]]
}

@test "statusline: Claude-Code-shaped JSON payload on stdin is discarded" {
  _seed_hatch
  local payload='{"model":"claude-opus","workspace":"/tmp/x","cost":0.123}'
  COLUMNS=80 NO_COLOR=1 run --separate-stderr bash -c "echo '$payload' | bash \"\$0\"" "$STATUSLINE_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Custard"* ]]
  [[ "$output" != *"claude-opus"* ]]
}

# ============================================================
# Missing-field / malformed-envelope resilience
# ============================================================

@test "statusline: species file missing emoji falls back to paw" {
  _seed_hatch
  local fixture="$BATS_TEST_TMPDIR/species-no-emoji"
  mkdir -p "$fixture"
  jq 'del(.emoji)' "$SPECIES_DIR/axolotl.json" > "$fixture/axolotl.json"

  BUDDY_SPECIES_DIR="$fixture" COLUMNS=80 NO_COLOR=1 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"🐾"* ]]
  [[ "$output" != *"🦎"* ]]
}

@test "statusline: species file absent falls back to paw" {
  _seed_hatch
  local fixture="$BATS_TEST_TMPDIR/species-empty"
  mkdir -p "$fixture"

  BUDDY_SPECIES_DIR="$fixture" COLUMNS=80 NO_COLOR=1 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"🐾"* ]]
  [[ "$output" != *"🦎"* ]]
}

@test "statusline: embedded newline in .buddy.name does not shift fields" {
  cat > "$CLAUDE_PLUGIN_DATA/buddy.json" <<'JSON'
{
  "schemaVersion": 1,
  "hatchedAt": "2026-04-20T00:00:00Z",
  "lastRerollAt": null,
  "buddy": {"id":"x","name":"Custard\nEvil","species":"axolotl","rarity":"epic","shiny":false,"stats":{"debugging":5,"patience":5,"chaos":5,"wisdom":5,"snark":5},"form":"base","level":7,"xp":0},
  "tokens": {"balance": 3, "earnedToday": 0, "windowStartedAt": "2026-04-20T00:00:00Z"},
  "meta": {"totalHatches": 1, "pityCounter": 0}
}
JSON
  COLUMNS=80 NO_COLOR=1 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Lv.7"* ]]
}

@test "statusline: envelope with null .buddy falls through to CORRUPT render" {
  echo '{"schemaVersion": 1, "buddy": null, "tokens": {"balance": 0}, "meta": {"totalHatches": 1, "pityCounter": 0}}' \
    > "$CLAUDE_PLUGIN_DATA/buddy.json"
  run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠️"* ]]
}

@test "statusline: envelope missing required buddy fields falls through to CORRUPT render" {
  echo '{"schemaVersion": 1, "buddy": {}, "tokens": {"balance": 0}, "meta": {"totalHatches": 1, "pityCounter": 0}}' \
    > "$CLAUDE_PLUGIN_DATA/buddy.json"
  run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠️"* ]]
}

# ============================================================
# Latency + stderr cleanliness
# ============================================================

# bats test_tags=slow
@test "statusline: single render completes in under 500ms" {
  _seed_hatch
  local start_ms end_ms elapsed_ms
  start_ms="$(($(date +%s%N) / 1000000))"
  COLUMNS=80 bash "$STATUSLINE_SH" </dev/null >/dev/null
  end_ms="$(($(date +%s%N) / 1000000))"
  elapsed_ms=$(( end_ms - start_ms ))
  [ "$elapsed_ms" -lt 500 ]
}

@test "statusline: never writes to stderr during a normal render" {
  _seed_hatch
  run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}
