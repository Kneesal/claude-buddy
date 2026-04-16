---
id: P0
title: Plugin scaffolding
phase: P0
status: done
depends_on: []
origin_plan: docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md
---

# P0 — Plugin scaffolding

## Goal

Prove the plugin installs and a slash command runs end-to-end. No state, no hooks, no status line yet — just the minimum that makes `claude plugin install .` succeed and a `/buddy:hatch` invocation return a greeting.

## Tasks

- [x] Create `.claude-plugin/plugin.json` with `name: "buddy"`, `version: "0.1.0"`, `description`. No `userConfig` yet.
- [x] Create skills as separate commands: `skills/hatch/SKILL.md`, `skills/interact/SKILL.md`, `skills/stats/SKILL.md`.
- [x] Create `settings.json` stub (`{}`).
- [x] Create `README.md` with install instructions and command reference.
- [x] **Verify slash command resolution**: plugin skills are namespaced as `/buddy:<skill>`. Built-in `/buddy` is separate. No collision — each command is distinct.
- [x] Manual verification: `claude --plugin-dir .` installs the plugin; `/buddy:hatch` returns greeting; `/buddy:interact` and `/buddy:stats` prompt to hatch first.
- [x] Decide on implementation language: **bash** (no runtime dep). Documented in README.

## Exit criteria

- Plugin installs without error.
- The chosen slash commands print greetings or appropriate responses.
- No state file is created yet.

## Notes

### Naming (resolved 2026-04-16)

- **Plugin name**: `buddy`
- **Skill names**: `hatch`, `interact`, `stats` — invoked as `/buddy:hatch`, `/buddy:interact`, `/buddy:stats`
- **GitHub slug**: TBD at publication time.

### Slash command resolution (resolved 2026-04-16)

Plugin skills are always namespaced as `/<plugin-name>:<skill-name>`. The built-in `/buddy` is a separate built-in command and does not conflict. Original plan anticipated a single `/buddy:buddy` command, but splitting into `/buddy:hatch`, `/buddy:interact`, `/buddy:stats` is a better fit for the plugin namespace — each command is distinct and self-documenting.

### Plugin layout (final)

```
.claude-plugin/plugin.json
skills/hatch/SKILL.md
skills/interact/SKILL.md
skills/stats/SKILL.md
settings.json
README.md
```

### Findings

- `settings.json` at plugin root only supports `agent` and `subagentStatusLine` keys — **not `statusLine`**. The P2 status line approach may need revisiting.
- New `skills/` directories created mid-session require a restart to be detected. `/reload-plugins` alone is not sufficient.
- `disable-model-invocation: true` in frontmatter prevents Claude from auto-invoking the commands — users must type them explicitly.

### References

- [Plugin reference](https://code.claude.com/docs/en/plugins-reference)
- [Skills docs](https://code.claude.com/docs/en/skills)
- Plan: Proposed Solution → Naming Decision
