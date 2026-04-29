#!/usr/bin/env bats
# Structural assertions on the 5 SKILL.md dispatchers.
# Surfaced by ce:review (run id 20260429-021833-77cd33fd) — the dispatchers
# went through several rewrites and we had no test pinning the contract:
# frontmatter shape, expected script path, and (for hatch/reset) the
# with/without --confirm code-block pair.
#
# These tests are markdown-structural, NOT LLM-behavioral. We can't assert
# that the imperative framing ACTUALLY causes a model to execute (that's
# an eval-harness question), but we can pin the surface every dispatcher
# is expected to maintain.

bats_require_minimum_version 1.5.0

load ../test_helper

SKILLS_DIR="$REPO_ROOT/skills"

# Each row: <skill_dir> <expected script path tail>
SKILLS=(
  "hatch:scripts/hatch.sh"
  "stats:scripts/status.sh"
  "interact:scripts/interact.sh"
  "reset:scripts/reset.sh"
  "install-statusline:scripts/install_statusline.sh"
)

@test "skills: every dispatcher has disable-model-invocation: true in frontmatter" {
  for entry in "${SKILLS[@]}"; do
    local skill="${entry%%:*}"
    local f="$SKILLS_DIR/$skill/SKILL.md"
    [ -f "$f" ] || { echo "missing $f"; return 1; }
    grep -qE '^disable-model-invocation:\s*true\s*$' "$f" \
      || { echo "$skill: disable-model-invocation:true missing or malformed"; return 1; }
  done
}

@test "skills: every dispatcher has a non-empty description in frontmatter" {
  for entry in "${SKILLS[@]}"; do
    local skill="${entry%%:*}"
    local f="$SKILLS_DIR/$skill/SKILL.md"
    grep -qE '^description:\s*\S' "$f" \
      || { echo "$skill: description missing or empty"; return 1; }
  done
}

@test "skills: every dispatcher names its expected bash script path" {
  for entry in "${SKILLS[@]}"; do
    local skill="${entry%%:*}"
    local script="${entry##*:}"
    local f="$SKILLS_DIR/$skill/SKILL.md"
    grep -qF "\${CLAUDE_PLUGIN_ROOT}/$script" "$f" \
      || { echo "$skill: SKILL.md does not reference \${CLAUDE_PLUGIN_ROOT}/$script"; return 1; }
  done
}

@test "skills: hatch + reset each contain BOTH a with-confirm AND a without-confirm bash block" {
  # Catches a copy-paste swap that would invert the destructive-op gate:
  # if the 'Without --confirm' block accidentally contained --confirm, every
  # /buddy:reset would wipe.
  for skill in hatch reset; do
    local f="$SKILLS_DIR/$skill/SKILL.md"
    local script="scripts/$skill.sh"
    [[ "$skill" == "reset" ]] && script="scripts/reset.sh"
    [[ "$skill" == "hatch" ]] && script="scripts/hatch.sh"
    grep -qF "\${CLAUDE_PLUGIN_ROOT}/$script\" --confirm" "$f" \
      || { echo "$skill: missing 'with --confirm' bash block"; return 1; }
    # The without-confirm block: the script path appears WITHOUT the --confirm
    # token on the same line. grep for the path then check at least one match
    # has nothing after the closing quote.
    grep -E "\\\$\\{CLAUDE_PLUGIN_ROOT\\}/$script\"\\s*$" "$f" >/dev/null \
      || { echo "$skill: missing 'without --confirm' bash block"; return 1; }
  done
}

@test "skills: hatch + reset SKILL.md preserve 'when in doubt' tiebreaker for ambiguous --confirm prompts" {
  # Adversarial review (run 20260429-021833) flagged: the destructive-op
  # gate is load-bearing on the 'when in doubt, omit it' tiebreaker. A
  # rewrite that compresses this rule out is a P1 regression for reset
  # (no backup) and P2 for hatch (eats 10 tokens).
  for skill in hatch reset; do
    local f="$SKILLS_DIR/$skill/SKILL.md"
    grep -qiE 'when in doubt|when (you'\''re )?not sure|if (you'\''re )?not sure' "$f" \
      || { echo "$skill: missing 'when in doubt, omit' style tiebreaker"; return 1; }
  done
}

@test "skills: install-statusline lists explicit code blocks for install / uninstall / --yes / --dry-run / --help" {
  # The dispatcher uses ONE script path with explicit subcommand args per
  # block. Match the trailing token of each variant after the closing quote.
  local f="$SKILLS_DIR/install-statusline/SKILL.md"
  local variants=(
    'install_statusline\.sh" install$'
    'install_statusline\.sh" install --dry-run'
    'install_statusline\.sh" install --yes'
    'install_statusline\.sh" uninstall$'
    'install_statusline\.sh" uninstall --dry-run'
    'install_statusline\.sh" --help'
  )
  for variant in "${variants[@]}"; do
    grep -qE "$variant" "$f" \
      || { echo "install-statusline: missing variant '$variant'"; return 1; }
  done
}

@test "skills: every dispatcher includes the path-fallback escape hatch" {
  # Canonical wording: 'walking up from this file's directory' — pin so future
  # rewrites don't drift to ambiguous alternatives.
  for entry in "${SKILLS[@]}"; do
    local skill="${entry%%:*}"
    local f="$SKILLS_DIR/$skill/SKILL.md"
    grep -qE 'walk(ing)? up from this file' "$f" \
      || { echo "$skill: missing path-fallback escape hatch wording"; return 1; }
  done
}

@test "skills: stats SKILL.md preserves the error.log debugging pointer" {
  # Lost in the first rewrite, restored after agent-native review caught it.
  local f="$SKILLS_DIR/stats/SKILL.md"
  grep -qF '${CLAUDE_PLUGIN_DATA}/error.log' "$f" \
    || { echo "stats: error.log debugging pointer missing"; return 1; }
}
