#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-issue-watcher.sh の動的モジュールローダ
#       （REQUIRED_MODULES / IDD_MODULE_DIR 解決）が、必須モジュール欠落時に
#       欠落モジュール名を含むエラーを標準エラー出力へ出し exit 1 で安全停止する
#       ことを検証するスモークテスト。Issue #180 Part 2 で導入。
#
#       検証観点（Req と対応付け）:
#         - 必須モジュール欠落時に exit 1（silent fail させない）
#           (Req 4.4 / NFR 3.1)
#         - エラーメッセージが欠落モジュール名（quota-aware.sh）を含む
#           (Req 4.4 / NFR 3.1)
#         - 欠落検知はローカル作業ディレクトリに依存せずスクリプトディレクトリ基準で
#           解決される（cwd 非依存 / Req 4.2）
#         - 全モジュールが揃っている場合は欠落エラーを出さずローダを通過する
#           (Req 4.1, 4.3)
#
# 配置先: local-watcher/test/module_loader_missing_test.sh
# 依存:   bash 4+
# 実行:   bash local-watcher/test/module_loader_missing_test.sh
# 前提:   idd-codex-issue-watcher.sh 本体と idd-codex-modules/ 一式を一時ディレクトリへコピーし、
#         BASH_SOURCE 基準のローダが一時コピー側の idd-codex-modules/ を解決することを利用する。
#         ローダは flock / cd "$REPO_DIR" / git fetch より前に走るため、欠落時は
#         git・ロック等の副作用に到達せず exit 1 する。本体側の実 idd-codex-modules/ は
#         一切変更しない（一時コピーのみ操作する）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/../bin"
WATCHER_SH="$BIN_DIR/idd-codex-issue-watcher.sh"
MODULES_DIR="$BIN_DIR/idd-codex-modules"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi
if [ ! -d "$MODULES_DIR" ]; then
  echo "ERROR: cannot find idd-codex-modules dir at $MODULES_DIR" >&2
  exit 2
fi

# ─── アサーションヘルパ ───
PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected: $(printf '%q' "$expected")"
    echo "  actual  : $(printf '%q' "$actual")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -Fq -- "$needle"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  needle: $(printf '%q' "$needle")"
    echo "  in    : $(printf '%q' "$haystack")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -Fq -- "$needle"; then
    echo "FAIL: $label"
    echo "  unexpected needle: $(printf '%q' "$needle")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

# 一時ディレクトリに本体 + idd-codex-modules/ をコピーする。
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
cp "$WATCHER_SH" "$TMPROOT/idd-codex-issue-watcher.sh"
mkdir -p "$TMPROOT/idd-codex-modules"
cp "$MODULES_DIR"/*.sh "$TMPROOT/idd-codex-modules/"

# watcher 本体は loader 到達前に必須コマンドの存在も検査する。モジュール欠落の
# テストに絞るため、一時 PATH に副作用のない stub を置く。
FAKEBIN="$TMPROOT/fakebin"
mkdir -p "$FAKEBIN"
for cmd in gh jq git flock codex; do
  {
    printf '#!/usr/bin/env bash\n'
    printf 'exit 0\n'
  } > "$FAKEBIN/$cmd"
  chmod +x "$FAKEBIN/$cmd"
done
{
  printf '#!/usr/bin/env bash\n'
  printf 'shift\n'
  printf 'exec "$@"\n'
} > "$FAKEBIN/timeout"
chmod +x "$FAKEBIN/timeout"
FAKE_PATH="$FAKEBIN:$PATH"

# ローダ通過後の処理（flock / cd "$REPO_DIR" / git）に到達しないよう、欠落ケースは
# 欠落により exit 1 する。全モジュール存在ケースはローダを通過した後、後続の git
# 操作で失敗しうるが、本テストは「欠落エラーが出ないこと」のみを検証対象とする
# （cd 先を存在しないパスにし、ローダ通過後すぐ非ローダ要因で停止させる）。

echo "--- module loader missing-module cases (Req 4.2, 4.4, NFR 3.1) ---"

# ─────────────────────────────────────────────────────────────────
# Case 1: quota-aware.sh を欠落させる → exit 1 + 欠落名を含む stderr
# cwd 非依存を担保するため、watcher のあるディレクトリとは別の cwd から起動する。
# ─────────────────────────────────────────────────────────────────
rm -f "$TMPROOT/idd-codex-modules/quota-aware.sh"

OTHER_CWD=$(mktemp -d)
rc=0
OUT=$(cd "$OTHER_CWD" && REPO=owner/test REPO_DIR=/tmp/idd-loader-test-nonexistent \
  PATH="$FAKE_PATH" \
  bash "$TMPROOT/idd-codex-issue-watcher.sh" 2>&1) || rc=$?
rmdir "$OTHER_CWD" 2>/dev/null || true

assert_eq "Case 1: 欠落モジュールで exit 1 (Req 4.4 / NFR 3.1)" "1" "$rc"
assert_contains "Case 1: stderr に欠落モジュール名 quota-aware.sh (Req 4.4 / NFR 3.1)" \
  "quota-aware.sh" "$OUT"
assert_contains "Case 1: stderr に新 module directory idd-codex-modules (Req 2.4 / NFR 3.1)" \
  "idd-codex-modules" "$OUT"
assert_contains "Case 1: stderr に '必須モジュールが見つかりません' (NFR 3.1)" \
  "必須モジュールが見つかりません" "$OUT"

# ─────────────────────────────────────────────────────────────────
# Case 2: merge-queue.sh を欠落させる → 欠落名は merge-queue.sh
# ─────────────────────────────────────────────────────────────────
# quota-aware.sh を戻し、別のモジュールを欠落させる
cp "$MODULES_DIR/quota-aware.sh" "$TMPROOT/idd-codex-modules/quota-aware.sh"
rm -f "$TMPROOT/idd-codex-modules/merge-queue.sh"

rc=0
OUT=$(REPO=owner/test REPO_DIR=/tmp/idd-loader-test-nonexistent \
  PATH="$FAKE_PATH" \
  bash "$TMPROOT/idd-codex-issue-watcher.sh" 2>&1) || rc=$?

assert_eq "Case 2: 別モジュール欠落でも exit 1" "1" "$rc"
assert_contains "Case 2: stderr に欠落モジュール名 merge-queue.sh" \
  "merge-queue.sh" "$OUT"
# 欠落していない quota-aware.sh のエラーは出ないこと（欠落検知が正しい対象を指す）
assert_not_contains "Case 2: 健全な quota-aware.sh は欠落エラーに含まれない" \
  "quota-aware.sh" "$OUT"

# ─────────────────────────────────────────────────────────────────
# Case 3: core_utils.sh 欠落 + shared modules/core_utils.sh 存在
# → shared modules/ へ fallback せず、_slot_run_issue 到達前に exit 1
# ─────────────────────────────────────────────────────────────────
cp "$MODULES_DIR/merge-queue.sh" "$TMPROOT/idd-codex-modules/merge-queue.sh"
mkdir -p "$TMPROOT/modules"
{
  printf 'echo "SHARED_MODULE_SOURCED"\n'
  printf '_worktree_inject_claude() { :; }\n'
  printf '_slot_run_issue() { echo "SHARED_SLOT_RUN_ISSUE"; }\n'
} > "$TMPROOT/modules/core_utils.sh"
rm -f "$TMPROOT/idd-codex-modules/core_utils.sh"

rc=0
OUT=$(REPO=owner/test REPO_DIR=/tmp/idd-loader-test-nonexistent \
  PATH="$FAKE_PATH" \
  bash "$TMPROOT/idd-codex-issue-watcher.sh" 2>&1) || rc=$?

assert_eq "Case 3: core_utils.sh 欠落で exit 1 (Req 2.4 / Req 4.2)" "1" "$rc"
assert_contains "Case 3: stderr に欠落モジュール名 core_utils.sh" \
  "core_utils.sh" "$OUT"
assert_contains "Case 3: stderr に専用 module directory idd-codex-modules" \
  "idd-codex-modules" "$OUT"
assert_not_contains "Case 3: shared modules/core_utils.sh は source されない" \
  "SHARED_MODULE_SOURCED" "$OUT"
assert_not_contains "Case 3: shared modules の _slot_run_issue へ到達しない" \
  "SHARED_SLOT_RUN_ISSUE" "$OUT"

# ─────────────────────────────────────────────────────────────────
# Case 4: 全モジュールが揃っている → ローダ起因の欠落エラーは出さない
# （後続の git 失敗等で非 0 終了しうるが、欠落メッセージは出ない）
# ─────────────────────────────────────────────────────────────────
cp "$MODULES_DIR/core_utils.sh" "$TMPROOT/idd-codex-modules/core_utils.sh"

rc=0
OUT=$(REPO=owner/test REPO_DIR=/tmp/idd-loader-test-nonexistent \
  PATH="$FAKE_PATH" \
  bash "$TMPROOT/idd-codex-issue-watcher.sh" 2>&1) || rc=$?

assert_not_contains "Case 4: 全モジュール存在時はローダ欠落エラーを出さない (Req 4.1, 4.3)" \
  "必須モジュールが見つかりません" "$OUT"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
