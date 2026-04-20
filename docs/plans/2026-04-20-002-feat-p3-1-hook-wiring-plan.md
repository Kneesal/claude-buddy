---
title: P3-1 Hook wiring + session init
type: feat
status: active
date: 2026-04-20
origin: docs/roadmap/P3-1-hook-wiring.md
---

# P3-1 — Hook wiring + session init

## Overview

Wire Claude Code's `SessionStart`, `PostToolUse`, `PostToolUseFailure`, and `Stop` events to four bash hook scripts under `hooks/`. Initialize per-session ephemeral state in `session-<id>.json` on `SessionStart` and keep a dedup ring of recent tool-call IDs. **Commentary is out of scope** — P3-2 builds the line-selection engine on top of the plumbing this ticket installs. This ticket's deliverable is "hooks fire, state writes happen, nothing breaks, still no visible behavior change for end users."

## Problem Frame

The plugin is currently ambient-only: P2 ships a read-only status line, slash commands (P1-3) let the user inspect and reset state, but nothing in the plugin *reacts* to what the user is doing inside Claude Code. The evolution loop (P4+) depends on signals accumulated by hooks; the commentary engine (P3-2) depends on per-session cooldown state initialized by `SessionStart`. Until the hook surface exists and is proven reliable, nothing downstream can land.

Hooks run inside the user's Claude Code session. They fire dozens to hundreds of times per session. A crashed hook surfaces to the user as a broken session. A slow hook adds perceptible latency to every tool call. The contract (`exit 0` on any internal failure, p95 < 100ms, atomic writes through `state.sh`) is non-negotiable and is what this ticket has to hit.

## Requirements Trace

- **R1 (from ticket exit criteria):** All four hooks fire in-session and exit cleanly.
- **R2 (from ticket exit criteria):** `NO_BUDDY` state produces zero hook output and zero state writes.
- **R3 (from ticket exit criteria):** Concurrent sessions don't race on `session-<id>.json` — each session has its own file.
- **R4 (from umbrella plan §State Lifecycle Risks):** Orphan tmp files older than the configured threshold are swept on `SessionStart` via `state_cleanup_orphans`.
- **R5 (from umbrella plan Interaction Graph and D6):** Pre-hatch (`NO_BUDDY`) is the cheap-check-and-bail path; no signals accumulate, no session file is written.
- **R6 (from brainstorm R4 / plan §System-Wide Impact):** Tool-call IDs are tracked in a ring buffer (last 20) so a tool-call ID that surfaces on both `PostToolUse` and `PostToolUseFailure` isn't double-counted by any downstream consumer.
- **R7 (from CLAUDE.md):** Hooks exit 0 on internal failure; never break the session.
- **R8 (performance):** Each hook's p95 runtime < 100ms measured across 100 invocations.

## Scope Boundaries

- **Not in scope:** commentary selection, line banks, rate-limit stack — all P3-2.
- **Not in scope:** signal increments (`variety.toolsUsed`, `quality.successfulEdits`, `chaos.errors`) — these are P4-1 and will land on top of the same hook scripts.
- **Not in scope:** XP tick on `Stop` — P4-1.
- **Not in scope:** `PreToolUse` — umbrella plan §API Surface Parity is explicit: "No `PreToolUse` (we don't want to gate any tool)."
- **Not in scope:** any user-visible stdout from hooks. All four hooks emit empty stdout in P3-1; P3-2 is the first ticket where a hook writes to the transcript.

## Context & Research

### Relevant Code and Patterns

- `scripts/lib/state.sh` — provides `buddy_load`, `session_load`, `session_save <id>`, `state_cleanup_orphans`, and the `STATE_NO_BUDDY` / `STATE_CORRUPT` / `STATE_FUTURE_VERSION` sentinels. Already guards against bash <4.1, manages re-sourcing, and refuses invalid session IDs. P3-1 consumes this library unchanged.
- `statusline/buddy-line.sh` — reference implementation of the "source state.sh, sentinel-switch on `buddy_load`, drain stdin defensively, exit 0" discipline. Hook scripts should mirror its structure (no module-level `set -euo pipefail`, explicit error handling, terminal-width-aware where relevant).
- `scripts/status.sh` — the P1-3 dispatcher backing `/buddy:stats`. Uses the upstream-validator variant of the `@tsv` extraction pattern; useful as a second reference for state.sh consumption.
- Umbrella plan §Interaction Graph — defines the ordered chain `hook → flock'd state write → status line re-render` and the <100ms per-step budget.

### Institutional Learnings

- `docs/solutions/best-practices/bash-state-library-patterns-2026-04-18.md` — the contract the hook scripts must respect: no module-level `set -euo`, guard bash 4.1+, atomic writes through `state.sh`, never call `rm` directly under a flock, sentinels are the load-bearing return value of `buddy_load`. Hooks are the first runtime writers into `session-<id>.json` so the no-`set -e` discipline matters even more here than in the status line.
- `docs/solutions/best-practices/bash-subshell-state-patterns-2026-04-19.md` — a reminder that `$(...)` subshells can't mutate caller state; ring-buffer updates must happen via stdout-and-capture, not in-place mutation of a variable set in the parent.
- `docs/solutions/best-practices/bash-jq-tsv-null-field-collapse-2026-04-20.md` — any multi-field jq extraction from the hook payload must use the newline-delimited `readarray` variant (Option B), because the payload is produced by an external system (Claude Code) and we cannot enforce a shape contract upstream.
- `docs/solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md` — creating a new top-level directory (`hooks/`) at the plugin root may require a full Claude Code restart, not just `/reload-plugins`. Validation workflow must assume restart is needed.
- `docs/solutions/developer-experience/claude-code-skill-dispatcher-pattern-2026-04-19.md` — the analogous "thin dispatcher" pattern for skills suggests hooks should also be short and funnel to shared helpers rather than duplicating boilerplate across four near-identical scripts.

### External References

- Claude Code hooks reference: `https://code.claude.com/docs/en/hooks`. The ticket cites this as the source of truth for hook event names, stdin payload schema, and the "stdout on exit 0 becomes a system message in the transcript" behavior. Resolved during planning (see Open Questions §Resolved During Planning).

## Key Technical Decisions

**D1. Shared `scripts/hooks/common.sh` for the sentinel-switch / payload-parse / early-exit boilerplate.** The four hook scripts otherwise duplicate the same first ~20 lines. One shared helper removes the duplication and gives us one place to fix a bug (e.g., a payload-schema change). The helper does not set `set -e`; it provides functions the caller invokes explicitly, matching `state.sh`'s discipline. Cost is one extra `source` per hook; benefit is ~80 lines of deduplication and a single test surface for payload extraction.

**D2. Session-id extraction from stdin JSON payload, via jq, with `readarray` multi-field extraction where needed.** The Claude Code hook payload is documented to include a session identifier alongside event-specific fields. We extract it once per hook invocation into a shell variable, then sanitize through `_state_valid_session_id` (re-exposed from `state.sh`) before passing to `session_save`. Rationale: `state.sh`'s session-id regex refuses anything containing slashes or dots, which is our defense against a hostile or malformed payload. Uses Option B (newline-delimited readarray) from `bash-jq-tsv-null-field-collapse-2026-04-20.md` because the payload has an external producer.

**D3. `SessionStart` is the only writer of initial session state; other hooks read-modify-write defensively.** On `SessionStart`, we reset `session-<id>.json` to a known-good starting shape (`sessionId`, `startedAt`, empty `cooldowns`, empty `recentToolCallIds`). The other three hooks treat a missing or `{}` session file as "SessionStart didn't run for some reason" and re-initialize the same shape before their own write. This keeps every hook self-contained — you can drop into any hook first and the state converges. Rationale: Claude Code may start a session without firing `SessionStart` in edge cases (plugin enabled mid-session, hook config reloaded); defensive re-init is cheaper than investigating why.

**D4. Ring-buffer dedup happens in `PostToolUse` / `PostToolUseFailure` only.** `SessionStart` clears the ring; `Stop` doesn't touch it. The ring is a fixed size (20); push-and-truncate happens in a single `jq` call so there's no read-then-write gap. `Stop` fires once at session end, so it doesn't need dedup; tool-call IDs are the dedup key.

**D5. No commentary, no signal increments, no XP.** P3-1 writes *only* the session-bookkeeping fields (`sessionId`, `startedAt`, `cooldowns`, `recentToolCallIds`). P3-2 and P4-1 extend the same scripts with their concerns. Each hook in P3-1 exits with empty stdout — the "placeholder" the ticket calls for is literally nothing on stdout, which is the most forwards-compatible choice.

**D6. Timeouts in `hooks.json` stay at the ticket's value (2s).** Matches the ticket. 2 seconds is a ceiling, not a target — p95 should sit comfortably under 100ms. The ceiling is there to cover filesystem hiccups on slow disks, not normal operation.

**D7. Error-log path.** Internal failures log to `${CLAUDE_PLUGIN_DATA}/error.log` (append-only, one line per failure with ISO timestamp, hook name, and short reason). This matches the umbrella plan's "writes to `error.log`, never stderr-to-Claude" clause. Size cap / rotation is deferred — the file grows slowly and doesn't affect correctness.

## Open Questions

### Resolved During Planning

- **hooks.json schema.** The ticket includes the exact manifest shape (top-level `"hooks"` key, per-event arrays of `{type: "command", command, timeout}` entries). This matches the Claude Code hooks reference and was already used as the authoritative spec in the umbrella plan. Resolution: use the ticket's manifest verbatim. **Post-hoc correction (2026-04-20):** the ticket's schema was flat and Claude Code v2.1.114 rejected it. Each event entry needed a nested `hooks:` key. Fixed during P3-1 implementation. See [docs/solutions/developer-experience/claude-code-plugin-hooks-json-schema-2026-04-20.md](../solutions/developer-experience/claude-code-plugin-hooks-json-schema-2026-04-20.md) for the correct schema and the live-session smoke technique that caught it.
- **Session-id source.** Claude Code pipes a JSON envelope to hook stdin containing at least `hook_event_name`, `session_id`, and event-specific fields (`tool_name`, `tool_input`, `tool_response` for tool events). Resolution: extract `session_id` via jq, sanitize, pass to `session_save`.
- **Shared common.sh vs inline.** Decided in **D1** — shared helper under `scripts/hooks/common.sh`.
- **SessionStart atomic contract.** Decided in **D3** — reset to a known-good shape; other hooks re-init on missing file.
- **`session_save($1=session_id)` from hooks.** Verified: `state.sh` already accepts a session_id argument, validates it, and uses `tmp+rename` atomic writes. No changes needed in `state.sh`. Hook scripts call `session_save "$sid"` with content on stdin.

### Deferred to Implementation

- **Exact stdin-drain pattern for the Stop hook when Claude Code sends a larger payload.** The status line uses `timeout 0.1 cat >/dev/null` as a defensive drain. The hook equivalent depends on whether we need the full payload (for Stop we likely don't). Resolved during implementation by checking the actual payload shape on a live session.
- **Whether `state_cleanup_orphans` needs to be time-bounded inside `SessionStart`.** The function already has its own internal limits (PID-aware pass + hard-age unconditional pass). Whether we wrap it in a `timeout 1` guard as belt-and-braces is a judgment call best made against measured p95.
- **Whether `PostToolUseFailure` payload carries the same `session_id` field as `PostToolUse`.** Resolved by printf-ing the payload to a temp log file during the first live-session smoke test and verifying empirically.

## Output Structure

```
hooks/
├── hooks.json                     # event → script wiring (NEW)
├── session-start.sh               # SessionStart handler (NEW)
├── post-tool-use.sh               # PostToolUse handler (NEW)
├── post-tool-use-failure.sh       # PostToolUseFailure handler (NEW)
└── stop.sh                        # Stop handler (NEW)

scripts/hooks/
└── common.sh                      # shared boilerplate: sentinel switch,
                                   # session-id extract, early-exit on NO_BUDDY,
                                   # error-log helper (NEW)

tests/hooks/
├── test_common.bats               # (NEW)
├── test_session_start.bats        # (NEW)
├── test_post_tool_use.bats        # (NEW)
├── test_post_tool_use_failure.bats # (NEW)
└── test_stop.bats                 # (NEW)
```

*Scope declaration; the implementer may adjust the directory layout if implementation reveals a better one. The per-unit `**Files:**` sections remain authoritative.*

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

**Hook script skeleton (all four):**

```
1. source scripts/lib/state.sh  (bash 4.1+ guard, sentinels, session I/O)
2. source scripts/hooks/common.sh (shared boilerplate)
3. read stdin payload into a variable (timeout-guarded; bounded drain)
4. buddy_load → sentinel switch:
      NO_BUDDY        → exit 0 immediately (no session file write)
      CORRUPT         → exit 0 immediately
      FUTURE_VERSION  → exit 0 immediately
      <json>          → fall through to per-hook logic
5. extract session_id from payload; validate; on invalid → log + exit 0
6. per-hook work (see per-unit Approach)
7. exit 0 unconditionally
```

**Data flow on PostToolUse:**

```
stdin JSON ──▶ jq (session_id, tool_call_id) ──▶ readarray ──▶ shell vars
                                                                   │
  buddy_load ─▶ (NO_BUDDY?) ───yes──▶ exit 0                       │
                     │                                             │
                     no                                            │
                     ▼                                             ▼
              session_load ──▶ jq (ring-push + truncate to 20) ──▶ session_save
                                        │
                                        ▼
                        if id already in ring → skip further work
                                        │
                                        ▼
                                 (P3-2/P4-1 hooks here)
                                        │
                                        ▼
                                    exit 0
```

## Implementation Units

- [ ] **Unit 1: `scripts/hooks/common.sh` shared helpers**

**Goal:** Single source of truth for payload parsing, sentinel handling, error logging, and session-id validation.

**Requirements:** R1, R2, R5, R7

**Dependencies:** None (consumes existing `state.sh`).

**Files:**
- Create: `scripts/hooks/common.sh`
- Test: `tests/hooks/test_common.bats`

**Approach:**
- Expose functions: `hook_drain_stdin`, `hook_extract_session_id`, `hook_early_exit_if_no_buddy`, `hook_log_error`, `hook_read_tool_call_id` (payload-specific helper used by the PostToolUse variants).
- Re-export `_state_valid_session_id` indirectly by calling it from `hook_extract_session_id` (do not duplicate the regex).
- Use Option B (newline-delimited readarray) when extracting multiple payload fields — the payload has an external producer (see institutional learning on `bash-jq-tsv-null-field-collapse`).
- `hook_drain_stdin` reads stdin into a global (or emits to stdout for caller `$(...)` capture — prefer the latter for testability). Timeout-guarded (100ms) so a stuck pipe cannot block the hook.
- `hook_log_error` appends one timestamped line to `${CLAUDE_PLUGIN_DATA}/error.log`, never stderr.
- No module-level `set -euo pipefail`. Guard re-sourcing with `_BUDDY_HOOK_COMMON_LOADED=1`.

**Patterns to follow:**
- `scripts/lib/state.sh` — overall library structure, sentinel discipline, bash-4.1 guard (can be omitted here since `state.sh` already enforces it before this file is sourced).
- `statusline/buddy-line.sh` — for the "drain stdin defensively + timeout" idiom.

**Test scenarios:**
- *Happy path:* `hook_extract_session_id` given a valid payload returns the session_id on stdout, exit 0.
- *Edge case:* missing `session_id` field → returns empty, exit non-zero (caller will then `hook_log_error` and exit 0).
- *Edge case:* session_id containing `../` or `/` → rejected by `_state_valid_session_id`, returns empty, exit non-zero.
- *Edge case:* payload with `session_id: null` → treated identically to missing.
- *Edge case:* payload is not valid JSON → jq fails silently; helper returns empty, exit non-zero.
- *Error path:* `hook_log_error` writes an append line when `${CLAUDE_PLUGIN_DATA}` exists; returns 0 silently when it does not (a hook must never fail because logging failed).
- *Integration:* sourcing `common.sh` from a shell with `set -u` active does not crash on the first call (i.e. no unset-variable bugs in happy-path functions).

**Verification:** All common-helper tests pass; sourcing the file from a caller with `set -e` does not abort the caller on routine failure paths.

---

- [ ] **Unit 2: `hooks/session-start.sh`**

**Goal:** Initialize (or reset) `session-<id>.json` to the known-good shape, sweep orphan tmps, exit fast on `NO_BUDDY`.

**Requirements:** R1, R2, R3, R4, R5, R7, R8

**Dependencies:** Unit 1 (common.sh).

**Files:**
- Create: `hooks/session-start.sh`
- Test: `tests/hooks/test_session_start.bats`

**Approach:**
- Source `state.sh` then `common.sh`.
- Drain stdin, extract session_id.
- `buddy_load` sentinel switch; on `NO_BUDDY` exit 0 immediately (no session file write — per D6 in umbrella plan).
- On active buddy: construct the initial session JSON via jq — `{schemaVersion: 1, sessionId, startedAt: <ISO-8601 UTC>, cooldowns: {}, recentToolCallIds: []}` — pipe to `session_save "$sid"`.
- Call `state_cleanup_orphans` after the write (post-write so that a cleanup failure cannot delay session setup). Ignore its return value.
- Empty stdout, exit 0.

**Patterns to follow:**
- `scripts/lib/state.sh` — timestamp handling uses the same `date -u +%Y-%m-%dT%H:%M:%SZ` pattern as `session.json` examples in umbrella plan §Data model.

**Test scenarios:**
- *Happy path:* active buddy + valid session_id → `session-<id>.json` created with all required top-level fields; `startedAt` is a valid ISO-8601 Zulu timestamp; `recentToolCallIds` is an empty array; `cooldowns` is an empty object; exit 0; empty stdout.
- *Happy path (re-init):* existing session file with stale data → overwritten with fresh shape; stale cooldowns cleared.
- *Edge case:* `NO_BUDDY` sentinel → no session file is created; `state_cleanup_orphans` is **not** called (pre-hatch stays fully passive per D6); exit 0; empty stdout.
- *Edge case:* `CORRUPT` sentinel → no session file created; exit 0; one line appended to `error.log`; empty stdout.
- *Edge case:* `FUTURE_VERSION` sentinel → behaves identically to CORRUPT for P3-1 purposes.
- *Edge case:* `${CLAUDE_PLUGIN_DATA}` unset or unwritable → exit 0; one line appended to stderr-sink (not stderr-to-Claude); session file not created.
- *Edge case:* invalid session_id in payload → exit 0; no session file created; error logged.
- *Error path:* `state_cleanup_orphans` returns non-zero → session-start still exits 0; session file still present.
- *Integration:* run against `$CLAUDE_PLUGIN_DATA` populated with 3 orphan `.tmp.<dead-pid>.XXX` files older than the threshold → all three are removed when buddy is active.

**Verification:** After a simulated session-start with an active buddy, `session-<id>.json` exists and parses; pre-hatch, no file is created; hook exit code is always 0.

---

- [ ] **Unit 3: `hooks/post-tool-use.sh`**

**Goal:** Wire the PostToolUse event, maintain the dedup ring on `recentToolCallIds`, keep stdout empty, exit in under 100ms p95.

**Requirements:** R1, R2, R3, R6, R7, R8

**Dependencies:** Units 1, 2.

**Files:**
- Create: `hooks/post-tool-use.sh`
- Test: `tests/hooks/test_post_tool_use.bats`

**Approach:**
- Source `state.sh`, `common.sh`.
- Drain stdin, extract `session_id` and `tool_call_id` via a single jq invocation using the newline-delimited readarray pattern.
- `buddy_load` sentinel switch (NO_BUDDY → exit 0; other sentinels → exit 0 + log).
- `session_load "$sid"` — if the returned JSON is `{}` (missing file), synthesize the initial shape (per D3).
- Ring-buffer update in a single jq pipeline:
  `.recentToolCallIds = ((.recentToolCallIds // []) + [$id] | unique_by_last_occurrence | .[-20:])`
  (Exact filter detail deferred to implementation; the shape — "push, truncate-to-20, preserve insertion order" — is the contract.)
- If `tool_call_id` was already in the ring → skip the write entirely (avoid unnecessary churn).
- Else: `session_save "$sid"` with the updated JSON.
- Empty stdout, exit 0.

**Patterns to follow:**
- `bash-jq-tsv-null-field-collapse-2026-04-20.md` Option B for the multi-field extraction.

**Test scenarios:**
- *Happy path:* active buddy, fresh session → ring grows from `[]` to `[id1]`, session file persists; exit 0; empty stdout.
- *Happy path (dedup):* same `tool_call_id` piped twice → ring remains `[id1]`, second invocation writes nothing (verify via mtime or a save-counter stub); exit 0 both times.
- *Happy path (eviction):* feed 25 distinct IDs → ring contains the last 20 in arrival order; older 5 are dropped.
- *Edge case:* `NO_BUDDY` → no session file read or written; exit 0; empty stdout.
- *Edge case:* missing `tool_call_id` in payload → hook logs error to `error.log`, exits 0; no state mutation.
- *Edge case:* missing `session_id` in payload → same as above.
- *Edge case:* session file exists but is `{}` (SessionStart didn't fire) → hook synthesizes initial shape and writes the first ring entry.
- *Edge case:* `tool_call_id` contains shell metacharacters (`$(date)`, backticks) → handled as opaque string by jq, no shell injection possible.
- *Error path:* `session_save` fails (unwritable data dir) → hook logs error, exits 0; no partial write left behind (guaranteed by `state.sh` tmp+rename).
- *Integration (performance):* 100 invocations with distinct IDs measured via `/usr/bin/time` — p95 wall-clock < 100ms.
- *Integration (concurrency):* two parallel invocations for the same session with distinct IDs → both IDs end up in the ring (rename atomicity is the contract; if one is lost under tight contention, document it).

**Verification:** After 20 distinct tool-call IDs, the ring contains exactly 20 entries; a 21st ID evicts the oldest; duplicate IDs are no-ops.

---

- [ ] **Unit 4: `hooks/post-tool-use-failure.sh`**

**Goal:** Same shape as `post-tool-use.sh` for the failure event, so the surface is uniform and P3-2 / P4-1 can extend both identically.

**Requirements:** R1, R2, R3, R6, R7, R8

**Dependencies:** Unit 3 (structure mirrors).

**Files:**
- Create: `hooks/post-tool-use-failure.sh`
- Test: `tests/hooks/test_post_tool_use_failure.bats`

**Approach:**
- Structurally identical to Unit 3. The only difference in P3-1 is the logical event label used in `error.log` diagnostics.
- Same dedup ring shared with `post-tool-use.sh` — the umbrella plan explicitly notes that a failed Edit may surface on both events and we track by ID, not event type (see ticket Notes §dedup).
- Empty stdout, exit 0.

**Patterns to follow:**
- Unit 3.

**Test scenarios:**
- *Happy path:* failure event with novel tool_call_id → ring grows; exit 0.
- *Happy path (dedup across events):* same tool_call_id fired first as PostToolUse, then as PostToolUseFailure → second invocation is a no-op; ring size unchanged.
- *Edge case:* `NO_BUDDY` → no state touched.
- *Edge case:* missing payload fields → logged, exit 0.
- *Integration:* 100 invocations — p95 < 100ms.

**Verification:** Cross-event dedup works; ring is the shared source of truth between both PostToolUse variants.

---

- [ ] **Unit 5: `hooks/stop.sh`**

**Goal:** Fire on session end. In P3-1, all it does is no-op (exit 0) after the sentinel check. Landing the script now means P3-2 has a file to extend without changing `hooks.json`.

**Requirements:** R1, R2, R7, R8

**Dependencies:** Unit 1.

**Files:**
- Create: `hooks/stop.sh`
- Test: `tests/hooks/test_stop.bats`

**Approach:**
- Source `state.sh`, `common.sh`.
- Drain stdin, extract session_id (for logging).
- `buddy_load` sentinel switch; any non-active state → exit 0.
- Empty stdout; no state writes.
- This unit is intentionally minimal so that P3-2's commentary + P4-1's XP tick both have an obvious place to land.

**Test scenarios:**
- *Happy path:* active buddy → exit 0; empty stdout; no state mutation.
- *Edge case:* NO_BUDDY → exit 0; empty stdout.
- *Edge case:* invalid payload → logged, exit 0.
- *Integration:* 100 invocations — p95 < 100ms.

**Verification:** Stop fires, is silent, and leaves state untouched.

---

- [ ] **Unit 6: `hooks/hooks.json` manifest**

**Goal:** Register the four hook scripts with Claude Code using the schema from the ticket.

**Requirements:** R1

**Dependencies:** Units 2, 3, 4, 5 (files must exist when the manifest references them).

**Files:**
- Create: `hooks/hooks.json`

**Approach:**
- Exact manifest from the ticket: one entry per event, type `command`, `${CLAUDE_PLUGIN_ROOT}/hooks/<script>.sh`, `timeout: 2`.
- No other events wired.
- Test expectation: none — pure config. Correctness is proven by Unit 7 (smoke test in a live session).

**Patterns to follow:**
- Ticket schema verbatim.

**Test scenarios:**
- Test expectation: none — pure configuration registered with Claude Code and exercised end-to-end by Unit 7.

**Verification:** `jq .` parses the file; `/reload-plugins` (or restart if directory is new) loads it; the four events fire in a live session.

---

- [ ] **Unit 7: End-to-end smoke + performance harness**

**Goal:** Prove p95 < 100ms for each hook under 100 invocations, and prove the hooks fire in a real Claude Code session.

**Requirements:** R1, R8

**Dependencies:** Units 1–6.

**Files:**
- Create: `tests/hooks/perf_hook_p95.sh` (bash script that pipes synthetic payloads through each hook 100 times via `/usr/bin/time -v` and asserts p95 wall-clock).
- Modify: `docs/roadmap/P3-1-hook-wiring.md` — add a Notes section summarizing measured p95 figures and any surprises from the live-session smoke test.

**Approach:**
- Generate synthetic payloads that match the actual Claude Code shape (captured during the live-session smoke test).
- Loop 100 iterations per hook, collecting wall-clock per iteration.
- Assert p95 < 100ms; print the full distribution on failure.
- Separately, document the live-session smoke: run `claude --plugin-dir .`, exercise each event type, confirm `session-<id>.json` appears, confirm `buddy.json` is untouched (P3-1 writes only session files), confirm no stderr surfaces in the transcript.

**Test scenarios:**
- *Integration:* each hook's p95 is measured and asserted; on regression, the script reports the offending hook and distribution.
- *Integration:* live session exercised manually — SessionStart creates `session-<id>.json`, PostToolUse adds to ring, PostToolUseFailure participates in shared dedup, Stop is silent.

**Verification:** Perf script passes for all four hooks on a clean workstation; live session shows the expected state file and no visible hook output.

## System-Wide Impact

- **Interaction graph:** Adds the *first* runtime writer into `session-<id>.json`. P2's status line and P1-3's slash commands are the existing readers; after P3-1, a status-line read can race a hook write for the same session. `state.sh`'s atomic-rename semantics already cover this, but worth re-verifying in Unit 7's smoke test.
- **Error propagation:** Every hook exits 0 internally. `error.log` is the new failure surface — must be created if missing, append-only, never block on write. Stderr from sourced libraries is swallowed (redirected to `error.log` or `/dev/null`) so it can never surface to the Claude transcript.
- **State lifecycle risks:** (1) Orphan session files from dead sessions — already swept by `state_cleanup_orphans` on next SessionStart. (2) Ring-buffer truncation is a jq one-liner — must verify it preserves insertion order and not rely on jq's `unique` (which sorts). (3) A `session-<id>.json` written by an older plugin version has no `schemaVersion` field today (the umbrella plan shows one in the data model but `session_save` does not stamp it). Decision for P3-1: stamp `schemaVersion: 1` on every session-state write so we have the upgrade seam for P4+ without retrofit. Non-breaking because readers today (`session_load`) ignore unknown fields.
- **API surface parity:** No user-visible surface changes in P3-1 — no new slash commands, no new status-line states, no new config keys. The only new file type is `session-<id>.json` which already existed as a design artifact. `hooks/hooks.json` is new to the plugin but is a plugin-framework file, not a user API.
- **Integration coverage:** A real Claude Code session is the only way to validate that the hook payload shape matches our parser. Unit 7 owns this.
- **Unchanged invariants:** `buddy.json` is untouched by P3-1 (no writes, no reads beyond `buddy_load`'s sentinel check). The plugin's existing slash commands, status line, and hatch roller are not modified. `state.sh` is not modified — it already exposes every primitive P3-1 needs. `settings.json` remains unchanged.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Claude Code hook payload shape differs from our assumption (e.g., `session_id` nested instead of top-level). | Unit 7 live-session smoke test captures actual payloads first; implementation of Units 2–5 uses those captures. If the shape surprises us (e.g., no top-level `session_id`), log it via `ce:compound` and update Unit 1's `hook_extract_session_id`. |
| `state_cleanup_orphans` runs too long on a large `${CLAUDE_PLUGIN_DATA}` and blows the 100ms budget for `SessionStart`. | Measured in Unit 7. If p95 regresses, wrap in `timeout 1` and log-and-continue on timeout; orphan sweep is best-effort anyway. |
| Ring-buffer update jq filter unintentionally sorts (using `unique` instead of first-seen dedup). | Unit 3's "eviction" test asserts insertion order; the test fails loudly on any re-ordering regression. |
| PostToolUseFailure payload is a subset of PostToolUse (missing `tool_call_id`). | Unit 4 tests the missing-field path; if the payload genuinely lacks an ID, we treat the event as undedupable and skip the ring update but still log. Documented in ce:compound if observed. |
| New `hooks/` directory requires a full Claude Code restart; iteration loop slows during development. | Documented in `claude-code-plugin-scaffolding-gotchas-2026-04-16.md`; dev workflow assumes restart after the first scaffolding commit. |

## Documentation / Operational Notes

- Update `docs/roadmap/P3-1-hook-wiring.md`: flip `status: todo` → `in-progress` at start, `done` at end; fill the Notes section with measured p95 figures and any live-session surprises.
- No README updates needed — hooks are invisible to the user in P3-1.
- If the live-session smoke test surfaces anything worth documenting (payload shape, unexpected event semantics, cross-hook ordering), escalate through `/compound-engineering:ce-compound` to `docs/solutions/`.

## Sources & References

- **Ticket:** [docs/roadmap/P3-1-hook-wiring.md](../roadmap/P3-1-hook-wiring.md)
- **Umbrella plan:** [docs/plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md](./2026-04-16-001-feat-claude-buddy-plugin-plan.md) §P3.1, §Interaction Graph, §API Surface Parity, §State Lifecycle Risks
- **Brainstorm:** [docs/brainstorms/2026-04-16-claude-buddy-plugin-requirements.md](../brainstorms/2026-04-16-claude-buddy-plugin-requirements.md) R4
- **State library:** `scripts/lib/state.sh` — `buddy_load`, `session_load`, `session_save`, `state_cleanup_orphans`, sentinels, session-id validator.
- **Reference renderer:** `statusline/buddy-line.sh` — structural template for "source state.sh, sentinel-switch, drain stdin, exit 0."
- **Institutional learnings:**
  - [bash-state-library-patterns-2026-04-18.md](../solutions/best-practices/bash-state-library-patterns-2026-04-18.md)
  - [bash-subshell-state-patterns-2026-04-19.md](../solutions/best-practices/bash-subshell-state-patterns-2026-04-19.md)
  - [bash-jq-tsv-null-field-collapse-2026-04-20.md](../solutions/best-practices/bash-jq-tsv-null-field-collapse-2026-04-20.md)
  - [claude-code-plugin-scaffolding-gotchas-2026-04-16.md](../solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md)
  - [claude-code-skill-dispatcher-pattern-2026-04-19.md](../solutions/developer-experience/claude-code-skill-dispatcher-pattern-2026-04-19.md)
- **External:** [Claude Code hooks reference](https://code.claude.com/docs/en/hooks)
