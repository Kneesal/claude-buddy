#!/usr/bin/env bats
# /buddy:install-statusline — consent-gated installer for the ambient
# buddy status-line segment. All paths resolve under $HOME, which we
# override per-test to a fixture directory.

bats_require_minimum_version 1.5.0

load ../test_helper

INSTALL_SH="$REPO_ROOT/scripts/install_statusline.sh"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude"
  export BUDDY_INSTALL_ASSUME_YES=1
  export CLAUDE_PLUGIN_DATA="$BATS_TEST_TMPDIR/plugin-data"
  mkdir -p "$CLAUDE_PLUGIN_DATA"
}

# ---------------------------------------------------------------
# install — append to existing
# ---------------------------------------------------------------

@test "install: dry-run prints diff, does not write" {
  echo "#!/usr/bin/env bash" > "$HOME/.claude/statusline-command.sh"
  local before
  before="$(cat "$HOME/.claude/statusline-command.sh")"

  run --separate-stderr bash "$INSTALL_SH" install --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would append"* ]]
  [[ "$output" == *"buddy-plugin"* ]]
  [ "$before" = "$(cat "$HOME/.claude/statusline-command.sh")" ]
  # No backup taken on dry-run.
  ! ls "$HOME/.claude/"*.buddy-bak.* >/dev/null 2>&1
}

@test "install: append to existing → block present, backup written" {
  echo "#!/usr/bin/env bash" > "$HOME/.claude/statusline-command.sh"
  echo 'echo "hello"' >> "$HOME/.claude/statusline-command.sh"

  run --separate-stderr bash "$INSTALL_SH" install
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installed"* ]]
  grep -qF "# >>> buddy-plugin >>>" "$HOME/.claude/statusline-command.sh"
  grep -qF "# <<< buddy-plugin <<<" "$HOME/.claude/statusline-command.sh"
  grep -qF 'echo "hello"' "$HOME/.claude/statusline-command.sh"
  # Backup written
  ls "$HOME/.claude/"*.buddy-bak.* >/dev/null 2>&1
}

@test "install: idempotent — second install reports already installed" {
  echo "#!/usr/bin/env bash" > "$HOME/.claude/statusline-command.sh"
  bash "$INSTALL_SH" install >/dev/null

  run --separate-stderr bash "$INSTALL_SH" install
  [ "$status" -eq 0 ]
  [[ "$output" == *"already present"* ]]
  # Block appears exactly once.
  count="$(grep -cF "# >>> buddy-plugin >>>" "$HOME/.claude/statusline-command.sh")"
  [ "$count" -eq 1 ]
}

@test "install: no consent → no writes" {
  echo "#!/usr/bin/env bash" > "$HOME/.claude/statusline-command.sh"
  local before
  before="$(cat "$HOME/.claude/statusline-command.sh")"
  unset BUDDY_INSTALL_ASSUME_YES

  run --separate-stderr bash -c 'echo "n" | bash "$0" install' "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cancelled"* ]]
  [ "$before" = "$(cat "$HOME/.claude/statusline-command.sh")" ]
}

# ---------------------------------------------------------------
# install — create from scratch
# ---------------------------------------------------------------

@test "install: no existing script → creates one and updates settings" {
  run --separate-stderr bash "$INSTALL_SH" install
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/statusline-command.sh" ]
  grep -qF "# >>> buddy-plugin >>>" "$HOME/.claude/statusline-command.sh"
  [ -f "$HOME/.claude/settings.json" ]
  # settings.json has statusLine.command pointing at the new script.
  cmd="$(jq -r '.statusLine.command' "$HOME/.claude/settings.json")"
  [ "$cmd" = "$HOME/.claude/statusline-command.sh" ]
  type_field="$(jq -r '.statusLine.type' "$HOME/.claude/settings.json")"
  [ "$type_field" = "command" ]
}

@test "install: existing valid settings.json is preserved on create path" {
  echo '{"theme":"dark","other":"field"}' > "$HOME/.claude/settings.json"
  run --separate-stderr bash "$INSTALL_SH" install
  [ "$status" -eq 0 ]
  [ "$(jq -r '.theme' "$HOME/.claude/settings.json")" = "dark" ]
  [ "$(jq -r '.other' "$HOME/.claude/settings.json")" = "field" ]
  [ "$(jq -r '.statusLine.type' "$HOME/.claude/settings.json")" = "command" ]
}

@test "install: malformed settings.json → refuses, exits non-zero, no write" {
  echo '{ not valid json' > "$HOME/.claude/settings.json"
  local before
  before="$(cat "$HOME/.claude/settings.json")"

  run --separate-stderr bash "$INSTALL_SH" install
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"not valid JSON"* ]]
  [ "$before" = "$(cat "$HOME/.claude/settings.json")" ]
}

# ---------------------------------------------------------------
# uninstall
# ---------------------------------------------------------------

@test "uninstall: removes the block but keeps surrounding script" {
  printf '%s\n' '#!/usr/bin/env bash' 'echo "before"' > "$HOME/.claude/statusline-command.sh"
  bash "$INSTALL_SH" install >/dev/null
  # Sanity: block is present
  grep -qF "# >>> buddy-plugin >>>" "$HOME/.claude/statusline-command.sh"

  run --separate-stderr bash "$INSTALL_SH" uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"Uninstalled"* ]]
  ! grep -qF "# >>> buddy-plugin >>>" "$HOME/.claude/statusline-command.sh"
  grep -qF 'echo "before"' "$HOME/.claude/statusline-command.sh"
}

@test "uninstall: no block → no-op success" {
  echo "#!/usr/bin/env bash" > "$HOME/.claude/statusline-command.sh"
  local before
  before="$(cat "$HOME/.claude/statusline-command.sh")"

  run --separate-stderr bash "$INSTALL_SH" uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to uninstall"* ]]
  [ "$before" = "$(cat "$HOME/.claude/statusline-command.sh")" ]
}

@test "uninstall: no script at all → no-op success" {
  run --separate-stderr bash "$INSTALL_SH" uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "round-trip: install then uninstall → file byte-identical to original" {
  printf '#!/usr/bin/env bash\necho "user content"\nexit 0\n' \
    > "$HOME/.claude/statusline-command.sh"
  local before
  before="$(cat "$HOME/.claude/statusline-command.sh")"
  local before_sum
  before_sum="$(md5sum "$HOME/.claude/statusline-command.sh" | awk '{print $1}')"

  bash "$INSTALL_SH" install >/dev/null
  bash "$INSTALL_SH" uninstall >/dev/null

  local after_sum
  after_sum="$(md5sum "$HOME/.claude/statusline-command.sh" | awk '{print $1}')"
  [ "$before_sum" = "$after_sum" ] || {
    echo "BEFORE:"
    echo "$before" | od -c | head
    echo "AFTER:"
    cat "$HOME/.claude/statusline-command.sh" | od -c | head
    return 1
  }
}

# ---------------------------------------------------------------
# Help / unknown subcommand
# ---------------------------------------------------------------

@test "help: --help prints usage" {
  run --separate-stderr bash "$INSTALL_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--yes"* ]]
}

@test "unknown subcommand exits non-zero" {
  run --separate-stderr bash "$INSTALL_SH" frobnicate
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------
# Top-level --dry-run and --yes synonyms (added after ce:review found
# /buddy:install-statusline --dry-run failed with 'Unknown subcommand').
# ---------------------------------------------------------------

@test "install: top-level --dry-run is treated as install --dry-run" {
  echo "#!/usr/bin/env bash" > "$HOME/.claude/statusline-command.sh"
  local before
  before="$(cat "$HOME/.claude/statusline-command.sh")"

  run --separate-stderr bash "$INSTALL_SH" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would append"* ]]
  [ "$before" = "$(cat "$HOME/.claude/statusline-command.sh")" ]
}

@test "install: --yes flag bypasses interactive consent and writes the block" {
  echo "#!/usr/bin/env bash" > "$HOME/.claude/statusline-command.sh"
  unset BUDDY_INSTALL_ASSUME_YES

  # Empty stdin emulates slash-command dispatch context — the consent
  # prompt would EOF and cancel WITHOUT --yes. With --yes it must succeed.
  run --separate-stderr bash -c 'bash "$0" install --yes </dev/null' "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installed"* ]]
  grep -qF "# >>> buddy-plugin >>>" "$HOME/.claude/statusline-command.sh"
}

@test "install: --yes can appear before or after the subcommand" {
  echo "#!/usr/bin/env bash" > "$HOME/.claude/statusline-command.sh"
  unset BUDDY_INSTALL_ASSUME_YES

  # --yes before subcommand
  run --separate-stderr bash -c 'bash "$0" --yes install </dev/null' "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -qF "# >>> buddy-plugin >>>" "$HOME/.claude/statusline-command.sh"
}

@test "install: short -y flag works as alias for --yes" {
  echo "#!/usr/bin/env bash" > "$HOME/.claude/statusline-command.sh"
  unset BUDDY_INSTALL_ASSUME_YES

  run --separate-stderr bash -c 'bash "$0" install -y </dev/null' "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -qF "# >>> buddy-plugin >>>" "$HOME/.claude/statusline-command.sh"
}
