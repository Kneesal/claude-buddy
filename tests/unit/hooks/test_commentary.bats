#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load ../../test_helper

COMMENTARY_SH="$REPO_ROOT/scripts/hooks/commentary.sh"
COMMON_SH="$REPO_ROOT/scripts/hooks/common.sh"

# Call hook_commentary_select and split the two-line stdout into the
# comment line and the updated session JSON. Tests assert against
# _BUDDY_COMMENT_LINE and _BUDDY_SESSION_UPDATED.
_call() {
  local out
  out="$(hook_commentary_select "$@")"
  _BUDDY_COMMENT_LINE="${out%%$'\n'*}"
  _BUDDY_SESSION_UPDATED="${out#*$'\n'}"
}

# A dedicated fixture species dir keeps tests independent of the real
# line-bank content (which can grow/shrink with voice edits).
_setup_species_fixture() {
  export BUDDY_SPECIES_DIR="$BATS_TEST_TMPDIR/species"
  mkdir -p "$BUDDY_SPECIES_DIR"
  cat > "$BUDDY_SPECIES_DIR/testfrog.json" <<'JSON'
{
  "schemaVersion": 1,
  "species": "testfrog",
  "emoji": "🐸",
  "voice": "test-voice",
  "line_banks": {
    "PostToolUse": {
      "default":    ["ptu-0", "ptu-1", "ptu-2", "ptu-3", "ptu-4"],
      "first_edit": ["first-A", "first-B"]
    },
    "PostToolUseFailure": {
      "default":     ["fail-0", "fail-1", "fail-2"],
      "error_burst": ["burst-A", "burst-B"]
    },
    "Stop": {
      "default":      ["bye-0", "bye-1", "bye-2"],
      "long_session": ["long-A", "long-B"]
    }
  }
}
JSON
}

_buddy_json() {
  local species="${1:-testfrog}"
  local name="${2:-Kermit}"
  jq -n --arg s "$species" --arg n "$name" '{
    schemaVersion: 1,
    buddy: { species: $s, name: $n, rarity: "common", stats: {}, form: "base", level: 1, xp: 0 }
  }'
}

_session_json() {
  local sid="${1:-sess-t}"
  local started="${2:-2026-04-20T12:00:00Z}"
  jq -n --arg sid "$sid" --arg ts "$started" '{
    schemaVersion: 1,
    sessionId: $sid,
    startedAt: $ts,
    cooldowns: {},
    recentToolCallIds: [],
    lastEventType: null,
    commentsThisSession: 0,
    recentFailures: [],
    commentary: { bags: {}, firstEditFired: false }
  }'
}

setup() {
  export CLAUDE_PLUGIN_DATA="$BATS_TEST_TMPDIR/plugin-data"
  mkdir -p "$CLAUDE_PLUGIN_DATA"
  source "$REPO_ROOT/scripts/lib/state.sh"
  source "$COMMON_SH"
  source "$COMMENTARY_SH"
  _setup_species_fixture
  export _BUDDY_COMMENTARY_NOW=1745150000
  # Fixed shuffle: indexes in ascending order. Bank length ≤ 10 in fixtures.
  # TEST_MODE gate required so a leaked shell export can't make
  # production deterministic.
  export _BUDDY_COMMENTARY_TEST_MODE=1
  export _BUDDY_COMMENTARY_SHUFFLE="0 1 2 3 4 5 6 7 8 9"
  unset BUDDY_COMMENTS_PER_SESSION
  unset BUDDY_STOP_LINE_ON_EXIT
}

teardown() {
  unset _BUDDY_COMMENTARY_NOW
  unset _BUDDY_COMMENTARY_TEST_MODE
  unset _BUDDY_COMMENTARY_SHUFFLE
  unset BUDDY_SPECIES_DIR
  unset BUDDY_COMMENTS_PER_SESSION
  unset BUDDY_STOP_LINE_ON_EXIT
}

# ------------------------------------------------------------
# Happy paths
# ------------------------------------------------------------

@test "PostToolUse: first event picks first_edit bank and emits" {
  local buddy session
  buddy="$(_buddy_json)"
  session="$(_session_json)"

  _call PostToolUse "$session" "$buddy"

  [ "$_BUDDY_COMMENT_LINE" = '🐸 Kermit: "first-A"' ]
  [ "$(echo "$_BUDDY_SESSION_UPDATED" | jq -r '.commentary.firstEditFired')" = "true" ]
  [ "$(echo "$_BUDDY_SESSION_UPDATED" | jq -r '.commentsThisSession')" = "1" ]
  [ "$(echo "$_BUDDY_SESSION_UPDATED" | jq -r '.lastEventType')" = "PostToolUse" ]
  [ "$(echo "$_BUDDY_SESSION_UPDATED" | jq -r '.cooldowns.PostToolUse.fires')" = "1" ]
  [ "$(echo "$_BUDDY_SESSION_UPDATED" | jq -r '.cooldowns.PostToolUse.nextAllowedAt')" = "$((_BUDDY_COMMENTARY_NOW + 300))" ]
}

@test "PostToolUse: after firstEditFired uses default bank" {
  local buddy session
  buddy="$(_buddy_json)"
  session="$(_session_json \
    | jq '.commentary.firstEditFired = true | .lastEventType = "Stop"')"
  _call PostToolUse "$session" "$buddy"
  [ "$_BUDDY_COMMENT_LINE" = '🐸 Kermit: "ptu-0"' ]
}

# ------------------------------------------------------------
# Novelty gate
# ------------------------------------------------------------

@test "Novelty gate: consecutive same-type PTUs silences the second" {
  local buddy session
  buddy="$(_buddy_json)"
  session="$(_session_json)"

  _call PostToolUse "$session" "$buddy"
  [ -n "$_BUDDY_COMMENT_LINE" ]
  local after1="$_BUDDY_SESSION_UPDATED"

  _call PostToolUse "$after1" "$buddy"
  [ -z "$_BUDDY_COMMENT_LINE" ]
  [ "$(echo "$_BUDDY_SESSION_UPDATED" | jq -r '.lastEventType')" = "PostToolUse" ]
  [ "$(echo "$_BUDDY_SESSION_UPDATED" | jq -r '.commentsThisSession')" = "1" ]
}

# ------------------------------------------------------------
# Cooldown / backoff
# ------------------------------------------------------------

@test "Cooldown: +5min then +15min backoff" {
  local buddy session
  buddy="$(_buddy_json)"
  session="$(_session_json)"

  # Fire 1.
  _call PostToolUse "$session" "$buddy"
  [ -n "$_BUDDY_COMMENT_LINE" ]
  local s="$_BUDDY_SESSION_UPDATED"

  # Advance 299s, clear novelty → still blocked by cooldown.
  export _BUDDY_COMMENTARY_NOW=$((1745150000 + 299))
  s="$(echo "$s" | jq '.lastEventType = "Stop"')"
  _call PostToolUse "$s" "$buddy"
  [ -z "$_BUDDY_COMMENT_LINE" ]

  # +301s, clear novelty → fires.
  export _BUDDY_COMMENTARY_NOW=$((1745150000 + 301))
  s="$(echo "$s" | jq '.lastEventType = "Stop"')"
  _call PostToolUse "$s" "$buddy"
  [ -n "$_BUDDY_COMMENT_LINE" ]
  [ "$(echo "$_BUDDY_SESSION_UPDATED" | jq -r '.cooldowns.PostToolUse.fires')" = "2" ]
  [ "$(echo "$_BUDDY_SESSION_UPDATED" | jq -r '.cooldowns.PostToolUse.nextAllowedAt')" = "$((_BUDDY_COMMENTARY_NOW + 900))" ]
  s="$_BUDDY_SESSION_UPDATED"

  # +301+899s, cleared novelty → blocked by 15min cooldown.
  export _BUDDY_COMMENTARY_NOW=$((1745150000 + 301 + 899))
  s="$(echo "$s" | jq '.lastEventType = "Stop"')"
  _call PostToolUse "$s" "$buddy"
  [ -z "$_BUDDY_COMMENT_LINE" ]

  # +301+901s → fires.
  export _BUDDY_COMMENTARY_NOW=$((1745150000 + 301 + 901))
  s="$(echo "$s" | jq '.lastEventType = "Stop"')"
  _call PostToolUse "$s" "$buddy"
  [ -n "$_BUDDY_COMMENT_LINE" ]
  [ "$(echo "$_BUDDY_SESSION_UPDATED" | jq -r '.cooldowns.PostToolUse.fires')" = "3" ]
}

# ------------------------------------------------------------
# Budget
# ------------------------------------------------------------

@test "Budget: cap blocks once reached" {
  local buddy session
  buddy="$(_buddy_json)"
  export BUDDY_COMMENTS_PER_SESSION=2
  session="$(_session_json \
    | jq '.commentsThisSession = 2 | .lastEventType = "Stop" | .commentary.firstEditFired = true')"
  _call PostToolUse "$session" "$buddy"
  [ -z "$_BUDDY_COMMENT_LINE" ]
  [ "$(echo "$_BUDDY_SESSION_UPDATED" | jq -r '.commentsThisSession')" = "2" ]
}

@test "Budget: default cap 8 blocks the 9th emission" {
  local buddy session
  buddy="$(_buddy_json)"
  session="$(_session_json \
    | jq '.commentsThisSession = 8 | .lastEventType = "Stop" | .commentary.firstEditFired = true')"
  _call PostToolUse "$session" "$buddy"
  [ -z "$_BUDDY_COMMENT_LINE" ]
}

# ------------------------------------------------------------
# Stop bypasses gates
# ------------------------------------------------------------

@test "Stop: emits even when budget exhausted" {
  local buddy session
  buddy="$(_buddy_json)"
  session="$(_session_json | jq '.commentsThisSession = 8')"
  _call Stop "$session" "$buddy"
  [ "$_BUDDY_COMMENT_LINE" = '🐸 Kermit: "bye-0"' ]
  [ "$(echo "$_BUDDY_SESSION_UPDATED" | jq -r '.commentsThisSession')" = "9" ]
  [ "$(echo "$_BUDDY_SESSION_UPDATED" | jq -r '.lastEventType')" = "null" ]
  [ "$(echo "$_BUDDY_SESSION_UPDATED" | jq -r '.cooldowns | length')" = "0" ]
}

@test "Stop: BUDDY_STOP_LINE_ON_EXIT=0 disables the goodbye" {
  local buddy session
  buddy="$(_buddy_json)"
  session="$(_session_json)"
  export BUDDY_STOP_LINE_ON_EXIT=0
  _call Stop "$session" "$buddy"
  [ -z "$_BUDDY_COMMENT_LINE" ]
  [ "$(echo "$_BUDDY_SESSION_UPDATED" | jq -r '.commentsThisSession')" = "0" ]
}

@test "Stop: long_session bank when startedAt > 1h ago" {
  local buddy session started
  buddy="$(_buddy_json)"
  started="$(date -u -d "@$((1745150000 - 7200))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
             || date -u -r $((1745150000 - 7200)) +%Y-%m-%dT%H:%M:%SZ)"
  session="$(_session_json "sess-long" "$started")"
  _call Stop "$session" "$buddy"
  [ "$_BUDDY_COMMENT_LINE" = '🐸 Kermit: "long-A"' ]
}

# ------------------------------------------------------------
# Error burst milestone
# ------------------------------------------------------------

@test "PostToolUseFailure: tight burst (≥3 failures in 300s) picks error_burst" {
  local buddy session
  buddy="$(_buddy_json)"
  session="$(_session_json \
    | jq --argjson now "$_BUDDY_COMMENTARY_NOW" \
         '.recentFailures = [$now - 100, $now - 50]
          | .lastEventType = "Stop"
          | .cooldowns.PostToolUseFailure = { fires: 0, nextAllowedAt: 0 }')"
  _call PostToolUseFailure "$session" "$buddy"
  [ "$_BUDDY_COMMENT_LINE" = '🐸 Kermit: "burst-A"' ]
  [ "$(echo "$_BUDDY_SESSION_UPDATED" | jq -r '.recentFailures | length')" = "3" ]
}

@test "PostToolUseFailure: recentFailures outside window are pruned" {
  local buddy session
  buddy="$(_buddy_json)"
  # Two old failures outside 300s window; incoming event arrives alone.
  session="$(_session_json \
    | jq --argjson now "$_BUDDY_COMMENTARY_NOW" \
         '.recentFailures = [$now - 500, $now - 400]
          | .lastEventType = "Stop"')"
  _call PostToolUseFailure "$session" "$buddy"
  # Old entries pruned; only the new one survives.
  [ "$(echo "$_BUDDY_SESSION_UPDATED" | jq -r '.recentFailures | length')" = "1" ]
  # Default bank (count = 1 < 3).
  [ "$_BUDDY_COMMENT_LINE" = '🐸 Kermit: "fail-0"' ]
}

# ------------------------------------------------------------
# Shuffle-bag: no repeats within a cycle
# ------------------------------------------------------------

@test "Shuffle-bag: no repeats across 5 draws; refills into full permutation" {
  unset _BUDDY_COMMENTARY_SHUFFLE
  # Default budget cap is 8 — 10 draws would hit the cap on draw 9.
  # Widen it for this test; shuffle semantics are what we're proving.
  export BUDDY_COMMENTS_PER_SESSION=20
  local buddy current seen_cycle1="" seen_cycle2="" line
  buddy="$(_buddy_json)"
  current="$(_session_json | jq '.commentary.firstEditFired = true')"

  local i
  # First 5 draws — every line unique within the cycle.
  for i in 1 2 3 4 5; do
    current="$(echo "$current" | jq '.lastEventType = "Stop" | .cooldowns = {}')"
    _call PostToolUse "$current" "$buddy"
    [ -n "$_BUDDY_COMMENT_LINE" ]
    current="$_BUDDY_SESSION_UPDATED"
    line="$(printf '%s' "$_BUDDY_COMMENT_LINE" | sed 's/.*: "\(.*\)"/\1/')"
    [[ "$seen_cycle1" != *"|$line|"* ]]
    seen_cycle1="$seen_cycle1|$line|"
  done

  [ "$(echo "$current" | jq -r '.commentary.bags["PostToolUse.default"] | length')" = "0" ]

  # Second 5 draws — refill exercised, should also be a full permutation
  # (no duplicates within cycle 2). This guards against a regression
  # where refill seeds with a partial or duplicate-heavy sequence.
  for i in 6 7 8 9 10; do
    current="$(echo "$current" | jq '.lastEventType = "Stop" | .cooldowns = {}')"
    _call PostToolUse "$current" "$buddy"
    [ -n "$_BUDDY_COMMENT_LINE" ]
    current="$_BUDDY_SESSION_UPDATED"
    line="$(printf '%s' "$_BUDDY_COMMENT_LINE" | sed 's/.*: "\(.*\)"/\1/')"
    [[ "$seen_cycle2" != *"|$line|"* ]]
    seen_cycle2="$seen_cycle2|$line|"
  done
  # Bag empty again — 5 elements drawn from a refilled 5-element bag.
  [ "$(echo "$current" | jq -r '.commentary.bags["PostToolUse.default"] | length')" = "0" ]
}

# ------------------------------------------------------------
# Error / edge paths
# ------------------------------------------------------------

@test "Empty bank: silent skip, no crash, session remains valid JSON" {
  cat > "$BUDDY_SPECIES_DIR/emptyfrog.json" <<'JSON'
{ "schemaVersion": 1, "species": "emptyfrog", "emoji": "🪨", "voice": "empty",
  "line_banks": { "PostToolUse": { "default": [] }, "PostToolUseFailure": { "default": [] }, "Stop": { "default": [] } } }
JSON
  local buddy session
  buddy="$(_buddy_json emptyfrog Rocky)"
  session="$(_session_json)"
  _call PostToolUse "$session" "$buddy"
  [ -z "$_BUDDY_COMMENT_LINE" ]
  # Error paths must still emit valid JSON on line 2 — session_save
  # would otherwise persist garbage.
  echo "$_BUDDY_SESSION_UPDATED" | jq -e '.' >/dev/null
}

@test "Malformed line_banks: silent skip, session remains valid JSON" {
  cat > "$BUDDY_SPECIES_DIR/weirdfrog.json" <<'JSON'
{ "schemaVersion": 1, "species": "weirdfrog", "emoji": "❓", "voice": "?",
  "line_banks": { "PostToolUse": "not-an-object" } }
JSON
  local buddy session
  buddy="$(_buddy_json weirdfrog Null)"
  session="$(_session_json)"
  _call PostToolUse "$session" "$buddy"
  [ -z "$_BUDDY_COMMENT_LINE" ]
  echo "$_BUDDY_SESSION_UPDATED" | jq -e '.' >/dev/null
}

@test "Missing species file: silent skip, session remains valid JSON" {
  local buddy session
  buddy="$(_buddy_json nonesuch Nope)"
  session="$(_session_json)"
  _call PostToolUse "$session" "$buddy"
  [ -z "$_BUDDY_COMMENT_LINE" ]
  echo "$_BUDDY_SESSION_UPDATED" | jq -e '.' >/dev/null
}

@test "Path-traversal species: silent skip, session remains valid JSON" {
  local buddy session
  buddy="$(_buddy_json "../etc/passwd" Hax)"
  session="$(_session_json)"
  _call PostToolUse "$session" "$buddy"
  [ -z "$_BUDDY_COMMENT_LINE" ]
  echo "$_BUDDY_SESSION_UPDATED" | jq -e '.' >/dev/null
}

@test "Missing buddy species/name: session remains valid JSON" {
  local buddy session
  buddy='{"schemaVersion":1,"buddy":{}}'
  session="$(_session_json)"
  _call PostToolUse "$session" "$buddy"
  [ -z "$_BUDDY_COMMENT_LINE" ]
  echo "$_BUDDY_SESSION_UPDATED" | jq -e '.' >/dev/null
}

@test "Control bytes in buddy name are stripped from transcript emit" {
  local buddy session
  # Embed ANSI CSI (ESC[31m) and BEL in the name.
  buddy="$(jq -n --arg n $'bad\x1b[31mname\x07' '{
    schemaVersion: 1,
    buddy: { species: "testfrog", name: $n, rarity: "common", stats: {}, form: "base", level: 1, xp: 0 }
  }')"
  session="$(_session_json)"
  _call PostToolUse "$session" "$buddy"
  # Output must not contain raw escape or BEL bytes.
  [[ "$_BUDDY_COMMENT_LINE" != *$'\x1b'* ]]
  [[ "$_BUDDY_COMMENT_LINE" != *$'\x07'* ]]
}

@test "BUDDY_STOP_LINE_ON_EXIT deny-list tolerates 'True' and whitespace" {
  local buddy session
  buddy="$(_buddy_json)"
  session="$(_session_json)"
  # 'True' (Python-style title case) should still enable per deny-list.
  BUDDY_STOP_LINE_ON_EXIT=True _call Stop "$session" "$buddy"
  [ -n "$_BUDDY_COMMENT_LINE" ]
  # Surrounding whitespace on a falsy value should still disable.
  BUDDY_STOP_LINE_ON_EXIT=" false " _call Stop "$session" "$buddy"
  [ -z "$_BUDDY_COMMENT_LINE" ]
}

@test "Unknown event type: session unchanged, no crash" {
  local buddy session
  buddy="$(_buddy_json)"
  session="$(_session_json)"
  _call SomeWeirdEvent "$session" "$buddy"
  [ "$(echo "$_BUDDY_SESSION_UPDATED" | jq -rc '.')" = "$(echo "$session" | jq -rc '.')" ]
  [ -z "$_BUDDY_COMMENT_LINE" ]
}

@test "Emit format: emoji + name + quoted line" {
  local buddy session
  buddy="$(_buddy_json)"
  session="$(_session_json)"
  _call PostToolUse "$session" "$buddy"
  [[ "$_BUDDY_COMMENT_LINE" =~ ^🐸\ Kermit:\ \".+\"$ ]]
}

@test "Session JSON is single-line (jq -c compatible for split)" {
  local buddy session out
  buddy="$(_buddy_json)"
  session="$(_session_json)"
  out="$(hook_commentary_select PostToolUse "$session" "$buddy")"
  # Exactly one newline between the comment line and the JSON.
  # `echo -n` + wc would count 1.
  [ "$(printf '%s' "$out" | tr -cd '\n' | wc -c)" = "1" ]
}

# ------------------------------------------------------------
# P4-1: LevelUp event handler bypasses all three rate-limit gates
# and does NOT count against commentsThisSession (per D9).
# ------------------------------------------------------------

# Add a LevelUp bank to the fixture so the draw can succeed.
_seed_levelup_bank() {
  jq '.line_banks.LevelUp = { default: ["level-A", "level-B", "level-C"] }' \
    "$BUDDY_SPECIES_DIR/testfrog.json" > "$BUDDY_SPECIES_DIR/testfrog.json.tmp"
  mv "$BUDDY_SPECIES_DIR/testfrog.json.tmp" "$BUDDY_SPECIES_DIR/testfrog.json"
}

@test "LevelUp: bypasses novelty gate — fires even when lastEventType == LevelUp" {
  _seed_levelup_bank
  local buddy session
  buddy="$(_buddy_json)"
  # Pre-seed lastEventType=LevelUp — would silence any event bound
  # by the novelty gate.
  session="$(_session_json | jq '.lastEventType = "LevelUp"')"
  _call LevelUp "$session" "$buddy"
  [ -n "$_BUDDY_COMMENT_LINE" ]
  [[ "$_BUDDY_COMMENT_LINE" =~ level-[ABC] ]]
}

@test "LevelUp: bypasses cooldown gate — fires even with active nextAllowedAt" {
  _seed_levelup_bank
  local buddy session far_future
  buddy="$(_buddy_json)"
  far_future=9999999999
  session="$(_session_json | jq --argjson n "$far_future" '.cooldowns.LevelUp = { fires: 99, nextAllowedAt: $n }')"
  _call LevelUp "$session" "$buddy"
  [ -n "$_BUDDY_COMMENT_LINE" ]
}

@test "LevelUp: bypasses budget gate — fires even when commentsThisSession >= cap" {
  _seed_levelup_bank
  local buddy session
  buddy="$(_buddy_json)"
  session="$(_session_json | jq '.commentsThisSession = 100')"
  BUDDY_COMMENTS_PER_SESSION=8 _call LevelUp "$session" "$buddy"
  [ -n "$_BUDDY_COMMENT_LINE" ]
}

@test "LevelUp: does NOT increment commentsThisSession (gate-bypass invariant)" {
  _seed_levelup_bank
  local buddy session before_count after_count
  buddy="$(_buddy_json)"
  session="$(_session_json | jq '.commentsThisSession = 3')"
  before_count="$(echo "$session" | jq '.commentsThisSession')"
  _call LevelUp "$session" "$buddy"
  after_count="$(echo "$_BUDDY_SESSION_UPDATED" | jq '.commentsThisSession')"
  [ "$before_count" = "3" ]
  [ "$after_count" = "3" ]
}

@test "LevelUp: does NOT bump cooldowns.LevelUp (gate-bypass invariant)" {
  _seed_levelup_bank
  local buddy session cooldowns_after
  buddy="$(_buddy_json)"
  session="$(_session_json)"
  _call LevelUp "$session" "$buddy"
  # cooldowns is {} in the initial shape; LevelUp handler must not
  # add a key for itself (nothing to rate-limit against).
  cooldowns_after="$(echo "$_BUDDY_SESSION_UPDATED" | jq -c '.cooldowns')"
  [ "$cooldowns_after" = "{}" ]
}

@test "LevelUp: empty bank → silent skip, no crash, session unchanged" {
  # No _seed_levelup_bank — species has no LevelUp entry.
  local buddy session before after
  buddy="$(_buddy_json)"
  session="$(_session_json)"
  before="$(echo "$session" | jq -c '.')"
  _call LevelUp "$session" "$buddy"
  after="$(echo "$_BUDDY_SESSION_UPDATED" | jq -c '.')"
  [ -z "$_BUDDY_COMMENT_LINE" ]
  [ "$before" = "$after" ]
}
