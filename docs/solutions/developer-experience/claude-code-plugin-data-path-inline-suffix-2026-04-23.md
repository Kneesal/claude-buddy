---
title: Claude Code plugin-data path — the -inline suffix for --plugin-dir loads
date: 2026-04-23
category: developer-experience
module: claude-code-plugin-system
problem_type: developer_experience
component: tooling
severity: medium
applies_when:
  - Running a live-session smoke against a plugin loaded via `claude --plugin-dir /path`
  - A plugin that writes to `${CLAUDE_PLUGIN_DATA}` and you need to inspect or back up that state
  - A hook fires successfully but the expected state mutation is not where you expected to find it
  - Documenting where a plugin stores data (for README, troubleshooting, backup tooling)
related_components:
  - plugin-manifest
  - hooks
  - smoke-testing
tags:
  - claude-code
  - plugin-system
  - plugin-data
  - --plugin-dir
  - inline-suffix
  - live-session-smoke
  - headless
---

# Claude Code plugin-data path — the -inline suffix for `--plugin-dir` loads

## Context

Every Claude Code plugin that stores state reads `${CLAUDE_PLUGIN_DATA}`
from its environment — an absolute path Claude Code scopes per plugin.
For the buddy plugin this is where `buddy.json`, `session-<id>.json`,
and the various `.lock` siblings live.

During the P4-1 live smoke we hatched a buddy at `~/.claude/plugin-data/buddy/`
and ran `claude --plugin-dir /workspace --debug-to-stderr -p "..."`.
All four hooks fired (payloads captured). But the hatched `buddy.json`
never advanced. Tests passed, live smoke passed the format checks,
yet the state we expected to see mutated did not change.

The investigation: we added an env-dumping line to one hook and re-ran.
The captured env showed

```
CLAUDE_PLUGIN_DATA=/home/vscode/.claude/plugins/data/buddy-inline
```

— **not** `/home/vscode/.claude/plugin-data/buddy/` where we had
hatched. Every assumption about "plugin-data lives under
`.claude/plugin-data/<name>/`" — held because other plugins, documented
examples, and our mental model all pointed there — was wrong for this
load mode.

The correct path has two surprises:

1. The parent directory is `~/.claude/plugins/data/` (plural
   `plugins/`, then `data/`), not `~/.claude/plugin-data/`
   (singular).
2. The plugin's own directory carries an `-inline` suffix when
   loaded via `--plugin-dir`. The suffix is not applied to
   marketplace-installed plugins.

Neither point is mentioned in the existing
[hooks.json schema solutions doc](./claude-code-plugin-hooks-json-schema-2026-04-20.md)
or in any internal Claude Code documentation we could find. The
`-inline` suffix tripped the first P4-1 smoke pass and was only
caught by dumping `CLAUDE_PLUGIN_DATA` from inside a hook
subprocess.

## Guidance

### A. Path resolution by load mode

| Load mode | `${CLAUDE_PLUGIN_DATA}` resolves to |
|-----------|--------------------------------------|
| `claude --plugin-dir /path/to/plugin` | `~/.claude/plugins/data/<plugin-name>-inline/` |
| Marketplace install | `~/.claude/plugins/data/<marketplace-id>/` (verify per-install; no `-inline` suffix) |
| Explicit `CLAUDE_PLUGIN_DATA=/custom/path` in env | `/custom/path` verbatim |

For `--plugin-dir` loads specifically, the `<plugin-name>` portion
is the value of `name` in `.claude-plugin/plugin.json` — in our case
`"name": "buddy"` yields the dir `buddy-inline`.

This is the sibling peer to the existing plugin-system gotchas family
(hooks.json schema, scaffolding, userConfig, transcript-as-trust-
boundary) — same "looks right, silently wrong" failure pattern.

### B. How to find the real path empirically

Do not trust guesses or design-doc paths. Capture the env from inside
a hook subprocess during a live smoke:

```bash
# In the hook, right after `payload="$(hook_drain_stdin)"` (temporary; remove before commit):
echo "TRACE CLAUDE_PLUGIN_DATA=[${CLAUDE_PLUGIN_DATA:-UNSET}]" >> /tmp/trace.log
env | grep -i claude >> /tmp/trace.log

# Run a real claude session with the plugin and a cheap tool use:
SCRATCH=$(mktemp -d)
cd "$SCRATCH"
claude --plugin-dir /path/to/plugin --debug-to-stderr \
  -p "use the Bash tool to run: echo hi" 2>/dev/null

# Read the captured path:
cat /tmp/trace.log
```

This is the same recipe as the hooks-schema live-smoke, just
looking at a different field of the captured env.

### C. Backup and inspection tooling should resolve the path at runtime

If you ship tooling that reads or backs up plugin state (e.g., a
`/buddy:reset` dry-run), use `${CLAUDE_PLUGIN_DATA:-}` inside the
tool — do **not** hard-code a parent directory. The env var is the
only cross-load-mode-portable source of truth. Hard-coding
`~/.claude/plugin-data/<name>/` works for nothing and hard-coding
`~/.claude/plugins/data/<name>-inline/` works only for one specific
load mode.

### D. Note for README and user-facing docs

When documenting "where buddy stores state" for end users, write it
as `${CLAUDE_PLUGIN_DATA}` (with the variable, not a concrete
example path). If a concrete example helps, include both forms and
show how to resolve at runtime:

```bash
# Print the actual plugin-data directory your plugin is using:
claude --plugin-dir /path/to/plugin --debug-to-stderr -p 'show the plugin env' 2>&1 \
  | grep CLAUDE_PLUGIN_DATA
```

## Why This Matters

The symptom when you guess wrong is identical to "my plugin's hooks
don't do anything." You hatch at Path A, run a session, look at Path A,
see no change, assume broken. Meanwhile Path B has correctly-updated
state that you never find.

Debugging time is the primary cost: a smoke that looks like it failed
can take 30+ minutes to diagnose before you suspect the path. The
discovery itself takes ~2 minutes (add env dump, re-run, read).

Secondarily: any future tooling that backs up, migrates, or inspects
plugin state must resolve the path at runtime or it will silently
operate on the wrong directory. That is an entire class of future bug.

## When to Apply

- Writing or reviewing a live-session smoke recipe.
- Writing README/user docs that reference the plugin-data directory.
- Writing backup/migration/inspection tooling for plugin state.
- Debugging "hooks fire but state does not mutate" when the state file
  you expected to mutate lives at a different path.
- Proposing a CI integration that reads or verifies plugin state —
  the CI must resolve the path, not hard-code it.

## Examples

### Before — guessed path, smoke appears to fail silently

```bash
# Wrong: guessed path, then hatched there
mkdir -p ~/.claude/plugin-data/buddy
CLAUDE_PLUGIN_DATA=~/.claude/plugin-data/buddy bash scripts/hatch.sh

# Run claude smoke
claude --plugin-dir /workspace --debug-to-stderr -p "use Bash: echo hi"

# Inspect — no change
jq '.buddy.xp' ~/.claude/plugin-data/buddy/buddy.json   # still 0
#              ^--- looking at the wrong directory
```

### After — resolved via the actual env var

```bash
# Run claude smoke; capture the env from inside a hook
# (see Section B recipe)
cat /tmp/trace.log
# TRACE CLAUDE_PLUGIN_DATA=[/home/vscode/.claude/plugins/data/buddy-inline]

# Hatch at the real path and re-run
mkdir -p ~/.claude/plugins/data/buddy-inline
CLAUDE_PLUGIN_DATA=~/.claude/plugins/data/buddy-inline bash scripts/hatch.sh

claude --plugin-dir /workspace --debug-to-stderr -p "use Bash: echo hi"
jq '.buddy.xp' ~/.claude/plugins/data/buddy-inline/buddy.json
# 35 — state advanced correctly
```

## Related

- [claude-code-plugin-hooks-json-schema-2026-04-20](./claude-code-plugin-hooks-json-schema-2026-04-20.md)
  — peer doc in the "platform-load-time behaviors not matching
  design-doc assumptions" family. Section B (live-session smoke
  recipe) is the exact mechanism that surfaces this path.
- [claude-code-plugin-scaffolding-gotchas-2026-04-16](./claude-code-plugin-scaffolding-gotchas-2026-04-16.md)
  — sibling doc on non-obvious plugin platform behaviors.
- [claude-code-plugin-userconfig-manifest-schema-2026-04-21](./claude-code-plugin-userconfig-manifest-schema-2026-04-21.md)
  — another "looks right, silently wrong" Claude-Code schema peer.
