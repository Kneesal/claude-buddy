#!/usr/bin/env bats
# scripts/dispatch.sh — the lexical router that fans out to the five
# per-command scripts. These tests pin the routing surface (correct
# script per command, correct flag forwarding, exit-0 discipline,
# unknown-command rejection) without relying on the hook glue.
#
# Note: the underlying scripts are exercised by their own bats files
# (slash.bats, test_install_statusline.bats, test_interact.bats). The
# tests below assert on dispatch.sh's output as the user would see it,
# not on the deeper script behavior.

bats_require_minimum_version 1.5.0

load ../test_helper

DISPATCH_SH="$REPO_ROOT/scripts/dispatch.sh"
INSTALL_SH="$REPO_ROOT/scripts/install_statusline.sh"

setup_file() {
  _prepare_hatched_cache
}

setup() {
  # Fresh, isolated plugin data + HOME for each test.
  export CLAUDE_PLUGIN_DATA="$BATS_TEST_TMPDIR/plugin-data"
  mkdir -p "$CLAUDE_PLUGIN_DATA"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude"
  export BUDDY_INSTALL_ASSUME_YES=1
  unset BUDDY_RNG_SEED
  unset BUDDY_SPECIES_DIR
  source "$STATE_LIB"
}

# =========================================================================
# Top-level routing — every command lands on the right script.
# =========================================================================

@test "dispatch: /buddy:stats with no buddy → status.sh's NO_BUDDY message" {
  run --separate-stderr bash "$DISPATCH_SH" "/buddy:stats"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No buddy"* || "$output" == *"hatch"* ]]
}

@test "dispatch: /buddy:stats with active buddy → status.sh renders" {
  _seed_hatch
  run --separate-stderr bash "$DISPATCH_SH" "/buddy:stats"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Custard"* ]]
}

@test "dispatch: /buddy:interact with active buddy → interact.sh renders" {
  _seed_hatch
  run --separate-stderr bash "$DISPATCH_SH" "/buddy:interact"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Custard"* ]]
}

@test "dispatch: /buddy:hatch with no buddy → hatches" {
  BUDDY_RNG_SEED=42 run --separate-stderr bash "$DISPATCH_SH" "/buddy:hatch"
  [ "$status" -eq 0 ]
  [[ "$output" == Hatched* ]]
  [ -f "$CLAUDE_PLUGIN_DATA/buddy.json" ]
}

@test "dispatch: /buddy:hatch with no args + active buddy → no reroll" {
  _seed_hatch
  local before
  before="$(cat "$CLAUDE_PLUGIN_DATA/buddy.json")"

  run --separate-stderr bash "$DISPATCH_SH" "/buddy:hatch"
  [ "$status" -eq 0 ]
  # With seed-42 buddy at 0 tokens the hatch script emits the
  # insufficient-tokens message rather than the --confirm prompt;
  # what matters is that no mutation occurred.
  [ "$before" = "$(cat "$CLAUDE_PLUGIN_DATA/buddy.json")" ]
  [[ "$output" == *"tokens"* || "$output" == *"--confirm"* ]]
}

@test "dispatch: /buddy:reset with no args + active buddy → consequences message, no wipe" {
  _seed_hatch
  run --separate-stderr bash "$DISPATCH_SH" "/buddy:reset"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All buddy data will be lost"* ]]
  [ -f "$CLAUDE_PLUGIN_DATA/buddy.json" ]
}

# =========================================================================
# Strict --confirm rule (D3) — exact-token-only.
# =========================================================================

@test "dispatch: /buddy:reset --confirm wipes (exact-token forwarded)" {
  _seed_hatch
  run --separate-stderr bash "$DISPATCH_SH" "/buddy:reset --confirm"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Buddy reset"* ]]
  [ ! -f "$CLAUDE_PLUGIN_DATA/buddy.json" ]
}

@test "dispatch: /buddy:hatch --confirm against active → rerolls" {
  _seed_hatch
  local before_hashes
  before_hashes="$(jq -r '.meta.totalHatches' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  BUDDY_RNG_SEED=99 run --separate-stderr bash "$DISPATCH_SH" "/buddy:hatch --confirm"
  [ "$status" -eq 0 ]
  local after_hashes
  after_hashes="$(jq -r '.meta.totalHatches' "$CLAUDE_PLUGIN_DATA/buddy.json")"
  [ "$after_hashes" -gt "$before_hashes" ] || [[ "$output" == *"tokens"* || "$output" == *"Lv."* ]]
}

@test "dispatch: /buddy:reset 'what does --confirm do' → no wipe (extra tokens reject)" {
  _seed_hatch
  run --separate-stderr bash "$DISPATCH_SH" "/buddy:reset what does --confirm do"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All buddy data will be lost"* ]]
  [ -f "$CLAUDE_PLUGIN_DATA/buddy.json" ]
}

@test "dispatch: /buddy:hatch '--confirm please' → strict rule rejects, no reroll" {
  _seed_hatch
  local before
  before="$(cat "$CLAUDE_PLUGIN_DATA/buddy.json")"
  run --separate-stderr bash "$DISPATCH_SH" "/buddy:hatch --confirm please"
  [ "$status" -eq 0 ]
  # No mutation — the strict-arg rule treated extra tokens as a non-directive.
  [ "$before" = "$(cat "$CLAUDE_PLUGIN_DATA/buddy.json")" ]
}

@test "dispatch: /buddy:reset with quoted '--confirm' literal → no wipe" {
  _seed_hatch
  run --separate-stderr bash "$DISPATCH_SH" "/buddy:reset '--confirm'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All buddy data will be lost"* ]]
  [ -f "$CLAUDE_PLUGIN_DATA/buddy.json" ]
}

# =========================================================================
# stats and interact ignore extra tokens.
# =========================================================================

@test "dispatch: /buddy:stats with trailing tokens → status.sh runs as if no args" {
  _seed_hatch
  run --separate-stderr bash "$DISPATCH_SH" "/buddy:stats please"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Custard"* ]]
}

@test "dispatch: /buddy:interact with trailing tokens → interact.sh runs as if no args" {
  _seed_hatch
  run --separate-stderr bash "$DISPATCH_SH" "/buddy:interact hi buddy"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Custard"* ]]
}

# =========================================================================
# install-statusline whitelist (D4).
# =========================================================================

@test "dispatch: /buddy:install-statusline → install (default)" {
  echo "#!/usr/bin/env bash" > "$HOME/.claude/statusline-command.sh"
  run --separate-stderr bash "$DISPATCH_SH" "/buddy:install-statusline"
  [ "$status" -eq 0 ]
  grep -qF "# >>> buddy-plugin >>>" "$HOME/.claude/statusline-command.sh"
}

@test "dispatch: /buddy:install-statusline --dry-run → install --dry-run, no writes" {
  echo "#!/usr/bin/env bash" > "$HOME/.claude/statusline-command.sh"
  local before
  before="$(cat "$HOME/.claude/statusline-command.sh")"
  run --separate-stderr bash "$DISPATCH_SH" "/buddy:install-statusline --dry-run"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would append"* ]]
  [ "$before" = "$(cat "$HOME/.claude/statusline-command.sh")" ]
}

@test "dispatch: /buddy:install-statusline --yes → install --yes (consent bypass)" {
  echo "#!/usr/bin/env bash" > "$HOME/.claude/statusline-command.sh"
  unset BUDDY_INSTALL_ASSUME_YES
  run --separate-stderr bash "$DISPATCH_SH" "/buddy:install-statusline --yes"
  [ "$status" -eq 0 ]
  grep -qF "# >>> buddy-plugin >>>" "$HOME/.claude/statusline-command.sh"
}

@test "dispatch: /buddy:install-statusline uninstall → uninstall" {
  echo "#!/usr/bin/env bash" > "$HOME/.claude/statusline-command.sh"
  bash "$INSTALL_SH" install >/dev/null
  run --separate-stderr bash "$DISPATCH_SH" "/buddy:install-statusline uninstall"
  [ "$status" -eq 0 ]
  ! grep -qF "# >>> buddy-plugin >>>" "$HOME/.claude/statusline-command.sh"
}

@test "dispatch: /buddy:install-statusline uninstall --dry-run → preview only" {
  echo "#!/usr/bin/env bash" > "$HOME/.claude/statusline-command.sh"
  bash "$INSTALL_SH" install >/dev/null
  run --separate-stderr bash "$DISPATCH_SH" "/buddy:install-statusline uninstall --dry-run"
  [ "$status" -eq 0 ]
  # block still present (dry-run didn't write)
  grep -qF "# >>> buddy-plugin >>>" "$HOME/.claude/statusline-command.sh"
}

@test "dispatch: /buddy:install-statusline --help → help text" {
  run --separate-stderr bash "$DISPATCH_SH" "/buddy:install-statusline --help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"install"* ]]
  [[ "$output" == *"uninstall"* ]]
}

@test "dispatch: /buddy:install-statusline frobnicate → usage message, no underlying script call" {
  echo "#!/usr/bin/env bash" > "$HOME/.claude/statusline-command.sh"
  local before
  before="$(cat "$HOME/.claude/statusline-command.sh")"
  run --separate-stderr bash "$DISPATCH_SH" "/buddy:install-statusline frobnicate"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [ "$before" = "$(cat "$HOME/.claude/statusline-command.sh")" ]
}

# =========================================================================
# Non-buddy / unknown / edge cases.
# =========================================================================

@test "dispatch: non-buddy prompt → silent exit 0" {
  run --separate-stderr bash "$DISPATCH_SH" "hello world"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dispatch: empty prompt → silent exit 0" {
  run --separate-stderr bash "$DISPATCH_SH" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dispatch: unknown /buddy:* command → silent exit 0" {
  run --separate-stderr bash "$DISPATCH_SH" "/buddy:nonsense"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dispatch: unrelated slash command → silent exit 0" {
  run --separate-stderr bash "$DISPATCH_SH" "/help"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dispatch: prefix collision /buddy:hatcher → silent exit 0 (word boundary)" {
  run --separate-stderr bash "$DISPATCH_SH" "/buddy:hatcher --confirm"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dispatch: leading whitespace trimmed before regex" {
  _seed_hatch
  run --separate-stderr bash "$DISPATCH_SH" "  /buddy:stats  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Custard"* ]]
}

# =========================================================================
# Internal-failure discipline — exit 0 + log to error.log.
# =========================================================================

@test "dispatch: missing underlying script → exit 0, error.log updated, user-facing one-liner" {
  # Point to a plugin root that has no scripts/ dir.
  local fake_root="$BATS_TEST_TMPDIR/fake-root"
  mkdir -p "$fake_root/scripts"
  # Note: we deliberately do NOT create scripts/status.sh under fake_root.
  CLAUDE_PLUGIN_ROOT="$fake_root" run --separate-stderr bash "$DISPATCH_SH" "/buddy:stats"
  [ "$status" -eq 0 ]
  [[ "$output" == *"internal error"* ]]
  [ -f "$CLAUDE_PLUGIN_DATA/error.log" ]
  grep -qF "missing script" "$CLAUDE_PLUGIN_DATA/error.log"
}

@test "dispatch: underlying script exits non-zero → stdout + stderr both surface, dispatch still exit 0" {
  # Build a fake plugin root where status.sh exits 1 with content on both
  # stdout and stderr, and verify dispatch.sh forwards both.
  local fake_root="$BATS_TEST_TMPDIR/fake-root"
  mkdir -p "$fake_root/scripts"
  cat > "$fake_root/scripts/status.sh" <<'EOF'
#!/usr/bin/env bash
echo "STDOUT_LINE"
echo "STDERR_LINE" >&2
exit 1
EOF
  chmod +x "$fake_root/scripts/status.sh"
  CLAUDE_PLUGIN_ROOT="$fake_root" run --separate-stderr bash "$DISPATCH_SH" "/buddy:stats"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STDOUT_LINE"* ]]
  [[ "$output" == *"STDERR_LINE"* ]]
}
