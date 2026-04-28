# Buddy

A Claude Code plugin that gives you a gacha-hatched, Tamagotchi-style coding companion. Your buddy rolls randomly on hatch — species, rarity, stats, eye style, hat — and reacts to your work as you code.

```
   \^^^/                                .---.
  <vvv-vvv>                            ( o   o )
  ( *   * )                            (   o   )
  (   u   )                             ~v~v~v~
   v_v_v_v
   axolotl                                ghost
```

## Install

```
/plugin marketplace add Kneesal/claude-buddy
/plugin install buddy@codemoddy
```

Then hatch your buddy:

```
/buddy:hatch
```

That's it. Claude Code clones the repo into its plugin cache and the `${CLAUDE_PLUGIN_DATA}` path is wired up automatically. To update later, re-run `/plugin install`. To remove, `/plugin uninstall buddy@codemoddy`.

> The first argument to `marketplace add` is the GitHub repo path (`Kneesal/claude-buddy`); the `@codemoddy` suffix on `install` is the marketplace **name** declared inside `.claude-plugin/marketplace.json`. The two arguments are deliberately different — repo path is where Claude Code clones from; marketplace name is the registry entry that owns the plugin.

## Requirements

- **bash 4.1+** — `state.sh` uses automatic file-descriptor assignment which is silently broken on bash 3.x. macOS users should `brew install bash` (system bash is 3.2).
- **`jq`** — for JSON manipulation.
- **`flock`** (util-linux) — for atomic state writes. Standard on Linux; macOS users get it via `brew install util-linux`.

A Linux devcontainer (`.devcontainer/`) ships all three.

## Commands

| Command | What it does |
|---|---|
| `/buddy:hatch` | Hatch a new buddy (random species, rarity, stats, eye glyph, hat). Re-running on an existing buddy prints reroll consequences; add `--confirm` to actually reroll (costs 10 tokens). |
| `/buddy:stats` | Full menu render — sprite + name/rarity/level header + XP bar + 5 stat bars + signal counters + token balance. |
| `/buddy:interact` | Read-only "check in" view — sprite + speech bubble. Doesn't mutate state. |
| `/buddy:reset` | Wipe your buddy and start fresh. Requires `--confirm`. |
| `/buddy:install-statusline` | Wire the ambient buddy line into your `~/.claude/statusline-command.sh` (consent-gated, reversible, takes a timestamped backup before any write). |

Destructive operations require `--confirm` because skill dispatchers can't reliably do mid-execution interactive prompts. Without the flag, the command prints the consequences and exits cleanly.

> **Note on namespacing:** plugin skills are always invoked as `/<plugin>:<skill>`. There's no way to expose a bare `/buddy` from a plugin — that name is reserved for Anthropic's built-in. See [`docs/solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md`](docs/solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md) for the full story.

## Species, eyes, and hats

Five launch species, each with a 6-glyph eye pool that gets randomized per buddy at hatch:

| Species | Eye pool |
|---|---|
| axolotl  | `o * u ^ O v` (cheerful) |
| dragon   | `x > < @ + X` (fierce) |
| owl      | `O 0 Q o @ 8` (wise) |
| ghost    | `o O . v * _` (spectral) |
| capybara | `- _ ~ . , :` (sleepy) |

Any non-common buddy has a 40% chance of rolling one of 13 hats: `crown`, `antlers`, `flame`, `headphones`, `bow`, `flower`, `stars`, `wizard`, `halo`, `beanie`, `cap`, `bunny`, `propeller`. Commons never roll a hat — keeps the rarity signal crisp.

That's 6 eye variants × 14 hat states (no-hat + 13) per species = up to 84 distinct looks within a single rarity tier.

## Ambient status line

After running `/buddy:install-statusline` you'll see a single-glyph status line:

```
🦎 Custard Lv.3
```

Width-safe (the name drops at narrow terminals), honors `$NO_COLOR`, rarity-colored. Legendary uses a per-character rainbow cycle; shiny prepends `✨`.

The installer is reversible: `/buddy:install-statusline uninstall` removes the buddy block and restores from backup. The round-trip is byte-identical for canonical inputs.

## Configuration

Two opt-in settings via the standard Claude Code plugin config UI:

- `commentsPerSession` (default `8`) — cap on hook-driven commentary lines per session
- `stopLineOnExit` (default `true`) — whether buddy emits a session-end goodbye

## How it works

- **`scripts/lib/state.sh`** — atomic, flock-locked JSON persistence with schema versioning and corruption sentinels
- **`scripts/lib/rng.sh`** — deterministic-via-seed hatch roller (rarity, species, stats, name, pity counter)
- **`scripts/lib/render.sh`** — shared render helpers for rarity coloring, bars, sprite composition, speech bubbles
- **`scripts/species/*.json`** — per-species data (voice archetype, stat weights, name pool, sprite, eye pool, line banks)
- **`scripts/species/_hats.json`** — shared hat library
- **`scripts/hooks/`** — event-driven scripts that accumulate XP and signal data
- **`statusline/buddy-line.sh`** — ambient single-line renderer

Hook scripts and rendering are pure bash. State is JSON. No package manager, no build step — the plugin is a directory of scripts and markdown.

## Roadmap

See [docs/roadmap/README.md](docs/roadmap/README.md) for the full build plan. Shipped through P4-4 as of v0.0.9 (pre-1.0 — public smoke test); P4-5 (reactive sprites + transcript-animation spike) is planned next.

## License

[MIT](LICENSE) — © 2026 Kneesal
