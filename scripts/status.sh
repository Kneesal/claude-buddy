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

# Render the full ACTIVE-state report from an envelope JSON on stdin.
_status_render_active() {
  local json="$1"
  # One jq invocation extracts all the fields we need, tab-separated, so we
  # pay one fork instead of nine. Order matches the IFS split below.
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
      echo "Buddy state needs repair. Run /buddy:reset or restore from backup."
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
