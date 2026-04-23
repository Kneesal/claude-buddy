#!/usr/bin/env bats
# /buddy:interact — read-only sprite + speech-bubble view.

bats_require_minimum_version 1.5.0

load ../test_helper

INTERACT_SH="$REPO_ROOT/scripts/interact.sh"

setup_file() {
  _prepare_hatched_cache
}

@test "interact: NO_BUDDY prints hatch hint" {
  run --separate-stderr bash "$INTERACT_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No buddy yet"* ]]
  [[ "$output" == *"/buddy:hatch"* ]]
}

@test "interact: ACTIVE renders speech bubble + sprite, exit 0" {
  _seed_hatch
  NO_COLOR=1 run --separate-stderr bash "$INTERACT_SH"
  [ "$status" -eq 0 ]
  # Bubble corner glyphs
  [[ "$output" == *"_"* ]]
  [[ "$output" == *"<"* ]]
  [[ "$output" == *">"* ]]
  [[ "$output" == *"v"* ]]
  # Placeholder voice line — Interact bank still empty (D9); only sprite content shipped.
  [[ "$output" == *"Custard looks at you curiously."* ]]
  # Axolotl sprite content (seed 42 pins axolotl)
  [[ "$output" == *"o v o"* ]]
}

@test "interact: NO_COLOR=1 strips ANSI escapes" {
  _seed_hatch
  NO_COLOR=1 run --separate-stderr bash "$INTERACT_SH"
  [ "$status" -eq 0 ]
  ! [[ "$output" == *$'\033'* ]]
}

@test "interact: CORRUPT prints repair pointer, exit 0" {
  _seed_corrupt
  run --separate-stderr bash "$INTERACT_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Buddy state needs repair"* ]]
}

@test "interact: FUTURE_VERSION prints update message, exit 0" {
  _seed_future_version
  run --separate-stderr bash "$INTERACT_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"newer plugin version"* ]]
}

@test "interact: extra args rejected" {
  run --separate-stderr bash "$INTERACT_SH" bogus
  [ "$status" -ne 0 ]
}

@test "interact: populated Interact bank — picked line appears in bubble" {
  # Build a fixture species dir with one species whose Interact bank has a
  # single distinctive line. Set buddy.species to that fixture.
  local fixture_dir="$BATS_TEST_TMPDIR/species"
  mkdir -p "$fixture_dir"
  cat > "$fixture_dir/widget.json" <<'JSON'
{
  "schemaVersion": 1,
  "species": "widget",
  "emoji": "🤖",
  "voice": "test",
  "base_stats_weights": {"debugging":"neutral","patience":"neutral","chaos":"neutral","wisdom":"neutral","snark":"neutral"},
  "name_pool": ["Widget"],
  "evolution_paths": {},
  "line_banks": {
    "PostToolUse": {"default": []},
    "PostToolUseFailure": {"default": []},
    "Stop": {"default": []},
    "LevelUp": {"default": []},
    "Interact": {"default": ["whirr-distinctive-fixture-line"]}
  },
  "sprite": {"base": []}
}
JSON
  cat > "$CLAUDE_PLUGIN_DATA/buddy.json" <<'JSON'
{
  "schemaVersion": 1,
  "hatchedAt": "2026-04-19T00:00:00Z",
  "lastRerollAt": null,
  "buddy": {"id":"x","name":"Widget","species":"widget","rarity":"common","shiny":false,"stats":{"debugging":5,"patience":5,"chaos":5,"wisdom":5,"snark":5},"form":"base","level":1,"xp":0},
  "tokens": {"balance": 0, "earnedToday": 0, "windowStartedAt": "2026-04-19T00:00:00Z"},
  "meta": {"totalHatches": 1, "pityCounter": 0}
}
JSON

  BUDDY_SPECIES_DIR="$fixture_dir" NO_COLOR=1 run --separate-stderr bash "$INTERACT_SH"
  [ "$status" -eq 0 ]
  # Strict assertion — pin the bank-line picked, not just substring overlap with
  # the placeholder. Placeholder must NOT appear when the bank is populated.
  [[ "$output" == *"whirr-distinctive-fixture-line"* ]]
  [[ "$output" != *"looks at you curiously"* ]]
}

@test "interact: invariant — does not mutate buddy.json or session-*.json across two runs" {
  _seed_hatch
  # Touch a session file so we can also pin its byte-identity through the run.
  echo '{"sessionId":"abc","commentsThisSession":0}' \
    > "$CLAUDE_PLUGIN_DATA/session-abc.json"

  local before_buddy before_session
  before_buddy="$(cat "$CLAUDE_PLUGIN_DATA/buddy.json")"
  before_session="$(cat "$CLAUDE_PLUGIN_DATA/session-abc.json")"

  bash "$INTERACT_SH" >/dev/null
  bash "$INTERACT_SH" >/dev/null

  [ "$before_buddy" = "$(cat "$CLAUDE_PLUGIN_DATA/buddy.json")" ]
  [ "$before_session" = "$(cat "$CLAUDE_PLUGIN_DATA/session-abc.json")" ]
}
