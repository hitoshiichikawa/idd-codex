#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-issue-watcher.sh の Stage C PR 実在 verify の
#       retry-with-backoff ヘルパー (verify_stagec_pr_or_retry) を、fake gh と
#       fake sleep を注入して end-to-end 検証するスモークテスト。Issue #108 で導入。
#       Issue #110 で主経路 6 試行 / 代替 API 経路 1 ターンに拡張されたため、本
#       既存テストも新デフォルトに合わせて assertion を更新した。代替経路固有の
#       経路網羅（fallback success / fallback empty / fallback error）は別ファイル
#       stagec_pr_verify_fallback_test.sh で担保する。
#
#       検証観点（Req と対応付け）:
#         - 1 回目の試行で PR URL 取得 → 即時成功 (#108 Req 1.2 / #110 Req 1.4 / 4.6, 5.1)
#         - 1 回目空応答 → 2 回目で URL 取得して成功 (#108 Req 1.3 / #110 Req 1.5, 5.2)
#         - 3 回目で初めて URL 取得して成功 (#108 Req 1.3 / #110 Req 1.5, 5.2)
#         - 主経路 6 回全て空応答 + 代替経路も空応答 → exit 1
#           （呼び出し側で codex-failed 化）(#108 Req 2.1 / #110 Req 2.1 / 2.3, 5.4)
#         - リトライ間 sleep は STAGEC_VERIFY_SLEEP_CMD で fake 化し
#           テスト 1 件あたり 30 秒以内に収める (#108 Req 5.6 / #110 Req 5.8)
#         - 進捗ログが $LOG に試行回数 / Issue 番号 / 対象 branch を伴って
#           記録されること (#108 Req 3.1, 3.2, 3.3 / #110 Req 3.1〜3.5 / NFR 2.1, 2.2)
#
# 配置先: local-watcher/test/stagec_pr_verify_retry_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/stagec_pr_verify_retry_test.sh
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

# ─── テスト用 fake コマンド・stub ───

# fake sleep（テスト用に no-op として振る舞う）。
# STAGEC_VERIFY_SLEEP_CMD env を `:` に向けることで本体の sleep 呼び出しを no-op 化する。
# また `:` は POSIX shell builtin で常に rc=0、引数を捨てる。
export STAGEC_VERIFY_SLEEP_CMD=":"

# fake timeout: 本テストでは timeout を経由せず gh stub の rc / 出力で挙動を制御する。
# verify_stagec_pr_or_retry 内 `command -v timeout` で timeout コマンドの存在を確認するため、
# PATH 上の実 timeout を一旦 hide する形にはせず、shell 関数として override する。
# bash の関数は builtin / external より優先される（ただし `command timeout` 経由では呼ばれない）。
# verify_stagec_pr_or_retry は `command -v timeout` で存在検出して `timeout 15` を実行するので
# 関数で override すれば挙動を差し替えられる。
timeout() {
  # 第 1 引数は秒数。残り全引数を gh コマンドとしてそのまま実行する。
  shift  # remove "15"
  "$@"
}

# fake gh: ファイルベースの call counter を進めて、GH_RESPONSES 配列の対応 index を返す
# - GH_RESPONSES[i] が空文字列なら stdout 空 + rc=0
# - "ERR:N" 形式なら stdout 空 + rc=N
# - それ以外の文字列なら stdout に文字列 + rc=0
#
# 注意: verify_stagec_pr_or_retry の戻り値（PR URL）は $(...) で捕捉するため
# subshell 内で実行される。GH_CALL_COUNT のような shell 変数の更新は parent shell
# へ波及しないため、ファイル ($GH_COUNTER_FILE) で call 回数を持ち回る。
GH_COUNTER_FILE=""
GH_RESPONSES=()
gh() {
  local count
  count=$(cat "$GH_COUNTER_FILE")
  count=$((count + 1))
  echo "$count" > "$GH_COUNTER_FILE"
  local idx=$((count - 1))
  local resp="${GH_RESPONSES[$idx]:-}"
  if [[ "$resp" == ERR:* ]]; then
    local code="${resp#ERR:}"
    return "$code"
  fi
  printf '%s\n' "$resp"
  return 0
}

# qa_warn / qa_log は本関数では呼ばれないが、もし将来追加された場合に備えて safe stub
qa_warn() { :; }
qa_log() { :; }

# 共通 env
NUMBER="108"
REPO="owner/test"
BRANCH="codex/issue-108-impl-foo"
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
  GH_RESPONSES=()
  LOG=$(mktemp -t stagec-retry-XXXXXX.log)
  export LOG GH_COUNTER_FILE
}

gh_call_count() {
  cat "$GH_COUNTER_FILE"
}

# テスト所要時間計測（Req 5.6: テスト 1 件あたり 30 秒以内）
TEST_START=$(date +%s)

echo "--- verify_stagec_pr_or_retry retry cases (Issue #108) ---"

# ─────────────────────────────────────────────────────────────────
# Test 1: 1 回目で PR URL 取得 → 即時成功（Req 1.2 / Req 5.1 / NFR 1.1）
#         本変更前と同様の挙動。$LOG への進捗ログは出さない（外形互換）。
# ─────────────────────────────────────────────────────────────────
reset_state
GH_RESPONSES=("https://github.com/owner/test/pull/108")
rc=0
stdout=$(verify_stagec_pr_or_retry "$BRANCH" "$NUMBER") || rc=$?

assert_eq "Test 1 (1 回目成功): rc=0" "0" "$rc"
assert_eq "Test 1 (1 回目成功): gh 呼出回数=1" "1" "$(gh_call_count)"
assert_eq "Test 1 (1 回目成功): stdout に PR URL" \
  "https://github.com/owner/test/pull/108" "$stdout"
# Req 4.1 / NFR 1.1: 1 回目即時成功は $LOG に進捗ログを出さない（本変更前と外形互換）
LOG_CONTENT=$(cat "$LOG" 2>/dev/null || echo "")
assert_eq "Test 1 (1 回目成功): \$LOG は空（外形互換 / Req 4.1 NFR 1.1）" "" "$LOG_CONTENT"
rm -f "$LOG"

# ─────────────────────────────────────────────────────────────────
# Test 2: 1 回目空応答 → 2 回目で URL 取得して成功
#         (#108 Req 1.3 / Req 5.2 / #110 Req 1.5)
# ─────────────────────────────────────────────────────────────────
reset_state
GH_RESPONSES=("" "https://github.com/owner/test/pull/108")
rc=0
stdout=$(verify_stagec_pr_or_retry "$BRANCH" "$NUMBER") || rc=$?

assert_eq "Test 2 (2 回目で成功): rc=0" "0" "$rc"
assert_eq "Test 2 (2 回目で成功): gh 呼出回数=2" "2" "$(gh_call_count)"
assert_eq "Test 2 (2 回目で成功): stdout に PR URL" \
  "https://github.com/owner/test/pull/108" "$stdout"

LOG_CONTENT=$(cat "$LOG" 2>/dev/null || echo "")
# #108 Req 3.1 / #110 Req 3.1: 試行回数 / Issue 番号 / 対象 branch を含む単一行
assert_contains "Test 2 (2 回目で成功): \$LOG に attempt=1/6 outcome=empty (Req 3.1)" \
  "attempt=1/6 outcome=empty" "$LOG_CONTENT"
assert_contains "Test 2 (2 回目で成功): \$LOG に issue=#108" \
  "issue=#108" "$LOG_CONTENT"
assert_contains "Test 2 (2 回目で成功): \$LOG に対象 branch" \
  "branch=${BRANCH}" "$LOG_CONTENT"
# #108 Req 3.2 / #110 Req 3.2: 成功までに要した試行回数を $LOG に残す
assert_contains "Test 2 (2 回目で成功): \$LOG に SUCCESS attempt=2/6 (Req 3.2)" \
  "SUCCESS attempt=2/6" "$LOG_CONTENT"
# #110 Req 2.7: 主経路で見つかったので代替経路は呼ばれない
assert_not_contains "Test 2 (2 回目で成功): \$LOG に fallback start なし (#110 Req 2.7)" \
  "fallback start" "$LOG_CONTENT"
rm -f "$LOG"

# ─────────────────────────────────────────────────────────────────
# Test 3: 3 回目で初めて URL 取得して成功
#         (#108 Req 1.3 / Req 5.2 / #110 Req 1.5)
# 1, 2 回目で異なる失敗種別（empty / timeout）を発生させて分類ログを検証
# ─────────────────────────────────────────────────────────────────
reset_state
GH_RESPONSES=("" "ERR:124" "https://github.com/owner/test/pull/108")
rc=0
stdout=$(verify_stagec_pr_or_retry "$BRANCH" "$NUMBER") || rc=$?

assert_eq "Test 3 (3 回目で成功): rc=0" "0" "$rc"
assert_eq "Test 3 (3 回目で成功): gh 呼出回数=3" "3" "$(gh_call_count)"
assert_eq "Test 3 (3 回目で成功): stdout に PR URL" \
  "https://github.com/owner/test/pull/108" "$stdout"

LOG_CONTENT=$(cat "$LOG" 2>/dev/null || echo "")
# NFR 2.1: 試行結果の種別（empty / timeout / exit=N）を識別可能に
assert_contains "Test 3 (3 回目で成功): \$LOG に attempt=1/6 outcome=empty (NFR 2.1)" \
  "attempt=1/6 outcome=empty" "$LOG_CONTENT"
assert_contains "Test 3 (3 回目で成功): \$LOG に attempt=2/6 outcome=timeout (NFR 2.1)" \
  "attempt=2/6 outcome=timeout" "$LOG_CONTENT"
assert_contains "Test 3 (3 回目で成功): \$LOG に SUCCESS attempt=3/6 (Req 3.2)" \
  "SUCCESS attempt=3/6" "$LOG_CONTENT"
rm -f "$LOG"

# ─────────────────────────────────────────────────────────────────
# Test 4: 主経路 6 回 + 代替経路すべて空応答 → exit 1
#         (#108 Req 2.1 / Req 5.3 / #110 Req 2.1 / 2.3 / 3.5 / Req 5.4)
# ─────────────────────────────────────────────────────────────────
reset_state
# GH_RESPONSES = 主経路 6 + 代替経路 1 = 7 件全て空応答
GH_RESPONSES=("" "" "" "" "" "" "")
rc=0
stdout=$(verify_stagec_pr_or_retry "$BRANCH" "$NUMBER") || rc=$?

assert_eq "Test 4 (全失敗): rc=1 (#108 Req 2.1 / #110 Req 2.3)" "1" "$rc"
assert_eq "Test 4 (全失敗): gh 呼出回数=7 (主経路 6 + 代替経路 1) (#110 Req 1.2 / 2.6)" \
  "7" "$(gh_call_count)"
assert_eq "Test 4 (全失敗): stdout 空" "" "$stdout"

LOG_CONTENT=$(cat "$LOG" 2>/dev/null || echo "")
# #108 Req 3.1 / #110 Req 3.1: attempt=1..6 すべての進捗が残る
for n in 1 2 3 4 5 6; do
  assert_contains "Test 4 (全失敗): \$LOG に attempt=${n}/6 (Req 3.1)" \
    "attempt=${n}/6 outcome=empty" "$LOG_CONTENT"
done
# #110 Req 3.3: 代替経路の開始と結果が記録される
assert_contains "Test 4 (全失敗): \$LOG に fallback start (#110 Req 3.3)" \
  "fallback start (List Pulls API)" "$LOG_CONTENT"
assert_contains "Test 4 (全失敗): \$LOG に fallback FAILED outcome=empty (#110 Req 3.3)" \
  "fallback FAILED outcome=empty" "$LOG_CONTENT"
# #110 Req 3.5: 最終失敗時に主経路試行回数 / 最終 primary outcome / fallback outcome を残す
assert_contains "Test 4 (全失敗): \$LOG に FAILED after 6 attempts + fallback (#110 Req 3.5)" \
  "FAILED after 6 attempts + fallback" "$LOG_CONTENT"
assert_contains "Test 4 (全失敗): \$LOG に last_primary_outcome=empty (#110 Req 3.5)" \
  "last_primary_outcome=empty" "$LOG_CONTENT"
assert_contains "Test 4 (全失敗): \$LOG に fallback_outcome=empty (#110 Req 3.5)" \
  "fallback_outcome=empty" "$LOG_CONTENT"
# Req 3.5: Issue 番号 / 対象 branch
assert_contains "Test 4 (全失敗): \$LOG に Issue 番号 (Req 3.5)" \
  "issue=#108" "$LOG_CONTENT"
assert_contains "Test 4 (全失敗): \$LOG に対象 branch (Req 3.5)" \
  "branch=${BRANCH}" "$LOG_CONTENT"
# Req 2.2 (#108): 成功ログを出さない
assert_not_contains "Test 4 (全失敗): \$LOG に SUCCESS 行なし (#108 Req 2.2)" \
  "SUCCESS" "$LOG_CONTENT"
rm -f "$LOG"

# ─────────────────────────────────────────────────────────────────
# Test 5: 主経路全試行で非 0 終了混在 + 代替経路も非 0 → exit 1
#         (#108 Req 2.4 / NFR 2.1 / #110 Req 2.4 / 3.5)
# 一時的失敗が混在しても上限まで継続する。
# ─────────────────────────────────────────────────────────────────
reset_state
# 主経路 6 件（exit=1 / empty / timeout 混在）+ 代替経路 1 件（exit=1）
GH_RESPONSES=("ERR:1" "" "ERR:124" "ERR:1" "" "ERR:1" "ERR:1")
rc=0
stdout=$(verify_stagec_pr_or_retry "$BRANCH" "$NUMBER") || rc=$?

assert_eq "Test 5 (失敗種別混在): rc=1 (#108 Req 2.4 / #110 Req 2.4)" "1" "$rc"
assert_eq "Test 5 (失敗種別混在): gh 呼出回数=7 (主経路 6 + 代替経路 1)" \
  "7" "$(gh_call_count)"
LOG_CONTENT=$(cat "$LOG" 2>/dev/null || echo "")
# NFR 2.1: 失敗種別の分類（exit=N / empty / timeout）が事後識別可能
assert_contains "Test 5 (失敗種別混在): \$LOG に outcome=exit=1 (NFR 2.1)" \
  "outcome=exit=1" "$LOG_CONTENT"
assert_contains "Test 5 (失敗種別混在): \$LOG に outcome=empty (NFR 2.1)" \
  "outcome=empty" "$LOG_CONTENT"
assert_contains "Test 5 (失敗種別混在): \$LOG に outcome=timeout (NFR 2.1)" \
  "outcome=timeout" "$LOG_CONTENT"
# #110 Req 3.3: 代替経路の失敗結果が exit=N で残る
assert_contains "Test 5 (失敗種別混在): \$LOG に fallback FAILED outcome=exit=1 (#110 Req 3.3)" \
  "fallback FAILED outcome=exit=1" "$LOG_CONTENT"
rm -f "$LOG"

# ─────────────────────────────────────────────────────────────────
# Test 6: 実時間待機が走らないこと
#         (#108 Req 5.6 / #110 Req 5.8 / テスト 1 件 30 秒以内)
# STAGEC_VERIFY_SLEEP_CMD=":" でテスト全体が（即時実行で）十分高速に完了することを
# 計測で担保。実時間 sleep が走っていれば最低 135 秒（新デフォルト主経路 sleep 合計）
# 以上経過するはず。
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
