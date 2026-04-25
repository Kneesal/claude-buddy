#!/usr/bin/env bash
# status.sh — Buddy plugin status command
# Dispatch target for /buddy:stats. Renders a menu-style panel:
# sprite + header + XP bar + 5 stat bars + signal glyph strip + footer.
#
# Reads state via buddy_load. Never mutates state. Always exits 0 —
# CORRUPT / FUTURE_VERSION / NO_BUDDY render diagnostic messages, not errors.

_STATUS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/state.sh
# Render surfaces must exit 0 on internal failure (matches the rest of the
# plugin's discipline). A library that fails to load makes us emit an empty
# line and leave gracefully rather than break the user's session.
source "$_STATUS_DIR/lib/state.sh" || { echo ""; exit 0; }
# shellcheck source=scripts/lib/evolution.sh
source "$_STATUS_DIR/lib/evolution.sh" || { echo ""; exit 0; }
# shellcheck source=scripts/lib/render.sh
source "$_STATUS_DIR/lib/render.sh" || { echo ""; exit 0; }

_status_render_repair() {
  echo "Buddy state needs repair. Run /buddy:reset or restore from backup."
}

# Resolve the species directory (honors BUDDY_SPECIES_DIR override like
# the other surfaces). Falls back to <repo>/scripts/species.
_status_species_dir() {
  if [[ -n "${BUDDY_SPECIES_DIR:-}" ]]; then
    printf '%s' "$BUDDY_SPECIES_DIR"
    return 0
  fi
  printf '%s/species' "$_STATUS_DIR"
}

# Resolve the species file path. Guards against path-traversal via
# species name (same discipline as buddy-line.sh).
_status_species_file() {
  local species="$1"
  # Reject species names that escape the species dir.
  [[ "$species" =~ ^[a-z][a-z0-9_-]*$ ]] || return 1
  local dir
  dir="$(_status_species_dir)" || return 1
  printf '%s/%s.json' "$dir" "$species"
}

# Render the full ACTIVE-state menu from an envelope JSON in $1.
_status_render_active() {
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
    _status_render_repair
    return 0
  fi

  # Pull every field we need in one jq invocation. Newline-delimited to
  # survive empty fields (tab would collapse under IFS=$'\t' read).
  local fields_raw
  fields_raw="$(printf '%s' "$json" | jq -r '
    (.buddy.name    | gsub("[\\n\\r\\t]"; " ")),
    (.buddy.species | gsub("[\\n\\r\\t]"; " ")),
    (.buddy.rarity  | gsub("[\\n\\r\\t]"; " ")),
    (.buddy.form    // "base"),
    (.buddy.level   // 1 | tostring),
    (.buddy.xp      // 0 | tostring),
    (.buddy.shiny   // false | tostring),
    (.buddy.stats.debugging // 0 | tostring),
    (.buddy.stats.patience  // 0 | tostring),
    (.buddy.stats.chaos     // 0 | tostring),
    (.buddy.stats.wisdom    // 0 | tostring),
    (.buddy.stats.snark     // 0 | tostring),
    (.buddy.signals.consistency.streakDays   // 0 | tostring),
    (.buddy.signals.variety.toolsUsed        // {} | keys | length | tostring),
    (.buddy.signals.quality.successfulEdits  // 0 | tostring),
    (.buddy.signals.quality.totalEdits       // 0 | tostring),
    (.buddy.signals.chaos.errors             // 0 | tostring),
    (.buddy.signals.chaos.repeatedEditHits   // 0 | tostring),
    (.tokens.balance // 0 | tostring),
    (.buddy.cosmetics.hat // "")
  ' 2>/dev/null)"
  if [[ -z "$fields_raw" ]]; then
    _status_render_repair
    return 0
  fi

  local -a parts=()
  readarray -t parts <<< "$fields_raw"
  local name="${parts[0]}" species="${parts[1]}" rarity="${parts[2]}" form="${parts[3]}"
  local level="${parts[4]}" xp="${parts[5]}" shiny="${parts[6]}"
  local debugging="${parts[7]}" patience="${parts[8]}" chaos="${parts[9]}"
  local wisdom="${parts[10]}" snark="${parts[11]}"
  local streak="${parts[12]}" tools_used="${parts[13]}"
  local edits_ok="${parts[14]}" edits_total="${parts[15]}"
  local errors="${parts[16]}" repeats="${parts[17]}"
  local balance="${parts[18]}"
  local hat_name="${parts[19]:-}"

  local rarity_disp="${rarity^}"
  local xp_ceiling
  xp_ceiling="$(xpForLevel "$level")"
  # "Lv.N+1 in K" hint.
  local next_level=$(( level + 1 ))
  local xp_delta=$(( xp_ceiling - xp ))
  (( xp_delta < 0 )) && xp_delta=0

  local shiny_flag=0
  [[ "$shiny" == "true" ]] && shiny_flag=1

  # Sprite block.
  local species_file
  species_file="$(_status_species_file "$species")" || species_file=""
  local sprite
  sprite="$(render_sprite_or_fallback "$species_file" "$rarity" "$shiny_flag" "$hat_name")"
  printf '%s\n' "$sprite"

  # Header line: name — Rarity species (Lv.N form)
  local name_colored
  name_colored="$(render_name "$name" "$rarity")"
  printf '%s — %s %s (Lv.%s %s form)\n' \
    "$name_colored" "$rarity_disp" "$species" "$level" "$form"

  # XP bar
  local xp_bar
  xp_bar="$(render_bar "$xp" "$xp_ceiling" 20)"
  if (( level >= MAX_LEVEL )); then
    printf '  %-10s %s  %s/%s  (max level)\n' "XP" "$xp_bar" "$xp" "$xp_ceiling"
  else
    printf '  %-10s %s  %s/%s  (Lv.%s in %s)\n' \
      "XP" "$xp_bar" "$xp" "$xp_ceiling" "$next_level" "$xp_delta"
  fi

  # Rarity stat bars. rng.sh clamps rarity stats to [0, 100] (see
  # scripts/lib/rng.sh:roll_stats — peak_hi/dump_hi/mid_hi ceiling at 100).
  # A prior comment here claimed "max 10 per species schema" which was wrong
  # — caught by ce:review 20260423-233451.
  render_stat_line "debugging" "$debugging" 100 20; printf '\n'
  render_stat_line "patience"  "$patience"  100 20; printf '\n'
  render_stat_line "chaos"     "$chaos"     100 20; printf '\n'
  render_stat_line "wisdom"    "$wisdom"    100 20; printf '\n'
  render_stat_line "snark"     "$snark"     100 20; printf '\n'

  # Signals glyph strip.
  printf '  🔥 %s-day · 🧰 %s tools · ✓ %s/%s edits · ⚡ %s repeats · 🪙 %s\n' \
    "$streak" "$tools_used" "$edits_ok" "$edits_total" "$repeats" "$balance"

  # Footer.
  printf '  ━ /buddy:interact · /buddy:install-statusline · /buddy:hatch --confirm to reroll ━\n'
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
