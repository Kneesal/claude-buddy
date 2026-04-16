---
title: "feat: P1-1 — State primitives (atomic I/O, flock, schema)"
type: feat
status: active
date: 2026-04-16
origin: docs/brainstorms/2026-04-16-claude-buddy-plugin-requirements.md
---

# feat: P1-1 — State primitives (atomic I/O, flock, schema)

## Overview

Create the foundational state layer that every subsequent ticket depends on. All reads and writes to `buddy.json` go through `scripts/lib/state.sh`, which provides atomic writes (tmp+rename), advisory locking (flock), schema versioning with incremental migration, and graceful corruption handling. Session state uses per-sessionId files with no locking (single writer per session).

## Problem Frame

P1-2 (hatch roller), P1-3 (slash commands), P2 (status line), and P3+ (hooks, evolution, tokens) all need to read and write buddy state. Without a safe, shared state layer, concurrent Claude Code sessions will corrupt data and schema changes will require painful retrofits. This ticket solves the persistence problem once so downstream tickets can focus on features. (see origin: `docs/brainstorms/2026-04-16-claude-buddy-plugin-requirements.md`, R2 — global persistence)

## Requirements Trace

- R2. Single active buddy, global — buddy state persists in `${CLAUDE_PLUGIN_DATA}/buddy.json`, survives restarts and plugin updates
- P1-1 exit criteria (from `docs/roadmap/P1-1-state-primitives.md`): other tickets can call `buddy_load`/`buddy_save` without worrying about corruption or concurrency; test suite passes; concurrent-writer test has zero lost increments

## Scope Boundaries

- No hatch logic, species data, or rng (P1-2)
- No slash command state machine (P1-3)
- No hook wiring or SessionStart integration (P3-1) — orphan cleanup function is implemented here but only called from P3-1
- No status line rendering (P2)
- No `userConfig` in the manifest

### Deferred to Separate Tasks

- Orphan cleanup invocation: implemented in state.sh, wired in P3-1's `session-start.sh`
- Session file cleanup for crashed sessions: function ready, hook wiring in P3-1

## Context & Research

### Relevant Code and Patterns

- Repo is post-P0: plugin manifest, 3 skill stubs, no executable bash code yet
- `CLAUDE.md` states: all state writes must go through atomic tmp+rename with flock; hook scripts must exit 0 on failure; p95 < 100ms latency target
- Data model defined in full plan at `docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md` (lines 96–157)
- Error propagation table in full plan (lines 410–422)
- `jq` 1.7 and `flock` (util-linux 2.39.3) available in devcontainer
- `bats` NOT installed — needs to be added for testing
- `shellcheck` NOT installed — nice-to-have but not blocking

### Institutional Learnings

- `docs/solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md` — settings.json only supports `agent` and `subagentStatusLine`; new skill directories need restart; plugin state must live in own managed files

### External References

- Atomic writes: `mktemp` in same directory + `mv` (same-filesystem guarantee). Never redirect jq output to same file.
- flock: Lock a separate `.lock` file, not the data file (data file inode changes on atomic rename). Use `(flock -x -w timeout FD; ...) FD>lockfile` pattern. Lock auto-releases on process death (no stale locks).
- jq: `--arg` for strings, `--argjson` for typed values. `-e` for conditionals. `-r` for raw output.
- Schema migration: incremental case chain (v1→v2→v3, never skip). `//` operator for lazy defaults.
- bats: `$BATS_TEST_TMPDIR` for isolation. Background processes need `3>&-` to avoid hanging.

## Key Technical Decisions

> **Note:** Three decisions below deliberately correct or supersede the full plan. The full plan's descriptions of flock target, corruption sentinel, and session file naming were written before implementation research revealed the correct patterns. This plan is authoritative for P1-1; the full plan should be updated to match when convenient.

- **Lock file is `buddy.json.lock`, not `buddy.json`** *(corrects full plan D7 and P1-1 ticket)*: The data file gets atomically replaced via `mv`, changing the inode. A lock on the replaced inode is meaningless. The `.lock` file is never replaced, so the lock persists correctly. The full plan says "flock on buddy.json" — this is technically incorrect for the atomic-rename pattern.
- **Migration happens in memory, not on disk during load**: `buddy_load` returns migrated JSON but does NOT write back. Migration persists on the next `buddy_save`. This means read-only callers (status line) never trigger writes and avoids lock re-entrancy.
- **Three sentinels, not two** *(extends P1-1 ticket scope)*: `NO_BUDDY` (file missing), `CORRUPT` (parse failure or missing schemaVersion), `FUTURE_VERSION` (schemaVersion > current). FUTURE_VERSION prevents users from wiping valid data a newer plugin version could read. The ticket specifies two sentinels; FUTURE_VERSION is a deliberate addition for data safety on plugin downgrade.
- **CORRUPT on parse failure, not NO_BUDDY** *(corrects full plan error table line 414 and P1-1 ticket line 22)*: The D5 state machine distinguishes CORRUPT from NO_BUDDY — CORRUPT shows a repair prompt, NO_BUDDY shows "hatch one." Both the ticket and the full plan's error propagation table incorrectly say `buddy_load` returns NO_BUDDY on malformed JSON. This plan returns CORRUPT, matching D5.
- **Session files are per-sessionId** *(supersedes full plan data model line 138)*: `session-<id>.json` (not a single shared `session.json`). No flock needed — each session is a single writer. The full plan's data model shows a single `session.json` — this plan changes to per-file isolation to prevent concurrent sessions from clobbering each other's cooldown state. P1-2/P1-3 authors should reference this plan, not the full plan's session data model.
- **buddy_save explicitly cleans up .tmp on failure**: `rm -f` the tmp file in the error path. Orphan sweep is a backstop, not the primary cleanup.
- **bats-core for testing**: Install via git clone into `tests/bats-core/` (no package manager needed). Gitignore it. Provides TAP output, `@test` syntax, `setup`/`teardown`, `$BATS_TEST_TMPDIR`.

## Open Questions

### Resolved During Planning

- **CORRUPT vs NO_BUDDY on parse failure**: CORRUPT is distinct — matches the D5 state machine. The P1-1 ticket text at line 22 ("return NO_BUDDY on parse failure") is incorrect; it should say CORRUPT. The ticket task list at line 24 already shows both options.
- **Migration write-back locking**: Migrate in memory, persist on next save. No re-entrancy.
- **FUTURE_VERSION handling**: Return a third sentinel with "update plugin" message. Don't wipe valid data.
- **Session file naming**: Per-sessionId (`session-<id>.json`). `session_load`/`session_save` take a session ID parameter.
- **Lock file path**: `${CLAUDE_PLUGIN_DATA}/buddy.json.lock`. Created implicitly by flock fd-open. Never cleaned up.
- **flock timeout**: 200ms (from full plan). Contended writes are rare; 2s hook timeout is the true safety bound.

### Deferred to Implementation

- **Exact jq filter expressions**: Depends on touching real data and seeing error modes
- **Whether `shellcheck` should be installed in the devcontainer**: Nice-to-have, not blocking for P1-1
- **bats helper organization**: Will emerge from the test scenarios; start simple

## Output Structure

```
scripts/
  lib/
    state.sh                   # buddy_load, buddy_save, session_load, session_save, migrate, state_cleanup_orphans
tests/
  bats-core/                   # git-cloned bats (gitignored)
  test_helper.bash             # shared setup/teardown
  state.bats                   # all state primitive tests
```

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```
buddy_load(data_dir):
  guard: CLAUDE_PLUGIN_DATA set and non-empty, else → NO_BUDDY
  guard: buddy.json exists, else → NO_BUDDY
  read file → jq parse
    parse fails → CORRUPT (+ stderr warning)
    parse succeeds → check .schemaVersion
      missing → CORRUPT
      > CURRENT_VERSION → FUTURE_VERSION
      == CURRENT_VERSION → return JSON
      < CURRENT_VERSION → migrate in memory → return migrated JSON

buddy_save(data_dir, json_content):
  mkdir -p data_dir
  open lockfile fd → flock -x -w 0.2
    timeout → log, return 1
    acquired →
      mktemp in data_dir → write json_content → mv to buddy.json
      on write failure → rm -f tmp, log, return 1
    release lock (fd close)

session_load(data_dir, session_id):
  read session-<id>.json → jq parse or return empty default

session_save(data_dir, session_id, json_content):
  mkdir -p data_dir → write to session-<id>.json (no lock, no atomic rename needed)

state_cleanup_orphans(data_dir):
  find *.tmp older than 1 hour → rm
  find session-*.json older than 1 hour → rm
```

## Implementation Units

- [ ] **Unit 1: Core buddy state library**

  **Goal:** Create `scripts/lib/state.sh` with `buddy_load` and `buddy_save` — atomic writes, flock locking, corruption handling, schema versioning with migration stub.

  **Requirements:** R2, P1-1 exit criteria

  **Dependencies:** None (P0 complete)

  **Files:**
  - Create: `scripts/lib/state.sh`

  **Approach:**
  - `buddy_load`: guard CLAUDE_PLUGIN_DATA → check file exists → jq parse → check schemaVersion → migrate in memory if needed → return JSON or sentinel (NO_BUDDY / CORRUPT / FUTURE_VERSION)
  - `buddy_save`: mkdir -p → flock -x -w 0.2 on `.lock` file → mktemp in same dir → write → mv → release lock. Explicit `rm -f` of .tmp on any write failure via trap.
  - `migrate()`: case chain on schemaVersion. v1 is a no-op (returns input unchanged). Structure makes adding v2+ obvious.
  - `CURRENT_SCHEMA_VERSION=1` constant at top of file
  - All functions use `${CLAUDE_PLUGIN_DATA}` as the data directory; guard at entry for unset/empty
  - Stamp `schemaVersion: 1` on every write via jq
  - All error paths: log to stderr, never crash, return non-zero exit code

  **Patterns to follow:**
  - Atomic write: `mktemp "$(dirname "$target")/.tmp.XXXXXX"` + `mv -f`
  - flock: `(flock -x -w 0.2 FD || return 1; ...) FD>"$lockfile"`
  - jq: `--argjson` for numbers, `--arg` for strings, `-e` for existence checks

  **Test scenarios:**
  - Happy path: `buddy_save` writes valid JSON with schemaVersion 1 → `buddy_load` returns identical content
  - Happy path: `buddy_save` called twice → second write overwrites first cleanly
  - Edge case: `CLAUDE_PLUGIN_DATA` unset → `buddy_load` returns NO_BUDDY
  - Edge case: `CLAUDE_PLUGIN_DATA` set but directory doesn't exist → `buddy_load` returns NO_BUDDY, `buddy_save` creates it
  - Edge case: `buddy.json` exists but is empty → `buddy_load` returns CORRUPT
  - Edge case: `buddy.json` has valid JSON but no schemaVersion field → CORRUPT
  - Edge case: `buddy.json` has schemaVersion > CURRENT → FUTURE_VERSION
  - Error path: `buddy.json` is truncated mid-JSON (e.g., `{"schema`) → CORRUPT, no crash
  - Error path: flock timeout (lock held by another process for >200ms) → buddy_save returns non-zero, no state change, log message
  - Integration: `buddy_load` with schemaVersion < CURRENT → returns migrated JSON in memory (at v1 this is a no-op, but the path should be exercised)

  **Verification:**
  - `buddy_load` returns NO_BUDDY, CORRUPT, or FUTURE_VERSION sentinels correctly for each failure mode
  - `buddy_save` creates the data directory if missing
  - Round-trip: save then load returns identical JSON
  - No partial writes visible to readers (atomic rename guarantees this)

- [ ] **Unit 2: Session state and orphan cleanup**

  **Goal:** Add `session_load`, `session_save` (per-sessionId, no locking), and `state_cleanup_orphans` to state.sh.

  **Requirements:** R2 (persistence layer), P3-1 alignment (per-sessionId files)

  **Dependencies:** Unit 1 (shared file, same conventions)

  **Files:**
  - Modify: `scripts/lib/state.sh`

  **Approach:**
  - `session_load(session_id)`: read `session-<id>.json` from CLAUDE_PLUGIN_DATA. Return empty JSON default if missing. No flock (single writer per session).
  - `session_save(session_id, json_content)`: write `session-<id>.json` directly (no atomic rename needed — single writer, ephemeral data, corruption means stale cooldowns at worst).
  - `state_cleanup_orphans`: `find` for `*.tmp` and `session-*.json` older than 1 hour in CLAUDE_PLUGIN_DATA, `rm -f` each. Called externally by P3-1's session-start.sh.

  **Patterns to follow:**
  - Same guard pattern for CLAUDE_PLUGIN_DATA as buddy_load/buddy_save
  - Session ID from hook payload (P3-1 will pass it in)

  **Test scenarios:**
  - Happy path: `session_save("abc123", json)` → `session_load("abc123")` returns same content
  - Happy path: `session_load` with non-existent session ID → returns empty default JSON
  - Edge case: two different session IDs write simultaneously → each gets its own file, no interference
  - Happy path: `state_cleanup_orphans` removes `.tmp` files older than 1 hour
  - Happy path: `state_cleanup_orphans` removes `session-*.json` files older than 1 hour
  - Edge case: `state_cleanup_orphans` does NOT remove `buddy.json`, `buddy.json.lock`, or recent files

  **Verification:**
  - Session files are isolated by session ID
  - Orphan cleanup removes stale files without touching live state
  - No flock used for session operations

- [ ] **Unit 3: Test infrastructure and test suite**

  **Goal:** Install bats-core, write the test helper, and implement all required test cases including the concurrent-writer stress test.

  **Requirements:** P1-1 exit criteria (test suite passes, concurrent-writer test has zero lost increments)

  **Dependencies:** Units 1 and 2

  **Files:**
  - Create: `tests/test_helper.bash`
  - Create: `tests/state.bats`
  - Modify: `.gitignore` (add `tests/bats-core/`)

  **Execution note:** Install bats-core first, then write tests against the state library. Run tests to verify all pass.

  **Approach:**
  - Install bats-core via `git clone https://github.com/bats-core/bats-core.git tests/bats-core`
  - `test_helper.bash`: source `scripts/lib/state.sh`, set up `CLAUDE_PLUGIN_DATA` in `$BATS_TEST_TMPDIR`, provide `assert_*` helpers
  - `state.bats`: all test cases from Units 1 and 2, plus the concurrent-writer stress test
  - Concurrent writer test: spawn 50 background processes, each acquires flock and increments a counter via buddy_save. After `wait`, verify counter == 50. Use a generous flock timeout (5s) in tests to avoid false negatives on slow devcontainers — the 200ms timeout is for production.
  - Add `tests/bats-core/` to `.gitignore`

  **Patterns to follow:**
  - bats: `@test` blocks, `setup`/`teardown` with `$BATS_TEST_TMPDIR`, `run` command for exit code assertions
  - Background processes: close fd 3 (`3>&-`) to avoid hanging bats

  **Test scenarios:**
  - All scenarios from Units 1 and 2 (enumerated above)
  - Integration: 50 concurrent writers → final counter value == 50 (zero lost increments)
  - Integration: write → corrupt file manually → load returns CORRUPT → save new valid state → load returns valid state (full recovery cycle)

  **Verification:**
  - `tests/bats-core/bin/bats tests/state.bats` exits 0 with all tests passing
  - Concurrent-writer test shows exactly 50 increments (no lost writes)

## System-Wide Impact

- **Interaction graph:** `state.sh` is sourced by every hook script (P3+), the status line script (P2), and indirectly by slash command scripts (P1-3). It is the single point of contact for all persistent state.
- **Error propagation:** All errors log to stderr and return non-zero. No function ever crashes or exits the calling script. Callers check return values and sentinels.
- **State lifecycle risks:** Orphaned `.tmp` files from crashed writes → cleaned up by `state_cleanup_orphans`. Stale session files from crashed sessions → same cleanup function. Lock file accumulation → harmless (tiny files, never cleaned up).
- **API surface parity:** `buddy_load`/`buddy_save` are the only way to touch `buddy.json`. No direct file reads/writes from any other module. `session_load`/`session_save` are the only way to touch session files.
- **Unchanged invariants:** P0 skill stubs remain as-is. Plugin manifest unchanged. No new slash commands.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| bats-core installation fails in devcontainer | Fall back to plain shell test runner (less ergonomic but functional) |
| jq 1.7 has edge cases with large numbers or unicode | State files are small (<4KB) with ASCII-only content; unlikely to hit jq edge cases |
| flock not available on macOS without util-linux | macOS ships `flock` via `util-linux` homebrew package; devcontainer uses Linux where flock is built-in. Windows is post-P8. |
| Concurrent writer stress test is flaky | Use a high flock timeout (5s) in the test to avoid false negatives. The 200ms timeout is for production; tests can be more generous. |

## Sources & References

- **Origin document:** [docs/brainstorms/2026-04-16-claude-buddy-plugin-requirements.md](../brainstorms/2026-04-16-claude-buddy-plugin-requirements.md)
- **Full plan:** [docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md](2026-04-16-001-feat-claude-buddy-plugin-plan.md) — data model (lines 96–157), error propagation (lines 410–422), state lifecycle risks (lines 424–432)
- **Ticket:** [docs/roadmap/P1-1-state-primitives.md](../roadmap/P1-1-state-primitives.md)
- **P0 gotchas:** [docs/solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md](../solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md)
- flock(1): https://man7.org/linux/man-pages/man1/flock.1.html
- rename(2) atomicity: https://man7.org/linux/man-pages/man2/rename.2.html
- bats-core: https://github.com/bats-core/bats-core
- jq manual: https://jqlang.org/manual/
