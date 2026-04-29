---
title: Claude Code plugin marketplace requires .claude-plugin/marketplace.json (not plugin.json)
date: 2026-04-29
category: developer-experience
module: .claude-plugin
problem_type: developer_experience
component: tooling
severity: high
applies_when:
  - Distributing a Claude Code plugin via the standard marketplace install flow
  - Telling end users "run /plugin marketplace add to get my plugin" and seeing it fail
  - Setting up a single-plugin repo that doubles as its own marketplace
  - Authoring install instructions for a plugin's README
tags:
  - claude-code-plugin
  - marketplace
  - distribution
  - plugin-manifest
  - install
  - gotcha
---

# Claude Code plugin marketplace requires .claude-plugin/marketplace.json

## Context

The Claude Code plugin install flow has two slash commands:

```
/plugin marketplace add <github-org>/<repo>
/plugin install <plugin-name>@<marketplace-name>
```

It's tempting to assume that any repo with a valid `.claude-plugin/plugin.json`
is automatically a usable marketplace — after all, the manifest exists, the
plugin is discoverable, surely the loader can figure it out. It can't.
Running `/plugin marketplace add` on a repo with only `plugin.json` fails
with:

```
Error: Marketplace file not found at
.../plugins/marketplaces/temp_<n>/.claude-plugin/marketplace.json
```

Two separate files are required, with two separate roles:

| File | Role |
|---|---|
| `.claude-plugin/plugin.json` | Manifest for ONE plugin: name, version, description, userConfig, etc. |
| `.claude-plugin/marketplace.json` | Registry that LISTS plugins: marketplace name, owner, plugins[] array pointing to plugin sources. |

A repo can be a marketplace, a plugin, or both. To be both (the common case
for solo plugin authors who don't want a separate registry repo), it needs
both files at the same `.claude-plugin/` directory.

The install commands are also asymmetric in a non-obvious way:

- `marketplace add Kneesal/claude-buddy` — argument is the **GitHub repo
  path**, that's where Claude Code clones from.
- `install buddy@devpets` — the suffix is the **marketplace name** declared
  inside `marketplace.json` (`{"name": "devpets", ...}`), not the repo path.

The two values can be equal but don't have to be. They're conceptually
different things — the GitHub repo is "where to clone from", the
marketplace name is "which registry entry owns this plugin." That gives
plugin authors flexibility (rename the marketplace without renaming the
repo, or vice versa) at the cost of one more piece of mental model.

## Guidance

### For a solo-plugin repo (single plugin, repo doubles as marketplace)

Drop both files at `.claude-plugin/`:

**`.claude-plugin/plugin.json`** — the plugin manifest you already have.
Minimum required: `name`, `description`. Add `version`, `author`,
`repository`, `license` for distribution.

**`.claude-plugin/marketplace.json`** — the marketplace registry. Use
`source: "./"` to point the plugin at the repo root (where `plugin.json`
lives):

```json
{
  "name": "devpets",
  "owner": { "name": "Nisal" },
  "description": "Marketplace for the buddy plugin.",
  "plugins": [
    {
      "name": "buddy",
      "source": "./",
      "description": "...",
      "version": "0.0.9",
      "author": { "name": "Nisal" },
      "license": "MIT",
      "repository": "https://github.com/Kneesal/claude-buddy"
    }
  ]
}
```

The marketplace `name` is what end users type after the `@` in
`/plugin install <name>@<marketplace>`. Pick it deliberately —
short, memorable, lowercase (we landed on `devpets`).

### Documenting the install in your README

```markdown
## Install

\`\`\`
/plugin marketplace add Kneesal/claude-buddy
/plugin install buddy@devpets
\`\`\`
```

Always show both lines. The two-step requirement is intentional — it gives
users a chance to inspect what marketplace they're trusting before any
plugin from it activates. There's no one-shot install command that bundles
the two; the trust hop is by design.

### Update churn

Every rename of the marketplace `name` invalidates users' existing local
registration. They'll get a "plugin not found in any marketplace" error
on the install step until they run `marketplace remove <old-name>` and
re-add. So pick the name once and don't change it lightly.

## Why This Matters

Without `marketplace.json`, the plugin literally cannot be installed via
the standard flow — your README's "run `/plugin install`" instructions
are broken. The error message is helpful (it names the missing file path)
but the JSON shape isn't documented in the loader's error output, so
plugin authors can hunt for ten minutes before realizing they're missing
a second manifest, not debugging a malformed first one.

The asymmetric arg between `marketplace add` and `install` is a separate
trap. Authors who skip step 1 in their README, or who set the marketplace
`name` to something different from the repo path, hand users an install
command that doesn't match the marketplace they just added.

## When to Apply

- Any time you're distributing a Claude Code plugin to end users (not
  just `claude --plugin-dir` for local dev).
- The first time you write a plugin README's install section.
- When renaming or relicensing a plugin — the `marketplace.json` name and
  the per-plugin `version` field both belong to the marketplace registry,
  not the plugin manifest.

## Examples

**Working install, end-to-end:**

1. Repo at `https://github.com/Kneesal/claude-buddy` has both
   `.claude-plugin/plugin.json` (plugin "buddy") and
   `.claude-plugin/marketplace.json` (marketplace "devpets").
2. User runs `/plugin marketplace add Kneesal/claude-buddy`. Claude Code
   clones, finds the marketplace.json, registers it under the name
   `devpets`.
3. User runs `/plugin install buddy@devpets`. Claude Code looks up the
   `devpets` registry, finds the `buddy` plugin pointing at `source:
   "./"`, resolves `plugin.json` at the repo root, installs.
4. `${CLAUDE_PLUGIN_DATA}` is wired to `~/.claude/plugins/data/buddy-inline/`
   automatically — no `--plugin-dir` flag needed for this user.

**Broken install path (what we hit):**

Repo had only `plugin.json`, no `marketplace.json`. The `marketplace add`
step errored with the file-not-found message. Even the user's "obvious"
fallback — using the full https URL form `marketplace add
https://github.com/Kneesal/claude-buddy.git` — produced the same error.
The fix wasn't a URL format issue; it was a missing file.

## See Also

- `docs/solutions/developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md`
  — companion doc covering the plugin-side manifest constraints
  (e.g., `settings.json` cannot register `statusLine` at the plugin level).
- `docs/solutions/developer-experience/claude-code-plugin-data-path-inline-suffix-2026-04-23.md`
  — `${CLAUDE_PLUGIN_DATA}` resolves to a `<plugin-name>-inline/`
  subdirectory under marketplace install too, not just `--plugin-dir`.
- The canonical install flow shipped in `README.md` and the marketplace
  manifest at `.claude-plugin/marketplace.json` in this repo.
