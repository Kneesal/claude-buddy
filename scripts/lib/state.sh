#!/usr/bin/env bash
# state.sh — Buddy plugin state primitives
# Provides atomic, flock-locked JSON persistence for buddy.json
# and per-session ephemeral state for session-<id>.json.
#
# Sentinels (returned by buddy_load):
#   NO_BUDDY        — file does not exist (fresh install or post-reset)
#   CORRUPT         — file exists but is unparseable or missing schemaVersion
#   FUTURE_VERSION  — schemaVersion is higher than this code supports
#
# All functions use ${CLAUDE_PLUGIN_DATA} as the data directory.
# All error paths log to stderr and return non-zero. No function ever exits
# the calling script — callers check return values and sentinels.

set -euo pipefail

readonly CURRENT_SCHEMA_VERSION=1
readonly FLOCK_TIMEOUT=0.2

# Sentinels — callers compare against these
readonly STATE_NO_BUDDY="NO_BUDDY"
readonly STATE_CORRUPT="CORRUPT"
readonly STATE_FUTURE_VERSION="FUTURE_VERSION"

# --- Internal helpers ---

_state_data_dir() {
  if [[ -z "${CLAUDE_PLUGIN_DATA:-}" ]]; then
    return 1
  fi
  printf '%s' "$CLAUDE_PLUGIN_DATA"
}

_state_log() {
  echo "buddy-state: $*" >&2
}

# --- Schema migration ---

# Migrate JSON from its current schemaVersion to CURRENT_SCHEMA_VERSION.
# Reads JSON from stdin, writes migrated JSON to stdout.
# Returns 0 on success, 1 on failure.
# Migration happens in memory — the caller decides whether to persist.
migrate() {
  local json
  json="$(cat)"

  local version
  version="$(printf '%s' "$json" | jq -r '.schemaVersion // empty')"

  if [[ -z "$version" ]]; then
    _state_log "migrate: missing schemaVersion"
    return 1
  fi

  while [[ "$version" -lt "$CURRENT_SCHEMA_VERSION" ]]; do
    case "$version" in
      # v1 is current — no migrations needed yet.
      # Future migrations go here:
      # 1)
      #   json="$(printf '%s' "$json" | jq '.schemaVersion = 2 | .newField //= "default"')"
      #   ;;
      *)
        _state_log "migrate: unknown schema version $version"
        return 1
        ;;
    esac
    version="$(printf '%s' "$json" | jq -r '.schemaVersion')"
  done

  printf '%s' "$json"
}

# --- Buddy state ---

# Load buddy state from ${CLAUDE_PLUGIN_DATA}/buddy.json.
# Outputs one of:
#   - Valid JSON (the buddy state, possibly migrated in memory)
#   - A sentinel string: NO_BUDDY, CORRUPT, or FUTURE_VERSION
# Always returns 0 — callers check the output string against the sentinel constants.
buddy_load() {
  local data_dir
  data_dir="$(_state_data_dir)" || {
    printf '%s' "$STATE_NO_BUDDY"
    return 0
  }

  local buddy_file="$data_dir/buddy.json"

  if [[ ! -f "$buddy_file" ]]; then
    printf '%s' "$STATE_NO_BUDDY"
    return 0
  fi

  # Parse JSON
  local json
  if ! json="$(jq '.' "$buddy_file" 2>/dev/null)"; then
    _state_log "buddy_load: failed to parse $buddy_file"
    printf '%s' "$STATE_CORRUPT"
    return 0
  fi

  # Empty or null result from jq
  if [[ -z "$json" || "$json" == "null" ]]; then
    _state_log "buddy_load: empty or null content in $buddy_file"
    printf '%s' "$STATE_CORRUPT"
    return 0
  fi

  # Check schemaVersion
  local version
  version="$(printf '%s' "$json" | jq -r '.schemaVersion // empty')"

  if [[ -z "$version" ]]; then
    _state_log "buddy_load: missing schemaVersion in $buddy_file"
    printf '%s' "$STATE_CORRUPT"
    return 0
  fi

  # Future version check
  if [[ "$version" -gt "$CURRENT_SCHEMA_VERSION" ]]; then
    _state_log "buddy_load: state is from a newer plugin version (v$version > v$CURRENT_SCHEMA_VERSION). Update the plugin or run /buddy:hatch to start fresh."
    printf '%s' "$STATE_FUTURE_VERSION"
    return 0
  fi

  # Migrate if needed (in memory only — not written back)
  if [[ "$version" -lt "$CURRENT_SCHEMA_VERSION" ]]; then
    local migrated
    if migrated="$(printf '%s' "$json" | migrate)"; then
      json="$migrated"
    else
      _state_log "buddy_load: migration failed from v$version"
      printf '%s' "$STATE_CORRUPT"
      return 0
    fi
  fi

  printf '%s' "$json"
  return 0
}

# Save buddy state to ${CLAUDE_PLUGIN_DATA}/buddy.json.
# Reads JSON content from stdin.
# Stamps schemaVersion on every write.
# Uses flock on buddy.json.lock for concurrency safety.
# Uses tmp+rename for atomic writes.
# Returns 0 on success, 1 on failure.
buddy_save() {
  local data_dir
  data_dir="$(_state_data_dir)" || {
    _state_log "buddy_save: CLAUDE_PLUGIN_DATA not set"
    return 1
  }

  # Ensure data directory exists
  if ! mkdir -p "$data_dir" 2>/dev/null; then
    _state_log "buddy_save: failed to create $data_dir"
    return 1
  fi

  local buddy_file="$data_dir/buddy.json"
  local lock_file="$data_dir/buddy.json.lock"

  # Read content from stdin and stamp schemaVersion
  local content
  content="$(jq --argjson v "$CURRENT_SCHEMA_VERSION" '.schemaVersion = $v' 2>/dev/null)" || {
    _state_log "buddy_save: invalid JSON input"
    return 1
  }

  # Acquire flock using exec-based fd (portable, no subshell needed)
  local lock_fd
  exec {lock_fd}>"$lock_file" || {
    _state_log "buddy_save: failed to open lock file"
    return 1
  }

  if ! flock -x -w "$FLOCK_TIMEOUT" "$lock_fd"; then
    exec {lock_fd}>&-
    _state_log "buddy_save: flock timeout after ${FLOCK_TIMEOUT}s"
    return 1
  fi

  # Create temp file in the same directory (same-filesystem guarantee)
  local tmp
  tmp="$(mktemp "$data_dir/.tmp.XXXXXX")" || {
    exec {lock_fd}>&-
    _state_log "buddy_save: failed to create temp file"
    return 1
  }

  # Write content to temp file, clean up on failure
  if ! printf '%s\n' "$content" > "$tmp"; then
    rm -f "$tmp"
    exec {lock_fd}>&-
    _state_log "buddy_save: failed to write temp file"
    return 1
  fi

  # Atomic rename
  if ! mv -f "$tmp" "$buddy_file"; then
    rm -f "$tmp"
    exec {lock_fd}>&-
    _state_log "buddy_save: failed to rename temp to $buddy_file"
    return 1
  fi

  # Release lock
  exec {lock_fd}>&-
}

# --- Session state (per-sessionId, no locking) ---

# Load session state for a given session ID.
# Outputs JSON content or an empty default if the session file doesn't exist.
# Always returns 0.
session_load() {
  local session_id="${1:?session_load requires a session_id argument}"

  local data_dir
  data_dir="$(_state_data_dir)" || {
    echo '{}'
    return 0
  }

  local session_file="$data_dir/session-${session_id}.json"

  if [[ ! -f "$session_file" ]]; then
    echo '{}'
    return 0
  fi

  local json
  if json="$(jq '.' "$session_file" 2>/dev/null)" && [[ -n "$json" && "$json" != "null" ]]; then
    printf '%s' "$json"
  else
    _state_log "session_load: failed to parse $session_file, returning default"
    echo '{}'
  fi
  return 0
}

# Save session state for a given session ID.
# Reads JSON content from stdin.
# No flock (single writer per session). No atomic rename (ephemeral data).
# Returns 0 on success, 1 on failure.
session_save() {
  local session_id="${1:?session_save requires a session_id argument}"

  local data_dir
  data_dir="$(_state_data_dir)" || {
    _state_log "session_save: CLAUDE_PLUGIN_DATA not set"
    return 1
  }

  if ! mkdir -p "$data_dir" 2>/dev/null; then
    _state_log "session_save: failed to create $data_dir"
    return 1
  fi

  local session_file="$data_dir/session-${session_id}.json"

  if ! cat > "$session_file"; then
    _state_log "session_save: failed to write $session_file"
    return 1
  fi
}

# --- Orphan cleanup ---

# Remove stale temp files and session files older than 1 hour.
# Called by P3-1's session-start.sh — not invoked directly by state.sh.
# Always returns 0.
state_cleanup_orphans() {
  local data_dir
  data_dir="$(_state_data_dir)" || return 0

  if [[ ! -d "$data_dir" ]]; then
    return 0
  fi

  # Remove .tmp files older than 60 minutes
  find "$data_dir" -maxdepth 1 -name '.tmp.*' -mmin +60 -delete 2>/dev/null || true

  # Remove stale session files older than 60 minutes
  find "$data_dir" -maxdepth 1 -name 'session-*.json' -mmin +60 -delete 2>/dev/null || true

  return 0
}
