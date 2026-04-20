#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load test_helper

# Script paths and shared seeding helpers (_seed_hatch, _seed_corrupt,
# _seed_future_version, _inject_tokens) come from test_helper.bash.
# _set_rarity is statusline-specific and stays local below.

# ------------------------------------------------------------------
# Helpers (statusline-specific)
# ------------------------------------------------------------------

# Overwrite the rarity on the current envelope so color tests can exercise
# all five rarity bands without chasing RNG. P1-2's roll_stats is deterministic
# on rarity+species, but seeding a specific rarity via pity/seed would be
# brittle; editing the envelope in place is the cleanest path.
_set_rarity() {
  local r="$1"
  local buddy_file="$CLAUDE_PLUGIN_DATA/buddy.json"
  local tmp
  tmp="$(mktemp "$CLAUDE_PLUGIN_DATA/.inject.XXXXXX")"
  jq --arg r "$r" '.buddy.rarity = $r' "$buddy_file" > "$tmp"
  mv -f "$tmp" "$buddy_file"
}

# ============================================================
# Sentinel matrix: the four-state machine plus FUTURE_VERSION
# ============================================================

@test "statusline: NO_BUDDY renders the hatch prompt" {
  run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"🥚"* ]]
  [[ "$output" == *"No buddy"* ]]
  [[ "$output" == *"/buddy:hatch"* ]]
}

@test "statusline: unset CLAUDE_PLUGIN_DATA renders NO_BUDDY (inherits state.sh behavior)" {
  unset CLAUDE_PLUGIN_DATA
  run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"🥚"* ]]
  [[ "$output" == *"No buddy"* ]]
}

@test "statusline: ACTIVE renders emoji, name, rarity, species, level, tokens" {
  _seed_hatch
  COLUMNS=80 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  # Seed 42 pins axolotl / Custard / common.
  [[ "$output" == *"🦎"* ]]
  [[ "$output" == *"Custard"* ]]
  [[ "$output" == *"Common"* ]]
  [[ "$output" == *"axolotl"* ]]
  [[ "$output" == *"Lv.1"* ]]
  [[ "$output" == *"🪙"* ]]
  # Default buddies are not shiny — asserting absence pins the sparkle guard.
  # If `_buddy_line_render_active`'s shiny branch were accidentally inverted
  # (`!=` instead of `==`), all the assertions above would still pass.
  [[ "$output" != *"✨"* ]]
}

@test "statusline: ACTIVE with injected tokens shows the new balance" {
  _seed_hatch
  _inject_tokens 7
  COLUMNS=80 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"7 🪙"* ]]
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
# Rarity colors: each rarity gets its expected ANSI code; NO_COLOR strips.
# ============================================================

@test "statusline: common rarity emits bright-black ANSI prefix" {
  _seed_hatch
  _set_rarity common
  COLUMNS=80 NO_COLOR= run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033[90m'* ]]
  [[ "$output" == *$'\033[0m'* ]]
}

@test "statusline: uncommon rarity emits bright-white ANSI prefix" {
  _seed_hatch
  _set_rarity uncommon
  COLUMNS=80 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033[97m'* ]]
}

@test "statusline: rare rarity emits bright-blue ANSI prefix" {
  _seed_hatch
  _set_rarity rare
  COLUMNS=80 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033[94m'* ]]
}

@test "statusline: epic rarity emits bright-magenta ANSI prefix" {
  _seed_hatch
  _set_rarity epic
  COLUMNS=80 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033[95m'* ]]
}

@test "statusline: legendary rarity emits bright-yellow ANSI prefix" {
  _seed_hatch
  _set_rarity legendary
  COLUMNS=80 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033[93m'* ]]
}

@test "statusline: NO_COLOR=1 strips all ANSI escapes" {
  _seed_hatch
  _set_rarity legendary
  COLUMNS=80 NO_COLOR=1 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  # No color, no reset — pure text.
  [[ "$output" != *$'\033['* ]]
  [[ "$output" == *"Legendary"* ]]
}

# ============================================================
# Width gating: >=40 full, 30-39 drops tokens, <30 drops rarity qualifier.
# ============================================================

@test "statusline: width 80 renders the full line (rarity + species + tokens)" {
  _seed_hatch
  COLUMNS=80 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Common"* ]]
  [[ "$output" == *"axolotl"* ]]
  [[ "$output" == *"🪙"* ]]
}

@test "statusline: width 35 drops tokens segment but keeps rarity qualifier" {
  _seed_hatch
  COLUMNS=35 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Common"* ]]
  [[ "$output" == *"axolotl"* ]]
  [[ "$output" != *"🪙"* ]]
}

@test "statusline: width 25 also drops rarity qualifier, leaving icon+name+level" {
  _seed_hatch
  COLUMNS=25 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Custard"* ]]
  [[ "$output" == *"Lv.1"* ]]
  [[ "$output" != *"Common"* ]]
  [[ "$output" != *"axolotl"* ]]
  [[ "$output" != *"🪙"* ]]
}

# Width-boundary tests — the thresholds are exactly `< 30` and `< 40`. These
# pin the off-by-one so a future `<= 30` or `<= 40` rewrite is caught.
@test "statusline: width 30 exactly (boundary) shows rarity qualifier, no tokens" {
  _seed_hatch
  COLUMNS=30 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Common"* ]]
  [[ "$output" == *"axolotl"* ]]
  [[ "$output" != *"🪙"* ]]
}

@test "statusline: width 40 exactly (boundary) shows full line with tokens" {
  _seed_hatch
  COLUMNS=40 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Common"* ]]
  [[ "$output" == *"axolotl"* ]]
  [[ "$output" == *"🪙"* ]]
}

@test "statusline: unset COLUMNS uses tput/80 fallback and doesn't crash" {
  _seed_hatch
  unset COLUMNS
  run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  # With no width info and no TTY, it falls back to 80 → full line.
  [[ "$output" == *"Custard"* ]]
}

# ============================================================
# Stdin handling: empty, malformed, and Claude Code payload all ignored.
# ============================================================

@test "statusline: empty stdin renders correctly" {
  _seed_hatch
  COLUMNS=80 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Custard"* ]]
}

@test "statusline: malformed JSON on stdin is discarded, not parsed" {
  _seed_hatch
  COLUMNS=80 run --separate-stderr bash -c 'echo "not { valid json :" | bash "$0"' "$STATUSLINE_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Custard"* ]]
}

@test "statusline: Claude-Code-shaped JSON payload on stdin is discarded" {
  _seed_hatch
  local payload='{"model":"claude-opus","workspace":"/tmp/x","cost":0.123}'
  COLUMNS=80 run --separate-stderr bash -c "echo '$payload' | bash \"\$0\"" "$STATUSLINE_SH"
  [ "$status" -eq 0 ]
  # Same output as empty stdin — script does not parse the payload.
  [[ "$output" == *"Custard"* ]]
  [[ "$output" != *"claude-opus"* ]]
}

# ============================================================
# Missing-field / malformed-envelope resilience
# ============================================================

@test "statusline: species file missing emoji field falls back to default paw emoji" {
  _seed_hatch
  # Point BUDDY_SPECIES_DIR at a fixture dir where axolotl has no emoji field.
  local fixture="$BATS_TEST_TMPDIR/species-no-emoji"
  mkdir -p "$fixture"
  jq 'del(.emoji)' "$SPECIES_DIR/axolotl.json" > "$fixture/axolotl.json"

  BUDDY_SPECIES_DIR="$fixture" COLUMNS=80 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  # Fallback is 🐾; the original 🦎 should be absent.
  [[ "$output" == *"🐾"* ]]
  [[ "$output" != *"🦎"* ]]
}

@test "statusline: species file entirely absent falls back to default paw emoji" {
  # The emoji resolver has two fallback branches: file missing vs file-present-
  # but-emoji-missing. The previous test covers branch 2; this covers branch 1.
  _seed_hatch
  local fixture="$BATS_TEST_TMPDIR/species-empty"
  mkdir -p "$fixture"   # empty directory, no species files at all

  BUDDY_SPECIES_DIR="$fixture" COLUMNS=80 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"🐾"* ]]
  [[ "$output" != *"🦎"* ]]
}

@test "statusline: embedded newline in .buddy.name does not shift field indices" {
  # Tampered envelope with a literal \n inside the name string. jq -r decodes
  # the JSON \n to a real LF — without the gsub strip in the field extractor,
  # readarray would split the name across two slots, shifting rarity/level/
  # tokens by one position and producing a scrambled line.
  cat > "$CLAUDE_PLUGIN_DATA/buddy.json" <<'JSON'
{
  "schemaVersion": 1,
  "hatchedAt": "2026-04-20T00:00:00Z",
  "lastRerollAt": null,
  "buddy": {"id":"x","name":"Custard\nEvil","species":"axolotl","rarity":"legendary","shiny":false,"stats":{"debugging":5,"patience":5,"chaos":5,"wisdom":5,"snark":5},"form":"base","level":7,"xp":0},
  "tokens": {"balance": 3, "earnedToday": 0, "windowStartedAt": "2026-04-20T00:00:00Z"},
  "meta": {"totalHatches": 1, "pityCounter": 0}
}
JSON
  COLUMNS=80 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  # Newline-stripped name has both parts joined by a space — the key point is
  # that the fields after name still land in their correct slots.
  [[ "$output" == *"Legendary"* ]]
  [[ "$output" == *"Lv.7"* ]]
  [[ "$output" == *"3 🪙"* ]]
  # Name part 2 must NOT end up in the rarity slot (which would produce
  # "Evil axolotl" in the output).
  [[ "$output" != *"Evil axolotl"* ]]
}

@test "statusline: envelope with null .buddy falls through to CORRUPT render" {
  # schemaVersion=1 (so buddy_load returns JSON, not CORRUPT) but buddy is null
  # → jq extraction succeeds but required fields are empty → CORRUPT fallback.
  echo '{"schemaVersion": 1, "buddy": null, "tokens": {"balance": 0}, "meta": {"totalHatches": 1, "pityCounter": 0}}' \
    > "$CLAUDE_PLUGIN_DATA/buddy.json"
  run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠️"* ]]
}

@test "statusline: envelope missing required buddy fields falls through to CORRUPT render" {
  # schemaVersion is valid, buddy exists but species/name/rarity empty.
  echo '{"schemaVersion": 1, "buddy": {}, "tokens": {"balance": 0}, "meta": {"totalHatches": 1, "pityCounter": 0}}' \
    > "$CLAUDE_PLUGIN_DATA/buddy.json"
  run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠️"* ]]
}

# ============================================================
# Shiny: stub code path. .buddy.shiny=true adds a sparkle prefix.
# ============================================================

@test "statusline: shiny buddy gets a sparkle emoji prefix in ACTIVE render" {
  _seed_hatch
  local tmp
  tmp="$(mktemp "$CLAUDE_PLUGIN_DATA/.inject.XXXXXX")"
  jq '.buddy.shiny = true' "$CLAUDE_PLUGIN_DATA/buddy.json" > "$tmp"
  mv -f "$tmp" "$CLAUDE_PLUGIN_DATA/buddy.json"

  COLUMNS=80 run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"✨"* ]]
  [[ "$output" == *"Custard"* ]]
}

# ============================================================
# Latency sanity: loose ceiling. p95 target is 50ms on the reference box;
# a generous single-shot wall-clock assertion catches obvious regressions
# (fork loops, accidental sleeps) without being flaky.
# ============================================================

# bats test_tags=slow
@test "statusline: single render completes in under 500ms (loose ceiling)" {
  _seed_hatch
  local start_ms end_ms elapsed_ms
  start_ms="$(($(date +%s%N) / 1000000))"
  COLUMNS=80 bash "$STATUSLINE_SH" </dev/null >/dev/null
  end_ms="$(($(date +%s%N) / 1000000))"
  elapsed_ms=$(( end_ms - start_ms ))
  # 500ms is ~10x the 50ms p95 target — a test failure here means something
  # fundamentally broke, not just a slow CI box.
  [ "$elapsed_ms" -lt 500 ]
}

# ============================================================
# Error resilience: state.sh missing or other source failure → empty output, exit 0
# ============================================================

@test "statusline: never writes to stderr during a normal render (no spurious warnings)" {
  _seed_hatch
  run --separate-stderr bash "$STATUSLINE_SH" </dev/null
  [ "$status" -eq 0 ]
  # stderr should be empty for the happy path — any log noise on every turn
  # would pollute the user's terminal.
  [ -z "$stderr" ]
}
