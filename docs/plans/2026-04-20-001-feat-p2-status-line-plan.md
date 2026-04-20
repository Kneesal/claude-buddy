---
title: P2 — Status line rendering
type: feat
status: complete
date: 2026-04-20
origin: docs/roadmap/P2-status-line.md
---

# P2 — Status line rendering

## Overview

Ship `statusline/buddy-line.sh`: a small bash script invoked by Claude Code on every assistant turn, reads the current buddy envelope, and prints one line. Single-line, ambient, never blocks the session. ANSI rarity color, per-species emoji, width-safe graceful degradation. No animation, no multi-line sprite, no runtime config surface beyond what state.sh already exposes.

The plan also corrects a known error in the P2 ticket: the status line cannot be registered from plugin-level `settings.json` — it's a user-level key. The README must hand users the snippet they need for their own `settings.json`.

## Problem Frame

P1 landed everything needed to persist a buddy and talk to it on demand via slash commands. What's missing is the "my buddy is here" feel — right now nothing is visible on-screen between commands. The status line is the only plugin-accessible ambient surface (verified against the live plugin docs: `statusLine` / `subagentStatusLine` are the only persistent render primitives; plugins cannot claim a side panel, overlay, or dedicated region). One line per turn is the right scope.

A design amendment locked in the umbrella plan before writing this ticket: rich ASCII portraits move from the status line to slash-command chat output. P7-2's `refreshInterval: 1` animation loop and multi-line status rendering are dropped. This keeps P2 small and P7-2 is re-scoped separately.

## Requirements Trace

- **R1.** Script at `statusline/buddy-line.sh`, marked executable, sources `scripts/lib/state.sh`, calls `buddy_load`, branches on the sentinel output (NO_BUDDY / CORRUPT / FUTURE_VERSION) or renders the ACTIVE line when the output is JSON.
- **R2.** ACTIVE line format: `<icon> <name> (<Rarity> <Species> · Lv.<level>) · <balance> 🪙`.
- **R3.** NO_BUDDY line: `🥚 No buddy — /buddy:hatch`. Namespaced command name, matches what P1-3 actually registers.
- **R4.** CORRUPT line: `⚠️ buddy state needs /buddy:reset`.
- **R5.** FUTURE_VERSION line: `⚠️ update plugin to read newer buddy.json`. Ticket didn't spell this out, but state.sh exposes the sentinel and P1-3's slash commands already render a distinct message for it — the status line should too.
- **R6.** Per-rarity ANSI color in the rarity-qualified segment: grey Common, white Uncommon, blue Rare, purple Epic, gold Legendary. `$NO_COLOR` is honored (strip all ANSI). Shiny flag is read from `.buddy.shiny` and stub-handled for P7-2 (no rainbow yet).
- **R7.** Per-species emoji. Each `scripts/species/<name>.json` gains a new top-level `emoji` string field. Default fallback emoji used if the field is missing (defensive — in case a future species file is malformed).
- **R8.** Width-safe degradation using `$COLUMNS` (falls back to `tput cols` if unset, then to 80 if that fails too):
  - `>= 40` cols → full line.
  - `< 40` → drop the ` · <balance> 🪙` segment.
  - `< 30` → also drop the rarity qualifier (render `<icon> <name> (Lv.<level>)`).
- **R9.** Stdin payload from Claude Code is read and discarded. Script never errors if stdin is empty, not JSON, or closed.
- **R10.** Missing `${CLAUDE_PLUGIN_DATA}` → render NO_BUDDY line (state.sh already handles this correctly; script inherits).
- **R11.** Exit 0 on every path, including internal errors — status line must never surface a shell error to the user. On internal error, print a safe fallback (empty line or the CORRUPT marker) and exit 0.
- **R12.** Target p95 latency < 50ms (tighter than the hook contract's 100ms — status line runs far more often).
- **R13.** README documents the user-level `settings.json` snippet so users can opt in.
- **R14.** `tests/statusline.bats` covers the sentinel matrix, rarity colors, width degradation, stdin handling, and the no-color fallback.

## Scope Boundaries

- **Not** multi-line rendering. `refreshInterval` stays at 5. No `tput` height inspection. P7-2 originally planned this; the umbrella plan amendment (companion to this ticket) moves ASCII portraits into slash-command chat output instead.
- **Not** animation. No frame counter, no random per-render variation.
- **Not** shiny rendering. `.buddy.shiny` is read and passed through a stub code path but the output is identical to non-shiny for P2.
- **Not** reading hook-driven session state (session-<id>.json). The status line is stateless beyond `buddy.json`.
- **Not** registering the status line from plugin `settings.json` — plugin-level `settings.json` only supports `agent` and `subagentStatusLine` (see institutional learning below). The README hands users the user-level snippet.

### Deferred to Separate Tasks

- **Umbrella plan amendment** — P7-2 re-scoped away from status-line animation and toward chat-output ASCII portraits. Tracked separately as a roadmap edit; P2 just stays within its one-line lane.
- **ASCII portrait renderer** — the new target surface for sprites. Will eventually hang off `scripts/status.sh` / `scripts/hatch.sh` output. Not in P2.

## Context & Research

### Relevant Code and Patterns

- `scripts/status.sh` — the P1-3 sentinel-switch renderer. Different surface (chat, multi-line) but same `buddy_load` → case branch pattern this script will mirror. Reuse the one-jq-invocation-per-render hygiene (line 25: `jq -r '[...] | @tsv'` extracts all fields in one fork).
- `scripts/lib/state.sh` — the sourcing contract: no module-level `set -euo pipefail`, bash 4.1+ guard, three sentinel constants (`STATE_NO_BUDDY` / `STATE_CORRUPT` / `STATE_FUTURE_VERSION`). Status-line script follows the same shape.
- `scripts/hatch.sh` and `scripts/reset.sh` — both source state.sh and use `BASH_SOURCE`-relative resolution for the lib path. Status-line script uses the same pattern with an extra `..` hop (it lives in `statusline/`, not `scripts/`).
- `scripts/species/*.json` — each species file follows the P1-2 schema (`species`, `voice`, `base_stats_weights`, `name_pool`, `evolution_paths`, `line_banks`, `sprite`, `schemaVersion`). No `emoji` field yet — this ticket adds it.
- `tests/test_helper.bash` — per-test `CLAUDE_PLUGIN_DATA` isolation via `BATS_TEST_TMPDIR`, unset of `BUDDY_RNG_SEED` / `BUDDY_SPECIES_DIR`, sources state.sh at suite level. Reuse for `statusline.bats`.

### Institutional Learnings

- `docs/solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md` — the constraint we're correcting: plugin-level `settings.json` supports only `agent` and `subagentStatusLine`. The ticket's proposed `statusLine` block must live in the user's `settings.json`, not the plugin's.
- `docs/solutions/best-practices/bash-state-library-patterns-2026-04-18.md` — sentinel-switch discipline (never compare against a raw string literal, always against the readonly constants); `run --separate-stderr` in bats; no module-level `set -e` in sourced libraries. All apply directly.
- `docs/solutions/developer-experience/claude-code-skill-dispatcher-pattern-2026-04-19.md` — establishes the thin-dispatcher convention. Status line is closer to a hook than a skill (no SKILL.md, runs directly), but the same "exit 0 on every user-visible path" hygiene applies.

### External References

None required. Claude Code status-line protocol (stdin JSON payload, refreshInterval, padding, command type) is already documented in the umbrella plan and cross-referenced to the live statusline docs.

## Key Technical Decisions

- **Registration is user-level, not plugin-level.** The ticket had the snippet in plugin `settings.json`; that's a no-op (silently ignored). README carries the correct user-level snippet and explicitly flags it as an opt-in step. We do not auto-install into the user's global config.
- **Add an `emoji` field to each species JSON.** Cleanest place for the icon — centralizes the species-display surface alongside voice and name pool. One field addition to the existing 5 species files. Default fallback emoji (e.g., `🐾`) lives in the status-line script for the malformed-file case.
- **Rarity color map is a bash associative array in the script.** Five entries, keyed on rarity name. Matches how state.sh's `_RNG_FLOORS` pattern already works.
- **Width detection priority: `$COLUMNS` → `tput cols 2>/dev/null` → 80.** `$COLUMNS` is what terminals set on SIGWINCH; `tput` is the portable fallback; 80 is a safe assumption. Reading `tput` is a fork — only do it if `$COLUMNS` is unset.
- **`NO_COLOR` environment variable honored.** De-facto standard. When set (non-empty), skip all ANSI escapes and render plain text.
- **Render via a single `printf` per line.** No intermediate variable concatenation in a hot path. One call, one flush, exit 0.
- **Script lives in `statusline/` at repo root, not `scripts/statusline/`.** The umbrella plan's directory tree already specifies this layout; matches Claude Code's plugin convention where each surface type gets a sibling top-level dir (`skills/`, `hooks/`, `statusline/`, `scripts/`).
- **p95 < 50ms target is 2× tighter than hooks.** The status line script runs on every assistant turn plus idle refresh (every 5s). A slower script shows up as perceptible UI lag. Realistically achievable: one file read, one jq invocation, one printf.

## Open Questions

### Resolved During Planning

- **Plugin-level vs user-level `settings.json`** — user-level only (docs verified + institutional learning).
- **Emoji storage location** — per-species JSON, new `emoji` field. Alternative (hardcoded map in the script) rejected because it would drift from the species roster as P7-1 adds 13 more.
- **FUTURE_VERSION line wording** — status line shows `⚠️ update plugin to read newer buddy.json`. Matches the message tone state.sh already uses in its warning.
- **Shiny rendering for P2** — stub only. `.buddy.shiny` is read but not rendered differently. Rainbow rendering lives in the same code path (a post-color filter) and lights up in P7 when shinies actually exist.
- **Refresh cadence** — keep `refreshInterval: 5` from the ticket; P7-2 would have dropped to 1 for animation, but that's moved to chat output so the 5-second cadence is permanent.

### Deferred to Implementation

- **`printf -v` vs direct `printf` for the ANSI-colored rarity segment** — decide while writing. If color-stripping for `NO_COLOR` is cleaner with a pre-formatted buffer, use `-v`. Style question, not correctness.
- **Exact width thresholds** — 40 and 30 are the ticket's starting point. May need a third break at ~50 if the full line routinely overflows on typical 80-col terminals after real species/rarity fill-in. Measure during implementation.

## Implementation Units

- [x] **Unit 1: Add `emoji` field to the 5 launch species**

**Goal:** Extend each `scripts/species/<name>.json` with a top-level `emoji` field so the status-line script has a per-species icon to render.

**Requirements:** R7

**Dependencies:** None (data-only change).

**Files:**
- Modify: `scripts/species/axolotl.json`, `scripts/species/capybara.json`, `scripts/species/dragon.json`, `scripts/species/ghost.json`, `scripts/species/owl.json`

**Approach:**
- Add `"emoji": "<unicode-codepoint>"` alongside the existing `"species"` / `"voice"` fields.
- Candidate mapping (final choice made during implementation — pick whichever single-codepoint emoji reads cleanly at 1-char width):
  - axolotl → 🦎 (lizard; no axolotl emoji exists)
  - capybara → 🐹 (hamster-ish; no capybara emoji)
  - dragon → 🐉
  - ghost → 👻
  - owl → 🦉
- Confirm each file still parses with `jq '.'` after the edit (trivial; the structural addition is safe).
- P1-2's rng tests read these files and select random names / stats; they don't reference `emoji`, so no test changes needed.

**Test scenarios:**
- `Test expectation: none — pure data addition with no behavioral change. Unit 4's statusline.bats exercises the read path.`

**Verification:**
- `jq '.emoji' scripts/species/*.json` returns a non-empty string for all 5 files.
- `bats tests/rng.bats` still green (no regressions from the schema addition).

---

- [x] **Unit 2: `statusline/buddy-line.sh` — the renderer**

**Goal:** Produce the single-line status output per state, with ANSI color, per-species emoji, and width-safe degradation.

**Requirements:** R1, R2, R3, R4, R5, R6, R8, R9, R10, R11, R12

**Dependencies:** Unit 1 (species files need the emoji field before the script reads it).

**Files:**
- Create: `statusline/buddy-line.sh`
- Test: `tests/statusline.bats` (Unit 4)

**Approach:**
- Shebang `#!/usr/bin/env bash`. No module-level `set -euo pipefail` (same discipline as scripts/hatch.sh). Script-level error handling is explicit; on any internal failure, print a safe fallback (empty line or CORRUPT marker) and exit 0.
- Source `scripts/lib/state.sh` via `BASH_SOURCE`-relative resolution: `$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/state.sh`.
- Read and discard stdin: `cat >/dev/null 2>&1 &` with a brief timeout, or `read -t 0 -N 0` — pick the simpler form. The script must never block waiting for stdin if Claude Code sends nothing.
- Resolve width: `${COLUMNS:-$(tput cols 2>/dev/null)}` with a `80` fallback.
- Call `buddy_load`; capture output into `state` variable.
- Branch on `"$state"` against `STATE_NO_BUDDY` / `STATE_CORRUPT` / `STATE_FUTURE_VERSION` constants. Default (`*`) is the JSON path.
- For the JSON path:
  - One `jq -r` invocation extracts `species`, `name`, `rarity`, `level`, `shiny`, `tokens.balance` as TSV (pattern from `scripts/status.sh` line 25).
  - Load the per-species emoji: `jq -r '.emoji // "🐾"' "$species_dir/$species.json"`. Cache the resolution once per invocation.
  - Rarity color: bash associative array keyed on rarity string. Apply ANSI only if `NO_COLOR` is unset.
  - Width degradation: three branches (>=40, 30–39, <30) produce three format strings.
  - Single `printf` emits the line.
- On malformed JSON (jq error), fall through to CORRUPT rendering. On missing emoji field, fall through to the default. Every path ends in `exit 0`.

**Execution note:** Start with a failing test for the NO_BUDDY case before writing the script. The sentinel-switch path is where most of the logic lives; test-first pins the contract.

**Patterns to follow:**
- `scripts/status.sh` — the sentinel-switch render pattern, one-jq-per-render hygiene.
- `scripts/hatch.sh` — `BASH_SOURCE`-relative library sourcing.

**Test scenarios:** (full list in Unit 4; this unit's verification is "the script exists, is executable, and runs without erroring against a seeded buddy.json").

**Verification:**
- `bash statusline/buddy-line.sh </dev/null` against a seeded `CLAUDE_PLUGIN_DATA` prints the expected line and exits 0.
- `bash statusline/buddy-line.sh </dev/null` against an unset `CLAUDE_PLUGIN_DATA` prints the NO_BUDDY line and exits 0.
- Script file has `chmod +x`.

---

- [x] **Unit 3: README user-level `settings.json` snippet**

**Goal:** Document the user-level opt-in for the status line, since plugin-level `settings.json` can't register it.

**Requirements:** R13

**Dependencies:** Unit 2 (script must exist at the documented path).

**Files:**
- Modify: `README.md`

**Approach:**
- Add a "Status line" section (or extend the existing Commands section) with:
  - A one-sentence framing: the plugin ships a status-line script; enable it by adding a snippet to your user-level `settings.json`.
  - The exact JSON snippet using `${CLAUDE_PLUGIN_ROOT}` so it works regardless of install location:
    ```
    {
      "statusLine": {
        "type": "command",
        "command": "${CLAUDE_PLUGIN_ROOT}/statusline/buddy-line.sh",
        "padding": 1,
        "refreshInterval": 5
      }
    }
    ```
  - A note pointing at `~/.claude/settings.json` (global) vs `.claude/settings.json` (per-project) as the two supported locations.
  - A one-liner about `NO_COLOR` honoring for users who don't want ANSI output.
  - A brief screenshot-style example line so users know what to expect: `🦎 Pip (Rare Axolotl · Lv.3) · 4 🪙`.

**Patterns to follow:**
- Existing README Commands section (shipped in P1-3) — same table/prose density.

**Test scenarios:**
- `Test expectation: none — README documentation. The snippet's correctness is covered by verifying users can paste it and the script runs (Unit 4).`

**Verification:**
- README renders cleanly in GitHub preview.
- The path shown in the snippet resolves to an existing, executable file after Unit 2 lands.
- A human (author) pastes the snippet into a test `settings.json`, restarts Claude Code, and sees the line.

---

- [x] **Unit 4: `tests/statusline.bats` — coverage matrix**

**Goal:** Automated coverage of the sentinel states, rarity colors, width gating, stdin handling, and `NO_COLOR`.

**Requirements:** R14

**Dependencies:** Units 1, 2.

**Files:**
- Create: `tests/statusline.bats`

**Approach:**
- Reuse `tests/test_helper.bash` setup (per-test `CLAUDE_PLUGIN_DATA` in `BATS_TEST_TMPDIR`). Test file defines `STATUSLINE_SH="$REPO_ROOT/statusline/buddy-line.sh"` alongside the existing `HATCH_SH` / `STATUS_SH` / `RESET_SH`.
- Helper `_seed_hatch` already exists in `slash.bats` for seeding a deterministic buddy — extract it into `test_helper.bash` so both suites share it, OR duplicate it here if extraction is too invasive.
- Every `run` uses `--separate-stderr` per the bash-state-library patterns doc.
- Test that stdin is drained: feed a deliberately malformed JSON payload in and assert script still exits 0 with the expected output.

**Patterns to follow:**
- `tests/slash.bats` — setup, `--separate-stderr` discipline, `_seed_corrupt` / `_seed_future_version` helpers already in place (consider sharing).

**Test scenarios:**

Sentinel matrix:
- **Happy path** — NO_BUDDY → stdout contains `🥚 No buddy` and `/buddy:hatch`.
- **Happy path** — ACTIVE (seeded with `BUDDY_RNG_SEED=42`, species axolotl, rarity common) → stdout contains emoji, name, `Common axolotl`, `Lv.1`, `🪙`.
- **Edge case** — ACTIVE with injected `tokens.balance = 7` → stdout shows `· 7 🪙`.
- **Error path** — CORRUPT → stdout contains `⚠️` and `/buddy:reset`, exit 0.
- **Error path** — FUTURE_VERSION → stdout contains `⚠️` and the update-plugin message, exit 0.
- **Edge case** — unset `CLAUDE_PLUGIN_DATA` → renders NO_BUDDY, exit 0.

Rarity colors:
- **Happy path** — each rarity (common / uncommon / rare / epic / legendary) produces the expected ANSI prefix when rendered. Assertion: stdout contains the expected color-code substring; with `NO_COLOR=1` set, no ANSI codes appear.

Width gating:
- **Edge case** — `COLUMNS=80` → full line with all three segments.
- **Edge case** — `COLUMNS=35` → token balance dropped, rarity qualifier still present.
- **Edge case** — `COLUMNS=25` → rarity qualifier also dropped; `<icon> <name> (Lv.<N>)` only.
- **Edge case** — `COLUMNS` unset → script falls back to `tput cols` or 80 without crashing (mock/stub `tput` unavailability if possible).

Stdin handling:
- **Edge case** — stdin is empty (`</dev/null`) → renders correctly, exits 0.
- **Edge case** — stdin has malformed JSON (`echo 'not json' | ...`) → renders correctly, exits 0 (payload discarded).
- **Edge case** — stdin has a valid Claude Code JSON payload → same output as empty stdin (we ignore it).

Missing-field resilience:
- **Edge case** — seeded buddy.json where the rolled species file has no `emoji` field → fallback `🐾` is used, exit 0. (Simulate by pointing `BUDDY_SPECIES_DIR` at a fixture missing the field.)
- **Error path** — `buddy.json` valid but empty `.buddy` object → falls through to CORRUPT render (same handling as `scripts/status.sh`).

Latency sanity:
- **Happy path** — `time bash statusline/buddy-line.sh </dev/null` against a seeded buddy completes in under 100ms on the reference box (loose assertion; p95 target is 50ms but a single-shot wall-clock assertion is flaky, so we use a generous ceiling).

**Verification:**
- `bats tests/statusline.bats` green. Target coverage: ~15-20 scenarios.
- Full suite still green: `bats tests/` includes state.bats + rng.bats + slash.bats + statusline.bats. Total: 151 + N new tests.

## System-Wide Impact

- **Interaction graph:** Claude Code invokes `statusline/buddy-line.sh` on every assistant turn (debounced 300ms) and on idle refresh (every 5s). Script reads `${CLAUDE_PLUGIN_DATA}/buddy.json` via `buddy_load`. No writes, no hooks triggered.
- **Error propagation:** Every internal failure exits 0 with a safe fallback message. A plugin bug here must never break the Claude Code session.
- **State lifecycle risks:** None new. The script is read-only. It does not interact with the `.deleted` marker from `scripts/reset.sh` (that file exists only transiently under flock; even if observed, the script falls back to NO_BUDDY correctly).
- **API surface parity:** The script output mirrors the message wording from `scripts/status.sh` where it overlaps (CORRUPT, NO_BUDDY, FUTURE_VERSION). Three render surfaces now exist:
  - **Status line** (this unit, one line, ambient)
  - **Slash-command chat output** (`scripts/status.sh`, multi-line, on-demand)
  - **Hook commentary** (P3, transcript pop-ins, on-event)
  All three should use consistent wording for degraded states. Reviewers should flag drift.
- **Integration coverage:** flock races are not a concern — the script is read-only and `buddy_load` uses `jq '.' <file>` (atomic read, no lock needed; `buddy_save`'s tmp+rename ensures readers always see a complete prior version).
- **Unchanged invariants:** state.sh's public API is untouched. rng.sh is untouched. The three SKILL.md dispatchers and their backing scripts are untouched. This is a purely additive surface.

## Risks & Dependencies

| Risk | Mitigation |
|---|---|
| Users don't discover the user-level `settings.json` opt-in, assume the plugin "doesn't work" | README gets a prominent "Status line" section with copy-pasteable snippet; the Commands table already mentions the status line as a surface |
| Script latency exceeds the 50ms p95 target on slow disks | Single `jq` fork per render; species emoji read is small and cached per invocation; `buddy.json` is small (a few KB) |
| Unicode emoji width varies across terminals (1 vs 2 cells) | `printf` is width-agnostic; terminals handle their own emoji rendering; if a specific terminal clips, users can set `NO_COLOR=1` and we can add a `BUDDY_ASCII_ONLY` escape hatch in a follow-up |
| A malformed species file (missing or invalid `emoji` field) crashes the renderer | Default-to-`🐾` guard with `jq -r '.emoji // "🐾"'` |
| `tput cols` on an environment without a terminal (e.g., piped output) writes to stderr | Swallow via `2>/dev/null` and fall back to `COLUMNS` or 80 |

## Documentation / Operational Notes

- README gets a "Status line" section with the user-level snippet (Unit 3).
- The P2 ticket's task list has one wrong bullet (plugin-level `settings.json` registration). Ticket should be corrected during implementation — add a note in the ticket Notes section rather than editing the Tasks list retroactively, so history is preserved.
- No monitoring or rollout concerns; the status line is opt-in.
- `/ce:compound` candidate: if the `NO_COLOR` handling or width-gating approach turns out to be reusable across future status-line consumers (hooks, subagent status line), promote. Not auto-required.

## Sources & References

- **Origin ticket:** [docs/roadmap/P2-status-line.md](../roadmap/P2-status-line.md)
- **Umbrella plan:** [docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md](./2026-04-16-001-feat-claude-buddy-plugin-plan.md) — §Architecture, §API Surface Parity, §Phase P2
- **P1-1 state primitives:** [scripts/lib/state.sh](../../scripts/lib/state.sh)
- **P1-3 slash commands (render-surface reference):** [scripts/status.sh](../../scripts/status.sh)
- **Plugin-settings constraint:** [docs/solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md](../solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md)
- **Bash state library patterns:** [docs/solutions/best-practices/bash-state-library-patterns-2026-04-18.md](../solutions/best-practices/bash-state-library-patterns-2026-04-18.md)
- **Skill dispatcher pattern (convention reference):** [docs/solutions/developer-experience/claude-code-skill-dispatcher-pattern-2026-04-19.md](../solutions/developer-experience/claude-code-skill-dispatcher-pattern-2026-04-19.md)
- **Live statusline docs (via claude-code-guide):** https://code.claude.com/docs/en/statusline
