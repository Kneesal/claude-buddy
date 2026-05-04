---
title: UserPromptSubmit hook short-circuit — decision:block + reason
date: 2026-04-30
category: developer-experience
module: claude-code-plugin-system
problem_type: developer_experience
component: tooling
severity: high
applies_when:
  - Building a Claude Code plugin that needs a slash command to run a bash script directly without model relay
  - Replacing a SKILL.md → model → Bash dispatch chain that proves unreliable across sessions
  - Designing any UserPromptSubmit hook that should produce user-visible output
related_components:
  - hooks
  - userpromptsubmit
  - slash-commands
tags:
  - claude-code
  - plugin-system
  - userpromptsubmit
  - hook-output-schema
  - decision-block
  - additionalcontext
  - slash-dispatch
---

# UserPromptSubmit hook short-circuit — `decision: block` + `reason`

## Context

The buddy plugin's five `/buddy:*` slash commands ship with SKILL.md
dispatchers that tell the model to run a bash script and print its
stdout verbatim. Live testing of v0.0.9/v0.0.10 showed the chain
`SKILL.md → model → Bash tool` is unreliable: end-user sessions
(varying model tier, permission config, prompt-cache pressure) often
make the model describe the script in prose and skip the tool call.
We wanted a deterministic, model-free dispatch path.

The candidate fix was a `UserPromptSubmit` hook that intercepts
`/buddy:<cmd>`, runs the script directly, and emits the output as
the assistant turn. The plan (`docs/plans/2026-04-29-001-feat-p4-6-hook-dispatch-plan.md`)
gated all subsequent work on a spike that pinned down exactly
which hook output shape achieves this.

## Guidance

### A. Confirmed schema for short-circuit + visible output

```json
{
  "decision": "block",
  "reason": "<full script stdout, including ANSI/emoji/box-drawing>"
}
```

- `decision: "block"` prevents the prompt from reaching the model
  (verified: `duration_api_ms: 0`, `num_turns: 2` — only the hook
  turn). The SKILL.md path also does NOT run.
- `reason` is rendered to the user in the chat UI as the visible
  consequence of the block. Multi-line, ANSI escape codes,
  unicode, and box-drawing characters all survive end-to-end —
  verified by inspecting the `hook_response` event in
  `--output-format=stream-json`:

  ```text
  [35m=== Multi-line ANSI test ===[0m
  Line 2 has [32mgreen[0m text
  Line 3 has emoji 🦎 and bars ▓▓░░░
  ```

### B. Payload shape on stdin

`UserPromptSubmit` payload (verified by capturing stdin to a
file):

```json
{
  "session_id": "<uuid>",
  "transcript_path": "/home/.../<session_id>.jsonl",
  "cwd": "/<user-cwd>",
  "permission_mode": "bypassPermissions",
  "hook_event_name": "UserPromptSubmit",
  "prompt": "<the user's typed text, full line>"
}
```

The user-typed text is in `.prompt` — not `.user_prompt`,
`.text`, or `.content`. Extract with
`jq -r '.prompt // empty'`.

### C. Hook fires for registered slash commands; not for unknown ones

When a plugin registers a SKILL.md (e.g. `skills/spike/test-cmd/SKILL.md`),
typing `/spike:test-cmd <args>` causes the `UserPromptSubmit` hook
to fire with the full prompt (including the slash and args) in
`.prompt`. The SKILL.md still runs unless the hook returns
`decision: block`.

Typing an **unregistered** slash command (e.g. `/spike-block test`
when no `spike-block` skill exists) causes Claude Code to reject
the input with `Unknown command:` BEFORE firing
`UserPromptSubmit`. Implication for buddy: the hook regex must
match the same command names that already have SKILL.md entries —
which is the natural design.

### D. What the other shapes do (and don't do)

Tested but not the right answer:

- **Plain stdout (no JSON)** — *Documented* as appearing as hook
  output in the transcript, but in practice the SKILL.md still
  ran and the model still responded. The text became additional
  context, not a replacement turn. Verified by setting the
  SKILL.md body to "output literal token SKILL_X_RAN" — the
  print-mode `result` was `SKILL_` (truncated), proving the
  model ran.
- **`hookSpecificOutput.additionalContext`** — Same outcome as
  plain stdout. Adds context for the model alongside the prompt;
  does NOT replace the assistant turn.
- **`{"continue": false, "stopReason": "..."}`** — The hook
  doesn't error, but no visible output reached the user in any
  observable channel.

`decision: block` is the only field combination that fully
short-circuits the model AND surfaces hook-produced text to the
user.

### E. Print mode (`claude -p`) caveat

In print mode, the `result` field of the final `success` event is
**empty** when the prompt was blocked — print mode reports the
model's response, and the model didn't run. The `reason` text is
in the `hook_response` event's `output` field, not in `result`.

```bash
claude --plugin-dir /tmp/spike --include-hook-events \
       --output-format=stream-json --verbose -p "/buddy:hatch" \
  | jq -r 'select(.hook_name=="UserPromptSubmit") | .output'
```

This matters for **automated smokes**: assertions about hook
output must read the `hook_response` event, not `result`. End
users running interactive Claude Code see the reason rendered
normally.

### F. Implementation pattern (canonical hook glue)

```bash
#!/usr/bin/env bash
set -u

payload="$(cat)"
prompt=$(printf '%s' "$payload" | jq -r '.prompt // empty' 2>/dev/null || true)

# Cheap pre-filter — exit silent for prompts not addressed to us.
[[ "$prompt" == /buddy:* ]] || exit 0

# Run the dispatcher; capture combined stdout+stderr.
output=$("${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" "$prompt" 2>&1) || true

# Empty output (e.g. dispatcher silently rejected) → fall through to model.
[[ -z "$output" ]] && exit 0

# Encode output as the reason field; emit short-circuit JSON.
printf '%s' "$output" | jq -Rs '{decision: "block", reason: .}'
exit 0
```

`jq -Rs '.'` is required to safely encode arbitrary text
(including ANSI escapes, double quotes, backslashes, newlines)
as a JSON string.

## Why This Matters

The cost of relying on SKILL.md → model → Bash:

- The model sometimes describes the script instead of running it.
- Even with bold-imperative phrasing and `disable-model-invocation: true`,
  failures still surface in real end-user sessions.
- No amount of prose framing makes it deterministic.

The cost of `decision: block + reason`:

- Zero API tokens spent (model never runs).
- Output appears verbatim, with full formatting preserved.
- Latency is bounded by the hook script + the dispatcher script
  (no model round-trip).
- Determinism: same prompt → same output, every time, for every
  user, regardless of their session config.

## When to Apply

Apply when:

- A plugin slash command should run a deterministic script and
  display its output without any model interpretation.
- The current SKILL.md → model → Bash chain is unreliable.
- The output is bounded and self-rendering (text/ANSI/emoji ok in
  the chat UI).

Skip when:

- The command needs the model to interpret arguments or compose
  a response — that's exactly what SKILL.md + Bash tool is for.
- The output is structured data the model is expected to parse
  before responding (different contract).
- The hook would need to mutate session state in a way the model
  also needs to see (use `additionalContext` instead).

## Examples

### Spike repro

A minimal scratch plugin to reproduce the findings:

```bash
mkdir -p /tmp/spike/{hooks,skills/spike/block,.claude-plugin}

cat > /tmp/spike/.claude-plugin/plugin.json <<'EOF'
{ "name": "spike", "version": "0.0.1", "description": "spike" }
EOF

cat > /tmp/spike/hooks/hooks.json <<'EOF'
{ "hooks": { "UserPromptSubmit": [ { "hooks": [
  { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/user-prompt-submit.sh", "timeout": 5 }
] } ] } }
EOF

cat > /tmp/spike/skills/spike/block/SKILL.md <<'EOF'
---
description: Spike command — should be short-circuited by the hook
disable-model-invocation: true
---
# /spike:block
If you see this body, the hook didn't short-circuit.
EOF

cat > /tmp/spike/hooks/user-prompt-submit.sh <<'EOF'
#!/usr/bin/env bash
set -u
prompt=$(jq -r '.prompt // empty' <<<"$(cat)")
[[ "$prompt" == /spike:block* ]] || exit 0
printf 'HELLO from hook — %s' "$(date)" | jq -Rs '{decision:"block", reason:.}'
EOF
chmod +x /tmp/spike/hooks/user-prompt-submit.sh

claude --plugin-dir /tmp/spike --include-hook-events \
       --output-format=stream-json --verbose -p "/spike:block" \
  | jq -r 'select(.hook_name=="UserPromptSubmit") | .output' \
  | jq -r '.reason'
```

Expected output: `HELLO from hook — <timestamp>`. The SKILL.md
body never appears.

## See Also

- `docs/solutions/developer-experience/skill-md-framing-as-execution-priming-2026-04-29.md`
  — the failure mode this hook routes around.
- `docs/solutions/developer-experience/claude-code-plugin-hooks-json-schema-2026-04-20.md`
  — the nested-array schema and live-session smoke recipe used here.
- `docs/plans/2026-04-29-001-feat-p4-6-hook-dispatch-plan.md` —
  the plan whose Unit 1 spike produced this learning.
- Claude Code hooks reference: https://code.claude.com/docs/en/hooks
