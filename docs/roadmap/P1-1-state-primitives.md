---
id: P1-1
title: State primitives (atomic I/O, flock, schema)
phase: P1
status: done
depends_on: [P0]
origin_plan: docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md
---

# P1-1 — State primitives

## Goal

Provide a safe, concurrency-correct state layer that every other ticket will depend on. All reads and writes to `buddy.json` go through this module. Gets `schemaVersion` right from day one so v2+ migrations don't require painful retrofits.

## Tasks

- [x] Create `scripts/lib/state.sh` exposing: `buddy_load`, `buddy_save`, `session_load`, `session_save`.
- [x] All writes: write to `buddy.json.tmp` → `rename` (atomic on POSIX).
- [x] All read-modify-write sequences: acquire `flock -x` on `buddy.json.lock` for the duration. (Lock file separate from data file — plan corrected the original "flock on buddy.json" text.)
- [x] `schemaVersion: 1` stamped into every write. Added `_state_migrate()` that is a no-op at v1 but establishes the pattern (with iteration cap for safety).
- [x] `buddy_load` on parse failure: returns `CORRUPT` sentinel (distinct from `NO_BUDDY`), prints one-time warning per key via `_state_log_once`, **does not crash**.
- [x] `buddy_load` when `${CLAUDE_PLUGIN_DATA}/buddy.json` is missing: returns `NO_BUDDY`.
- [x] Orphan cleanup: `state_cleanup_orphans` implemented in `state.sh` (wiring comes in P3-1). Skips `.tmp` files whose owning PID is still alive to avoid racing with in-flight writes.
- [x] Tests (bats under `tests/`) — 43 total, all passing:
  - [x] Fresh install → `NO_BUDDY`.
  - [x] Round-trip write/read.
  - [x] Truncate mid-write → load returns `CORRUPT`, no crash.
  - [x] 50 concurrent writers via `buddy_save` → no lost increments (XP counter stress test).

## Exit criteria

- Other tickets can call `buddy_load` / `buddy_save` without worrying about corruption or concurrency.
- Test suite passes; concurrent-writer test has zero lost increments.

## Notes

- State files live in `${CLAUDE_PLUGIN_DATA}` (resolves to `~/.claude/plugins/data/<id>/`). Auto-created on first write. Survives plugin updates per [plugins-reference](https://code.claude.com/docs/en/plugins-reference).
- Schema reference: Plan → Technical Approach → Data Model.
- `flock` is POSIX standard on Linux/macOS. Windows is post-P8.
- All timestamps: ISO-8601 UTC for display, `date +%s` for cooldown math (monotonic-robust).

### Post-review hardening (applied after ce:review)

Review surfaced 14 findings; all P1/P2/P3 fixes applied in follow-up commits:

- Removed `set -euo pipefail` module-level pollution (would break hook exit-0 contract)
- `schemaVersion` validated as non-negative integer — float/string/negative all return CORRUPT
- `session_id` sanitized against path traversal (`^[A-Za-z0-9_-]+$` only)
- Stress test rewritten to use `buddy_save` instead of reimplementing locking inline
- `_state_migrate()` has iteration cap protecting against future migration case arms forgetting to bump `.schemaVersion`
- `session_save` uses atomic tmp+rename (prevents concurrent-writer corruption within same session_id)
- `.tmp` files named with PID so `state_cleanup_orphans` skips live writers
- `_state_log_once` prevents stderr flooding at status-line cadence
- Bash 4.1+ required — explicit version check at source time (macOS users need `brew install bash`)
- `_state_ensure_dir` helper extracted from duplicated `mkdir -p` guard

### Implementation decisions

- **Lock file is `buddy.json.lock`, not `buddy.json`** — data file inode changes on atomic rename, so locking the data file itself is incorrect.
- **Migration happens in memory** — `buddy_load` returns migrated JSON but does not write back. Read-only callers (status line) never trigger writes.
- **Three sentinels, not two** — added `FUTURE_VERSION` to prevent data loss on plugin downgrade.
- **Session files per-sessionId** — `session-<id>.json` instead of a single shared `session.json`. No flock needed.
- **buddy_load always returns 0** — sentinel string in output is what callers check. Avoids `set -e` footguns for callers.
