---
title: Collapse jq invocations to protect hook p95 budgets — fusion, not caching
date: 2026-04-21
category: best-practices
module: scripts/hooks/
problem_type: best_practice
component: tooling
severity: high
applies_when:
  - A bash hook script has a p95 latency budget (Claude Code plugin hooks target < 100 ms) and the happy path reads, checks, or mutates JSON via multiple sequential `jq` calls
  - A function performs N jq passes that each read the same blob — each jq read-modify round-trip is ~5-20 ms of fork/parse/serialize overhead on a cold page cache
  - A reviewer flags "p95 is close to budget with no obvious algorithmic cost" on a hook that touches JSON
  - Planning a new hook that will evolve toward multi-step state mutation (dedup → gate → budget → cooldown → draw) and the per-hook fork count is trending upward
related_components:
  - hooks
  - testing_framework
tags:
  - bash
  - jq
  - hot-path
  - performance
  - hooks
  - claude-code-plugin
  - p95
---

# Collapse jq invocations to protect hook p95 budgets — fusion, not caching

## Context

During P3-2 of the buddy Claude Code plugin, the PostToolUse hook's
happy path (dedup-ring update → novelty gate → cooldown gate →
budget gate → bank resolution → shuffle-bag draw → cooldown bump →
budget bump → session save) spawned roughly 25 `jq` subprocesses
per fire. On a 100-iteration perf harness, p95 was 87 ms against a
100 ms budget. Under concurrency the 0.2 s flock timeout would have
started engaging before any real work serialized.

The existing in-repo performance doc
([bash-lcg-hotpath-patterns-2026-04-19.md](./bash-lcg-hotpath-patterns-2026-04-19.md))
documents **caching** — per-process `declare -gA` maps that avoid
spawning jq on repeat reads of the same blob. That works when the
hot loop reads unchanged data. It does not help when a single call
has to do N distinct **mutations** of the same blob in sequence.

The fix there is a different technique: **fusion** — collapse N
sequential jq filters into one jq invocation that receives all
necessary inputs as `--arg`/`--argjson` parameters and emits the
final result (or a sentinel) in a single pipeline. The canonical
in-repo example predates P3-2:

```bash
# From scripts/hooks/common.sh — one jq invocation that does
# membership check AND ring push, returning "DEDUP" sentinel on hit.
hook_ring_update() {
  local id="$1"
  jq -r --arg id "$id" --argjson max "$HOOK_RING_MAX" '
    if ((.recentToolCallIds // []) | any(. == $id)) then
      "DEDUP"
    else
      (.recentToolCallIds = (((.recentToolCallIds // []) + [$id]) | .[-($max):]))
      | tojson
    end
  '
}
```

That single jq invocation replaces a read-check-decide-write chain
that would otherwise be 3-4 forks. Each fusion saves ~15-40 ms of
wall time on a cold cache.

## Guidance

### A. Reach for fusion before reaching for caching

Caching avoids recomputing what hasn't changed. Fusion avoids
paying fork/startup cost N times when a single call would produce
the same result. On hook hot paths, the inputs typically change
every fire (session-JSON is new, event-type varies), so caching
buys nothing. Fusion buys the full 5-20 ms × N.

Decision rule:

- Same blob read repeatedly across calls? → cache (per-process
  `declare -gA`, see [bash-lcg-hotpath-patterns](./bash-lcg-hotpath-patterns-2026-04-19.md)).
- Same blob mutated multiple times within one call? → fuse.

### B. Fusion patterns that work in practice

**1. Predicate + mutation in one filter.** Wrap the check and the
write in a single jq program. Emit a sentinel string when the
predicate fails so the caller can short-circuit without a second
jq pass:

```bash
update_or_dedup() {
  jq -r --arg key "$1" '
    if .seen[$key] then "DEDUP"
    else (.seen[$key] = true | tojson)
    end
  '
}
# caller
result="$(printf '%s' "$state" | update_or_dedup "$id")"
[[ "$result" == "DEDUP" ]] && return 0
state="$result"
```

**2. Multi-field mutation in one program.** Instead of four
sequential `jq '.a = $x'`, `jq '.b = $y'`, … fuse them:

```bash
jq --arg event "$e" \
   --argjson now "$now" \
   --argjson fires "$new_fires" \
   --argjson budget "$new_budget" \
   '.lastEventType = $event
    | .cooldowns[$event] = { fires: $fires, nextAllowedAt: ($now + 300) }
    | .commentsThisSession = $budget'
```

One fork, three mutations committed atomically in memory.

**3. Compute + emit scalar + emit updated blob in one program.**
When the caller needs both a derived value (a line to print) and
the updated state, return both and split downstream:

```bash
jq -r --argjson now "$now" '
  .bags[$key] as $bag |
  (if ($bag | length) == 0 then refill else $bag end) as $b |
  [ .lines[ $b[0] ],                            # scalar output
    (.bags[$key] = $b[1:] | tojson)             # updated blob
  ] | @tsv
'
```

See also [bash-subshell-value-plus-json-return-2026-04-21.md](./bash-subshell-value-plus-json-return-2026-04-21.md)
for the downstream delivery pattern.

### C. Measure before fusing; measure after

Fusion is not free — complex jq programs are harder to read and
debug than short sequential filters. Only pay the readability cost
when the wall-time cost is real.

Use `EPOCHREALTIME` (bash 5+) inside the hot function to measure
before and after. The project's existing `tests/hooks/perf_hook_p95.sh`
is the right harness:

```bash
ITERATIONS=100 ./tests/hooks/perf_hook_p95.sh
# post-tool-use.sh    n=100  min= 74ms  p95= 85ms  max=103ms  [OK]
```

p95 close to the budget ceiling is a signal to fuse. p95 at half
the budget is a signal to leave the code readable.

### D. The fork-cost ceiling is real

Approximate cost on typical Linux CI runners for this plugin's
workloads:

| Operation              | Cost |
|------------------------|------|
| bash builtin (e.g. `[[ ]]`, `printf`) | ~0 ms |
| Subshell `$(...)` fork | 1-3 ms |
| `jq` fork + parse + emit | 5-20 ms |
| `date +%s` fork        | 2-5 ms |
| Flock acquire (uncontended) | <1 ms |

A single hook doing 25 jq forks buys a 125-500 ms floor before it
has done any work. Fusion that cuts it to 5-7 jq forks buys the
difference back.

## Why This Matters

Claude Code hooks fire on every tool use. A 500 ms hook is not
just slow — it hits the 2-second hook timeout under any sort of
contention or system load, at which point the hook is killed
mid-critical-section and can leave partial state on disk. The p95
< 100 ms budget exists to give headroom for flock contention,
cold caches, and disk variance. Fusion protects that headroom.

Secondarily: fewer forks means fewer opportunities for a single
jq crash (OOM, signal, malformed transient input) to interrupt a
multi-step mutation. Each fused filter is atomic in memory; every
fork-per-mutation is a separate failure point.

## When to Apply

- Hook scripts where p95 is within ~15 ms of budget.
- Any function that reads and mutates the same JSON blob 3+ times
  sequentially.
- New hot-path features added to an existing hook — apply the
  fusion pattern in the first draft, not after measurement shows
  regression.
- Reviews that land on "p95 crept up" without an algorithmic
  change — the likely cause is added jq forks.

## Examples

### Before — four sequential jq forks

```bash
# 4 forks, ~50-80 ms on a cold cache
session="$(printf '%s' "$session" | jq '.lastEventType = "PTU"')"
session="$(printf '%s' "$session" | jq --argjson n "$now" '.cooldowns.PTU = { fires: 1, nextAllowedAt: $n + 300 }')"
session="$(printf '%s' "$session" | jq '.commentsThisSession += 1')"
session="$(printf '%s' "$session" | jq '.commentary.firstEditFired = true')"
```

### After — one fused filter

```bash
# 1 fork, ~5-15 ms
session="$(printf '%s' "$session" | jq \
  --argjson n "$now" \
  '.lastEventType = "PTU"
   | .cooldowns.PTU = { fires: 1, nextAllowedAt: ($n + 300) }
   | .commentsThisSession += 1
   | .commentary.firstEditFired = true')"
```

### Perf harness assertion for budget ceilings

```bash
# tests/hooks/perf_hook_p95.sh asserts p95 per hook. A regression that
# adds a jq fork without fusing will surface as the hook's p95 creeping
# past the budget.
ITERATIONS=100 PERF_P95_MAX_MS=100 ./tests/hooks/perf_hook_p95.sh
```

## Related

- [bash-lcg-hotpath-patterns-2026-04-19.md](./bash-lcg-hotpath-patterns-2026-04-19.md)
  — the complementary technique: per-process caching to avoid
  spawning jq at all on repeat reads of unchanged data. Use both.
  Fusion first, then cache the inputs to the fused filters if
  they're stable.
- [bash-state-library-concurrent-load-modify-save-2026-04-20.md](./bash-state-library-concurrent-load-modify-save-2026-04-20.md)
  — fusion matters even more inside a flock, because the held-lock
  time bounds the contention window. A 10-fork hook holds the lock
  longer than a 3-fork hook.
- `scripts/hooks/common.sh:hook_ring_update` — canonical in-repo
  fusion (check + mutate + sentinel in one jq).
- `tests/hooks/perf_hook_p95.sh` — the measurement harness; run
  before and after any fusion work.
