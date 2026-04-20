#!/usr/bin/env bash
# perf_hook_p95.sh — assert p95 wall-clock < 100ms for each hook across
# 100 invocations. Exits 0 if every hook passes, non-zero with a printed
# distribution otherwise.
#
# Run from repo root:
#   ./tests/hooks/perf_hook_p95.sh
#
# Requires: bash 4.1+, jq, bc, /usr/bin/env. Timings come from bash's
# builtin EPOCHREALTIME (bash 5+) or a date-fallback for older shells.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ -z "${BASH_VERSINFO[0]:-}" ]] || (( BASH_VERSINFO[0] < 5 )); then
  echo "perf harness: needs bash 5+ for EPOCHREALTIME (got $BASH_VERSION)" >&2
  exit 2
fi

ITERATIONS="${PERF_ITERATIONS:-100}"
P95_MAX_MS="${PERF_P95_MAX_MS:-100}"

TMPDIR_HARNESS="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_HARNESS"' EXIT

export CLAUDE_PLUGIN_DATA="$TMPDIR_HARNESS/data"
mkdir -p "$CLAUDE_PLUGIN_DATA"

# Seed an ACTIVE buddy — hooks short-circuit on NO_BUDDY, which would
# make the numbers meaningless. Use the hatch script with a fixed seed.
BUDDY_RNG_SEED=42 bash "$REPO_ROOT/scripts/hatch.sh" >/dev/null

_time_one() {
  local script="$1"
  local payload="$2"
  local t0 t1
  t0="$EPOCHREALTIME"
  printf '%s' "$payload" | "$script" >/dev/null 2>&1 || true
  t1="$EPOCHREALTIME"
  # Convert the "sec.microsec" strings into integer ms.
  # EPOCHREALTIME is locale-agnostic "<sec>.<usec>"; avoid bc for speed.
  local sec_diff usec_diff
  sec_diff=$((${t1%.*} - ${t0%.*}))
  usec_diff=$((10#${t1#*.} - 10#${t0#*.}))
  echo $(( sec_diff * 1000 + usec_diff / 1000 ))
}

_p95() {
  # Sort ascending, pick index ceil(0.95 * N) - 1 (0-indexed).
  local n="$1"
  shift
  local idx
  idx=$(( (n * 95 + 99) / 100 - 1 ))
  (( idx < 0 )) && idx=0
  printf '%s\n' "$@" | sort -n | awk -v i=$((idx+1)) 'NR==i{print;exit}'
}

_bench() {
  local label="$1"
  local script="$2"
  local payload="$3"
  local -a times=()
  local i ms
  for (( i=0; i<ITERATIONS; i++ )); do
    ms="$(_time_one "$script" "$payload")"
    times+=("$ms")
  done
  local p95
  p95="$(_p95 "$ITERATIONS" "${times[@]}")"
  local max min
  max="$(printf '%s\n' "${times[@]}" | sort -n | tail -1)"
  min="$(printf '%s\n' "${times[@]}" | sort -n | head -1)"
  local verdict
  if (( p95 <= P95_MAX_MS )); then
    verdict="OK"
  else
    verdict="FAIL"
  fi
  printf "%-28s  n=%d  min=%3dms  p95=%3dms  max=%3dms  [%s]\n" \
    "$label" "$ITERATIONS" "$min" "$p95" "$max" "$verdict"
  (( p95 <= P95_MAX_MS ))
}

_payload_session_start() {
  local sid="sess-$1"
  jq -n --arg s "$sid" '{hook_event_name:"SessionStart", session_id:$s}'
}
_payload_tool() {
  local sid="sess-$1" tcid="tu_$1"
  jq -n --arg s "$sid" --arg t "$tcid" \
    '{hook_event_name:"PostToolUse", session_id:$s, tool_use_id:$t}'
}
_payload_stop() {
  local sid="sess-$1"
  jq -n --arg s "$sid" '{hook_event_name:"Stop", session_id:$s}'
}

# Vary the sid/tcid per invocation so the dedup ring doesn't short-circuit
# every tool-event call after the first. We pre-generate payloads once so
# jq-forking isn't part of the measured span.
declare -a SS_PAYLOADS=() TOOL_PAYLOADS=() STOP_PAYLOADS=()
for (( i=0; i<ITERATIONS; i++ )); do
  SS_PAYLOADS+=("$(_payload_session_start "$i")")
  TOOL_PAYLOADS+=("$(_payload_tool "$i")")
  STOP_PAYLOADS+=("$(_payload_stop "$i")")
done

_bench_varying() {
  local label="$1" script="$2"
  local payloads_ref="$3"
  local -n _payloads="$payloads_ref"
  local -a times=()
  local i ms
  for (( i=0; i<ITERATIONS; i++ )); do
    ms="$(_time_one "$script" "${_payloads[$i]}")"
    times+=("$ms")
  done
  local p95 max min
  p95="$(_p95 "$ITERATIONS" "${times[@]}")"
  max="$(printf '%s\n' "${times[@]}" | sort -n | tail -1)"
  min="$(printf '%s\n' "${times[@]}" | sort -n | head -1)"
  local verdict
  if (( p95 <= P95_MAX_MS )); then verdict="OK"; else verdict="FAIL"; fi
  printf "%-28s  n=%d  min=%3dms  p95=%3dms  max=%3dms  [%s]\n" \
    "$label" "$ITERATIONS" "$min" "$p95" "$max" "$verdict"
  (( p95 <= P95_MAX_MS ))
}

all_ok=0
_bench_varying "session-start.sh"         "$REPO_ROOT/hooks/session-start.sh"        SS_PAYLOADS   || all_ok=1
_bench_varying "post-tool-use.sh"         "$REPO_ROOT/hooks/post-tool-use.sh"        TOOL_PAYLOADS || all_ok=1
_bench_varying "post-tool-use-failure.sh" "$REPO_ROOT/hooks/post-tool-use-failure.sh" TOOL_PAYLOADS || all_ok=1
_bench_varying "stop.sh"                  "$REPO_ROOT/hooks/stop.sh"                 STOP_PAYLOADS || all_ok=1

exit "$all_ok"
