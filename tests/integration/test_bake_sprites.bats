#!/usr/bin/env bats
# bake-sprites.sh — contributor-time chafa wrapper.
# These tests lock the properties the ce:review adversarial round surfaced:
#   - idempotent re-bake produces byte-identical species JSONs
#   - whitespace-only chafa output is rejected (transparent PNG → invisible buddy)
#   - missing source PNG fails with a clear message
#   - --check runs without writing

bats_require_minimum_version 1.5.0

load ../test_helper

BAKE_SH="$REPO_ROOT/scripts/bake-sprites.sh"
SOURCE_ART="$REPO_ROOT/scripts/art/source-sprites.py"

# Skip the whole file if contributor-time tools are absent — these tests only
# run in environments with chafa + python3 + pillow installed.
setup_file() {
  if ! command -v chafa >/dev/null 2>&1; then
    skip "chafa not installed — contributor-time tests only run where chafa is present"
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 not installed"
  fi
}

@test "bake-sprites: idempotent — second bake produces no diff" {
  # Capture committed species JSONs as fingerprints, re-bake, compare.
  local before_axolotl before_dragon
  before_axolotl="$(md5sum "$REPO_ROOT/scripts/species/axolotl.json" | awk '{print $1}')"
  before_dragon="$(md5sum "$REPO_ROOT/scripts/species/dragon.json" | awk '{print $1}')"

  run bash "$BAKE_SH"
  [ "$status" -eq 0 ]

  local after_axolotl after_dragon
  after_axolotl="$(md5sum "$REPO_ROOT/scripts/species/axolotl.json" | awk '{print $1}')"
  after_dragon="$(md5sum "$REPO_ROOT/scripts/species/dragon.json" | awk '{print $1}')"

  [ "$before_axolotl" = "$after_axolotl" ]
  [ "$before_dragon" = "$after_dragon" ]
}

@test "bake-sprites: --check prints all species, does not write" {
  local before
  before="$(md5sum "$REPO_ROOT/scripts/species/axolotl.json" | awk '{print $1}')"

  run bash "$BAKE_SH" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== axolotl ==="* ]]
  [[ "$output" == *"=== dragon ==="* ]]

  local after
  after="$(md5sum "$REPO_ROOT/scripts/species/axolotl.json" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

@test "bake-sprites: rejects fully-transparent source PNG as whitespace-only" {
  # Build a fixture checkout: copy the bake script and a stand-in transparent
  # PNG into a scratch dir so we don't corrupt the real species JSONs.
  local scratch="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$scratch/scripts/species" "$scratch/assets/species"
  cp "$BAKE_SH" "$scratch/scripts/bake-sprites.sh"
  # Minimal species JSON
  cat > "$scratch/scripts/species/axolotl.json" <<'JSON'
{"schemaVersion":1,"species":"axolotl","emoji":"🦎","sprite":{"base":["placeholder"]}}
JSON
  # Fully transparent 64x64 PNG
  python3 -c "
from PIL import Image
Image.new('RGBA', (64, 64), (0,0,0,0)).save('$scratch/assets/species/axolotl.png')
"
  # Patch the bake script to only process axolotl (other species files aren't there).
  sed -i 's/^SPECIES=(axolotl dragon owl ghost capybara)/SPECIES=(axolotl)/' "$scratch/scripts/bake-sprites.sh"

  run bash "$scratch/scripts/bake-sprites.sh"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"whitespace-only"* || "$output" == *"whitespace-only"* ]]
}

@test "bake-sprites: missing source PNG fails clearly" {
  local scratch="$BATS_TEST_TMPDIR/fixture-missing"
  mkdir -p "$scratch/scripts/species" "$scratch/assets/species"
  cp "$BAKE_SH" "$scratch/scripts/bake-sprites.sh"
  cat > "$scratch/scripts/species/axolotl.json" <<'JSON'
{"schemaVersion":1,"species":"axolotl","emoji":"🦎","sprite":{"base":[]}}
JSON
  # Deliberately NO source PNG
  sed -i 's/^SPECIES=(axolotl dragon owl ghost capybara)/SPECIES=(axolotl)/' "$scratch/scripts/bake-sprites.sh"

  run bash "$scratch/scripts/bake-sprites.sh"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"missing source PNG"* || "$output" == *"missing source PNG"* ]]
}

@test "bake-sprites: --help prints usage" {
  run bash "$BAKE_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "bake-sprites: unknown flag exits non-zero" {
  run bash "$BAKE_SH" --bogus
  [ "$status" -ne 0 ]
}

@test "source-sprites.py: --check runs without writing PNGs" {
  if ! python3 -c "from PIL import Image" 2>/dev/null; then
    skip "pillow not installed"
  fi
  local before
  before="$(md5sum "$REPO_ROOT/assets/species/axolotl.png" | awk '{print $1}')"

  run python3 "$SOURCE_ART" --check
  [ "$status" -eq 0 ]

  local after
  after="$(md5sum "$REPO_ROOT/assets/species/axolotl.png" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

@test "source-sprites.py: --help prints usage" {
  if ! python3 -c "from PIL import Image" 2>/dev/null; then
    skip "pillow not installed"
  fi
  run python3 "$SOURCE_ART" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"deterministic"* || "$output" == *"claude-buddy"* ]]
}
