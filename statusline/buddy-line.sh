#!/usr/bin/env bash
# buddy-line.sh — Buddy plugin status line
# Registered by the user via their own settings.json (plugin-level settings.json
# does NOT support statusLine — see docs/solutions/developer-experience/
# claude-code-plugin-scaffolding-gotchas-2026-04-16.md). Runs on every assistant
# turn plus idle refresh (refreshInterval=5).
#
# Renders one line describing the current buddy state:
#   NO_BUDDY        -> "🥚 No buddy — /buddy:hatch"
#   ACTIVE          -> "<icon> <name> (<Rarity> <species> · Lv.<level>) · <N> 🪙"
#   CORRUPT         -> "⚠️ buddy state needs /buddy:reset"
#   FUTURE_VERSION  -> "⚠️ update plugin to read newer buddy.json"
#
# Exits 0 on every path (even internal errors). A status-line bug must never
# surface to the user as a shell error.
#
# Honors $NO_COLOR (skips ANSI) and $COLUMNS (width-safe degradation).
# Reads and discards stdin — Claude Code may pipe a JSON payload; we ignore it.

# NOTE: No module-level `set -euo pipefail`. Matches the discipline in
# scripts/lib/state.sh — we source that library, so a stray `set -e` here
# could interact badly with its per-function error handling. Errors are
# handled explicitly per branch; the final catch-all still exits 0.

_BUDDY_LINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/state.sh
if ! source "$_BUDDY_LINE_DIR/../scripts/lib/state.sh" 2>/dev/null; then
  # Library missing or fails to load — render a harmless empty line and exit 0.
  # The status line must never break the session.
  echo ""
  exit 0
fi

readonly FALLBACK_EMOJI="🐾"

# ANSI color codes keyed by rarity. 256-color where possible, 16-color
# fallbacks where the terminal's palette might be narrow.
declare -A _BUDDY_LINE_COLOR=(
  [common]=$'\033[90m'       # bright black / grey
  [uncommon]=$'\033[97m'     # bright white (distinct from grey and from default)
  [rare]=$'\033[94m'         # bright blue
  [epic]=$'\033[95m'         # bright magenta / purple
  [legendary]=$'\033[93m'    # bright yellow / gold
)
readonly _BUDDY_LINE_RESET=$'\033[0m'

# Resolve terminal width with fallbacks:
#   1. $COLUMNS if set by the terminal (SIGWINCH-updated).
#   2. `tput cols` if tput is available and a terminal is attached.
#   3. 80 as a safe default.
_buddy_line_width() {
  if [[ -n "${COLUMNS:-}" && "$COLUMNS" =~ ^[0-9]+$ ]]; then
    printf '%s' "$COLUMNS"
    return 0
  fi
  local cols
  # `tput cols` writes "0" to stdout (and an error to stderr) when there's
  # no attached terminal. Accepting 0 would force every render into the
  # narrow-line band even on wide terminals, so require cols > 0.
  if cols="$(tput cols 2>/dev/null)" \
      && [[ "$cols" =~ ^[0-9]+$ ]] \
      && (( cols > 0 )); then
    printf '%s' "$cols"
    return 0
  fi
  printf '%s' 80
}

# Resolve the species emoji, falling back to FALLBACK_EMOJI if the species
# file is missing, unreadable, or has no `.emoji` field.
_buddy_line_species_emoji() {
  local species="$1"
  # Allow BUDDY_SPECIES_DIR override for tests; default to the plugin's species dir.
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

# Render the ACTIVE state from an envelope JSON string in $1.
# Width-safe: >=40 full line; 30-39 drops tokens; <30 drops rarity qualifier too.
_buddy_line_render_active() {
  local json="$1"
  # Validate the envelope shape upstream in jq, then extract fields. Two jq
  # calls instead of one, but the separation removes a subtle bash gotcha:
  # `IFS=$'\t' read -a` collapses consecutive tabs because tab is whitespace,
  # so a null/empty buddy (which produces "\t\t\t0\tfalse\t0") would be
  # misparsed. Validating upstream lets us skip the split entirely for
  # malformed envelopes.
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

  # Envelope is valid — extract all six fields in one jq invocation,
  # newline-delimited so bash readarray preserves empty fields correctly.
  # `@tsv` collapses on tab (whitespace), `@csv` quotes strings; newlines are
  # the simplest delimiter that round-trips cleanly.
  #
  # String fields (species / name / rarity) are gsub'd to strip embedded
  # newlines and tabs — a hand-edited buddy.json with "name": "Foo\nBar"
  # would otherwise split across multiple readarray slots and shift every
  # field after name one position to the left. Integer/boolean fields are
  # tostring'd so they never introduce whitespace.
  local fields_raw
  fields_raw="$(printf '%s' "$json" | jq -r '
    (.buddy.species | gsub("[\\n\\r\\t]"; " ")),
    (.buddy.name    | gsub("[\\n\\r\\t]"; " ")),
    (.buddy.rarity  | gsub("[\\n\\r\\t]"; " ")),
    (.buddy.level // 0 | tostring),
    (.buddy.shiny // false | tostring),
    (.tokens.balance // 0 | tostring)' 2>/dev/null)"
  if [[ -z "$fields_raw" ]]; then
    # jq failed for an unexpected reason after passing the validator (OOM, signal).
    # Render the repair marker rather than a half-populated line.
    _buddy_line_render_corrupt
    return 0
  fi
  local -a parts=()
  readarray -t parts <<< "$fields_raw"
  local species="${parts[0]:-}" name="${parts[1]:-}" rarity="${parts[2]:-}"
  local level="${parts[3]:-0}" shiny="${parts[4]:-false}" balance="${parts[5]:-0}"

  local emoji
  emoji="$(_buddy_line_species_emoji "$species")"

  # Shiny sparkle prefix. Stubbed for P7-2: the .buddy.shiny flag is always
  # false in P1-2's roll_buddy output, but rendering reads it now so turning
  # it on later is a data-only change.
  local sparkle=""
  if [[ "$shiny" == "true" ]]; then
    sparkle="✨ "
  fi

  # Bash parameter expansion titlecases the first letter. Requires bash 4.0+,
  # which is guaranteed by the 4.1+ floor in state.sh. Avoids a sed fork and
  # the GNU-only `\U` replacement escape (BSD sed on macOS doesn't support it).
  local rarity_disp="${rarity^}"

  # ANSI color on the rarity qualifier only. Honor NO_COLOR.
  local color="" reset=""
  if [[ -z "${NO_COLOR:-}" ]]; then
    color="${_BUDDY_LINE_COLOR[$rarity]:-}"
    [[ -n "$color" ]] && reset="$_BUDDY_LINE_RESET"
  fi

  local width
  width="$(_buddy_line_width)"

  # Three width bands:
  #   >=40: "✨ 🦎 Pip (Rare Axolotl · Lv.3) · 4 🪙"
  #   30-39: drop tokens segment
  #   <30: also drop rarity qualifier -> "🦎 Pip (Lv.3)"
  if (( width < 30 )); then
    printf '%s%s %s (Lv.%s)\n' "$sparkle" "$emoji" "$name" "$level"
  elif (( width < 40 )); then
    printf '%s%s %s (%s%s %s%s · Lv.%s)\n' \
      "$sparkle" "$emoji" "$name" \
      "$color" "$rarity_disp" "$species" "$reset" \
      "$level"
  else
    printf '%s%s %s (%s%s %s%s · Lv.%s) · %s 🪙\n' \
      "$sparkle" "$emoji" "$name" \
      "$color" "$rarity_disp" "$species" "$reset" \
      "$level" "$balance"
  fi
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
  # Drain stdin. Claude Code pipes a JSON payload (model/workspace/cost);
  # we read and discard it. The TTY guard skips the drain entirely for
  # interactive use, where there's no payload to consume.
  #
  # The drain is wrapped in `timeout 0.1` to defend against a pipe-deadlock
  # scenario: if the parent process keeps the write-end open past script
  # launch, bare `cat` would block until EOF and never return. 100ms is
  # far longer than any legitimate Claude Code payload takes to arrive,
  # and even if the timeout fires the status line still renders correctly.
  # `|| true` suppresses the non-zero exit from timeout on the hang case.
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

  # Unconditional exit 0. Even if a renderer errored above, we already printed
  # something reasonable. The status line must never surface errors.
  return 0
}

_buddy_line_main
exit 0
