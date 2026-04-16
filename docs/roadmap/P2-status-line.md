---
id: P2
title: Status line rendering
phase: P2
status: todo
depends_on: [P1-1]
origin_plan: docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md
---

# P2 — Status line

## Goal

Render the buddy ambiently in the Claude Code status line on every assistant turn. Single line in P2; full animated 5-line sprite comes in P7-2.

## Tasks

- [ ] Create `statusline/buddy-line.sh`:
  - [ ] Read Claude Code's JSON payload from stdin (we ignore it in P2 but parse it without erroring — future-proofs for session-aware status in later phases).
  - [ ] Load buddy state via `buddy_load`.
  - [ ] NO_BUDDY → `🥚 No buddy — /buddy hatch`
  - [ ] ACTIVE → `<icon> <name> (<Rarity> <Species> · Lv.<N>) · <N> 🪙`
  - [ ] CORRUPT → `⚠️ buddy state needs /buddy reset`
- [ ] Per-rarity ANSI color: grey Common, white Uncommon, blue Rare, purple Epic, gold Legendary. Skip colors if `$NO_COLOR` is set.
- [ ] Width-safe: if `$COLUMNS < 40`, drop the token balance segment; `< 30`, drop the rarity qualifier.
- [ ] Per-species emoji icon (maps to species id in `scripts/species/<name>.json`).
- [ ] Register the status line in plugin `settings.json`:
  ```json
  {
    "statusLine": {
      "type": "command",
      "command": "${CLAUDE_PLUGIN_ROOT}/statusline/buddy-line.sh",
      "padding": 1,
      "refreshInterval": 5
    }
  }
  ```
- [ ] Test matrix:
  - [ ] NO_BUDDY: renders the hatch prompt.
  - [ ] Each rarity: ANSI color correct.
  - [ ] Terminal widths 30, 40, 80, 200: degrades cleanly.
  - [ ] CORRUPT: renders repair prompt, no crash.

## Exit criteria

- Status line visible on every assistant turn.
- Reflects live state (re-renders after hatch / reset).
- Never blocks Claude Code (p95 runtime < 50ms).

## Notes

- Status line script runs debounced 300ms after each assistant message per [statusline docs](https://code.claude.com/docs/en/statusline). `refreshInterval: 5` adds an idle timer; drops to 1 in P7-2 for animation cadence.
- Claude Code pipes a JSON payload (model, workspace, cost, etc.) on stdin — ignored here, but don't error if malformed.
- Shiny variants (P7-2) will add rainbow ANSI; ensure `buddy.shiny` flag is read now but purely cosmetic until P7-2.
