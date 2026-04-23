#!/usr/bin/env bash
# bake-sprites.sh — Contributor-time tool.
#
# Converts each `assets/species/<name>.png` into a Unicode-sextant silhouette
# via chafa, strips ANSI/color codes, and writes the resulting lines into
# `scripts/species/<name>.json` under `.sprite.base`.
#
# Per the P4-4 plan D2: we commit Unicode-block characters only — no embedded
# ANSI. `scripts/lib/render.sh` applies rarity color at render time on top of
# the baked silhouette, which keeps the legendary rainbow + $NO_COLOR paths
# working unchanged.
#
# Usage:
#   bash scripts/bake-sprites.sh          # bake every species
#   bash scripts/bake-sprites.sh --check  # bake to stdout, don't write
#   bash scripts/bake-sprites.sh --help
#
# Requires chafa (tested against 1.14.x). Exits 1 and prints an install hint
# on any other platform if chafa is missing. Idempotent: running twice with
# the same source PNGs produces byte-identical species JSONs.

set -uo pipefail

BAKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$BAKE_DIR/.." && pwd)"
ASSETS_DIR="$REPO_ROOT/assets/species"
SPECIES_DIR="$REPO_ROOT/scripts/species"

# Locked chafa flags (D5). Changing these invalidates the baked output; expect
# a large diff if you change them. --fg-only + colors=256 emits rarity-agnostic
# silhouettes where transparent background stays empty; the downstream strip
# removes the color codes, leaving glyph-only output for render.sh to wrap.
CHAFA_FLAGS=(
  --size=14x10
  --symbols=sextant
  --fg-only
  --colors=256
  --format=symbols
  --dither=none
  --color-space=din99d
)

SPECIES=(axolotl dragon owl ghost capybara)

_usage() {
  cat <<EOF
Usage: $0 [--check|--help]

  (default)  Bake every species — overwrite scripts/species/<name>.json:.sprite.base.
  --check    Print what would be baked for each species; write nothing.
  --help     Print this message.

Requires:
  chafa >= 1.14 on PATH  (apt: chafa | brew: chafa)
  jq on PATH
EOF
}

_require_tool() {
  local tool="$1" hint="$2"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "bake-sprites: $tool not found on PATH. Install hint: $hint" >&2
    exit 1
  fi
}

# Run chafa, strip ANSI/color escapes, drop blank leading/trailing lines.
# Emits the cleaned silhouette on stdout.
_bake_one() {
  local src="$1"
  # The default chafa output contains cursor-hide (ESC[?25l) and color-change
  # sequences. The sed strips any CSI sequence (ESC [ ... letter) so only the
  # Unicode sextants remain. Then awk drops leading+trailing blank lines so
  # the render helper's centering stays clean.
  chafa "${CHAFA_FLAGS[@]}" "$src" \
    | sed -E $'s/\x1b\\[[?0-9;]*[A-Za-z]//g' \
    | awk 'BEGIN{buf=""} /./ {if(buf!="") print buf; buf=$0; next} {buf=buf"\n"$0} END{if(buf!="") print buf}' \
    | awk 'NR==1 && /^[[:space:]]*$/ {next} {print}'
}

# Validate the baked output against the render.sh contract:
#   - ≤10 lines
#   - ≤20 chars per line (display width — bash ${#s} is byte-count so we use awk)
#   - no embedded ANSI (already stripped but double-check)
#   - no tab / carriage-return / other control bytes
_validate() {
  local name="$1" content="$2"
  local nlines
  nlines="$(printf '%s\n' "$content" | wc -l)"
  if (( nlines > 10 )); then
    echo "bake-sprites: $name exceeded 10 lines ($nlines)" >&2
    return 1
  fi
  if printf '%s' "$content" | grep -q $'\x1b'; then
    echo "bake-sprites: $name contains ANSI escapes post-strip — check chafa flags" >&2
    return 1
  fi
  if printf '%s' "$content" | grep -Pq '[\t\r]'; then
    echo "bake-sprites: $name contains tab or CR — sanitize the source PNG" >&2
    return 1
  fi
  # Width check — Unicode, so count codepoints not bytes. python3 is already a
  # plugin-wide dep (used elsewhere at build time); falling back to LC_ALL wc -m
  # would also work but needs the UTF-8 locale installed on the build box.
  local overflow
  overflow="$(printf '%s\n' "$content" | python3 -c '
import sys
for i, line in enumerate(sys.stdin.read().splitlines(), 1):
    n = len(line)
    if n > 20:
        print(f"{i}: {n}")
')"
  if [[ -n "$overflow" ]]; then
    echo "bake-sprites: $name has lines over 20 chars: $overflow" >&2
    return 1
  fi
  return 0
}

# Write the baked content into the species JSON via atomic tmp+rename.
_write_back() {
  local name="$1" content="$2"
  local json="$SPECIES_DIR/$name.json"
  if [[ ! -f "$json" ]]; then
    echo "bake-sprites: $json not found" >&2
    return 1
  fi
  # Build a JSON array from the content lines.
  local base_json
  base_json="$(printf '%s\n' "$content" | jq -R -s 'split("\n") | map(select(length > 0))')"
  local tmp
  tmp="$(mktemp "$json.XXXXXX")"
  if ! jq --argjson sprite "$base_json" '.sprite.base = $sprite' "$json" > "$tmp"; then
    rm -f "$tmp"
    echo "bake-sprites: jq failed updating $json" >&2
    return 1
  fi
  if ! mv -f "$tmp" "$json"; then
    rm -f "$tmp"
    echo "bake-sprites: failed to rename tmp into $json" >&2
    return 1
  fi
}

_bake_all() {
  local check_only="${1:-0}"
  local failed=0
  for name in "${SPECIES[@]}"; do
    local src="$ASSETS_DIR/$name.png"
    if [[ ! -f "$src" ]]; then
      echo "bake-sprites: missing source PNG $src" >&2
      failed=1
      continue
    fi
    local baked
    baked="$(_bake_one "$src")" || { failed=1; continue; }
    if ! _validate "$name" "$baked"; then
      failed=1
      continue
    fi
    if (( check_only )); then
      echo "=== $name ==="
      printf '%s\n' "$baked"
      echo ""
    else
      if _write_back "$name" "$baked"; then
        echo "baked $name -> scripts/species/$name.json"
      else
        failed=1
      fi
    fi
  done
  return "$failed"
}

_main() {
  case "${1:-}" in
    --help|-h) _usage; return 0 ;;
    --check) _require_tool chafa "apt install chafa | brew install chafa"; _require_tool jq "apt install jq | brew install jq"; _bake_all 1; return $? ;;
    "") _require_tool chafa "apt install chafa | brew install chafa"; _require_tool jq "apt install jq | brew install jq"; _bake_all 0; return $? ;;
    *) echo "Unknown flag: $1" >&2; _usage; return 1 ;;
  esac
}

_main "$@"
