---
id: P4-3
title: Visible buddy — stats menu + interact + emoji statusline + installer
phase: P4
status: done
depends_on: [P4-1]
origin_plan: docs/plans/2026-04-23-001-feat-p4-3-visible-buddy-plan.md
---

# P4-3 — Visible buddy

## Goal

Surface the XP and four-axis signals from P4-1 across four user-visible
surfaces: a rich `/buddy:stats` menu, a read-only `/buddy:interact`
sprite + speech bubble, a simplified ambient status line (emoji + name +
level only), and a consent-gated `/buddy:install-statusline` helper.

## Tasks

- [x] Unit 1 — Add `sprite.base []` and `line_banks.Interact.default []` to all 5 species; structural test in `species_line_banks.bats`.
- [x] Unit 2 — `scripts/lib/render.sh`: rarity color, bar, stat line, sprite-or-fallback, speech bubble, name (rainbow per-char on legendary). 29 unit tests.
- [x] Unit 3 — Rewrite `scripts/status.sh _status_render_active` as a menu (sprite, header, XP bar, 5 stat bars, signals strip, footer).
- [x] Unit 4 — New `scripts/interact.sh`: read-only sprite + speech bubble. Invariant test pins zero state mutation across two invocations.
- [x] Unit 5 — Simplify `statusline/buddy-line.sh` to `<emoji> <name> Lv.<N>`. Width tier `<30` drops name.
- [x] Unit 6 — `scripts/install_statusline.sh`: install / uninstall / `--dry-run` with timestamped backup, guarded markers, byte-identical round-trip test.

## Exit criteria

- `/buddy:stats` renders the full menu with sprite fallback box + bars + signals + footer.
- `/buddy:interact` shows the placeholder speech bubble + sprite. Re-running it does not change `buddy.json` or `session-*.json`.
- Status line shows emoji + name + level. Honors `$NO_COLOR` and `$COLUMNS`.
- Installer round-trips: `install` then `uninstall` leaves the user's `~/.claude/statusline-command.sh` byte-identical to the pre-install state.

## Notes

- **Sprite art content is deferred (D2).** Every species ships with `"sprite": { "base": [] }` and the user-visible portrait is the emoji-in-a-box fallback. Authoring real ASCII portraits is its own ticket — suggested P4-4 (or merged into P7-2 if scope aligns).
- **`Interact.default` banks ship empty.** The placeholder voice line `"<name> looks at you curiously."` covers the read path until the same content ticket authors real interact lines.
- **No bare `/buddy` alias (D11 deferred).** Anthropic's built-in `/buddy` may shadow plugin-registered bare aliases. Resolution order needs a live-session smoke; out of scope here. Users get explicit paths only.
- **Plugin `settings.json` cannot register `statusLine`** — the installer is the only path. See `docs/solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md`.

### Implementation notes (2026-04-23)

- **Plan:** [docs/plans/2026-04-23-001-feat-p4-3-visible-buddy-plan.md](../plans/2026-04-23-001-feat-p4-3-visible-buddy-plan.md).
- **Branch:** `feat/p4-3-visible-buddy`.
- **Render library shape:** `scripts/lib/render.sh` is the single home for visual language. All three surfaces (`status.sh`, `interact.sh`, `buddy-line.sh`) source it. `declare -gA` (not `declare -A`) on the rarity color map — without `-g`, sourcing inside `setup()` scopes the array to that function and tests see an empty palette.
- **Speech bubble layout:** bubble-above-sprite picked over sprite-left-bubble-right (D4 deferred-question). At 80 cols the vertical layout reads cleaner and survives narrow terminals without clipping the bubble.
- **Installer round-trip discipline:** `install` injects exactly one leading blank line before the guarded block; `uninstall` strips it back. Pinned by the byte-identity test in `tests/integration/test_install_statusline.bats`.
- **Test count:** 268 total (was ~225 pre-P4-3). Suite stays under ~75s wall-clock at `--jobs 4`.
