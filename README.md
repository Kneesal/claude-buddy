# Buddy

A Claude Code plugin that extends the built-in `/buddy` with gacha hatching and Tamagotchi-style evolution. Your buddy rolls randomly on hatch — species, rarity, stats, personality — and grows over time based on how you code.

> **Status:** P0 scaffolding — plugin installs and slash commands respond. Hatching, evolution, and commentary are coming in future releases.

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

Hook scripts and status line rendering use **bash** — no runtime dependencies required beyond a POSIX shell. Species data and schemas use JSON.

## Roadmap

See [docs/roadmap/README.md](docs/roadmap/README.md) for the full build plan.

## License

TBD
