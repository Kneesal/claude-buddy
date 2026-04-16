---
id: P4-2
title: Form transitions + evolution paths
phase: P4
status: todo
depends_on: [P4-1]
origin_plan: docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md
---

# P4-2 — Form transitions

## Goal

Turn accumulated XP + signals into observable evolution. At level 10 (first evolution threshold), pick a form based on the dominant behavior axis. Update status line, line banks, and commentary to reflect the new form. This ticket ships the product's distinct value vs Anthropic's `/buddy`.

## Tasks

- [ ] Define evolution paths in each `scripts/species/<name>.json` under `evolution_paths`:
  - [ ] At minimum 2 paths per species, one triggered by each of 2 different dominant axes.
  - [ ] Example — Axolotl: `base → scholar` (variety-dominant), `base → chaos` (chaos-dominant), `base → zen` (consistency-dominant).
- [ ] Form thresholds: Lv 10 → form 2. Lv 25 → form 3 (if defined). Stored as `form_thresholds: [10, 25]` in each species file.
- [ ] **Form selection at threshold**:
  - Normalize each signal to [0, 1]: divide by a species-specific typical-max.
  - Pick the highest-normalized axis. Ties broken by species preference (`preferred_axis` in species JSON, e.g., Dragon prefers `chaos`).
- [ ] **Evolution ceremony**: when form transitions, run a one-time surprise-budget-exempt comment (`🦎 Pip is evolving! ... Pip became a Scholar Axolotl!`). Record in `buddy.evolution_history`.
- [ ] **Status line**: shows current form (e.g., "Scholar Axolotl" instead of just "Axolotl"). Per-form icon override optional.
- [ ] **Commentary banks per form**: species JSON gets `line_banks.<EventType>.by_form.<form>` override; falls back to `default` when not defined.
- [ ] Tests:
  - [ ] Simulate variety-dominant user → Lv 10 → Scholar form.
  - [ ] Simulate chaos-dominant user → Lv 10 → Chaos form.
  - [ ] Evolution ceremony fires exactly once per transition.
  - [ ] Reroll resets `form` to `base` and clears `evolution_history` (but preserves tokens).

## Exit criteria

- After ~a week of real use, a user sees their buddy visibly evolve.
- Different behavior patterns on fresh buddies of the same species yield different forms.
- Rerolling wipes form and history cleanly.

## Notes

- **This is the thing.** Everything before P4-2 is plumbing; this is the feature that makes the plugin different from Anthropic's `/buddy`. Get the transition moment right — it should feel like a small celebration.
- Per-species `preferred_axis` matters for flavor: a chaos-leaning dragon is a feature, not a bug. Gives each species identity beyond stats.
- Consider visual marker on evolution: brief ANSI flash / sparkle chars in status line for N seconds. Nice-to-have, not required for exit.
- Content commitment: per-form line banks need ≥ 30 lines each, or forms feel hollow. Can be lower if time-constrained; revisit in P8.
