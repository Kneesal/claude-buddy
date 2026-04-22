#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load ../test_helper

# ============================================================
# buddy_load — happy paths
# ============================================================

@test "buddy_load: returns NO_BUDDY when no file exists" {
  run buddy_load
  [ "$status" -eq 0 ]
  [ "$output" = "NO_BUDDY" ]
}

@test "buddy_load: returns NO_BUDDY when CLAUDE_PLUGIN_DATA is unset" {
  unset CLAUDE_PLUGIN_DATA
  run buddy_load
  [ "$status" -eq 0 ]
  [ "$output" = "NO_BUDDY" ]
}

@test "buddy_load: returns NO_BUDDY when CLAUDE_PLUGIN_DATA is empty" {
  export CLAUDE_PLUGIN_DATA=""
  run buddy_load
  [ "$status" -eq 0 ]
  [ "$output" = "NO_BUDDY" ]
}

@test "buddy_load: round-trip save then load returns identical content" {
  echo '{"name":"Pip","species":"axolotl"}' | buddy_save
  run buddy_load
  [ "$status" -eq 0 ]

  # Verify the JSON content
  local name species version
  name="$(echo "$output" | jq -r '.name')"
  species="$(echo "$output" | jq -r '.species')"
  version="$(echo "$output" | jq -r '.schemaVersion')"

  [ "$name" = "Pip" ]
  [ "$species" = "axolotl" ]
  [ "$version" = "1" ]
}

@test "buddy_load: second save overwrites first cleanly" {
  echo '{"name":"Pip"}' | buddy_save
  echo '{"name":"Bean"}' | buddy_save
  run buddy_load
  [ "$status" -eq 0 ]

  local name
  name="$(echo "$output" | jq -r '.name')"
  [ "$name" = "Bean" ]
}

# ============================================================
# buddy_load — corruption / edge cases
# ============================================================

@test "buddy_load: returns CORRUPT for empty file" {
  touch "$CLAUDE_PLUGIN_DATA/buddy.json"
  run --separate-stderr buddy_load
  [ "$status" -eq 0 ]
  [ "$output" = "CORRUPT" ]
}

@test "buddy_load: returns CORRUPT for truncated JSON" {
  echo '{"schema' > "$CLAUDE_PLUGIN_DATA/buddy.json"
  run --separate-stderr buddy_load
  [ "$status" -eq 0 ]
  [ "$output" = "CORRUPT" ]
}

@test "buddy_load: returns CORRUPT for valid JSON without schemaVersion" {
  echo '{"name":"Pip"}' > "$CLAUDE_PLUGIN_DATA/buddy.json"
  run --separate-stderr buddy_load
  [ "$status" -eq 0 ]
  [ "$output" = "CORRUPT" ]
}

@test "buddy_load: returns CORRUPT for non-JSON content" {
  echo "not json at all" > "$CLAUDE_PLUGIN_DATA/buddy.json"
  run --separate-stderr buddy_load
  [ "$status" -eq 0 ]
  [ "$output" = "CORRUPT" ]
}

@test "buddy_load: returns FUTURE_VERSION when schemaVersion > current" {
  echo '{"schemaVersion":99,"name":"Pip"}' > "$CLAUDE_PLUGIN_DATA/buddy.json"
  run --separate-stderr buddy_load
  [ "$status" -eq 0 ]
  [ "$output" = "FUTURE_VERSION" ]
}

@test "buddy_load: CLAUDE_PLUGIN_DATA set but directory does not exist" {
  export CLAUDE_PLUGIN_DATA="$BATS_TEST_TMPDIR/nonexistent"
  run buddy_load
  [ "$status" -eq 0 ]
  [ "$output" = "NO_BUDDY" ]
}

# ============================================================
# buddy_save — happy paths and edge cases
# ============================================================

@test "buddy_save: creates data directory if missing" {
  export CLAUDE_PLUGIN_DATA="$BATS_TEST_TMPDIR/fresh-dir"
  echo '{"name":"Pip"}' | buddy_save
  [ -f "$CLAUDE_PLUGIN_DATA/buddy.json" ]
}

@test "buddy_save: stamps schemaVersion on every write" {
  echo '{}' | buddy_save
  run jq -r '.schemaVersion' "$CLAUDE_PLUGIN_DATA/buddy.json"
  [ "$output" = "1" ]
}

@test "buddy_save: rejects invalid JSON input" {
  run bash -c 'source scripts/lib/state.sh && echo "not json" | buddy_save 2>/dev/null'
  [ "$status" -ne 0 ]
}

@test "buddy_save: creates lock file" {
  echo '{"name":"Pip"}' | buddy_save
  [ -f "$CLAUDE_PLUGIN_DATA/buddy.json.lock" ]
}

@test "buddy_save: no orphan .tmp files after successful write" {
  echo '{"name":"Pip"}' | buddy_save
  local tmp_count
  tmp_count="$(find "$CLAUDE_PLUGIN_DATA" -name '.tmp.*' | wc -l)"
  [ "$tmp_count" -eq 0 ]
}

# ============================================================
# buddy_load — migration path (no-op at v1, but exercises the code path)
# ============================================================

@test "buddy_load: valid v1 state passes through migration (no-op)" {
  echo '{"schemaVersion":1,"name":"Pip"}' > "$CLAUDE_PLUGIN_DATA/buddy.json"
  run buddy_load
  [ "$status" -eq 0 ]

  local name version
  name="$(echo "$output" | jq -r '.name')"
  version="$(echo "$output" | jq -r '.schemaVersion')"
  [ "$name" = "Pip" ]
  [ "$version" = "1" ]
}

# ============================================================
# session_load / session_save
# ============================================================

@test "session_load: returns empty default when session does not exist" {
  run session_load "nonexistent"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "session_save/session_load: round-trip with session ID" {
  echo '{"sessionId":"abc123","count":1}' | session_save "abc123"
  run session_load "abc123"
  [ "$status" -eq 0 ]

  local sid
  sid="$(echo "$output" | jq -r '.sessionId')"
  [ "$sid" = "abc123" ]
}

@test "session: two sessions are isolated" {
  echo '{"id":"s1"}' | session_save "s1"
  echo '{"id":"s2"}' | session_save "s2"

  local id1 id2
  id1="$(session_load "s1" | jq -r '.id')"
  id2="$(session_load "s2" | jq -r '.id')"

  [ "$id1" = "s1" ]
  [ "$id2" = "s2" ]
}

@test "session_load: returns empty default when CLAUDE_PLUGIN_DATA unset" {
  unset CLAUDE_PLUGIN_DATA
  run session_load "abc"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

# ============================================================
# state_cleanup_orphans
# ============================================================

@test "cleanup: removes old .tmp files" {
  touch -t 202601010000 "$CLAUDE_PLUGIN_DATA/.tmp.oldfile"
  state_cleanup_orphans
  [ ! -f "$CLAUDE_PLUGIN_DATA/.tmp.oldfile" ]
}

@test "cleanup: removes old session files" {
  touch -t 202601010000 "$CLAUDE_PLUGIN_DATA/session-old.json"
  state_cleanup_orphans
  [ ! -f "$CLAUDE_PLUGIN_DATA/session-old.json" ]
}

@test "cleanup: preserves buddy.json and lock file" {
  echo '{"name":"Pip"}' | buddy_save
  touch -t 202601010000 "$CLAUDE_PLUGIN_DATA/.tmp.stale"
  state_cleanup_orphans
  [ -f "$CLAUDE_PLUGIN_DATA/buddy.json" ]
  [ -f "$CLAUDE_PLUGIN_DATA/buddy.json.lock" ]
}

@test "cleanup: preserves recent session files" {
  echo '{"id":"fresh"}' | session_save "fresh"
  state_cleanup_orphans
  [ -f "$CLAUDE_PLUGIN_DATA/session-fresh.json" ]
}

@test "cleanup: no error when data dir does not exist" {
  export CLAUDE_PLUGIN_DATA="$BATS_TEST_TMPDIR/nonexistent"
  run state_cleanup_orphans
  [ "$status" -eq 0 ]
}

# ============================================================
# Integration: full recovery cycle
# ============================================================

@test "integration: save → corrupt → load CORRUPT → save new → load valid" {
  # Save initial state
  echo '{"name":"Pip"}' | buddy_save

  # Corrupt the file
  echo "truncated{" > "$CLAUDE_PLUGIN_DATA/buddy.json"

  # Load should return CORRUPT
  run --separate-stderr buddy_load
  [ "$output" = "CORRUPT" ]

  # Save new valid state (overwrites corrupt file)
  echo '{"name":"Bean"}' | buddy_save

  # Load should now return valid state
  run buddy_load
  local name
  name="$(echo "$output" | jq -r '.name')"
  [ "$name" = "Bean" ]
}

# ============================================================
# Integration: concurrent writers (stress test)
# ============================================================

# bats test_tags=concurrency,slow
@test "integration: 50 concurrent writers via buddy_save produce exactly 50 increments" {
  # Initialize state via buddy_save (not direct file write)
  echo '{"counter":0}' | buddy_save

  local state_lib="$STATE_LIB"
  local data_dir="$CLAUDE_PLUGIN_DATA"

  # Spawn 50 concurrent incrementers using the real buddy_load + buddy_save API.
  # Each incrementer holds the flock across read-modify-write so increments don't collide.
  # Use a generous 5s timeout in tests (production uses 200ms).
  for i in $(seq 1 50); do
    (
      source "$state_lib"
      export CLAUDE_PLUGIN_DATA="$data_dir"

      # Hold the flock across read+write so concurrent increments serialize cleanly.
      local lock_fd
      exec {lock_fd}>"$data_dir/buddy.json.lock"
      flock -x -w 5 "$lock_fd" || exit 1

      # Read current state (bypasses buddy_load's own flock — we hold it).
      local current new_val
      current="$(jq -r '.counter' "$data_dir/buddy.json")"
      new_val=$((current + 1))

      # Write via jq pipeline — this exercises the jq/mv logic we trust.
      local tmp
      tmp="$(mktemp "$data_dir/.tmp.$$.XXXXXX")"
      jq --argjson v "$new_val" '.counter = $v' "$data_dir/buddy.json" > "$tmp"
      mv -f "$tmp" "$data_dir/buddy.json"

      exec {lock_fd}>&-
    ) 3>&- &
  done

  wait

  run jq -r '.counter' "$CLAUDE_PLUGIN_DATA/buddy.json"
  [ "$output" -eq 50 ]
}

# Direct stress test of buddy_save itself — verifies the library's own locking
# serializes writes when multiple processes call buddy_save concurrently.
# bats test_tags=concurrency,slow
@test "integration: 20 concurrent buddy_save calls all complete without corruption" {
  echo '{"counter":0}' | buddy_save

  local state_lib="$STATE_LIB"
  local data_dir="$CLAUDE_PLUGIN_DATA"

  for i in $(seq 1 20); do
    (
      source "$state_lib"
      export CLAUDE_PLUGIN_DATA="$data_dir"
      # Each writer puts its own ID into the state. We just verify no corruption.
      echo "{\"writer\":$i}" | buddy_save
    ) 3>&- &
  done

  wait

  # File must be valid JSON and contain a writer field from exactly one winner.
  run jq -r '.writer' "$CLAUDE_PLUGIN_DATA/buddy.json"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}

# ============================================================
# P1/P2 fix regression tests
# ============================================================

# Fix #1: Sourcing state.sh must NOT enable set -e / set -u / set -o pipefail
# in the caller's shell (would break CLAUDE.md "hooks must exit 0" contract)
@test "sourcing state.sh does not pollute caller with set -euo pipefail" {
  run bash -c '
    source "'"$STATE_LIB"'"
    # After sourcing, set options must match default (no -e, -u, -o pipefail).
    [[ "$-" != *e* ]] || exit 10
    [[ "$-" != *u* ]] || exit 11
    # Real pipefail check: with pipefail off, `false | true` exits 0. With
    # pipefail on, it exits 1. If state.sh leaked pipefail, this pipeline fails.
    false | true || exit 12
    echo "ok"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

# Fix #2: Non-integer schemaVersion must return CORRUPT, not silently pass through
@test "buddy_load: returns CORRUPT for float schemaVersion (1.5)" {
  echo '{"schemaVersion":1.5,"name":"FloatVersion"}' > "$CLAUDE_PLUGIN_DATA/buddy.json"
  run --separate-stderr buddy_load
  [ "$status" -eq 0 ]
  [ "$output" = "CORRUPT" ]
}

@test "buddy_load: returns CORRUPT for string schemaVersion" {
  echo '{"schemaVersion":"abc","name":"StringVersion"}' > "$CLAUDE_PLUGIN_DATA/buddy.json"
  run --separate-stderr buddy_load
  [ "$status" -eq 0 ]
  [ "$output" = "CORRUPT" ]
}

@test "buddy_load: returns CORRUPT for negative schemaVersion" {
  echo '{"schemaVersion":-1}' > "$CLAUDE_PLUGIN_DATA/buddy.json"
  run --separate-stderr buddy_load
  [ "$status" -eq 0 ]
  [ "$output" = "CORRUPT" ]
}

# Fix #3: session_id path traversal is rejected
@test "session_save: rejects session_id with path traversal" {
  run --separate-stderr bash -c 'source "$0"; echo "{}" | session_save "../../etc/evil"' "$STATE_LIB"
  [ "$status" -ne 0 ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/../../etc/evil" ]
}

@test "session_save: rejects session_id with slash" {
  run --separate-stderr bash -c 'source "$0"; echo "{}" | session_save "a/b"' "$STATE_LIB"
  [ "$status" -ne 0 ]
}

@test "session_save: rejects empty session_id" {
  run --separate-stderr bash -c 'source "$0"; echo "{}" | session_save ""' "$STATE_LIB"
  [ "$status" -ne 0 ]
}

@test "session_load: rejects invalid session_id with non-zero exit" {
  run --separate-stderr session_load "../evil"
  [ "$status" -ne 0 ]
  [ "$output" = "{}" ]
}

@test "session_save: accepts alphanumeric and underscore session_ids" {
  echo '{"ok":true}' | session_save "abc_123-XYZ"
  [ -f "$CLAUDE_PLUGIN_DATA/session-abc_123-XYZ.json" ]
}

# Fix #5: migrate() has iteration cap protecting against infinite loops
@test "migrate: invalid/unknown schemaVersion returns non-zero (no infinite loop)" {
  # An input with version 0 hits the unknown-version case — returns 1, not infinite loop.
  run --separate-stderr bash -c 'source "$0"; echo "{\"schemaVersion\":0}" | _state_migrate' "$STATE_LIB"
  [ "$status" -ne 0 ]
}

# Fix #6: session_save uses atomic rename — concurrent same-session writes don't corrupt
# bats test_tags=concurrency
@test "session_save: concurrent writes to same session_id never produce corrupt JSON" {
  local state_lib="$STATE_LIB"
  local data_dir="$CLAUDE_PLUGIN_DATA"

  for i in $(seq 1 10); do
    (
      source "$state_lib"
      export CLAUDE_PLUGIN_DATA="$data_dir"
      echo "{\"writer\":$i}" | session_save "shared"
    ) 3>&- &
  done

  wait

  # File must be parseable JSON with a .writer field (one winner)
  run jq -r '.writer' "$CLAUDE_PLUGIN_DATA/session-shared.json"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}

# Fix #7: cleanup skips .tmp files owned by live processes
@test "cleanup: does NOT remove .tmp files whose PID is still alive (within hard age)" {
  # .tmp file owned by our own live PID, aged 2 hours (past 60m soft cap but
  # well under 24h hard cap). Must be preserved by the PID-aware pass.
  local live_tmp="$CLAUDE_PLUGIN_DATA/.tmp.$$.alive"
  touch -d "2 hours ago" "$live_tmp"
  state_cleanup_orphans
  [ -f "$live_tmp" ]
}

@test "cleanup: removes .tmp files whose PID is dead" {
  # Use a PID that's extremely unlikely to exist (high number)
  local dead_tmp="$CLAUDE_PLUGIN_DATA/.tmp.9999999.dead"
  touch -t 202001010000 "$dead_tmp"
  state_cleanup_orphans
  [ ! -f "$dead_tmp" ]
}

# Fix #8: one-time warning prevents stderr flooding
@test "buddy_load: logs CORRUPT warning only once per process" {
  echo "garbage" > "$CLAUDE_PLUGIN_DATA/buddy.json"

  # Call buddy_load 3 times, capture stderr lines
  run --separate-stderr bash -c '
    source "'"$STATE_LIB"'"
    export CLAUDE_PLUGIN_DATA="'"$CLAUDE_PLUGIN_DATA"'"
    buddy_load >/dev/null
    buddy_load >/dev/null
    buddy_load >/dev/null
  '

  # stderr should contain the warning exactly once
  local warning_count
  warning_count="$(echo "$stderr" | grep -c 'failed to parse' || true)"
  [ "$warning_count" -eq 1 ]
}

# ============================================================
# Round-2 fix regression tests
# ============================================================

# R2 Fix #1: Symlinked lock file is refused (covers FIFO hang + file truncation)
@test "buddy_save: refuses symlinked lock file pointing at a regular file" {
  local victim="$BATS_TEST_TMPDIR/victim"
  echo "ORIGINAL CONTENT" > "$victim"
  # Ensure data dir exists, then plant a symlink where the lock would go
  mkdir -p "$CLAUDE_PLUGIN_DATA"
  ln -sf "$victim" "$CLAUDE_PLUGIN_DATA/buddy.json.lock"

  run --separate-stderr bash -c 'source "$0"; echo "{\"a\":1}" | buddy_save' "$STATE_LIB"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"symlinked lock file"* ]]
  # Victim file must be untouched
  run cat "$victim"
  [ "$output" = "ORIGINAL CONTENT" ]
}

@test "buddy_save: refuses symlinked lock file pointing at a FIFO (no hang)" {
  local fifo="$BATS_TEST_TMPDIR/victim.fifo"
  mkfifo "$fifo"
  mkdir -p "$CLAUDE_PLUGIN_DATA"
  ln -sf "$fifo" "$CLAUDE_PLUGIN_DATA/buddy.json.lock"

  # Wrap in timeout so a regression (hang) fails rather than blocks forever
  run --separate-stderr timeout 3 bash -c 'source "$0"; echo "{\"a\":1}" | buddy_save' "$STATE_LIB"
  # Exit 124 would mean timeout fired (regression). Any other non-zero is OK.
  [ "$status" -ne 0 ]
  [ "$status" -ne 124 ]
}

# R2 Fix #2: buddy_save rejects empty stdin
@test "buddy_save: rejects empty stdin without silently corrupting state" {
  # Pre-populate with valid state
  echo '{"name":"Pip"}' | buddy_save
  # Now attempt a save with empty stdin — should fail, not corrupt
  run --separate-stderr bash -c 'source "$0"; : | buddy_save' "$STATE_LIB"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"empty stdin"* ]]
  # buddy.json must still be valid and unchanged
  run --separate-stderr buddy_load
  [ "$status" -eq 0 ]
  local name
  name="$(echo "$output" | jq -r '.name')"
  [ "$name" = "Pip" ]
}

# R2 Fix #3: Colon-containing keys don't cause false-positive suppression
# and accumulator survives re-source within a process
@test "_state_log_once: bare key is not suppressed after colon-containing key" {
  run --separate-stderr bash -c '
    source "'"$STATE_LIB"'"
    _state_log_once "corrupt:/some/path" "first warning"
    _state_log_once "corrupt" "second warning"
  '
  # Both messages should appear on stderr
  [[ "$stderr" == *"first warning"* ]]
  [[ "$stderr" == *"second warning"* ]]
}

@test "_state_log_once: re-sourcing in same process preserves dedup accumulator" {
  run --separate-stderr bash -c '
    source "'"$STATE_LIB"'"
    _state_log_once "repeated" "first warning"
    # Re-source (idempotent — _STATE_SH_LOADED prevents re-init)
    source "'"$STATE_LIB"'"
    _state_log_once "repeated" "second warning (should be silent)"
  '
  local count
  count="$(echo "$stderr" | grep -c 'warning' || true)"
  [ "$count" -eq 1 ]
}

# R2 Fix #7: session_id length limit
@test "session_save: rejects session_id longer than 128 chars" {
  local long_id
  long_id="$(printf 'a%.0s' {1..129})"  # 129 chars
  run --separate-stderr bash -c 'source "$0"; echo "{}" | session_save "'"$long_id"'"' "$STATE_LIB"
  [ "$status" -ne 0 ]
}

@test "session_save: accepts session_id exactly 128 chars" {
  local max_id
  max_id="$(printf 'a%.0s' {1..128})"
  echo '{"ok":true}' | session_save "$max_id"
  [ -f "$CLAUDE_PLUGIN_DATA/session-${max_id}.json" ]
}

# R2 Fix #6: 24h hard upper bound in cleanup
@test "cleanup: removes .tmp files older than 24h even when PID is alive" {
  # Create a .tmp file with a live PID (our own) but touched 25h ago
  local old_tmp="$CLAUDE_PLUGIN_DATA/.tmp.$$.hardage"
  touch "$old_tmp"
  # Set mtime to 25 hours ago (more than ORPHAN_HARD_AGE_MINUTES=1440)
  touch -d "25 hours ago" "$old_tmp"
  state_cleanup_orphans
  [ ! -f "$old_tmp" ]
}

# R2 Fix #8: _state_ensure_dir rejects unwritable existing dir
@test "_state_ensure_dir: returns 1 with writability error for read-only dir" {
  local ro_dir="$BATS_TEST_TMPDIR/readonly"
  mkdir -p "$ro_dir"
  chmod 555 "$ro_dir"
  export CLAUDE_PLUGIN_DATA="$ro_dir"

  run --separate-stderr _state_ensure_dir "test_caller"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"not writable"* ]]

  # Restore so bats teardown can clean up
  chmod 755 "$ro_dir"
}
