---
title: Claude Buddy Plugin — gacha hatch + Tamagotchi evolution
type: feat
status: active
date: 2026-04-16
origin: docs/brainstorms/2026-04-16-claude-buddy-plugin-requirements.md
---

# Claude Buddy Plugin — gacha hatch + Tamagotchi evolution

A Claude Code plugin that **extends Anthropic's built-in `/buddy`** (shipped April 1, 2026 in Claude Code v2.1.90) with a gacha-hatched, Tamagotchi-style-evolving companion. The built-in `/buddy` is deterministic and static; this plugin layers **random hatch + behavior-driven evolution + earned reroll tokens** on top of that concept — the distinct product value is the evolution loop that Anthropic's version doesn't have.

Origin: [docs/brainstorms/2026-04-16-claude-buddy-plugin-requirements.md](../brainstorms/2026-04-16-claude-buddy-plugin-requirements.md). Key decisions carried forward: **gacha hatch + Tamagotchi evolution (hybrid)**, **global single active buddy**, **pure-growth progression (no death/devolve)**, **reroll via earned tokens**, **status line + hook reactions hybrid surface**. All ten requirements R1–R10 from the origin document are reflected in the acceptance criteria and phases below.

## Overview

Claude Buddy is delivered as a Claude Code plugin with four surfaces:

- **Slash commands** for hatching, status, and admin (`/buddy`, `/buddy hatch`, `/buddy reset`) — implemented as a SKILL.md under `skills/`.
- **Status line script** rendering the buddy ambiently on every assistant turn (`statusline/buddy-line.sh`).
- **Hook scripts** listening for `PostToolUse`, `PostToolUseFailure`, `Stop`, and `SessionStart` events to post in-character commentary and accumulate evolution signals.
- **Persistent state** in `${CLAUDE_PLUGIN_DATA}/buddy.json` (durable, survives plugin updates) plus `session.json` (ephemeral rate-limit bookkeeping).

The rollout is sequenced as nine phases (P0–P8) that each stand alone as a ticket-sized unit of work. The product is playable after P3 (scaffolding + hatch + status line + canned commentary); P4–P8 deliver the evolution loop, token economy, LLM commentary, the full 18-species roster, and polish.

## Problem Statement

Anthropic's built-in `/buddy` is delightful but static. The user ID is hashed and fed through a PRNG to determine species, rarity, stats, eyes, and hat — one buddy per user, forever, with no progression. Community plugins like [1270011/claude-buddy](https://github.com/1270011/claude-buddy) and [cpaczek/any-buddy](https://github.com/cpaczek/any-buddy) have already shipped *around* this (preserving buddies across updates, letting you hack which buddy you get), but **none add the progression layer a Tamagotchi-style pet wants**: behavior-driven growth, visible evolution, and the gentle tension of rerolling a buddy you've grown attached to.

The target user is any Claude Code user who found `/buddy` charming and wants a reason to come back to it — a companion that reflects *their* coding patterns over time, and a reroll loop with enough stakes that choices feel meaningful.

## Proposed Solution

Ship a plugin named **`buddy`** (resolved 2026-04-16 — see Naming Decision below) — built on Claude Code's documented plugin primitives:

1. **Gacha hatch on `/buddy hatch`.** Random species (5 at launch, scaling to 18), rarity roll (60% Common / 25% Uncommon / 10% Rare / 4% Epic / 1% Legendary — matching Anthropic's proven distribution), stats rolled per rarity floor, canned name in P1 upgraded to LLM-generated name in P6. The hatch is **non-deterministic** (seeded from `crypto.randomBytes`) — this is an explicit product break from built-in `/buddy`'s user-ID determinism, because we need randomness for the gacha loop to matter.
2. **Global single-buddy persistence** in `${CLAUDE_PLUGIN_DATA}/buddy.json`. Survives plugin updates; explicit lifecycle contract documented (see State Lifecycle Risks below).
3. **Ambient status line** showing species icon, name, form/level, and a short speech bubble.
4. **Hook-driven commentary** wired to `PostToolUse`, `PostToolUseFailure`, `Stop`, and `SessionStart`. Rate-limited via event-novelty gating + exponential backoff on same-category events + per-session budget.
5. **Tamagotchi evolution** driven by four behavior axes tracked cumulatively: **consistency** (active-day streak), **variety** (distinct tools used), **quality** (successful-edit ratio), **chaos** (errors, repeated edits to same file). Dominant axis selects which of 2–3 evolution paths per species the buddy follows. Pure growth — no devolve, no death.
6. **Reroll economy** — earn 1 token per active session-hour (capped 3/day on a rolling 24h window), plus milestone bonuses; reroll costs 10 tokens. Rerolling wipes the current buddy's level/form/signals but keeps token balance.

### Naming Decision (resolved 2026-04-16)

- **Plugin name**: `buddy`
- **Skill name**: `buddy` — invoked as `/buddy`, with the fully-qualified `/buddy:buddy` as fallback if Anthropic's built-in takes precedence.
- **GitHub slug**: deferred to publication time; namespaced slug (`<user>/buddy` or similar) avoids the `1270011/claude-buddy` collision.

The plugin name `buddy` side-steps the `1270011/claude-buddy` GitHub slug collision directly (different name, not just different owner). The slash-command collision with Anthropic's built-in `/buddy` remains — Claude Code's resolution order between built-in and plugin-provided identically-named commands is not publicly documented, so P0's first verification task is to empirically test which wins. If the built-in always shadows the plugin, users invoke as `/buddy:buddy`; README documents behavior.

## Technical Approach

### Architecture

```
claude-buddy/                          # dev dir (repo name)
├── .claude-plugin/
│   └── plugin.json                    # manifest: name=buddy, version, description
├── skills/
│   └── buddy/
│       └── SKILL.md                   # slash command logic (LLM-interpreted)
├── hooks/
│   ├── hooks.json                     # event wiring
│   ├── post-tool-use.sh               # commentary + signal accumulation
│   ├── post-tool-use-failure.sh       # error-specific commentary + chaos++
│   ├── stop.sh                        # session-summary commentary + XP tick
│   └── session-start.sh               # init session.json, reset rate-limit window
├── statusline/
│   └── buddy-line.sh                  # reads buddy.json, prints 1-line (later 5-line)
├── scripts/
│   ├── lib/
│   │   ├── state.sh                   # atomic read/write + flock + migrate
│   │   ├── rng.sh                     # rarity/species/stat rolls
│   │   ├── commentary.sh              # line selection + rate limiting
│   │   └── evolution.sh               # signal tracking + form transitions
│   └── species/                       # per-species data
│       ├── axolotl.json               # voice, base stats, evolution paths, line bank
│       ├── dragon.json
│       ├── owl.json
│       ├── ghost.json
│       └── capybara.json
├── settings.json                      # statusLine config
├── README.md
└── docs/
    ├── brainstorms/
    │   └── 2026-04-16-claude-buddy-plugin-requirements.md  # origin
    ├── plans/
    │   └── 2026-04-16-001-feat-claude-buddy-plugin-plan.md  # this file
    └── roadmap.md                      # checkbox tracker, generated after plan approval
```

**Implementation language**: Bash for hooks/status line (lowest install friction, no runtime deps), species data + schemas in JSON (trivial to diff-review). If commentary generation gets complex in P6, a small Node or Python helper under `scripts/` is an escape hatch — decided in P6, not before.

### Data Model

**`${CLAUDE_PLUGIN_DATA}/buddy.json`** (durable, single active buddy):

```json
{
  "schemaVersion": 1,
  "hatchedAt": "2026-04-16T10:30:00Z",
  "lastRerollAt": null,
  "buddy": {
    "id": "uuid-v4",
    "name": "Pip",
    "species": "axolotl",
    "rarity": "rare",
    "shiny": false,
    "stats": {
      "debugging": 42,
      "patience": 78,
      "chaos": 12,
      "wisdom": 65,
      "snark": 30
    },
    "form": "base",
    "level": 1,
    "xp": 0,
    "signals": {
      "consistency": { "streakDays": 0, "lastActiveDay": "2026-04-16" },
      "variety": { "toolsUsed": [] },
      "quality": { "successfulEdits": 0, "totalEdits": 0 },
      "chaos": { "errors": 0, "repeatedEditHits": 0 }
    }
  },
  "tokens": {
    "balance": 0,
    "earnedToday": 0,
    "windowStartedAt": "2026-04-16T10:30:00Z"
  },
  "meta": {
    "totalHatches": 1,
    "pityCounter": 0
  }
}
```

**`${CLAUDE_PLUGIN_DATA}/session.json`** (ephemeral, per-Claude-Code-session rate-limit state):

```json
{
  "sessionId": "uuid-from-hook-payload",
  "startedAt": "2026-04-16T10:30:00Z",
  "commentsThisSession": 2,
  "lastEventType": "PostToolUse",
  "lastCommentAt": "2026-04-16T10:31:12Z",
  "cooldowns": {
    "PostToolUse": "2026-04-16T10:36:12Z",
    "PostToolUseFailure": null,
    "Stop": null
  }
}
```

**`schemaVersion`** is load-bearing: every read goes through a migrator. Adding `schemaVersion` from day one is a ~5-line commitment that saves a painful retrofit later (see System-Wide Impact → Failure Propagation).

**Atomic writes**: every state write goes `write-to-buddy.json.tmp` → `rename`. Combined with `flock`-based advisory locks (held during read-modify-write), this gives safe multi-session behavior on POSIX filesystems.

### Key Design Decisions

**D1. Stats are LLM prompt dimensions, not gameplay levers** (resolves origin-doc R10 deferred question — see [origin](../brainstorms/2026-04-16-claude-buddy-plugin-requirements.md)).
Mirror Anthropic's approach: the 5 stats (DEBUGGING, PATIENCE, CHAOS, WISDOM, SNARK) shape *how* the buddy talks — fed as prompt dimensions to the commentary LLM in P6, and used as ranked lookup keys into species line banks in P3. They do **not** affect XP gain, token earn rate, or commentary frequency. This keeps the mental model simple, matches `/buddy`'s pattern users already understand, and avoids creating a stat-min-maxing meta.

**D2. Multi-axis evolution signals to prevent gaming** (resolves R5).
Single-axis signals (Pokémon friendship) are trivial to grind. Four axes tracked cumulatively:
- **Consistency** — active-day streak (days with ≥1 recorded event). Hardest to game because it requires real elapsed time.
- **Variety** — distinct tool types used in the last 7 active days. Rewards exploration over repetition.
- **Quality** — ratio of successful edits (PostToolUse) to failed edits (PostToolUseFailure). Proxies for "you're writing code that works."
- **Chaos** — error count + repeated-edit-to-same-file counter. Not bad — just different. Feeds Chaos-form evolutions.

Dominant axis at level thresholds (e.g., Lv 10) selects the evolution path. Ties break by a seeded species preference (dragons lean Chaos, owls lean Variety, etc.).

**D3. Rate-limit strategy** (resolves R4): three-layer stack.
1. **Event-novelty gating**: skip commentary if the event type matches `session.lastEventType` (suppresses "you did another Edit... and another...").
2. **Exponential backoff per event type**: first fire immediately, second after 5 min cooldown, third after 15 min, flat 15 min thereafter.
3. **Per-session budget**: default 8 comments per session, user-configurable via `userConfig.commentsPerSession` in `plugin.json`.

**D4. Hatch randomness, not determinism** (resolves R1 — explicit departure from built-in `/buddy`).
Seed each hatch from `crypto.randomBytes(16)`. The built-in `/buddy` is deterministic on user ID specifically so that *everyone gets a buddy without the app storing anything*. We're already storing state (necessary for evolution), so we trade determinism for the gacha loop.

**D5. Slash command state machine with explicit pre-hatch state** (resolves spec-flow gap #3).
Every surface defines behavior for four distinct states:

| State | `/buddy` | `/buddy hatch` | `/buddy reset` | Status line | Hooks |
|---|---|---|---|---|---|
| `NO_BUDDY` (first install, or post-reset) | "No buddy yet. Run `/buddy hatch` to hatch one." | Roll + persist | "No buddy to reset." | `🥚 No buddy — /buddy hatch` | Silent |
| `ACTIVE` + enough tokens | Show full status | Prompt reroll via `--confirm` flag | Prompt wipe via `--confirm` | Show buddy | Fire normally |
| `ACTIVE` + not enough tokens | Show full status | Reject with "Need N more tokens" | Prompt wipe via `--confirm` | Show buddy | Fire normally |
| `CORRUPT` (unparseable state) | "Buddy state needs repair. Run `/buddy reset` or restore from backup." | Reject | Wipe | `⚠️ /buddy reset` | Silent |

Confirmation is **flag-based** (`/buddy hatch --confirm`) because SKILL.md slash commands cannot reliably do mid-execution interactive prompts. First run of `/buddy hatch` without `--confirm` prints the consequences and next-step command.

**D6. Token accrual starts at first hatch, not at install** (resolves spec-flow gap #3 extension).
Pre-hatch: no token accumulation, no commentary, no hook work. `SessionStart` does a cheap state check and early-exits on `NO_BUDDY`. This prevents weirdness from users who install and ignore for weeks.

**D7. Atomic writes + flock for concurrent sessions** (resolves spec-flow gap #1).
Every write: acquire `flock -x` on buddy.json, read, modify in memory, write to `.tmp`, rename, release lock. This is the simplest correct answer for POSIX and matches what battle-tested CLI tools do. Flock is built-in on Linux/macOS.

**D8. Pseudo-pity from day one** (resolves spec-flow gap #8 partially).
Track `meta.pityCounter` in buddy.json (increments on each Common-only hatch, resets on Rare+). At `pityCounter = 10`, next hatch guarantees Rare+. Prevents the worst tail of the rarity distribution from being a user-hostile experience.

### Implementation Phases (the roadmap)

Each phase is a ticket-sized unit of work with explicit entry and exit criteria. Phases P0–P3 deliver a playable plugin; P4 unlocks the core differentiator (evolution); P5–P8 are polish and depth.

---

#### **P0 — Plugin scaffolding** *(1 ticket)*

**Goal**: prove the plugin installs and a slash command runs end-to-end.

- [ ] `.claude-plugin/plugin.json` with `name: "buddy"`, `version: "0.1.0"`, `description`, no `userConfig` yet.
- [ ] `skills/buddy/SKILL.md` with minimal frontmatter + instructions to greet. Returns "Hi, I'm your buddy."
- [ ] `settings.json` stub with `statusLine` commented out.
- [ ] `README.md` with install instructions (`claude plugin install .`).
- [ ] Empirically verify `/buddy` resolution order vs Anthropic's built-in; document behavior in README.
- [ ] Manual verification: `claude --plugin-dir .` installs the plugin; `/buddy` (and `/buddy:buddy` fallback) returns greeting.

**Exit criteria**: plugin installs and `/buddy` (however namespaced) prints a greeting. No state yet.

---

#### **P1 — Hatch & persistence** *(3 tickets)*

**P1.1 — State primitives** *(ticket)*

- [ ] `scripts/lib/state.sh` with: `buddy_load`, `buddy_save`, `session_load`, `session_save`. All writes go through tmp+rename + `flock` on buddy.json.
- [ ] `schemaVersion: 1` in every write. `buddy_load` runs `migrate` which is a no-op at v1 but establishes the pattern.
- [ ] Corruption handling: `buddy_load` on parse failure returns `NO_BUDDY` and logs a one-time warning to stderr.
- [ ] Unit tests (bats or plain shell) for: fresh install, round-trip read/write, concurrent-writer simulation, corrupt JSON recovery.

**P1.2 — Hatch roller** *(ticket)*

- [ ] `scripts/lib/rng.sh` with `roll_rarity`, `roll_species`, `roll_stats`, `roll_name`. Seeded from `/dev/urandom`.
- [ ] Rarity distribution: 60/25/10/4/1 (Common/Uncommon/Rare/Epic/Legendary) matching Anthropic's proven split ([findskill.ai source](https://findskill.ai/blog/claude-code-buddy-guide/)).
- [ ] Stat floors per rarity: Common 5, Uncommon 15, Rare 25, Epic 35, Legendary 50 (remaining 0–100 range filled stochastically with "one peak, one dump, three mid" pattern matching `/buddy` — see [claudefa.st](https://claudefa.st/blog/guide/mechanics/claude-buddy)).
- [ ] Starting roster (5 species, one distinct voice each):
  - **Axolotl** — wholesome-cheerleader
  - **Dragon** — chaotic-gremlin
  - **Owl** — dry-scholar
  - **Ghost** — deadpan-night
  - **Capybara** — chill-zen
- [ ] Name pool: 20 canned names per species in P1 (e.g., Pip, Bean, Spud, Mochi…). LLM-generated names come in P6.
- [ ] Pity counter logic: increment on Common, reset on Rare+.

**P1.3 — Slash command logic** *(ticket)*

- [ ] `skills/buddy/SKILL.md` implements the state machine from D5:
  - `/buddy` → show status (NO_BUDDY / ACTIVE / CORRUPT).
  - `/buddy hatch` (no args, NO_BUDDY state) → roll + persist.
  - `/buddy hatch` (no args, ACTIVE state) → describe reroll consequences, require `--confirm`.
  - `/buddy hatch --confirm` (ACTIVE, enough tokens) → deduct tokens, reset signals/level/form, roll new species.
  - `/buddy hatch` (ACTIVE, insufficient tokens) → reject with "Need N more tokens."
  - `/buddy reset` → describe consequences, require `--confirm`.
  - `/buddy reset --confirm` → wipe buddy.json (keep nothing; treat as NO_BUDDY).
- [ ] Manual script wrappers in `scripts/` that SKILL.md instructs Claude to call (`scripts/hatch.sh`, `scripts/reset.sh`, `scripts/status.sh`) so slash-command logic is actually shell, not LLM interpretation.

**Exit criteria**: `/buddy hatch` produces a persisted buddy. `/buddy` shows it. `/buddy reset --confirm` wipes it. Round-trips survive Claude Code restart.

---

#### **P2 — Status line** *(1 ticket)*

- [ ] `statusline/buddy-line.sh` reads stdin (ignores Claude Code's status payload for now), loads buddy.json, prints one line:
  - `NO_BUDDY` → `🥚 No buddy — /buddy hatch`
  - `ACTIVE` → `🦎 Pip (Rare Axolotl · Lv.3) · 4 🪙`
  - `CORRUPT` → `⚠️ buddy state needs /buddy reset`
- [ ] Plugin's `settings.json` registers `statusLine.type: "command"` with `refreshInterval: 5`, padding 1.
- [ ] ANSI color per rarity (grey Common → gold Legendary); shiny flag swaps to rainbow once shiny exists (P7).
- [ ] Gracefully handle missing `${CLAUDE_PLUGIN_DATA}` — treat as NO_BUDDY.
- [ ] Width-safe: if status line width < 40 cols, drop the speech-bubble segment.

**Exit criteria**: buddy is visible in the status bar on every assistant turn. No speech bubble yet — commentary is P3.

---

#### **P3 — Commentary v1 (canned)** *(2 tickets)*

**P3.1 — Hook wiring + session init** *(ticket)*

- [ ] `hooks/hooks.json` registers:
  - `SessionStart` → `session-start.sh` (init session.json, reset cooldowns, set `lastEventType=null`).
  - `PostToolUse` → `post-tool-use.sh`.
  - `PostToolUseFailure` → `post-tool-use-failure.sh`.
  - `Stop` → `stop.sh`.
- [ ] All hook scripts early-exit on NO_BUDDY. Target p95 runtime < 100ms (load state, check cooldown, maybe print).
- [ ] Commentary output: stdout with exit code 0 (appears in transcript as system message per [hooks docs](https://code.claude.com/docs/en/hooks)).

**P3.2 — Commentary engine** *(ticket)*

- [ ] `scripts/lib/commentary.sh` implements the rate-limit stack (D3): event-novelty gate → exponential backoff per event type → per-session budget.
- [ ] Line banks: 50+ lines per species in `scripts/species/<name>.json` under keys like `line_banks.PostToolUse.default`, `line_banks.PostToolUseFailure.default`, `line_banks.Stop.default`, plus rare "milestone" banks (first edit of session, long session, etc.).
- [ ] Line selection: shuffle-bag (no repeats until bank exhausted) per event type.
- [ ] `userConfig.commentsPerSession` (default 8) in `plugin.json` for user control.

**Exit criteria**: buddy chimes in ≤ 8 times per session with on-brand lines that don't feel spammy. Rate-limit obeys cooldowns under burst traffic (stress test: 100 tool uses in 60 seconds produce ≤ 3 comments).

---

#### **P4 — Evolution v1** *(2 tickets)*

**P4.1 — XP + signal accumulation** *(ticket)*

- [ ] Each hook increments relevant fields in `buddy.json.signals`:
  - `PostToolUse` → `variety.toolsUsed` (append unique), `quality.successfulEdits++` when tool is Edit/Write, `consistency.streakDays` updated if new day.
  - `PostToolUseFailure` → `chaos.errors++`, `quality.totalEdits++`.
  - `Stop` → XP tick (base + bonuses for session length, streak).
- [ ] XP curve: `xpForLevel(n) = 50 * n * (n + 1)` — Lv 2 at 100 XP, Lv 5 at 750, Lv 10 at 2750. Tunable.
- [ ] All signal writes go through the flock'd state API (D7).

**P4.2 — Form transitions** *(ticket)*

- [ ] Each species has 2–3 evolution paths defined in `scripts/species/<name>.json` under `evolution_paths`. Minimum per species: `base` → `{path1, path2}` at Lv 10.
- [ ] Path selection at Lv 10: highest-signal axis over the past N active days determines form. Ties break by species preference.
- [ ] Transitions trigger a one-time "evolution ceremony" comment (surprise budget bypass).
- [ ] Status line and commentary banks switch to the new form's variants.

**Exit criteria**: a user who codes actively for ~a week can see their buddy reach Lv 10 and evolve into a different form. Different behavior patterns produce different forms on fresh buddies of the same species.

---

#### **P5 — Reroll token economy** *(1 ticket)*

- [ ] Token accrual in `stop.sh`: +1 per active session-hour, capped at 3 per rolling 24h window (window starts at first earn, not midnight). Window reset logic stored in `tokens.windowStartedAt`.
- [ ] Milestone bonuses: +2 on first evolution, +5 on shiny hatch (once shiny exists in P7). Bonuses bypass the daily cap but trigger once-per-buddy.
- [ ] Reroll cost: 10 tokens (configurable via `userConfig.rerollCost`).
- [ ] Insufficient-token UX: `/buddy hatch` on insufficient-token state prints "You have N tokens; reroll costs 10. Earn 1 per active-session-hour."
- [ ] Max-level XP: continues to accrue into a rollover pool (no capping weirdness); visible only via `/buddy` detail view.

**Exit criteria**: a committed user can reroll after ~10 active session-hours. Insufficient-token and at-cap cases are clearly messaged. Token balance survives reroll (only evolution state resets).

---

#### **P6 — LLM commentary v2 (contextual)** *(1 ticket)*

- [ ] Replace canned-line selection in `commentary.sh` with an LLM call. Delivery mechanism: `prompt`-type hook ([hooks docs](https://code.claude.com/docs/en/hooks)) OR a small dedicated subagent — pick during this ticket based on latency testing.
- [ ] Prompt template includes: species voice, current form, 5 stats, recent event payload summary, last 3 comments (to avoid self-repetition), session mood tags.
- [ ] Fallback on timeout (>2s) or error: pick a canned line. LLM calls must never block the transcript.
- [ ] LLM-generated names at hatch (upgrade from canned pool — matching `/buddy`'s "bones are deterministic, soul is LLM-generated once" pattern per [claudefa.st](https://claudefa.st/blog/guide/mechanics/claude-buddy)).

**Exit criteria**: commentary references what you actually just did (e.g., "third rewrite of `auth.ts`, bold choice") more often than not, falls back gracefully under LLM failure.

---

#### **P7 — Scale roster + sprites** *(2 tickets)*

**P7.1 — 18-species roster** *(ticket)*

- [ ] Expand `scripts/species/` to 18 species matching `/buddy`'s roster (per [findskill.ai](https://findskill.ai/blog/claude-code-buddy-guide/)): Duck, Goose, Cat, Rabbit, Owl, Penguin, Turtle, Snail, Dragon, Octopus, Axolotl, Ghost, Robot, Blob, Cactus, Mushroom, Chonk, Capybara.
- [ ] Each new species: archetype voice, evolution paths, ≥50 canned lines per event bank.

**P7.2 — Full ASCII sprites** *(ticket)*

- [ ] 5-line × 12-char × 3-frame ASCII sprite per species per form (matching `/buddy`'s proven format per [claudefa.st](https://claudefa.st/blog/guide/mechanics/claude-buddy)).
- [ ] Status line switches to multi-line rendering when terminal supports it (>= 5 lines of `statusLine` output).
- [ ] Shiny variants: ~1/256 post-rarity-roll; rainbow ANSI frame in status line.
- [ ] `refreshInterval: 1` for animation cadence, with graceful fallback for narrow terminals.

**Exit criteria**: full 18 species hatchable; status line animates; shinies are real rare treats.

---

#### **P8 — Polish & extras** *(1 ticket)*

- [ ] `/buddy stats` sub-command for detailed stat + signal breakdown.
- [ ] Optional `/buddy feed` daily engagement hook (feeds buddy once per calendar day for a small XP bump).
- [ ] Pseudo-pity counter made visible in `/buddy stats`.
- [ ] `--verbose` flag on `/buddy` for migration logs, schema version, data dir path.
- [ ] Documentation: README with GIFs, species rarity chart, evolution-path cheatsheet.
- [ ] Optional: marketplace publication (see Dependencies).

**Exit criteria**: plugin is shipable/shareable; no known UX cliffs.

---

## Alternative Approaches Considered

**A1. Fork/patch Anthropic's built-in `/buddy`.** Rejected — origin doc explicitly scopes this out ("Not a replacement or fork"). Also fragile against Claude Code updates (community plugin `any-buddy` has to re-apply patches on every update via SessionStart hooks per [its repo](https://github.com/cpaczek/any-buddy) — painful).

**A2. MCP server architecture** (like `1270011/claude-buddy` and `cpaczek/any-buddy` both use). Considered — MCP gives richer tool affordances. Rejected for v1 because: (a) bash scripts + SKILL.md are lower-complexity and lower-install-friction, (b) all our surfaces (slash command, hooks, status line) map cleanly to plugin primitives without needing MCP, (c) we can add an MCP server later if richer agent interactions emerge. Revisit at P6 if LLM commentary benefits from server-side state.

**A3. Per-project buddies.** Rejected in brainstorm — origin R2 decides global. Keeping here only to note we considered it and might revisit post-P8 as a "stable of project-specific buddies" in a separate brainstorm.

**A4. Stats as full gameplay levers (option (c) from brainstorm R10).** Rejected in D1 — creates a stat-min-maxing meta that distracts from the buddy's personality being the point.

**A5. Deterministic seeded hatch like `/buddy`** (resolves R1 deferred question). Rejected — deterministic hatch precludes the gacha loop. We're already storing state (required for evolution), so the privacy/zero-state argument doesn't apply.

## System-Wide Impact

### Interaction Graph

```
User runs a tool (e.g., Edit)
  └─ Claude Code fires PostToolUse hook
      └─ scripts/hooks/post-tool-use.sh runs
          ├─ acquires flock on buddy.json
          ├─ reads session.json (cooldown check)
          ├─ if passes: picks a line from species line bank, prints to stdout
          ├─ updates signals (variety.toolsUsed, quality.successfulEdits++)
          ├─ updates session.json (lastEventType, cooldown, commentsThisSession)
          ├─ writes buddy.json.tmp, rename to buddy.json
          └─ releases flock
             └─ hook exit 0: stdout surfaces in transcript as system message
                └─ status line script re-runs (debounced 300ms after assistant turn)
                   └─ reads buddy.json, re-renders 1-line state
```

The critical chain is **hook → flock'd state write → status line re-render**. Each step is bounded in duration (<100ms target). No step recursively triggers another hook.

### Error & Failure Propagation

| Layer | Failure | Behavior |
|---|---|---|
| State read | Malformed JSON | `buddy_load` returns `NO_BUDDY`, prints one-time warning to stderr; hooks early-exit silently. User sees `⚠️ /buddy reset` in status line. |
| State read | `${CLAUDE_PLUGIN_DATA}` missing | Treated as NO_BUDDY; state initializes on next successful write. |
| State write | Disk full / tmp rename fails | Error written to stderr; buddy.json untouched (atomic); hook exits 0 so Claude session is unaffected. |
| Hook script | Script crashes / times out | Hook exits 2 (stderr fed back to Claude). No user-facing buddy action, but also no session breakage. Log line in `${CLAUDE_PLUGIN_DATA}/error.log`. |
| Commentary LLM (P6) | Timeout > 2s or API error | Fall back to canned line from species bank. Never blocks transcript. |
| flock contention | Two sessions write simultaneously | Second waits up to 200ms for lock; on timeout, skips the write (the event increment is lost — acceptable for XP; we log for auditability). |
| Schema mismatch | v2 client reads v1 state | Migrator runs on load; un-migratable states surface as CORRUPT with `/buddy reset` prompt. |

**Key principle: a buddy plugin bug must never break the Claude Code session.** Every hook exits 0 on internal failure and writes to its own error log.

### State Lifecycle Risks

| Risk | Mitigation |
|---|---|
| Orphaned tmp files after crash mid-write | `session-start.sh` sweeps `${CLAUDE_PLUGIN_DATA}/*.tmp` older than 1 hour. |
| Signal double-counting if hook fires twice | Hook payload includes a tool-call ID; session.json tracks last 20 IDs; duplicates skipped. |
| Evolution state corruption after partial reroll | Reroll is a single atomic write: new buddy + preserved tokens + reset signals/level in one transaction. |
| Uninstall data lifecycle | Data in `${CLAUDE_PLUGIN_DATA}` persists across plugin updates per [plugins-reference](https://code.claude.com/docs/en/plugins-reference) but **is deleted on full uninstall unless `--keep-data` is used**. README explicitly documents this contract; `/buddy reset --export` (P8) offers a one-line state dump users can save before uninstall. |
| Clock skew between hooks | All timestamps use ISO-8601 UTC; relative windows (cooldowns, 24h token cap) use monotonic `date +%s` for robustness. |

### API Surface Parity

The plugin primitives this plugin touches:

| Surface | Used in phases | Notes |
|---|---|---|
| `skills/<name>/SKILL.md` (slash command) | P0–P1 onward | Free-text args (`/buddy hatch --confirm`) interpreted by SKILL.md instructions per [skills docs](https://code.claude.com/docs/en/skills). |
| `hooks/hooks.json` (event hooks) | P3 onward | `PostToolUse`, `PostToolUseFailure`, `Stop`, `SessionStart`. No `PreToolUse` (we don't want to gate any tool). |
| `settings.json` → `statusLine` (status line) | P2 onward | `type: "command"`, `refreshInterval: 5` initially, dropping to 1 in P7 for animation. |
| `${CLAUDE_PLUGIN_DATA}` (persistent state) | P1 onward | Survives updates; documented contract. |
| `userConfig` (manifest) | P3 onward | Expose `commentsPerSession`, `rerollCost`, later tokens-per-hour. |
| `bin/` (PATH extension) | Not used | No need for externally-invokable tools. |
| `.mcp.json` (MCP server) | Not used in P0–P8 | A P6 decision point; MCP currently not required. |

No other plugin feature set needs parallel updates — this plugin is self-contained.

### Integration Test Scenarios

(Scenarios unit tests with mocks would miss.)

1. **Two concurrent Claude Code sessions** each fire 50 PostToolUse hooks in 30 seconds → final `buddy.json.signals.quality.totalEdits` equals 100 (no lost increments). Flock correctness check.
2. **Session start → hatch → 5 tool uses → kill -9 Claude Code → restart** → buddy is still there, level/XP/signals match what should have accumulated. Persistence + atomic write correctness.
3. **Manually corrupt `buddy.json`** (truncate mid-write) → Claude Code session starts cleanly, status line shows `⚠️ /buddy reset`, hooks silent, slash commands route to CORRUPT state. Graceful degradation.
4. **User hatches Legendary on first try (lucky RNG)** → stat floors at 50+, status line shows gold ANSI, token balance starts at 0. No off-by-one in rarity floor logic.
5. **User evolves buddy to form 2, then rerolls with `/buddy hatch --confirm`** → new species, level 1, all signals zero, token balance = (previous - 10). Milestone bonuses do NOT re-trigger on new buddy.
6. **Plugin version bumps and schema changes from v1 to v2** → existing user's buddy.json migrates on first load, no data loss, schemaVersion=2 after migration. Run against a frozen fixture from v1.
7. **Plugin uninstalled with `--keep-data`, reinstalled** → buddy resurrected at exact prior state. Without `--keep-data`: buddy lost, NO_BUDDY state on reinstall.
8. **Commentary during a 100-tool-use burst in 60 seconds** → ≤ 3 comments (rate-limit honored). Cooldowns observed across events.

## Acceptance Criteria

### Functional (derived from R1–R10)

- [ ] **(R1)** `/buddy hatch` rolls a random buddy with species, rarity, stats, name; rolling again when one exists requires `--confirm` and sufficient tokens.
- [ ] **(R2)** Buddy state persists in `${CLAUDE_PLUGIN_DATA}/buddy.json`; survives Claude Code restart; follows across projects (global).
- [ ] **(R3)** Buddy is visible in the status line on every assistant turn, with name, species, form, level.
- [ ] **(R4)** Buddy comments opportunistically via hooks; ≤ 8 comments per session by default; no comments in NO_BUDDY or CORRUPT state.
- [ ] **(R5)** Buddy evolves through at least 2 distinct paths per species based on dominant behavior axis at Lv 10; evolution is observable (different form, different line bank).
- [ ] **(R6)** No state exists where a buddy devolves, dies, or gets worse. Only growth.
- [ ] **(R7)** Each of the 5 starting species has a distinct, consistent voice.
- [ ] **(R8)** Reroll requires spending 10 tokens; tokens accrue at 1/active-session-hour up to 3/day; rerolling wipes level/form/signals but keeps token balance.
- [ ] **(R9)** `/buddy`, `/buddy hatch`, `/buddy reset` all implemented with flag-based confirmation for destructive operations.
- [ ] **(R10)** Hatched buddies have 5-dim stats (DEBUGGING/PATIENCE/CHAOS/WISDOM/SNARK) visible in `/buddy`; stats measurably influence voice (line-bank selection in P3, LLM prompt dimensions in P6).

### Non-functional

- [ ] Hook scripts p95 latency < 100ms on a cold cache. No hook ever blocks > 2s.
- [ ] No plugin failure mode breaks the Claude Code session (all hooks exit 0 on internal errors; errors go to plugin-local log).
- [ ] Status line renders correctly on terminal widths 40–200 columns.
- [ ] All state writes are atomic (tmp + rename + flock).
- [ ] Schema migrations are backward-compatible through at least 3 versions.

### Quality gates

- [ ] Integration test scenarios 1–8 (above) all pass.
- [ ] Manual play-test: user uninstalls and reinstalls, state survives (with `--keep-data` documented).
- [ ] Each species has ≥ 50 canned lines before P3 ships and a distinct voice per voice-review.

## Success Metrics

**Quantitative**:
- Users run `/buddy hatch` within 60 seconds of plugin install (first-session feel per origin doc).
- ≥ 70% of users who hatch a buddy still have that buddy (not reset or rerolled) after 7 days.
- Median first evolution occurs within ~5 active-session days of hatch (signals feel responsive, not grindy).
- Comment rate settles at 3–6 per active session (not the max of 8) — evidence that rate-limiting is felt, not hit.

**Qualitative**:
- Users refer to their buddy by name in external mentions (Twitter/Discord/GitHub issues).
- Reroll discussions happen ("should I reroll my Rare Owl for a shot at Legendary?") — the gacha tension is real.
- Comments get screenshotted and shared — voice is good enough to be memorable.

## Dependencies & Prerequisites

- Claude Code v2.1.90+ (brings plugin primitives — hooks, status line, plugin data dir).
- POSIX filesystem with `flock` (Linux/macOS). Windows support is a post-P8 consideration.
- User has write access to `${CLAUDE_PLUGIN_DATA}` (resolves to `~/.claude/plugins/data/<id>/` on install; auto-created).
- **No** API key requirement for P0–P5. **P6+** may use LLM calls; if those happen via `prompt`-type hooks they ride Claude Code's existing auth, no new API key needed.
- Marketplace publication (P8 optional) needs a GitHub repo; no Anthropic review pipeline known to be required.

## Risk Analysis & Mitigation

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| `/buddy` slash command collides with Anthropic's built-in and fails silently | High (ship-blocker) | Medium | P0's first verification task empirically tests resolution order; document behavior in README; fall back to unambiguous `/buddy:buddy` if the built-in always wins. |
| Concurrent session writes corrupt state | Medium (data loss) | Medium | Flock + atomic writes (D7); covered by integration test 1. |
| LLM commentary in P6 introduces latency that feels bad | Medium (UX) | Low–Medium | 2s hard timeout → canned fallback; measure p95 before shipping P6. |
| Anthropic changes `/buddy` or the plugin API between now and ship | Medium (rework) | Medium | Pin to Claude Code v2.1.90 in README; subscribe to [changelog](https://code.claude.com/docs/en/changelog). |
| Rate limiting still feels spammy | Medium (users disable) | Low | User-configurable `commentsPerSession`; default is conservative (8); telemetry via opt-in in P8. |
| 60/25/10/4/1 rarity feels too stingy (Legendary 1% disappointing) | Low | Low | Pseudo-pity from day one (D8); re-tune after P5 based on user feedback. |
| Users lose buddy on uninstall without warning | Medium (trust) | Medium | Document in README; `/buddy reset --export` in P8 lets users back up state. |
| Schema migration bug loses data for v1 users when v2 ships | High | Low | Migrations are tested against frozen fixtures; schemaVersion from day one (D6 — the insurance policy). |

## Future Considerations

Explicitly out of scope for this plan (deferred to future brainstorms, per origin doc's source-of-truth rule):

- Per-project buddies / multi-buddy stable / Pokédex.
- Social features (buddy sharing, leaderboards, tag battles).
- Real-money monetization (**hard no** — origin doc).
- Voice/audio output for buddy commentary.
- Custom species/mods — user-defined JSON files under `~/.claude/plugins/data/buddygrow/species/` — compelling but needs its own brainstorm around safety and discoverability.
- Cross-device sync (two of your machines running the same buddy). Requires a server; not Plugin-primitive-friendly.

## Documentation Plan

- **README.md** (updated progressively P0 → P8): install, quick-start, slash command reference, rarity table, evolution cheatsheet (P4+), troubleshooting, uninstall/data-lifecycle contract.
- **CHANGELOG.md** (added P1): schema versions, behavior changes.
- **docs/roadmap.md**: checkbox tracker referencing this plan's phase IDs. Created as an immediate follow-up to plan approval.
- **docs/solutions/** (added ad-hoc): `/ce:compound` entries as we solve things worth remembering across the roadmap.

## Outstanding Questions

### Carried forward from origin, now addressed

| Origin question | Resolution in this plan |
|---|---|
| R10 — what do stats mechanically do? | D1 — stats are LLM prompt dimensions + line-bank lookup keys. No XP/token effect. |
| R5 — which behaviors drive evolution? | D2 — four axes (consistency/variety/quality/chaos), dominant axis picks path at Lv 10. |
| R4 — which hook events? Rate-limit? | D3 — PostToolUse/PostToolUseFailure/Stop/SessionStart; three-layer rate limit. |
| R8 — reroll token rate? | P5 — 1/hour capped 3/day; reroll cost 10. All tunable via userConfig. |
| R1, R7 — initial species roster? | P1.2 — 5 species at launch (Axolotl/Dragon/Owl/Ghost/Capybara), scales to 18 in P7.1. |
| R2 — storage format & location? | Data Model section — `${CLAUDE_PLUGIN_DATA}/buddy.json` + `session.json`. |
| R3 — status line constraints? | P2 — refreshInterval 5 in P2, drops to 1 in P7; width-safe to 40 cols. |
| Naming collision | Resolved — plugin `buddy`, skill `/buddy` (fallback `/buddy:buddy`). See "Naming Decision" above. |

### New questions surfaced during planning

- ~~**[P0 blocker][User decision]** Plugin name and slash command naming.~~ **Resolved 2026-04-16**: plugin `buddy`, skill `/buddy`, fallback `/buddy:buddy`.
- **[P6][Technical — decide during P6]** `prompt`-type hook vs dedicated subagent for LLM commentary. Pick based on measured latency and output flexibility.
- **[P7][Design — defer to P7]** Shiny variant rate — `/buddy` uses some percentage (not publicly documented); 1/256 is my starting point, tuneable after real playtime.
- **[P8][Discovery]** Marketplace publication — do we list in Anthropic's official marketplace, a third-party one, or neither for v1?

## Sources & References

### Origin

- **Origin document**: [docs/brainstorms/2026-04-16-claude-buddy-plugin-requirements.md](../brainstorms/2026-04-16-claude-buddy-plugin-requirements.md) — carried forward decisions: **Tamagotchi evolution + gacha hatch hybrid model**, **global single-buddy persistence**, **pure-growth progression**, **earned-token reroll economy**, **hybrid status-line + hook-reaction surface**, **full-vision documented up front, roadmap drives delivery**.

### Claude Code plugin architecture

- [Plugin reference — manifest, directory, CLI](https://code.claude.com/docs/en/plugins-reference)
- [Plugin creation guide](https://code.claude.com/docs/en/plugins)
- [Skills / slash commands](https://code.claude.com/docs/en/skills)
- [Hooks](https://code.claude.com/docs/en/hooks)
- [Status line](https://code.claude.com/docs/en/statusline)
- [Settings & scopes](https://code.claude.com/docs/en/settings)
- [Plugin marketplaces](https://code.claude.com/docs/en/plugin-marketplaces)
- [Changelog](https://code.claude.com/docs/en/changelog)

### Built-in `/buddy` reverse-engineering (for design reference, not implementation copy)

- [claudefa.st — mechanics guide](https://claudefa.st/blog/guide/mechanics/claude-buddy) — stats, sprites, soul/bones pattern.
- [findskill.ai — 18 species + 5 rarities guide](https://findskill.ai/blog/claude-code-buddy-guide/) — rarity distribution 60/25/10/4/1.
- [DEV Community — complete guide](https://dev.to/damon_bb9e4bba1285afe2fcd/claude-buddy-the-complete-guide-to-your-ai-terminal-pet-all-18-species-rarities-hidden-22da)
- [MindStudio — feature overview](https://www.mindstudio.ai/blog/what-is-claude-code-buddy-feature)

### Community plugins (architectural prior art)

- [1270011/claude-buddy](https://github.com/1270011/claude-buddy) — MCP + SKILL.md + hooks + statusline; state in `$CLAUDE_CONFIG_DIR/buddy-state/`. Our plugin name `buddy` side-steps their slug.
- [cpaczek/any-buddy](https://github.com/cpaczek/any-buddy) — patches account-ID hash; SessionStart hook re-applies after updates.
- [tama96](https://github.com/siegerts/tama96) — TUI pet with ratatui + MCP; animation precedent.
- [usik/tamagotchi](https://github.com/usik/tamagotchi) — stats, poop, discipline, care-driven evolution in terminal.
- [SSH Buddy (C-GBL/sshb)](https://github.com/C-GBL/sshb) — pet survives terminal close pattern.

### Design pattern references

- [Bulbapedia — Pokémon Natures](https://bulbapedia.bulbagarden.net/wiki/Nature) — "one peak, one dump" stat pattern for buddy stat generation.
- [Alan Zucconi — AI of Creatures](https://www.alanzucconi.com/2020/07/27/the-ai-of-creatures/) — drive-based personality emergence.
- [Tamagotchi care guide](https://thaao.net/tama/p1/) — care-mistake evolution signal design.
- [Humulos — Digimon V-Pet guide](https://humulos.com/digimon/dm20/) — multi-axis evolution signals.
- [Genshin Impact gacha rates](https://www.rpgsite.net/feature/10312-genshin-impact-gacha-system-wish-gacha-draws-rates-banners-pity-and-more-explained) — soft-pity pattern reference (not adopted directly; pseudo-pity in D8 is simpler).
- [Clippy retrospective — WindowsForum](https://windowsforum.com/threads/clippy-lessons-for-microsoft-copilot-when-assistants-become-intrusive.411922/) — "visibility should match utility" principle driving commentary rate limits.
- [Discord rate-limits docs](https://docs.discord.com/developers/topics/rate-limits) — cooldown patterns informing D3.
