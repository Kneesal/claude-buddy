---
id: P3-1
title: Hook wiring + session init
phase: P3
status: todo
depends_on: [P1-1, P1-3]
origin_plan: docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md
---

# P3-1 — Hook wiring

## Goal

Wire the four hook events we need (`SessionStart`, `PostToolUse`, `PostToolUseFailure`, `Stop`). Initialize per-session state, establish the fast-path early-exit when NO_BUDDY. No commentary yet — that's P3-2.

## Tasks

- [ ] Create `hooks/hooks.json`:
  ```json
  {
    "hooks": {
      "SessionStart":        [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh", "timeout": 2 }],
      "PostToolUse":         [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/post-tool-use.sh", "timeout": 2 }],
      "PostToolUseFailure":  [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/post-tool-use-failure.sh", "timeout": 2 }],
      "Stop":                [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/stop.sh", "timeout": 2 }]
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

- Hook payload format: documented in [hooks docs](https://code.claude.com/docs/en/hooks). Each hook receives tool-specific JSON via stdin.
- Dedup matters: the same tool-call ID can surface in multiple hooks (e.g., a failed Edit may fire both `PostToolUse` and `PostToolUseFailure` depending on Claude Code version) — track by ID, not timestamp.
- One `session.json` per `sessionId` lets multiple concurrent sessions coexist without stepping on each other's rate-limit state.
- `${CLAUDE_PLUGIN_ROOT}` resolves to the plugin install dir; `${CLAUDE_PLUGIN_DATA}` to the durable data dir.
