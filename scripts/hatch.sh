#!/usr/bin/env bash
# hatch.sh — Buddy plugin hatch command
# Dispatch target for /buddy:hatch. Composes the full buddy.json envelope
# around P1-2's roll_buddy inner object, and handles the four-state matrix
# from the origin plan D5 (NO_BUDDY / ACTIVE+enough-tokens / ACTIVE+insufficient /
# CORRUPT) plus the FUTURE_VERSION sentinel state.sh exposes.
#
# Exit conventions (see plan key decision):
#   0 — user-visible outcome handled cleanly (includes gentle rejections:
#       missing --confirm, insufficient tokens, CORRUPT, FUTURE_VERSION).
#   1 — internal error (flock timeout, disk full, invalid roll, etc).
#
# Output: all user-facing text goes to stdout so SKILL.md can relay it
# verbatim. Internal diagnostics go to stderr via the library _*_log helpers.

# NOTE: No `set -euo pipefail` at top — we source libraries that document
# sourcing-safety, and this script is the reference shape future hook scripts
# will mirror. Error handling is explicit per branch.

_HATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/state.sh
source "$_HATCH_DIR/lib/state.sh" || exit 1
# shellcheck source=scripts/lib/rng.sh
source "$_HATCH_DIR/lib/rng.sh" || exit 1
# shellcheck source=scripts/lib/evolution.sh
source "$_HATCH_DIR/lib/evolution.sh" || exit 1

readonly REROLL_COST=10

# ISO-8601 UTC timestamp, e.g. 2026-04-19T12:34:56Z.
_hatch_now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Compose the first-hatch envelope. Reads inner-buddy JSON from $1, new pity
# counter from $2. Writes the full envelope to stdout.
#
# P4-1: the inner buddy object gets a .signals child baked in from the
# canonical skeleton so new hatches ship with the full four-axis shape.
# Existing (pre-P4-1) buddies are picked up lazily on their first hook
# fire via jq `// default` reads in scripts/hooks/signals.sh.
_hatch_compose_first_envelope() {
  local inner="$1"
  local next_pity="$2"
  local now
  now="$(_hatch_now_utc)"
  local signals
  signals="$(signals_skeleton)"
  local cosmetics
  cosmetics="$(_hatch_roll_cosmetics "$inner")"
  jq -n -c \
    --argjson buddy "$inner" \
    --argjson signals "$signals" \
    --argjson cosmetics "$cosmetics" \
    --arg hatchedAt "$now" \
    --arg windowStartedAt "$now" \
    --argjson pityCounter "$next_pity" \
    '{
      schemaVersion: 1,
      hatchedAt: $hatchedAt,
      lastRerollAt: null,
      buddy: ($buddy + {signals: $signals, cosmetics: $cosmetics}),
      tokens: {
        balance: 0,
        earnedToday: 0,
        windowStartedAt: $windowStartedAt
      },
      meta: {
        totalHatches: 1,
        pityCounter: $pityCounter
      }
    }'
}

# _hatch_roll_cosmetics <inner_buddy_json>
#
# Returns a cosmetics JSON object on stdout. Today that's just {hat: "name"} or
# {hat: null}. 40% hat-roll for non-common rarities; commons never roll a hat
# (keeps the visual "this one's special" signal crisp, matching the reference
# aesthetic's hat-gating convention).
_hatch_roll_cosmetics() {
  local inner="$1"
  local rarity
  rarity="$(printf '%s' "$inner" | jq -r '.rarity' 2>/dev/null)"
  if [[ "$rarity" == "common" ]]; then
    printf '{"hat": null}'
    return 0
  fi
  # 40% roll. $RANDOM is seedable via BUDDY_RNG_SEED in tests; not using
  # rng.sh's public API here because that's reserved for species/stats rolls.
  local roll=$(( RANDOM % 100 ))
  if (( roll < 40 )); then
    printf '{"hat": "crown"}'
  else
    printf '{"hat": null}'
  fi
}

# Compose the reroll envelope. Reads existing envelope from $1, new inner from
# $2, new pity counter from $3, reroll cost from $4. Writes to stdout.
#
# Preserves: tokens.earnedToday, tokens.windowStartedAt.
# Updates: tokens.balance -= cost; meta.totalHatches += 1; meta.pityCounter;
#          lastRerollAt = now; buddy = $inner; hatchedAt unchanged.
_hatch_compose_reroll_envelope() {
  local existing="$1"
  local inner="$2"
  local next_pity="$3"
  local cost="$4"
  local now
  now="$(_hatch_now_utc)"
  local signals
  signals="$(signals_skeleton)"
  # P4-1 / R6: a reroll wipes level/form/signals (pure-growth progression
  # means the new buddy starts fresh). The new inner object does not
  # carry signals (rng.sh defers shape ownership to P4-1), so bake the
  # skeleton in here alongside the wholesale .buddy replacement.
  # P4-4d: cosmetics re-roll per new rarity (same rules as first hatch).
  local cosmetics
  cosmetics="$(_hatch_roll_cosmetics "$inner")"
  printf '%s' "$existing" | jq -c \
    --argjson buddy "$inner" \
    --argjson signals "$signals" \
    --argjson cosmetics "$cosmetics" \
    --arg lastRerollAt "$now" \
    --argjson pityCounter "$next_pity" \
    --argjson cost "$cost" \
    '.lastRerollAt = $lastRerollAt
     | .buddy = ($buddy + {signals: $signals, cosmetics: $cosmetics})
     | .tokens.balance = (.tokens.balance - $cost)
     | .meta.totalHatches = (.meta.totalHatches + 1)
     | .meta.pityCounter = $pityCounter'
}

# First hatch — NO_BUDDY state. No confirm required.
_hatch_first() {
  # Fresh buddy has no pity history — start at 0.
  if ! roll_buddy 0 >/dev/null; then
    echo "buddy-hatch: roll_buddy failed" >&2
    return 1
  fi
  local inner="$_RNG_ROLL"
  local rarity species name
  rarity="$(printf '%s' "$inner" | jq -r '.rarity')" || return 1
  species="$(printf '%s' "$inner" | jq -r '.species')" || return 1
  name="$(printf '%s' "$inner" | jq -r '.name')" || return 1

  # next_pity_counter uses command substitution deliberately: unlike roll_buddy
  # it's pure arithmetic with no LCG side effects (see rng.sh), so the subshell
  # boundary doesn't wipe RNG state. The asymmetry with roll_buddy above is
  # intentional, not a copy-paste miss.
  local next_pity
  if ! next_pity="$(next_pity_counter 0 "$rarity")"; then
    echo "buddy-hatch: next_pity_counter failed" >&2
    return 1
  fi

  local envelope
  if ! envelope="$(_hatch_compose_first_envelope "$inner" "$next_pity")"; then
    echo "buddy-hatch: failed to compose first-hatch envelope" >&2
    return 1
  fi

  if ! printf '%s' "$envelope" | buddy_save; then
    echo "buddy-hatch: buddy_save failed" >&2
    return 1
  fi

  printf 'Hatched a %s %s named %s! Run /buddy:stats to see more.\n' \
    "$rarity" "$species" "$name"
}

# Reroll — ACTIVE state. $1 is the current envelope JSON, $2 is confirm (0/1).
_hatch_reroll() {
  local current="$1"
  local confirm="$2"

  local level form balance pity
  level="$(printf '%s' "$current" | jq -r '.buddy.level')"
  form="$(printf '%s' "$current" | jq -r '.buddy.form')"
  balance="$(printf '%s' "$current" | jq -r '.tokens.balance')"
  pity="$(printf '%s' "$current" | jq -r '.meta.pityCounter')"

  # Defensive: reject nonsense values we got from the envelope.
  if ! [[ "$balance" =~ ^-?[0-9]+$ && "$pity" =~ ^[0-9]+$ && "$level" =~ ^[0-9]+$ ]]; then
    echo "buddy-hatch: buddy.json envelope is missing required fields (level/balance/pityCounter)" >&2
    return 1
  fi
  # form defaults to "base" if the envelope was hand-edited to null/missing — keeps the
  # user-facing reroll-consequences message readable without a separate guard branch.
  [[ -z "$form" || "$form" == "null" ]] && form="base"

  # Token check runs before the --confirm gate: plan R4 says insufficient-tokens
  # rejection fires "with or without --confirm" — the user shouldn't see a reroll
  # consequences prompt for an action they can't afford.
  if (( balance < REROLL_COST )); then
    local need=$(( REROLL_COST - balance ))
    printf 'Need %d more tokens. Earn 1 per active session-hour.\n' "$need"
    return 0
  fi

  if (( confirm == 0 )); then
    printf 'Reroll will wipe your Lv.%s %s form. Run /buddy:hatch --confirm to continue.\n' \
      "$level" "$form"
    return 0
  fi

  if ! roll_buddy "$pity" >/dev/null; then
    echo "buddy-hatch: roll_buddy failed" >&2
    return 1
  fi
  local inner="$_RNG_ROLL"
  local rarity species name
  rarity="$(printf '%s' "$inner" | jq -r '.rarity')" || return 1
  species="$(printf '%s' "$inner" | jq -r '.species')" || return 1
  name="$(printf '%s' "$inner" | jq -r '.name')" || return 1

  # next_pity_counter uses command substitution deliberately: unlike roll_buddy
  # it's pure arithmetic with no LCG side effects (see rng.sh), so the subshell
  # boundary doesn't wipe RNG state. The asymmetry with roll_buddy above is
  # intentional, not a copy-paste miss.
  local next_pity
  if ! next_pity="$(next_pity_counter "$pity" "$rarity")"; then
    echo "buddy-hatch: next_pity_counter failed" >&2
    return 1
  fi

  local envelope
  if ! envelope="$(_hatch_compose_reroll_envelope "$current" "$inner" "$next_pity" "$REROLL_COST")"; then
    echo "buddy-hatch: failed to compose reroll envelope" >&2
    return 1
  fi

  if ! printf '%s' "$envelope" | buddy_save; then
    echo "buddy-hatch: buddy_save failed" >&2
    return 1
  fi

  local new_balance=$(( balance - REROLL_COST ))
  printf 'Rerolled into a %s %s named %s. %d tokens remaining.\n' \
    "$rarity" "$species" "$name" "$new_balance"
}

_hatch_main() {
  local confirm=0
  if (( $# > 1 )); then
    echo "Usage: hatch.sh [--confirm]" >&2
    return 1
  fi
  if (( $# == 1 )); then
    case "$1" in
      --confirm) confirm=1 ;;
      *)
        echo "Usage: hatch.sh [--confirm]" >&2
        return 1
        ;;
    esac
  fi

  local state
  state="$(buddy_load)"

  case "$state" in
    "$STATE_NO_BUDDY")
      _hatch_first
      return $?
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
      _hatch_reroll "$state" "$confirm"
      return $?
      ;;
  esac
}

_hatch_main "$@"
