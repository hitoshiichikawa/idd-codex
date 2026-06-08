#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-issue-watcher.sh の Quota-Aware Stage Wrapper
#       (qa_run_codex_stage) を fixture で end-to-end 検証する。
#       Issue #104 で導入。
#
#       検証観点（Req と対応付け）:
#         - 現行スキーマ rate_limit_event_v2 検出 → exit 99 + reset_file = epoch
#           (Req 1.1, 1.2, 5.4)
#         - 旧スキーマ rate_limit_event_v1 検出 → exit 99 + reset_file = epoch
#           (Req 2.1, 5.4)
#         - synthetic 429 result（rate_limit_info 同居） → exit 99 + reset_file = epoch
#           (Req 3.1, 3.3, 5.4)
#         - 通常成功（detection なし） → exit 0
#           (Req 3.4)
#         - synthetic 429 のみで reset 不在 → codex_rc 透過 + warn
#           (Req 3.2)
#         - usage-limit fatal + reset あり → exit 99 + reset_file = epoch
#           (Issue #12 Req 1, 2, 3, 6)
#         - usage-limit fatal + reset なし → codex_rc 透過
#           (Issue #12 Option B / Req 4)
#         - opt-out (QUOTA_AWARE_ENABLED!=true) → 素通し
#           (NFR 1.1)
#
# 配置先: local-watcher/test/qa_run_codex_stage_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/qa_run_codex_stage_test.sh
# 前提:   idd-codex-issue-watcher.sh から関数 2 つ（qa_log/qa_warn/qa_error と
#         qa_detect_rate_limit / qa_run_codex_stage）を切り出して読み込む。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
# #177 Part 1 で低レベル共通ユーティリティ（qa_log 等のロガーを含む）は
# modules/core_utils.sh へ分離された。関数抽出の探索元に core_utils.sh も含める。
CORE_UTILS_SH="$SCRIPT_DIR/../bin/modules/core_utils.sh"
# #180 Part 2 で quota 待機制御プロセッサ（qa_detect_rate_limit / qa_run_codex_stage 等）は
# modules/quota-aware.sh へ分離された。関数抽出の探索元に quota-aware.sh も含める。
QUOTA_AWARE_SH="$SCRIPT_DIR/../bin/modules/quota-aware.sh"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/qa_detect_rate_limit"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi
if [ ! -f "$CORE_UTILS_SH" ]; then
  echo "ERROR: cannot find core_utils.sh at $CORE_UTILS_SH" >&2
  exit 2
fi
if [ ! -f "$QUOTA_AWARE_SH" ]; then
  echo "ERROR: cannot find quota-aware.sh at $QUOTA_AWARE_SH" >&2
  exit 2
fi

# 一時 LOG ファイル（qa_run_codex_stage は $LOG に tee する）
TMPDIR_TEST=$(mktemp -d)
LOG="$TMPDIR_TEST/test.log"
export LOG
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# 必要な関数だけを抽出して eval で読み込む。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script" "$CORE_UTILS_SH" "$QUOTA_AWARE_SH"
}

# qa_log / qa_warn / qa_error は qa_run_codex_stage が呼ぶので必ず loaded する
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_log")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_warn")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_error")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_detect_rate_limit")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_extract_usage_limit_reset_epoch")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_run_codex_stage")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "codex_log_detect_529")"

for fn in qa_log qa_warn qa_error qa_detect_rate_limit qa_extract_usage_limit_reset_epoch qa_run_codex_stage codex_log_detect_529; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

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

# fake-codex: fixture を stdout にダンプし、指定された exit code を返す。
# qa_run_codex_stage は "$@" を実行するため、引数として fixture と rc を受け取る。
fake_codex() {
  local fx_path="$1"
  local rc="${2:-0}"
  cat "$fx_path"
  return "$rc"
}

# テスト 1 件を実行する補助関数。
# Args: <test_label> <expected_rc> <expected_reset_file_content> <fixture> [fake_codex_rc] [stage_label]
# QUOTA_AWARE_ENABLED は呼び出し側で export する想定。
run_case() {
  local label="$1"
  local expected_rc="$2"
  local expected_reset="$3"
  local fx="$4"
  local fake_rc="${5:-0}"
  local stage_label="${6:-TestStage}"

  local reset_file
  reset_file=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
  local rc=0
  qa_run_codex_stage "$stage_label" "$reset_file" -- \
    fake_codex "$FIXTURE_DIR/$fx" "$fake_rc" >/dev/null 2>&1 || rc=$?

  local actual_reset
  actual_reset=$(cat "$reset_file" 2>/dev/null || true)
  rm -f "$reset_file" "${reset_file}.detect"

  assert_eq "$label rc" "$expected_rc" "$rc"
  assert_eq "$label reset_file" "$expected_reset" "$actual_reset"
}

# ─── テストケース ───

echo "--- qa_run_codex_stage cases (opt-in) ---"
export QUOTA_AWARE_ENABLED="true"

# Req 1.1, 1.2, 5.4: 現行スキーマ単独 → exit 99 + epoch 永続化
# 注: v2-rate-limit-event-rejected は末尾に reset 無し synthetic 429 を含むが、
# epoch 付き検出を優先採用するため exit 99 + 1778821200 が期待値。
run_case "v2-rate-limit-event-rejected (Req 1.1, 1.2, 5.4)" \
  99 "1778821200" "v2-rate-limit-event-rejected.jsonl" 0

# Req 1.1, 1.3 numeric epoch
run_case "v2-numeric-epoch (Req 1.1, 1.3)" \
  99 "1747375200" "v2-numeric-epoch.jsonl" 0

# Req 1.4: 現行スキーマで reset 欠落 → codex_rc 透過 (fake rc=0) + warn
run_case "v2-no-reset (Req 1.4)" \
  0 "" "v2-no-reset.jsonl" 0

# Req 2.1, 5.4: 旧スキーマ → exit 99 + epoch
run_case "v1-rate-limit-event-exceeded (Req 2.1, 5.4)" \
  99 "1778821200" "v1-rate-limit-event-exceeded.jsonl" 0

# Req 2.2: 旧スキーマ snake-case reset_at
run_case "v1-reset-at-snake (Req 2.2)" \
  99 "1778821200" "v1-reset-at-snake.jsonl" 0

# Req 3.1, 5.4: synthetic 429 (rate_limit_info 同居) → exit 99 + epoch
run_case "synthetic-429-result (Req 3.1, 5.4)" \
  99 "1778821200" "synthetic-429-result.jsonl" 0

# Req 3.2: synthetic 429 単独 + reset 不在 → codex_rc 透過 + warn
run_case "synthetic-429-no-reset (Req 3.2)" \
  0 "" "synthetic-429-no-reset.jsonl" 0

# Req 3.4: 通常成功 → codex_rc=0 透過、reset_file 空
run_case "normal-success (Req 3.4)" \
  0 "" "normal-success.jsonl" 0

# 補助: codex が非 0 で終了する場合は素通し（quota 検出なし時）
run_case "normal-success with codex rc=2 (NFR 1.2 既存 rc 透過)" \
  2 "" "normal-success.jsonl" 2

# Req 5.4: malformed line 混入でも検出を継続
run_case "v2-rate-limit-malformed-line (Req 5.4)" \
  99 "1778821200" "v2-rate-limit-malformed-line.jsonl" 0

usage_reset_epoch=$(qa_extract_usage_limit_reset_epoch "You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Jun 9th, 2026 1:16 AM.")
if [[ "$usage_reset_epoch" =~ ^[0-9]+$ ]]; then
  assert_eq "usage-limit reset parser returns numeric epoch (Issue #12 Req 3, 6)" "true" "true"
else
  assert_eq "usage-limit reset parser returns numeric epoch (Issue #12 Req 3, 6)" "true" "false"
fi

run_case "StageA usage-limit-with-reset → quota wait (Issue #12 Req 1, 6)" \
  99 "$usage_reset_epoch" "usage-limit-with-reset.jsonl" 1 "StageA"

run_case "Reviewer usage-limit-with-reset → quota wait (Issue #12 Req 1, 6)" \
  99 "$usage_reset_epoch" "usage-limit-with-reset.jsonl" 1 "Reviewer-r1-a1"

run_case "Debugger後 Reviewer usage-limit-with-reset → quota wait (Issue #12 Req 1, 6)" \
  99 "$usage_reset_epoch" "usage-limit-with-reset.jsonl" 1 "Reviewer-r3-a1"

run_case "Triage usage-limit-with-reset → quota wait (Issue #12 Req 2, 6)" \
  99 "$usage_reset_epoch" "usage-limit-with-reset.jsonl" 1 "Triage"

run_case "StageC usage-limit-with-reset → quota wait (Issue #12 Req 1, 6)" \
  99 "$usage_reset_epoch" "usage-limit-with-reset.jsonl" 1 "StageC"

run_case "usage-limit-no-reset → codex rc透過 (Issue #12 Option B)" \
  1 "" "usage-limit-no-reset.jsonl" 1 "StageA"

run_case "normal-error with codex rc=1 remains normal failure (Issue #12 Req 5)" \
  1 "" "normal-error.jsonl" 1 "StageA"

# Issue #12 regression guard: 529 Overloaded の既存 detector は維持する。
LOG="$TMPDIR_TEST/overloaded-529.log"
export LOG
run_case "529-overloaded is not reclassified by usage-limit path (Issue #12 regression)" \
  2 "" "529-overloaded.jsonl" 2 "StageA"
_rc_529=0
codex_log_detect_529 "$LOG" || _rc_529=$?
assert_eq "codex_log_detect_529 still detects 529 Overloaded (Issue #12 regression)" "0" "$_rc_529"

echo ""
echo "--- qa_run_codex_stage cases (opt-out) ---"
export QUOTA_AWARE_ENABLED="false"

# NFR 1.1: opt-out 時は tee も解析も走らず素通し
# Req 1.1 / NFR 1.1 で codex_rc を完全透過、reset_file は touch されない
reset_file=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
rm -f "$reset_file"  # opt-out 時は touch されないことを確認するため事前削除
rc=0
qa_run_codex_stage "TestStage" "$reset_file" -- \
  fake_codex "$FIXTURE_DIR/v2-rate-limit-event-rejected.jsonl" 0 >/dev/null 2>&1 || rc=$?
assert_eq "opt-out v2 input rc=0 (NFR 1.1)" "0" "$rc"
if [ ! -e "$reset_file" ]; then
  echo "PASS: opt-out reset_file untouched (NFR 1.1)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: opt-out reset_file unexpectedly created"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# opt-out で codex rc を透過
reset_file=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
rm -f "$reset_file"
rc=0
qa_run_codex_stage "TestStage" "$reset_file" -- \
  fake_codex "$FIXTURE_DIR/normal-success.jsonl" 7 >/dev/null 2>&1 || rc=$?
assert_eq "opt-out preserves codex rc=7 (NFR 1.1, 1.2)" "7" "$rc"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
