#!/usr/bin/env bash
#
# 用途: Issue #52 task 2 の install.sh local runtime safe overwrite を検証する。
# 配置先: local-watcher/test/security_medium_install_test.sh
# 依存: bash 4+, cmp, grep, mktemp
# 実行: bash local-watcher/test/security_medium_install_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
WATCHER_SRC="$REPO_ROOT/local-watcher/bin/idd-codex-issue-watcher.sh"
PLIST_SRC="$REPO_ROOT/local-watcher/LaunchAgents/com.local.idd-codex-issue-watcher.plist"

PASS_COUNT=0
FAIL_COUNT=0

assert_true() {
  local label="$1"
  shift
  if "$@"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  command: $*"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_file_contains() {
  local label="$1" path="$2" needle="$3"
  if [ -f "$path" ] && grep -Fq -- "$needle" "$path"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  path: $path"
    echo "  needle: $needle"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_file_not_exists() {
  local label="$1" path="$2"
  if [ ! -e "$path" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  unexpected path: $path"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

run_install_local() {
  local home_dir="$1"
  local output_path="$2"
  shift 2
  HOME="$home_dir" "$INSTALL_SH" --local "$@" >"$output_path"
}

run_install_local_darwin() {
  local home_dir="$1"
  local output_path="$2"
  local fake_bin="$3"
  shift 3
  mkdir -p "$fake_bin"
  cat > "$fake_bin/uname" <<'FAKE_UNAME'
#!/usr/bin/env bash
printf 'Darwin\n'
FAKE_UNAME
  chmod +x "$fake_bin/uname"
  HOME="$home_dir" PATH="$fake_bin:$PATH" "$INSTALL_SH" --local "$@" >"$output_path"
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# Normal: missing watcher is created with executable bit.
home_new="$TMPROOT/home-new"
mkdir -p "$home_new"
run_install_local "$home_new" "$TMPROOT/new.log"
assert_true "missing watcher is created from bundled template (Req 2.1 / NFR 1.3)" \
  cmp -s "$WATCHER_SRC" "$home_new/bin/idd-codex-issue-watcher.sh"
assert_true "created watcher is executable (NFR 1.3)" \
  test -x "$home_new/bin/idd-codex-issue-watcher.sh"
assert_file_contains "normal install reports watcher creation (Req 2.5)" \
  "$TMPROOT/new.log" "NEW       $home_new/bin/idd-codex-issue-watcher.sh"

# Changed existing watcher: backup is visible and target is refreshed.
home_changed="$TMPROOT/home-changed"
mkdir -p "$home_changed/bin"
printf '#!/usr/bin/env bash\n# operator custom watcher\n' > "$home_changed/bin/idd-codex-issue-watcher.sh"
chmod +x "$home_changed/bin/idd-codex-issue-watcher.sh"
run_install_local "$home_changed" "$TMPROOT/changed.log"
assert_true "changed watcher is backed up before overwrite (Req 2.1 / Req 2.3)" \
  grep -Fq '# operator custom watcher' "$home_changed/bin/idd-codex-issue-watcher.sh.bak"
assert_true "changed watcher target is refreshed after backup (Req 2.1)" \
  cmp -s "$WATCHER_SRC" "$home_changed/bin/idd-codex-issue-watcher.sh"
assert_file_contains "changed watcher backup path is operator-visible (Req 2.3)" \
  "$TMPROOT/changed.log" "BACKUP    $home_changed/bin/idd-codex-issue-watcher.sh"
assert_file_contains "changed watcher overwrite action is reported (Req 2.5)" \
  "$TMPROOT/changed.log" "OVERWRITE $home_changed/bin/idd-codex-issue-watcher.sh"

# Existing recovery without --force: target and recovery are preserved.
home_existing_bak="$TMPROOT/home-existing-bak"
mkdir -p "$home_existing_bak/bin"
printf 'custom watcher v2\n' > "$home_existing_bak/bin/idd-codex-issue-watcher.sh"
printf 'original backup sentinel\n' > "$home_existing_bak/bin/idd-codex-issue-watcher.sh.bak"
run_install_local "$home_existing_bak" "$TMPROOT/existing-bak.log"
assert_file_contains "existing recovery prevents silent overwrite without force (Req 2.4)" \
  "$home_existing_bak/bin/idd-codex-issue-watcher.sh" "custom watcher v2"
assert_file_contains "existing recovery file is preserved without force (Req 2.4)" \
  "$home_existing_bak/bin/idd-codex-issue-watcher.sh.bak" "original backup sentinel"
assert_file_contains "existing recovery skip is operator-visible (Req 2.4 / Req 2.5)" \
  "$TMPROOT/existing-bak.log" "existing .bak found, use --force to overwrite"

# Existing recovery with --force: target is overwritten, recovery remains unchanged.
home_force="$TMPROOT/home-force"
mkdir -p "$home_force/bin"
printf 'custom watcher v3\n' > "$home_force/bin/idd-codex-issue-watcher.sh"
printf 'force backup sentinel\n' > "$home_force/bin/idd-codex-issue-watcher.sh.bak"
run_install_local "$home_force" "$TMPROOT/force.log" --force
assert_true "force refreshes watcher target when recovery already exists (Req 2.4)" \
  cmp -s "$WATCHER_SRC" "$home_force/bin/idd-codex-issue-watcher.sh"
assert_file_contains "force does not overwrite existing recovery file (Req 2.4)" \
  "$home_force/bin/idd-codex-issue-watcher.sh.bak" "force backup sentinel"
assert_file_contains "force logs recovery preservation (Req 2.4)" \
  "$TMPROOT/force.log" "existing .bak preserved even with --force"

# Dry-run: planned backup/overwrite is reported without modifying files.
home_dry="$TMPROOT/home-dry"
mkdir -p "$home_dry/bin"
printf 'dry-run custom watcher\n' > "$home_dry/bin/idd-codex-issue-watcher.sh"
run_install_local "$home_dry" "$TMPROOT/dry.log" --dry-run
assert_file_contains "dry-run keeps existing watcher unchanged (Req 2.5)" \
  "$home_dry/bin/idd-codex-issue-watcher.sh" "dry-run custom watcher"
assert_file_not_exists "dry-run does not create watcher backup file (Req 2.5)" \
  "$home_dry/bin/idd-codex-issue-watcher.sh.bak"
assert_file_contains "dry-run reports backup plan for watcher (Req 2.5)" \
  "$TMPROOT/dry.log" "[DRY-RUN] BACKUP    $home_dry/bin/idd-codex-issue-watcher.sh"
assert_file_contains "dry-run reports overwrite plan for watcher (Req 2.5)" \
  "$TMPROOT/dry.log" "[DRY-RUN] OVERWRITE $home_dry/bin/idd-codex-issue-watcher.sh"

# macOS launchd plist path: fake uname lets the Darwin branch run on any host.
home_plist="$TMPROOT/home-plist"
fake_bin="$TMPROOT/fake-bin"
plist_dest="$home_plist/Library/LaunchAgents/com.local.idd-codex-issue-watcher.plist"
mkdir -p "$(dirname "$plist_dest")"
printf '<plist>operator repo settings</plist>\n' > "$plist_dest"
run_install_local_darwin "$home_plist" "$TMPROOT/plist.log" "$fake_bin"
assert_true "changed launchd plist is backed up before overwrite (Req 2.2 / Req 2.3)" \
  grep -Fq 'operator repo settings' "$plist_dest.bak"
assert_true "changed launchd plist target is refreshed after backup (Req 2.2)" \
  cmp -s "$PLIST_SRC" "$plist_dest"
assert_file_contains "launchd plist backup is operator-visible (Req 2.3 / Req 2.5)" \
  "$TMPROOT/plist.log" "BACKUP    $plist_dest"
assert_file_contains "launchd plist overwrite action is reported (Req 2.5)" \
  "$TMPROOT/plist.log" "OVERWRITE $plist_dest"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
