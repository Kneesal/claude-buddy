---
title: "feat: P0 — Plugin scaffolding"
type: feat
status: active
date: 2026-04-16
origin: docs/brainstorms/2026-04-16-claude-buddy-plugin-requirements.md
---

# feat: P0 — Plugin scaffolding

## Overview

Create the minimum viable Claude Code plugin that installs without error and provides a working `/buddy` slash command that returns a greeting. No state, no hooks, no status line — just prove the plugin primitives work end-to-end.

## Problem Frame

The Claude Buddy plugin needs a foundation before any feature work can begin. P0 establishes the plugin directory structure, manifest, and slash command wiring so that all subsequent tickets (P1–P8) have a working plugin to build on. The critical unknown is whether the plugin's `/buddy` command collides with Anthropic's built-in `/buddy` (see origin: `docs/brainstorms/2026-04-16-claude-buddy-plugin-requirements.md`).

## Requirements Trace

- R9. Slash commands — `/buddy` (or `/buddy:buddy`) must respond to user invocation
- P0 exit criteria (from `docs/roadmap/P0-scaffolding.md`): plugin installs without error; chosen slash command prints a greeting; no state file created

## Scope Boundaries

- No persistent state (`buddy.json` arrives in P1-1)
- No hooks or hook wiring (P3)
- No status line rendering (P2)
- No `userConfig` in the manifest (P3)
- No hatch/reset/status logic — just a greeting

## Context & Research

### Relevant Code and Patterns

- Repo is greenfield — no plugin files exist yet. Only `docs/` with brainstorm, plan, and roadmap.
- Full plugin plan at `docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md` defines the target architecture (lines 56–89).
- Devcontainer has Claude Code pre-installed with `jq`, `shellcheck`, `bats` available.

### External References

- [Plugin reference — manifest, directory, CLI](https://code.claude.com/docs/en/plugins-reference)
- [Plugin creation guide](https://code.claude.com/docs/en/plugins)
- [Skills / slash commands](https://code.claude.com/docs/en/skills)
- [Issue #41842](https://github.com/anthropics/claude-code/issues/41842) — plugin skills may not register as user-invocable slash commands without a `commands/` entry

## Key Technical Decisions

- **Bash as implementation language**: decided in the full plan — lowest install friction, no runtime deps. Documented in README.
- **Verification-first approach for `commands/`**: Research surfaced Issue #41842 — `skills/*/SKILL.md` alone may not register as a user-facing slash command. The workaround is `commands/buddy.md`. Start with `skills/` only; add `commands/buddy.md` during verification (Unit 3) only if the skill doesn't register as a slash command.
- **Plugin name `buddy`**: resolved in full plan — side-steps the `1270011/claude-buddy` GitHub slug collision. Creates namespace `/buddy:buddy` for the fully-qualified fallback.

## Open Questions

### Resolved During Planning

- **Plugin manifest fields**: Only `name`, `description`, `version` required for P0. No `userConfig`, no `hooks`, no `mcpServers`.
- **settings.json placement**: At repo root (not inside `.claude-plugin/`). Distinct from `.claude/settings.json` which is the agent's permissions file.

### Deferred to Implementation

- **`/buddy` vs built-in resolution order**: Must be tested empirically. If built-in wins, README documents `/buddy:buddy` as the invocation path. This is the first verification task.
- **Whether `commands/buddy.md` is actually needed**: Issue #41842 may be resolved. Test both paths during verification.

## Output Structure

```
.claude-plugin/
  plugin.json                # manifest: name=buddy, version 0.1.0  [Unit 1]
skills/
  buddy/
    SKILL.md                 # skill definition                     [Unit 1]
commands/                    # only if needed — see Unit 3 verification
  buddy.md                   # slash command workaround for #41842  [Unit 3, conditional]
settings.json                # stub: {}  statusLine deferred to P2  [Unit 2]
README.md                    # install + invocation docs            [Unit 2]
```

## Implementation Units

- [ ] **Unit 1: Plugin manifest and skill definition**

  **Goal:** Create the core plugin files — manifest and skill — so Claude Code recognizes this as a plugin with a `/buddy` skill.

  **Requirements:** R9 (slash commands), P0 exit criteria

  **Dependencies:** None

  **Files:**
  - Create: `.claude-plugin/plugin.json`
  - Create: `skills/buddy/SKILL.md`

  **Approach:**
  - `plugin.json`: minimal manifest with `name: "buddy"`, `version: "0.1.0"`, `description` field summarizing the plugin
  - `SKILL.md`: frontmatter with `description` field. Body instructs Claude to greet the user and mention their buddy plugin is installed. Keep it to a few lines.

  **Patterns to follow:**
  - Plugin manifest schema from [plugins-reference](https://code.claude.com/docs/en/plugins-reference)
  - SKILL.md frontmatter from [skills docs](https://code.claude.com/docs/en/skills)

  **Test expectation:** none — pure scaffolding. Verified manually in Unit 3.

  **Verification:**
  - `plugin.json` is valid JSON with required fields
  - `SKILL.md` has valid YAML frontmatter

- [ ] **Unit 2: Settings stub and README**

  **Goal:** Create the settings.json stub (statusLine deferred) and a README with install and invocation instructions.

  **Requirements:** P0 exit criteria (install instructions)

  **Dependencies:** Unit 1 (need to know the file structure to document it)

  **Files:**
  - Create: `settings.json`
  - Create: `README.md`

  **Approach:**
  - `settings.json`: empty object `{}` (JSON has no comment syntax). README notes that statusLine config arrives in P2.
  - `README.md`: document both install methods (`claude plugin install .` and `claude --plugin-dir .`), the `/buddy` vs `/buddy:buddy` invocation paths (filled in after Unit 3 verification), and the decision to use bash as the implementation language.

  **Patterns to follow:**
  - Installation methods from [plugins-reference](https://code.claude.com/docs/en/plugins-reference)

  **Test expectation:** none — documentation. Verified manually in Unit 3.

  **Verification:**
  - `settings.json` is valid JSON
  - README covers install + invocation + known `/buddy` resolution behavior

- [ ] **Unit 3: Manual verification and documentation update**

  **Goal:** Verify the plugin installs, the slash command works, and document the `/buddy` resolution behavior.

  **Requirements:** R9, P0 exit criteria (all three)

  **Dependencies:** Units 1 and 2

  **Files:**
  - Modify: `README.md` (update with empirical findings)
  - Create (conditional): `commands/buddy.md` (only if `skills/buddy/SKILL.md` doesn't register as a slash command — workaround for Issue #41842)

  **Approach:**
  - Install plugin with `claude --plugin-dir .` in a fresh session
  - Test whether `skills/buddy/SKILL.md` alone registers as a user-invocable slash command
  - If it doesn't register, create `commands/buddy.md` with the same content and re-test
  - Test `/buddy` — does it resolve to the plugin or the built-in?
  - Test `/buddy:buddy` — confirm the fully-qualified form works
  - Update README with findings: which invocation path users should use, any caveats

  **Test scenarios:**
  - Happy path: `claude --plugin-dir .` succeeds without error, `/buddy:buddy` prints a greeting
  - Happy path: `claude plugin install .` succeeds without error
  - Edge case: `/buddy` invocation — does it hit the built-in or the plugin? Document whichever behavior is observed
  - Edge case: `/reload-plugins` after install — skill appears in the reload summary

  **Verification:**
  - Plugin installs without error via both methods
  - A slash command (either `/buddy` or `/buddy:buddy`) prints a greeting
  - README accurately documents the observed resolution behavior

## System-Wide Impact

- **Interaction graph:** Minimal — P0 only creates inert files. No hooks, no state writes, no status line script.
- **Error propagation:** None — the greeting has no failure modes beyond the plugin not loading.
- **Unchanged invariants:** Anthropic's built-in `/buddy` continues to work regardless of this plugin's presence.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `/buddy` collides with built-in and the plugin command is unreachable via short name | Fall back to `/buddy:buddy`; document in README. This is expected behavior. |
| Issue #41842 — skills don't register as slash commands | Verification-first: test `skills/` alone in Unit 3; add `commands/buddy.md` only if needed. |
| Plugin manifest schema has changed since docs were written | Verify against current Claude Code version during manual testing; adjust fields if needed. |

## Sources & References

- **Origin document:** [docs/brainstorms/2026-04-16-claude-buddy-plugin-requirements.md](../brainstorms/2026-04-16-claude-buddy-plugin-requirements.md)
- **Full plan:** [docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md](2026-04-16-001-feat-claude-buddy-plugin-plan.md) — P0 section (lines 208–219), architecture diagram (lines 56–89)
- **Ticket:** [docs/roadmap/P0-scaffolding.md](../roadmap/P0-scaffolding.md)
- Plugin reference: https://code.claude.com/docs/en/plugins-reference
- Skills docs: https://code.claude.com/docs/en/skills
- Issue #41842: https://github.com/anthropics/claude-code/issues/41842
