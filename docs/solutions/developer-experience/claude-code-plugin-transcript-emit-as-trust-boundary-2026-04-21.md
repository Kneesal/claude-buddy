---
title: The Claude Code transcript is a cross-trust boundary — strip control bytes at emit
date: 2026-04-21
category: developer-experience
module: claude-code-plugin-system
problem_type: best_practice
component: tooling
severity: high
applies_when:
  - A Claude Code plugin emits text to the transcript via hook stdout, slash-command output, or status line
  - The emitted text contains any author-controlled string (species line, commit message, user-provided name, tool output summary, LLM completion)
  - The plugin ships without a strict schema on that author-controlled content (JSON banks, Markdown SKILL.md, loose config)
  - Downstream agents or automation may read the transcript and act on its content (agent-native workflows, CI orchestrators, replay tools)
related_components:
  - hooks
  - skills
  - status-line
tags:
  - claude-code
  - plugin-system
  - security
  - transcript
  - ansi-escape
  - cross-trust-boundary
  - agent-native
---

# The Claude Code transcript is a cross-trust boundary — strip control bytes at emit

## Context

A Claude Code plugin's hook scripts, skills, and status-line output
all surface text into the transcript — the in-terminal scrollback
rendered by Claude Code. It is easy to think of that surface as
"just for the user" and apply a loose threat model: the plugin is
local, the user installed it, the author is known, no attacker in
the loop.

That model misses two things:

1. **The transcript is the only record of the session that
   downstream agents read.** A replay tool, a session historian,
   an automation wrapper, or a second Claude Code instance
   processing the transcript is a separate consumer — and agents
   that parse transcripts key off text content (commentary lines,
   tool output summaries, status-line segments). Any text you
   emit is an input to those consumers.
2. **Author-controlled content is rarely validated against the
   transcript's rendering rules.** Species JSON (P3-2 buddy
   plugin), SKILL.md instructions, name_pool entries, canned
   response banks — all of these are unchecked strings. A
   contributor writes a line; `jq -r` decodes any `[...`
   escape sequence to its literal byte; `printf '%s'` passes it
   through to the terminal.

In P3-2 the concrete failure case is a species line like
`"ooh[31m a green test"`, which after `jq -r` decoding
becomes a real ANSI color code in the user's terminal. More
dangerous variants exist: CSI sequences that move the cursor,
clear the screen, or alter the terminal title; BEL bytes (`\x07`);
null bytes; DEL/backspace sequences that obscure the preceding
line. None of these require a "malicious" plugin — they only
require a contributor who pasted styled text from somewhere, or
an LLM-generated line (P6) that emits one by accident.

## Guidance

### A. Strip all control bytes at the emit boundary

Use `tr -d '[:cntrl:]'` on author-controlled fields before the
final `printf '%s'` that surfaces them in the transcript. This is
stricter than `\n`/`\r` stripping (the minimum needed to keep
each emission on its own line) because it also removes ESC
(`\x1b`), BEL (`\x07`), backspace, and the entire 0x00-0x1f and
0x7f range:

```bash
_commentary_format() {
  local emoji="$1" name="$2" line="$3"
  # Strip control bytes — ANSI escapes, BEL, backspace, NUL, tabs.
  name="$(printf '%s' "$name" | tr -d '[:cntrl:]')"
  line="$(printf '%s' "$line" | tr -d '[:cntrl:]')"
  printf '%s %s: "%s"' "$emoji" "$name" "$line"
}
```

`[:cntrl:]` deliberately includes `\t`. Hook stdout that will be
rendered as a single transcript line shouldn't carry tabs —
structural tests should enforce bank content has no tabs anyway
(they also double as an internal delimiter defense in the
two-line stdout contract).

### B. Apply the strip at every emit surface, not at ingest

Stripping when a contributor's line lands in `scripts/species/*.json`
is easy to circumvent — a future contributor editing by hand, a
content-migration tool, or an LLM call that writes the bank (P6)
bypasses any ingest-time cleanup. Strip at the point the data
becomes a terminal write. There are typically three such points
for a Claude Code plugin:

1. Hook stdout (`hooks/*.sh` scripts on exit 0).
2. Slash-command output (SKILL.md dispatched scripts).
3. Status-line output (`statusline/*.sh`).

Each one is a separate defense: a control byte in a name field
reaches the transcript via all three, but the strip is local to
each emit function.

### C. Structural tests back up the strip

`tr` is an emit-time defense. A structural test on the content
source catches regressions earlier and gives contributors a fast
failure when they accidentally paste styled text:

```bash
@test "no control bytes in any species line bank" {
  for f in "$SPECIES_DIR"/*.json; do
    # jq -r decodes \u-escapes; we check the decoded bytes.
    local hits
    hits="$(jq -r '[ .line_banks | .. | strings | select(test("[\\x00-\\x1f\\x7f]")) ] | length' "$f")"
    [ "$hits" = "0" ] || { echo "$f has $hits lines with control bytes"; return 1; }
  done
}
```

See `tests/species_line_banks.bats` for an in-repo implementation.

### D. Extend the threat model when P6 (LLM-generated commentary) lands

An LLM-generated commentary line is author-controlled in a
stronger sense than a canned bank: the "author" now includes
prompt injections from tool output the LLM summarized. A
compromised dependency that prints a crafted error message
upstream of the LLM call can arrive as a transcript emission
if the emit surface trusts LLM output. The strip at emit stays
the right defense — the key is to apply it to the LLM path on
day one of P6, not retrofit it later.

## Why This Matters

Severity is high because the attack surface is broad and the
detection cost is high. Symptoms of a bad emit:

- A "buddy comment" that silently turns the user's terminal red
  for the rest of the session.
- A status-line segment that repositions the cursor and obscures
  the Claude Code prompt.
- A tool-output summary that contains a BEL byte, audibly
  beeping on every tool use.
- A downstream agent transcript parser that misattributes a
  commentary line to tool output because a CSI sequence consumed
  the line prefix.

None of these are "compromises" in the RCE sense. All of them
are trust-boundary violations that degrade the surface users
and agents rely on. They are cheap to prevent and expensive to
diagnose after the fact (especially for non-visible bytes like
NUL or DEL).

The transcript is not a private channel. Every plugin that
touches it should assume a reader with stricter rendering rules
than the user's terminal.

## When to Apply

- Implementing hook stdout emission, slash-command output, or
  status-line rendering for any Claude Code plugin.
- Reviewing a PR that adds a new text surface to the transcript
  (e.g., a new hook emission, a new status-line segment).
- Adding LLM-generated content to any transcript surface —
  prompt-injection-from-upstream content is author-controlled
  by a broader author set than the plugin's contributors.
- Accepting contributions to content files (line banks, name
  pools, SKILL.md instructions) — add the structural test as
  a CI-level check.

## Examples

### Before — author-controlled name flows through unchecked

```bash
_commentary_format() {
  local emoji="$1" name="$2" line="$3"
  line="${line//$'\n'/ }"        # newlines only
  printf '%s %s: "%s"' "$emoji" "$name" "$line"
}
```

A line like `"green[31mtest"` renders as a real color change
in the user's terminal.

### After — control bytes stripped at emit

```bash
_commentary_format() {
  local emoji="$1" name="$2" line="$3"
  name="$(printf '%s' "$name" | tr -d '[:cntrl:]')"
  line="$(printf '%s' "$line" | tr -d '[:cntrl:]')"
  printf '%s %s: "%s"' "$emoji" "$name" "$line"
}
```

### Bats assertion for emit hygiene

```bash
@test "Control bytes in author-controlled fields don't reach stdout" {
  local buddy
  buddy="$(jq -n --arg n $'bad\x1b[31mname\x07' '{
    buddy: { name: $n, species: "testfrog" }
  }')"
  _call PostToolUse "$(_session_json)" "$buddy"
  [[ "$_BUDDY_COMMENT_LINE" != *$'\x1b'* ]]
  [[ "$_BUDDY_COMMENT_LINE" != *$'\x07'* ]]
}
```

## Related

- [claude-code-plugin-hooks-json-schema-2026-04-20.md](./claude-code-plugin-hooks-json-schema-2026-04-20.md)
  — sibling doc covering the other "looks right, silently wrong"
  plugin-level trap around hook wiring.
- [claude-code-plugin-userconfig-manifest-schema-2026-04-21.md](./claude-code-plugin-userconfig-manifest-schema-2026-04-21.md)
  — also in the "live-smoke catches what unit tests miss" family.
- [bash-subshell-value-plus-json-return-2026-04-21.md](../best-practices/bash-subshell-value-plus-json-return-2026-04-21.md)
  — the two-line stdout contract this strip operates inside; the
  strip is what keeps the newline delimiter invariant.
- `scripts/hooks/commentary.sh:_commentary_format` — canonical
  in-repo implementation of the strip.
- `tests/species_line_banks.bats` — structural CI guard for content
  files.
