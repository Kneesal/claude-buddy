#!/usr/bin/env bash
# render.sh — Visible-buddy render helpers (P4-3).
# Pure functions shared by scripts/status.sh, scripts/interact.sh, and
# statusline/buddy-line.sh. Every function honors $NO_COLOR. Every error
# path returns a graceful fallback and exits 0 — render surfaces never
# break the session.
#
# Public API:
#   render_rarity_color_open <rarity>
#   render_rarity_color_close
#   render_bar <value> <max> [width=20] [fill="▓"] [empty="░"]
#   render_stat_line <label> <value> <max> [width=20]
#   render_name <name> <rarity>
#   render_sprite_or_fallback <species_json_path> <rarity> [shiny=0]
#   render_speech_bubble <text> [width=40]
#
# No `set -euo pipefail` — matches the discipline in scripts/lib/state.sh.
# Errors are handled per-function.

if [[ -z "${BASH_VERSINFO[0]:-}" ]] || (( BASH_VERSINFO[0] < 4 )) || \
   (( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 1 )); then
  echo "buddy-render: requires bash 4.1+ (got ${BASH_VERSION:-unknown})" >&2
  return 1 2>/dev/null || exit 1
fi

if [[ "${_RENDER_SH_LOADED:-}" != "1" ]]; then
  _RENDER_SH_LOADED=1

  # Rarity → ANSI open code. legendary is handled per-character via the
  # rainbow palette below; the entry here is its single-color fallback for
  # callers that can't do per-char cycling.
  declare -gA _RENDER_RARITY_COLOR=(
    [common]=$'\033[90m'
    [uncommon]=$'\033[97m'
    [rare]=$'\033[94m'
    [epic]=$'\033[95m'
    [legendary]=$'\033[93m'
  )
  readonly _RENDER_RESET=$'\033[0m'

  # 6-color palette cycled per character for legendary (D7).
  declare -ga _RENDER_RAINBOW=(
    $'\033[91m'  # bright red
    $'\033[93m'  # bright yellow
    $'\033[92m'  # bright green
    $'\033[96m'  # bright cyan
    $'\033[94m'  # bright blue
    $'\033[95m'  # bright magenta
  )

  readonly _RENDER_FALLBACK_EMOJI="🐾"
fi

# --- color helpers -------------------------------------------------------

# Internal: emit one of the 6 rainbow colors. Caller passes a 0-based index.
_render_rainbow_at() {
  local idx=$(( ${1:-0} % 6 ))
  (( idx < 0 )) && idx=$(( idx + 6 ))
  printf '%s' "${_RENDER_RAINBOW[$idx]}"
}

render_rarity_color_open() {
  [[ -n "${NO_COLOR:-}" ]] && return 0
  local rarity="${1:-}"
  if [[ "$rarity" == "legendary" ]]; then
    # Re-seeded each call: pick a random palette entry. Callers that want
    # per-character cycling render via the sprite/name helpers below.
    _render_rainbow_at $(( RANDOM % 6 ))
    return 0
  fi
  printf '%s' "${_RENDER_RARITY_COLOR[$rarity]:-}"
}

render_rarity_color_close() {
  [[ -n "${NO_COLOR:-}" ]] && return 0
  printf '%s' "$_RENDER_RESET"
}

# Internal: wrap a single text line in rarity color, with rainbow per-char
# for legendary. Honors NO_COLOR.
_render_color_line() {
  local text="$1" rarity="$2"
  # User-controllable strings (buddy name, species, sprite lines) reach here.
  # Strip control bytes before emit so a hand-edited buddy.json / species.json
  # can't plant OSC escapes, clear the screen, or forge ANSI codes we didn't
  # inject ourselves. Project pattern — see docs/solutions/developer-experience/
  # claude-code-plugin-transcript-emit-as-trust-boundary-2026-04-21.md.
  text="$(printf '%s' "$text" | tr -d '[:cntrl:]')"
  if [[ -n "${NO_COLOR:-}" ]]; then
    printf '%s' "$text"
    return 0
  fi
  if [[ "$rarity" == "legendary" ]]; then
    # Per-character cycle, re-seeded for shimmer.
    #
    # bash ${var:i:1} is byte-indexed, so walking a UTF-8 string byte-by-byte
    # would splice ANSI escapes between the bytes of a single codepoint (shreds
    # emoji, box-drawing glyphs, the ✨ sparkle). Detect any non-ASCII byte and
    # fall back to a single-color wrap for the whole string in that case —
    # still shimmers per render, still colored per rarity, without mangling
    # the glyph stream.
    if LC_ALL=C printf '%s' "$text" | LC_ALL=C grep -q '[^[:print:][:space:]]'; then
      local color
      color="$(_render_rainbow_at $(( RANDOM % 6 )))"
      printf '%s%s%s' "$color" "$text" "$_RENDER_RESET"
      return 0
    fi
    local seed=$(( RANDOM % 6 ))
    local i=0 ch
    local len=${#text}
    while (( i < len )); do
      ch="${text:$i:1}"
      printf '%s%s%s' "$(_render_rainbow_at $(( seed + i )))" "$ch" "$_RENDER_RESET"
      i=$(( i + 1 ))
    done
    return 0
  fi
  local color="${_RENDER_RARITY_COLOR[$rarity]:-}"
  if [[ -z "$color" ]]; then
    printf '%s' "$text"
  else
    printf '%s%s%s' "$color" "$text" "$_RENDER_RESET"
  fi
}

render_name() {
  local name="${1:-}" rarity="${2:-common}"
  _render_color_line "$name" "$rarity"
}

# --- bars ----------------------------------------------------------------

render_bar() {
  local value="${1:-0}" max="${2:-100}"
  local width="${3:-20}"
  local fill="${4:-▓}" empty="${5:-░}"

  # Defensive — non-integer collapses to zero/safe defaults.
  [[ "$value" =~ ^-?[0-9]+$ ]] || value=0
  [[ "$max"   =~ ^-?[0-9]+$ ]] || max=0
  [[ "$width" =~ ^[0-9]+$    ]] || width=20

  local filled=0
  if (( max > 0 && value > 0 )); then
    if (( value >= max )); then
      filled=$width
    else
      filled=$(( value * width / max ))
      (( filled > width )) && filled=$width
    fi
  fi
  local emptyn=$(( width - filled ))
  (( emptyn < 0 )) && emptyn=0

  local out=""
  local i
  for (( i = 0; i < filled; i++ )); do out+="$fill"; done
  for (( i = 0; i < emptyn; i++ )); do out+="$empty"; done
  printf '%s' "$out"
}

render_stat_line() {
  local label="${1:-}" value="${2:-0}" max="${3:-0}" width="${4:-20}"
  local bar
  bar="$(render_bar "$value" "$max" "$width")"
  printf '  %-10s %s  %s/%s' "$label" "$bar" "$value" "$max"
}

# --- sprite + fallback ---------------------------------------------------

# Resolve a hat sprite by name from scripts/species/_hats.json. Returns the
# sprite string on stdout; empty on miss. Caller decides what to do with
# an empty return (render a blank reserved row).
_render_hat_lookup() {
  local hat_name="${1:-}"
  [[ -z "$hat_name" ]] && return 0
  local hats_dir="${BUDDY_SPECIES_DIR:-}"
  if [[ -z "$hats_dir" ]]; then
    # Walk up from this file's directory: scripts/lib/render.sh -> scripts/species
    local render_dir
    render_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 0
    hats_dir="$render_dir/../species"
  fi
  local hats_file="$hats_dir/_hats.json"
  [[ ! -f "$hats_file" ]] && return 0
  jq -r --arg name "$hat_name" '.hats[$name] // ""' "$hats_file" 2>/dev/null
}

# render_sprite_or_fallback <species_json_path> <rarity> [shiny=0] [hat_name=""] [eye=""]
#
# Renders a 5-row portrait:
#   Row 1: hat sprite (if hat_name provided and resolves) OR blank reserved row
#   Rows 2-5: sprite.base content from the species JSON, with {EYE} markers
#             substituted by the per-buddy eye glyph if provided
#
# The 5x12 grid is the shipped convention (see P4-4d). Species JSONs store
# 4 face rows with {EYE} placeholders; both row 1 and the eye glyph are
# composed at render time so accessories and per-buddy eye style can be
# swapped without re-baking the sprite. Defaults to · if no eye is provided.
render_sprite_or_fallback() {
  local path="${1:-}" rarity="${2:-common}" shiny="${3:-0}" hat_name="${4:-}" eye="${5:-·}"

  local emoji="$_RENDER_FALLBACK_EMOJI"
  local sprite_lines=""

  if [[ -f "$path" ]]; then
    local meta
    meta="$(jq -r '
      [
        (.emoji // ""),
        ((.sprite.base // []) | length | tostring)
      ] | @tsv
    ' "$path" 2>/dev/null)"
    if [[ -n "$meta" ]]; then
      local e n
      IFS=$'\t' read -r e n <<< "$meta"
      [[ -n "$e" ]] && emoji="$e"
      if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )); then
        # Pull lines newline-delimited and sanitize control bytes.
        # Each array entry arrives on its own line; preserve the \n separators
        # here — per-line control-byte stripping happens in _render_color_line
        # at emit time, so embedded ESC/BEL can't leak to the transcript.
        sprite_lines="$(jq -r '.sprite.base[]' "$path" 2>/dev/null)"
      fi
    fi
  fi

  local sparkle=""
  [[ "$shiny" == "1" || "$shiny" == "true" ]] && sparkle="✨ "

  if [[ -n "$sprite_lines" ]]; then
    # Row 1: hat overlay or blank reserved row. Always emit exactly one row
    # here so callers get a stable 5-row height regardless of cosmetics.
    local hat_row=""
    if [[ -n "$hat_name" ]]; then
      hat_row="$(_render_hat_lookup "$hat_name")"
    fi
    if [[ -z "$hat_row" ]]; then
      hat_row="            "  # 12-space blank reserved row
    fi
    printf '%s%s\n' "$sparkle" "$(_render_color_line "$hat_row" "$rarity")"
    sparkle=""  # sparkle only decorates the first emitted row

    # Rows 2-N: face content with {EYE} substitution, truncated to 10 lines
    # as a runaway guard. Bash 5.0+ treats `&` in the replacement string of
    # ${var//pat/repl} as "the matched pattern" (sed-like). Escape the eye
    # glyph defensively so an eye_pool containing `&` substitutes literally.
    local eye_safe="${eye//&/\\&}"
    local count=0
    local line rendered
    while IFS= read -r line; do
      (( count >= 10 )) && break
      rendered="${line//\{EYE\}/$eye_safe}"
      printf '%s\n' "$(_render_color_line "$rendered" "$rarity")"
      count=$(( count + 1 ))
    done <<< "$sprite_lines"
    return 0
  fi

  # Fallback box: 3-line, emoji centered. Width fixed at 7 cells visually
  # (emoji counts as 2 width in most terminals; padding accounts for that).
  local top="┌─────┐"
  local mid="│ ${sparkle}${emoji} │"
  local bot="└─────┘"
  printf '%s\n' "$(_render_color_line "$top" "$rarity")"
  printf '%s\n' "$(_render_color_line "$mid" "$rarity")"
  printf '%s\n' "$(_render_color_line "$bot" "$rarity")"
  return 0
}

# --- speech bubble -------------------------------------------------------

# Word-wrap a single string into lines no longer than $1 chars (best effort,
# byte-counted — fine for ASCII-ish content). Splits on spaces; long single
# tokens that exceed width get hard-broken.
_render_wrap() {
  local width="$1"; shift
  local text="$*"
  (( width < 1 )) && width=1
  local line="" word
  for word in $text; do
    if [[ -z "$line" ]]; then
      line="$word"
    elif (( ${#line} + 1 + ${#word} <= width )); then
      line+=" $word"
    else
      printf '%s\n' "$line"
      line="$word"
    fi
    # Hard-break a single oversized word.
    while (( ${#line} > width )); do
      printf '%s\n' "${line:0:$width}"
      line="${line:$width}"
    done
  done
  [[ -n "$line" ]] && printf '%s\n' "$line"
}

render_speech_bubble() {
  local text="${1:-}" width="${2:-40}"
  # Strip control bytes and collapse internal newlines/tabs to spaces.
  text="$(printf '%s' "$text" | tr '\t\n\r' '   ' | tr -d '[:cntrl:]')"
  # Trim leading/trailing whitespace.
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  [[ -z "$text" ]] && return 0

  [[ "$width" =~ ^[0-9]+$ ]] || width=40
  (( width < 8 )) && width=8

  local body
  body="$(_render_wrap "$width" "$text")"

  # Determine longest body line for bubble width.
  local max_len=0 line
  while IFS= read -r line; do
    (( ${#line} > max_len )) && max_len=${#line}
  done <<< "$body"
  (( max_len < 4 )) && max_len=4

  # Top + bottom: "  ____...____  "
  local bar=""
  local i
  for (( i = 0; i < max_len + 2; i++ )); do bar+="_"; done
  printf '  %s  \n' "$bar"

  # Body lines, padded to max_len.
  while IFS= read -r line; do
    printf ' < %-*s > \n' "$max_len" "$line"
  done <<< "$body"

  # Bottom with pointer ('v') at center.
  local under=""
  for (( i = 0; i < max_len + 2; i++ )); do under+="-"; done
  local mid=$(( (max_len + 2) / 2 ))
  # Replace char at mid with 'v'
  local left="${under:0:$mid}"
  local right="${under:$((mid+1))}"
  printf "  '%s%s%s'  \n" "$left" "v" "$right"
}
