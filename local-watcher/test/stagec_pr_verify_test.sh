#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-issue-watcher.sh の Stage C 完了処理に追加された
#       「PR 実在 verify」分岐 (Issue #104 Bug 3 / Req 4.1〜4.4) を
#       fake gh と fake mark_issue_failed で検証するスモークテスト。
#
#       検証観点（Req と対応付け）:
#         - PR 実在ありなら成功 echo + return 0      (Req 4.1, 4.3)
#         - PR 不在（gh OK + 空文字）なら codex-failed 化 (Req 4.2)
#         - gh 失敗（rc != 0）なら codex-failed 化 (Req 4.4)
#
# 配置先: local-watcher/test/stagec_pr_verify_test.sh
# 依存:   bash 4+
# 実行:   bash local-watcher/test/stagec_pr_verify_test.sh
# 前提:   このスクリプトは idd-codex-issue-watcher.sh の Stage C `case 0)` ブロックを
#         意味的に再現した小ルーチンを評価する（ソース全体を eval すると
#         グローバル副作用が走るため、対象ブロックの仕様を最小再現で検証）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

# スモークテストのスコープ: Stage C 完了 case 0) ブロック内の PR 実在 verify ロジック。
# 直接 `qa_run_codex_stage` の呼び出し直後 case "$_qa_rc_c" in 0) を切り出すと
# run_impl_pipeline 関数全体に依存してしまうため、本テストでは仕様レベルの再現
# 関数 `_test_stagec_complete` を定義して同じロジックパスを評価する。
#
# 本仕様再現が idd-codex-issue-watcher.sh と divergent しないよう、idd-codex-issue-watcher.sh 側の
# 該当ブロック（grep で "stageC-pr-missing" を含む行が存在することで担保）を
# サニティチェックする。
if ! grep -q "stageC-pr-missing" "$WATCHER_SH"; then
  echo "ERROR: idd-codex-issue-watcher.sh に stageC-pr-missing ハンドラが見つからない" >&2
  exit 2
fi
# Issue #108: 元々の inline `gh pr view --repo "$REPO" --head "$BRANCH"` 呼び出しは
# verify_stagec_pr_or_retry ヘルパーに置き換えられた。サニティチェックは
# (a) 新ヘルパー関数定義と (b) Stage C 完了時の呼び出し配線、(c) ヘルパー内部の
# gh pr view --head 呼び出し（PR URL 取得ロジック）が残っていることを確認する。
if ! grep -q "verify_stagec_pr_or_retry()" "$WATCHER_SH"; then
  echo "ERROR: idd-codex-issue-watcher.sh に verify_stagec_pr_or_retry 定義が見つからない (Issue #108)" >&2
  exit 2
fi
# 単一引用符内の \$ は文字列リテラル "$BRANCH" / "$NUMBER" を grep するためのもので、
# 展開抑止が意図的（shellcheck SC2016 は false positive のため抑止）。
# shellcheck disable=SC2016
if ! grep -q 'verify_stagec_pr_or_retry "\$BRANCH" "\$NUMBER"' "$WATCHER_SH"; then
  echo "ERROR: idd-codex-issue-watcher.sh に verify_stagec_pr_or_retry の呼び出し配線が見つからない (Issue #108)" >&2
  exit 2
fi
# 同上（"$REPO" / "$branch" の文字列リテラルを grep する）
# shellcheck disable=SC2016
if ! grep -q 'gh pr view --repo "\$REPO" --head "\$branch"' "$WATCHER_SH"; then
  echo "ERROR: idd-codex-issue-watcher.sh に PR 実在 verify (gh pr view --head) が見つからない" >&2
  exit 2
fi

# 仕様再現: 実装の Stage C `case 0)` ブロックと等価ロジック。
# fake gh / fake mark_issue_failed / fake echo で副作用を全テストプロセスに閉じ込める。
_test_stagec_complete() {
  local _qa_reset_file_c="/tmp/qa-reset-stagec-test"  # 削除対象だけのダミー
  : > "$_qa_reset_file_c"

  rm -f "$_qa_reset_file_c"
  local _stagec_pr_url _stagec_verify_rc=0
  _stagec_pr_url=$(gh pr view --repo "$REPO" --head "$BRANCH" \
                      --json url --jq '.url' 2>/dev/null) || _stagec_verify_rc=$?
  if [ "$_stagec_verify_rc" -eq 0 ] && [ -n "$_stagec_pr_url" ]; then
    echo "Stage C 完了 / PR 作成済み"
    return 0
  fi
  echo "Stage C 完了報告だが対応 PR 不在 verify_rc=$_stagec_verify_rc"
  mark_issue_failed "stageC-pr-missing" "PR 不在のため失敗"
  return 1
}

# fake mark_issue_failed: 引数を $LAST_MARK_FAILED_STAGE / $LAST_MARK_FAILED_BODY に保存
mark_issue_failed() {
  LAST_MARK_FAILED_STAGE="$1"
  LAST_MARK_FAILED_BODY="$2"
}

# fake gh: 実装は test ごとに上書きする
gh() { :; }

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

# 共通 env（実装側の echo / qa_warn は本テストの仕様再現関数に含めていないため
# NUMBER は未参照になる。実装側ログのフォーマットには含まれることを覚書として残す）
# shellcheck disable=SC2034
NUMBER="123"
REPO="owner/test"
BRANCH="codex/issue-123-impl-foo"
LOG="/tmp/test-watcher.log"
: > "$LOG"

# ─── テストケース ───

echo "--- Stage C PR verify cases ---"

# Req 4.1, 4.3: gh が PR URL を返す → return 0
gh() {
  # gh pr view --repo X --head Y --json url --jq '.url'
  echo "https://github.com/owner/test/pull/45"
  return 0
}
LAST_MARK_FAILED_STAGE=""
# shellcheck disable=SC2034  # 本テストでは body は未検証だが将来検証用に保持
LAST_MARK_FAILED_BODY=""
rc=0
# サブシェル経由（$()）だと global 代入が消えるため、リダイレクト経由で stdout を捨て
# call は current shell で実行する
_test_stagec_complete >/dev/null 2>&1 || rc=$?
assert_eq "PR 実在あり: rc=0 (Req 4.1, 4.3)" "0" "$rc"
assert_eq "PR 実在あり: mark_issue_failed 未呼出 (Req 4.3)" "" "$LAST_MARK_FAILED_STAGE"

# Req 4.2: gh は成功 (rc=0) だが URL が空（--head に対応 PR が無い） → codex-failed
gh() {
  # gh は対応 PR 無しでも成功で終了するが --jq '.url' が空文字列 / null になる
  # （gh pr view は head に該当 PR が無いと exit 1 を返すケースもあるが、
  # gh 1.x の挙動差を吸収するため空文字 + 成功も同等に扱う）
  echo ""
  return 0
}
LAST_MARK_FAILED_STAGE=""
# shellcheck disable=SC2034  # 本テストでは body は未検証だが将来検証用に保持
LAST_MARK_FAILED_BODY=""
rc=0
# サブシェル経由（$()）だと global 代入が消えるため、リダイレクト経由で stdout を捨て
# call は current shell で実行する
_test_stagec_complete >/dev/null 2>&1 || rc=$?
assert_eq "PR 不在 (空 URL): rc=1 (Req 4.2)" "1" "$rc"
assert_eq "PR 不在 (空 URL): mark_issue_failed 呼出 (Req 4.2)" "stageC-pr-missing" "$LAST_MARK_FAILED_STAGE"

# Req 4.4: gh が非 0 終了 (API 障害シミュレーション) → codex-failed
gh() {
  return 1
}
LAST_MARK_FAILED_STAGE=""
# shellcheck disable=SC2034  # 本テストでは body は未検証だが将来検証用に保持
LAST_MARK_FAILED_BODY=""
rc=0
# サブシェル経由（$()）だと global 代入が消えるため、リダイレクト経由で stdout を捨て
# call は current shell で実行する
_test_stagec_complete >/dev/null 2>&1 || rc=$?
assert_eq "gh 失敗 (rc=1): _test_stagec_complete rc=1 (Req 4.4)" "1" "$rc"
assert_eq "gh 失敗 (rc=1): mark_issue_failed 呼出 (Req 4.4)" "stageC-pr-missing" "$LAST_MARK_FAILED_STAGE"

# Req 4.4: gh が timeout 相当の rc=124 → codex-failed
gh() {
  return 124
}
LAST_MARK_FAILED_STAGE=""
# shellcheck disable=SC2034  # 本テストでは body は未検証だが将来検証用に保持
LAST_MARK_FAILED_BODY=""
rc=0
# サブシェル経由（$()）だと global 代入が消えるため、リダイレクト経由で stdout を捨て
# call は current shell で実行する
_test_stagec_complete >/dev/null 2>&1 || rc=$?
assert_eq "gh timeout (rc=124): _test_stagec_complete rc=1 (Req 4.4)" "1" "$rc"
assert_eq "gh timeout (rc=124): mark_issue_failed 呼出 (Req 4.4)" "stageC-pr-missing" "$LAST_MARK_FAILED_STAGE"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
