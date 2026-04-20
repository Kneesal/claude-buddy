#!/usr/bin/env bash
# stop.sh — Stop hook. No-op in P3-1.
#
# Fires once at session end. P3-1 intentionally does nothing here —
# P3-2 will extend this file with end-of-session commentary and P4-1
# will add the XP tick. Landing the file + the hooks.json wiring now
# means those tickets don't have to touch hooks.json at all.
#
# Contract: always exits 0, empty stdout, p95 < 100ms.

exec 2>/dev/null
exit 0
