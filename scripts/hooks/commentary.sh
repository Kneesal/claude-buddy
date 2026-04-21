#!/usr/bin/env bash
# commentary.sh — Buddy plugin hook-layer commentary engine.
#
# Given an event type, the current session JSON, and the buddy JSON,
# decides whether buddy emits a line and which line. The caller
# (a hook script) must invoke this INSIDE the per-session flock
# critical section so rate-limit state (cooldowns, budget counter,
# shuffle-bag) updates atomically with the dedup-ring update.
#
# Single public entry point:
#   hook_commentary_select <event_type> <session_json> <buddy_json>
#     - Emits TWO lines on stdout:
#         line 1: the commentary line to print (or empty string for no emit)
#         line 2: the updated session JSON (single-line, jq -c)
#     - Returns 0 on success; 1 only on caller-programming errors
#       (unknown event type, missing inputs). A "nothing to emit"
#       outcome is success with an empty first line — hooks must
#       exit 0 regardless.
#
# Why two stdout lines instead of a global variable: callers invoke
# this as `out="$(hook_commentary_select ...)"` which runs the function
# in a subshell. A global set inside the subshell doesn't propagate
# back to the hook. Two-line stdout dodges the subshell-scope problem
# without needing a temp file. Commentary lines never contain embedded
# newlines (stripped in _commentary_format) and session JSON is emitted
# via `jq -c`, so the split is unambiguous.
#
# Caller pattern:
#   out="$(hook_commentary_select "$event" "$session" "$buddy")"
#   line="${out%%$'\n'*}"
#   updated="${out#*$'\n'}"
#   [[ -n "$line" ]] && printf '%s\n' "$line"
#
# Rate-limit stack (three layers, checked in order, all bypassed for
# Stop per D7):
#   1. Event-novelty gate — skip if session.lastEventType == event_type.
#      lastEventType is always updated on observation (D5).
#   2. Exponential backoff per event type — cooldowns[<event>] =
#      { fires, nextAllowedAt: epoch-secs }. `fires` counts prior
#      emits for this event. After the first emit we set
#      +5min cooldown (prev_fires was 0); after the second emit and
#      beyond we set +15min (prev_fires was >=1). See D4 of the plan.
#   3. Per-session budget — commentsThisSession < BUDDY_COMMENTS_PER_SESSION
#      (default 8). Stop bypasses.
#
# Shuffle-bag (D3): commentary.bags[<event>] is an array of remaining
# line indexes. Empty → refill with shuffled(0..N-1). Head popped per
# selection. Bag resets at session start.
#
# Milestone banks (D8) — bank-selection overrides, NOT budget bypasses:
#   - PostToolUse.first_edit      (commentary.firstEditFired == false)
#   - PostToolUseFailure.error_burst (3+ failures within 5min)
#   - Stop.long_session           (startedAt > 1h ago)
#
# Fork budget (P4-1 Unit 2 fusion pass):
#   A successful PTU emit runs ~5 jq forks (down from ~17 in P3-2):
#     1 gate-read + lastEventType write  (fused)
#     1 milestone bank resolve           (may be skipped on default bank)
#     1 draw bank_len read               (pre-shuffle sizing)
#     1 fused draw                       (bag pop/slice + session write)
#     1 emit-mutations                   (cooldown + budget + firstEdit)
#   Skip paths are a single fork. See docs/solutions/best-practices/
#   bash-jq-fork-collapse-hot-path-2026-04-21.md for the pattern.
#
# Env-var hooks (for tests + power users):
#   BUDDY_COMMENTS_PER_SESSION — override the per-session cap.
#   BUDDY_STOP_LINE_ON_EXIT    — "0"/"false" disables the Stop goodbye.
#   _BUDDY_COMMENTARY_NOW      — integer epoch-seconds; mocks the clock.
#   _BUDDY_COMMENTARY_SHUFFLE  — space-separated integers; if set AND
#                                _BUDDY_COMMENTARY_TEST_MODE=1, used
#                                verbatim as the refill order instead
#                                of $RANDOM-shuffling. Length should
#                                match the bank length. The TEST_MODE
#                                gate prevents a leaked shell-dotfile
#                                export from turning production
#                                deterministic.
#   BUDDY_SPECIES_DIR          — already honored by rng.sh; same convention
#                                here for species JSON lookup.

if [[ "${_BUDDY_COMMENTARY_LOADED:-}" != "1" ]]; then
  _BUDDY_COMMENTARY_LOADED=1

  # Cooldown cadence in seconds. First fire: immediate. Second: +5min.
  # Third and beyond: flat +15min.
  readonly _COMMENTARY_COOLDOWN_FIRST=300
  readonly _COMMENTARY_COOLDOWN_LATER=900

  # Error-burst milestone window. 3+ failures within 5 minutes trigger
  # the error_burst bank (if present and non-empty).
  readonly _COMMENTARY_BURST_WINDOW_SECS=300
  readonly _COMMENTARY_BURST_THRESHOLD=3

  # Hard cap on recentFailures length. Time-window pruning is the
  # primary bound, but a tight retry loop could enqueue thousands
  # before the prune condition kicks in. Session JSON inflates,
  # jq work scales, flock-held time creeps toward the 0.2s timeout.
  # 20 is comfortably above the BURST_THRESHOLD (3) yet keeps the
  # blob small.
  readonly _COMMENTARY_RECENT_FAILURES_MAX=20

  # Long-session milestone threshold. startedAt > 1h ago picks the
  # Stop.long_session bank.
  readonly _COMMENTARY_LONG_SESSION_SECS=3600

  # Default budget cap when BUDDY_COMMENTS_PER_SESSION is unset or
  # invalid. Matches plugin.json userConfig.commentsPerSession.default.
  readonly _COMMENTARY_DEFAULT_BUDGET=8
fi

# Internal (per-call) — the line the current invocation decided to
# emit, or empty string. Handlers write here; hook_commentary_select
# formats the final two-line stdout from this plus the updated JSON.
# Reset to "" at the top of every public call.
_BUDDY_COMMENT_LINE=""

# Internal (per-call) — updated session JSON accumulated by handlers.
# Works around the subshell-scope problem: callers invoke
# hook_commentary_select via command substitution, which forks a
# subshell. Handlers that use `printf '%s' "$json"` inside that
# subshell would compete with the final two-line emit. Handlers now
# write to this global and hook_commentary_select emits both at the
# very end. All writes happen within the command-substitution subshell,
# so the global is confined to that one invocation.
_BUDDY_SESSION_UPDATED=""

# --- Internal helpers ---

# Current epoch-seconds. _BUDDY_COMMENTARY_NOW overrides for tests so
# cooldown and burst-window logic is deterministic.
_commentary_now_epoch() {
  if [[ -n "${_BUDDY_COMMENTARY_NOW:-}" && "${_BUDDY_COMMENTARY_NOW}" =~ ^[0-9]+$ ]]; then
    printf '%s' "$_BUDDY_COMMENTARY_NOW"
    return 0
  fi
  date +%s 2>/dev/null || printf '0'
}

# Resolve the species directory. Matches rng.sh's convention —
# BUDDY_SPECIES_DIR override first, else walk from this file's location
# up to scripts/species/.
_commentary_species_dir() {
  if [[ -n "${BUDDY_SPECIES_DIR:-}" ]]; then
    printf '%s' "$BUDDY_SPECIES_DIR"
    return 0
  fi
  local hooks_dir
  hooks_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  # hooks_dir is scripts/hooks; walk up to scripts/, then into species/.
  printf '%s/../species' "$hooks_dir"
}

# Budget cap for this session. Falls back to default on invalid
# input. plugin.json declares commentsPerSession as `type: number`
# so Claude Code may pass a float (8.5) through the env. We require
# a non-negative integer and log at most once per process on any
# other value so the user can see their knob was ignored.
_commentary_budget_cap() {
  local raw="${BUDDY_COMMENTS_PER_SESSION:-}"
  if [[ -z "$raw" ]]; then
    printf '%d' "$_COMMENTARY_DEFAULT_BUDGET"
    return 0
  fi
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    printf '%d' "$raw"
    return 0
  fi
  # Log once, via the hook logging facility if available. Silent in
  # test contexts that source commentary.sh without common.sh.
  if declare -F hook_log_error >/dev/null 2>&1 \
       && [[ -z "${_BUDDY_BUDGET_CAP_WARNED:-}" ]]; then
    hook_log_error "commentary" "ignoring non-integer BUDDY_COMMENTS_PER_SESSION=$raw; using default $_COMMENTARY_DEFAULT_BUDGET"
    _BUDDY_BUDGET_CAP_WARNED=1
  fi
  printf '%d' "$_COMMENTARY_DEFAULT_BUDGET"
}

# True if the Stop goodbye is enabled. Deny-list: only explicit
# falsy values (0, false, no — any case) disable. Everything else
# (including unset, empty, "1", "true", "True", "on", "yes", and
# platform-serialization variants with surrounding whitespace) is
# treated as enabled. Matches the manifest default of true and
# tolerates Claude Code's boolean-serialization drift.
_commentary_stop_enabled() {
  local raw="${BUDDY_STOP_LINE_ON_EXIT:-}"
  # Trim surrounding whitespace so " true " etc. match.
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  case "$raw" in
    "0" | "false" | "False" | "FALSE" | "no" | "No" | "NO") return 1 ;;
    *) return 0 ;;
  esac
}

# Emit a shuffled integer sequence 0..(N-1) as space-separated ints.
# _BUDDY_COMMENTARY_SHUFFLE overrides for tests (must match N) but
# only when _BUDDY_COMMENTARY_TEST_MODE=1 — a leaked shell export of
# the shuffle var alone is ignored in production.
_commentary_shuffle_seq() {
  local n="$1"
  if [[ "${_BUDDY_COMMENTARY_TEST_MODE:-}" == "1" \
        && -n "${_BUDDY_COMMENTARY_SHUFFLE:-}" ]]; then
    # Test override: emit verbatim. Caller is responsible for length
    # matching; mismatch will surface as an out-of-range index at draw
    # time, which is the behavior we want in tests.
    printf '%s' "$_BUDDY_COMMENTARY_SHUFFLE"
    return 0
  fi
  if (( n <= 0 )); then
    return 0
  fi
  # Fisher-Yates using $RANDOM. Small bag (N ≤ ~60) — this is cheap.
  local -a arr=()
  local i
  for (( i=0; i < n; i++ )); do
    arr[i]=$i
  done
  local j tmp
  for (( i = n - 1; i > 0; i-- )); do
    j=$(( RANDOM % (i + 1) ))
    tmp=${arr[i]}
    arr[i]=${arr[j]}
    arr[j]=$tmp
  done
  printf '%s' "${arr[*]}"
}

# Given a species JSON, event type, and bank name, emit the bank
# array on stdout (as JSON). Empty array `[]` if the bank doesn't
# exist or isn't an array of strings. Callers treat `[]` as "skip".
_commentary_resolve_bank() {
  local species_json="$1"
  local event_type="$2"
  local bank_name="$3"
  printf '%s' "$species_json" | jq -c --arg e "$event_type" --arg b "$bank_name" '
    (.line_banks[$e][$b] // [])
    | if type == "array" then map(select(type == "string")) else [] end
  ' 2>/dev/null
}

# --- Public API ---

# Main entry. Reads event_type + session_json + buddy_json, writes
# updated session_json to stdout, sets _BUDDY_COMMENT_LINE.
#
# Caller contract: invoke INSIDE the per-session flock, BEFORE the
# session_save. The return value of the whole pipeline is the updated
# session JSON that the caller persists.
hook_commentary_select() {
  _BUDDY_COMMENT_LINE=""
  _BUDDY_SESSION_UPDATED=""

  local event_type="${1:-}"
  local session_json="${2:-}"
  local buddy_json="${3:-}"

  # Pass-through fallback used on every early-exit path. Emits a
  # blank comment line + the session JSON (compacted via jq -c so
  # the newline split is unambiguous).
  #
  # If jq -c fails (signal, OOM, invalid input), we suppress the emit
  # entirely and return an empty comment + empty session. The caller's
  # defensive `if [[ -z "$final_session" ]]; then final_session="$ring_updated"`
  # keeps the ring update but drops the commentary decision — that is
  # safer than emitting pretty-printed multi-line JSON that would
  # poison the caller's two-line split and corrupt session state.
  _commentary_emit() {
    local compact
    compact="$(printf '%s' "$_BUDDY_SESSION_UPDATED" | jq -c '.' 2>/dev/null)"
    if [[ -z "$compact" ]]; then
      # jq failed or input is malformed — bail safely. The comment is
      # already set (possibly to a good value for this call) but we
      # clear it so the caller doesn't emit a line unbacked by a saved
      # session. Two empty lines is a valid "nothing happened" reply.
      printf '\n'
      return
    fi
    printf '%s\n%s' "$_BUDDY_COMMENT_LINE" "$compact"
  }

  if [[ -z "$event_type" || -z "$session_json" || -z "$buddy_json" ]]; then
    # Programming error — emit session unchanged so caller's save
    # isn't corrupted.
    _BUDDY_SESSION_UPDATED="${session_json:-{\}}"
    _commentary_emit
    return 1
  fi

  _BUDDY_SESSION_UPDATED="$session_json"

  case "$event_type" in
    PostToolUse|PostToolUseFailure|Stop) ;;
    *)
      # Unknown event — pass-through. Hook layer never crashes.
      _commentary_emit
      return 0
      ;;
  esac

  local now
  now="$(_commentary_now_epoch)"

  local species name emoji
  species="$(printf '%s' "$buddy_json" | jq -r '.buddy.species // empty' 2>/dev/null)"
  name="$(printf '%s' "$buddy_json" | jq -r '.buddy.name // empty' 2>/dev/null)"
  if [[ -z "$species" || -z "$name" ]]; then
    _commentary_emit
    return 0
  fi

  # Strict species-name check (path-traversal defense — same rule as
  # _rng_valid_species_name in rng.sh).
  if ! [[ "$species" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
    _commentary_emit
    return 0
  fi

  local species_dir species_file
  species_dir="$(_commentary_species_dir)" || {
    _commentary_emit
    return 0
  }
  species_file="$species_dir/${species}.json"
  if [[ ! -f "$species_file" ]]; then
    _commentary_emit
    return 0
  fi

  local species_json
  if ! species_json="$(jq -c '.' "$species_file" 2>/dev/null)" || [[ -z "$species_json" ]]; then
    _commentary_emit
    return 0
  fi
  emoji="$(printf '%s' "$species_json" | jq -r '.emoji // ""' 2>/dev/null)"

  case "$event_type" in
    PostToolUse)        _commentary_handle_ptu  "$species_json" "$name" "$emoji" "$now" ;;
    PostToolUseFailure) _commentary_handle_ptuf "$species_json" "$name" "$emoji" "$now" ;;
    Stop)               _commentary_handle_stop "$species_json" "$name" "$emoji" "$now" ;;
  esac

  _commentary_emit
  return 0
}

# --- Fused gate-read + mutation helpers (P4-1 Unit 2) ---
#
# The P3-2 handlers did 15+ jq forks per successful emit: one jq per
# gate read, one per mutation, multiple inside the draw. That put PTU
# p95 at ~85ms against a 100ms budget with no headroom for P4-1's
# signals work. The fork-collapse solutions doc
# (docs/solutions/best-practices/bash-jq-fork-collapse-hot-path-
# 2026-04-21.md) is the authoritative pattern; this block is its
# P4-1 application. Observable behaviour is unchanged — the P3-2
# test_commentary.bats suite must run green.

# Fused PTU gate-read. Returns a 6-line stdout payload:
#   line 1: cooldown_ok  (1 / 0)
#   line 2: budget_ok    (1 / 0)
#   line 3: first_fired  (true / false)
#   line 4: prev_fires   (integer)
#   line 5: prev_event   (string; empty if unset)
#   line 6: session with lastEventType set to $e (compact JSON)
#
# Newline-separated (rather than @tsv) because jq compact JSON never
# contains literal newlines — the split is unambiguous — while @tsv
# escapes tabs inside the serialized payload and would corrupt the
# JSON readback.
#
# lastEventType is written unconditionally so skip paths can persist
# the update from a single jq fork without a second pass. D5.
_commentary_ptu_gates_read() {
  local session_json="$1"
  local event_type="$2"
  local now="$3"
  local cap="$4"
  printf '%s' "$session_json" | jq -r \
    --arg e "$event_type" \
    --argjson now "$now" \
    --argjson cap "$cap" '
    . as $s |
    (.lastEventType = $e) as $updated |
    ((($s.cooldowns[$e].nextAllowedAt // 0) | tonumber? // 0) as $n
      | if $now >= $n then "1" else "0" end) as $cd_ok |
    ((($s.commentsThisSession // 0) | tonumber? // 0) as $c
      | if $c < $cap then "1" else "0" end) as $bud_ok |
    (($s.commentary.firstEditFired // false) | tostring) as $fired |
    (($s.cooldowns[$e].fires // 0) | tonumber? // 0 | tostring) as $pf |
    ($s.lastEventType // "") as $pe |
    "\($cd_ok)\n\($bud_ok)\n\($fired)\n\($pf)\n\($pe)\n\($updated | tojson)"
  ' 2>/dev/null
}

# Fused PTUF gate-read. Extends the PTU variant with recentFailures
# append+trim and returns the post-append failure count so the
# error_burst milestone check runs in bash without an extra fork.
# 7-line stdout:
#   line 1: cooldown_ok
#   line 2: budget_ok
#   line 3: first_fired     (unused by PTUF; kept for shape symmetry)
#   line 4: prev_fires
#   line 5: prev_event
#   line 6: session with lastEventType = $e AND recentFailures updated
#   line 7: failure_count   (post-append integer)
_commentary_ptuf_gates_read() {
  local session_json="$1"
  local event_type="$2"
  local now="$3"
  local cap="$4"
  printf '%s' "$session_json" | jq -r \
    --arg e "$event_type" \
    --argjson now "$now" \
    --argjson cap "$cap" \
    --argjson window "$_COMMENTARY_BURST_WINDOW_SECS" \
    --argjson fcap "$_COMMENTARY_RECENT_FAILURES_MAX" '
    . as $s |
    ($s | .recentFailures = (
       ((.recentFailures // []) + [$now])
       | map(select(type == "number" and . > ($now - $window)))
       | .[-($fcap):]
     )) as $after_failures |
    ($after_failures | .lastEventType = $e) as $updated |
    ((($s.cooldowns[$e].nextAllowedAt // 0) | tonumber? // 0) as $n
      | if $now >= $n then "1" else "0" end) as $cd_ok |
    ((($s.commentsThisSession // 0) | tonumber? // 0) as $c
      | if $c < $cap then "1" else "0" end) as $bud_ok |
    (($s.commentary.firstEditFired // false) | tostring) as $fired |
    (($s.cooldowns[$e].fires // 0) | tonumber? // 0 | tostring) as $pf |
    ($s.lastEventType // "") as $pe |
    ($updated.recentFailures | length | tostring) as $fc |
    "\($cd_ok)\n\($bud_ok)\n\($fired)\n\($pf)\n\($pe)\n\($updated | tojson)\n\($fc)"
  ' 2>/dev/null
}

# Fused post-draw mutation: lastEventType = e, cooldowns[$e] bump,
# commentsThisSession++, optional firstEditFired = true. ONE jq fork.
# Caller has already bumped the bag (via _commentary_draw); this
# runs on the session emitted by that draw.
_commentary_apply_emit_mutations() {
  local session_json="$1"
  local event_type="$2"
  local now="$3"
  local prev_fires="$4"
  local set_first_fired="$5"  # "true" or "false"

  # Cooldown cadence is pre-computed in bash so the fused jq doesn't
  # need to branch: first fire → +5min, subsequent → +15min (D4 from
  # the P3-2 plan).
  local cadence
  if (( prev_fires == 0 )); then
    cadence=$_COMMENTARY_COOLDOWN_FIRST
  else
    cadence=$_COMMENTARY_COOLDOWN_LATER
  fi
  local next=$(( now + cadence ))
  local new_fires=$(( prev_fires + 1 ))
  printf '%s' "$session_json" | jq -c \
    --arg e "$event_type" \
    --argjson fires "$new_fires" \
    --argjson next "$next" \
    --argjson setFirst "$set_first_fired" '
    .lastEventType = $e
    | .cooldowns[$e] = { fires: $fires, nextAllowedAt: $next }
    | .commentsThisSession = ((.commentsThisSession // 0) + 1)
    | (if $setFirst then .commentary.firstEditFired = true else . end)
  ' 2>/dev/null
}

# --- Per-event handlers ---
#
# Handlers read/write _BUDDY_SESSION_UPDATED and may set
# _BUDDY_COMMENT_LINE. They do NOT write to stdout. hook_commentary_select
# does the final two-line emit. Fork budget per successful emit is
# ~5 jq forks (see file-top comment).

_commentary_handle_ptu() {
  local species_json="$1"
  local name="$2"
  local emoji="$3"
  local now="$4"
  local event_type="PostToolUse"

  local session_json="$_BUDDY_SESSION_UPDATED"
  local cap
  cap="$(_commentary_budget_cap)"

  local gates_out
  gates_out="$(_commentary_ptu_gates_read "$session_json" "$event_type" "$now" "$cap")"
  if [[ -z "$gates_out" ]]; then
    return
  fi

  local cd_ok bud_ok fired prev_fires prev_event session_with_last
  {
    IFS= read -r cd_ok
    IFS= read -r bud_ok
    IFS= read -r fired
    IFS= read -r prev_fires
    IFS= read -r prev_event
    IFS= read -r session_with_last
  } <<< "$gates_out"

  # Persist the lastEventType update on every outcome (D5 — always
  # update on observation, regardless of emit decision).
  [[ -n "$session_with_last" ]] && _BUDDY_SESSION_UPDATED="$session_with_last"

  # Novelty gate: previous observed event was also PostToolUse.
  [[ "$prev_event" == "$event_type" ]] && return
  [[ "$cd_ok" != "1" ]] && return
  [[ "$bud_ok" != "1" ]] && return

  # Milestone bank selection — first_edit bank?
  local bank_name="default"
  if [[ "$fired" == "false" ]]; then
    local milestone
    milestone="$(_commentary_resolve_bank "$species_json" "$event_type" "first_edit")"
    if [[ -n "$milestone" && "$milestone" != "[]" ]]; then
      bank_name="first_edit"
    fi
  fi

  local line_and_session
  line_and_session="$(_commentary_draw "$session_with_last" "$species_json" "$event_type" "$bank_name")"
  [[ -z "$line_and_session" ]] && return

  local line post_draw
  line="${line_and_session%%$'\t'*}"
  post_draw="${line_and_session#*$'\t'}"

  local set_first="false"
  [[ "$bank_name" == "first_edit" ]] && set_first="true"

  local updated
  updated="$(_commentary_apply_emit_mutations "$post_draw" "$event_type" "$now" "$prev_fires" "$set_first")"
  [[ -z "$updated" ]] && return

  _BUDDY_COMMENT_LINE="$(_commentary_format "$emoji" "$name" "$line")"
  _BUDDY_SESSION_UPDATED="$updated"
}

_commentary_handle_ptuf() {
  local species_json="$1"
  local name="$2"
  local emoji="$3"
  local now="$4"
  local event_type="PostToolUseFailure"

  local session_json="$_BUDDY_SESSION_UPDATED"
  local cap
  cap="$(_commentary_budget_cap)"

  local gates_out
  gates_out="$(_commentary_ptuf_gates_read "$session_json" "$event_type" "$now" "$cap")"
  if [[ -z "$gates_out" ]]; then
    return
  fi

  local cd_ok bud_ok fired prev_fires prev_event session_with_last failure_count
  {
    IFS= read -r cd_ok
    IFS= read -r bud_ok
    IFS= read -r fired
    IFS= read -r prev_fires
    IFS= read -r prev_event
    IFS= read -r session_with_last
    IFS= read -r failure_count
  } <<< "$gates_out"

  # recentFailures was trimmed + appended AND lastEventType was set in
  # the gates jq — persist on every outcome so burst-density tracking
  # and D5 both hold on skip paths.
  [[ -n "$session_with_last" ]] && _BUDDY_SESSION_UPDATED="$session_with_last"

  [[ "$prev_event" == "$event_type" ]] && return
  [[ "$cd_ok" != "1" ]] && return
  [[ "$bud_ok" != "1" ]] && return

  # Milestone: error_burst if 3+ failures inside the 5-min window.
  local bank_name="default"
  if [[ "$failure_count" =~ ^[0-9]+$ ]] && (( failure_count >= _COMMENTARY_BURST_THRESHOLD )); then
    local milestone
    milestone="$(_commentary_resolve_bank "$species_json" "$event_type" "error_burst")"
    if [[ -n "$milestone" && "$milestone" != "[]" ]]; then
      bank_name="error_burst"
    fi
  fi

  local line_and_session
  line_and_session="$(_commentary_draw "$session_with_last" "$species_json" "$event_type" "$bank_name")"
  [[ -z "$line_and_session" ]] && return

  local line post_draw
  line="${line_and_session%%$'\t'*}"
  post_draw="${line_and_session#*$'\t'}"

  local updated
  updated="$(_commentary_apply_emit_mutations "$post_draw" "$event_type" "$now" "$prev_fires" "false")"
  [[ -z "$updated" ]] && return

  _BUDDY_COMMENT_LINE="$(_commentary_format "$emoji" "$name" "$line")"
  _BUDDY_SESSION_UPDATED="$updated"
}

_commentary_handle_stop() {
  local species_json="$1"
  local name="$2"
  local emoji="$3"
  local now="$4"
  local event_type="Stop"

  local session_json="$_BUDDY_SESSION_UPDATED"

  _commentary_stop_enabled || return

  local bank_name="default"
  local started_at_epoch
  started_at_epoch="$(printf '%s' "$session_json" \
    | jq -r '.startedAt // ""' 2>/dev/null \
    | _commentary_iso_to_epoch)"
  if [[ "$started_at_epoch" =~ ^[0-9]+$ ]] \
       && (( now - started_at_epoch >= _COMMENTARY_LONG_SESSION_SECS )); then
    local milestone
    milestone="$(_commentary_resolve_bank "$species_json" "$event_type" "long_session")"
    if [[ -n "$milestone" && "$milestone" != "[]" ]]; then
      bank_name="long_session"
    fi
  fi

  local line_and_session
  line_and_session="$(_commentary_draw "$session_json" "$species_json" "$event_type" "$bank_name")"
  [[ -z "$line_and_session" ]] && return

  local line post_draw
  line="${line_and_session%%$'\t'*}"
  post_draw="${line_and_session#*$'\t'}"

  # Stop bumps commentsThisSession for telemetry (D7) but doesn't touch
  # cooldowns or lastEventType. Fold the bump into a single jq on the
  # post-draw session rather than reusing _commentary_apply_emit_mutations
  # (which would also bump cooldown + lastEventType — not wanted here).
  local updated
  updated="$(printf '%s' "$post_draw" | jq -c '
    .commentsThisSession = ((.commentsThisSession // 0) + 1)
  ' 2>/dev/null)"
  [[ -z "$updated" ]] && return

  _BUDDY_COMMENT_LINE="$(_commentary_format "$emoji" "$name" "$line")"
  _BUDDY_SESSION_UPDATED="$updated"
}

# --- Shuffle-bag draw (fused, P4-1 Unit 2) ---

# Draw one line from commentary.bags[<event>.<bank>]. Refills+reshuffles
# when the bag is empty. Output format: "<line>\t<updated_session_json>"
# on stdout, or empty stdout on skip (empty bank, JSON error, out-of-range
# index).
#
# Fork count: 2 jqs (bank_len read + fused draw). P3-2 did 8.
#
# The refill shuffle is computed in bash via _commentary_shuffle_seq and
# handed to the fused jq as --argjson. Always computed — bash-level
# Fisher-Yates on an N ≤ ~60 array is microseconds, and paying it
# unconditionally lets the fused jq make one pass without a branch for
# "is refill needed".
#
# NOTE: a line containing a literal TAB or newline would break the
# caller's tab split. The fused jq substitutes both for spaces before
# assembling the output; tests/species_line_banks.bats also rejects
# such content up-front.
_commentary_draw() {
  local session_json="$1"
  local species_json="$2"
  local event_type="$3"
  local bank_name="$4"

  # Bank length — one jq fork. Used to size the bash-level shuffle.
  local bank_len
  bank_len="$(printf '%s' "$species_json" | jq -r --arg e "$event_type" --arg b "$bank_name" '
    (.line_banks[$e][$b] // [])
    | if type == "array" then (map(select(type == "string")) | length) else 0 end
  ' 2>/dev/null)"
  if ! [[ "$bank_len" =~ ^[0-9]+$ ]] || (( bank_len == 0 )); then
    return 0
  fi

  local shuffled_ints
  shuffled_ints="$(_commentary_shuffle_seq "$bank_len")"
  # Build JSON array literal from the space-separated ints WITHOUT a
  # jq fork. _commentary_shuffle_seq emits validated non-negative
  # integers so bracket/comma substitution is safe.
  local shuffled_json
  if [[ -n "$shuffled_ints" ]]; then
    shuffled_json="[${shuffled_ints// /,}]"
  else
    shuffled_json='[]'
  fi

  # Fused: bank strings, bag substitution, head-pop, slice, write.
  printf '%s' "$session_json" | jq -r \
    --argjson species "$species_json" \
    --arg e "$event_type" \
    --arg b "$bank_name" \
    --argjson shuffled "$shuffled_json" '
    . as $session |
    ($species.line_banks[$e][$b] // []) as $raw |
    (if ($raw | type) == "array"
       then ($raw | map(select(type == "string")))
       else []
     end) as $bank |
    ($bank | length) as $n |
    ($e + "." + $b) as $k |
    (.commentary.bags[$k] // []) as $cur |
    (if ($cur | type) == "array" and ($cur | length) > 0
       then $cur
       else $shuffled
     end) as $bag |
    if $n == 0 or ($bag | length) == 0 then empty
    else
      ($bag[0]) as $idx |
      (if ($idx | type) == "number" and $idx >= 0 and $idx < $n
         then $bank[$idx]
         else null
       end) as $line |
      if $line == null or ($line | type) != "string" or $line == "" then empty
      else
        # Sanitize tabs + newlines so the caller can split on the first \t.
        ($line | gsub("\t"; " ") | gsub("\n"; " ") | gsub("\r"; " ")) as $safe |
        ($session | .commentary.bags[$k] = $bag[1:]) as $new |
        ($safe + "\t" + ($new | tojson))
      end
    end
  ' 2>/dev/null
}

# --- Formatting ---

_commentary_format() {
  local emoji="$1"
  local name="$2"
  local line="$3"
  # Strip control bytes before emitting to the transcript. Species line
  # content and buddy.name are author-controlled; a crafted entry with
  # ANSI/CSI escapes (\x1b), backspace (\x08), or other control bytes
  # could hijack the transcript surface or downstream agent automation
  # that keys off commentary text. tr -d '[:cntrl:]' removes the
  # \x00-\x1f and \x7f class. \t is also in [:cntrl:] so this is
  # strictly tighter than the prior \n/\r-only strip.
  name="$(printf '%s' "$name" | tr -d '[:cntrl:]')"
  line="$(printf '%s' "$line" | tr -d '[:cntrl:]')"
  if [[ -n "$emoji" ]]; then
    printf '%s %s: "%s"' "$emoji" "$name" "$line"
  else
    printf '%s: "%s"' "$name" "$line"
  fi
}

# Read an ISO-8601 UTC timestamp from stdin and emit its epoch-seconds
# representation on stdout. Empty output on parse failure.
_commentary_iso_to_epoch() {
  local ts
  ts="$(cat)"
  [[ -z "$ts" ]] && return 0
  # GNU date handles ISO-8601 via -d; BSD date needs -j -f. Try both.
  local epoch
  epoch="$(date -u -d "$ts" +%s 2>/dev/null)"
  if [[ -z "$epoch" ]]; then
    epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null)"
  fi
  [[ "$epoch" =~ ^[0-9]+$ ]] && printf '%s' "$epoch"
}
