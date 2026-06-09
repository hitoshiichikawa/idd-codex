#!/usr/bin/env bash
#
# 用途: install.sh --local が stale installed watcher を現行版で上書きし、
#       idd-codex 専用 module directory を $HOME/bin/idd-codex-modules/ に配置することを検証する。
# 配置先: local-watcher/test/install_local_namespace_test.sh
# 依存: bash 4+, cmp, find
# 実行: bash local-watcher/test/install_local_namespace_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
WATCHER_SRC="$REPO_ROOT/local-watcher/bin/idd-codex-issue-watcher.sh"
MODULES_SRC="$REPO_ROOT/local-watcher/bin/idd-codex-modules"

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

assert_file_not_contains() {
  local label="$1" path="$2" needle="$3"
  if [ -f "$path" ] && grep -Fq -- "$needle" "$path"; then
    echo "FAIL: $label"
    echo "  path: $path"
    echo "  unexpected needle: $needle"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

TMP_HOME=$(mktemp -d)
trap 'rm -rf "$TMP_HOME"' EXIT

mkdir -p "$TMP_HOME/bin/modules"

# stale installed watcher: #14 以前の shared modules layout を模した最小ファイル。
{
  printf '#!/usr/bin/env bash\n'
  # shellcheck disable=SC2016  # stale watcher fixture として実行時展開される literal を書き込む
  printf 'IDD_MODULE_DIR="$HOME/bin/modules"\n'
  # shellcheck disable=SC2016  # stale watcher fixture として実行時展開される literal を書き込む
  printf '. "$IDD_MODULE_DIR/core_utils.sh"\n'
} > "$TMP_HOME/bin/idd-codex-issue-watcher.sh"
chmod +x "$TMP_HOME/bin/idd-codex-issue-watcher.sh"

# idd-claude 風 shared module。install.sh --local が触らないことを sentinel で検証する。
{
  printf '#!/usr/bin/env bash\n'
  printf '# idd-claude sentinel\n'
  printf '_worktree_inject_claude() { :; }\n'
} > "$TMP_HOME/bin/modules/core_utils.sh"
shared_before=$(cat "$TMP_HOME/bin/modules/core_utils.sh")

HOME="$TMP_HOME" "$INSTALL_SH" --local >/tmp/idd-codex-install-local-namespace-test.log

assert_true "stale installed watcher is overwritten with repo watcher (Req 1.1 / Req 4.1)" \
  cmp -s "$WATCHER_SRC" "$TMP_HOME/bin/idd-codex-issue-watcher.sh"
assert_file_contains "installed watcher references idd-codex-modules (Req 1.3 / Req 2.1)" \
  "$TMP_HOME/bin/idd-codex-issue-watcher.sh" "idd-codex-modules"
assert_file_not_contains "installed watcher does not reference shared HOME modules (Req 1.4 / Req 2.2)" \
  "$TMP_HOME/bin/idd-codex-issue-watcher.sh" 'HOME/bin/modules'
assert_true "core_utils.sh is installed under idd-codex-modules (Req 1.2)" \
  test -f "$TMP_HOME/bin/idd-codex-modules/core_utils.sh"
assert_true "shared modules/core_utils.sh is not overwritten (Req 1.4 / Req 2.2)" \
  test "$shared_before" = "$(cat "$TMP_HOME/bin/modules/core_utils.sh")"

missing_modules=""
while IFS= read -r src; do
  name="$(basename "$src")"
  if [ ! -f "$TMP_HOME/bin/idd-codex-modules/$name" ]; then
    missing_modules="${missing_modules:+$missing_modules }$name"
  fi
done < <(find "$MODULES_SRC" -maxdepth 1 -type f -name '*.sh' | sort)

assert_true "all repo idd-codex-modules/*.sh are installed under HOME idd-codex-modules (Req 1.2 / Req 4.4)" \
  test -z "$missing_modules"
assert_true "install.sh --local does not add idd-codex files to shared HOME modules (Req 1.4 / Req 2.2)" \
  test "$(find "$TMP_HOME/bin/modules" -maxdepth 1 -type f | wc -l | tr -d ' ')" = "1"

HOME="$TMP_HOME" "$INSTALL_SH" --local >/tmp/idd-codex-install-local-namespace-test-rerun.log
assert_file_contains "repeated install keeps watcher aligned with idd-codex-modules loader (NFR 1.3)" \
  "$TMP_HOME/bin/idd-codex-issue-watcher.sh" "idd-codex-modules"
assert_true "repeated install still leaves shared modules/core_utils.sh untouched (NFR 2.1)" \
  test "$shared_before" = "$(cat "$TMP_HOME/bin/modules/core_utils.sh")"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
