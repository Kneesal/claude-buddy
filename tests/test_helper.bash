#!/usr/bin/env bash
# test_helper.bash — shared setup/teardown for state.sh tests

# Path to the state library (relative to repo root)
STATE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/lib/state.sh"

setup() {
  # Each test gets its own isolated CLAUDE_PLUGIN_DATA in bats temp dir
  export CLAUDE_PLUGIN_DATA="$BATS_TEST_TMPDIR/plugin-data"
  mkdir -p "$CLAUDE_PLUGIN_DATA"

  # Source the state library
  source "$STATE_LIB"
}

teardown() {
  # bats cleans up BATS_TEST_TMPDIR automatically
  :
}
