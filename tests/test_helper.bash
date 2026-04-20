#!/usr/bin/env bash
# test_helper.bash — shared setup/teardown for state.sh and rng.sh tests

# Paths to libraries (relative to repo root)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_LIB="$REPO_ROOT/scripts/lib/state.sh"
RNG_LIB="$REPO_ROOT/scripts/lib/rng.sh"
SPECIES_DIR="$REPO_ROOT/scripts/species"

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
