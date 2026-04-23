#!/usr/bin/env bash
# interact.sh — Buddy plugin /buddy:interact target.
# Read-only: prints the buddy's sprite plus a speech bubble with one
# line drawn from the species' Interact bank. Does NOT mutate any state
# (no shuffle-bag advance, no commentsThisSession bump, no cooldowns).
# That discipline keeps the commentary engine's hook-driven budget
# sacred — see plan D4 of P4-3.
#
# Always exits 0 even on internal failure: a render command must never
# break the session.

_INTERACT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/state.sh
source "$_INTERACT_DIR/lib/state.sh" || exit 1
# shellcheck source=scripts/lib/render.sh
source "$_INTERACT_DIR/lib/render.sh" || exit 1

_interact_species_dir() {
  if [[ -n "${BUDDY_SPECIES_DIR:-}" ]]; then
    printf '%s' "$BUDDY_SPECIES_DIR"
    return 0
  fi
  printf '%s/species' "$_INTERACT_DIR"
}

_interact_species_file() {
  local species="$1"
  [[ "$species" =~ ^[a-z][a-z0-9_-]*$ ]] || return 1
  printf '%s/%s.json' "$(_interact_species_dir)" "$species"
}

_interact_render_active() {
  local json="$1"

  local valid
  valid="$(printf '%s' "$json" | jq -r '
    if (.buddy | type) != "object" then "no"
    elif (.buddy.species // "" | length) == 0 then "no"
    elif (.buddy.name // "" | length) == 0 then "no"
    elif (.buddy.rarity // "" | length) == 0 then "no"
    else "yes"
    end' 2>/dev/null)"
  if [[ "$valid" != "yes" ]]; then
    echo "Buddy state needs repair. Run /buddy:reset or restore from backup."
    return 0
  fi

  local fields_raw
  fields_raw="$(printf '%s' "$json" | jq -r '
    (.buddy.name    | gsub("[\\n\\r\\t]"; " ")),
    (.buddy.species | gsub("[\\n\\r\\t]"; " ")),
    (.buddy.rarity  | gsub("[\\n\\r\\t]"; " ")),
    (.buddy.shiny   // false | tostring)
  ' 2>/dev/null)"

  local -a parts=()
  readarray -t parts <<< "$fields_raw"
  local name="${parts[0]}" species="${parts[1]}" rarity="${parts[2]}" shiny="${parts[3]:-false}"
  local shiny_flag=0
  [[ "$shiny" == "true" ]] && shiny_flag=1

  local species_file
  species_file="$(_interact_species_file "$species")" || species_file=""

  # Pick a line from species.line_banks.Interact.default. If empty (the
  # current shipped state — content pass to follow), use a placeholder
  # built from the buddy's name. Pure random per call (D4 + Deferred).
  local line=""
  if [[ -f "$species_file" ]]; then
    local count
    count="$(jq -r '(.line_banks.Interact.default // []) | length' "$species_file" 2>/dev/null)"
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
      local idx=$(( RANDOM % count ))
      line="$(jq -r --argjson i "$idx" '.line_banks.Interact.default[$i]' "$species_file" 2>/dev/null)"
    fi
  fi
  if [[ -z "$line" || "$line" == "null" ]]; then
    line="$name looks at you curiously."
  fi

  # Speech bubble first, then sprite below — D4 / deferred-question
  # pick: bubble-above-sprite reads cleaner than sprite-left at 80 cols.
  render_speech_bubble "$line" 40
  printf '%s\n' "$(render_sprite_or_fallback "$species_file" "$rarity" "$shiny_flag")"
}

_interact_main() {
  if (( $# > 0 )); then
    echo "Usage: interact.sh" >&2
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
      _interact_render_active "$state"
      return 0
      ;;
  esac
}

_interact_main "$@"
