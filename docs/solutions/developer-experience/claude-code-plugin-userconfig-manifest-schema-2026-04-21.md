---
title: Claude Code plugin.json userConfig — valid type set + required title field
date: 2026-04-21
category: developer-experience
module: claude-code-plugin-system
problem_type: developer_experience
component: tooling
severity: high
applies_when:
  - Adding or editing userConfig entries in a Claude Code plugin's .claude-plugin/plugin.json
  - Copying userConfig examples from planning docs, tickets, or older internal snippets
  - Debugging "my plugin doesn't load" after a manifest edit
  - Upgrading a plugin across Claude Code versions
related_components:
  - plugin-manifest
  - settings
tags:
  - claude-code
  - plugin-system
  - plugin-json
  - userConfig
  - schema
  - live-session-smoke
  - bats-blind-spot
---

# Claude Code plugin.json userConfig — valid type set + required title field

## Context

`plugin.json`'s `userConfig` block lets a plugin expose user-tunable
settings with typed defaults. P3-2 of the buddy plugin added two entries:

```json
"userConfig": {
  "commentsPerSession": { "type": "integer", "default": 8, "description": "..." },
  "stopLineOnExit":     { "type": "boolean", "default": true, "description": "..." }
}
```

That shape came directly from the ticket's example. JSON-valid. Read
naturally. Passed every bats test (plugin manifest isn't a test
surface). Rejected at plugin load time by Claude Code with a cryptic
error only visible in `--debug-to-stderr`:

```
[ERROR] Plugin workspace has an invalid manifest file at
/workspace/.claude-plugin/plugin.json. Validation errors:
userConfig.commentsPerSession.type: Invalid option: expected one of
"string"|"number"|"boolean"|"directory"|"file",
userConfig.commentsPerSession.title: Invalid input: expected string,
received undefined,
userConfig.stopLineOnExit.title: Invalid input: expected string,
received undefined
```

Two facets of the same gotcha:

1. **Valid `type` values are a closed set**: `string`, `number`,
   `boolean`, `directory`, `file`. No `integer`, no `int`, no `float`,
   no `array`, no `object`. A clamped integer uses `type: "number"`
   and documents the expected range in `description`.
2. **`title` is required** alongside `type`, `default`, and
   `description`. Omitting it fails validation even when every other
   field is well-formed.

Failure mode: the whole plugin fails to load. Hooks never register.
Skills vanish. Slash commands stop responding. The only signal is the
debug-stderr error above — there is no user-facing warning in the
normal session UI. This is the same trap shape as the hooks.json
schema issue: **looks right, silently wrong, catastrophic impact.**

## Guidance

### A. Correct shape

```json
{
  "name": "buddy",
  "version": "0.1.0",
  "description": "...",
  "userConfig": {
    "commentsPerSession": {
      "type": "number",
      "title": "Comments per session",
      "default": 8,
      "description": "Maximum number of commentary lines per session."
    },
    "stopLineOnExit": {
      "type": "boolean",
      "title": "Session-end goodbye",
      "default": true,
      "description": "Emit a one-line goodbye when a session ends."
    }
  }
}
```

Required fields per entry: `type`, `title`, `default`, `description`.

Valid `type` values: `"string"` | `"number"` | `"boolean"` |
`"directory"` | `"file"`. Integer knobs use `"number"` and document
"positive integer" (or similar) in `description`.

### B. Live-smoke recipe (same as hooks.json)

This schema, like hooks.json, is only validated by Claude Code's
plugin loader against the file on disk. Unit tests can't catch it.

```bash
SCRATCH=$(mktemp -d)
cd "$SCRATCH"
claude --plugin-dir /path/to/plugin --debug-to-stderr \
  -p "use Bash to run: echo ok" 2>&1 | grep -iE "manifest|invalid|failed to load"
```

Empty output means the manifest loaded. Any `[ERROR]` line surfaces
the exact validation issue.

### C. Detection cost in normal operation

Without the debug flag, a broken manifest is indistinguishable from
a plugin that's simply doing nothing:

- No hook fires.
- No skill registers.
- Slash commands fall back to Anthropic's built-in (or no-op).
- Status line shows whatever it showed before — if it's user-level
  registered (which it is for buddy), it still renders.

A reviewer looking at the session would reasonably conclude "the
plugin doesn't do anything yet." The plugin-load error lives a flag
away.

## Why This Matters

Severity high, detection cost high — same profile as the hooks.json
schema. A plugin passes CI, installs cleanly, and silently breaks in
production after a seemingly-innocuous userConfig edit.

The `integer` vs `number` trap is especially bait-y: integer is the
natural type for a count, it's valid in almost every adjacent schema
system (JSON Schema, OpenAPI, TypeScript), and the error message
lists the valid alternatives only after you opt into debug output.
The `title` requirement compounds the problem — even if you fix the
type, the manifest stays broken until you realize a second field is
also missing.

## When to Apply

- Adding any userConfig entry to `plugin.json`.
- Reviewing a PR that touches `plugin.json` — schema errors are not
  catchable by review of other files; read the manifest directly.
- Debugging "my plugin silently does nothing" after a manifest edit.
  First check: `--debug-to-stderr | grep -iE "manifest|invalid"`.
- Copying userConfig examples from planning docs, tickets, or
  external snippets — assume the types and fields shown are not
  authoritative until live-validated.
- Upgrading Claude Code — the validator's strictness has changed
  before and may change again (P3-1 learned the same about
  hooks.json).

## Examples

### Before (rejected)

```json
"userConfig": {
  "commentsPerSession": {
    "type": "integer",
    "default": 8,
    "description": "Max comments per session"
  }
}
```

### After (accepted)

```json
"userConfig": {
  "commentsPerSession": {
    "type": "number",
    "title": "Comments per session",
    "default": 8,
    "description": "Maximum comments per session (positive integer)."
  }
}
```

## Related

- [claude-code-plugin-hooks-json-schema-2026-04-20.md](./claude-code-plugin-hooks-json-schema-2026-04-20.md)
  — sibling schema learning for `hooks.json`. Same "design-doc schema
  is not authoritative" pattern; the live-smoke recipe is identical.
- [claude-code-plugin-scaffolding-gotchas-2026-04-16.md](./claude-code-plugin-scaffolding-gotchas-2026-04-16.md)
  — other non-obvious plugin platform behaviors. This finding is a
  fifth peer behavior; the trap patterns overlap.
- P3-2 ticket: [docs/roadmap/P3-2-commentary-engine.md](../../roadmap/P3-2-commentary-engine.md)
  — the live smoke that surfaced this is documented in the ticket's
  Notes section.
- Claude Code plugin reference: https://code.claude.com/docs/en/plugins-reference
