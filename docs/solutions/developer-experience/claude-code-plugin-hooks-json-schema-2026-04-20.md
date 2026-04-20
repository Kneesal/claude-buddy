---
title: Claude Code plugin hooks.json — nested schema + live-session smoke
date: 2026-04-20
category: developer-experience
module: claude-code-plugin-system
problem_type: developer_experience
component: tooling
severity: high
applies_when:
  - Authoring or editing hooks/hooks.json in a Claude Code plugin
  - Reviewing a PR that wires new hook events
  - Debugging "my hook doesn't fire" on a plugin with a green unit-test suite
  - Copying hook config from ticket examples, planning docs, or internal snippets
  - Upgrading a plugin across Claude Code versions
related_components:
  - hooks
  - plugin-manifest
  - testing_framework
tags:
  - claude-code
  - plugin-system
  - hooks-json
  - schema
  - headless
  - live-session-smoke
  - bats-blind-spot
  - payload-fields
---

# Claude Code plugin hooks.json — nested schema + live-session smoke

## Context

Claude Code's plugin hook system is wired through `hooks/hooks.json`. The schema requires a two-level nesting under each event name: an outer array of matcher-groups, each containing an inner `hooks:` array of command entries. In abbreviated form this looks redundant, so ticket examples, planning docs, and even some pieces of the Claude Code documentation flatten it to a single `hooks: { EventName: [ {type, command} ] }` shape. That flattened shape is syntactically valid JSON and reads naturally, but Claude Code rejects it at plugin load time.

The rejection is quiet. It surfaces only in `--debug-to-stderr` output as:

```
[ERROR] Failed to load hooks for <plugin>: [["hooks","hooks"],...]
Plugin loading errors: Hook load failed
```

Normal session output shows nothing. Commands still register, skills still run, the status line still renders. The only symptom is that hooks never fire — which is indistinguishable from a plugin that simply has no hooks wired.

**The test-suite blind spot amplifies the trap.** The standard pattern for hook-script testing is bats tests that pipe a synthetic payload into the script on stdin and assert on stdout/exit code. This exercises the script but bypasses `hooks.json` entirely. A plugin with 243 green bats tests can ship with every hook dark. There is no unit-testable surface for the hooks.json schema — it is only validated by Claude Code at plugin load time, against a live session.

Empirical discovery: during P3-1 of the buddy plugin (session `2026-04-20`), `hooks/hooks.json` was written from the ticket's own example (flat form) and committed. All 243 bats tests passed. The ticket was flipped to `done`. Only when a headless `claude -p --plugin-dir ...` smoke was run did the loader's rejection surface. No prior signal. The ticket example was itself wrong — the design doc had never been validated against a live Claude Code binary. (Context: session history)

## Guidance

### A. Correct schema

Every event entry is an array of objects. Each object has an **optional** `matcher` (string or regex, for tool-scoped events) and a **required** `hooks` array. Each entry in the inner `hooks` array is `{ type, command, timeout? }`.

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh",
            "timeout": 2
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/post-tool-use-bash.sh",
            "timeout": 2
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/post-tool-use.sh",
            "timeout": 2
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/stop.sh",
            "timeout": 2
          }
        ]
      }
    ],
    "PostToolUseFailure": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/post-tool-use-failure.sh",
            "timeout": 2
          }
        ]
      }
    ]
  }
}
```

Matchers are per-group. Omit the `matcher` key for "fire for everything." For tool events (`PreToolUse`, `PostToolUse`, `PostToolUseFailure`) the matcher is checked against `tool_name`.

### B. Live-session smoke recipe

The only way to confirm `hooks.json` loads is to run Claude Code against the plugin and check debug output. bats cannot catch this.

```bash
# 1. Scratch workspace (avoids touching real project state)
SCRATCH=$(mktemp -d)

# 2. Add a payload capture to each hook script, right after hook_drain_stdin
#    (one line per hook, unique filename per hook):
#
#    printf '%s' "$payload" > "/tmp/smoke-session-start-$$.json"

# 3. Run a prompt that exercises at least one tool
cd "$SCRATCH" && \
  claude --plugin-dir /path/to/plugin --debug-to-stderr \
    -p "run 'echo hello' with the Bash tool" 2>&1 \
  | grep -iE "plugin|hook"

# 4. Check for the load error. Absence of this line means hooks.json loaded:
#    [ERROR] Failed to load hooks for <plugin>: [...]

# 5. Inspect captured payloads
ls /tmp/smoke-*.json
cat /tmp/smoke-post-tool-use-*.json | jq .

# 6. Remove the capture lines from hook scripts before committing
```

The critical signal is the `Failed to load hooks` line in stderr. A silent run with no captured payload files means either the hooks didn't match or the schema is wrong — check stderr to disambiguate.

### C. Adjacent payload-shape findings

Worth knowing while you're in this area so these don't become their own smokes later:

- **Top-level payload fields** use `session_id` (UUID) and `tool_use_id`. Some planning docs show `tool_call_id` — that name is **wrong**; Claude Code never sends it.
- **Full PostToolUse payload** includes `session_id`, `tool_use_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`, `tool_name`, `tool_input`, `tool_response`.
- **SessionStart** carries `source: "startup"` (vs `"resume"`). Useful when commentary needs to distinguish fresh-start from resume.
- **`claude -p` always sets `permission_mode: "bypassPermissions"`** regardless of `--allowedTools`. Headless smokes cannot test permission-mode-sensitive logic faithfully.

## Why This Matters

Severity is high and detection cost is high.

- A plugin with a broken `hooks.json` looks identical to a plugin that intentionally ships no hooks. There is no runtime warning in the normal session UI.
- The test surface most plugins build (bats + stdin-piped payloads) cannot catch the bug — the schema is only validated by the Claude Code loader, against the file on disk.
- The error message when you do catch it (`[["hooks","hooks"],...]`) is cryptic — it's a path into the validator's expected shape, not a human-readable diagnostic. If you haven't seen it before it reads like noise.
- The flat shape is the shape most people will write from memory, because abbreviated examples in planning docs show it and it is the shape that matches most other config-file conventions.

Net: a plugin can pass CI, install cleanly, register all its commands, and have every single hook dark in production. In the buddy plugin's case, the user-visible symptom would have been "the Tamagotchi never reacts to anything" — hard to distinguish from "the evolution loop isn't implemented yet."

## When to Apply

Reach for this guidance when:

- Writing or editing `hooks/hooks.json` for any plugin.
- Reviewing a PR that adds hook wiring — the schema error is not catchable by review of isolated hook scripts; you have to look at the JSON itself.
- Debugging "my hook doesn't fire" with a green test suite. First check is `--debug-to-stderr` for the load error.
- Copying hook config from ticket examples, planning docs, or older internal docs — assume the shape shown is flat and needs unnesting.
- Upgrading Claude Code versions — the loader's strictness has changed before and may change again; re-run the smoke after upgrades.

## Examples

### Before (rejected)

```json
{
  "hooks": {
    "SessionStart": [
      { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh", "timeout": 2 }
    ],
    "PostToolUse": [
      { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/post-tool-use.sh", "timeout": 2 }
    ]
  }
}
```

Load error in `--debug-to-stderr`:

```
[ERROR] Failed to load hooks for buddy: [["hooks","hooks"],...]
Plugin loading errors: Hook load failed
```

### After (accepted)

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh", "timeout": 2 }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/post-tool-use.sh", "timeout": 2 }
        ]
      }
    ]
  }
}
```

### Reproducing the smoke in 30 seconds

```bash
SCRATCH=$(mktemp -d)
# In one hook script, after hook_drain_stdin:
#   printf '%s' "$payload" > /tmp/smoke-$(basename "$0" .sh)-$$.json
cd "$SCRATCH"
claude --plugin-dir "$OLDPWD" --debug-to-stderr \
  -p "use Bash to run: echo ok" 2>&1 | grep -iE "hook|plugin"
ls /tmp/smoke-*.json 2>/dev/null && echo "hooks fired" || echo "hooks dark"
```

If the grep shows `Failed to load hooks`, the schema is wrong. If it shows nothing and `/tmp/smoke-*.json` is empty, check matchers and event names. If files exist, hooks are wired correctly — inspect payload shape with `jq`.

## Related

- [claude-code-plugin-scaffolding-gotchas-2026-04-16.md](./claude-code-plugin-scaffolding-gotchas-2026-04-16.md) — sibling "non-obvious plugin platform behaviors" doc (skill namespacing, settings.json key surface, mid-session directory watching, disable-model-invocation scope). This finding is a fifth peer behavior; the trap patterns overlap ("looks right, silently wrong").
- [claude-code-skill-dispatcher-pattern-2026-04-19.md](./claude-code-skill-dispatcher-pattern-2026-04-19.md) — the "SKILL.md dispatches to a backing script" pattern. Hook scripts follow the same discipline: thin entry points that delegate to tested bash helpers.
- P3-1 ticket: [docs/roadmap/P3-1-hook-wiring.md](../../roadmap/P3-1-hook-wiring.md) — original ticket with the flat-schema example that triggered the bug. Notes section documents the correction.
- P3-1 plan: [docs/plans/2026-04-20-002-feat-p3-1-hook-wiring-plan.md](../../plans/2026-04-20-002-feat-p3-1-hook-wiring-plan.md) — the implementation plan that accepted the ticket's schema as authoritative without live-validation (the lesson: no design-doc schema is authoritative until it has loaded in a real Claude Code session).
- Claude Code hooks reference: https://code.claude.com/docs/en/hooks
