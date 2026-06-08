#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-issue-watcher.sh の PR Iteration 用 quota 警告検知関数
#       (pi_detect_quota_soft_fail) を fixture で検証するスモークテスト。
#       Issue #118 で導入。
#
#       検出条件:
#         - type == "rate_limit_event"
#         - status == "allowed_warning"（top-level または rate_limit_info ネスト位置）
#         - surpassedThreshold >= 0.9（top-level または rate_limit_info ネスト位置）
#
# 配置先: local-watcher/test/pi_detect_quota_soft_fail_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/pi_detect_quota_soft_fail_test.sh
# 前提:   idd-codex-issue-watcher.sh から pi_detect_quota_soft_fail() のみを awk で切り出して
#         eval で読み込み、トップレベル副作用は回避する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/pi_detect_quota_soft_fail"
# #181 Part 3 で PR Iteration Processor の関数群（pi_detect_quota_soft_fail ほか）は
# modules/pr-iteration.sh へ切り出された。抽出元を本体から pr-iteration.sh へ repoint する。
PR_ITERATION_SH="$SCRIPT_DIR/../bin/idd-codex-modules/pr-iteration.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi
if [ ! -f "$PR_ITERATION_SH" ]; then
  echo "ERROR: cannot find pr-iteration.sh at $PR_ITERATION_SH" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 2
fi

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
eval "$(extract_function "$PR_ITERATION_SH" "pi_detect_quota_soft_fail")"

if ! declare -F pi_detect_quota_soft_fail >/dev/null; then
  echo "ERROR: pi_detect_quota_soft_fail not loaded" >&2
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

detect_all() {
  local fx="$1"
  pi_detect_quota_soft_fail < "$FIXTURE_DIR/$fx"
}

detect_last_line() {
  local fx="$1"
  pi_detect_quota_soft_fail < "$FIXTURE_DIR/$fx" | tail -n 1
}

# ─── テストケース ───

echo "--- pi_detect_quota_soft_fail cases (Issue #118 Req 1.1) ---"

# Req 1.1: status と surpassedThreshold が top-level にある現代スキーマ →
# rate_limit_warning + threshold 値を出力
out=$(detect_last_line "allowed-warning-top-level.jsonl")
assert_eq "Req 1.1: top-level status/threshold で検出" \
  "$(printf 'rate_limit_warning\t0.9')" \
  "$out"

# Req 1.1: status と surpassedThreshold が rate_limit_info ネスト位置にあるスキーマ →
# 同様に検出
out=$(detect_last_line "allowed-warning-nested.jsonl")
assert_eq "Req 1.1: rate_limit_info ネスト位置でも検出" \
  "$(printf 'rate_limit_warning\t0.95')" \
  "$out"

# Req 1.1: surpassedThreshold が 0.9 未満 → 検出しない（境界値）
out=$(detect_all "allowed-warning-below-threshold.jsonl")
assert_eq "Req 1.1: surpassedThreshold < 0.9 は検出しない" "" "$out"

# Req 1.1 / Req 5.3: status=rejected は本関数の対象外（dispatcher 連携を避ける）
out=$(detect_all "rejected-not-warning.jsonl")
assert_eq "Req 5.3: status=rejected は pi_detect_quota_soft_fail では検出しない" "" "$out"

# Req 1.1: 通常の成功 stream には検出ゼロ
out=$(detect_all "normal-success.jsonl")
assert_eq "NFR 1.1: 通常成功 stream は検出ゼロ" "" "$out"

# NFR resilience: 不正 JSON 行が混入しても以降の検出を継続する
# （`qa_detect_rate_limit` と同じ try/catch 設計）
out=$(detect_last_line "allowed-warning-malformed-line.jsonl")
assert_eq "NFR resilience: 不正行を skip して後続を検出" \
  "$(printf 'rate_limit_warning\t0.92')" \
  "$out"

echo ""

# ─── pi_branch_is_codex_pr_head の確認 ───
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_SH" "pi_branch_is_codex_pr_head")"

if ! declare -F pi_branch_is_codex_pr_head >/dev/null; then
  echo "ERROR: pi_branch_is_codex_pr_head not loaded" >&2
  exit 2
fi

echo "--- pi_branch_is_codex_pr_head cases (Issue #118 Req 3.2 / 3.4) ---"

rc=0; pi_branch_is_codex_pr_head "codex/issue-118-impl-foo" || rc=$?
assert_eq "Req 3.2: codex/issue-<N>-<slug> は一致 (return 0)" "0" "$rc"

rc=0; pi_branch_is_codex_pr_head "codex/issue-42-design-bar" || rc=$?
assert_eq "Req 3.2: codex/issue-<N>-design-... も一致" "0" "$rc"

rc=0; pi_branch_is_codex_pr_head "main" || rc=$?
assert_eq "Req 3.4: main は不一致 (return 1)" "1" "$rc"

rc=0; pi_branch_is_codex_pr_head "develop" || rc=$?
assert_eq "Req 3.4: develop は不一致" "1" "$rc"

rc=0; pi_branch_is_codex_pr_head "hitoshi/manual-work" || rc=$?
assert_eq "Req 3.4: 人間の作業 branch は不一致" "1" "$rc"

rc=0; pi_branch_is_codex_pr_head "codex/no-issue-prefix" || rc=$?
assert_eq "Req 3.4: codex/ で始まっても issue-<N>- がなければ不一致" "1" "$rc"

rc=0; pi_branch_is_codex_pr_head "" || rc=$?
assert_eq "NFR safety: 空文字列は不一致" "1" "$rc"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
