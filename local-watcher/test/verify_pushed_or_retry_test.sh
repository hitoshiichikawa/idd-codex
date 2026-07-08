#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-issue-watcher.sh の Stage A / A' / B 完了直後 push 状態
#       verify ヘルパー (verify_pushed_or_retry) を、ローカル bare repo を fake origin
#       として用いた擬似環境で end-to-end 検証するスモークテスト。Issue #106 で導入。
#
#       検証観点（Req と対応付け）:
#         - ahead == 0 (通常成功) → return 0、副作用なし
#           (Req 1.3, 2.3, 3.3, 5.1, NFR 1.1)
#         - ahead > 0 + 自動 push リトライ成功 → return 0、gh issue comment は
#           投稿しない（#248 で抑止）、成功 info 行に Issue 番号 / stage 識別子 /
#           branch / 復旧 commit 数を含める、mark_issue_failed 未呼出
#           (Req 1.1, 1.2, 1.3, 2.1, 2.2, 2.3, 2.4, NFR 2.1, 2.2, 3.1)
#         - ahead > 0 + 自動 push リトライ失敗 → return 1、mark_issue_failed 呼出、
#           虚偽の成功メッセージなし、stage 識別子が正しく伝搬
#           (Req 1.2, 4.1, 4.4, 4.5, 4.6, NFR 2.3)
#         - stage 識別子 stageA-push-missing / stageA-prime-push-missing /
#           stageB-push-missing が呼び出し側から正しく渡されることを spot-check
#           (Open Question 4 / 既存 stageC-pr-missing との一貫性)
#
# 配置先: local-watcher/test/verify_pushed_or_retry_test.sh
# 依存:   bash 4+, git, awk
# 実行:   bash local-watcher/test/verify_pushed_or_retry_test.sh
# 前提:   外部ネットワークを使わない。fake origin は mktemp 配下の bare repo。
#         GH_TOKEN は不要（gh コマンドを関数で stub する）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
# #177 Part 1 で低レベル共通ユーティリティ（qa_log 等のロガーを含む）は
# modules/core_utils.sh へ分離された。関数抽出の探索元に core_utils.sh も含める。
CORE_UTILS_SH="$SCRIPT_DIR/../bin/idd-codex-modules/core_utils.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi
if [ ! -f "$CORE_UTILS_SH" ]; then
  echo "ERROR: cannot find core_utils.sh at $CORE_UTILS_SH" >&2
  exit 2
fi

# idd-codex-issue-watcher.sh から verify_pushed_or_retry / qa_log / qa_warn / qa_error の
# 関数定義のみを抽出して current shell に load する。トップレベル副作用は回避する。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script" "$CORE_UTILS_SH"
}

# qa_log / qa_warn / qa_error は verify_pushed_or_retry 内部で呼ばれる
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "qa_log")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "qa_warn")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "qa_error")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "verify_pushed_or_retry")"
# ── watcher refactor 追従: verify_pushed_or_retry は push stderr を secure tempfile に取る ──
# extract_function は CORE_UTILS_SH も探索対象に含むため idd_secure_mktemp を抽出できる。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "idd_secure_mktemp")"

for fn in qa_log qa_warn qa_error verify_pushed_or_retry; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded from idd-codex-issue-watcher.sh" >&2
    exit 2
  fi
done

# サニティ: 実装側の verify_pushed_or_retry が想定通り 3 系統の stage 識別子を文字列
# として保有していること（実装が divergent していないか）を grep でチェック。
if ! grep -q "stageA-push-missing" "$WATCHER_SH"; then
  echo "ERROR: idd-codex-issue-watcher.sh に stageA-push-missing 呼出が無い" >&2
  exit 2
fi
if ! grep -q "stageA-prime-push-missing" "$WATCHER_SH"; then
  echo "ERROR: idd-codex-issue-watcher.sh に stageA-prime-push-missing 呼出が無い" >&2
  exit 2
fi
if ! grep -q "stageB-push-missing" "$WATCHER_SH"; then
  echo "ERROR: idd-codex-issue-watcher.sh に stageB-push-missing 呼出が無い" >&2
  exit 2
fi

# ─── 一時環境（bare repo + work repo）構築ヘルパ ───
TMPROOT=$(mktemp -d)
# 0700 / 0000 にした権限を戻してから rm -rf する（chmod 000 した refs が残ると rm に失敗するため）
cleanup() {
  chmod -R u+rwX "$TMPROOT" 2>/dev/null || true
  rm -rf "$TMPROOT" 2>/dev/null || true
}
trap cleanup EXIT

# fake gh: 引数を $LAST_GH_ARGS / $LAST_GH_COMMENT_BODY に保存し、stdout を捨てる
LAST_GH_ARGS=""
LAST_GH_COMMENT_BODY=""
gh() {
  LAST_GH_ARGS="$*"
  # `gh issue comment NUMBER --repo X --body Y` 形式で呼ばれる前提。
  # --body 直後の引数を回収する。
  local prev=""
  for arg in "$@"; do
    if [ "$prev" = "--body" ]; then
      LAST_GH_COMMENT_BODY="$arg"
    fi
    prev="$arg"
  done
  return 0
}

# fake mark_issue_failed: 引数を保存
LAST_MARK_FAILED_STAGE=""
LAST_MARK_FAILED_BODY=""
mark_issue_failed() {
  LAST_MARK_FAILED_STAGE="$1"
  LAST_MARK_FAILED_BODY="$2"
}

# 必須 env vars（verify_pushed_or_retry 本体が参照する）
NUMBER="106"
REPO="owner/test"
LOG="$TMPROOT/test-watcher.log"
: > "$LOG"
export NUMBER REPO LOG

# work / bare repo を新規生成し、branch を 1 commit push 済みの状態にする。
# Stdout に work repo の絶対パスを返す。
setup_work_with_upstream() {
  local case_id="$1"
  local work="$TMPROOT/work-$case_id"
  local bare="$TMPROOT/bare-$case_id.git"

  git init --bare --quiet "$bare"
  git init --quiet "$work"
  (
    cd "$work"
    git config user.email "test@example.com"
    git config user.name "Test"
    git config commit.gpgsign false
    git remote add origin "$bare"
    echo "v0" > a.txt
    git add a.txt
    git commit --quiet -m "init"
    git branch -m work-branch
    git push --quiet -u origin work-branch
  )
  echo "$work"
}

# 追加 commit を 1 件積む（未 push 状態を作る）
add_local_commit() {
  local work="$1"
  local n="${2:-1}"
  (
    cd "$work"
    local i=1
    while [ "$i" -le "$n" ]; do
      echo "extra-$i" >> a.txt
      git add a.txt
      git commit --quiet -m "extra $i"
      i=$((i + 1))
    done
  )
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
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -Fq "$needle"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  needle: $(printf '%q' "$needle")"
    echo "  in    : $(printf '%q' "$haystack")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

reset_state() {
  LAST_GH_ARGS=""
  LAST_GH_COMMENT_BODY=""
  LAST_MARK_FAILED_STAGE=""
  LAST_MARK_FAILED_BODY=""
}

echo "--- verify_pushed_or_retry cases ---"

# ─────────────────────────────────────────────────────────────────
# Case 1: ahead == 0 (通常成功 / Req 1.3, 2.3, 3.3, 5.1, NFR 1.1)
# ─────────────────────────────────────────────────────────────────
WORK=$(setup_work_with_upstream "case1")
reset_state
rc=0
(
  cd "$WORK"
  verify_pushed_or_retry "stageA-push-missing" "work-branch" "Stage A" >/dev/null 2>&1
) || rc=$?
# サブシェルで実行したので global 変数は変わらない。代わりに rc / log を検査する。
assert_eq "Case 1 (ahead==0): rc=0 (Req 1.3, 5.1)" "0" "$rc"

# verify が成功し、副作用がないこと: $LOG に新規行が増えていないことを確認
LOG_SIZE_AHEAD0=$(wc -l < "$LOG" | tr -d ' ')
assert_eq "Case 1 (ahead==0): \$LOG 行数 0（副作用なし / Req 5.1）" "0" "$LOG_SIZE_AHEAD0"

# ─────────────────────────────────────────────────────────────────
# Case 2: ahead > 0 + 自動 push 成功 (Req 1.1, 1.2, 1.3, 2.1〜2.4, NFR 2.1, 2.2, 3.1)
# #248: 成功時の Issue コメント投稿は抑止され、info 行のみが記録される。
# ─────────────────────────────────────────────────────────────────
WORK=$(setup_work_with_upstream "case2")
add_local_commit "$WORK" 2  # 2 commits 未 push
reset_state
: > "$LOG"
rc=0
# サブシェル経由だと gh stub の global 代入が消えるため、cwd を保ったままにする必要がある。
# pushd/popd で cwd を切り替えて global 変数代入を current shell に反映させる。
pushd "$WORK" >/dev/null
verify_pushed_or_retry "stageA-push-missing" "work-branch" "Stage A" >/dev/null 2>&1 || rc=$?
popd >/dev/null

assert_eq "Case 2 (push 成功): rc=0 (Req 1.3)" "0" "$rc"
assert_eq "Case 2 (push 成功): mark_issue_failed 未呼出 (Req 1.4)" "" "$LAST_MARK_FAILED_STAGE"
# #248 Req 1.1: 成功時は Issue コメントを投稿しない（gh stub が一切呼ばれない）
assert_eq "Case 2 (push 成功): gh issue comment 未投稿 / LAST_GH_ARGS 空 (Req 1.1)" \
  "" "$LAST_GH_ARGS"
assert_eq "Case 2 (push 成功): gh comment body 空 (Req 1.1)" \
  "" "$LAST_GH_COMMENT_BODY"

# Req 1.2 / 2.1〜2.4 / NFR 3.1: 成功 info 行が \$LOG に 1 件記録され、その行に
# Issue 番号 / stage 識別子 / branch / 復旧 commit 数（ahead 数）が含まれる。
# 成功 info 行（"自動 push リトライ成功" を含む行）を 1 行だけ抽出して検査する
# （NFR 3.1: 単一行形式で機械的に grep できること）。
SUCCESS_LINE=$(grep "自動 push リトライ成功" "$LOG" || true)
assert_contains "Case 2 (push 成功): 成功 info 行に Issue 番号 #106 (Req 2.1)" \
  "issue=#106" "$SUCCESS_LINE"
assert_contains "Case 2 (push 成功): 成功 info 行に stage 識別子 (Req 2.2)" \
  "stage_id=stageA-push-missing" "$SUCCESS_LINE"
assert_contains "Case 2 (push 成功): 成功 info 行に branch (Req 2.3)" \
  "branch=work-branch" "$SUCCESS_LINE"
assert_contains "Case 2 (push 成功): 成功 info 行に復旧 commit 数 2 (Req 2.4)" \
  "recovered_commits=2" "$SUCCESS_LINE"
# NFR 3.1: 成功 info 行は単一行（複数行に分割しない）
SUCCESS_LINE_COUNT=$(grep -c "自動 push リトライ成功" "$LOG" || true)
assert_eq "Case 2 (push 成功): 成功 info 行は 1 行のみ (NFR 3.1)" "1" "$SUCCESS_LINE_COUNT"
# Req 1.1 補足: 成功 info 行に「push 漏れ」原因示唆文言を含めない
if grep -q "push 漏れ" "$LOG"; then
  echo "FAIL: Case 2 (push 成功): \$LOG に「push 漏れ」誤原因示唆文言が残存 (#248)"
  cat "$LOG" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "PASS: Case 2 (push 成功): \$LOG に「push 漏れ」文言なし (#248)"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

# bare 側に commit が伝播していることを git で確認
BARE_COMMITS=$(git -C "$TMPROOT/bare-case2.git" rev-list --count work-branch)
assert_eq "Case 2 (push 成功): bare 側に 3 commit 到達 (init + extra 2)" \
  "3" "$BARE_COMMITS"

# ─────────────────────────────────────────────────────────────────
# Case 3: ahead > 0 + 自動 push 失敗 (Req 4.1, 4.4, 4.5, NFR 2.3)
# bare repo の権限を奪う形で push を失敗させる（chmod 0 で書き込み不可）
# ─────────────────────────────────────────────────────────────────
WORK=$(setup_work_with_upstream "case3")
add_local_commit "$WORK" 1
# bare repo を壊して push を失敗させる
chmod -R 000 "$TMPROOT/bare-case3.git/refs" 2>/dev/null || true

reset_state
: > "$LOG"
rc=0
pushd "$WORK" >/dev/null
verify_pushed_or_retry "stageA-prime-push-missing" "work-branch" "Stage A'" >/dev/null 2>&1 || rc=$?
popd >/dev/null

# 後片付け前に権限を戻す
chmod -R 755 "$TMPROOT/bare-case3.git/refs" 2>/dev/null || true

assert_eq "Case 3 (push 失敗): rc=1 (Req 4.5)" "1" "$rc"
assert_eq "Case 3 (push 失敗): mark_issue_failed stage 識別子 (Req 4.4)" \
  "stageA-prime-push-missing" "$LAST_MARK_FAILED_STAGE"
assert_contains "Case 3 (push 失敗): mark_issue_failed body に対象 branch (NFR 2.3)" \
  "work-branch" "$LAST_MARK_FAILED_BODY"
assert_contains "Case 3 (push 失敗): mark_issue_failed body に commit 数 (NFR 2.3)" \
  "未 push commit 数: 1" "$LAST_MARK_FAILED_BODY"

# 「Stage A' 完了」相当の成功ログを出力していないこと（Req 4.5）
if grep -q "Stage A' 完了" "$LOG"; then
  echo "FAIL: Case 3: 虚偽の成功メッセージが \$LOG に出力された (Req 4.5)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "PASS: Case 3: 虚偽の成功メッセージなし (Req 4.5)"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

# ─────────────────────────────────────────────────────────────────
# Case 4: stage 識別子の多様性チェック（stageB-push-missing も伝搬できる）
# ─────────────────────────────────────────────────────────────────
WORK=$(setup_work_with_upstream "case4")
add_local_commit "$WORK" 1
chmod -R 000 "$TMPROOT/bare-case4.git/refs" 2>/dev/null || true

reset_state
: > "$LOG"
rc=0
pushd "$WORK" >/dev/null
verify_pushed_or_retry "stageB-push-missing" "work-branch" "Stage B (round=1 approve)" >/dev/null 2>&1 || rc=$?
popd >/dev/null

chmod -R 755 "$TMPROOT/bare-case4.git/refs" 2>/dev/null || true

assert_eq "Case 4 (Stage B 識別子): rc=1" "1" "$rc"
assert_eq "Case 4 (Stage B 識別子): mark_issue_failed stage" \
  "stageB-push-missing" "$LAST_MARK_FAILED_STAGE"
# Req 3.4: review-notes.md 識別ログ粒度。stage_label が log に出力されることで担保。
if grep -q "Stage B (round=1 approve)" "$LOG"; then
  echo "PASS: Case 4: \$LOG に Stage B round 識別子 (Req 3.4)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Case 4: \$LOG に Stage B round 識別子が無い"
  cat "$LOG" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
