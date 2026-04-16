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

- [ ] Create `scripts/lib/state.sh` exposing: `buddy_load`, `buddy_save`, `session_load`, `session_save`.
- [ ] All writes: write to `buddy.json.tmp` → `rename` (atomic on POSIX).
- [ ] All read-modify-write sequences: acquire `flock -x` on `buddy.json` for the duration.
- [ ] `schemaVersion: 1` stamped into every write. Add `migrate()` that is a no-op at v1 but establishes the pattern.
- [ ] `buddy_load` on parse failure: return a sentinel value (`NO_BUDDY` or `CORRUPT`), print a one-time warning to stderr, **do not crash**.
- [ ] `buddy_load` when `${CLAUDE_PLUGIN_DATA}/buddy.json` is missing: return `NO_BUDDY`.
- [ ] Orphan cleanup: on `SessionStart` (wiring comes in P3-1), sweep `*.tmp` files older than 1 hour.
- [ ] Tests (bats or plain shell under `tests/`):
  - [ ] Fresh install → `NO_BUDDY`.
  - [ ] Round-trip write/read.
  - [ ] Truncate mid-write → load returns `CORRUPT`, no crash.
  - [ ] 50 concurrent writers → no lost increments (XP counter stress test).

## Exit criteria

- Other tickets can call `buddy_load` / `buddy_save` without worrying about corruption or concurrency.
- Test suite passes; concurrent-writer test has zero lost increments.

## Notes

- State files live in `${CLAUDE_PLUGIN_DATA}` (resolves to `~/.claude/plugins/data/<id>/`). Auto-created on first write. Survives plugin updates per [plugins-reference](https://code.claude.com/docs/en/plugins-reference).
- Schema reference: Plan → Technical Approach → Data Model.
- `flock` is POSIX standard on Linux/macOS. Windows is post-P8.
- All timestamps: ISO-8601 UTC for display, `date +%s` for cooldown math (monotonic-robust).
