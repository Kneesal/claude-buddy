# Buddy

A Claude Code plugin that extends the built-in `/buddy` with gacha hatching and Tamagotchi-style evolution. Your buddy rolls randomly on hatch — species, rarity, stats, personality — and grows over time based on how you code.

> **Status:** P2 landed — status line shipped (see the Status line section below), plus the P1-3 slash command state machine (`/buddy:hatch`, `/buddy:stats`, `/buddy:reset`). Evolution and commentary are coming in future releases.

## Requirements

- **bash 4.1+** — `state.sh` uses automatic file-descriptor assignment (`exec {fd}>file`) which is silently broken on bash 3.x. macOS users need `brew install bash` (the system bash is 3.2).
- **`jq`** — for JSON manipulation in the state library.
- **`flock`** (util-linux) — for advisory locking on `buddy.json`. Standard on Linux; install via Homebrew (`brew install util-linux`) on macOS.

Linux devcontainer (`.devcontainer/`) ships all three. Windows is a post-P8 consideration.

## Install

### From a local directory (development)

```bash
claude --plugin-dir /path/to/this/repo
```

This loads the plugin for the current session only.

### Permanent install

```bash
cd /path/to/this/repo
claude plugin install .
```

## Commands

| Command | Description |
|---------|-------------|
| `/buddy:hatch` | Hatch a new buddy (random species, rarity, stats). Re-running on an existing buddy prints reroll consequences; add `--confirm` to actually reroll (costs 10 tokens from P5 onward). |
| `/buddy:stats` | View your buddy's stats, level, XP progress, and token balance. |
| `/buddy:reset` | Wipe your buddy and start fresh. Requires `--confirm`. |
| `/buddy:interact` | Talk to your buddy (P0 scaffold; full interaction system comes later). |

Destructive operations (reroll, reset) require an explicit `--confirm` flag because SKILL.md can't reliably do mid-execution interactive prompts — the flag is the confirmation. Without it, the command prints the consequences and exits.

> **Note on namespacing:** plugin skills are always invoked as `/<plugin>:<skill>`. There's no way to expose a bare `/buddy` from a plugin — that name is reserved for Anthropic's built-in. See [`docs/solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md`](docs/solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md) for the full story.

If you haven't hatched a buddy yet, `/buddy:interact`, `/buddy:stats`, and `/buddy:reset` will print a short pointer to `/buddy:hatch`.

## Status line

Enable the ambient status line to see your buddy on every assistant turn:

```
🦎 Custard (Common axolotl · Lv.1) · 4 🪙
```

The plugin's status line is opt-in because plugin-level `settings.json` cannot register a `statusLine` (only `agent` and `subagentStatusLine` are supported at that level — see [`docs/solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md`](docs/solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md)). Enable it by adding the snippet below to your **user-level** `settings.json`:

- Global (all projects): `~/.claude/settings.json`
- Per-project: `.claude/settings.json` in the project root

```json
{
  "statusLine": {
    "type": "command",
    "command": "${CLAUDE_PLUGIN_ROOT}/statusline/buddy-line.sh",
    "padding": 1,
    "refreshInterval": 5
  }
}
```

Restart Claude Code (or open a new session) and the buddy appears in the bottom status bar.

**What renders:**

| State | Status line |
|---|---|
| NO_BUDDY (fresh install / post-reset) | `🥚 No buddy — /buddy:hatch` |
| ACTIVE (width ≥ 40) | `<emoji> <name> (<Rarity> <species> · Lv.<N>) · <N> 🪙` |
| ACTIVE (width 30–39) | Tokens segment dropped |
| ACTIVE (width < 30) | Rarity qualifier also dropped: `<emoji> <name> (Lv.<N>)` |
| CORRUPT | `⚠️ buddy state needs /buddy:reset` |
| FUTURE_VERSION (newer plugin wrote the file) | `⚠️ update plugin to read newer buddy.json` |

**Customization:**

- Set `NO_COLOR=1` in your environment to strip ANSI color codes (the rarity qualifier renders plain).
- Rarity color map: Common = grey, Uncommon = white, Rare = blue, Epic = magenta, Legendary = gold.
- Shiny buddies (P7-2) will get a ✨ sparkle prefix here as a lightweight visual tell; the full rainbow portrait lives in chat output, not the status line.

## Libraries

- **`scripts/lib/state.sh`** (P1-1) — atomic, flock-locked JSON persistence for `buddy.json` and per-session `session-<id>.json` with schema versioning and corruption sentinels. Tests: `tests/state.bats`.
- **`scripts/lib/rng.sh`** (P1-2) — hatch roller: `roll_rarity` (60/25/10/4/1 with pseudo-pity rescue at 10), `roll_species`, `roll_stats` (rarity floors + one-peak/one-dump/three-mid shape with species bias), `roll_name`, `roll_buddy` (the full composed inner-buddy JSON), `next_pity_counter`. Deterministic via `BUDDY_RNG_SEED` for tests. Tests: `tests/rng.bats`.
- **`scripts/species/*.json`** (P1-2, extended P2) — per-species data (voice archetype, stat weights, name pool, emoji). 5 launch species; 18 at P7-1.
- **`statusline/buddy-line.sh`** (P2) — single-line ambient renderer for the status bar. Reads `buddy.json`, prints one line per state, width-safe, honors `NO_COLOR`. Tests: `tests/statusline.bats`.

## Implementation language

Hook scripts and status line rendering use **bash 4.1+** (see Requirements above). Species data and schemas use JSON. No package manager, no build step — the plugin is a directory of scripts and markdown.

## Roadmap

See [docs/roadmap/README.md](docs/roadmap/README.md) for the full build plan.

## License

TBD
