---
title: Consent-gated user-config installer pattern for Claude Code plugins
date: 2026-04-23
category: developer-experience
module: scripts/install_statusline.sh
problem_type: developer_experience
component: tooling
severity: high
applies_when:
  - A Claude Code plugin needs to mutate the user's `~/.claude/` config because plugin `settings.json` cannot register the feature directly (e.g., `statusLine`, which is not in the plugin manifest schema — see `claude-code-plugin-scaffolding-gotchas-2026-04-16.md`)
  - Writing any installer that modifies a user-owned file outside `${CLAUDE_PLUGIN_DATA}`
  - Writing any CLI that takes destructive action on the user's shell environment or dotfiles
tags:
  - claude-code-plugin
  - installer
  - user-config
  - consent
  - backup
  - guarded-block
  - idempotence
  - byte-identity-test
  - reversible
---

# Consent-gated user-config installer pattern for Claude Code plugins

## Context

The Claude Code plugin manifest schema only supports `agent` and `subagentStatusLine`
keys — not `statusLine` (see `claude-code-plugin-scaffolding-gotchas-2026-04-16.md`).
Plugins that want to install an ambient status-line segment must patch the user's
own `~/.claude/statusline-command.sh`. That's a user-owned file outside
`${CLAUDE_PLUGIN_DATA}`, so the discipline for mutating it is strictly tighter
than the usual plugin-state discipline:

- The user may have their own existing content in that file.
- A botched install that corrupts the file could break the user's status line
  across every Claude Code session — not just within the plugin.
- `settings.json` may have a pre-existing `.statusLine` pointing at an entirely
  different command (from another plugin or a hand-roll).
- Silent overwrite of any of the above is an unacceptable failure mode.

The P4-3 `/buddy:install-statusline` command crystallized a pattern that any
plugin in the same situation should mirror.

## Guidance

**Every mutation of user-owned config goes through six layered gates:**

1. **Guarded block with markers.** Append — never replace — using a pair of
   marker comments:
   ```
   # >>> <plugin-name> >>> (managed by /<plugin>:install-<feature>)
   ...plugin-generated block...
   # <<< <plugin-name> <<<
   ```
   The markers enable clean `uninstall` later. Use full-line matching (or
   `grep -Fx`) when detecting the markers, not substring — a README that
   quotes the marker would otherwise trigger a false "already installed"
   short-circuit.

2. **Timestamped backup before any write.** Backup path:
   `~/.claude/<target>.<plugin>-bak.<ISO-timestamp-Z>`. Use `cp -p` to preserve
   mode/mtime. Backup happens **before** reading the file for rewrite — a
   TOCTOU between read and backup would silently discard a concurrent edit.

3. **In-band warning for destructive overwrites.** If the installer is about
   to replace user content that isn't under the guarded-block protocol
   (example: `settings.json.statusLine` already points at another command),
   surface that fact *before* the consent prompt with the specific value
   being replaced. A terse "Updating will REPLACE it" is enough; don't hide
   it behind a link or summarize.

4. **Consent prompt, y/N default NO.** Stdin `y`/`yes` accepts; anything
   else (including empty line / EOF / stdin closed) declines. The prompt
   text shows the exact diff that would be applied. A `BUDDY_INSTALL_ASSUME_YES`
   env var opens a test hatch — don't document it as a user-facing flag.

5. **`--dry-run` mode.** Prints the planned diff without writing. No backup
   is taken because no mutation happens. Tests for destructive subcommands
   start here.

6. **`uninstall` subcommand.** Always reversible. Removes the guarded block
   cleanly. If the file is empty or whitespace-only after block removal,
   offer to delete it entirely. Pinned by a **byte-identity round-trip test**
   against a fixture `$HOME`:

   ```bash
   before_sum="$(md5sum "$HOME/.claude/<target>")"
   <plugin>:install
   <plugin>:uninstall
   after_sum="$(md5sum "$HOME/.claude/<target>")"
   [ "$before_sum" = "$after_sum" ]
   ```

   This is the single most valuable test an installer can have. It catches
   trim-heuristic bugs, trailing-newline drift, marker-residue, and double-
   install regressions in one assertion.

**File-write discipline:**

- Appends can use `>>` when a backup exists and failure recovery is the backup
  itself (acceptable for contributor-friendly ergonomics).
- JSON rewrites (`~/.claude/settings.json`) must use `jq | mktemp | mv -f` for
  atomicity — partial writes to settings.json break every Claude Code session.
- Refuse to touch `settings.json` if it exists but doesn't parse as valid JSON.
  Surface the parse error; a "fix your JSON then re-run" message is much
  friendlier than a clobber.

**Exit codes:** installer exits non-zero on failed writes even though the
plugin's render surfaces exit 0. This is the exception that proves the
exit-0 rule: the user needs to *see* that the install failed, otherwise they
get a silent "nothing happened" with a timestamped backup they don't know
they have.

## Why This Matters

A plugin installer that doesn't follow this pattern has three common failure
modes:

- **Silent clobber of user work.** The most common regression — user had
  their own `statusline-command.sh`, installer overwrote it, user's content
  is gone. The guarded-block + append protocol makes this structurally
  impossible.

- **Unreversible install.** User tries the plugin, decides they don't want
  the ambient segment, has no clean way to remove it. The marker-block +
  `uninstall` subcommand gives them a one-line exit.

- **Drift between "uninstalled" and original state.** Round-trip is almost
  byte-identical but leaves a trailing newline or a stripped blank line.
  Users don't notice, but it pollutes their git-tracked dotfiles with a
  no-op diff every time they open them. The byte-identity test is the
  only way to reliably catch this.

## When to Apply

- Any plugin feature that needs a hook into `~/.claude/` config the manifest
  can't register directly. Today that's `statusLine`; in the future it might
  be a pre-commit hook, a global setting, or a workspace-level toggle.
- Any CLI that edits a user's shell rc (`.bashrc`, `.zshrc`, `.profile`).
  The guarded-block pattern is the industry standard there for the same reasons.
- Any tool that installs integration into a third-party config (Claude Desktop
  `claude_desktop_config.json`, Cursor `~/.cursor/*`, VS Code settings.json).

Skip: mutations inside `${CLAUDE_PLUGIN_DATA}` — that's your plugin's own
state directory. The flock + atomic tmp+rename discipline from
`bash-state-library-patterns-2026-04-18.md` applies there instead.

## Examples

See `scripts/install_statusline.sh` (P4-3) for the full shape. Key excerpts:

**Guarded block append (idempotent, marker-matched):**

```bash
_install_has_block() {
  grep -qF "$_BUDDY_BEGIN_MARKER" "$1"
}

if _install_has_block "$target"; then
  echo "buddy-plugin block already present in $target. Nothing to do."
  return 0
fi
```

**Pre-consent warning for existing `.statusLine`:**

```bash
if [[ -f "$settings" ]] && jq -e '.statusLine' "$settings" >/dev/null 2>&1; then
  local existing_cmd
  existing_cmd="$(jq -r '.statusLine.command // ""' "$settings" 2>/dev/null)"
  echo "Note: $settings already has a statusLine set:"
  echo "  command = \"$existing_cmd\""
  echo "Updating will REPLACE it (a backup will be written first)."
fi
if ! _install_consent "Update $settings to use this script as the statusLine?"; then
  echo "Skipped settings update."
  return 0
fi
```

**Round-trip byte-identity test (the single most valuable installer test):**

```bash
@test "round-trip: install then uninstall → file byte-identical to original" {
  printf '#!/usr/bin/env bash\necho "user content"\nexit 0\n' \
    > "$HOME/.claude/statusline-command.sh"
  local before_sum
  before_sum="$(md5sum "$HOME/.claude/statusline-command.sh" | awk '{print $1}')"

  bash "$INSTALL_SH" install >/dev/null
  bash "$INSTALL_SH" uninstall >/dev/null

  local after_sum
  after_sum="$(md5sum "$HOME/.claude/statusline-command.sh" | awk '{print $1}')"
  [ "$before_sum" = "$after_sum" ]
}
```

## Known Residual Risks

- The round-trip test passes for files with a trailing newline. A file ending
  with *no* trailing newline (or an intentional blank line) round-trips to
  byte-identical *except* for the terminal `\n` because the install-path's
  `{ printf '\n' && block; } >> file` injects one. Documented trade-off;
  fix is to record+restore the original trailing-newline state.
- Backup files accumulate forever in `~/.claude/`. Document this in the
  installer's output; don't auto-prune.
- Concurrent installs within the same UTC second collide on backup path.
  Add a PID or random suffix if users report it.

## See Also

- `docs/solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md`
  — why the installer exists at all (plugin `settings.json` can't register
  `statusLine`).
- `docs/solutions/developer-experience/claude-code-plugin-data-path-inline-suffix-2026-04-23.md`
  — the `CLAUDE_PLUGIN_DATA` inline-suffix that the installed block respects.
- `scripts/install_statusline.sh`, `tests/integration/test_install_statusline.bats`
  — the canonical implementation + test file in this repo.
