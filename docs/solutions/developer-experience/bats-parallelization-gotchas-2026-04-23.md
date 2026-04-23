---
title: bats parallelization — three gotchas when speeding up a bats suite
date: 2026-04-23
category: developer-experience
module: testing_framework
problem_type: developer_experience
component: tooling
severity: medium
applies_when:
  - Speeding up a bats-core test suite that runs serially today
  - Introducing `bats --jobs N` and it appears to "work" but runs zero tests
  - Moving test files into a tiered directory structure (`tests/unit/`, `tests/integration/`)
  - Attempting to hoist expensive per-test `setup` work into `setup_file`
  - Reviewing a PR that touches test infrastructure or wrappers around bats
related_components:
  - testing_framework
  - bats-core
tags:
  - bats
  - bats-core
  - test-performance
  - parallel-execution
  - setup_file
  - gnu-parallel
  - recursion
  - test-tiering
---

# bats parallelization — three gotchas when speeding up a bats suite

## Context

The buddy plugin's bats suite grew to 217 scenarios. Per-test logic
was ~70 ms (fast) but wall-clock was 18 minutes 36 seconds on an
8-core devcontainer running at 21 % CPU — the suite was blocked on
serial process spawns, not on test logic. The obvious fix was
`bats --jobs N` plus some structural changes to tier and cache
fixtures. Shipping that took one afternoon. Three bats behaviors
that looked innocuous cost measurable debug time.

None of these are documented prominently in bats-core's README.
Writing this down so the next suite speedup does not re-discover
them.

## Guidance

### A. `bats --jobs N` silently runs zero tests without GNU parallel

`bats --jobs 4 tests/` requires the GNU `parallel` CLI on `PATH`.
Without it, bats prints one unhelpful line to stderr and exits 0:

```
/.../bats-core/libexec/bats-core/bats-exec-suite: line 314: parallel: command not found
# bats warning: Executed 0 instead of expected 217 tests
```

The warning is the only signal — CI parses `pass/fail counts` not
`expected/actual counts` in most setups, so a broken parallel
invocation masquerades as a **green** run with no tests. This is
the worst kind of failure mode for a performance optimization: it
looks like you sped up your suite to infinity.

**Mitigation:** every wrapper script that forwards `--jobs` to bats
must probe for `parallel` and fail loudly:

```bash
if ! command -v parallel >/dev/null 2>&1; then
  echo "run-all.sh: GNU parallel is required for --jobs execution but is not installed." >&2
  echo "  Ubuntu/Debian: sudo apt-get install -y parallel" >&2
  echo "  macOS:         brew install parallel" >&2
  exit 2
fi
```

For a devcontainer or CI image, treat `parallel` as a dependency
and install it in the image rather than relying on every contributor
to have it. The buddy plugin documents this in
[tests/.perf-baseline.md](../../../tests/.perf-baseline.md).

### B. `setup_file` propagates env vars, NOT functions, to `@test`

bats documents `setup_file` as "once per file, for common setup,"
which invites the assumption that libraries sourced in `setup_file`
will be available in `@test`. Empirically confirmed: they are not.
Each `@test` runs in its own bash subshell. `setup_file` runs in a
different subshell. Only **exported env vars** survive the boundary.

A minimal repro:

```bash
#!/usr/bin/env bats
setup_file() {
  export MY_VAR=hi     # ✓ visible to @test
  my_fn() { echo hi; } # ✗ NOT visible to @test
}

@test "var propagates" { [ "$MY_VAR" = "hi" ]; }      # PASS
@test "fn does not"   { run my_fn; [ $status -eq 127 ]; }  # PASS (fn not found)
```

This rules out a tempting optimization: hoisting `source
scripts/lib/state.sh` from per-test `setup` to per-file
`setup_file`. The sourced functions are defined in `setup_file`'s
shell and evaporate before the first `@test` runs. Each `@test`
must still re-source, and the "once-per-file" savings never
materialize.

What `setup_file` **does** reliably amortize is **filesystem-
fixture caching**. Pre-compute an expensive artifact (a canonical
hatched buddy envelope, a fixture JSON, a prepared temp dir) to
`$BATS_FILE_TMPDIR`, then have each per-test `setup` `cp` it into
`$BATS_TEST_TMPDIR`. Both variables are exported; the filesystem
is the shared channel.

```bash
# tests/test_helper.bash
_prepare_hatched_cache() {
  local cache="$BATS_FILE_TMPDIR/seed42-hatched.json"
  [[ -f "$cache" ]] && return 0
  local scratch="$BATS_FILE_TMPDIR/hatch-scratch"
  mkdir -p "$scratch"
  CLAUDE_PLUGIN_DATA="$scratch" BUDDY_RNG_SEED=42 bash "$HATCH_SH" >/dev/null
  cp "$scratch/buddy.json" "$cache"
}

_seed_hatch() {
  local seed="${1:-42}"
  if [[ "$seed" == "42" \
        && -n "${BATS_FILE_TMPDIR:-}" \
        && -f "$BATS_FILE_TMPDIR/seed42-hatched.json" ]]; then
    cp "$BATS_FILE_TMPDIR/seed42-hatched.json" "$CLAUDE_PLUGIN_DATA/buddy.json"
    return 0
  fi
  BUDDY_RNG_SEED="$seed" bash "$HATCH_SH" >/dev/null
}

# tests/integration/slash.bats
setup_file() {
  _prepare_hatched_cache
}
```

The 71 `_seed_hatch` call sites each save ~80 ms of user CPU (5
jq forks in `roll_buddy` → 1 `cp`). Total: ~5-6 s per suite run.

### C. `bats DIR/` recurses **one level only**; `-r` picks up vendored fixtures

`bats DIR/` descends **one directory** looking for `.bats` files.
It does **not** recurse arbitrarily.

Practical consequence: after tiering your suite into
`tests/unit/` and `tests/integration/`, `bats tests/` finds **zero**
tests because `tests/` itself no longer has direct `.bats`
children — they all moved down a level. The suite looks empty.

```bash
# Before tier split:
bats tests/               # finds all .bats under tests/ and tests/hooks/ (works)

# After tier split to tests/unit/ and tests/integration/:
bats tests/               # finds 0 tests (silently)
bats tests/unit/          # finds tests/unit/*.bats AND tests/unit/hooks/*.bats (works)
bats -r tests/            # recurses everywhere — INCLUDING tests/bats-core/test/
                          #   which is the vendored bats-core's own test suite
                          #   and fails with "MARKER_FILE: parameter not set"
```

The `-r` recursive flag is also a trap: if you vendor `bats-core`
inside `tests/` (as this project does), `-r` descends into the
vendored runner's own fixture tests and fails on them.

**Mitigation:** pass tier directories explicitly in wrapper scripts:

```bash
# tests/run-all.sh
exec "$BATS_BIN" --jobs 4 --timing "$@" tests/unit/ tests/integration/
```

This finds every tier while excluding the vendored runner by
omission. Adding a new tier later requires touching only the
wrapper — a small price for no surprise recursion.

## Why This Matters

All three gotchas share the same shape: **a plausible mental model
fails silently**. The suite looks green; CI looks green; the actual
coverage is zero or partial. A performance optimization whose worst
failure mode is "silently reduce coverage to 0" is worse than no
optimization — it looks like progress while eroding the safety net.

For the buddy plugin specifically these three took roughly 30
minutes combined to debug. For a larger project with more test
files, more tiers, or a more opaque CI harness, each one could
cost hours. Writing them down once prevents the re-discovery tax.

## When to Apply

- Proposing parallel bats execution for any project.
- Reviewing a PR that adds a `tests/run-*.sh` wrapper around bats.
- Moving tests into a tiered directory layout
  (`tests/unit/`, `tests/integration/`, `tests/e2e/`, etc.).
- A "successful" test-infrastructure change that also (coincidentally)
  reports much faster wall-clock — verify test count first.
- Writing a devcontainer / CI image that will run bats in parallel:
  pin GNU `parallel` as a dependency.

## Examples

### A. Parallel probe in a wrapper

See
[tests/run-all.sh](../../../tests/run-all.sh) and
[tests/run-quick.sh](../../../tests/run-quick.sh) for the project's
implementation.

### B. setup_file fixture caching

See
[tests/test_helper.bash](../../../tests/test_helper.bash) —
`_prepare_hatched_cache` writes once to `$BATS_FILE_TMPDIR`;
`_seed_hatch` prefers the cache over re-running the RNG.

### C. Explicit tier directories in the wrapper

Repo example:

```bash
# tests/run-all.sh — after tier split
cd "$REPO_ROOT"
exec "$BATS_BIN" --jobs 4 --timing "$@" tests/unit/ tests/integration/
```

## Numbers from the suite speedup

| Config | Wall-clock | Speedup vs serial |
|--------|-----------:|------------------:|
| serial | 18:36 | 1.0× |
| `--jobs 4` | 1:27 | 12.7× |
| `--jobs 8` | 0:59 | 18.6× |

Picked `--jobs 4` as the default: 93 % of the max speedup without
saturating all cores on a devcontainer shared with editor and agent
processes. Full table in
[tests/.perf-baseline.md](../../../tests/.perf-baseline.md).

## Related

- [bash-jq-fork-collapse-hot-path-2026-04-21](../best-practices/bash-jq-fork-collapse-hot-path-2026-04-21.md)
  — the fork-cost numbers apply to test setup too. Each
  `_seed_hatch` fork saved by the cache is 5 jq invocations
  avoided. Same cost model.
- [bash-state-library-patterns-2026-04-18](../best-practices/bash-state-library-patterns-2026-04-18.md)
  — the state library whose `roll_buddy` jq forks dominate
  `_seed_hatch` cost.
- bats-core parallel execution docs:
  https://bats-core.readthedocs.io/en/stable/usage.html#parallel-execution
- Test-speed plan: [docs/plans/2026-04-22-001-perf-test-suite-speed-plan.md](../../plans/2026-04-22-001-perf-test-suite-speed-plan.md)
  — the plan that landed these changes. Unit 3's
  "hoist library sourcing into `setup_file`" was empirically
  determined to not work during execution; the plan notes the
  supersession.
