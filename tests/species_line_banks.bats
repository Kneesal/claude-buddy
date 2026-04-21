#!/usr/bin/env bats
# Structural guarantees for species line banks (P3-2).
# Voice consistency is a manual review gate — this file only asserts
# shape, size, and properties the commentary engine relies on.

bats_require_minimum_version 1.5.0

load test_helper

SPECIES_FILES=(
  "$SPECIES_DIR/axolotl.json"
  "$SPECIES_DIR/dragon.json"
  "$SPECIES_DIR/owl.json"
  "$SPECIES_DIR/ghost.json"
  "$SPECIES_DIR/capybara.json"
)

@test "species: every shipped species JSON parses" {
  for f in "${SPECIES_FILES[@]}"; do
    run jq -e '.' "$f"
    [ "$status" -eq 0 ] || { echo "parse failed: $f"; return 1; }
  done
}

@test "species: PostToolUse.default has ≥50 lines per species" {
  for f in "${SPECIES_FILES[@]}"; do
    local n
    n="$(jq -r '.line_banks.PostToolUse.default | length' "$f")"
    [ "$n" -ge 50 ] || { echo "$f: PostToolUse.default has $n"; return 1; }
  done
}

@test "species: PostToolUseFailure.default has ≥50 lines per species" {
  for f in "${SPECIES_FILES[@]}"; do
    local n
    n="$(jq -r '.line_banks.PostToolUseFailure.default | length' "$f")"
    [ "$n" -ge 50 ] || { echo "$f: PostToolUseFailure.default has $n"; return 1; }
  done
}

@test "species: Stop.default has ≥50 lines per species" {
  for f in "${SPECIES_FILES[@]}"; do
    local n
    n="$(jq -r '.line_banks.Stop.default | length' "$f")"
    [ "$n" -ge 50 ] || { echo "$f: Stop.default has $n"; return 1; }
  done
}

@test "species: milestone banks are non-empty when present" {
  # first_edit / error_burst / long_session are currently shipped on
  # every species. If a species drops one later, the engine silently
  # falls back to default — but while they exist, they must carry
  # actual lines so we don't ship an empty milestone bank.
  for f in "${SPECIES_FILES[@]}"; do
    local n
    for path in '.line_banks.PostToolUse.first_edit' \
                '.line_banks.PostToolUseFailure.error_burst' \
                '.line_banks.Stop.long_session'; do
      n="$(jq -r "($path // []) | length" "$f")"
      [ "$n" -ge 1 ] || { echo "$f: $path has $n"; return 1; }
    done
  done
}

@test "species: no duplicate lines within any bank" {
  # The shuffle-bag relies on bank length as the cycle. Duplicate lines
  # mean a user sees the same line twice in a cycle — breaks the
  # "no repeats" promise of shuffle-bag selection.
  for f in "${SPECIES_FILES[@]}"; do
    local report
    report="$(jq -r '
      .line_banks
      | to_entries[]
      | .key as $event
      | .value | to_entries[]
      | .key as $bank
      | .value
      | select(type == "array")
      | (length) as $n
      | ((unique | length) as $u
         | if $n != $u then "\($event).\($bank): \($n) lines, \($u) unique" else empty end)
    ' "$f")"
    [ -z "$report" ] || { echo "$f: $report"; return 1; }
  done
}

@test "species: no tab characters in any line (split-safe)" {
  # _commentary_draw uses TAB as the line/session separator internally.
  # A literal tab in content would mis-split the handler output.
  for f in "${SPECIES_FILES[@]}"; do
    local hits
    hits="$(jq -r '
      [ .line_banks | .. | strings | select(contains("\t")) ] | length
    ' "$f")"
    [ "$hits" = "0" ] || { echo "$f: $hits lines contain tabs"; return 1; }
  done
}

@test "species: no newline characters in any line (single-line emit)" {
  for f in "${SPECIES_FILES[@]}"; do
    local hits
    hits="$(jq -r '
      [ .line_banks | .. | strings | select(contains("\n")) ] | length
    ' "$f")"
    [ "$hits" = "0" ] || { echo "$f: $hits lines contain newlines"; return 1; }
  done
}

@test "species: every line is a non-empty string" {
  for f in "${SPECIES_FILES[@]}"; do
    local bad
    bad="$(jq -r '
      [ .line_banks | .. | arrays | .[] | select((type == "string" | not) or (length == 0)) ] | length
    ' "$f")"
    [ "$bad" = "0" ] || { echo "$f: $bad invalid entries"; return 1; }
  done
}

@test "species: emoji field is a non-empty string" {
  for f in "${SPECIES_FILES[@]}"; do
    local emoji
    emoji="$(jq -r '.emoji // ""' "$f")"
    [ -n "$emoji" ] || { echo "$f: missing emoji"; return 1; }
  done
}
