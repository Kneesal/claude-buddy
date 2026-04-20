#!/usr/bin/env bash
# reset.sh — Buddy plugin reset command
# Dispatch target for /buddy:reset. Destructive: wipes buddy.json.
#
# Confirmation is flag-based (--confirm) because SKILL.md cannot reliably
# prompt mid-execution (see origin plan D5).
#
# Atomic delete dance (ticket task + origin plan):
#   1. Acquire flock on buddy.json.lock (same persistent sibling state.sh
#      uses — never deleted, never renamed).
#   2. If buddy.json exists, mv -f buddy.json buddy.json.deleted (atomic rename
#      on POSIX). After this, buddy_load sees NO_BUDDY.
#   3. rm -f buddy.json.deleted.
#   4. Release flock.
#
# If the process dies between step 2 and step 3, buddy_load still reports
# NO_BUDDY (correct) and the orphan .deleted file is swept by
# state_cleanup_orphans on next session start.
#
# DOES NOT call buddy_load before deleting — buddy.json may be CORRUPT and
# we still want to wipe it cleanly without parsing.
#
# Exit conventions:
#   0 — user-visible outcome handled cleanly (includes missing --confirm).
#   1 — internal error (flock timeout, symlinked lock, rename failure).

_RESET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/state.sh
source "$_RESET_DIR/lib/state.sh" || exit 1

_reset_do_wipe() {
  local data_dir="${CLAUDE_PLUGIN_DATA:-}"
  if [[ -z "$data_dir" ]]; then
    echo "buddy-reset: CLAUDE_PLUGIN_DATA not set" >&2
    return 1
  fi
  # If the data dir doesn't exist at all, there's nothing to wipe. Use a
  # distinct no-op message so callers (agents and audit logs) can tell a
  # no-op from an actual destructive wipe just from stdout.
  if [[ ! -d "$data_dir" ]]; then
    echo "No buddy to reset. Run /buddy:hatch to hatch one."
    return 0
  fi

  local buddy_file="$data_dir/buddy.json"
  local deleted_file="$data_dir/buddy.json.deleted"
  local lock_file="$data_dir/buddy.json.lock"

  # Refuse symlinked lock file — same guard as buddy_save. Opening a regular-
  # file symlink with exec {fd}> would truncate the target; a FIFO symlink
  # would hang past flock's timeout.
  if [[ -L "$lock_file" ]]; then
    echo "buddy-reset: refusing to open symlinked lock file $lock_file" >&2
    return 1
  fi

  local lock_fd
  if ! exec {lock_fd}>"$lock_file"; then
    echo "buddy-reset: failed to open lock file" >&2
    return 1
  fi

  if ! flock -x -w "$FLOCK_TIMEOUT" "$lock_fd"; then
    exec {lock_fd}>&-
    echo "buddy-reset: could not acquire lock within ${FLOCK_TIMEOUT}s — another buddy operation may be in flight. Try /buddy:reset --confirm again in a moment." >&2
    return 1
  fi

  local wiped=0
  if [[ -f "$buddy_file" ]]; then
    if ! mv -f "$buddy_file" "$deleted_file"; then
      exec {lock_fd}>&-
      echo "buddy-reset: failed to rename buddy.json to .deleted" >&2
      return 1
    fi
    # Best-effort unlink. If this fails (extremely unlikely on a local FS),
    # the next state_cleanup_orphans pass will clear it. buddy.json is
    # already gone from buddy_load's perspective.
    rm -f "$deleted_file"
    wiped=1
  fi

  exec {lock_fd}>&-
  if (( wiped )); then
    echo "Buddy reset. Run /buddy:hatch to start over."
  else
    echo "No buddy to reset. Run /buddy:hatch to hatch one."
  fi
  return 0
}

_reset_main() {
  local confirm=0
  if (( $# > 1 )); then
    echo "Usage: reset.sh [--confirm]" >&2
    return 1
  fi
  if (( $# == 1 )); then
    case "$1" in
      --confirm) confirm=1 ;;
      *)
        echo "Usage: reset.sh [--confirm]" >&2
        return 1
        ;;
    esac
  fi

  if (( confirm == 0 )); then
    echo "All buddy data will be lost. Run /buddy:reset --confirm to continue."
    return 0
  fi

  _reset_do_wipe
}

_reset_main "$@"
