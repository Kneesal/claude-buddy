#!/usr/bin/env bash
# state.sh — Buddy plugin state primitives
# Provides atomic, flock-locked JSON persistence for buddy.json
# and per-session ephemeral state for session-<id>.json.
#
# Sentinels (returned by buddy_load):
#   NO_BUDDY        — file does not exist (fresh install or post-reset)
#   CORRUPT         — file exists but is unparseable or missing/invalid schemaVersion
#   FUTURE_VERSION  — schemaVersion is higher than this code supports
#
# All functions use ${CLAUDE_PLUGIN_DATA} as the data directory.
# All error paths log to stderr and return non-zero. No function ever crashes
# the calling script — callers check return values and sentinels.
#
# NOTE: This library does NOT set `set -euo pipefail` at module scope.
# Doing so would pollute any hook script that sources this library and break
# the CLAUDE.md "hooks must exit 0" contract. Error handling is explicit
# per-function instead.

# Require bash 4.1+ for the `exec {fd}>file` automatic-fd-assignment syntax
# used in buddy_save's flock acquisition. On bash 3.x (macOS system bash),
# that syntax silently creates a file named literally `{lock_fd}` and leaves
# the fd variable unset — buddy_save would run WITHOUT holding the lock.
# Fail loudly at source time rather than silently corrupt state.
if [[ -z "${BASH_VERSINFO[0]:-}" ]] || (( BASH_VERSINFO[0] < 4 )) || \
   (( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 1 )); then
  echo "buddy-state: requires bash 4.1+ (got ${BASH_VERSION:-unknown}). On macOS, install via: brew install bash" >&2
  return 1 2>/dev/null || exit 1
fi

# Guard against re-sourcing — readonly variables would error on re-declaration.
if [[ "${_STATE_SH_LOADED:-}" != "1" ]]; then
  _STATE_SH_LOADED=1

  readonly CURRENT_SCHEMA_VERSION=1
  readonly FLOCK_TIMEOUT=0.2
  readonly ORPHAN_MAX_AGE_MINUTES=60
  readonly MIGRATE_MAX_ITERATIONS=32

  # Sentinels — callers compare against these
  readonly STATE_NO_BUDDY="NO_BUDDY"
  readonly STATE_CORRUPT="CORRUPT"
  readonly STATE_FUTURE_VERSION="FUTURE_VERSION"
fi

# --- Internal helpers ---

_state_log() {
  echo "buddy-state: $*" >&2
}

# Log a warning once per process. Later calls with the same key are silent.
# Prevents stderr flooding when status line or repeated hooks hit a stable
# CORRUPT/FUTURE_VERSION state.
_state_warned_keys=""
_state_log_once() {
  local key="$1"
  shift
  case ":$_state_warned_keys:" in
    *":$key:"*) return 0 ;;
  esac
  _state_warned_keys="${_state_warned_keys}:${key}"
  _state_log "$@"
}

# Validate a session_id against path-traversal and shell-injection.
# Allowed: letters, digits, hyphen, underscore. No slashes, no dots.
# Returns 0 if valid, 1 otherwise.
_state_valid_session_id() {
  local id="$1"
  [[ -n "$id" && "$id" =~ ^[A-Za-z0-9_-]+$ ]]
}

# Ensure CLAUDE_PLUGIN_DATA is set and the directory exists.
# Outputs the data_dir on success; logs and returns 1 on failure.
# The caller's name is used in error messages so the caller can say
# `buddy_save: ...` etc.
_state_ensure_dir() {
  local caller="$1"
  local data_dir="${CLAUDE_PLUGIN_DATA:-}"
  if [[ -z "$data_dir" ]]; then
    _state_log "${caller}: CLAUDE_PLUGIN_DATA not set"
    return 1
  fi
  if ! mkdir -p "$data_dir" 2>/dev/null; then
    _state_log "${caller}: failed to create $data_dir"
    return 1
  fi
  printf '%s' "$data_dir"
}

# --- Schema migration ---

# Migrate JSON from its current schemaVersion to CURRENT_SCHEMA_VERSION.
# Reads JSON from stdin, writes migrated JSON to stdout.
# Returns 0 on success, 1 on failure (including infinite-loop protection).
# Migration happens in memory — the caller decides whether to persist.
#
# IMPORTANT for future authors: each case arm MUST bump .schemaVersion in its
# jq filter, otherwise the while loop cannot advance. The iteration cap below
# is a safety net, not a license to skip the version bump.
_state_migrate() {
  local json
  json="$(cat)"

  local version
  version="$(printf '%s' "$json" | jq -r '.schemaVersion // empty' 2>/dev/null)"

  if ! [[ "$version" =~ ^[0-9]+$ ]]; then
    _state_log "migrate: invalid or missing schemaVersion"
    return 1
  fi

  local iterations=0
  while (( version < CURRENT_SCHEMA_VERSION )); do
    if (( ++iterations > MIGRATE_MAX_ITERATIONS )); then
      _state_log "migrate: exceeded max iterations ($MIGRATE_MAX_ITERATIONS) — case arm likely forgot to bump .schemaVersion"
      return 1
    fi

    case "$version" in
      # v1 is current — no migrations needed yet.
      # Future migrations go here. Each arm MUST set .schemaVersion in its filter:
      # 1)
      #   json="$(printf '%s' "$json" | jq '.schemaVersion = 2 | .newField //= "default"')"
      #   ;;
      *)
        _state_log "migrate: unknown schema version $version"
        return 1
        ;;
    esac

    version="$(printf '%s' "$json" | jq -r '.schemaVersion' 2>/dev/null)"
    if ! [[ "$version" =~ ^[0-9]+$ ]]; then
      _state_log "migrate: case arm produced invalid schemaVersion"
      return 1
    fi
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
  local data_dir="${CLAUDE_PLUGIN_DATA:-}"
  if [[ -z "$data_dir" ]]; then
    printf '%s' "$STATE_NO_BUDDY"
    return 0
  fi

  local buddy_file="$data_dir/buddy.json"

  if [[ ! -f "$buddy_file" ]]; then
    printf '%s' "$STATE_NO_BUDDY"
    return 0
  fi

  # Parse JSON
  local json
  if ! json="$(jq '.' "$buddy_file" 2>/dev/null)"; then
    _state_log_once "corrupt:$buddy_file" "buddy_load: failed to parse $buddy_file"
    printf '%s' "$STATE_CORRUPT"
    return 0
  fi

  # Empty or null result from jq
  if [[ -z "$json" || "$json" == "null" ]]; then
    _state_log_once "corrupt:$buddy_file" "buddy_load: empty or null content in $buddy_file"
    printf '%s' "$STATE_CORRUPT"
    return 0
  fi

  # Check schemaVersion — must be a non-negative integer
  local version
  version="$(printf '%s' "$json" | jq -r '.schemaVersion // empty' 2>/dev/null)"

  if ! [[ "$version" =~ ^[0-9]+$ ]]; then
    _state_log_once "corrupt:$buddy_file" "buddy_load: invalid or missing schemaVersion in $buddy_file"
    printf '%s' "$STATE_CORRUPT"
    return 0
  fi

  # Future version check
  if (( version > CURRENT_SCHEMA_VERSION )); then
    _state_log_once "future:$buddy_file" "buddy_load: state is from a newer plugin version (v$version > v$CURRENT_SCHEMA_VERSION). Update the plugin or run /buddy:hatch to start fresh."
    printf '%s' "$STATE_FUTURE_VERSION"
    return 0
  fi

  # Migrate if needed (in memory only — not written back)
  if (( version < CURRENT_SCHEMA_VERSION )); then
    local migrated
    if migrated="$(printf '%s' "$json" | _state_migrate)"; then
      json="$migrated"
    else
      _state_log_once "corrupt:$buddy_file" "buddy_load: migration failed from v$version"
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
# .tmp files are named with PID so state_cleanup_orphans can skip files
# belonging to live processes, avoiding a race with in-flight writes.
# Returns 0 on success, 1 on failure.
buddy_save() {
  local data_dir
  data_dir="$(_state_ensure_dir "buddy_save")" || return 1

  local buddy_file="$data_dir/buddy.json"
  local lock_file="$data_dir/buddy.json.lock"

  # Read content from stdin and stamp schemaVersion
  local content
  if ! content="$(jq --argjson v "$CURRENT_SCHEMA_VERSION" '.schemaVersion = $v' 2>/dev/null)"; then
    _state_log "buddy_save: invalid JSON input"
    return 1
  fi

  # Acquire flock using exec-based fd
  local lock_fd
  if ! exec {lock_fd}>"$lock_file"; then
    _state_log "buddy_save: failed to open lock file"
    return 1
  fi

  if ! flock -x -w "$FLOCK_TIMEOUT" "$lock_fd"; then
    exec {lock_fd}>&-
    _state_log "buddy_save: flock timeout after ${FLOCK_TIMEOUT}s"
    return 1
  fi

  # Create temp file named with PID so cleanup can identify live writers.
  local tmp
  if ! tmp="$(mktemp "$data_dir/.tmp.$$.XXXXXX")"; then
    exec {lock_fd}>&-
    _state_log "buddy_save: failed to create temp file"
    return 1
  fi

  if ! printf '%s\n' "$content" > "$tmp"; then
    rm -f "$tmp"
    exec {lock_fd}>&-
    _state_log "buddy_save: failed to write temp file"
    return 1
  fi

  if ! mv -f "$tmp" "$buddy_file"; then
    rm -f "$tmp"
    exec {lock_fd}>&-
    _state_log "buddy_save: failed to rename temp to $buddy_file"
    return 1
  fi

  exec {lock_fd}>&-
  return 0
}

# --- Session state (per-sessionId) ---

# Load session state for a given session ID.
# Outputs JSON content or '{}' if the file is missing, unreadable, or corrupt.
# Always returns 0 for valid session IDs. Returns 1 with '{}' on invalid IDs.
session_load() {
  local session_id="${1:-}"
  if ! _state_valid_session_id "$session_id"; then
    _state_log "session_load: invalid session_id"
    echo '{}'
    return 1
  fi

  local data_dir="${CLAUDE_PLUGIN_DATA:-}"
  if [[ -z "$data_dir" ]]; then
    echo '{}'
    return 0
  fi

  local session_file="$data_dir/session-${session_id}.json"

  if [[ ! -f "$session_file" ]]; then
    echo '{}'
    return 0
  fi

  local json
  if json="$(jq '.' "$session_file" 2>/dev/null)" && [[ -n "$json" && "$json" != "null" ]]; then
    printf '%s' "$json"
  else
    _state_log_once "corrupt-session:$session_id" "session_load: failed to parse $session_file, returning default"
    echo '{}'
  fi
  return 0
}

# Save session state for a given session ID.
# Reads JSON content from stdin.
# Uses tmp+rename for atomic writes (prevents concurrent-writer corruption
# within the same session_id). No flock — rename atomicity is sufficient
# for the ephemeral, typically-single-writer case.
# Returns 0 on success, 1 on failure.
session_save() {
  local session_id="${1:-}"
  if ! _state_valid_session_id "$session_id"; then
    _state_log "session_save: invalid session_id"
    return 1
  fi

  local data_dir
  data_dir="$(_state_ensure_dir "session_save")" || return 1

  local session_file="$data_dir/session-${session_id}.json"

  local tmp
  if ! tmp="$(mktemp "$data_dir/.tmp.$$.XXXXXX")"; then
    _state_log "session_save: failed to create temp file"
    return 1
  fi

  if ! cat > "$tmp"; then
    rm -f "$tmp"
    _state_log "session_save: failed to write temp file"
    return 1
  fi

  if ! mv -f "$tmp" "$session_file"; then
    rm -f "$tmp"
    _state_log "session_save: failed to rename temp to $session_file"
    return 1
  fi

  return 0
}

# --- Orphan cleanup ---

# Remove stale temp files and session files older than ORPHAN_MAX_AGE_MINUTES.
# Skips .tmp files whose embedded PID is still a live process (avoids racing
# with in-flight buddy_save/session_save). Never removes buddy.json or
# buddy.json.lock.
# Called by P3-1's session-start.sh — not invoked directly by state.sh.
# Always returns 0.
state_cleanup_orphans() {
  local data_dir="${CLAUDE_PLUGIN_DATA:-}"
  if [[ -z "$data_dir" || ! -d "$data_dir" ]]; then
    return 0
  fi

  # Remove old .tmp files whose owning PID is no longer running
  local tmp_file pid
  while IFS= read -r tmp_file; do
    # Extract PID from filename: .tmp.<pid>.<suffix>
    pid="$(basename "$tmp_file" | awk -F. '{print $3}')"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      continue
    fi
    rm -f "$tmp_file"
  done < <(find "$data_dir" -maxdepth 1 -name '.tmp.*' -mmin "+$ORPHAN_MAX_AGE_MINUTES" 2>/dev/null)

  # Remove stale session files
  find "$data_dir" -maxdepth 1 -name 'session-*.json' -mmin "+$ORPHAN_MAX_AGE_MINUTES" -delete 2>/dev/null || true

  return 0
}
