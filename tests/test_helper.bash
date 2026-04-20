#!/usr/bin/env bash
# test_helper.bash — shared setup/teardown for state.sh and rng.sh tests

# Paths to libraries (relative to repo root)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_LIB="$REPO_ROOT/scripts/lib/state.sh"
RNG_LIB="$REPO_ROOT/scripts/lib/rng.sh"
SPECIES_DIR="$REPO_ROOT/scripts/species"

# Paths to dispatch scripts — used by slash.bats and statusline.bats.
HATCH_SH="$REPO_ROOT/scripts/hatch.sh"
STATUS_SH="$REPO_ROOT/scripts/status.sh"
RESET_SH="$REPO_ROOT/scripts/reset.sh"
STATUSLINE_SH="$REPO_ROOT/statusline/buddy-line.sh"

setup() {
  # Each test gets its own isolated CLAUDE_PLUGIN_DATA in bats temp dir
  export CLAUDE_PLUGIN_DATA="$BATS_TEST_TMPDIR/plugin-data"
  mkdir -p "$CLAUDE_PLUGIN_DATA"

  # Reset any rng test hooks — individual tests opt in explicitly
  unset BUDDY_RNG_SEED
  unset BUDDY_SPECIES_DIR

  # Source the state library (rng tests source rng.sh individually to control state)
  source "$STATE_LIB"
}

teardown() {
  # bats cleans up BATS_TEST_TMPDIR automatically
  :
}

# -----------------------------------------------------------------------------
# Shared state-seeding helpers. Both slash.bats and statusline.bats need these
# for their ACTIVE/CORRUPT/FUTURE_VERSION scenarios; hoisting them keeps the
# seeding contract single-sourced.
# -----------------------------------------------------------------------------

# Seed a deterministic first hatch. With BUDDY_RNG_SEED=42 the roll pins to a
# Common axolotl named Custard (pinned in tests/rng.bats and referenced by
# seed-determinism assertions in tests/slash.bats and tests/statusline.bats).
_seed_hatch() {
  local seed="${1:-42}"
  BUDDY_RNG_SEED="$seed" bash "$HATCH_SH" >/dev/null
}

_seed_corrupt() {
  echo '{"schema' > "$CLAUDE_PLUGIN_DATA/buddy.json"
}

_seed_future_version() {
  echo '{"schemaVersion": 999, "buddy": {}}' > "$CLAUDE_PLUGIN_DATA/buddy.json"
}

# Inject tokens directly into an existing envelope. Used to exercise the
# reroll-paid path and ACTIVE-state tests that need a specific balance while
# P5 (token economy) isn't built yet. Note: bypasses flock — safe under bats'
# per-test CLAUDE_PLUGIN_DATA isolation where there are no concurrent writers.
_inject_tokens() {
  local n="$1"
  local buddy_file="$CLAUDE_PLUGIN_DATA/buddy.json"
  local tmp
  tmp="$(mktemp "$CLAUDE_PLUGIN_DATA/.inject.XXXXXX")"
  jq --argjson v "$n" '.tokens.balance = $v' "$buddy_file" > "$tmp"
  mv -f "$tmp" "$buddy_file"
}
