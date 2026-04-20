---
title: Claude Code plugin scaffolding — non-obvious behaviors
date: 2026-04-16
category: developer-experience
module: claude-code-plugin-system
problem_type: developer_experience
component: tooling
severity: medium
applies_when:
  - Scaffolding a new Claude Code plugin from scratch
  - Designing plugin command structure and naming
  - Configuring plugin settings.json
  - Developing or reloading plugin skills mid-session
  - Using disable-model-invocation in skill frontmatter
tags:
  - claude-code
  - plugin-system
  - skill-namespacing
  - settings-json
  - plugin-reload
  - disable-model-invocation
---

# Claude Code plugin scaffolding — non-obvious behaviors

## Context

During P0 scaffolding of a Claude Code plugin named "buddy", four non-obvious behaviors of the plugin system surfaced. These behaviors are not prominently documented and caused design pivots mid-implementation. The findings apply to any developer building a Claude Code plugin for the first time.

## Guidance

### 1. Plugin skills are always namespaced — no bare slash command from a plugin

Every skill registered through a plugin is invoked as `/<plugin-name>:<skill-name>`. There is no mechanism to expose a bare `/<name>` command from a plugin. That namespace is reserved for built-in Claude Code commands and project/personal (non-plugin) skills.

**Design implication:** If you name your plugin "buddy" and create a single skill also named "buddy", the user must type `/buddy:buddy` — redundant and awkward. The correct response is to decompose the plugin into purposeful, well-named skills so the resulting commands are self-documenting.

Preferred pattern: name skills for what they do, not for the plugin itself.

```
# Avoid — results in /buddy:buddy
plugin: buddy
skill: buddy

# Prefer — results in /buddy:hatch, /buddy:interact, /buddy:stats
plugin: buddy
skills: hatch, interact, stats
```

### 2. `settings.json` at the plugin level supports only `agent` and `subagentStatusLine`

Plugin-level `settings.json` has a constrained key surface. The only supported keys are:

- `agent`
- `subagentStatusLine`

The key `statusLine` is **not** supported at the plugin level. Any plan that places a `statusLine` configuration in a plugin's `settings.json` will be silently ignored. Check the [official plugin reference](https://code.claude.com/docs/en/plugins-reference) for the authoritative list before designing plugin configuration.

### 3. New `skills/` directories created mid-session require a full restart

If you create a `skills/` directory during an active Claude Code session (i.e., the directory did not exist when the session started), `/reload-plugins` will not pick it up. The file watcher only monitors directories that existed at session start.

To activate a newly created skills directory you must restart Claude Code:

```bash
claude --plugin-dir .
```

Skills added to an already-watched `skills/` directory (one that existed at session start) can be reloaded with `/reload-plugins` as expected.

### 4. `disable-model-invocation: true` prevents auto-invocation only

The `disable-model-invocation: true` frontmatter flag stops Claude from automatically loading or invoking a skill based on conversational context. It does **not** prevent the model from processing the skill's `SKILL.md` body when the user explicitly types the slash command. On explicit invocation, the model still reads and executes the instructions.

Do not rely on this flag as a way to suppress model interpretation on explicit invocation — it only controls automatic context-triggered invocation.

## Why This Matters

These behaviors collectively determine the shape of a plugin before a line of real feature code is written. Misunderstanding any one of them leads to:

- **Awkward command naming** that cannot be fixed without renaming skills or the plugin itself (namespace issue)
- **Silent misconfiguration** where `settings.json` keys are ignored without error (`statusLine`)
- **Wasted debugging time** attributing missing skills to code errors rather than a session-restart requirement (directory watching)
- **Incorrect assumptions** about invocation gating because `disable-model-invocation` is misread as a full invocation block

Getting these right at the scaffolding stage avoids rework that touches both the plugin structure and any downstream documentation or user-facing command references.

## When to Apply

- When scaffolding a new Claude Code plugin from scratch
- When naming plugin skills and deciding on command ergonomics
- When adding `settings.json` to a plugin and choosing configuration keys
- When creating new skill directories during an active development session
- When using `disable-model-invocation` in skill frontmatter and reasoning about its scope

## Examples

### Namespace pivot: before and after

**Before** — single skill named after the plugin:

```
plugin name: buddy
skills/
  buddy/
    SKILL.md   → invoked as /buddy:buddy (redundant)
```

**After** — separate purposeful skills:

```
plugin name: buddy
skills/
  hatch/
    SKILL.md   → /buddy:hatch
  interact/
    SKILL.md   → /buddy:interact
  stats/
    SKILL.md   → /buddy:stats
```

### `settings.json` — invalid vs valid keys

```json
// INVALID — statusLine is not supported at plugin level
{
  "statusLine": { "type": "command", "command": "sh ./statusline.sh" }
}

// VALID — only these keys are supported
{
  "agent": { },
  "subagentStatusLine": "buddy active"
}
```

### Directory watching — reload vs restart

```bash
# Scenario: skills/ directory did not exist at session start
mkdir -p skills/hatch
# Write SKILL.md...

# /reload-plugins → detects plugin manifest, but 0 skills loaded

# Must restart:
claude --plugin-dir .
# /buddy:hatch is now available
```

## Related

- [claude-code-plugin-hooks-json-schema-2026-04-20.md](./claude-code-plugin-hooks-json-schema-2026-04-20.md) — fifth peer gotcha in the "non-obvious Claude Code plugin platform behaviors" family: `hooks/hooks.json` requires nested `hooks:` entries, not the flat shape some docs show. Same "looks right, silently wrong" trap pattern as the items in this doc.
- [P0 scaffolding ticket](../roadmap/P0-scaffolding.md) — source findings in the Notes section
- [P0 implementation plan](../plans/2026-04-16-002-feat-p0-plugin-scaffolding-plan.md) — pre-discovery framing of namespace and reload questions
- [Full plugin plan](../plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md) — architectural context (Naming Decision, API Surface Parity)
- [Plugin reference docs](https://code.claude.com/docs/en/plugins-reference) — authoritative manifest schema and settings.json key support
- [Skills docs](https://code.claude.com/docs/en/skills) — SKILL.md frontmatter reference including `disable-model-invocation`
