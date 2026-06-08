#!/usr/bin/env bash
#
# 本テストの fake 依存ヘルパ（sc_log / sc_warn / stage_checkpoint_find_impl_pr / gh）は
# eval で読み込んだ stage_c_existing_pr_guard から間接的にのみ呼ばれるため unreachable
# 扱いになり、env var（REPO / BRANCH / LABEL_NEEDS_DECISIONS / STAGE_CHECKPOINT_ENABLED）も
# eval 済み関数内でのみ参照されるため unused 扱いになる。いずれも false positive のため
# ファイル全体で抑止する（既存 stagec_pr_verify_test.sh / parse_review_result_test.sh と
# 同じ扱い）。本ディレクティブは shebang 直後（先頭コメントブロック内）に置くことで
# file-wide に適用される。
# shellcheck disable=SC2317,SC2034
#
# 用途: local-watcher/bin/idd-codex-issue-watcher.sh の Stage C 既存 PR 冪等ガード
#       (stage_c_existing_pr_guard, Issue #212) を fake gh / fake
#       stage_checkpoint_find_impl_pr で検証するスモークテスト。
#
#       検証観点（Requirement と対応付け）:
#         - OPEN 検出   → 作成抑止 (return 0) / ログ出力 / Issue コメント無 (Req 2.1〜2.4)
#         - MERGED 検出 → 着地済み停止 (return 0) / ログ出力 / Issue コメント無 (Req 3.1〜3.4)
#         - CLOSED 検出 → 作成抑止 (return 0) / codex-needs-decisions 付与 / コメント 1 件
#                         / codex-failed 不付与 (Req 4.1〜4.5)
#         - none (rc=1) → 作成方向 (return 1) / 副作用無 (Req 5.1, 5.2)
#         - gh API エラー (rc=2) → 作成方向 (return 1) / 警告ログ (Req 6.1〜6.3)
#         - STAGE_CHECKPOINT_ENABLED!=true → no-op (return 1) / 副作用無 (Req 1.2 / NFR 1.2)
#
# 配置先: local-watcher/test/stage_c_existing_pr_guard_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/stage_c_existing_pr_guard_test.sh
# 前提:   idd-codex-issue-watcher.sh から stage_c_existing_pr_guard 定義のみを awk で抽出し
#         eval で current shell に読み込む（トップレベル副作用を回避）。
#         依存ヘルパ（sc_log / sc_warn / stage_checkpoint_find_impl_pr / gh）は
#         テスト側で fake を定義してロジックパスのみを評価する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

# idd-codex-issue-watcher.sh から該当関数 1 個だけを抽出する。
# awk で「関数開始行」から最初の単独 `}`（インデント無し close brace）までを抜き出す。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "stage_c_existing_pr_guard")"

# サニティチェック: 関数が読み込まれていることを確認。
if ! declare -F stage_c_existing_pr_guard >/dev/null; then
  echo "ERROR: stage_c_existing_pr_guard not loaded" >&2
  exit 2
fi

# サニティチェック: call site の配線（idd-codex-issue-watcher.sh 側）が残っていること。
if ! grep -q "stage_c_existing_pr_guard" "$WATCHER_SH"; then
  echo "ERROR: idd-codex-issue-watcher.sh に stage_c_existing_pr_guard の配線が見つからない (Issue #212)" >&2
  exit 2
fi

# ─── fake 依存ヘルパ ───
# sc_log / sc_warn: 実装は `>> "$LOG"` でリダイレクトされるため、ここでは stdout に
# 出した内容をテスト側でリダイレクト先に集約する（呼び出し側で >> "$LOG" される）。
sc_log()  { echo "stage-checkpoint: $*"; }
sc_warn() { echo "stage-checkpoint: WARN: $*"; }

# stage_checkpoint_find_impl_pr: テストごとに override する。既定は「なし」。
stage_checkpoint_find_impl_pr() { return 1; }

# fake gh: 呼び出し記録用。引数を GH_CALLS に追記。
GH_CALLS=()
gh() {
  GH_CALLS+=("$*")
  return 0
}

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
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "PASS: $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
    *)
      echo "FAIL: $label"
      echo "  expected to contain: $(printf '%q' "$needle")"
      echo "  actual            : $(printf '%q' "$haystack")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
  esac
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "FAIL: $label"
      echo "  expected NOT to contain: $(printf '%q' "$needle")"
      echo "  actual                : $(printf '%q' "$haystack")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
    *)
      echo "PASS: $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
  esac
}

# 共通 env
# shellcheck disable=SC2034  # LOG は実装側の `>> "$LOG"` で参照される
NUMBER="212"
REPO="owner/test"
BRANCH="codex/issue-212-impl-foo"
LABEL_NEEDS_DECISIONS="codex-needs-decisions"
LOG="/tmp/test-stage-c-guard.log"

# 1 ケースを実行するヘルパ:
#   $1=label-prefix を返す。stdout(ログ)を $GUARD_LOG に、return code を $GUARD_RC に、
#   gh 呼び出しを ${GH_CALLS}（配列）に集約する。
run_guard() {
  GH_CALLS=()
  : > "$LOG"
  GUARD_RC=0
  # current shell で実行し global 副作用（GH_CALLS）を保持。stdout(=sc_log) は $LOG へ。
  stage_c_existing_pr_guard || GUARD_RC=$?
  GUARD_LOG="$(cat "$LOG")"
}

echo "--- Stage C existing-PR guard cases (Issue #212) ---"

# ───────────────────────────────────────────────────────────────
# Req 2: OPEN 検出 → 作成抑止 (return 0) / ログ / Issue コメント無
# ───────────────────────────────────────────────────────────────
STAGE_CHECKPOINT_ENABLED="true"
stage_checkpoint_find_impl_pr() { echo "210,OPEN"; return 0; }
run_guard
assert_eq        "OPEN: return 0 (Req 2.1, 2.2)"          "0" "$GUARD_RC"
assert_contains  "OPEN: ログに state=OPEN (Req 2.3)"       "$GUARD_LOG" "state=OPEN"
assert_contains  "OPEN: ログに PR 番号 210 (Req 2.3)"      "$GUARD_LOG" "210,OPEN"
assert_eq        "OPEN: gh 未呼出（コメント無 / Req 2.4）" "0" "${#GH_CALLS[@]}"

# ───────────────────────────────────────────────────────────────
# Req 3: MERGED 検出 → 着地済み停止 (return 0) / ログ / Issue コメント無
# ───────────────────────────────────────────────────────────────
STAGE_CHECKPOINT_ENABLED="true"
stage_checkpoint_find_impl_pr() { echo "208,MERGED"; return 0; }
run_guard
assert_eq        "MERGED: return 0 (Req 3.1, 3.2)"          "0" "$GUARD_RC"
assert_contains  "MERGED: ログに state=MERGED (Req 3.3)"    "$GUARD_LOG" "state=MERGED"
assert_contains  "MERGED: ログに PR 番号 208 (Req 3.3)"     "$GUARD_LOG" "208,MERGED"
assert_eq        "MERGED: gh 未呼出（コメント無 / Req 3.4）" "0" "${#GH_CALLS[@]}"

# ───────────────────────────────────────────────────────────────
# Req 4: CLOSED 検出 → 作成抑止 + codex-needs-decisions + コメント 1 件 / codex-failed 不付与
# ───────────────────────────────────────────────────────────────
STAGE_CHECKPOINT_ENABLED="true"
stage_checkpoint_find_impl_pr() { echo "209,CLOSED"; return 0; }
run_guard
assert_eq        "CLOSED: return 0 (Req 4.5)"               "0" "$GUARD_RC"
assert_contains  "CLOSED: ログに state=CLOSED (NFR 3.1)"    "$GUARD_LOG" "state=CLOSED"
# gh は 2 回呼ばれる: issue edit --add-label, issue comment
assert_eq        "CLOSED: gh 2 回呼出 (Req 4.2, 4.3)"       "2" "${#GH_CALLS[@]}"
GH_JOINED="${GH_CALLS[*]}"
assert_contains  "CLOSED: codex-needs-decisions 付与 (Req 4.2)"   "$GH_JOINED" "--add-label codex-needs-decisions"
assert_contains  "CLOSED: issue comment 投稿 (Req 4.3)"     "$GH_JOINED" "issue comment 212"
assert_not_contains "CLOSED: codex-failed 不付与 (Req 4.4)" "$GH_JOINED" "codex-failed"

# ───────────────────────────────────────────────────────────────
# Req 5: none (rc=1) → 作成方向 (return 1) / 副作用無
# ───────────────────────────────────────────────────────────────
STAGE_CHECKPOINT_ENABLED="true"
stage_checkpoint_find_impl_pr() { return 1; }
run_guard
assert_eq        "none: return 1（作成方向 / Req 5.1）"      "1" "$GUARD_RC"
assert_eq        "none: gh 未呼出（副作用無 / Req 5.2）"     "0" "${#GH_CALLS[@]}"
assert_eq        "none: ログ無（副作用無 / Req 5.2）"        ""  "$GUARD_LOG"

# ───────────────────────────────────────────────────────────────
# Req 6: gh API エラー (rc=2) → 作成方向 (return 1) / 警告ログ
# ───────────────────────────────────────────────────────────────
STAGE_CHECKPOINT_ENABLED="true"
stage_checkpoint_find_impl_pr() { return 2; }
run_guard
assert_eq        "API エラー: return 1（作成方向 / Req 6.2）" "1" "$GUARD_RC"
assert_contains  "API エラー: 警告ログ出力 (Req 6.1)"        "$GUARD_LOG" "WARN:"
assert_contains  "API エラー: 二重 PR 可能性を明示 (Req 6.3)" "$GUARD_LOG" "二重 PR"
assert_eq        "API エラー: gh 未呼出（観測のみ）"          "0" "${#GH_CALLS[@]}"

# ───────────────────────────────────────────────────────────────
# Req 1.2 / NFR 1.2: STAGE_CHECKPOINT_ENABLED!=true → no-op (return 1)
# 既存 PR が OPEN であっても観測すらせず作成方向へ抜ける。
# ───────────────────────────────────────────────────────────────
stage_checkpoint_find_impl_pr() { echo "210,OPEN"; return 0; }

STAGE_CHECKPOINT_ENABLED="false"
run_guard
assert_eq        "gate=false: return 1（no-op / Req 1.2）"   "1" "$GUARD_RC"
assert_eq        "gate=false: gh 未呼出（副作用無 / NFR 1.2）" "0" "${#GH_CALLS[@]}"
assert_eq        "gate=false: ログ無（副作用無 / NFR 1.2）"   ""  "$GUARD_LOG"

STAGE_CHECKPOINT_ENABLED="anything-else"
run_guard
assert_eq        "gate=任意値: return 1（no-op / Req 1.2）"   "1" "$GUARD_RC"
assert_eq        "gate=任意値: gh 未呼出（NFR 1.2）"          "0" "${#GH_CALLS[@]}"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
