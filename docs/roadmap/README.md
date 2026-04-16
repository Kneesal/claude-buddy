# Roadmap

Tickets for the Claude Buddy plugin build, derived from the [plan](../plans/2026-04-16-001-feat-claude-buddy-plugin-plan.md) and grounded in the [brainstorm](../brainstorms/2026-04-16-claude-buddy-plugin-requirements.md).

Each ticket is a self-contained markdown file with frontmatter (`id`, `phase`, `status`, `depends_on`) and a task list. Status values: `todo` · `in-progress` · `done` · `blocked`.

## Phases

| Ticket | Title | Status | Depends on |
|---|---|---|---|
| [P0](./P0-scaffolding.md) | Plugin scaffolding | `done` | — |
| [P1-1](./P1-1-state-primitives.md) | State primitives (atomic I/O, flock, schema) | `todo` | P0 |
| [P1-2](./P1-2-hatch-roller.md) | Hatch roller (rarity, stats, species) | `todo` | P1-1 |
| [P1-3](./P1-3-slash-commands.md) | Slash command state machine | `todo` | P1-1, P1-2 |
| [P2](./P2-status-line.md) | Status line rendering | `todo` | P1-1 |
| [P3-1](./P3-1-hook-wiring.md) | Hook wiring + session init | `todo` | P1-1, P1-3 |
| [P3-2](./P3-2-commentary-engine.md) | Commentary engine (canned v1) | `todo` | P3-1 |
| [P4-1](./P4-1-xp-signals.md) | XP + evolution signal accumulation | `todo` | P3-1 |
| [P4-2](./P4-2-form-transitions.md) | Form transitions + evolution paths | `todo` | P4-1 |
| [P5](./P5-reroll-tokens.md) | Reroll token economy | `todo` | P4-2 |
| [P6](./P6-llm-commentary.md) | LLM-generated contextual commentary | `todo` | P3-2 |
| [P7-1](./P7-1-full-roster.md) | Scale roster to 18 species | `todo` | P4-2 |
| [P7-2](./P7-2-full-sprites.md) | 5-line animated sprites + shinies | `todo` | P2, P7-1 |
| [P8](./P8-polish.md) | Polish, docs, `/buddy stats`, publication | `todo` | P7-2, P5 |

## Playable milestones

- **After P3**: plugin installs, hatches a buddy, shows it in the status line, chimes in with canned lines.
- **After P4**: the distinct feature is live — buddy evolves based on coding behavior.
- **After P5**: gacha loop complete — earn tokens, reroll with real stakes.
- **After P8**: shippable / shareable.

## Open blockers

_None._ Naming decided 2026-04-16: plugin `buddy`, skill `/buddy`. P0 task list includes an empirical check for `/buddy` resolution precedence against Anthropic's built-in.

## Conventions

- Update a ticket's `status` field when starting (`in-progress`) and finishing (`done`).
- Add implementation notes to the ticket's **Notes** section as you work — they compound.
- If a ticket spawns a meaningful sub-decision or learning, consider promoting it to `docs/solutions/` via `/ce:compound`.
- New features past P8 → new brainstorm doc → new plan → new roadmap tickets.
