---
id: P4-1
title: XP + evolution signal accumulation
phase: P4
status: done
depends_on: [P3-1]
origin_plan: docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md
---

# P4-1 — XP + signals

## Goal

Accumulate XP and the four behavior-axis signals (consistency, variety, quality, chaos) that drive evolution in P4-2. Every hook contributes to `buddy.json.signals` atomically.

## Tasks

- [x] XP curve: `xpForLevel(n) = 50 * n * (n + 1)` stored in `scripts/lib/evolution.sh`. Plan pins xpForLevel(1)=100, xpForLevel(5)=1500, xpForLevel(10)=5500 as the formula outputs. Ticket's original 750/2750 anchors were inconsistent with the formula — implementation matches the formula; the Lv 5 = 1500 / Lv 10 = 5500 cumulative thresholds are the authoritative public values.
- [x] **XP sources** (all flow through `buddy_save` with caller-held flock):
  - [x] `PostToolUse` → +2 XP.
  - [x] `PostToolUseFailure` → +1 XP.
  - [x] `Stop` → +5 XP + 2 × floor(sessionActiveHours).
  - [x] Streak bonus: +10 XP on the first event of a day that extends `consistency.streakDays`.
- [x] **Signal accumulation**:
  - [x] `PostToolUse`: appends tool to variety.toolsUsed with 7-day prune; bumps quality.{successful,total}Edits when tool ∈ {Edit,Write,MultiEdit}; bumps chaos.repeatedEditHits when file matches session.lastToolFilePath AND tool is edit-like; updates consistency per UTC day boundary with 1-day gap tolerance.
  - [x] `PostToolUseFailure`: chaos.errors++, quality.totalEdits++.
- [x] **Level-up event**: `hook_signals_apply` emits `LEVEL_UP:<n>` on stdout line 1 when level advances; hooks route that through `hook_commentary_select LevelUp` which bypasses all three rate-limit gates and does NOT count against `commentsThisSession`.
- [x] **Max-level cap**: MAX_LEVEL=50. XP accrues past cap; level stays.
- [x] Tests: tests/hooks/test_week_simulation.bats (7-day sim), tests/hooks/test_signals.bats (13 streak boundary scenarios including sentinel, continuation, gap-reset, midnight, same-day no-op), tests/hooks/test_post_tool_use.bats (concurrent dual-fire, level-up fires LevelUp bank, repeatedEditHits bumps on consecutive same-file Edits).

## Exit criteria

- A realistic session produces level + signal increments visible in `/buddy`.
- Streak logic handles day boundaries, UTC vs local, gap tolerance.
- No hook ever blocks > 100ms from signal accumulation.

## Notes

- **Why four axes**: single-axis signals (Pokémon friendship) are trivial to grind. Four axes create cross-axis tension — optimizing one means neglecting another. Plan D2 and Digimon-V-Pet prior-art reference.
- All writes must go through the flock'd state API from P1-1. Never write directly.
- Retention of `variety.toolsUsed`: 7-active-day window so variety reflects *recent* exploration, not tool types used once months ago.
- This ticket does NOT implement the form transition — that's P4-2. We only accumulate here.

### Implementation notes (2026-04-21)

- **Plan:** [docs/plans/2026-04-21-001-feat-p4-1-xp-signals-plan.md](../plans/2026-04-21-001-feat-p4-1-xp-signals-plan.md). 6 implementation units, all shipped.
- **Branch:** feat/p4-1-xp-signals. Commits: evolution.sh + skeleton (bc0c329), jq-fork collapse on commentary (35213ee), hook_signals_apply (61c5045), hook wiring + lock nesting (9ff529e), LevelUp banks + week-sim (cf4a3be).
- **Lock ordering:** session OUTER, buddy INNER, release reversed. State.sh got `_BUDDY_SAVE_LOCK_HELD=1` escape hatch so the kernel's per-open-file-description lock table does not deadlock buddy_save's internal flock against the caller-held one.
- **Variety shape change from the ticket draft:** `variety.toolsUsed` is a flat map `{tool: epoch_last_seen}` with prune-on-write > 7 days, rather than an array of day-bucket objects. Cheaper in jq, bounded size (tool roster count). Plan D6.
- **Perf before/after (100-iter harness, `tests/hooks/perf_hook_p95.sh`):**
  | hook | P3-2 baseline | Unit 2 (fusion) | Unit 4 (+signals) | Unit 6 final |
  |---|---|---|---|---|
  | session-start.sh | 27ms | 27ms | 20ms | 26ms |
  | post-tool-use.sh | 85ms | 61ms | 80ms | 90ms |
  | post-tool-use-failure.sh | 30ms | 30ms | 27ms | 27ms |
  | stop.sh | 67ms | 58ms | 86ms | 71ms |
  All under the 100ms ceiling across every pass. PTU p95 ends 5ms above baseline but ~35ms under the ceiling.
- **jq-fork collapse on commentary.sh:** absorbed (Unit 2). The P3-2 residual item "Stop-double-fire dedup" stays deferred to its own follow-up ticket.
- **LevelUp commentary:** 12 lines per species, voice-reviewed. Bypasses all three rate-limit gates and does NOT bump commentsThisSession — level-ups should never count against the steady-state chatter budget.
- **Test totals:** 216 bats scenarios green. New this ticket: 21 (evolution.bats), 27 (test_signals.bats), 6 P4-1 additions in test_post_tool_use.bats, 1 week-sim, 1 structural assertion for LevelUp banks. Extended test_common.bats for lastToolFilePath and test_slash.bats for the signals skeleton in the hatch envelope.
- **Live-session smoke (2026-04-21, passed):** ran `claude --plugin-dir /workspace --debug-to-stderr -p "<edit then bash>"` against a hatched buddy. Captures in `/workspace/.smoke/`.
  - `hooks.json` loaded cleanly — stderr shows `Registered 4 hooks from 2 plugins`, no `Failed to load hooks`.
  - All four hooks fired (payloads captured in `.smoke/payload-*.jsonl`): SessionStart, 4 PostToolUse events, Stop.
  - **Payload shape confirmed:** Write/Edit carry `tool_input.file_path` (e.g., `"/tmp/.../smoke-target.txt"`); Bash carries `tool_input.command + description` with no file_path. Matches D8 exactly.
  - **End-to-end signals + commentary verified:** `~/.claude/plugins/data/buddy-inline/buddy.json` shows xp=35, streakDays=1, lastActiveDay=2026-04-21, variety.toolsUsed has both Write+Bash epochs, quality.successfulEdits=2, chaos.errors=0. Commentary lines emitted ("🦎 Custard: \"first edit feels like a clean tank\"").
  - **Gotcha — plugin-data path:** Claude Code sets `CLAUDE_PLUGIN_DATA=~/.claude/plugins/data/<plugin-name>-inline` (not `~/.claude/plugin-data/<plugin-name>`) when a plugin loads via `--plugin-dir`. The `-inline` suffix was undocumented in the hooks-schema solutions doc and tripped the first smoke pass (we looked in the wrong dir). Candidate for its own solutions-doc entry under developer-experience.
- **Unchanged invariants:** hooks still exit 0 on internal failure; session_load/session_save/buddy_load semantics unchanged; dedup ring behaviour unchanged; schemaVersion stays at 1 (signals lazy-init via jq `// default`).
