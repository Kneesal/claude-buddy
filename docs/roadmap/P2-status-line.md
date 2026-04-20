---
id: P2
title: Status line rendering
phase: P2
status: done
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
- [ ] **Document the user-level `settings.json` opt-in in README.** Plugin-level `settings.json` only supports `agent` and `subagentStatusLine`; `statusLine` is user-level only (`~/.claude/settings.json` or project-level `.claude/settings.json`). README gives users the snippet:
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
- [ ] Add a top-level `emoji` field to each `scripts/species/*.json` file so the status line can pick a per-species icon from species data (scales to P7-1's 18 species without a hardcoded map).
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

- Status line script runs debounced 300ms after each assistant message per [statusline docs](https://code.claude.com/docs/en/statusline). `refreshInterval: 5` adds an idle timer.
- **`refreshInterval` stays at 5 permanently.** The original plan had it dropping to 1 in P7-2 for animation; P7-2 has been re-scoped away from status-line animation and toward chat-output ASCII portraits. The status line is ambient-only from here on.
- Claude Code pipes a JSON payload (model, workspace, cost, etc.) on stdin — ignored here, but don't error if malformed.
- Shiny variants (P7-2) add a sparkle emoji to the status line as the lightweight tell, plus rainbow ANSI on the chat-output portrait. `.buddy.shiny` is read now for a stub code path and surfaces in P7-2.
- **FUTURE_VERSION** is the fourth sentinel from `state.sh` — not mentioned in the original task list but worth rendering: `⚠️ update plugin to read newer buddy.json`. Consistent with how `scripts/status.sh` handles it in P1-3.

### Implementation notes

- **Plan**: [docs/plans/2026-04-20-001-feat-p2-status-line-plan.md](../plans/2026-04-20-001-feat-p2-status-line-plan.md).
- **Landed:** `statusline/buddy-line.sh`, `emoji` field in all 5 species JSONs, README status-line section with the user-level `settings.json` snippet, `tests/statusline.bats` with 25 scenarios.
- **Width bands:** ≥40 full line, 30–39 drops tokens, <30 drops rarity qualifier. Tested explicitly at 80 / 35 / 25.
- **Rarity color map** implemented as a bash associative array (`_BUDDY_LINE_COLOR`), one entry per rarity. `NO_COLOR=1` strips ANSI. Rainbow rendering for shinies is the P7-2 handoff.
- **Field extraction gotcha:** the `@tsv` + `IFS=$'\t' read -a` pattern from `scripts/status.sh` does not preserve empty fields because tab is whitespace — bash's `read` collapses consecutive tabs. For the status line, which must render correctly even when `buddy.json` is semi-valid (a schemaVersion=1 envelope with null `.buddy`), this matters. Solution: two-step jq extraction — one upstream validity check (`.buddy | type == "object"` and required string fields non-empty), then a newline-delimited `jq -r` for the six fields, consumed via `readarray -t`. Newlines are non-whitespace to bash's line-reading path and preserve empties correctly.
- **Performance:** 14.5ms average on 10 warm runs on the dev container. p95 target was <50ms; actual is well under.
- **Stdin handling:** script drains stdin when not a TTY (via `cat > /dev/null`) so Claude Code's JSON payload is discarded without being parsed. Stdin with malformed JSON is explicitly tested and doesn't crash.
- **Umbrella plan amendment (2026-04-20):** P7-2 was re-scoped away from status-line animation toward chat-output ASCII portraits. See [docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md](../plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md) P7-2 section's design-amendment block, and the updated P7-2 ticket.

### Review-driven changes (2026-04-20)

`/ce:review` at medium effort dispatched 8 reviewers (4 always-on + 2 CE + reliability, adversarial). Merged set: ~14 findings. Applied 9 `safe_auto` fixes:

- **P1 — GNU sed portability (COR-001 / M-002 / REL-002 / ADV-006 / PS-002):** `_buddy_line_cap` used `sed 's/^./\U&/'` which is a GNU extension. BSD sed on macOS would render "Uommon" instead of "Common". Replaced with bash's `${rarity^}` parameter expansion — same technique `scripts/status.sh` already uses. Function deleted; one fork fewer per render. Five reviewers flagged this independently.
- **P2 — newline in `.buddy.name` (ADV-001):** a literal `\n` inside a hand-edited name decoded to a real LF in `jq -r`, split by `readarray -t`, and shifted every downstream field one slot left. Fix: jq `gsub("[\\n\\r\\t]"; " ")` on string fields so embedded whitespace never enters the split. Empty-output guard added after the second jq call to route to CORRUPT on unexpected failure.
- **P2 — stdin-drain deadlock (REL-001 / ADV-003):** bare `cat >/dev/null` has no timeout, so a parent that keeps the pipe write-end open past script launch would hang indefinitely. Wrapped in `timeout 0.1` — legitimate Claude Code payloads arrive in microseconds, so the cap is only reached on a pathological caller.
- **P2 — `_inject_tokens` + seed helpers duplicated across slash.bats and statusline.bats (T-03 / M-001):** hoisted to `tests/test_helper.bash` with `HATCH_SH` / `STATUS_SH` / `RESET_SH` / `STATUSLINE_SH` globals. `_set_rarity` stays local to statusline.bats since it's only used there.
- **P2 — roadmap README P7-2 row stale (PS-001):** updated title to "ASCII portraits in chat output + shinies" and deps to `[P1-3, P2, P7-1]` to match the re-scoped ticket.
- **P3 — `tput cols` returns 0 without TTY (REL-003):** regex passed 0 as valid, forcing every non-TTY render into the narrow-line band. Added `(( cols > 0 ))` to the width-fallback guard.
- **P3 — shiny=false absence assertion (T-01), width 30/40 boundary tests (T-02), `.buddy` non-object types (T-05), species dir missing (T-06), unset CLAUDE_PLUGIN_DATA status check (T-04):** six new test scenarios across statusline.bats and slash.bats close the coverage gaps reviewers surfaced.
- **P3 — misleading stdin-drain comment (COR-002):** comment said "use read with zero timeout" but code uses `cat`. Rewrote to match the actual strategy and document the new `timeout 0.1` wrapper.
- **P3 — duplicate "Plan:" link in P2 ticket (PS RR-002):** removed.

Deferred / rejected with rationale:

- **ADV-002 `NO_COLOR=''` (empty):** rejected. Per [no-color.org spec](https://no-color.org): *"when present and not an empty string, prevents the addition of ANSI color."* Current `[[ -z "${NO_COLOR:-}" ]]` is correct — empty value leaves colors on.
- **ADV-004 `buddy.json` symlink hangs jq:** deferred. The fix belongs in `state.sh::buddy_load` (same symlink guard it already applies to the lock file); affects every reader, not just P2's status line. Follow-up ticket candidate for a future P1-1 refresh.
- **ADV-005 ANSI injection via `.buddy.name`:** deferred. P1-2's `roll_name` uses a canned pool with no control chars. Surfaces when P6 LLM-generated names land; handle there.
- **M-003 jq shape-validator duplicated across status.sh and buddy-line.sh:** advisory. Acceptable at two call sites; extract to `scripts/lib/state.sh` when P7-2's portrait renderer becomes the third consumer.

Learnings-researcher output: the `@tsv` + `IFS=$'\t'` null-field-collapse gotcha is empirically verified, present in two renderers with matching rationale comments, and currently undocumented. Worth promoting to `docs/solutions/` via a follow-up `/ce:compound`. Suggested title: "bash jq @tsv null-field collapse — use readarray or validate first".

Tests after review: **184 green** (state 52 + rng 66 + slash 37 + statusline 29), up from 178 at review start.

### Exit criteria check

- ✅ Status line visible on every assistant turn (once user opts in via settings.json).
- ✅ Reflects live state (re-renders after hatch / reset since it reads `buddy.json` each invocation).
- ✅ Never blocks Claude Code (measured 14.5ms average, well under the 50ms p95 target).
- ✅ All four sentinel states covered (NO_BUDDY, ACTIVE, CORRUPT, FUTURE_VERSION) plus 5 rarity color variants + 3 width bands + stdin-drain + shiny stub + `NO_COLOR` + missing-emoji fallback + malformed-envelope fallback.
