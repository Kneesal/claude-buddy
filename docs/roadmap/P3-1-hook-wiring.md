---
id: P3-1
title: Hook wiring + session init
phase: P3
status: done
depends_on: [P1-1, P1-3]
origin_plan: docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md
---

# P3-1 — Hook wiring

## Goal

Wire the four hook events we need (`SessionStart`, `PostToolUse`, `PostToolUseFailure`, `Stop`). Initialize per-session state, establish the fast-path early-exit when NO_BUDDY. No commentary yet — that's P3-2.

## Tasks

- [ ] Create `hooks/hooks.json`. **Schema correction (2026-04-20):** the flat shape originally shown in this ticket was rejected by Claude Code v2.1.114. See [docs/solutions/developer-experience/claude-code-plugin-hooks-json-schema-2026-04-20.md](../solutions/developer-experience/claude-code-plugin-hooks-json-schema-2026-04-20.md). The correct nested shape:
  ```json
  {
    "hooks": {
      "SessionStart":       [{ "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh", "timeout": 2 }] }],
      "PostToolUse":        [{ "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/post-tool-use.sh", "timeout": 2 }] }],
      "PostToolUseFailure": [{ "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/post-tool-use-failure.sh", "timeout": 2 }] }],
      "Stop":               [{ "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/stop.sh", "timeout": 2 }] }]
    }
  }
  ```
- [ ] `hooks/session-start.sh`:
  - [ ] Early-exit on NO_BUDDY.
  - [ ] Initialize/reset `session.json` with `sessionId`, `startedAt`, empty cooldowns, empty `recentToolCallIds` ring buffer (last 20).
  - [ ] Sweep `${CLAUDE_PLUGIN_DATA}/*.tmp` files older than 1 hour (orphan cleanup from P1-1).
  - [ ] Exit 0 with no stdout (no transcript surfacing needed).
- [ ] `hooks/post-tool-use.sh`:
  - [ ] Early-exit on NO_BUDDY.
  - [ ] Parse hook payload (tool name, tool-call ID).
  - [ ] Dedup via `recentToolCallIds` — skip if seen.
  - [ ] Placeholder stdout (e.g., `""` — commentary in P3-2, signal accumulation in P4-1).
- [ ] `hooks/post-tool-use-failure.sh`: same structure, different placeholder for failures.
- [ ] `hooks/stop.sh`: same structure; placeholder for XP tick + session-end commentary in later phases.
- [ ] p95 runtime target: < 100ms each. Time each hook with `/usr/bin/time` across 100 invocations.
- [ ] Failure safety: every hook exits 0 on internal error (writes to `${CLAUDE_PLUGIN_DATA}/error.log`, never stderr-to-Claude) — **must not break the Claude Code session**.

## Exit criteria

- All four hooks fire in-session and exit cleanly.
- NO_BUDDY state produces zero hook output.
- Concurrent sessions don't race on `session.json` (each has its own session file keyed by `sessionId`).

## Notes

### Implementation summary (2026-04-20)

Plan: [docs/plans/2026-04-20-002-feat-p3-1-hook-wiring-plan.md](../plans/2026-04-20-002-feat-p3-1-hook-wiring-plan.md)

Shipped:
- `scripts/hooks/common.sh` — shared payload/sentinel/log/ring helpers
- `scripts/hooks/tool-event.sh` — shared body for both PostToolUse variants (kept the two hooks as single-line entry points rather than duplicating ~40 lines)
- `hooks/session-start.sh`, `hooks/post-tool-use.sh`, `hooks/post-tool-use-failure.sh`, `hooks/stop.sh`
- `hooks/hooks.json` manifest (schema from the ticket verbatim)
- 59 new bats tests across `tests/hooks/` — total suite now 243 green

### Measured p95 (100 iterations, `tests/hooks/perf_hook_p95.sh`)

| Hook | min | p95 | max |
|---|---:|---:|---:|
| session-start.sh | 14ms | **19ms** | 23ms |
| post-tool-use.sh | 19ms | **28ms** | 115ms |
| post-tool-use-failure.sh | 14ms | **19ms** | 22ms |
| stop.sh | 8ms | **11ms** | 12ms |

All four hooks sit comfortably under the 100ms p95 ceiling. The 115ms `max` on post-tool-use is a single outlier — driven by one late iteration where the session file had grown to its 20-entry cap and jq had the largest ring-push workload. Still well below the 2s hook timeout in `hooks.json`.

### Post-review hardening (2026-04-20, ce:review round 1)

Applied inline after the tiered-persona code review. 250/250 bats green, p95 20/27/21/**2**ms (stop.sh is now a bare `exit 0`).

- **Orphan-sweep TTL split (state.sh):** `SESSION_FILE_MAX_AGE_MINUTES=1440` (24h) replaces the shared `ORPHAN_MAX_AGE_MINUTES=60` for the `session-*.json` and new `session-*.json.lock` sweep passes. Prevents a concurrent window's `SessionStart` from deleting a live-but-idle session's file. `.tmp` sweep keeps the 60min TTL.
- **Per-session flock (tool-event.sh):** Load-modify-save cycle now runs under an `exec {fd}>session-<id>.json.lock; flock -x -w 0.2` mirroring `buddy_save`'s discipline. Closes the concurrent-write race between PostToolUse + PostToolUseFailure.
- **Cleanup-sweep watchdog (session-start.sh):** `state_cleanup_orphans` runs in background with an 80ms kill watchdog — a data dir with thousands of stale files can't blow the 100ms budget.
- **Hot-path jq collapse:** `hook_ring_contains + hook_ring_push` replaced by a single `hook_ring_update` that returns `"DEDUP"` or updated JSON.
- **Rename:** `hook_extract_tool_call_id` → `hook_extract_tool_use_id` (primary field is `tool_use_id`; `tool_call_id` is the defensive fallback).
- **stop.sh:** stopped logging on missing session_id (Stop payloads legitimately omit it; prevents unbounded error.log growth).
- **skills/stats/SKILL.md:** documents `${CLAUDE_PLUGIN_DATA}/error.log` as the debug surface for silent hook failures.
- **7 new bats tests** covering FUTURE_VERSION sentinels, `CLAUDE_PLUGIN_DATA` unset on post-tool-use, `session_save` failure path, and the schemaVersion:2 upgrade seam.
- **YAGNI cleanup (findings #10 + #11):**
  - `scripts/hooks/tool-event.sh` dissolved — the shared body is inlined into both `hooks/post-tool-use.sh` and `hooks/post-tool-use-failure.sh`. The plan anticipated P3-2 divergence anyway; inlining now avoids mid-sprint refactor pressure.
  - `hooks/stop.sh` stripped to `exec 2>/dev/null; exit 0`. The earlier scaffold (payload drain, `buddy_load`, sid extraction) was dead code. P3-2 adds structure back when it needs it.

### Design decisions deviated from the plan

- **Extracted a shared `scripts/hooks/tool-event.sh`** in addition to `common.sh`. The plan treated Units 3 and 4 as structurally identical; once the bodies were written that turned into ~40 duplicated lines of main logic, so the shared tool-event runner landed alongside the shared common helpers. Both PostToolUse hook files are now 2-line entry points that source state.sh + common.sh + tool-event.sh and call `_hook_tool_event_main "<hook-name>"`.
- **stderr redirect → `/dev/null`, not `error.log`.** The plan suggested redirecting library stderr into `error.log`. Implementation found that opening `error.log` in append mode creates the file as a side effect on *every* hook invocation, including the NO_BUDDY fast-path — which broke the "pre-hatch is fully passive" contract (one test caught this). Switched to `exec 2>/dev/null`; durable logging still goes through `hook_log_error` on explicit call.
- **Accept both `tool_use_id` and `tool_call_id`** in the payload extractor. The hooks docs use `tool_use_id`; the umbrella plan uses `tool_call_id`. Defensive extraction handles either, preventing a silent dedup miss if Claude Code renames the field.
- **`hook_extract_tool_call_id` rejects IDs >256 chars.** Defensive cap so a hostile or malformed payload can't bloat `session-<id>.json`.
- **`schemaVersion: 1` is stamped on every `session-<id>.json` write** via `hook_initial_session_json`. `session_save` in state.sh doesn't stamp it (unlike `buddy_save`); hooks own the session-file shape and take responsibility for the seam.

### Live-session smoke

Performed via `claude -p --plugin-dir /workspace` headless mode against a scratch dir with per-hook stdin-capture lines temporarily spliced in. **Caught a real schema bug before PR:**

- **Bug:** The `hooks.json` schema in the ticket example was flat (`{hook_event: [{type, command, timeout}]}`). Claude Code rejected it with `Failed to load hooks for buddy: [["hooks","hooks"],...]`. The real schema nests each event entry under a second `hooks:` key (alongside an optional `matcher`), e.g. `{hook_event: [{hooks: [{type, command, timeout}]}]}`. Fixed before landing.
- **Payload field names confirmed.** Real events carry top-level `session_id` (UUID, 36 chars with hyphens — passes our validator) and `tool_use_id` for tool events. Our `hook_extract_tool_call_id` dual-field fallback (`tool_use_id // tool_call_id`) was over-cautious but harmless. `tool_call_id` from the umbrella plan is not the real field name.
- **PostToolUseFailure** did not fire in the smoke (Bash succeeded) — payload shape still assumed to mirror PostToolUse; verified during P3-2 when the commentary engine exercises the failure path.
- **SessionStart payload** includes a `source: "startup"` field we don't read — fine, ignored.
- `permission_mode: "bypassPermissions"` is set in `-p` mode regardless of `--allowedTools`. Worth knowing for anyone running the smoke themselves.

### Original design notes

- Hook payload format: documented in [hooks docs](https://code.claude.com/docs/en/hooks). Each hook receives tool-specific JSON via stdin.
- Dedup matters: the same tool-call ID can surface in multiple hooks (e.g., a failed Edit may fire both `PostToolUse` and `PostToolUseFailure` depending on Claude Code version) — track by ID, not timestamp.
- One `session.json` per `sessionId` lets multiple concurrent sessions coexist without stepping on each other's rate-limit state.
- `${CLAUDE_PLUGIN_ROOT}` resolves to the plugin install dir; `${CLAUDE_PLUGIN_DATA}` to the durable data dir.
