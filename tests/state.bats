#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load test_helper

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
@test "integration: 50 concurrent writers produce exactly 50 increments" {
  # Initialize counter at 0
  echo '{"schemaVersion":1,"counter":0}' > "$CLAUDE_PLUGIN_DATA/buddy.json"

  local lock_file="$CLAUDE_PLUGIN_DATA/buddy.json.lock"
  local buddy_file="$CLAUDE_PLUGIN_DATA/buddy.json"

  # Spawn 50 concurrent incrementers
  for i in $(seq 1 50); do
    (
      # Use generous timeout for tests (5s vs 200ms production)
      local lock_fd
      exec {lock_fd}>"$lock_file"
      flock -x -w 5 "$lock_fd" || exit 1

      # Read current counter
      local current
      current="$(jq '.counter' "$buddy_file")"

      # Increment
      local new_val=$((current + 1))

      # Atomic write
      local tmp
      tmp="$(mktemp "$CLAUDE_PLUGIN_DATA/.tmp.XXXXXX")"
      jq --argjson v "$new_val" '.counter = $v' "$buddy_file" > "$tmp"
      mv -f "$tmp" "$buddy_file"

      exec {lock_fd}>&-
    ) 3>&- &
  done

  # Wait for all background jobs
  wait

  # Verify final count
  run jq -r '.counter' "$CLAUDE_PLUGIN_DATA/buddy.json"
  [ "$output" -eq 50 ]
}
