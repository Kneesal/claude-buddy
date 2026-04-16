---
date: 2026-04-16
topic: claude-buddy-plugin
---

# Claude Buddy Plugin

A Claude Code plugin that extends Anthropic's `/buddy` feature (added April 1, 2026 in Claude Code v2.1.90) with **gacha hatching + Tamagotchi-style evolution**. Your buddy rolls randomly on hatch — species, rarity, stats, personality — and then *grows and evolves* over time based on how you actually code. Original `/buddy` is deterministic and static; this plugin's distinct value is the evolution layer.

## Problem Frame

Anthropic's `/buddy` is fun but static — once hatched, your buddy never grows, never reacts to *your* patterns over time, and you can't reroll. Community plugins exist to preserve buddies across updates or hack in arbitrary ones, but none add the thing a Tamagotchi-style pet really wants: **progression tied to your coding behavior, and gentle tension over rerolling a buddy you've grown attached to**.

The target user is any Claude Code user who found `/buddy` delightful and wants a deeper loop to come back to — a coding companion that feels earned, not just rolled.

## Requirements

- **R1. Gacha hatch** — `/buddy hatch` rolls a random buddy: species, rarity, base stats, personality. Random, not deterministic from user ID. Hatching when one already exists prompts a confirmation that the current buddy's evolution progress will be lost.
- **R2. Single active buddy, global** — one buddy per user at a time. Buddy persists globally (not per-project) in user config (e.g. `~/.claude/`) so it follows you across every codebase.
- **R3. Status line presence** — buddy is always visible in the Claude Code status line as ASCII/emoji with name and (eventually) evolution form. Ambient, not intrusive.
- **R4. Hook-driven commentary** — buddy chimes in opportunistically via hook events (tool use, errors, session stop, etc.) with short in-character speech bubbles. Rate-limited to avoid spam.
- **R5. Tamagotchi evolution** — buddy grows over time based on your coding behavior, unlocking evolution forms along paths (e.g. Scholar, Chaos, Night). Behavior shapes *which* path, not *whether* you progress.
- **R6. Pure-growth progression** — no death, no devolve, no negative end states. Buddies can have *moods* (optional, TBD) but cannot be permanently harmed by neglect or rough sessions. A dev tool shouldn't punish.
- **R7. Per-species personality** — each species has a distinct voice/tone driving commentary (e.g. dry-scholar, chaotic-gremlin, wholesome-cheerleader, deadpan-night). The voice *is* the reward for what you rolled. Stats nuance the voice further (see R10).
- **R8. Reroll via earned tokens** — rerolling requires spending tokens earned through coding activity. Gates the gacha loop so it's not free-spam but not locked either. Rerolling resets evolution progress on your current buddy. A `/buddy reset` escape hatch exists with explicit warnings.
- **R9. Slash commands** — at minimum: `/buddy` (status), `/buddy hatch` (first hatch or reroll), `/buddy reset` (wipe + confirm). More commands (feed, pet, rename, etc.) are open space for the roadmap.
- **R10. Stats exist and influence the buddy** — each hatched buddy has stat dimensions (like original `/buddy`'s 5-dim stats). Stats shape personality at minimum; whether they mechanically affect evolution paths, commentary frequency, or token earn rate is a design decision deferred to planning.

## Success Criteria

- First-session feel: a user can run `/buddy hatch` and within one minute see their buddy in the status line and hear it comment on something.
- Commentary feels *contextual* (it's reacting to what just happened) at least some of the time, not purely canned.
- Over a week of normal use, visible evolution progress occurs — the buddy changes in an observable way.
- Users refer to their buddy by its rolled name — qualitative sign of attachment.
- Commentary stays under a threshold where it would feel spammy (specific cadence TBD in planning, but the bar is "users don't disable it").

## Scope Boundaries

- **Not a collection game.** One active buddy at a time. No Pokédex, no stable, no trading.
- **Not a replacement or fork of Anthropic's `/buddy`.** Runs alongside it. No attempt to spoof or manipulate Anthropic's deterministic hash.
- **No multiplayer, no social, no leaderboards, no sharing.** Your buddy is yours.
- **No per-project buddies.** Global only. (Could be revisited later; explicitly deferred for now.)
- **Not gated by Claude subscription tier.** Works for any Claude Code install.
- **Not monetized.** No real-money gacha. Tokens are earned only.
- **No "death" mechanics.** Explicitly ruled out.

## Key Decisions

- **Extension, not clone.** The evolution layer is the distinctive value — we are not rebuilding what Anthropic already ships.
- **Tamagotchi evolution + gacha hatch** (hybrid model). Reconciles "each buddy has different stats" (gacha) with "one pet that grows" (Tamagotchi).
- **Global persistence** over per-project. Matches original `/buddy` feel; simpler to build; users unlikely to want to re-hatch per repo.
- **Pure growth, no stakes.** A coding pet should never make you feel worse about your day.
- **Earn reroll tokens via coding activity.** Creates tension (do I keep evolving Pip or pull for a legendary?) without being free-spam or pay-to-play.
- **Document full vision now; build from a roadmap.** Brainstorm doc is source of truth until the full roadmap ships. Additional features get their own brainstorm docs later.
- **Hybrid surface**: status line (ambient) + hook reactions (pop-in). Slash commands handle gacha/admin actions.

## Dependencies / Assumptions

- Claude Code plugin architecture supports: status line customization, hook events, slash commands (all documented plugin extension points).
- User's machine has a writable config directory (`~/.claude/` or equivalent) for persistent buddy state.
- Naming: the directory is `claude-buddy`, which collides with the existing [1270011/claude-buddy](https://github.com/1270011/claude-buddy) GitHub plugin (preserves Anthropic buddies across updates). Rename decision deferred — see Outstanding Questions.

## Outstanding Questions

### Resolve Before Planning

*(None are strictly blocking — implementation shape will resolve the rest. If any below turn out to need a user call during planning, `/ce:plan` will surface them.)*

### Deferred to Planning

- [Affects R10][User decision + Technical] What do buddy stats *mechanically* do? Four candidate roles, from simplest to most depth: (a) flavor-only, shape personality text; (b) shape evolution path probabilities; (c) affect mechanics (reroll token earn rate, commentary frequency, XP gain, unlock conditions); (d) drop stats entirely. Original `/buddy` uses (a). Planning to propose a first-pass model.
- [Affects R5][Technical + Needs research] Which specific coding behaviors map to which evolution paths? Candidates: commit cadence, test pass/fail ratio, repeated edits to the same file, session length, time of day, tool-use distribution, error frequency. Depends on what signals are actually available via Claude Code hooks.
- [Affects R4][Technical + Needs research] Which Claude Code hook events feed commentary (PostToolUse, Stop, SessionStart, UserPromptSubmit, etc.), and what's the rate-limit strategy so the buddy doesn't spam?
- [Affects R8][User decision] Reroll token earn rate and economy — what activity earns tokens, how often, and how many tokens does a reroll cost?
- [Affects R1, R7][User decision] Initial species roster — how many species ship in the first playable version (suggest 3–5 to start, scaling toward original `/buddy`'s 18), and what are their archetype voices?
- [Affects R2][Technical] Storage format and exact location for persisted buddy state (schema, migration strategy).
- [Affects R3][Technical + Needs research] Status line rendering constraints in Claude Code plugins — character width, update cadence, ANSI support for ASCII art.
- [Naming][User decision] Plugin name / GitHub slug given the collision with `1270011/claude-buddy`. Options: rename locally before publishing, scope under a unique namespace, or accept the collision.

## Next Steps

→ `/ce:plan` for a structured implementation plan + roadmap. The roadmap should live alongside this doc (e.g. `docs/roadmap.md` or `docs/plans/`) and drive incremental delivery. This brainstorm remains the source of truth for scope and intent until the roadmap is fully delivered; new features after that get their own brainstorm docs.
