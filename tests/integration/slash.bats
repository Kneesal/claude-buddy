#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load ../test_helper

# Pre-compute the seed-42 hatch once per file so every `_seed_hatch`
# call in the test body copies the cached JSON instead of re-running
# roll_buddy (which forks jq ~5 times per call). See test_helper.bash.
setup_file() {
  _prepare_hatched_cache
}

# Script paths and shared seeding helpers (_seed_hatch, _seed_corrupt,
# _seed_future_version, _inject_tokens) come from test_helper.bash.

# ============================================================
# hatch.sh — NO_BUDDY (first hatch)
# ============================================================

@test "hatch: first hatch common buddy never rolls a hat" {
  # P4-4d cosmetics rule: commons always get cosmetics.hat = null. Seed 42
  # pins axolotl/common, so this must hold.
  BUDDY_RNG_SEED=42 run --separate-stderr bash "$HATCH_SH"
  [ "$status" -eq 0 ]
  local rarity hat
  rarity="$(jq -r '.buddy.rarity' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  hat="$(jq -r '.buddy.cosmetics.hat' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  [ "$rarity" = "common" ]
  [ "$hat" = "null" ]
}

@test "hatch: first hatch on NO_BUDDY creates a valid envelope" {
  run --separate-stderr bash "$HATCH_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == Hatched* ]]
  [ -f "$CLAUDE_PLUGIN_DATA/buddy.json" ]

  local schema totalHatches balance level pity
  schema="$(jq -r '.schemaVersion' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  totalHatches="$(jq -r '.meta.totalHatches' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  balance="$(jq -r '.tokens.balance' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  level="$(jq -r '.buddy.level' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  pity="$(jq -r '.meta.pityCounter' "$CLAUDE_PLUGIN_DATA/buddy.json")"

  [ "$schema" = "1" ]
  [ "$totalHatches" = "1" ]
  [ "$balance" = "0" ]
  [ "$level" = "1" ]
  # Pity is 0 (Rare+) or 1 (Common) depending on the random roll.
  [[ "$pity" =~ ^[0-9]+$ ]]

  # P4-1: signals skeleton is baked in so new hatches start with the
  # full four-axis shape.
  [ "$(jq -r '.buddy.signals.consistency.streakDays' "$CLAUDE_PLUGIN_DATA/buddy.json")" = "0" ]
  [ "$(jq -r '.buddy.signals.consistency.lastActiveDay' "$CLAUDE_PLUGIN_DATA/buddy.json")" = "1970-01-01" ]
  [ "$(jq -r '.buddy.signals.variety.toolsUsed | type' "$CLAUDE_PLUGIN_DATA/buddy.json")" = "object" ]
  [ "$(jq -r '.buddy.signals.quality.successfulEdits' "$CLAUDE_PLUGIN_DATA/buddy.json")" = "0" ]
  [ "$(jq -r '.buddy.signals.quality.totalEdits' "$CLAUDE_PLUGIN_DATA/buddy.json")" = "0" ]
  [ "$(jq -r '.buddy.signals.chaos.errors' "$CLAUDE_PLUGIN_DATA/buddy.json")" = "0" ]
  [ "$(jq -r '.buddy.signals.chaos.repeatedEditHits' "$CLAUDE_PLUGIN_DATA/buddy.json")" = "0" ]
}

@test "hatch: first hatch ignores --confirm flag (treats it as first hatch, not reroll)" {
  run --separate-stderr bash "$HATCH_SH" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == Hatched* ]]
  [ "$(jq -r '.meta.totalHatches' "$CLAUDE_PLUGIN_DATA/buddy.json")" = "1" ]
}

@test "hatch: deterministic seed pins species and rarity" {
  BUDDY_RNG_SEED=42 run --separate-stderr bash "$HATCH_SH"
  [ "$status" -eq 0 ]
  # Seed 42 with 5 launch species — pin the exact roll so regressions surface.
  local species rarity
  species="$(jq -r '.buddy.species' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  rarity="$(jq -r '.buddy.rarity' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  [ "$species" = "axolotl" ]
  [ "$rarity" = "common" ]
}

# ============================================================
# hatch.sh — ACTIVE reroll paths
# ============================================================

@test "hatch: reroll gate — ACTIVE + tokens + no --confirm prints consequences, no mutation" {
  _seed_hatch
  # Inject enough tokens so the token check passes and the --confirm gate is
  # the thing being exercised. Plan R4 says insufficient-tokens rejection fires
  # "with or without --confirm", so the no-token case is a different cell
  # (covered in the no-confirm-zero-tokens test below).
  _inject_tokens 15
  local before
  before="$(jq -r '.buddy.id' "$CLAUDE_PLUGIN_DATA/buddy.json")"

  run --separate-stderr bash "$HATCH_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Reroll will wipe your Lv.1 base form"* ]]
  [[ "$output" == *"--confirm"* ]]

  local after
  after="$(jq -r '.buddy.id' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  [ "$before" = "$after" ]
  # Token balance unchanged by the gate message.
  [ "$(jq -r '.tokens.balance' "$CLAUDE_PLUGIN_DATA/buddy.json")" = "15" ]
}

@test "hatch: ACTIVE + no --confirm + 0 tokens prints need-more message (R4: with or without --confirm)" {
  _seed_hatch
  # balance starts at 0; no confirm flag passed — plan R4 still expects the
  # need-tokens message, not the reroll-consequences gate.
  run --separate-stderr bash "$HATCH_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Need 10 more tokens"* ]]
  [[ "$output" != *"Reroll will wipe"* ]]
  [ "$(jq -r '.tokens.balance' "$CLAUDE_PLUGIN_DATA/buddy.json")" = "0" ]
}

@test "hatch: reroll rejected — ACTIVE + --confirm + 0 tokens prints need-more message" {
  _seed_hatch
  local before
  before="$(jq -r '.buddy.id' "$CLAUDE_PLUGIN_DATA/buddy.json")"

  run --separate-stderr bash "$HATCH_SH" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"Need 10 more tokens"* ]]

  local after
  after="$(jq -r '.buddy.id' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  [ "$before" = "$after" ]
}

@test "hatch: reroll rejected — partial balance produces precise need-N message" {
  _seed_hatch
  _inject_tokens 4
  run --separate-stderr bash "$HATCH_SH" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"Need 6 more tokens"* ]]
  [ "$(jq -r '.tokens.balance' "$CLAUDE_PLUGIN_DATA/buddy.json")" = "4" ]
}

@test "hatch: reroll paid — ACTIVE + --confirm + 15 tokens rerolls and preserves 5 tokens" {
  _seed_hatch
  _inject_tokens 15
  local before_id before_hatched before_pity
  before_id="$(jq -r '.buddy.id' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  before_hatched="$(jq -r '.hatchedAt' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  before_pity="$(jq -r '.meta.pityCounter' "$CLAUDE_PLUGIN_DATA/buddy.json")"

  run --separate-stderr bash "$HATCH_SH" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == Rerolled* ]]

  local after_id balance totalHatches lastRerollAt hatchedAt level xp pity rarity
  after_id="$(jq -r '.buddy.id' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  balance="$(jq -r '.tokens.balance' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  totalHatches="$(jq -r '.meta.totalHatches' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  lastRerollAt="$(jq -r '.lastRerollAt' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  hatchedAt="$(jq -r '.hatchedAt' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  level="$(jq -r '.buddy.level' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  xp="$(jq -r '.buddy.xp' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  pity="$(jq -r '.meta.pityCounter' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  rarity="$(jq -r '.buddy.rarity' "$CLAUDE_PLUGIN_DATA/buddy.json")"

  # New identity
  [ "$before_id" != "$after_id" ]
  # Token math
  [ "$balance" = "5" ]
  # Meta increments
  [ "$totalHatches" = "2" ]
  # Timestamps: lastRerollAt now set, hatchedAt unchanged (first-hatch marker preserved)
  [ "$lastRerollAt" != "null" ]
  [ "$hatchedAt" = "$before_hatched" ]
  # Progression reset
  [ "$level" = "1" ]
  [ "$xp" = "0" ]
  # Pity counter carried through next_pity_counter: Common increments, Rare+ resets.
  # before_pity is 0 or 1 from the seeded first hatch; the rolled rarity dictates the new value.
  case "$rarity" in
    common)              [ "$pity" = "$((before_pity + 1))" ] ;;
    uncommon)            [ "$pity" = "$before_pity" ] ;;
    rare|epic|legendary) [ "$pity" = "0" ] ;;
    *) printf 'unexpected rarity: %s\n' "$rarity" >&2; return 1 ;;
  esac
}

@test "hatch: reroll paid — preserves tokens.earnedToday and windowStartedAt" {
  _seed_hatch
  _inject_tokens 20
  local tmp
  tmp="$(mktemp "$CLAUDE_PLUGIN_DATA/.inject.XXXXXX")"
  jq '.tokens.earnedToday = 3 | .tokens.windowStartedAt = "2026-04-10T00:00:00Z"' \
    "$CLAUDE_PLUGIN_DATA/buddy.json" > "$tmp"
  mv -f "$tmp" "$CLAUDE_PLUGIN_DATA/buddy.json"

  run --separate-stderr bash "$HATCH_SH" --confirm
  [ "$status" -eq 0 ]

  [ "$(jq -r '.tokens.earnedToday' "$CLAUDE_PLUGIN_DATA/buddy.json")" = "3" ]
  [ "$(jq -r '.tokens.windowStartedAt' "$CLAUDE_PLUGIN_DATA/buddy.json")" = "2026-04-10T00:00:00Z" ]
  [ "$(jq -r '.tokens.balance' "$CLAUDE_PLUGIN_DATA/buddy.json")" = "10" ]
}

# ============================================================
# hatch.sh — degraded states
# ============================================================

@test "hatch: CORRUPT state prints repair pointer, no mutation" {
  _seed_corrupt
  local before
  before="$(cat "$CLAUDE_PLUGIN_DATA/buddy.json")"

  run --separate-stderr bash "$HATCH_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Buddy state needs repair"* ]]
  [[ "$output" == *"/buddy:reset"* ]]

  local after
  after="$(cat "$CLAUDE_PLUGIN_DATA/buddy.json")"
  [ "$before" = "$after" ]
}

@test "hatch: FUTURE_VERSION state prints update-plugin message, no mutation" {
  _seed_future_version
  local before
  before="$(cat "$CLAUDE_PLUGIN_DATA/buddy.json")"

  run --separate-stderr bash "$HATCH_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"newer plugin version"* ]]

  local after
  after="$(cat "$CLAUDE_PLUGIN_DATA/buddy.json")"
  [ "$before" = "$after" ]
}

@test "hatch: unknown flag exits non-zero" {
  run --separate-stderr bash "$HATCH_SH" --bogus
  [ "$status" -ne 0 ]
}

@test "hatch: CORRUPT + --confirm still prints repair pointer (flag ignored on degraded states)" {
  _seed_corrupt
  local before
  before="$(cat "$CLAUDE_PLUGIN_DATA/buddy.json")"

  run --separate-stderr bash "$HATCH_SH" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"Buddy state needs repair"* ]]

  [ "$before" = "$(cat "$CLAUDE_PLUGIN_DATA/buddy.json")" ]
}

@test "hatch: FUTURE_VERSION + --confirm still prints update message (flag ignored on degraded states)" {
  _seed_future_version
  local before
  before="$(cat "$CLAUDE_PLUGIN_DATA/buddy.json")"

  run --separate-stderr bash "$HATCH_SH" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"newer plugin version"* ]]

  [ "$before" = "$(cat "$CLAUDE_PLUGIN_DATA/buddy.json")" ]
}

@test "hatch: parseable envelope with non-integer balance trips the defensive guard (exit 1)" {
  # Seed a valid-looking envelope where tokens.balance is a string instead of
  # an integer. buddy_load returns it as JSON (not CORRUPT), and _hatch_reroll's
  # regex guard must reject it before arithmetic tries to compare against a
  # non-integer. A regression removing the guard would let `(( balance < 10 ))`
  # run against "not-a-number" with undefined behavior.
  cat > "$CLAUDE_PLUGIN_DATA/buddy.json" <<'JSON'
{
  "schemaVersion": 1,
  "hatchedAt": "2026-04-19T00:00:00Z",
  "lastRerollAt": null,
  "buddy": {"id":"x","name":"Mal","species":"axolotl","rarity":"common","shiny":false,"stats":{"debugging":5,"patience":5,"chaos":5,"wisdom":5,"snark":5},"form":"base","level":1,"xp":0},
  "tokens": {"balance": "not-a-number", "earnedToday": 0, "windowStartedAt": "2026-04-19T00:00:00Z"},
  "meta": {"totalHatches": 1, "pityCounter": 0}
}
JSON
  run --separate-stderr bash "$HATCH_SH" --confirm
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"missing required fields"* ]]
}

# ============================================================
# status.sh — four-state matrix
# ============================================================

@test "status: NO_BUDDY prints pointer to hatch" {
  run --separate-stderr bash "$STATUS_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No buddy yet"* ]]
  [[ "$output" == *"/buddy:hatch"* ]]
}

@test "status: ACTIVE renders P4-3 menu — sprite, header, XP bar, stat bars, signals, footer" {
  _seed_hatch
  NO_COLOR=1 run --separate-stderr bash "$STATUS_SH"
  [ "$status" -eq 0 ]
  # Header (seed 42 -> axolotl/common/Custard)
  [[ "$output" == *"Custard"* ]]
  [[ "$output" == *"Common"* ]]
  [[ "$output" == *"axolotl"* ]]
  [[ "$output" == *"Lv.1"* ]]
  [[ "$output" == *"base form"* ]]
  # Sprite content — 5x12 face-only (P4-4d v2). Seed 42 pins axolotl; its
  # distinctive top row is the frilly gill fringe `<vvv-vvv>`. Asserting the
  # gill row stays robust across the per-buddy eye-glyph randomization.
  [[ "$output" == *'<vvv-vvv>'* ]]
  # XP bar — label and the next-level hint
  [[ "$output" == *"XP"* ]]
  [[ "$output" == *"0/100"* ]]
  [[ "$output" == *"Lv.2 in 100"* ]]
  [[ "$output" == *"░"* ]]
  # Five rarity-stat bars
  [[ "$output" == *"debugging"* ]]
  [[ "$output" == *"patience"* ]]
  [[ "$output" == *"chaos"* ]]
  [[ "$output" == *"wisdom"* ]]
  [[ "$output" == *"snark"* ]]
  # Signals glyph strip
  [[ "$output" == *"🔥"* ]]
  [[ "$output" == *"🧰"* ]]
  [[ "$output" == *"✓"* ]]
  [[ "$output" == *"⚡"* ]]
  [[ "$output" == *"🪙"* ]]
  # Footer with related-command pointers
  [[ "$output" == *"/buddy:interact"* ]]
  [[ "$output" == *"/buddy:install-statusline"* ]]
  [[ "$output" == *"/buddy:hatch --confirm"* ]]
}

@test "status: ACTIVE with injected tokens reflects the new balance in signal strip" {
  _seed_hatch
  _inject_tokens 7
  NO_COLOR=1 run --separate-stderr bash "$STATUS_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"🪙 7"* ]]
}

@test "status: ACTIVE NO_COLOR strips every ANSI escape" {
  _seed_hatch
  NO_COLOR=1 run --separate-stderr bash "$STATUS_SH"
  [ "$status" -eq 0 ]
  ! [[ "$output" == *$'\033'* ]]
}

@test "status: ACTIVE without NO_COLOR includes ANSI escapes" {
  _seed_hatch
  unset NO_COLOR
  run --separate-stderr bash "$STATUS_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033'* ]]
}

@test "status: CORRUPT prints repair pointer" {
  _seed_corrupt
  run --separate-stderr bash "$STATUS_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Buddy state needs repair"* ]]
}

@test "status: FUTURE_VERSION prints update-plugin message" {
  _seed_future_version
  run --separate-stderr bash "$STATUS_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"newer plugin version"* ]]
}

@test "status: extra args are rejected" {
  run --separate-stderr bash "$STATUS_SH" bogus
  [ "$status" -ne 0 ]
}

@test "status: envelope with null .buddy falls through to repair pointer (not garbled)" {
  # schemaVersion=1 is valid so buddy_load returns JSON (not the CORRUPT
  # sentinel), but .buddy is null. Without the upstream validity guard, the
  # @tsv + IFS=$'\t' read path in _status_render_active would collapse the
  # leading empty fields and print a scrambled line. With the guard, this
  # routes to the repair message identical to the CORRUPT sentinel path.
  echo '{"schemaVersion": 1, "buddy": null, "tokens": {"balance": 0}, "meta": {"totalHatches": 1, "pityCounter": 0}}' \
    > "$CLAUDE_PLUGIN_DATA/buddy.json"
  run --separate-stderr bash "$STATUS_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Buddy state needs repair"* ]]
  [[ "$output" != *"Lv."* ]]
}

@test "status: envelope with empty .buddy object falls through to repair pointer" {
  # Same hazard as above with a different shape — empty object instead of null.
  echo '{"schemaVersion": 1, "buddy": {}, "tokens": {"balance": 0}, "meta": {"totalHatches": 1, "pityCounter": 0}}' \
    > "$CLAUDE_PLUGIN_DATA/buddy.json"
  run --separate-stderr bash "$STATUS_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Buddy state needs repair"* ]]
}

@test "status: envelope with .buddy as a string falls through to repair pointer" {
  # The shape validator uses `(.buddy | type) != "object"`. Pin that it rejects
  # non-object types beyond null and empty-object — a string here is the same
  # class of malformation and must route to repair, not crash.
  echo '{"schemaVersion": 1, "buddy": "broken", "tokens": {"balance": 0}, "meta": {"totalHatches": 1, "pityCounter": 0}}' \
    > "$CLAUDE_PLUGIN_DATA/buddy.json"
  run --separate-stderr bash "$STATUS_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Buddy state needs repair"* ]]
}

@test "status: envelope with .buddy as an array falls through to repair pointer" {
  echo '{"schemaVersion": 1, "buddy": [], "tokens": {"balance": 0}, "meta": {"totalHatches": 1, "pityCounter": 0}}' \
    > "$CLAUDE_PLUGIN_DATA/buddy.json"
  run --separate-stderr bash "$STATUS_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Buddy state needs repair"* ]]
}

# ============================================================
# reset.sh — --confirm gate and atomic wipe
# ============================================================

@test "reset: without --confirm on ACTIVE prints consequences, no mutation" {
  _seed_hatch
  local before
  before="$(cat "$CLAUDE_PLUGIN_DATA/buddy.json")"

  run --separate-stderr bash "$RESET_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All buddy data will be lost"* ]]
  [[ "$output" == *"--confirm"* ]]

  local after
  after="$(cat "$CLAUDE_PLUGIN_DATA/buddy.json")"
  [ "$before" = "$after" ]
}

@test "reset: --confirm on ACTIVE deletes buddy.json, leaves no .deleted behind, lock persists" {
  _seed_hatch
  [ -f "$CLAUDE_PLUGIN_DATA/buddy.json" ]

  run --separate-stderr bash "$RESET_SH" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"Buddy reset"* ]]

  [ ! -f "$CLAUDE_PLUGIN_DATA/buddy.json" ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/buddy.json.deleted" ]
  # Lock file is expected to persist (state.sh uses it for locking, never deletes).
  [ -f "$CLAUDE_PLUGIN_DATA/buddy.json.lock" ]
}

@test "reset: --confirm on NO_BUDDY is a no-op success with distinct wording" {
  run --separate-stderr bash "$RESET_SH" --confirm
  [ "$status" -eq 0 ]
  # Distinct from the destructive wipe message so agents can tell them apart.
  [[ "$output" == *"No buddy to reset"* ]]
  [[ "$output" != *"Buddy reset."* ]]
  [ ! -f "$CLAUDE_PLUGIN_DATA/buddy.json" ]
}

@test "reset: --confirm when data dir exists but buddy.json absent is also a no-op with distinct wording" {
  # Data dir exists (common case — prior session created the dir but never hatched).
  # Distinct from both the destructive wipe and the data-dir-missing paths.
  run --separate-stderr bash "$RESET_SH" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"No buddy to reset"* ]]
  [ ! -f "$CLAUDE_PLUGIN_DATA/buddy.json" ]
}

@test "reset: --confirm on CORRUPT wipes without parsing (no buddy_load call)" {
  _seed_corrupt
  [ -f "$CLAUDE_PLUGIN_DATA/buddy.json" ]

  run --separate-stderr bash "$RESET_SH" --confirm
  [ "$status" -eq 0 ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/buddy.json" ]
}

@test "reset: --confirm on FUTURE_VERSION also wipes cleanly" {
  _seed_future_version
  run --separate-stderr bash "$RESET_SH" --confirm
  [ "$status" -eq 0 ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/buddy.json" ]
}

@test "reset: refuses a symlinked lock file (attack surface guard)" {
  # Create a FIFO and point the lock path at it. buddy_save rejects this for
  # the same reason — opening a FIFO symlink with exec {fd}> would hang past
  # the flock timeout. Wrap in timeout 3 so a regression fails instead of
  # hanging the test run.
  mkfifo "$CLAUDE_PLUGIN_DATA/fifo"
  ln -sf "$CLAUDE_PLUGIN_DATA/fifo" "$CLAUDE_PLUGIN_DATA/buddy.json.lock"

  run --separate-stderr timeout 3 bash "$RESET_SH" --confirm
  [ "$status" -ne 0 ]
  [ "$status" -ne 124 ]   # 124 = timeout fired (regression: script would hang)
}

@test "reset: unknown flag exits non-zero" {
  run --separate-stderr bash "$RESET_SH" --bogus
  [ "$status" -ne 0 ]
}

# ============================================================
# Crash recovery: state_cleanup_orphans sweeps .deleted markers
# ============================================================

@test "reset: state_cleanup_orphans removes an orphan buddy.json.deleted" {
  # Simulate a reset that crashed between mv and rm by leaving .deleted behind.
  echo '{"ghost":true}' > "$CLAUDE_PLUGIN_DATA/buddy.json.deleted"
  [ -f "$CLAUDE_PLUGIN_DATA/buddy.json.deleted" ]

  state_cleanup_orphans

  [ ! -f "$CLAUDE_PLUGIN_DATA/buddy.json.deleted" ]
}

@test "reset: state_cleanup_orphans leaves buddy.json and its lock untouched" {
  _seed_hatch
  state_cleanup_orphans

  [ -f "$CLAUDE_PLUGIN_DATA/buddy.json" ]
  [ -f "$CLAUDE_PLUGIN_DATA/buddy.json.lock" ]
  # Valid buddy.json still parses.
  run --separate-stderr jq '.' "$CLAUDE_PLUGIN_DATA/buddy.json"
  [ "$status" -eq 0 ]
}

# ============================================================
# Concurrency: flock serializes racing writers
# ============================================================

# bats test_tags=concurrency,slow
@test "concurrency: two racing first-hatch attempts produce exactly one valid buddy" {
  local hatch_sh="$HATCH_SH"
  local data_dir="$CLAUDE_PLUGIN_DATA"

  # Fire two hatches in parallel on a shared data dir. flock inside buddy_save
  # serializes the writes; both attempts "see" NO_BUDDY at start, but only one
  # winning rename lands. The loser may overwrite with its own envelope — either
  # way, the file on disk is valid and parseable.
  (CLAUDE_PLUGIN_DATA="$data_dir" bash "$hatch_sh" >/dev/null 2>&1) &
  (CLAUDE_PLUGIN_DATA="$data_dir" bash "$hatch_sh" >/dev/null 2>&1) &
  wait

  [ -f "$data_dir/buddy.json" ]
  run --separate-stderr jq '.' "$data_dir/buddy.json"
  [ "$status" -eq 0 ]
  # Whichever hatch won, it was a first-hatch (totalHatches=1) — proving no
  # partial interleaving slipped into the reroll path (which would set totalHatches=2).
  [ "$(jq -r '.meta.totalHatches' "$data_dir/buddy.json")" = "1" ]
}

# bats test_tags=concurrency,slow
@test "concurrency: hatch racing reset produces either NO_BUDDY or a valid envelope" {
  _seed_hatch
  local hatch_sh="$HATCH_SH"
  local reset_sh="$RESET_SH"
  local data_dir="$CLAUDE_PLUGIN_DATA"

  (CLAUDE_PLUGIN_DATA="$data_dir" bash "$reset_sh" --confirm >/dev/null 2>&1) &
  (CLAUDE_PLUGIN_DATA="$data_dir" bash "$hatch_sh" >/dev/null 2>&1) &
  wait

  # Two legal outcomes: either buddy.json is gone (reset last) OR it exists
  # and is valid (hatch last, or hatch ran after reset on NO_BUDDY). Never a
  # partial file.
  if [ -f "$data_dir/buddy.json" ]; then
    run --separate-stderr jq '.' "$data_dir/buddy.json"
    [ "$status" -eq 0 ]
    # Whichever path got the file, only the NO_BUDDY → first-hatch branch is
    # supposed to land here. totalHatches=2 would mean hatch read the seeded
    # state outside the flock, then wrote a reroll envelope after reset's
    # destructive step — the lost-update race ADV-001 / REL-001 warns about.
    # This assertion pins the design intent: reroll should not silently win
    # after a clean reset.
    [ "$(jq -r '.meta.totalHatches' "$data_dir/buddy.json")" = "1" ]
  fi
  [ ! -f "$data_dir/buddy.json.deleted" ]
}
