#!/usr/bin/env bash
# status.sh — Buddy plugin status command
# Dispatch target for /buddy:stats (the ticket's `/buddy` status-view slot —
# plugin skills are always namespaced, see docs/solutions/developer-experience/
# claude-code-plugin-scaffolding-gotchas-2026-04-16.md).
#
# Reads state via buddy_load and prints a human-readable report per the four
# state matrix. Never mutates state. Always exits 0 (user-visible output even
# for CORRUPT / FUTURE_VERSION; those are diagnostics, not errors).

_STATUS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/state.sh
source "$_STATUS_DIR/lib/state.sh" || exit 1

# Placeholder XP ceiling until P4-1 ships the real curve.
# Umbrella-plan formula: xpForLevel(n) = 50 * n * (n + 1). Evaluated at n=1
# that's 50*1*2 = 100. P4-1 replaces this constant with a real per-level call
# and updates the XP line below to show "xp / xpForLevel(level)".
readonly NEXT_LEVEL_XP_PLACEHOLDER=100

# Render the "buddy state needs repair" message. Used both for the CORRUPT
# sentinel path and for schema-valid envelopes that fail the shape check in
# _status_render_active (null .buddy, missing required fields, etc).
_status_render_repair() {
  echo "Buddy state needs repair. Run /buddy:reset or restore from backup."
}

# Render the full ACTIVE-state report from an envelope JSON on stdin.
_status_render_active() {
  local json="$1"

  # Validate the envelope shape upstream. `buddy_load` only screens for parse
  # errors and schema version — a valid-JSON envelope with `.buddy = null` or
  # an empty `.buddy` object slips past it and lands here. The @tsv + IFS-tab
  # read path below cannot handle consecutive empty fields (bash collapses
  # them because tab is whitespace), so catching malformed envelopes here
  # keeps the happy path simple and the error path correct.
  local valid
  valid="$(printf '%s' "$json" | jq -r '
    if (.buddy | type) != "object" then "no"
    elif (.buddy.species // "" | length) == 0 then "no"
    elif (.buddy.name // "" | length) == 0 then "no"
    elif (.buddy.rarity // "" | length) == 0 then "no"
    else "yes"
    end' 2>/dev/null)"
  if [[ "$valid" != "yes" ]]; then
    _status_render_repair
    return 0
  fi

  # One jq invocation extracts all the fields we need, tab-separated, so we
  # pay one fork instead of twelve. Order matches the IFS split below.
  # Safe now that the validator above guarantees the required string fields
  # are non-empty — `@tsv` + `IFS=$'\t' read` would otherwise collapse leading
  # empties (see statusline/buddy-line.sh for a renderer that needed the
  # newline-delimited workaround because it accepts more shape variance).
  local fields
  if ! fields="$(printf '%s' "$json" | jq -r '[
      .buddy.name,
      .buddy.species,
      .buddy.rarity,
      .buddy.form,
      .buddy.level,
      .buddy.xp,
      .buddy.stats.debugging,
      .buddy.stats.patience,
      .buddy.stats.chaos,
      .buddy.stats.wisdom,
      .buddy.stats.snark,
      .tokens.balance
    ] | @tsv')"; then
    echo "buddy-status: failed to parse envelope" >&2
    return 1
  fi

  local name species rarity form level xp debugging patience chaos wisdom snark balance
  IFS=$'\t' read -r name species rarity form level xp \
    debugging patience chaos wisdom snark balance <<< "$fields"

  # Capitalize rarity for display (common -> Common). Keep species lowercase
  # since species IDs are canonically lowercase in species files.
  local rarity_disp="${rarity^}"

  printf '%s — %s %s (Lv.%s %s form)\n' "$name" "$rarity_disp" "$species" "$level" "$form"
  printf '  XP: %s / %s\n' "$xp" "$NEXT_LEVEL_XP_PLACEHOLDER"
  printf '  Stats: debugging %s, patience %s, chaos %s, wisdom %s, snark %s\n' \
    "$debugging" "$patience" "$chaos" "$wisdom" "$snark"
  printf '  Tokens: %s\n' "$balance"
}

_status_main() {
  if (( $# > 0 )); then
    echo "Usage: status.sh" >&2
    return 1
  fi

  local state
  state="$(buddy_load)"

  case "$state" in
    "$STATE_NO_BUDDY")
      echo "No buddy yet. Run /buddy:hatch to hatch one."
      return 0
      ;;
    "$STATE_CORRUPT")
      _status_render_repair
      return 0
      ;;
    "$STATE_FUTURE_VERSION")
      echo "Your buddy.json was written by a newer plugin version. Update the plugin to read it."
      return 0
      ;;
    *)
      _status_render_active "$state"
      return 0
      ;;
  esac
}

_status_main "$@"
