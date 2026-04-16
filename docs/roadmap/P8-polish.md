---
id: P8
title: Polish, docs, /buddy stats, publication
phase: P8
status: todo
depends_on: [P7-2, P5]
origin_plan: docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md
---

# P8 — Polish

## Goal

Ship-ready plugin: extra UX affordances, comprehensive docs, optional marketplace publication. This is the ticket where we decide if the plugin is genuinely good.

## Tasks

- [ ] `/buddy stats` sub-command: detailed view of stats, signals, evolution history, token history, pity counter, schema version.
- [ ] `/buddy feed` (optional daily engagement):
  - [ ] Once per calendar day, feeds the buddy for a small XP bump (~5% of current level's XP requirement).
  - [ ] Purely optional — does not gate progression.
- [ ] `/buddy reset --export` (or similar flag): dump buddy state to stdout before wipe, so users can manually back up their buddy.
- [ ] `--verbose` flag on `/buddy` showing schema version, data dir path, recent migration log, error log tail.
- [ ] **README overhaul**:
  - [ ] Quick-start GIF showing hatch → status line → commentary.
  - [ ] Rarity/species chart.
  - [ ] Evolution-path cheatsheet per species.
  - [ ] Troubleshooting section (corrupt state, lost buddy, uninstall lifecycle).
  - [ ] Uninstall contract: explicit warning that `claude plugin uninstall` without `--keep-data` deletes the buddy.
- [ ] `CHANGELOG.md` with schema versions and behavior changes from v0.1.0 onward.
- [ ] **Marketplace publication** (optional — decide now):
  - [ ] Submit to [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) if appropriate.
  - [ ] Or list in a third-party marketplace.
  - [ ] Or publish as GitHub-only (`claude plugin install gh:user/repo`).
- [ ] Opt-in telemetry: user-configurable `userConfig.telemetry: false` (default). When on, counts hatches/rerolls/evolutions locally into `${CLAUDE_PLUGIN_DATA}/stats.json` — for the user's own curiosity, not sent anywhere.
- [ ] Voice review pass: read 5 random lines per species per form; rewrite any that don't land.
- [ ] Integration test scenarios 1-8 from the plan all pass on a clean install.

## Exit criteria

- No known UX cliffs.
- Docs are good enough that a new user installs and hatches within 2 minutes of reading the README.
- At least one friend/colleague has used it for a week and is attached to their buddy.

## Notes

- This ticket is the "should we ship" gate. If voice review or UX pass surfaces issues, loop back.
- Marketplace publication is not required — a well-documented GitHub repo is sufficient for v1. Decide based on polish level.
- Telemetry defaulting to off is deliberate: the brainstorm was explicit about no monetization and no cross-user sharing. Personal stats stay local.
- After P8: new features (per-project buddies, custom species mods, cross-device sync) each get their own brainstorm + plan + roadmap tickets. See Plan → Future Considerations.
