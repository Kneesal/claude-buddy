# Buddy

A Claude Code plugin that extends the built-in `/buddy` with gacha hatching and Tamagotchi-style evolution. Your buddy rolls randomly on hatch — species, rarity, stats, personality — and grows over time based on how you code.

> **Status:** P0 scaffolding — plugin installs and slash commands respond. P1-1 state primitives landed. Hatching, evolution, and commentary are coming in future releases.

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
| `/buddy:hatch` | Hatch a new buddy (random species, rarity, stats) |
| `/buddy:interact` | Talk to your buddy |
| `/buddy:stats` | View your buddy's stats, level, and evolution progress |

If you haven't hatched a buddy yet, `/buddy:interact` and `/buddy:stats` will prompt you to run `/buddy:hatch` first.

## Implementation language

Hook scripts and status line rendering use **bash 4.1+** (see Requirements above). Species data and schemas use JSON. No package manager, no build step — the plugin is a directory of scripts and markdown.

## Roadmap

See [docs/roadmap/README.md](docs/roadmap/README.md) for the full build plan.

## License

TBD
