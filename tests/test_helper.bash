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
#
# For non-default seeds, always re-runs hatch.sh (no caching since the
# output depends on the seed). For the default seed (42), prefers the
# per-file cache written by `_prepare_hatched_cache` (see below) —
# this cuts ~80-100 ms per call (5 jq forks in roll_buddy) and adds up
# fast across a 70+ call-site suite.
_seed_hatch() {
  local seed="${1:-42}"
  if [[ "$seed" == "42" \
        && -n "${BATS_FILE_TMPDIR:-}" \
        && -f "$BATS_FILE_TMPDIR/seed42-hatched.json" ]]; then
    cp "$BATS_FILE_TMPDIR/seed42-hatched.json" "$CLAUDE_PLUGIN_DATA/buddy.json"
    # buddy_save opens (and thus creates) buddy.json.lock as part of
    # its flock dance. Replicate that here so tests that assert on the
    # lock file's existence (e.g., reset state_cleanup_orphans
    # preservation check) don't fail under the cache path.
    : > "$CLAUDE_PLUGIN_DATA/buddy.json.lock"
    return 0
  fi
  BUDDY_RNG_SEED="$seed" bash "$HATCH_SH" >/dev/null
}

# Pre-compute a hatched buddy envelope at seed 42 and stash it under
# $BATS_FILE_TMPDIR so every `_seed_hatch` call in the file can `cp`
# instead of re-running the RNG. Call from a file's `setup_file()`:
#
#   setup_file() {
#     export BATS_FILE_TMPDIR  # exposed to per-test setup
#     _prepare_hatched_cache
#   }
#
# The function is idempotent — a second call within the same file
# short-circuits.
_prepare_hatched_cache() {
  local cache="$BATS_FILE_TMPDIR/seed42-hatched.json"
  [[ -f "$cache" ]] && return 0
  local scratch="$BATS_FILE_TMPDIR/hatch-scratch"
  mkdir -p "$scratch"
  CLAUDE_PLUGIN_DATA="$scratch" BUDDY_RNG_SEED=42 bash "$HATCH_SH" >/dev/null
  cp "$scratch/buddy.json" "$cache"
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
