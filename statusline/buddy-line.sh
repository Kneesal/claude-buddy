#!/usr/bin/env bash
# buddy-line.sh — Buddy plugin status line (P4-3 simplified).
# Registered by the user via their own settings.json (plugin-level
# settings.json does not support statusLine — see docs/solutions/
# developer-experience/claude-code-plugin-scaffolding-gotchas-2026-04-16.md).
# Runs on every assistant turn plus idle refresh.
#
# Renders a single line — emoji + name + level — for ACTIVE buddies.
# The status line is the at-a-glance "yep, she's there" surface; the
# rich sprite menu lives in /buddy:stats. Format:
#
#   NO_BUDDY        -> "🥚 No buddy — /buddy:hatch"
#   ACTIVE >= 30    -> "<emoji> <name> Lv.<N>"  (rarity-colored)
#   ACTIVE <  30    -> "<emoji> Lv.<N>"          (name dropped)
#   CORRUPT         -> "⚠️ buddy state needs /buddy:reset"
#   FUTURE_VERSION  -> "⚠️ update plugin to read newer buddy.json"
#
# Legendary rarity uses a per-character rainbow cycle (via render.sh).
# Shiny prepends ✨. NO_COLOR strips ANSI everywhere. Exits 0 on every
# path — a status-line bug must never surface as a shell error.

_BUDDY_LINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/state.sh
if ! source "$_BUDDY_LINE_DIR/../scripts/lib/state.sh" 2>/dev/null; then
  echo ""
  exit 0
fi
# shellcheck source=../scripts/lib/render.sh
if ! source "$_BUDDY_LINE_DIR/../scripts/lib/render.sh" 2>/dev/null; then
  echo ""
  exit 0
fi

readonly FALLBACK_EMOJI="🐾"

_buddy_line_width() {
  if [[ -n "${COLUMNS:-}" && "$COLUMNS" =~ ^[0-9]+$ ]]; then
    printf '%s' "$COLUMNS"
    return 0
  fi
  local cols
  if cols="$(tput cols 2>/dev/null)" \
      && [[ "$cols" =~ ^[0-9]+$ ]] \
      && (( cols > 0 )); then
    printf '%s' "$cols"
    return 0
  fi
  printf '%s' 80
}

_buddy_line_species_emoji() {
  local species="$1"
  # Path-traversal guard: reject anything that doesn't look like a canonical
  # species id. Matches the discipline in scripts/status.sh + scripts/interact.sh.
  if [[ ! "$species" =~ ^[a-z][a-z0-9_-]*$ ]]; then
    printf '%s' "$FALLBACK_EMOJI"
    return 0
  fi
  local species_dir="${BUDDY_SPECIES_DIR:-$_BUDDY_LINE_DIR/../scripts/species}"
  local file="$species_dir/$species.json"
  if [[ ! -f "$file" ]]; then
    printf '%s' "$FALLBACK_EMOJI"
    return 0
  fi
  local emoji
  emoji="$(jq -r '.emoji // empty' "$file" 2>/dev/null)"
  if [[ -z "$emoji" ]]; then
    printf '%s' "$FALLBACK_EMOJI"
  else
    printf '%s' "$emoji"
  fi
}

_buddy_line_render_active() {
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
    _buddy_line_render_corrupt
    return 0
  fi

  local fields_raw
  fields_raw="$(printf '%s' "$json" | jq -r '
    (.buddy.species | gsub("[\\n\\r\\t]"; " ")),
    (.buddy.name    | gsub("[\\n\\r\\t]"; " ")),
    (.buddy.rarity  | gsub("[\\n\\r\\t]"; " ")),
    (.buddy.level // 0 | tostring),
    (.buddy.shiny // false | tostring)' 2>/dev/null)"
  if [[ -z "$fields_raw" ]]; then
    _buddy_line_render_corrupt
    return 0
  fi
  local -a parts=()
  readarray -t parts <<< "$fields_raw"
  local species="${parts[0]:-}" name="${parts[1]:-}" rarity="${parts[2]:-}"
  local level="${parts[3]:-0}" shiny="${parts[4]:-false}"

  local emoji
  emoji="$(_buddy_line_species_emoji "$species")"

  local sparkle=""
  [[ "$shiny" == "true" ]] && sparkle="✨ "

  local width
  width="$(_buddy_line_width)"

  # Build the inner text segment, then color-wrap it. Two width tiers:
  #   >=30: "<emoji> <name> Lv.<N>"
  #   <30:  "<emoji> Lv.<N>"
  local segment
  if (( width < 30 )); then
    segment="$emoji Lv.$level"
  else
    segment="$emoji $name Lv.$level"
  fi

  # Legendary uses per-char rainbow; other rarities are single-color via
  # _render_color_line (called inside render_name analog). render_name
  # only colors the name itself — but here we want the whole segment
  # colored, including the emoji and level. Reuse the render.sh helpers
  # by calling _render_color_line directly via render_name on the full
  # segment string (it's just a colored text wrapper).
  printf '%s' "$sparkle"
  render_name "$segment" "$rarity"
  printf '\n'
}

_buddy_line_render_corrupt() {
  echo "⚠️ buddy state needs /buddy:reset"
}

_buddy_line_render_future_version() {
  echo "⚠️ update plugin to read newer buddy.json"
}

_buddy_line_render_no_buddy() {
  echo "🥚 No buddy — /buddy:hatch"
}

_buddy_line_main() {
  if [[ ! -t 0 ]]; then
    timeout 0.1 cat >/dev/null 2>&1 || true
  fi

  local state
  state="$(buddy_load)"

  case "$state" in
    "$STATE_NO_BUDDY")
      _buddy_line_render_no_buddy
      ;;
    "$STATE_CORRUPT")
      _buddy_line_render_corrupt
      ;;
    "$STATE_FUTURE_VERSION")
      _buddy_line_render_future_version
      ;;
    *)
      _buddy_line_render_active "$state"
      ;;
  esac

  return 0
}

_buddy_line_main
exit 0
