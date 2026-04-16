# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Claude Code plugin named **buddy** — a gacha-hatched, Tamagotchi-style evolving coding companion. The plugin extends Anthropic's built-in `/buddy` with random hatching, behavior-driven evolution, and an earned reroll token economy.

## Plugin Architecture

This is a Claude Code plugin, not a standalone application. It uses plugin primitives (skills, hooks, status line scripts) — no build system, no package manager, no test framework yet.

- `.claude-plugin/plugin.json` — plugin manifest (`name: buddy`, provides the `/buddy:*` namespace)
- `skills/<name>/SKILL.md` — each skill becomes a slash command at `/buddy:<name>`
- `hooks/` — event-driven scripts (P3+), wired via `hooks/hooks.json`
- `statusline/` — ambient status line rendering (P2+)
- `scripts/lib/` — shared bash libraries for state, rng, commentary, evolution (P1+)
- `scripts/species/*.json` — per-species data: voice, stats, evolution paths, line banks
- `settings.json` — plugin settings (only `agent` and `subagentStatusLine` keys are supported — NOT `statusLine`)
- `${CLAUDE_PLUGIN_DATA}/buddy.json` — persistent buddy state (created at runtime, not in repo)

Implementation language is **bash** for all hook/statusline scripts. Species data and schemas use JSON.

## Current State

P0 (scaffolding) is complete. The plugin installs and three slash commands respond: `/buddy:hatch`, `/buddy:interact`, `/buddy:stats`. No state, hooks, or status line yet. See `docs/roadmap/README.md` for phase status.

## Plugin Development Workflow

Test changes by restarting Claude Code with the plugin loaded:

```
claude --plugin-dir .
```

`/reload-plugins` works for changes to existing files but **does not detect new skill directories** created mid-session — a full restart is required. See `docs/solutions/developer-experience/` for detailed gotchas.

## Key Constraints

- Plugin skills are always namespaced as `/buddy:<skill-name>`. There is no way to expose a bare `/buddy` from a plugin.
- All state writes must go through atomic tmp+rename with `flock` advisory locks (design decision from P1 onward).
- Hook scripts must exit 0 on internal failure — a plugin bug must never break the Claude Code session.
- Hook scripts target p95 < 100ms latency.

## Roadmap and Ticket Conventions

Roadmap lives in `docs/roadmap/`. Each ticket has YAML frontmatter (`id`, `phase`, `status`, `depends_on`).

- Update `status` to `in-progress` when starting, `done` when finishing.
- Add implementation notes to the ticket's **Notes** section as you work.
- Meaningful sub-decisions or learnings go to `docs/solutions/` via `/ce:compound`.

## Documented Solutions

`docs/solutions/` — documented solutions to past problems and platform gotchas, organized by category with YAML frontmatter (`module`, `tags`, `problem_type`). Search here before implementing features or debugging issues in documented areas.

## Planning Documents

- `docs/brainstorms/` — requirements documents (source of truth for scope and intent)
- `docs/plans/` — implementation plans with checkboxed implementation units
- The brainstorm → plan → roadmap ticket pipeline drives all feature work
