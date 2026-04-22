#!/usr/bin/env bash
# signals.sh — Buddy plugin XP + four-axis signals accumulator.
#
# Single public entry point:
#
#   hook_signals_apply <event_type> <buddy_json> <event_inputs_json>
#     Emits TWO lines on stdout:
#       line 1: "LEVEL_UP:<new_level>"  (or empty on no level-up)
#       line 2: updated buddy JSON (compact, jq -c)
#     Returns 0 on success; 1 only on caller-programming errors
#     (missing args). On any internal jq failure, both lines are
#     empty — callers must fall back to the pre-call buddy JSON
#     and suppress the emit (D11 of the P4-1 plan).
#
# Caller contract: invoke INSIDE the per-session flock AND inside
# the nested buddy.json flock. The returned buddy JSON is what the
# caller persists via buddy_save. See hooks/post-tool-use.sh for the
# lock-nesting discipline.
#
# Fork budget: ONE jq per call (the fused filter). The filter handles
# signals lazy-init, all four axes, XP add, streak bonus, and level-up
# detection in one pass. See
# docs/solutions/best-practices/bash-jq-fork-collapse-hot-path-2026-04-21.md.
#
# Event-inputs JSON shape (caller builds via `jq -n`):
#   {
#     "toolName":            "Edit" | "Bash" | ... | "",
#     "filePath":            "/absolute/path/to/file" | "",
#     "filePathMatchedLast": true | false,
#     "isEditTool":          true | false,   # caller's Edit/Write/MultiEdit check
#     "now":                 1745270100,     # epoch-seconds
#     "today":               "2026-04-21",   # UTC YYYY-MM-DD
#     "sessionActiveHours":  1.5             # float, Stop only; else 0
#   }
#
# The filter parses `today` via jq strptime/mktime under TZ=UTC to derive
# its own day-boundary epoch — callers do NOT need to pre-compute it.
#
# Event types: "PostToolUse" | "PostToolUseFailure" | "Stop" |
#              "LevelUp"  (reserved; no-op — level-up events are
#                         detected and signalled INSIDE this helper
#                         on PTU/PTUF/Stop fires).
#
# XP rules (D5 of P4-1 plan):
#   PostToolUse:          +2
#   PostToolUseFailure:   +1
#   Stop:                 +5 + 2 * floor(sessionActiveHours)
#   Streak-extend bonus:  +10 (ONLY when the streak branch advances
#                              OR resets — same-day fires don't pay it)
#
# Signal rules:
#   consistency — D7 streak gate-tolerance, UTC day boundary:
#     today == lastActiveDay                → no change
#     today == lastActiveDay + 1 day        → streakDays++, bonus applies
#     today  > lastActiveDay + 1 day        → streakDays = 1, bonus applies
#     lastActiveDay == "1970-01-01" (sentinel) → streakDays = 1, bonus applies
#   variety — .toolsUsed[$toolName] = $now; prune entries older than 7 days.
#   quality — PTU+isEditTool: successfulEdits++, totalEdits++
#              PTUF:           totalEdits++
#              Stop:           unchanged
#   chaos    — PTUF:                                           errors++
#              PTU + filePathMatchedLast + isEditTool:         repeatedEditHits++
#              Stop:                                           unchanged
#
# Level-up rule (D12): new_xp = old_xp + xp_add + streak_bonus.
# target_level = min(level_for_xp(new_xp), MAX_LEVEL). LEVEL_UP sentinel
# fires iff target_level > old_level. XP over the cap accrues but no
# further level transitions happen.
#
# The level_for_xp helper is inlined into the jq filter directly — no
# external call. Identical to the bash implementation in scripts/lib/
# evolution.sh; kept in sync manually. A regression on either side is
# covered by the anchor tests in tests/evolution.bats AND the level-up
# scenarios in tests/hooks/test_signals.bats.

# Require bash 4.1+ for exec {fd} syntax used by hooks (not here, but
# keeps the same floor).
if [[ -z "${BASH_VERSINFO[0]:-}" ]] || (( BASH_VERSINFO[0] < 4 )) || \
   (( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 1 )); then
  echo "buddy-signals: requires bash 4.1+ (got ${BASH_VERSION:-unknown})" >&2
  return 1 2>/dev/null || exit 1
fi

if [[ "${_BUDDY_SIGNALS_LOADED:-}" != "1" ]]; then
  _BUDDY_SIGNALS_LOADED=1

  # Retention window for variety.toolsUsed entries — 7 days in seconds.
  # Anything not seen in this window is pruned on the next write.
  readonly _SIGNALS_VARIETY_RETENTION_SECS=604800

  # XP rewards per event.
  readonly _SIGNALS_XP_PTU=2
  readonly _SIGNALS_XP_PTUF=1
  readonly _SIGNALS_XP_STOP_BASE=5
  readonly _SIGNALS_XP_STOP_PER_HOUR=2
  readonly _SIGNALS_XP_STREAK_BONUS=10

  # Absolute level ceiling. Duplicated from scripts/lib/evolution.sh
  # because signals.sh is sourced by hooks that may not have sourced
  # evolution.sh (signal mutation is independent of status rendering).
  # Keep these in sync.
  readonly _SIGNALS_MAX_LEVEL=50
fi

# Public entry — fused signals + XP + level-up evaluator.
#
# Two-line stdout, as documented at the top of this file.
hook_signals_apply() {
  local event_type="${1:-}"
  local buddy_json="${2:-}"
  local event_inputs_json="${3:-}"

  if [[ -z "$event_type" || -z "$buddy_json" || -z "$event_inputs_json" ]]; then
    # Programming error. Emit empty scalar + empty blob — the caller's
    # defensive fallback (pre-call buddy JSON, no emit) handles it.
    printf '\n'
    return 1
  fi

  # Unknown event type — pass through unchanged with empty sentinel.
  # Hook layer never crashes.
  case "$event_type" in
    PostToolUse|PostToolUseFailure|Stop) ;;
    *)
      local compact
      compact="$(printf '%s' "$buddy_json" | jq -c '.' 2>/dev/null)"
      printf '\n%s' "${compact:-$buddy_json}"
      return 0
      ;;
  esac

  # Signals skeleton — passed to the filter for lazy-init via
  # `.buddy.signals // $skel`. Duplicated here as a string literal
  # (rather than calling signals_skeleton from evolution.sh) so this
  # module stays sourced-independently of the evolution lib.
  local signals_skel='{"consistency":{"streakDays":0,"lastActiveDay":"1970-01-01"},"variety":{"toolsUsed":{}},"quality":{"successfulEdits":0,"totalEdits":0},"chaos":{"errors":0,"repeatedEditHits":0}}'

  # Single fused jq: signals lazy-init + axis mutations + XP add + level
  # evaluation + level-up sentinel. TZ=UTC so strptime/mktime parse
  # ISO dates deterministically regardless of host timezone (the P3-2
  # iso_to_epoch helper uses -u; same discipline here).
  printf '%s' "$buddy_json" | TZ=UTC jq -r \
    --arg event "$event_type" \
    --argjson in "$event_inputs_json" \
    --argjson skel "$signals_skel" \
    --argjson retention "$_SIGNALS_VARIETY_RETENTION_SECS" \
    --argjson xp_ptu "$_SIGNALS_XP_PTU" \
    --argjson xp_ptuf "$_SIGNALS_XP_PTUF" \
    --argjson xp_stop_base "$_SIGNALS_XP_STOP_BASE" \
    --argjson xp_stop_hr "$_SIGNALS_XP_STOP_PER_HOUR" \
    --argjson xp_streak "$_SIGNALS_XP_STREAK_BONUS" \
    --argjson max_level "$_SIGNALS_MAX_LEVEL" '
    # Inline level_for_xp. Identical semantics to scripts/lib/evolution.sh.
    def level_for_xp($xp; $max):
      if $xp < 0 then 1
      else
        [range(1; $max + 1)]
        | map(select((50 * . * (. + 1)) <= $xp))
        | length + 1
        | if . > $max then $max else . end
      end;

    . as $buddy |
    ($buddy.buddy.signals // $skel) as $sig |
    ($buddy.buddy.xp    // 0) as $xp0 |
    ($buddy.buddy.level // 1) as $lvl0 |

    # --- Streak logic (D7) ---
    ($sig.consistency.lastActiveDay // "1970-01-01") as $lad |
    # An empty or missing `today` is a caller-programming error. If we
    # propagated it through, lastActiveDay would be set to "" on the
    # write below, and the subsequent sentinel guard ("1970-01-01"
    # reset branch) would no longer match the unset state. Preserve
    # the prior lastActiveDay + skip the bonus instead.
    (if ($in.today // "") == "" then $lad else $in.today end) as $today |
    # Parse both ISO dates via strptime/mktime. TZ=UTC env ensures
    # UTC-coherent epoch conversion. Invalid dates → 0 → "reset" branch.
    ($lad   | try (strptime("%Y-%m-%d") | mktime) catch 0) as $lad_ep |
    ($today | try (strptime("%Y-%m-%d") | mktime) catch 0) as $today_ep |
    (if $lad_ep > 0 and $today_ep > 0
       then (($today_ep - $lad_ep) / 86400 | floor)
       else 9999  # force reset branch
     end) as $days_diff |

    # Streak decision.
    # - Same day        → no change, no bonus.
    # - Next day (+1)   → increment, bonus applies.
    # - Gap > 1 or sentinel → reset to 1, bonus applies.
    (if $lad == "1970-01-01" then
       { streakDays: 1, lastActiveDay: $today, bonus: true }
     elif $days_diff == 0 then
       { streakDays: ($sig.consistency.streakDays // 0),
         lastActiveDay: $lad,
         bonus: false }
     elif $days_diff == 1 then
       { streakDays: (($sig.consistency.streakDays // 0) + 1),
         lastActiveDay: $today,
         bonus: true }
     else
       # Any gap > 1 day, including backwards (host clock skew) and
       # invalid parse, resets to 1. New streak is still worth the
       # bonus — the user showed up.
       { streakDays: 1, lastActiveDay: $today, bonus: true }
     end) as $streak |

    # --- variety.toolsUsed: set + prune ---
    # The set is PTU-only per the ticket requirement to append the tool
    # name on PostToolUse. PTUF attempts and Stop events do not count as
    # tool usage (a failed Edit did not successfully exercise the tool
    # surface). Prune still runs on every event so the 7-day retention
    # window advances even on non-PTU fires.
    ($in.toolName // "") as $tool |
    ($in.now // 0 | tonumber? // 0) as $now |
    (
      ($sig.variety.toolsUsed // {})
      | (if $event == "PostToolUse" and $tool != ""
           then .[$tool] = $now
           else .
         end)
      | with_entries(select(
          (.value | type) == "number" and .value > ($now - $retention)
        ))
    ) as $tools_used |

    # --- quality ---
    ($in.isEditTool // false) as $is_edit |
    (if $event == "PostToolUse" and $is_edit then
       { successfulEdits: (($sig.quality.successfulEdits // 0) + 1),
         totalEdits:      (($sig.quality.totalEdits      // 0) + 1) }
     elif $event == "PostToolUseFailure" then
       { successfulEdits: ($sig.quality.successfulEdits // 0),
         totalEdits:      (($sig.quality.totalEdits // 0) + 1) }
     else
       { successfulEdits: ($sig.quality.successfulEdits // 0),
         totalEdits:      ($sig.quality.totalEdits // 0) }
     end) as $quality |

    # --- chaos ---
    ($in.filePathMatchedLast // false) as $match |
    (if $event == "PostToolUseFailure" then
       { errors:           (($sig.chaos.errors // 0) + 1),
         repeatedEditHits: ($sig.chaos.repeatedEditHits // 0) }
     elif $event == "PostToolUse" and $is_edit and $match then
       { errors:           ($sig.chaos.errors // 0),
         repeatedEditHits: (($sig.chaos.repeatedEditHits // 0) + 1) }
     else
       { errors:           ($sig.chaos.errors // 0),
         repeatedEditHits: ($sig.chaos.repeatedEditHits // 0) }
     end) as $chaos |

    # --- XP: base + optional streak bonus ---
    ($in.sessionActiveHours // 0) as $hrs |
    (if $event == "PostToolUse"        then $xp_ptu
     elif $event == "PostToolUseFailure" then $xp_ptuf
     elif $event == "Stop"             then ($xp_stop_base + $xp_stop_hr * ($hrs | floor))
     else 0
     end) as $xp_base |
    (if $streak.bonus then $xp_streak else 0 end) as $xp_bonus |
    ($xp0 + $xp_base + $xp_bonus) as $xp_new |

    # --- Level evaluation ---
    level_for_xp($xp_new; $max_level) as $lvl_new |
    (if $lvl_new > $lvl0 then "LEVEL_UP:\($lvl_new)" else "" end) as $sentinel |

    # --- Assemble updated buddy JSON ---
    ($buddy
      | .buddy.xp    = $xp_new
      | .buddy.level = $lvl_new
      | .buddy.signals = {
          consistency: {
            streakDays: $streak.streakDays,
            lastActiveDay: $streak.lastActiveDay
          },
          variety: { toolsUsed: $tools_used },
          quality: $quality,
          chaos:   $chaos
        }
    ) as $new_buddy |

    "\($sentinel)\n\($new_buddy | tojson)"
  ' 2>/dev/null || {
    # jq failure → empty scalar + empty blob. Caller falls back to
    # pre-call buddy JSON.
    printf '\n'
    return 0
  }
}
