#!/usr/bin/env bash
# run-all.sh — run the full bats suite in parallel.
#
# Default: --jobs 4 on an 8-core box (see tests/.perf-baseline.md).
# Users can override with --jobs N or any other bats flag; extra args
# are forwarded to bats verbatim.
#
# Exit code is bats' exit code.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BATS_BIN="$SCRIPT_DIR/bats-core/bin/bats"

if [[ ! -x "$BATS_BIN" ]]; then
  echo "run-all.sh: vendored bats not found at $BATS_BIN" >&2
  echo "  Expected the bats-core submodule/vendor to be present under tests/bats-core/." >&2
  exit 2
fi

# bats' --jobs flag requires GNU parallel. Without it, bats silently
# runs 0 tests and reports "Executed 0 instead of expected 217 tests",
# which is a terrible failure mode — check up front.
if ! command -v parallel >/dev/null 2>&1; then
  echo "run-all.sh: GNU parallel is required for --jobs execution but is not installed." >&2
  echo "  Ubuntu/Debian: sudo apt-get install -y parallel" >&2
  echo "  macOS:         brew install parallel" >&2
  echo "  Or run serially with: $BATS_BIN tests/" >&2
  exit 2
fi

# Default jobs = 4 (covers ~93% of max speedup on this devcontainer;
# see tests/.perf-baseline.md). User-supplied --jobs wins because it
# appears later on the bats command line.
cd "$REPO_ROOT"
# Pass both tier directories explicitly — bats recurses one level
# into a directory arg, so tests/unit/ finds tests/unit/hooks/ too,
# but tests/ alone would only find direct children (none now that
# the tier split has moved everything down). tests/bats-core/ is
# excluded by construction since it's not listed.
exec "$BATS_BIN" --jobs 4 --timing "$@" tests/unit/ tests/integration/
