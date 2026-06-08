#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-issue-watcher.sh の Reviewer Result Parser
#       (extract_review_result_token / parse_review_result) を fixture で検証する
#       スモークテスト。Issue #63 で導入。
# 配置先: local-watcher/test/parse_review_result_test.sh
# 依存:   bash 4+, awk, grep, diff
# 実行:   bash local-watcher/test/parse_review_result_test.sh
# 前提:   このスクリプトは local-watcher/bin/idd-codex-issue-watcher.sh から
#         Reviewer Result Parser 関連の関数定義 2 つだけを sed で切り出して
#         eval で読み込み、idd-codex-issue-watcher.sh のトップレベル副作用は回避する。
#
# 期待動作: 全 fixture が AC どおりの結果を返せば PASS、1 件でも失敗すれば
#           exit 1 で全体失敗。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/parse_review_result"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

# idd-codex-issue-watcher.sh から該当関数 2 個だけを抽出する。
# awk で「関数開始行」から最初の単独 `}` までを抜き出す（インデント無し close brace を境界とする）。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 関数定義のみを current shell に読み込む。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "extract_review_result_token")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "parse_review_result")"

# サニティチェック: 関数が読み込まれていることを確認。
if ! declare -F extract_review_result_token >/dev/null; then
  echo "ERROR: extract_review_result_token not loaded" >&2
  exit 2
fi
if ! declare -F parse_review_result >/dev/null; then
  echo "ERROR: parse_review_result not loaded" >&2
  exit 2
fi

# ─── アサーションヘルパ ───
PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
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

assert_rc() {
  local label="$1"
  local expected_rc="$2"
  local actual_rc="$3"
  if [ "$expected_rc" -eq "$actual_rc" ]; then
    echo "PASS: $label (rc=$actual_rc)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label (expected rc=$expected_rc, got rc=$actual_rc)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

run_extract() {
  local fx="$1"
  local out rc=0
  out=$(extract_review_result_token "$FIXTURE_DIR/$fx") || rc=$?
  echo "$out"
  return "$rc"
}

run_parse() {
  local fx="$1"
  local out rc=0
  out=$(parse_review_result "$FIXTURE_DIR/$fx") || rc=$?
  printf '%s' "$out"
  return "$rc"
}

# ─── テストケース ───

echo "--- extract_review_result_token cases ---"

# Req 4.4 / NFR 1.3: 既存の末尾独立行 RESULT: approve
out=$(run_extract "tail-approve.txt") || true
assert_eq "tail-approve: token=approve (Req 4.4 / NFR 1.3)" "approve" "$out"

# Req 4.4 / NFR 1.3: 既存の末尾独立行 RESULT: reject
out=$(run_extract "tail-reject.txt") || true
assert_eq "tail-reject: token=reject (Req 4.4 / NFR 1.3)" "reject" "$out"

# Req 1.1 / NFR 1.1: バッククォート付きインライン approve（Issue #52 再現）
out=$(run_extract "inline-approve-backticks.txt") || true
assert_eq "inline-approve-backticks: token=approve (Req 1.1 / NFR 1.1)" "approve" "$out"

# Req 1.2 / NFR 1.2: バッククォート付きインライン reject
out=$(run_extract "inline-reject-backticks.txt") || true
assert_eq "inline-reject-backticks: token=reject (Req 1.2 / NFR 1.2)" "reject" "$out"

# Req 1.3: 複数マッチ時は最後採用（reject → approve, 最後 approve）
out=$(run_extract "multi-last-wins-approve.txt") || true
assert_eq "multi-last-wins-approve: token=approve (Req 1.3)" "approve" "$out"

# Req 1.3: 複数マッチ時は最後採用（approve → reject, 最後 reject）
out=$(run_extract "multi-last-wins-reject.txt") || true
assert_eq "multi-last-wins-reject: token=reject (Req 1.3)" "reject" "$out"

# Req 1.6 / NFR 1.4: RESULT トークンが無いファイル → rc=1
rc=0
out=$(extract_review_result_token "$FIXTURE_DIR/no-result.txt") || rc=$?
assert_rc "no-result: rc=1 (Req 1.6 / NFR 1.4)" 1 "$rc"
assert_eq "no-result: stdout 空 (Req 1.6)" "" "$out"

# Req 1.5: ファイル不存在 → rc=1
rc=0
out=$(extract_review_result_token "$FIXTURE_DIR/__no_such_file__.txt") || rc=$?
assert_rc "missing file: rc=1 (Req 1.5)" 1 "$rc"

# Req 1.7: 大文字混入は不採用（rc=1）
rc=0
out=$(extract_review_result_token "$FIXTURE_DIR/uppercase-no-match.txt") || rc=$?
assert_rc "uppercase-no-match: rc=1 (Req 1.7 lowercase only)" 1 "$rc"
assert_eq "uppercase-no-match: stdout 空 (Req 1.7)" "" "$out"

# Req 1.1: bullet 装飾 (- RESULT: approve)
out=$(run_extract "decorated-bullet-approve.txt") || true
assert_eq "decorated-bullet-approve: token=approve (Req 1.1)" "approve" "$out"

# Req 1.2: blockquote 装飾 (> RESULT: reject)
out=$(run_extract "blockquote-reject.txt") || true
assert_eq "blockquote-reject: token=reject (Req 1.2)" "reject" "$out"

echo ""
echo "--- parse_review_result cases ---"

# Req 2.2: approve 時は categories / targets が空、rc=0
out=$(run_parse "tail-approve.txt") || true
assert_eq "tail-approve: TSV (Req 2.2)" "$(printf 'approve\t\t')" "$out"

# Req 2.1: reject 時に Findings の Category / Target を抽出
out=$(run_parse "reject-with-findings.txt") || true
expected="$(printf 'reject\tAC 未カバー,boundary 逸脱\t1.1,boundary:Watcher')"
assert_eq "reject-with-findings: TSV (Req 2.1)" "$expected" "$out"

# Req 2.1: 既存 tail-reject も同等に Findings を抽出
out=$(run_parse "tail-reject.txt") || true
expected="$(printf 'reject\tAC 未カバー,boundary 逸脱\t1.2,boundary:Watcher')"
assert_eq "tail-reject: TSV (Req 2.1 / Req 4.4 backward compat)" "$expected" "$out"

# Req 1.1 + 2.2: インライン approve でも parse_review_result が成功
out=$(run_parse "inline-approve-backticks.txt") || true
assert_eq "inline-approve-backticks: TSV (Req 1.1 + 2.2)" "$(printf 'approve\t\t')" "$out"

# Req 1.6: RESULT 行なしは rc=2（装飾起因 parse 失敗）
# Issue #296 Req 1.2: ファイル存在下での RESULT 抽出失敗は装飾起因として rc=2 を維持する。
rc=0
out=$(parse_review_result "$FIXTURE_DIR/no-result.txt") || rc=$?
assert_rc "no-result: parse rc=2 (Req 1.6 / Issue #296 Req 1.2 ファイルあり RESULT 欠落 = parse-failed 維持)" 2 "$rc"

# Issue #296 Req 1.1: ファイル不存在は装飾起因 parse 失敗（rc=2）と区別して rc=3 を返す。
# 旧仕様（rc=2）から本要件で rc=3 に変更。`run_reviewer_stage` / `run_per_task_reviewer` 側で
# 同一 round 内 1 回限定リトライを発火させるためのシグナル。
rc=0
out=$(parse_review_result "$FIXTURE_DIR/__no_such_file__.txt") || rc=$?
assert_rc "missing file: parse rc=3 (Issue #296 Req 1.1 ファイル不在 = missing-file rc=3 / 旧 rc=2 から変更)" 3 "$rc"

# Issue #296 Req 5.1 / Req 5.2 / NFR 1.2: 既存装飾耐性パース (#63) のリグレッション防止。
# ファイル存在 + RESULT 行が装飾されている既存ケースは引き続き rc=0 (approve / reject) を返す。
echo ""
echo "--- Issue #296 backward compatibility (decoration parse retention) ---"

rc=0
out=$(parse_review_result "$FIXTURE_DIR/inline-approve-backticks.txt") || rc=$?
assert_rc "decoration approve: parse rc=0 (Issue #296 Req 5.1 / NFR 1.2 装飾耐性パース維持)" 0 "$rc"

rc=0
out=$(parse_review_result "$FIXTURE_DIR/inline-reject-backticks.txt") || rc=$?
assert_rc "decoration reject: parse rc=0 (Issue #296 Req 5.1 / NFR 1.2 装飾耐性パース維持)" 0 "$rc"

rc=0
out=$(parse_review_result "$FIXTURE_DIR/multi-last-wins-approve.txt") || rc=$?
assert_rc "multi-last-wins approve: parse rc=0 (Issue #296 Req 5.2 / NFR 1.2 最後マッチ採用維持)" 0 "$rc"

rc=0
out=$(parse_review_result "$FIXTURE_DIR/multi-last-wins-reject.txt") || rc=$?
assert_rc "multi-last-wins reject: parse rc=0 (Issue #296 Req 5.2 / NFR 1.2 最後マッチ採用維持)" 0 "$rc"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
