---
title: P4-6 — Hook-driven dispatch for /buddy:* slash commands
type: refactor
status: active
date: 2026-04-29
---

# P4-6 — Hook-driven dispatch for /buddy:* slash commands

## Overview

Replace the SKILL.md → model → Bash tool dispatch chain for the
five `/buddy:*` commands (`hatch`, `stats`, `interact`, `reset`,
`install-statusline`) with a `UserPromptSubmit` hook that pattern-
matches the prompt and runs a single `scripts/dispatch.sh` router
directly. The router calls the existing per-command scripts —
`hatch.sh`, `status.sh`, `interact.sh`, `reset.sh`,
`install_statusline.sh` — unchanged. The five SKILL.md files stay
as a degraded fallback for hook-disabled clients but get
rewritten as concise one-liner pointers.

## Problem Frame

Live testing of the v0.0.9 + v0.0.10 marketplace install
surfaced a real bug: when an end user types `/buddy:stats` (or
any of the five commands) in Claude Code, the model loads the
SKILL.md, *describes* what the script would do, and stops. The
bash never runs. The user sees prose where they should see a
buddy.

The chain that breaks is **SKILL.md → model → Bash tool**. We
already iterated on the prose three times — roleplay-removed,
IMMEDIATELY imperatives, four-bullet directive-vs-mention rules
— and dispatch is still non-deterministic across model tiers and
permission configs we don't control. The framing is documented
as load-bearing in
`docs/solutions/developer-experience/skill-md-framing-as-execution-priming-2026-04-29.md`,
but no amount of prose makes the model's tool-use reliable in
arbitrary end-user sessions.

The bash itself is fine. `scripts/dispatch.sh` invoked directly
works. The fix is to bypass the model entirely with a
`UserPromptSubmit` hook that matches `/buddy:<cmd>` lexically
and runs the right script, emitting its stdout to the chat
without round-tripping through the model.

## Requirements Trace

- **R1.** Typing `/buddy:hatch`, `/buddy:stats`, `/buddy:interact`,
  `/buddy:reset`, or `/buddy:install-statusline` (with or without
  args) in a Claude Code session with the buddy plugin installed
  runs the matching script and shows its stdout in the
  transcript — no Bash-tool permission prompt, no model relay,
  no SKILL.md framing risk.
- **R2.** All existing argument-handling rules are preserved
  deterministically inside `scripts/dispatch.sh` — no model
  judgment in the parsing:
  - `/buddy:hatch --confirm` honored only when the post-command
    arg list is **exactly** `--confirm` (single token).
  - `/buddy:reset --confirm` same shape.
  - `/buddy:install-statusline` maps to a labelled subcommand +
    flag table mirroring the current SKILL.md (install,
    install --dry-run, install --yes, uninstall,
    uninstall --dry-run, --help).
- **R3.** Anything that does not match the regex
  `^/buddy:(hatch|stats|interact|reset|install-statusline)\b`
  passes through to the model unchanged. The hook never
  short-circuits a non-buddy prompt.
- **R4.** When the hook fires it short-circuits the model: the
  user sees only the script's stdout (and stderr appended on
  non-zero exit) as the response.
- **R5.** All five SKILL.md files remain in place with
  `disable-model-invocation: true` frontmatter unchanged. Their
  bodies become concise one-liner pointers (the canonical path
  is the hook; the SKILL.md is a fallback for hook-disabled
  clients, where the existing model-relay risk is the same as
  today and explicitly accepted as the degraded mode).
- **R6.** Hook script honors the plugin's existing discipline:
  exit 0 on internal failure; never break the user's session.
  Latency p95 < 100ms on the dispatch glue itself (the
  underlying scripts have their own budgets and stay
  unchanged).
- **R7.** `dispatch.sh` is exercised by bats coverage on its
  CLI surface — correct script per command, correct flag
  forwarding, exit codes, unknown-command rejection — beyond
  the per-script tests already in place.
- **R8.** The full round-trip (slash command typed in real
  session → script output rendered) is verified by a
  live-session smoke documented in the solutions
  doc compound, because bats cannot validate `hooks.json`
  schema or hook-event semantics
  (per `docs/solutions/developer-experience/claude-code-plugin-hooks-json-schema-2026-04-20.md`).

## Scope Boundaries

- **No changes to the five underlying scripts.** `hatch.sh`,
  `status.sh`, `interact.sh`, `reset.sh`,
  `install_statusline.sh` are tested, reviewed, and stable. The
  only new dispatch surface is the new `scripts/dispatch.sh`
  router and the new `hooks/user-prompt-submit.sh` glue.
- **No changes to `scripts/lib/render.sh`, the species JSONs,
  or any sprite / cosmetics code.** Visible-buddy work is
  separate.
- **No changes to SKILL.md frontmatter.** `description` and
  `disable-model-invocation: true` stay. Only the markdown body
  is shortened.
- **No new commands, no removed commands, no behavior
  changes** in any per-command script. This refactor is purely
  the wrapper layer between "user typed text" and "script
  ran."
- **No removal of the SKILL.md fallback path.** Even though it
  carries the model-relay risk we are escaping, it remains in
  place as a degraded mode for older Claude Code versions or
  hook-disabled clients. Removing it is a future ticket only
  after enough real-world evidence shows the hook path works
  universally.
- **No bare `/buddy` alias.** Out of scope (carried over from
  P4-3 D11).
- **No model-judgment safety nets in the router.** The hook
  is purely lexical. The strict-arg rule for `--confirm`
  (R2) is the new safety mechanism, replacing the SKILL.md
  prose four-bullet "directive vs mention" rule.

### Deferred to Separate Tasks

- **Removing the SKILL.md fallback** entirely once the hook
  path is proven on enough Claude Code versions.
- **Compound-engineering learnings doc** for the dispatch
  pivot — written via `/ce:compound` after implementation
  ships, not part of this plan's units.

## Context & Research

### Relevant Code and Patterns

- `hooks/hooks.json` — current schema-correct nested-array
  shape. New `UserPromptSubmit` event added as a sibling to
  the existing four. Pattern reference: any current entry.
- `hooks/post-tool-use.sh`, `hooks/session-start.sh` — current
  hook-script discipline: `hook_drain_stdin`, exit 0 on
  internal failure, latency-conscious.
- `scripts/lib/state.sh` — source-guard idiom (`_STATE_SH_LOADED`),
  re-used by the new `dispatch.sh` if it ends up sharing
  helpers (does not strictly need to).
- `scripts/install_statusline.sh:_install_main` — the
  subcommand/flag parser that the SKILL.md install-statusline
  table mirrors. `dispatch.sh`'s install-statusline branch
  routes the prompt-line tokens into the same shape.
- `scripts/reset.sh:_reset_main` — minimal `--confirm`-only
  arg parser. `dispatch.sh` calls it with a strict `--confirm`
  passthrough rule.
- `scripts/hatch.sh:_hatch_main` — same pattern as reset.
- `scripts/status.sh`, `scripts/interact.sh` — both take no
  args. `dispatch.sh` ignores any post-command tokens for
  these two and warns nothing (the SKILL.md was already
  ignoring them).
- `tests/integration/slash.bats`,
  `tests/integration/test_install_statusline.bats`,
  `tests/integration/test_interact.bats` — pattern reference
  for the new `tests/integration/test_dispatch.bats` (the
  router's CLI surface) and `tests/integration/test_hook_dispatch.bats`
  (the hook glue's payload-shape behavior).

### Institutional Learnings

- [skill-md-framing-as-execution-priming-2026-04-29](../solutions/developer-experience/skill-md-framing-as-execution-priming-2026-04-29.md)
  — the failure mode this plan routes around. The fallback
  SKILL.md bodies will retain the imperative framing as a
  best-effort degraded path, but the hook is the canonical
  fix.
- [claude-code-slash-dispatch-stdin-eof-2026-04-29](../solutions/developer-experience/claude-code-slash-dispatch-stdin-eof-2026-04-29.md)
  — `install-statusline`'s `--yes` flag exists for this same
  class of "model-driven dispatch is unreliable." The
  `dispatch.sh` install-statusline branch must keep `--yes`
  forwarding intact; switching to a hook does NOT bring
  stdin back, so consent still has to be flag-driven.
- [claude-code-plugin-hooks-json-schema-2026-04-20](../solutions/developer-experience/claude-code-plugin-hooks-json-schema-2026-04-20.md)
  — `hooks.json` schema is two-level nested arrays. New
  event entries must follow the same shape. bats cannot
  validate the schema; live-session smoke is mandatory.
- [claude-code-skill-dispatcher-pattern-2026-04-19](../solutions/developer-experience/claude-code-skill-dispatcher-pattern-2026-04-19.md)
  — the original "thin SKILL.md → tested bash" pattern. This
  plan upgrades the dispatcher *layer* (model-driven →
  hook-driven) but preserves the "tested bash helper does the
  real work" half of the discipline.

### External References

None required. The Claude Code hooks documentation surface
(`https://code.claude.com/docs/en/hooks`) is the only external
reference, and the spike (Unit 1) verifies its concrete
behavior against a real session — the doc is reference-grade
but the exact JSON shape that fully short-circuits the model
is what the spike pins down.

## Key Technical Decisions

**D1. Single `scripts/dispatch.sh` router, not five per-command hooks.** A single regex match in `hooks.json` followed by a single bash entry point keeps the hook config small and centralizes the lexical-parsing logic. The router fans out to the five existing scripts. Per-command hooks would mean five regex matchers and five hook scripts — more surface, no benefit.

**D2. Hook glue is `hooks/user-prompt-submit.sh`, separate from `scripts/dispatch.sh`.** The hook script's job is to (a) read the `UserPromptSubmit` JSON payload from stdin, (b) extract the prompt text, (c) check the regex, (d) call `dispatch.sh`, (e) format the result as the JSON output Claude Code expects to short-circuit the model. The `dispatch.sh` script's job is purely "given a `/buddy:<cmd> <args>` string, run the right script, emit its stdout/stderr." Splitting the two responsibilities lets `dispatch.sh` be unit-testable as a normal CLI without mocking the hook payload shape, and lets the hook glue stay tiny.

**D3. `--confirm` requires strict-exact arg shape.** For `/buddy:hatch` and `/buddy:reset`, the post-command arg list must be **exactly** the single token `--confirm` (no extra tokens, no quoted variants) for `dispatch.sh` to forward `--confirm` to the underlying script. `/buddy:reset what does --confirm do` does NOT trigger a wipe — it routes to `reset.sh` with no args, which prints the consequences message. This replaces the SKILL.md prose "directive vs mention" rule with a deterministic lexical rule that is far stricter (and therefore safer) than what the model was doing. Documented in dispatch.sh inline and tested explicitly.

**D4. `install-statusline` token table is whitelisted, not pass-through.** `dispatch.sh` recognizes a fixed set of post-command shapes (no args; `--dry-run`; `--yes`; `uninstall`; `uninstall --dry-run`; `--help`) and maps each to the matching `install_statusline.sh` invocation. Anything that doesn't match the whitelist falls through to a "usage" message printed by `dispatch.sh` itself — no underlying script call. This prevents arbitrary token injection and matches the labelled-menu approach the SKILL.md already uses.

**D5. Stats and interact ignore post-command tokens.** Both scripts take no args. `dispatch.sh` strips and ignores anything after `/buddy:stats` or `/buddy:interact` (matches current SKILL.md behavior). No usage error; the user gets the same output they'd get with a bare command.

**D6. Short-circuit mechanism is the JSON `{"decision": "block", "reason": "..."}` output from the `UserPromptSubmit` hook.** This is the field the spike (Unit 1) verifies. The hook emits its JSON response on stdout; the script's actual output goes into `reason`. If the spike reveals a different field name (e.g., `hookSpecificOutput.additionalContext` injects rather than replaces, requiring a different field for full short-circuit), the plan adjusts in Unit 1's deliverable doc and Units 2-5 follow. The plan **assumes** the `decision: block` shape based on Claude Code's documented hook-control model; the spike confirms.

**D7. Hook receives the raw user prompt as a JSON field on stdin.** Per the hook payload conventions in
`docs/solutions/developer-experience/claude-code-plugin-hooks-json-schema-2026-04-20.md`,
`UserPromptSubmit` is expected to deliver a `prompt` (or similarly named) field carrying the user's typed text. The spike confirms the exact field name. The hook glue extracts that field via `jq` (already a hard dependency of the plugin) and feeds it to the regex check.

**D8. Non-matching prompts exit 0 with empty stdout.** When the regex doesn't match, the hook script exits cleanly without any JSON output. Per Claude Code hook conventions, an empty/silent UserPromptSubmit hook lets the prompt continue to the model unchanged. This is the path 99% of prompts take.

**D9. Hook script honors the existing exit-0-on-internal-failure rule.** A bug in the hook (broken `jq`, missing `dispatch.sh`, malformed payload, etc.) must not break the user's session. On internal error the hook logs to `${CLAUDE_PLUGIN_DATA}/error.log` (same convention as the existing P3 hooks) and exits 0 silently — the user's prompt then passes through to the model, which falls back to the SKILL.md path. The user sees graceful degradation; we see the failure in the log.

**D10. SKILL.md fallback bodies become one-liners.** The current bodies (imperative + bash blocks + flag-decision rules) are kept *only* in `dispatch.sh`'s `--help` output for `install-statusline`-style commands. The SKILL.md body becomes: "This command is normally handled by the buddy plugin's UserPromptSubmit hook. If you're seeing this, the hook didn't fire — run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" /buddy:<cmd> <args>` directly." For destructive commands the safety prose is preserved on top of the one-liner so the model still has guardrails in the degraded path.

**D11. No new env-var contracts.** `dispatch.sh` and the hook glue rely only on `${CLAUDE_PLUGIN_ROOT}` (existing), `${CLAUDE_PLUGIN_DATA}` (existing), and `${BUDDY_INSTALL_ASSUME_YES}` indirectly through `install_statusline.sh` (existing). No new knobs.

## Open Questions

### Resolved During Planning

- **Per-command hook vs single-router?** Single router (D1).
- **Hook glue and router as one file or split?** Split (D2).
- **`--confirm` parsing rule?** Strict exact-token (D3).
- **install-statusline token forwarding?** Whitelist (D4).
- **Stats/interact extra tokens?** Ignored (D5).
- **Keep SKILL.md fallback?** Yes (R5, D10) — degraded mode is acceptable; removing the fallback entirely is deferred until enough hook-path evidence accumulates.
- **New env vars?** No (D11).
- **Where does graceful degradation route?** Hook errors fall through to model + SKILL.md (D9).

### Deferred to Implementation

- **Exact JSON output shape that short-circuits the model** — pinned by the Unit 1 spike. Plan assumes `{"decision": "block", "reason": "..."}` (D6); spike confirms or surfaces an alternate field. The spike's deliverable is a small note in `docs/solutions/developer-experience/` capturing the verified shape.
- **Exact prompt field name on the UserPromptSubmit payload** — `prompt` is the assumed field (D7); spike confirms.
- **Whether the spike's findings reveal that `decision: block` truncates long output** — if there's a length cap on the `reason` field, `/buddy:stats` (which is the longest output, with sprite + bars + signals) might not fit. Mitigation if discovered: fall back to a hybrid approach where the hook truncates and includes a "see terminal" pointer, or appends to a file the SKILL.md path reads. Out of scope to design preemptively.
- **Does the hook fire before slash-command resolution, or after?** I.e., does Claude Code consider `/buddy:stats` a slash command (routed to a SKILL.md) or a plain user prompt (routed to UserPromptSubmit)? If both fire, the hook's short-circuit must beat the SKILL.md dispatch. Spike clarifies the ordering; plan assumes hook fires first (or that the short-circuit suppresses the slash-command path). Adjust in Unit 1 if not.
- **Per-script latency overhead** — the hook adds one bash exec + one regex match + one `jq` field-extract on every user prompt (matched or not). Targeted to <10ms on a non-matching prompt. Verified by an inline timing assertion in Unit 4's smoke; if exceeded, optimize by skipping `jq` for prompts that don't start with `/`.

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification.*

```
┌──────────────────────────────────────────────────────────────┐
│ Claude Code session                                           │
│                                                               │
│ user types: /buddy:hatch --confirm                            │
│                                                               │
│ ┌─────────────────────────────────────────────────────────┐  │
│ │ UserPromptSubmit event                                  │  │
│ │   stdin payload: {"prompt": "/buddy:hatch --confirm"...} │  │
│ │   ↓                                                      │  │
│ │ hooks/user-prompt-submit.sh                             │  │
│ │   • jq -r .prompt                                       │  │
│ │   • regex match ^/buddy:(hatch|stats|...)\b             │  │
│ │   • match? → call scripts/dispatch.sh "$prompt"          │  │
│ │           → wrap stdout in {"decision":"block",         │  │
│ │             "reason": "<stdout>"}                       │  │
│ │           → emit JSON, exit 0                           │  │
│ │   • no match? → exit 0 silent → prompt → model           │  │
│ └─────────────────────────────────────────────────────────┘  │
│                          ↓                                    │
│ user sees: <buddy hatched> rendered as the assistant turn     │
└──────────────────────────────────────────────────────────────┘

scripts/dispatch.sh /buddy:hatch --confirm
  ├─ tokenize: cmd="hatch", args=["--confirm"]
  ├─ route on cmd:
  │   hatch  → strict --confirm rule (D3) → hatch.sh --confirm
  │   reset  → strict --confirm rule (D3) → reset.sh --confirm
  │   stats  → status.sh   (ignore tokens, D5)
  │   interact → interact.sh (ignore tokens, D5)
  │   install-statusline → whitelist token table (D4)
  └─ exec; emit stdout; exit 0
```

The router is purely a lexical fan-out. No model in the loop.

## Output Structure

```
hooks/
  user-prompt-submit.sh             # NEW — UserPromptSubmit glue
  hooks.json                         # MODIFIED — add UserPromptSubmit entry

scripts/
  dispatch.sh                        # NEW — single router

skills/
  hatch/SKILL.md                     # MODIFIED — body shortened to one-liner + safety prose
  stats/SKILL.md                     # MODIFIED — body shortened to one-liner
  interact/SKILL.md                  # MODIFIED — body shortened to one-liner
  reset/SKILL.md                     # MODIFIED — body shortened to one-liner + safety prose
  install-statusline/SKILL.md        # MODIFIED — body shortened to one-liner

tests/
  integration/
    test_dispatch.bats               # NEW — dispatch.sh CLI surface
    test_hook_dispatch.bats          # NEW — hooks/user-prompt-submit.sh payload behavior

docs/
  solutions/developer-experience/
    claude-code-userpromptsubmit-shortcircuit-2026-04-29.md   # NEW — spike findings (Unit 1)
  roadmap/
    P4-6-hook-dispatch.md            # NEW — ticket mirror of this plan
```

## Implementation Units

- [ ] **Unit 1: Spike — verify UserPromptSubmit short-circuit semantics**

**Goal:** Pin down the exact `hooks.json` field and JSON output shape that makes a `UserPromptSubmit` hook short-circuit the model and emit content as the assistant turn. Pin down the prompt payload field name. Document findings as a learnings doc that the rest of the plan references.

**Requirements:** R4, R8.

**Dependencies:** None. This unit gates Units 2-5 — its findings may revise D6/D7.

**Files:**
- Create: `docs/solutions/developer-experience/claude-code-userpromptsubmit-shortcircuit-2026-04-29.md`
- Temporary scratch: a throwaway test plugin under `/tmp/` (not committed) — minimal `hooks.json` + a tiny `user-prompt-submit.sh` that echoes a known string with each candidate output shape.

**Approach:**
- Build a minimal scratch plugin: `plugin.json`, `hooks/hooks.json` registering a `UserPromptSubmit` hook on a single regex (`^/spike\b`), and a hook script that for each invocation tries one candidate JSON output shape against stdout (e.g., `{"decision": "block", "reason": "HELLO"}`, then `{"continue": false, "stopReason": "HELLO"}`, then `{"hookSpecificOutput": {...}}`).
- Run `claude --plugin-dir /tmp/spike --debug-to-stderr -p "/spike test"` and observe: did the model see the prompt? Did "HELLO" appear in the chat as the assistant turn? Did stderr show the hook fired?
- Repeat for each candidate output shape until one fully short-circuits the model AND emits the desired text.
- Side-investigate: log the raw stdin payload to a file inside the hook script. Verify the field name carrying the user's typed text (`prompt`, `user_prompt`, `text`, etc.).
- Side-investigate: type `/spike` (which Claude Code may attempt to dispatch as a slash command) vs. `Run /spike test` (plain prose containing the token). Verify the hook fires in both cases or only one. Adjust D8 if needed.
- Time the hook overhead on a no-match prompt (`echo`, plain text) using `time` around the claude invocation; ensure overhead is in the noise.

**Patterns to follow:**
- Live-session smoke recipe in `docs/solutions/developer-experience/claude-code-plugin-hooks-json-schema-2026-04-20.md` § B.

**Test scenarios:**
- Test expectation: none — spike output is a learnings doc, not a code change.

**Verification:**
- Solutions doc captures: (a) confirmed short-circuit JSON shape with example, (b) confirmed prompt field name, (c) confirmed prompt visibility (slash-command-typed vs prose-embedded), (d) noted overhead, (e) any surprises (truncation caps, ordering quirks).
- The doc explicitly states the shape Units 2-3 should implement; if it differs from D6/D7, the plan is updated before those units start.

---

- [ ] **Unit 2: `scripts/dispatch.sh` router + bats coverage**

**Goal:** Single-entry-point router that takes the raw `/buddy:<cmd> <args>` string, parses it deterministically, calls the matching script, and emits its combined stdout/stderr. Pure CLI — no hook payload shape involved.

**Requirements:** R1, R2, R3, R6, R7.

**Dependencies:** None. (Unit 1 findings only matter for the hook glue, not the router.)

**Files:**
- Create: `scripts/dispatch.sh`
- Create: `tests/integration/test_dispatch.bats`

**Approach:**
- Public CLI: `dispatch.sh "<full prompt line>"`. Script:
  1. Trim leading/trailing whitespace.
  2. Regex-match `^/buddy:(hatch|stats|interact|reset|install-statusline)\b\s*(.*)$`. If no match, exit 0 silent. (Used by the hook glue's no-match path; defense in depth.)
  3. Branch on captured `<cmd>`:
     - `hatch`: if remaining args are exactly `--confirm` (single trimmed token), run `hatch.sh --confirm`; else run `hatch.sh` (no args).
     - `reset`: same shape as hatch.
     - `stats`: ignore remaining args, run `status.sh`.
     - `interact`: ignore remaining args, run `interact.sh`.
     - `install-statusline`: whitelisted token table — empty / `--dry-run` / `--yes` / `uninstall` / `uninstall --dry-run` / `--help` / `install` / `install --dry-run` / `install --yes`. Anything else falls through to a usage message and exits 0.
  4. exec the matching script with the resolved args; pass through its stdout. On non-zero exit, emit stderr after stdout (matches current SKILL.md contract).
- Resolve script paths via `${CLAUDE_PLUGIN_ROOT:-$(walk-up from this script)}`, mirroring SKILL.md fallback logic.
- Source-guard with `_DISPATCH_SH_LOADED` even though it's primarily an entry point — protects against re-source in tests.
- Log internal failures (jq missing, script not found, exec failed) to `${CLAUDE_PLUGIN_DATA}/error.log` with the standard tab-separated shape; still exit 0 for the user.

**Execution note:** Start with a failing bats scenario for each routing case in `test_dispatch.bats` before implementing. The router's value is its determinism; tests pin the spec.

**Patterns to follow:**
- `scripts/install_statusline.sh:_install_main` for subcommand+flag dispatch.
- `scripts/reset.sh` for strict-arg parsing.
- Existing hook scripts for `${CLAUDE_PLUGIN_DATA}/error.log` logging convention.

**Test scenarios:**
- *Happy path:* `dispatch.sh "/buddy:stats"` → invokes `status.sh`, output contains expected stats output, exit 0.
- *Happy path:* `dispatch.sh "/buddy:interact"` → invokes `interact.sh`, exit 0.
- *Happy path (strict --confirm):* `dispatch.sh "/buddy:hatch --confirm"` → invokes `hatch.sh --confirm`, exit 0. (Use a test fixture `BUDDY_DATA_DIR` so this is hermetic.)
- *Happy path:* `dispatch.sh "/buddy:hatch"` (no args) → invokes `hatch.sh` no-args, NO_BUDDY → hatches.
- *Happy path:* `dispatch.sh "/buddy:reset --confirm"` against an active buddy (test fixture) → wipes.
- *Happy path:* `dispatch.sh "/buddy:reset"` → consequences message, no wipe.
- *Strict-arg defense:* `dispatch.sh "/buddy:reset what does --confirm do"` → routes to `reset.sh` with NO `--confirm`. Verify by checking the buddy file is unchanged and the consequences message appears.
- *Strict-arg defense:* `dispatch.sh "/buddy:hatch --confirm please"` → no `--confirm` forwarded.
- *Strict-arg defense:* `dispatch.sh "/buddy:hatch '--confirm'"` (quoted) → no `--confirm` forwarded.
- *Whitelist (install-statusline):* `dispatch.sh "/buddy:install-statusline"` → `install_statusline.sh install`.
- *Whitelist:* `dispatch.sh "/buddy:install-statusline --dry-run"` → `install_statusline.sh install --dry-run`.
- *Whitelist:* `dispatch.sh "/buddy:install-statusline --yes"` → `install_statusline.sh install --yes`.
- *Whitelist:* `dispatch.sh "/buddy:install-statusline uninstall"` → `install_statusline.sh uninstall`.
- *Whitelist:* `dispatch.sh "/buddy:install-statusline uninstall --dry-run"` → `install_statusline.sh uninstall --dry-run`.
- *Whitelist:* `dispatch.sh "/buddy:install-statusline --help"` → help message.
- *Whitelist (reject):* `dispatch.sh "/buddy:install-statusline frobnicate"` → usage message, exit 0, no underlying script called.
- *Ignore-extra-tokens:* `dispatch.sh "/buddy:stats please"` → `status.sh` runs as if no args.
- *Ignore-extra-tokens:* `dispatch.sh "/buddy:interact hi buddy"` → `interact.sh` runs as if no args.
- *Unknown command:* `dispatch.sh "/buddy:nonsense"` → exit 0 silent (regex doesn't match the whitelist of 5 cmds).
- *Non-buddy prompt:* `dispatch.sh "hello world"` → exit 0 silent.
- *Edge case (whitespace):* `dispatch.sh "  /buddy:stats  "` → trims and routes correctly.
- *Edge case (empty input):* `dispatch.sh ""` → exit 0 silent.
- *Error path (script missing):* with `CLAUDE_PLUGIN_ROOT=/nonexistent`, `dispatch.sh "/buddy:stats"` → logs to error.log, exits 0, user sees a one-line graceful message.
- *Forwarding stderr:* simulate underlying script exiting non-zero (a fixture test script) → dispatch.sh appends stderr after stdout, still exits 0.

**Verification:**
- `tests/integration/test_dispatch.bats` green.
- `bash scripts/dispatch.sh "/buddy:stats"` from a real terminal renders the stats menu identically to running `bash scripts/status.sh` directly.

---

- [ ] **Unit 3: `hooks/user-prompt-submit.sh` glue + payload tests**

**Goal:** Tiny hook script that reads the `UserPromptSubmit` JSON payload from stdin, extracts the user's typed prompt, calls `dispatch.sh`, and emits the JSON output shape that short-circuits the model (per Unit 1's spike findings).

**Requirements:** R1, R3, R4, R6, R8, R9.

**Dependencies:** Unit 1 (verified output shape and field name). Unit 2 (the `dispatch.sh` it calls).

**Files:**
- Create: `hooks/user-prompt-submit.sh`
- Create: `tests/integration/test_hook_dispatch.bats`

**Approach:**
- Pipeline:
  1. `hook_drain_stdin` (existing helper from `hooks/lib/`) → raw payload JSON.
  2. `jq -r '.<prompt-field>'` → prompt string. Exact field name pinned by Unit 1.
  3. Cheap pre-filter: if the prompt doesn't start with `/buddy:`, exit 0 silent. (Avoids the `dispatch.sh` exec on 99% of prompts.)
  4. Call `dispatch.sh "$prompt"` capturing stdout into a variable.
  5. If `dispatch.sh` produced output, emit `{"decision": "block", "reason": <captured>}` (or whatever shape Unit 1 verified) on stdout, exit 0.
  6. If `dispatch.sh` produced no output (regex didn't match — defense-in-depth duplication of the pre-filter), exit 0 silent.
- Internal-error handling: any failure (jq error, dispatch.sh exec failure, JSON encoding error) logs to `${CLAUDE_PLUGIN_DATA}/error.log` and exits 0 silent. The user's prompt then passes to the model, which falls back to the SKILL.md path. Failure is invisible to the user but visible to operators.
- JSON encoding of the captured output: must JSON-escape the string. Use `jq -Rs '.'` or equivalent to round-trip the captured text through proper escaping — buddy output contains ANSI escapes, control bytes (post-`tr`), unicode, and quotes that must survive.

**Execution note:** This unit's tests use synthetic stdin payloads to exercise the glue without needing a real Claude Code session. A real-session smoke is part of Unit 4.

**Patterns to follow:**
- `hooks/post-tool-use.sh` for `hook_drain_stdin` + error.log convention.
- `hooks/session-start.sh` for the early-exit-on-cheap-check pattern.

**Test scenarios:**
- *Happy path:* synthetic payload with `prompt: "/buddy:stats"` → hook stdout is JSON `{"decision":"block","reason":"<stats output>"}`, exit 0.
- *Happy path:* `prompt: "/buddy:hatch --confirm"` → hook calls dispatch which calls hatch with `--confirm`; reason field carries hatch output.
- *Pre-filter:* `prompt: "hello world"` → exit 0, no stdout. Verify by asserting stdout is empty.
- *Pre-filter:* `prompt: "/help"` → exit 0, no stdout (only `/buddy:` prefix triggers).
- *Defense in depth:* `prompt: "/buddy:nonsense"` → starts with `/buddy:` so passes pre-filter, but `dispatch.sh` returns silent → hook also silent. No JSON emitted.
- *Edge case:* malformed JSON payload (no prompt field) → log to error.log, exit 0 silent.
- *Edge case:* prompt contains double quotes, backslashes, ANSI escapes, multi-line content → JSON encoding survives (assert via `jq -e '.reason'` round-trip).
- *Edge case:* prompt contains a literal newline before `/buddy:stats` (`"foo\n/buddy:stats"`) → does NOT match (regex requires line start). Verify regex anchoring.
- *Error path:* `dispatch.sh` not found at expected path → log to error.log, exit 0 silent.
- *Error path:* prompt is the empty string → exit 0 silent.
- *Latency:* on a non-matching prompt, hook completes in <50ms (assert via `time` in bats). On a matching prompt, hook completes in <100ms + the underlying script's budget.

**Verification:**
- `tests/integration/test_hook_dispatch.bats` green.
- Manual: `echo '{"prompt":"/buddy:stats"}' | bash hooks/user-prompt-submit.sh` returns valid JSON with the stats output in `.reason`.

---

- [ ] **Unit 4: `hooks.json` wiring + live-session smoke**

**Goal:** Add the `UserPromptSubmit` event entry to `hooks/hooks.json` using the schema verified in Unit 1, and verify with a real Claude Code session that the round-trip works end-to-end.

**Requirements:** R1, R3, R4, R8.

**Dependencies:** Units 1-3.

**Files:**
- Modify: `hooks/hooks.json`

**Approach:**
- Add a `UserPromptSubmit` entry alongside the existing four events. Schema follows the nested-array shape documented in `claude-code-plugin-hooks-json-schema-2026-04-20.md`. The matcher field is omitted (UserPromptSubmit is not tool-scoped); the hook script handles its own regex match.
- Run the live-session smoke recipe: `claude --plugin-dir . --debug-to-stderr -p "/buddy:stats"` and verify (a) no `Failed to load hooks` error in stderr, (b) the buddy stats output appears as the assistant turn, (c) `${CLAUDE_PLUGIN_DATA}/error.log` is empty.
- Repeat for each of the five commands and for one no-match prompt (`"hello"`) to verify pass-through.
- Repeat for the destructive-strict-arg cases: `/buddy:hatch what does --confirm do` should NOT trigger a wipe (verify the buddy file is unchanged); `/buddy:hatch --confirm` triggered against an active buddy should reroll cleanly.

**Patterns to follow:**
- `hooks/hooks.json` existing entries.
- Live-session smoke recipe from the hooks-schema solutions doc.

**Test scenarios:**
- *Schema:* `jq -e '.hooks.UserPromptSubmit[0].hooks[0]' hooks/hooks.json` returns a valid `{type, command, timeout?}` object. (Lightweight schema check that bats can do; deeper validation requires the live smoke.)
- *Live smoke:* documented as a checklist in the unit's PR description, not as automated test code (bats can't drive `claude`).

**Verification:**
- `hooks.json` parses cleanly; existing structural tests stay green.
- Manual live-session smoke passes the five command cases + one pass-through + two strict-arg cases.

---

- [ ] **Unit 5: SKILL.md fallback rewrites**

**Goal:** Replace the verbose body of each of the five SKILL.md files with a concise one-liner pointing at the hook as the canonical path. Preserve frontmatter and (for hatch/reset) the destructive-flag safety prose.

**Requirements:** R5.

**Dependencies:** None (independent of Units 1-4; can land in parallel as a separate commit).

**Files:**
- Modify: `skills/hatch/SKILL.md`
- Modify: `skills/stats/SKILL.md`
- Modify: `skills/interact/SKILL.md`
- Modify: `skills/reset/SKILL.md`
- Modify: `skills/install-statusline/SKILL.md`

**Approach:**
- For `stats` / `interact` / `install-statusline`: body becomes 3-5 lines — "this command is normally handled by the buddy plugin's UserPromptSubmit hook; if you're seeing this fallback, run the bash directly: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" /buddy:<cmd> <args>`." Plus the existing "print stdout verbatim, no roleplay" closing line.
- For `hatch` / `reset`: same one-liner shape, but **preserve the destructive-flag safety prose** — the four-bullet "Pass `--confirm` when... Do NOT pass `--confirm` when..." section stays intact. The fallback path still has the model in the loop, so it still needs the guardrails. Only the boilerplate dispatch instructions are shortened.
- Frontmatter (`description`, `disable-model-invocation: true`) unchanged on all five.
- The existing structural test `tests/unit/test_skills_structure.bats` may assert specific phrases (e.g., "IMMEDIATELY"). Audit and adjust assertions to match the new shape — but only the assertions that are tied to specific phrases. Frontmatter assertions stay.

**Test scenarios:**
- *Structural:* every SKILL.md still parses with the expected frontmatter (`disable-model-invocation: true`, non-empty `description`).
- *Structural:* the new body contains the dispatch.sh fallback invocation string for each command.
- *Structural (destructive only):* `hatch` and `reset` SKILL.md bodies still contain the strict "Do NOT pass `--confirm`" prose.

**Verification:**
- `tests/unit/test_skills_structure.bats` green after assertion-update.
- Manual: each rewritten SKILL.md is under ~20 lines body content (excluding frontmatter), down from current 40-60.

## System-Wide Impact

- **Interaction graph:** `UserPromptSubmit` hook is a new event handler on every prompt the user types. The pre-filter (D8) ensures the dispatch path is taken only on `/buddy:*` prompts. Existing hooks (SessionStart, PostToolUse, PostToolUseFailure, Stop) are unaffected. The five SKILL.md fallbacks are still loaded but only consulted when the hook can't run.
- **Error propagation:** Hook script errors silently degrade to the SKILL.md fallback path. `dispatch.sh` errors degrade to a graceful one-liner shown to the user + an entry in `error.log`. Underlying scripts' error behavior is unchanged.
- **State lifecycle risks:** None new. The router does not touch `buddy.json`, session state, or backups. It only execs scripts that already manage their own state.
- **API surface parity:** The five `/buddy:*` commands behave identically (input shape → output shape) before and after this change. The destructive-flag interpretation gets *stricter* (lexical, not heuristic) — that's a behavior change that the strict-arg test scenarios in Unit 2 explicitly cover. Users who relied on natural-language `--confirm` directives ("yes wipe it with --confirm") will hit the consequences message; the message itself directs them to `/buddy:reset --confirm` literal which works.
- **Integration coverage:** The full round-trip (typed slash command → hook → dispatch → script → assistant turn) can only be proven by a live Claude Code session. Unit 4's smoke is the only verification of R8. The bats coverage in Units 2-3 verifies every layer except the Claude Code → hook → JSON-shape interface, which is the failure mode the spike (Unit 1) is designed to catch.
- **Unchanged invariants:** All five underlying scripts (`hatch.sh`, `status.sh`, `interact.sh`, `reset.sh`, `install_statusline.sh`) — byte-identical. `scripts/lib/render.sh`, `scripts/lib/state.sh`, `scripts/lib/evolution.sh`, `scripts/lib/commentary.sh` — byte-identical. Species JSONs, sprite content, statusline render, the four existing hooks — byte-identical. Existing 294+ tests stay green.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Spike (Unit 1) discovers UserPromptSubmit cannot fully short-circuit the model | Plan explicitly gates Units 2-5 on Unit 1's findings. If `decision: block` doesn't replace the assistant turn but only injects context, the design needs a different approach (e.g., a hybrid where the hook writes output to a known file and the SKILL.md path reads it; or rely on the `additionalContext` field with a stronger imperative). Document the contingency in Unit 1's solutions doc; revisit Unit 2-5 design before starting them. |
| `decision: block` truncates long output (`/buddy:stats` is the longest) | Unit 1 spike measures the cap. If hit, mitigation: split the stats output into chunks, or fall back to the model-relay path for stats only. Out-of-band fallback is preferable to truncation. |
| Strict `--confirm` arg rule (D3) surprises users who typed natural-language directives | The consequences message explicitly directs users to the literal flag. `/buddy:reset` (no flag) prints "Run `/buddy:reset --confirm` to continue" — the literal instruction. Net: stricter parsing produces clearer prompts. |
| Hook adds latency to every user prompt | Pre-filter on `/buddy:` prefix (D8) before any work. Latency budget enforced in Unit 3 tests (<50ms on no-match). The `time` measurement during Unit 4's live smoke confirms in a real session. |
| `hooks.json` schema change for new event silently fails to load (the bats blind spot) | Unit 4's live-session smoke is mandatory. Plan flags it explicitly; no auto-test substitute exists. |
| Hook fires on every keystroke if Claude Code's UserPromptSubmit triggers on intermediate events | Unverified assumption. Spike (Unit 1) confirms event timing — fires on submit, not keystroke. If it does fire intra-keystroke, mitigation: still safe (regex fails → silent exit), but latency budget may need revisiting. |
| Hook payload field name (D7) differs across Claude Code versions | Spike pins current version; document the field name's source and add a defensive jq fallback (`.prompt // .user_prompt // .text`) in the hook glue if multiple plausible names exist. |
| SKILL.md fallback bodies drift from the dispatch.sh CLI surface over time | Unit 5's structural tests assert the SKILL.md body contains the exact `dispatch.sh` fallback command. Drift → red test. |
| Removing the destructive-flag prose from `hatch`/`reset` SKILL.md bodies regresses safety in the fallback path | Plan explicitly preserves that prose (Unit 5 approach). Test scenario in Unit 5 asserts presence. |
| Existing tests assume the SKILL.md body contains specific phrases ("IMMEDIATELY", etc.) | Unit 5 audits and updates `test_skills_structure.bats` assertions. New assertions match the new body shape. |

## Documentation / Operational Notes

- **Solutions doc compound** (post-implementation): writeup capturing the dispatch-layer pivot, the spike findings, and the strict-arg rule. Triggered via `/ce:compound` after Unit 5 lands. Audience: future plugin authors hitting the same SKILL.md → model unreliability wall.
- **Roadmap ticket** at `docs/roadmap/P4-6-hook-dispatch.md` mirrors this plan, transitions from `in-progress` to `done` on PR merge.
- **README** gets a one-line note in the "How it works" section: slash commands are served by a UserPromptSubmit hook with a SKILL.md fallback. Body of the change is small; doc impact is small.
- **No migration.** Existing buddy state is unaffected. Users do not need to reinstall the plugin; the hook starts handling commands the next session after the new version lands.

## Sources & References

- Related plan: [docs/plans/2026-04-23-001-feat-p4-3-visible-buddy-plan.md](./2026-04-23-001-feat-p4-3-visible-buddy-plan.md) — original SKILL.md dispatch contract that this plan replaces (the script-side contract is preserved).
- Solutions:
  - [skill-md-framing-as-execution-priming-2026-04-29.md](../solutions/developer-experience/skill-md-framing-as-execution-priming-2026-04-29.md) — failure mode being routed around.
  - [claude-code-slash-dispatch-stdin-eof-2026-04-29.md](../solutions/developer-experience/claude-code-slash-dispatch-stdin-eof-2026-04-29.md) — `--yes` flag rationale that dispatch.sh must preserve.
  - [claude-code-plugin-hooks-json-schema-2026-04-20.md](../solutions/developer-experience/claude-code-plugin-hooks-json-schema-2026-04-20.md) — schema discipline + live-session smoke recipe.
  - [claude-code-skill-dispatcher-pattern-2026-04-19.md](../solutions/developer-experience/claude-code-skill-dispatcher-pattern-2026-04-19.md) — the dispatcher pattern this plan upgrades.
- Claude Code hooks reference: https://code.claude.com/docs/en/hooks (verified live by Unit 1 spike).
