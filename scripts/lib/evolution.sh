#!/usr/bin/env bash
# evolution.sh — Buddy plugin XP curve + level helpers.
#
# Pure arithmetic primitives. No state I/O, no jq forks, no external
# dependencies beyond bash itself. Callers:
#   - scripts/hooks/signals.sh — runs a jq filter that inlines the same
#     level_for_xp loop for its hot path; uses this library's
#     MAX_LEVEL constant as the cap.
#   - scripts/status.sh — renders "xp / xpForLevel(level)" on /buddy:stats.
#
# Semantics (pinned by the P4-1 plan, §Unit 1):
#
#   xpForLevel(n) = 50 * n * (n + 1)
#
#     The cumulative XP threshold to advance FROM level n to level n+1.
#     A buddy at level L has reached that level once its xp >=
#     xpForLevel(L-1) and stays there until xp >= xpForLevel(L).
#
#     Anchor values:
#       xpForLevel(1)  = 100    (Lv 1→2 threshold)
#       xpForLevel(5)  = 1500
#       xpForLevel(10) = 5500
#
#   level_for_xp(xp) = highest level reached at the given xp total,
#   capped at MAX_LEVEL. Monotone non-decreasing in xp.
#
#     Anchor values:
#       level_for_xp(0)         = 1
#       level_for_xp(99)        = 1
#       level_for_xp(100)       = 2
#       level_for_xp(9999999999)= 50 (cap)
#
# MAX_LEVEL is the absolute ceiling; XP over the cap accrues to the
# xp field but no further level transitions occur (P4-1 ticket D12).

# Require bash 4.1+ to match state.sh and rng.sh. See state.sh for rationale.
if [[ -z "${BASH_VERSINFO[0]:-}" ]] || (( BASH_VERSINFO[0] < 4 )) || \
   (( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 1 )); then
  echo "buddy-evolution: requires bash 4.1+ (got ${BASH_VERSION:-unknown})" >&2
  return 1 2>/dev/null || exit 1
fi

# Source-guard — the state.sh pattern. Protects the readonly below.
if [[ "${_EVOLUTION_SH_LOADED:-}" != "1" ]]; then
  _EVOLUTION_SH_LOADED=1

  # Absolute level ceiling. XP accrues past the threshold but the level
  # does not advance. 50 is chosen per ticket; a larger cap would push
  # the level_for_xp loop beyond a trivial cost.
  readonly MAX_LEVEL=50
fi

# xpForLevel(n) — emit the XP threshold to advance FROM level n to n+1.
# Negative / non-integer / zero inputs are degenerate but tolerated:
# n=0 → 0 (used as the "xp to reach level 1" sentinel in loops).
xpForLevel() {
  local n="${1:-0}"
  # Defensive: non-integer (including empty) collapses to 0.
  [[ "$n" =~ ^-?[0-9]+$ ]] || n=0
  if (( n < 0 )); then
    printf '0'
    return 0
  fi
  printf '%d' $(( 50 * n * (n + 1) ))
}

# level_for_xp(xp) — emit the highest level achieved at the given xp.
# Capped at MAX_LEVEL. Negative inputs return 1.
# O(level) — at most MAX_LEVEL iterations of integer arithmetic.
level_for_xp() {
  local xp="${1:-0}"
  [[ "$xp" =~ ^-?[0-9]+$ ]] || xp=0
  if (( xp < 0 )); then
    printf '1'
    return 0
  fi
  local level=1
  while (( level < MAX_LEVEL )); do
    local threshold=$(( 50 * level * (level + 1) ))
    (( xp < threshold )) && break
    level=$(( level + 1 ))
  done
  printf '%d' "$level"
}

# signals_skeleton — emit the canonical initial JSON fragment for
# buddy.signals as a COMPACT object on stdout.
#
# Shape pinned by P4-1 plan D3. lastActiveDay uses the 1970-01-01
# sentinel so the streak logic's "first ever signal write" branch
# fires via the gap-tolerance rule in D7 without a special case.
# variety.toolsUsed is a flat map per D6 — keyed by tool name,
# values are epoch-seconds of last observation.
signals_skeleton() {
  # Static JSON — no inputs — so we ship the literal via printf rather
  # than pay a jq fork. Kept single-line (jq -c equivalent) so callers
  # can splice it into larger documents via --argjson cleanly.
  printf '%s' '{"consistency":{"streakDays":0,"lastActiveDay":"1970-01-01"},"variety":{"toolsUsed":{}},"quality":{"successfulEdits":0,"totalEdits":0},"chaos":{"errors":0,"repeatedEditHits":0}}'
}
