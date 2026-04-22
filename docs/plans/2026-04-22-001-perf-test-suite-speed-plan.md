---
title: Speed up the bats suite — tiered layout + parallel execution + setup-cost reduction
type: perf
status: complete
date: 2026-04-22
---

# Speed up the bats suite — tiered layout + parallel execution + setup-cost reduction

## Overview

The full bats suite (`./tests/bats-core/bin/bats tests/`) now takes **18
minutes 36 seconds** for 217 scenarios on this devcontainer. The pain
is real: during P4-1 iteration every "run the tests" step stalled
collaboration for the time it takes to walk to a coffee machine. This
plan cuts that to under 2 minutes for the tight-loop case and under 3
minutes for the full-suite case, without sacrificing coverage.

## Problem Frame

Per-test actual logic is cheap — the median scenario completes in
~70 ms, and only three scenarios exceed 100 ms. But the wall-clock
budget is ~5 100 ms **per** scenario. The delta is bats + bash overhead:
each `@test` is a fresh bash process that re-sources `scripts/lib/state.sh`,
creates a temp dir, possibly runs `scripts/hatch.sh` (which spawns jq
forks for `roll_buddy`), then tears down. That setup pattern is correct
in isolation but executes ~217 times serially on a box where process
fork + filesystem sync are the dominant cost, not the test logic itself.

Three observations pin the shape of the problem:

1. **CPU utilization during the suite is 21 %.** The other 79 % is
   blocked on process creation and disk fsync — embarrassingly
   parallel at the file level.
2. **The statusline suite alone accounts for ~60-120 ms × 29 tests ≈
   2.5-3.5 s of the budget** but contributes ~17 s of wall-clock
   because each scenario shells out to a subprocess that itself does
   a buddy hatch roll.
3. **Hook-integration tests spawn the hook as a subprocess**
   (`"$POST_SH"`) per `@test`, and each hook invocation re-sources
   four libraries. Hatch+hook in one test ≈ 200 ms of real work inside
   ~5 s of bash/bats overhead.

## Requirements Trace

- **R1.** A "tight-loop" subset (unit tests for lib helpers and pure
  functions) runs under 2 minutes on this devcontainer.
- **R2.** The full suite runs under 3 minutes.
- **R3.** No loss of coverage — the same 217 scenarios still run, just
  faster and grouped.
- **R4.** The speed-up does not mask real regressions (e.g., flakes
  introduced by parallelism). Any test that becomes flaky under
  parallelism is either isolated or opted out of parallel mode
  explicitly.
- **R5.** The default `make test` or equivalent entry point still
  runs the full suite so CI (when we add it) does not need special
  wiring.

## Scope Boundaries

- No change to what each `@test` asserts — the fix is infrastructure,
  not semantics.
- No new test framework — stay on bats-core (already vendored under
  `tests/bats-core/`).
- No migration of existing tests to a different layout unless the
  speed win requires it; target is to make the current file structure
  faster first.
- No CI changes — this plan ships local-dev wins only; CI plumbing is
  a separate future ticket.
- No changes to hook scripts themselves (those are under a p95 budget
  enforced elsewhere).

### Deferred to Separate Tasks

- **CI integration** — GitHub Actions / pre-commit hook to run the
  suite automatically. Prereq: some version of this plan lands first.
- **Per-file test runners in SKILL.md for /buddy:\* commands** — not
  relevant to this plan.

## Context & Research

### Relevant Code and Patterns

- `tests/bats-core/` — vendored bats. Version check: the `--jobs`
  flag for parallel execution is supported in bats-core 1.5.0+.
  `bats_require_minimum_version 1.5.0` already appears at the top of
  every test file in the repo, so parallelism is available today
  without a bats upgrade.
- `tests/test_helper.bash` — the shared setup function. Every test
  inherits `setup()` which:
  1. Sets `CLAUDE_PLUGIN_DATA` to `$BATS_TEST_TMPDIR/plugin-data`
  2. Runs `mkdir -p` on it
  3. Unsets two env vars
  4. Sources `STATE_LIB`
  This is the common-path overhead.
- `tests/test_helper.bash:_seed_hatch` — 13 of the per-test paths
  call this, which invokes `scripts/hatch.sh` as a subprocess. Each
  `_seed_hatch` adds ~80-100 ms because `roll_buddy` forks jq ~5
  times. Running 13 seeds serially inside a 217-test suite is ~1.3 s
  of pure hatch work, multiplied by the bats per-test cost ceiling
  becomes ~65 s of measured wall-clock.
- `tests/statusline.bats` — 29 scenarios, each calling
  `statusline/buddy-line.sh` as a subprocess. This is the single
  largest concentration of subprocess-spawn cost in the suite.
- `tests/hooks/test_*.bats` — each hook-integration `@test` fires the
  hook under test via `_fire`, which is another subprocess spawn.
- `tests/hooks/perf_hook_p95.sh` — NOT part of the bats suite; run
  separately. Out of scope for this plan.

### Institutional Learnings

- [bash-jq-fork-collapse-hot-path-2026-04-21](../solutions/best-practices/bash-jq-fork-collapse-hot-path-2026-04-21.md)
  — the fork-cost numbers at the bottom (jq ≈ 5-20 ms, subshell ≈
  1-3 ms) apply to test setup too. A test that forks 5 jqs just to
  seed state is paying 25-100 ms before its first assertion.
- [bash-state-library-patterns-2026-04-18](../solutions/best-practices/bash-state-library-patterns-2026-04-18.md)
  — the "atomic write with flock" discipline. Parallel tests would
  stress this if they shared `CLAUDE_PLUGIN_DATA`; they don't (each
  test gets its own tmpdir), so file-level parallelism is safe.

### External References

- bats-core parallel execution: https://bats-core.readthedocs.io/en/stable/usage.html#parallel-execution
- bats-core docs on `setup_file` (run-once-per-file setup): referenced
  as part of Unit 3. Available in the vendored 1.5+ series.

## Key Technical Decisions

**D1. Parallelize with `--jobs N` is the single biggest lever.** The
devcontainer has multiple cores and the suite runs at 21 % CPU on one
of them. `--jobs 4` should push that toward full use without changing
semantics — every `@test` already uses its own `BATS_TEST_TMPDIR`, so
there is no shared mutable state to race on. Target: 4-jobs parallel
brings the 18 min run down to ~4-5 min at the algorithmic limit of the
longest single file.

**D2. Tier the suite into `unit/` and `integration/`.** Unit tests
(pure bash functions from `scripts/lib/` and `scripts/hooks/`) can
run in one bash process per file via `setup_file` + direct-sourcing.
Integration tests (hooks, slash commands, statusline) must keep
subprocess fidelity. The tight-loop entry point runs unit only.

**D3. Use `setup_file` to amortize library sourcing + common seeding.**
bats supports `setup_file` (once per file) and `setup` (once per test).
Today everything is in `setup`. Moving library-source + reusable
no-mutation seeding to `setup_file` is a one-line-per-file win that
cuts per-test cost by whatever the source-time is (~50-100 ms on this
box, per file) — a ~1-minute wall-clock saving across the suite.

**D4. Cache the hatched buddy JSON once per test file, not per test.**
For files that want a baseline ACTIVE buddy, run `_seed_hatch` in
`setup_file` to produce a canonical JSON blob and write it to a file
alongside the tests. Per-test `setup` then copies the pre-hatched JSON
into the fresh tmpdir instead of running the hatch roller. Saves the
RNG-fork overhead on every test that needs a buddy.

**D5. A `make test-quick` target (or `./tests/run-quick.sh` wrapper)
invokes only the unit tier with `--jobs`.** The full-suite entry
stays as-is. Users get "under 2 minutes" for the tight loop without
having to remember flags.

**D6. Statusline tests deserve their own fast path.** They are 29 of
the 217 scenarios (13 %) and contribute a disproportionate chunk of
wall-clock (~17 s measured) because each spawns the statusline
subprocess. Either:
- (a) Parallelize statusline.bats specifically with `--jobs 8` (more
  concurrency since each test is isolated), OR
- (b) Refactor so that rendering tests call a helper function in the
  current shell instead of invoking the script subprocess.
Pick (a) for this plan; (b) is architectural and out of scope.

**D7. Opt specific tests out of parallel execution** only if they
prove flaky under `--jobs`. Expected candidates: the concurrency
tests in `tests/hooks/test_post_tool_use.bats` and
`tests/state.bats:"session_save under concurrent load-modify-save"`,
which deliberately background-fire hooks and could interleave poorly
with parallel-siblings contending on the same resources — but they
already use `BATS_TEST_TMPDIR` isolation, so they should be fine. Only
opt out after measuring.

**D8. Preserve exact coverage.** No `@test` is deleted, split, or
merged in this plan. Every scenario that ran before still runs.

## Open Questions

### Resolved During Planning

- **Is bats-core `--jobs` available?** Yes, vendored version supports
  it (1.5+).
- **Does parallel execution require shared-state work?** No —
  `BATS_TEST_TMPDIR` isolates per test. Confirmed by reading
  test_helper.bash.
- **Statusline subprocess cost — inevitable or refactorable?** For
  this plan: inevitable; parallelize instead (D6a).

### Deferred to Implementation

- The exact `--jobs` number. Start at 4, measure, iterate.
- Which tests (if any) need `--no-parallelize-across-files` or
  `--no-parallelize-within-file` opt-outs. Only determinable
  empirically.
- Whether `setup_file` hatched-buddy caching needs a fixture
  directory (e.g., `tests/fixtures/hatched-common-axolotl.json`) or
  can just live in `$BATS_FILE_TMPDIR`.

## High-Level Technical Design

> *Directional guidance, not implementation specification.*

Current layout (one tier, serial):

```
tests/
├── bats-core/          # vendored runner
├── test_helper.bash    # shared setup/teardown, helpers
├── evolution.bats      # 22 unit tests — pure lib
├── rng.bats            # ~25 unit tests — pure lib
├── state.bats          # ~60 mixed (some spawn subprocesses)
├── slash.bats          # ~40 integration — spawns hatch/status/reset
├── species_line_banks.bats  # structural JSON checks
├── statusline.bats     # 29 integration — spawns statusline
└── hooks/
    ├── test_common.bats       # unit
    ├── test_commentary.bats   # unit (sources commentary.sh)
    ├── test_signals.bats      # unit (sources signals.sh)
    ├── test_post_tool_use.bats        # integration — fires hook
    ├── test_post_tool_use_failure.bats # integration
    ├── test_stop.bats                 # integration
    ├── test_session_start.bats        # integration
    └── test_week_simulation.bats      # integration-ish
```

Target layout (two tiers, same files, explicit tier declaration):

```
tests/
├── bats-core/
├── test_helper.bash               # shared; adds setup_file helper
├── run-quick.sh                   # NEW: wraps bats --jobs 4 tier:unit
├── run-all.sh                     # NEW: wraps bats --jobs 4 tests/
├── unit/                          # MOVE here OR tag via filename suffix
│   ├── evolution.bats
│   ├── rng.bats
│   ├── species_line_banks.bats
│   └── hooks/
│       ├── test_common.bats
│       ├── test_commentary.bats
│       └── test_signals.bats
└── integration/
    ├── state.bats
    ├── slash.bats
    ├── statusline.bats
    └── hooks/
        ├── test_post_tool_use.bats
        ├── test_post_tool_use_failure.bats
        ├── test_stop.bats
        ├── test_session_start.bats
        └── test_week_simulation.bats
```

**Execution shape:**

- `./tests/run-quick.sh` → `bats --jobs 4 tests/unit/` → ~30-60 s
- `./tests/run-all.sh` → `bats --jobs 4 tests/` → ~2-3 min
- `./tests/bats-core/bin/bats tests/` → unchanged, full-suite serial
  (for debugging / CI without jobs flag)

If physical file moves are too intrusive, an alternative uses bats
tags (requires bats 1.10+, NOT in our vendored version) or naming
conventions (`*_unit.bats` vs `*_integration.bats`) — but moving
directories is the least ambiguous.

## Implementation Units

- [x] **Unit 1: Baseline measurement + parallel-jobs spike**

**Goal:** Establish a shared measurement baseline, then empirically
validate that `--jobs N` yields a meaningful speed-up with no new
failures.

**Dependencies:** None.

**Files:**
- Create: `tests/.perf-baseline.md` — append-only log of suite run
  times at each commit.
- No code changes yet.

**Approach:**
- Run the full suite 3x serially, record wall-clock median.
- Run with `--jobs 2`, `--jobs 4`, `--jobs 8`, record each. Note
  which (if any) expose flakes.
- Pick the lowest `N` that captures ~80 % of the speed-up.

**Test scenarios:**
- Not applicable — this unit is a measurement exercise. Completion
  criterion: baseline numbers written to `.perf-baseline.md` and a
  recommended `--jobs` value committed to the plan's Notes.

**Verification:**
- `.perf-baseline.md` has at least 4 rows (serial + 3 parallel
  settings). Every row records pass/fail counts alongside time.

---

- [x] **Unit 2: `tests/run-quick.sh` + `tests/run-all.sh` wrappers**

**Goal:** Give the user two one-shot commands for the two common
cases without needing to remember flags.

**Dependencies:** Unit 1 (know the right `--jobs` value).

**Files:**
- Create: `tests/run-quick.sh`
- Create: `tests/run-all.sh`
- Modify: `README.md` or `CLAUDE.md` — add a "Running tests" section
  pointing at the wrappers. (If the repo does not already have a
  testing section, skip the docs change for this unit and defer to a
  docs-pass ticket.)

**Approach:**
- Each wrapper is ~10 lines of bash: set `cd` to repo root, point at
  vendored bats, pass `--jobs N --timing` + the relevant test
  directory.
- `run-quick.sh` additionally accepts `-k <pattern>` forwarded to
  `bats --filter`, so the tight loop can narrow further.

**Patterns to follow:**
- `scripts/hatch.sh` top: `set -euo pipefail` discipline and
  explicit error handling.
- bats-core CLI conventions (use `--jobs`, `--timing`, `--filter`).

**Test scenarios:**
- Happy path: `./tests/run-all.sh` exits 0 and reports all 217 tests.
- Error path: `./tests/run-all.sh` exits non-zero if any test fails.
- Edge case: `./tests/run-quick.sh -k evolution` runs only
  evolution-matching tests.

**Verification:**
- Both wrappers run the intended subsets green.

---

- [x] **Unit 3: Hoist library sourcing into `setup_file` — SUPERSEDED**

**Status:** Investigated during execution, superseded by the
merged Unit 3+4 work below. bats empirically confirms:
`setup_file`-defined functions do **not** propagate to per-test
`@test` subshells — only exported env vars do. Sourcing libraries
in `setup_file` would therefore save nothing, because each `@test`
still needs to re-source in its own shell.

Where `setup_file` DOES pay off is filesystem-fixture caching:
pre-compute expensive artifacts to `$BATS_FILE_TMPDIR` once per
file, and have per-test `setup` copy them into each scenario's
isolated `$CLAUDE_PLUGIN_DATA`. That is Unit 4's scope, so the
planned savings land there.

This doc is kept as a pointer to the empirical finding so future
readers don't re-attempt the function-hoist path.

**Files touched:** None (no code change; the work is all in Unit 4).

---

- [x] **Unit 4: Cache hatched-buddy JSON via `setup_file`**

**Goal:** Test files that need an ACTIVE buddy state should hatch
**once per file**, not once per test.

**Dependencies:** Unit 3.

**Files:**
- Modify: `tests/test_helper.bash` — add `_seed_hatch_once_per_file`
  helper that writes to `$BATS_FILE_TMPDIR/buddy.json` and a
  per-test `_copy_seeded_hatch` that cps from there to
  `$CLAUDE_PLUGIN_DATA`.
- Modify: `tests/slash.bats`, `tests/statusline.bats`, and any
  hook-integration file that currently calls `_seed_hatch` on every
  test — swap for the new pattern.
- Preserve: tests that intentionally exercise the first-hatch code
  path (e.g., `@test "hatch: first hatch on NO_BUDDY creates a valid
  envelope"`) — they must keep calling `_seed_hatch` directly.

**Approach:**
- Use `BUDDY_RNG_SEED=42` in `setup_file` to produce a canonical
  envelope, then in per-test `setup` do a `cp` + `chmod`. Avoids
  forking hatch.sh once per test.

**Test scenarios:**
- Every file that previously hatched per-test now hatches per-file
  and copies on setup. No test output changes.
- A per-file test that asserts the hatched file contents match the
  cached one ensures no cross-contamination from earlier tests.

**Verification:**
- Full suite green; wall-clock shrinks further.

---

- [x] **Unit 5: Physical tier split into `tests/unit/` and
  `tests/integration/`**

**Goal:** Directory-level separation so `run-quick.sh` can target
`tests/unit/` unambiguously.

**Dependencies:** Unit 2 (wrappers exist and can be re-pointed),
Unit 3 + Unit 4 (the savings are real).

**Files:**
- Move: `tests/evolution.bats` → `tests/unit/evolution.bats`
- Move: `tests/rng.bats` → `tests/unit/rng.bats`
- Move: `tests/species_line_banks.bats` → `tests/unit/`
- Move: `tests/hooks/test_common.bats`,
  `tests/hooks/test_commentary.bats`,
  `tests/hooks/test_signals.bats` → `tests/unit/hooks/`
- Move: everything else → `tests/integration/` (matching
  subdirectory structure under `hooks/`)
- Modify: `tests/test_helper.bash` — update `REPO_ROOT` /
  `SPECIES_DIR` / etc. path calculations to survive the deeper
  nesting.
- Modify: `tests/run-quick.sh` to point at `tests/unit/`.
- Modify: `tests/run-all.sh` to point at `tests/` (unchanged scope).
- Modify: any tests/perf_hook_p95.sh-style helpers that walk up to
  `REPO_ROOT` via `dirname/..`.

**Approach:**
- Do the moves in a single commit. All test file contents stay the
  same.
- Run the full suite after the move; fix any broken path references
  in helpers before the PR.

**Test scenarios:**
- Full suite still green after the move.
- `tests/run-quick.sh` runs only unit tests and completes under 2
  minutes.
- `tests/run-all.sh` runs all 217 and completes under 3 minutes.

**Verification:**
- Both wrappers hit their wall-clock targets on this devcontainer.
- `.perf-baseline.md` gains a "post-Unit-5" row beating the Unit 1
  baseline by ~6-10×.

---

- [x] **Unit 6: Flake audit + per-file opt-out documentation**

**Goal:** Catch any parallelism-induced flake and document the
opt-out mechanism for future tests that can't share the devcontainer
concurrently.

**Dependencies:** Unit 5 shipped and running.

**Files:**
- Modify: `tests/.perf-baseline.md` — add a "Flake audit" section.
- Possibly modify: any test that proves flaky — add
  `# bats disable-parallel-within-file` or move to a serial-only
  directory.
- Modify: the testing section of `CLAUDE.md` or a new
  `tests/README.md` documenting the `run-quick.sh` / `run-all.sh`
  entry points and the rules for serial-only tests.

**Approach:**
- Run `run-all.sh` 5 times in a row. Any scenario that fails once
  but passes the other four is flaky under parallelism.
- For each flake: identify the shared resource (if any — usually a
  race on a non-tmpdir path), either fix the test or mark it serial.

**Test scenarios:**
- 5 consecutive `run-all.sh` invocations all pass.
- If flakes were found, documented opt-out works.

**Verification:**
- `.perf-baseline.md` Flake audit row shows 5/5 passes.
- README/CLAUDE.md has a testing section.

## System-Wide Impact

- **Interaction graph:** Tests are self-contained; moving files and
  adding parallelism does not affect plugin runtime behavior.
- **State lifecycle risks:** Per-test `BATS_TEST_TMPDIR` isolation is
  the only barrier between parallel tests. Verified today by reading
  `test_helper.bash`. No plan-introduced races.
- **API surface parity:** The `bats tests/` invocation still works
  exactly as before; wrappers are additive.
- **Unchanged invariants:** Every current `@test` still runs with
  the same assertions. No coverage is deleted or weakened.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Parallel execution exposes flakes in concurrency-deliberate tests (the 10-fire dual-fire test) | Unit 6 flake audit; opt-out documented; fall back to `--jobs 1` on the integration tier if needed |
| `setup_file` hoisting introduces cross-test contamination (a library global leaks) | Unit 3 includes a smoke test specifically to catch this; any regression shows up as a test that passes in isolation but fails in the file |
| Cached hatched buddy (Unit 4) diverges from what tests expect because a test mutates the buddy file mid-run | Tests mutate via `_inject_tokens` on their own copy, not the cache — verified by the existing per-test tmpdir pattern |
| Directory moves break path references in helpers | Unit 5 explicitly lists the path-recalculation follow-ups; full suite is the verification gate |
| The 18-minute number is a one-shot measurement on a busy devcontainer — the speed-up may be less dramatic on a quiet box | Unit 1 re-measures 3x to bound variance; plan goals are stated as ranges, not absolutes |

## Documentation / Operational Notes

- Add a small "Running tests" section to `CLAUDE.md` or a new
  `tests/README.md` once Unit 5 lands, documenting:
  - `./tests/run-quick.sh` — tight loop (<2 min)
  - `./tests/run-all.sh` — full suite (<3 min)
  - `./tests/bats-core/bin/bats tests/path/to/file.bats` — single-file
    debug

## Sources & References

- bats-core parallel execution: https://bats-core.readthedocs.io/en/stable/usage.html#parallel-execution
- Related learnings:
  - [bash-jq-fork-collapse-hot-path-2026-04-21](../solutions/best-practices/bash-jq-fork-collapse-hot-path-2026-04-21.md)
  - [bash-state-library-patterns-2026-04-18](../solutions/best-practices/bash-state-library-patterns-2026-04-18.md)
- Observed timing: `time ./tests/bats-core/bin/bats tests/ --timing`
  on this devcontainer, 2026-04-22: 217 tests in 18 m 36 s, 221 s
  user + 20 s sys, 21 % CPU.
