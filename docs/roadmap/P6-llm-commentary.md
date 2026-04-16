---
id: P6
title: LLM-generated contextual commentary
phase: P6
status: todo
depends_on: [P3-2]
origin_plan: docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md
---

# P6 — LLM commentary (contextual)

## Goal

Upgrade commentary from shuffle-bag canned lines to LLM-generated lines that reference what the user actually just did. Keeps the plugin's voice sharp while reacting to real context. Canned fallbacks preserve reliability.

## Tasks

- [ ] **Decide delivery mechanism** (A/B during this ticket):
  - **A.** `prompt`-type hook ([hooks docs](https://code.claude.com/docs/en/hooks)) — simpler, rides Claude Code's existing auth.
  - **B.** Dedicated plugin subagent — richer but heavier.
  - Measure latency (target p95 < 2s) and output flexibility on 50 sample events. Pick based on data. Document choice in this ticket's Notes.
- [ ] **Prompt template** includes:
  - [ ] Species archetype voice (e.g., "deadpan-night").
  - [ ] Current form.
  - [ ] 5 stats (DEBUGGING/PATIENCE/CHAOS/WISDOM/SNARK) with brief descriptors.
  - [ ] Recent event payload summary (tool name, file, success/failure, error if any).
  - [ ] Last 3 comments (to avoid self-repetition).
  - [ ] Session mood tags (optional — short session / long session / error streak).
  - [ ] Output constraints: single sentence, ≤ 80 chars, in-character, no markdown.
- [ ] **Fallback chain**: LLM timeout > 2s OR error OR output fails constraint check → pick canned line. Users never see a gap.
- [ ] **LLM-generated names** on hatch (upgrade from canned name pool in P1-2). Mirrors `/buddy`'s "bones are computed, soul is LLM-generated once and persisted" pattern.
- [ ] **Cache generated names** in `buddy.name_source: "llm" | "canned"` so names never regenerate (stability matters — the buddy's name is its identity).
- [ ] **Observability**: log LLM calls to `${CLAUDE_PLUGIN_DATA}/commentary.log` with event type, latency, success/failure, fallback-used flag. Helps tune prompt + detect regressions.
- [ ] Tests:
  - [ ] Latency: 100-event batch — p95 under 2s.
  - [ ] Fallback triggers when LLM fails (simulate timeout).
  - [ ] Self-repetition test: 20 consecutive events don't repeat phrasing (LLM prompt includes last 3 comments).
  - [ ] Constraint check: output longer than 80 chars or containing markdown → fallback.

## Exit criteria

- Commentary references the actual tool call / file / error more often than not.
- Failure modes never block Claude Code (fallback always fires).
- LLM-generated names land on hatch.

## Notes

- This is the single biggest quality lever for felt personality. Canned lines in P3-2 carry until here; P6 is the upgrade that makes the buddy feel alive.
- Keep canned banks from P3-2 as the fallback pool — don't delete them.
- Possible optimization: cache generated lines per (species, form, event_type) to reduce LLM calls. Evaluate after initial latency testing.
- Plan reference: Key Design Decision D3 rate-limit stack is preserved here — P6 changes line *generation*, not line *gating*.
