#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-issue-watcher.sh の Stage C PR 実在 verify ヘルパー
#       (verify_stagec_pr_or_retry) の代替 API 経路 (List Pulls API) fallback
#       経路を、fake gh / fake sleep を注入して end-to-end 検証する
#       スモークテスト。Issue #110 で導入。
#
#       検証観点（Issue #110 Req と対応付け）:
#         - 主経路 5/6 試行目で初めて成功（延長 backoff の効果） (Req 5.2)
#         - 主経路 6 試行全 empty + 代替経路で PR 救済 → 成功 (Req 5.3, 2.1, 2.2, 3.4)
#         - 主経路 6 試行全 empty + 代替経路でも空応答 → codex-failed (Req 5.4, 2.3, 3.3)
#         - 主経路 6 試行全 empty + 代替経路がネットワーク失敗 / 認証失敗 /
#           タイムアウト / 非 0 終了で失敗 → codex-failed (Req 5.5, 2.4)
#         - 主経路で成功した場合は代替経路を呼ばない（Req 2.7）
#         - 代替経路の呼び出しは 1 回限り（Req 2.6）
#         - 代替経路の呼び出しに timeout コマンドを経由する（NFR 1.4 / Req 2.5）
#         - 代替経路の URL に owner プレフィックスが含まれる
#           （`gh api repos/{owner}/{repo}/pulls?head={owner}:BRANCH&state=all`）
#         - リトライ間 sleep は STAGEC_VERIFY_SLEEP_CMD で fake 化し
#           テスト 1 件あたり 30 秒以内に収める（Req 5.8）
#
# 配置先: local-watcher/test/stagec_pr_verify_fallback_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/stagec_pr_verify_fallback_test.sh
# 前提:   外部ネットワークを使わない。`gh` / `sleep` / `timeout` を関数で stub する。
#         GH_TOKEN は不要。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

# idd-codex-issue-watcher.sh から verify_stagec_pr_or_retry の関数定義のみを抽出して
# current shell に load する。トップレベル副作用は回避する。
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
eval "$(extract_function "$WATCHER_SH" "verify_stagec_pr_or_retry")"

if ! declare -F verify_stagec_pr_or_retry >/dev/null; then
  echo "ERROR: verify_stagec_pr_or_retry not loaded from idd-codex-issue-watcher.sh" >&2
  exit 2
fi

# サニティチェック: 代替経路の `gh api repos/.../pulls?head=...&state=all` 呼び出しが
# 実装本体に残っていること（Issue #110 Req 2.1）。`state=all` は高速 merge 済み PR を
# 取りこぼさないための回帰ガード（state=open 固定だと merged PR を見落とす）。
# shellcheck disable=SC2016
if ! grep -q 'gh api "repos/\${REPO}/pulls?head=.*&state=all"' "$WATCHER_SH"; then
  echo "ERROR: idd-codex-issue-watcher.sh に代替 API 経路 (gh api repos/.../pulls?head=...&state=all) が見つからない (Issue #110 Req 2.1)" >&2
  exit 2
fi

# ─── テスト用 fake コマンド・stub ───

# fake sleep（テスト用に no-op として振る舞う / Req 5.8）
export STAGEC_VERIFY_SLEEP_CMD=":"

# fake timeout: 第 1 引数 (秒数) を捨てて残り引数をそのまま実行する。
# timeout 関数を経由したことを検出するため、TIMEOUT_CALL_COUNT_FILE をインクリメントする。
TIMEOUT_CALL_COUNT_FILE=""
timeout() {
  if [ -n "$TIMEOUT_CALL_COUNT_FILE" ]; then
    local tc
    tc=$(cat "$TIMEOUT_CALL_COUNT_FILE")
    echo "$((tc + 1))" > "$TIMEOUT_CALL_COUNT_FILE"
  fi
  shift  # remove timeout 秒数
  "$@"
}

# fake gh: ファイルベースの call counter で GH_RESPONSES の対応 index を返す。
# - GH_RESPONSES[i] が空文字列なら stdout 空 + rc=0
# - "ERR:N" 形式なら stdout 空 + rc=N
# - それ以外の文字列なら stdout に文字列 + rc=0
#
# また、呼び出された gh の最終引数列を $GH_LAST_ARGS_FILE に記録する
# （代替経路の URL/owner 検証用）。
GH_COUNTER_FILE=""
GH_RESPONSES=()
GH_LAST_ARGS_FILE=""
gh() {
  local count
  count=$(cat "$GH_COUNTER_FILE")
  count=$((count + 1))
  echo "$count" > "$GH_COUNTER_FILE"
  local idx=$((count - 1))
  local resp="${GH_RESPONSES[$idx]:-}"
  if [ -n "$GH_LAST_ARGS_FILE" ]; then
    # 引数列を 1 行に詰めて末尾の行で保持
    printf 'CALL[%d]: %s\n' "$count" "$*" >> "$GH_LAST_ARGS_FILE"
  fi
  if [[ "$resp" == ERR:* ]]; then
    local code="${resp#ERR:}"
    return "$code"
  fi
  printf '%s\n' "$resp"
  return 0
}

qa_warn() { :; }
qa_log() { :; }

# 共通 env
NUMBER="110"
REPO="owner/test"
BRANCH="codex/issue-110-impl-foo"
export NUMBER REPO BRANCH

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

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -Fq "$needle"; then
    echo "FAIL: $label"
    echo "  needle: $(printf '%q' "$needle")"
    echo "  in    : $(printf '%q' "$haystack")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

reset_state() {
  GH_COUNTER_FILE=$(mktemp -t gh-counter-XXXXXX)
  echo "0" > "$GH_COUNTER_FILE"
  GH_LAST_ARGS_FILE=$(mktemp -t gh-args-XXXXXX.log)
  TIMEOUT_CALL_COUNT_FILE=$(mktemp -t timeout-count-XXXXXX)
  echo "0" > "$TIMEOUT_CALL_COUNT_FILE"
  GH_RESPONSES=()
  LOG=$(mktemp -t stagec-fallback-XXXXXX.log)
  export LOG GH_COUNTER_FILE GH_LAST_ARGS_FILE TIMEOUT_CALL_COUNT_FILE
}

gh_call_count() {
  cat "$GH_COUNTER_FILE"
}

timeout_call_count() {
  cat "$TIMEOUT_CALL_COUNT_FILE"
}

TEST_START=$(date +%s)

echo "--- verify_stagec_pr_or_retry fallback cases (Issue #110) ---"

# ─────────────────────────────────────────────────────────────────
# Test 1 (#110 Req 5.2): 主経路 5/6 試行目で初めて成功（延長 backoff の効果）
# Issue #108 設計では 4 試行までしかリトライしなかった経路を、Issue #110 で
# 6 試行に延長したことを保証する。
# ─────────────────────────────────────────────────────────────────
reset_state
GH_RESPONSES=("" "" "" "" "https://github.com/owner/test/pull/110")
rc=0
stdout=$(verify_stagec_pr_or_retry "$BRANCH" "$NUMBER") || rc=$?

assert_eq "Test 1 (5 試行目で成功): rc=0 (#110 Req 1.5 / 5.2)" "0" "$rc"
assert_eq "Test 1 (5 試行目で成功): gh 呼出回数=5" "5" "$(gh_call_count)"
assert_eq "Test 1 (5 試行目で成功): stdout に PR URL" \
  "https://github.com/owner/test/pull/110" "$stdout"
LOG_CONTENT=$(cat "$LOG" 2>/dev/null || echo "")
assert_contains "Test 1 (5 試行目で成功): \$LOG に SUCCESS attempt=5/6 (#110 Req 3.2)" \
  "SUCCESS attempt=5/6" "$LOG_CONTENT"
# Req 2.7: 主経路で見つかったので fallback は呼ばれない
assert_not_contains "Test 1 (5 試行目で成功): \$LOG に fallback start なし (#110 Req 2.7)" \
  "fallback start" "$LOG_CONTENT"
rm -f "$LOG"

# ─────────────────────────────────────────────────────────────────
# Test 2 (#110 Req 5.3): 主経路 6 試行全 empty + 代替経路で PR 救済
# Req 2.1 / 2.2 / 3.3 / 3.4: 代替経路成功時の救済ログ
# ─────────────────────────────────────────────────────────────────
reset_state
# 主経路 6 件 empty + 代替経路 1 件で PR URL を返す
GH_RESPONSES=("" "" "" "" "" "" "https://github.com/owner/test/pull/110-rescued")
rc=0
stdout=$(verify_stagec_pr_or_retry "$BRANCH" "$NUMBER") || rc=$?

assert_eq "Test 2 (代替経路で救済): rc=0 (#110 Req 2.2 / 5.3)" "0" "$rc"
assert_eq "Test 2 (代替経路で救済): gh 呼出回数=7 (主経路 6 + 代替経路 1) (#110 Req 2.6)" \
  "7" "$(gh_call_count)"
assert_eq "Test 2 (代替経路で救済): stdout に PR URL" \
  "https://github.com/owner/test/pull/110-rescued" "$stdout"
LOG_CONTENT=$(cat "$LOG" 2>/dev/null || echo "")
# Req 3.3: 代替経路の呼び出し開始ログ
assert_contains "Test 2 (代替経路で救済): \$LOG に fallback start (#110 Req 3.3)" \
  "fallback start (List Pulls API)" "$LOG_CONTENT"
# Req 3.4: 代替経路成功時の rescued ログ
assert_contains "Test 2 (代替経路で救済): \$LOG に fallback SUCCESS rescued (#110 Req 3.4)" \
  "fallback SUCCESS rescued" "$LOG_CONTENT"
assert_contains "Test 2 (代替経路で救済): \$LOG に primary_attempts=6 (#110 Req 3.4)" \
  "primary_attempts=6" "$LOG_CONTENT"
assert_contains "Test 2 (代替経路で救済): \$LOG に救済時の pr_url (#110 Req 3.4)" \
  "pr_url=https://github.com/owner/test/pull/110-rescued" "$LOG_CONTENT"
# Req 3.5: 主経路全失敗 + fallback 成功時には FAILED ログを残さない（成功扱い）
assert_not_contains "Test 2 (代替経路で救済): \$LOG に FAILED 行なし (#110 Req 3.5)" \
  "FAILED after" "$LOG_CONTENT"
# 代替経路の URL に owner プレフィックスが含まれる（Open Question で実装側に
# 委ねられた {owner}:BRANCH 形式 / Req 2.1）
GH_ARGS=$(cat "$GH_LAST_ARGS_FILE" 2>/dev/null || echo "")
assert_contains "Test 2 (代替経路で救済): gh 引数列に List Pulls API URL (#110 Req 2.1)" \
  "repos/owner/test/pulls?head=owner:${BRANCH}" "$GH_ARGS"
assert_contains "Test 2 (代替経路で救済): gh 引数列に api サブコマンド (#110 Req 2.1)" \
  "api repos/owner/test/pulls" "$GH_ARGS"
# NFR 1.4 / Req 2.5: 代替経路も timeout 経由で呼ばれる（主経路 6 + 代替 1 = 7 回 timeout を通る）
assert_eq "Test 2 (代替経路で救済): timeout 呼出回数=7 (主経路 + 代替経路すべて経由) (#110 NFR 1.4)" \
  "7" "$(timeout_call_count)"
rm -f "$LOG"

# ─────────────────────────────────────────────────────────────────
# Test 3 (#110 Req 5.4): 主経路 6 試行全 empty + 代替経路も空応答 → codex-failed
# Req 2.3 / 3.3 / 3.5: 代替経路空応答時の FAILED 終了
# ─────────────────────────────────────────────────────────────────
reset_state
GH_RESPONSES=("" "" "" "" "" "" "")  # 全 7 件 empty
rc=0
stdout=$(verify_stagec_pr_or_retry "$BRANCH" "$NUMBER") || rc=$?

assert_eq "Test 3 (代替経路も空): rc=1 (#110 Req 2.3 / 5.4)" "1" "$rc"
assert_eq "Test 3 (代替経路も空): gh 呼出回数=7" "7" "$(gh_call_count)"
assert_eq "Test 3 (代替経路も空): stdout 空" "" "$stdout"
LOG_CONTENT=$(cat "$LOG" 2>/dev/null || echo "")
assert_contains "Test 3 (代替経路も空): \$LOG に fallback start" \
  "fallback start (List Pulls API)" "$LOG_CONTENT"
assert_contains "Test 3 (代替経路も空): \$LOG に fallback FAILED outcome=empty (#110 Req 3.3)" \
  "fallback FAILED outcome=empty" "$LOG_CONTENT"
assert_contains "Test 3 (代替経路も空): \$LOG に FAILED after 6 attempts + fallback (#110 Req 3.5)" \
  "FAILED after 6 attempts + fallback" "$LOG_CONTENT"
assert_contains "Test 3 (代替経路も空): \$LOG に fallback_outcome=empty (#110 Req 3.5)" \
  "fallback_outcome=empty" "$LOG_CONTENT"
rm -f "$LOG"

# ─────────────────────────────────────────────────────────────────
# Test 4a (#110 Req 5.5): 代替経路が非 0 終了 → codex-failed
# Req 2.4: ネットワーク失敗 / 認証失敗 / 非 0 終了は「PR 不在」と等価
# ─────────────────────────────────────────────────────────────────
reset_state
GH_RESPONSES=("" "" "" "" "" "" "ERR:1")  # 主経路 6 empty + 代替経路 exit 1
rc=0
stdout=$(verify_stagec_pr_or_retry "$BRANCH" "$NUMBER") || rc=$?

assert_eq "Test 4a (代替経路 exit=1): rc=1 (#110 Req 2.4 / 5.5)" "1" "$rc"
assert_eq "Test 4a (代替経路 exit=1): gh 呼出回数=7" "7" "$(gh_call_count)"
LOG_CONTENT=$(cat "$LOG" 2>/dev/null || echo "")
assert_contains "Test 4a (代替経路 exit=1): \$LOG に fallback FAILED outcome=exit=1 (#110 Req 3.3)" \
  "fallback FAILED outcome=exit=1" "$LOG_CONTENT"
assert_contains "Test 4a (代替経路 exit=1): \$LOG に fallback_outcome=exit=1 (#110 Req 3.5)" \
  "fallback_outcome=exit=1" "$LOG_CONTENT"
rm -f "$LOG"

# ─────────────────────────────────────────────────────────────────
# Test 4b (#110 Req 5.5): 代替経路が timeout (rc=124) → codex-failed
# Req 2.4 / 2.5 / NFR 1.4: timeout 上限到達時も「PR 不在」と等価
# ─────────────────────────────────────────────────────────────────
reset_state
GH_RESPONSES=("" "" "" "" "" "" "ERR:124")  # 代替経路 timeout
rc=0
stdout=$(verify_stagec_pr_or_retry "$BRANCH" "$NUMBER") || rc=$?

assert_eq "Test 4b (代替経路 timeout): rc=1 (#110 Req 2.4 / 2.5 / 5.5)" "1" "$rc"
LOG_CONTENT=$(cat "$LOG" 2>/dev/null || echo "")
assert_contains "Test 4b (代替経路 timeout): \$LOG に fallback FAILED outcome=timeout (#110 Req 3.3)" \
  "fallback FAILED outcome=timeout" "$LOG_CONTENT"
assert_contains "Test 4b (代替経路 timeout): \$LOG に fallback_outcome=timeout (#110 Req 3.5)" \
  "fallback_outcome=timeout" "$LOG_CONTENT"
rm -f "$LOG"

# ─────────────────────────────────────────────────────────────────
# Test 4c (#110 Req 5.5): 代替経路が認証失敗相当 (rc=4 / gh CLI の auth error) → codex-failed
# Req 2.4: 認証失敗 / ネットワーク失敗も等価扱い
# ─────────────────────────────────────────────────────────────────
reset_state
GH_RESPONSES=("" "" "" "" "" "" "ERR:4")
rc=0
stdout=$(verify_stagec_pr_or_retry "$BRANCH" "$NUMBER") || rc=$?

assert_eq "Test 4c (代替経路 auth fail rc=4): rc=1 (#110 Req 2.4 / 5.5)" "1" "$rc"
LOG_CONTENT=$(cat "$LOG" 2>/dev/null || echo "")
assert_contains "Test 4c (代替経路 auth fail): \$LOG に fallback FAILED outcome=exit=4 (#110 Req 3.3)" \
  "fallback FAILED outcome=exit=4" "$LOG_CONTENT"
rm -f "$LOG"

# ─────────────────────────────────────────────────────────────────
# Test 5 (#110 Req 2.6): 代替経路の呼び出しは 1 回限り（リトライしない）
# 主経路全 empty + 代替経路 empty で gh 呼出回数が「主経路 6 + 代替 1 = 7」を超えないこと
# ─────────────────────────────────────────────────────────────────
reset_state
# 8 件 empty 用意するが、関数は 7 回しか呼ばないはず
GH_RESPONSES=("" "" "" "" "" "" "" "")
rc=0
stdout=$(verify_stagec_pr_or_retry "$BRANCH" "$NUMBER") || rc=$?

assert_eq "Test 5 (代替経路リトライなし): gh 呼出回数=7 (主経路 6 + 代替 1 のみ) (#110 Req 2.6)" \
  "7" "$(gh_call_count)"
assert_eq "Test 5 (代替経路リトライなし): rc=1" "1" "$rc"
rm -f "$LOG"

# ─────────────────────────────────────────────────────────────────
# Test 6 (#110 Req 5.8 / NFR 1.2 sanity): 実時間待機が走らないこと
# STAGEC_VERIFY_SLEEP_CMD=":" で全テスト 30 秒以内（実 sleep が走ると 135 秒以上経過する）
# ─────────────────────────────────────────────────────────────────
TEST_END=$(date +%s)
ELAPSED=$((TEST_END - TEST_START))
if [ "$ELAPSED" -lt 30 ]; then
  echo "PASS: Test 6 (実時間待機なし): 全テスト経過 ${ELAPSED}s < 30s (#110 Req 5.8)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Test 6 (実時間待機なし): 全テスト経過 ${ELAPSED}s >= 30s (#110 Req 5.8)"
  echo "  STAGEC_VERIFY_SLEEP_CMD の fake 注入が効いていない可能性がある"
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
