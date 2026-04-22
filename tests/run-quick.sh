#!/usr/bin/env bash
# run-quick.sh — tight-loop test runner for the fast "unit" tier.
#
# The unit tier consists of tests that exercise pure-bash library
# functions (evolution.sh, rng.sh, signals.sh, commentary.sh,
# common.sh) plus structural JSON checks (species_line_banks.bats).
# These tests don't spawn subprocesses for hook/slash/statusline
# invocation, so they're the cheapest to run during iteration.
#
# After Unit 5 of the test-speed plan lands, this script will point
# at tests/unit/. Until then, it uses an explicit file list.
#
# Usage:
#   ./tests/run-quick.sh              # run the whole unit tier
#   ./tests/run-quick.sh --filter pat # forward any flag to bats
#
# Exit code is bats' exit code.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BATS_BIN="$SCRIPT_DIR/bats-core/bin/bats"

if [[ ! -x "$BATS_BIN" ]]; then
  echo "run-quick.sh: vendored bats not found at $BATS_BIN" >&2
  exit 2
fi

if ! command -v parallel >/dev/null 2>&1; then
  echo "run-quick.sh: GNU parallel is required for --jobs execution but is not installed." >&2
  echo "  Ubuntu/Debian: sudo apt-get install -y parallel" >&2
  echo "  macOS:         brew install parallel" >&2
  exit 2
fi

cd "$REPO_ROOT"
# tests/unit/ is the tier directory — every .bats file under it is
# either a pure-library assertion (evolution.sh, rng.sh, signals.sh,
# commentary.sh, common.sh) or a structural-shape check (species
# JSON). No subprocess spawns for hook/slash/statusline scripts.
exec "$BATS_BIN" --jobs 4 --timing "$@" tests/unit/
