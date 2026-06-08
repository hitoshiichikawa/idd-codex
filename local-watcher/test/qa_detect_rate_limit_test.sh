#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-issue-watcher.sh の Quota-Aware 検出関数
#       (qa_detect_rate_limit) を fixture で検証するスモークテスト。
#       Issue #104 で導入。
#
#       検出経路:
#         - rate_limit_event_v2  : 現行スキーマ（rate_limit_info.status==rejected）
#         - rate_limit_event_v1  : 旧スキーマ（top-level status==exceeded）
#         - synthetic_429_result : type==result/is_error==true/api_error_status==429
#
# 配置先: local-watcher/test/qa_detect_rate_limit_test.sh
# 依存:   bash 4+, awk, jq, diff
# 実行:   bash local-watcher/test/qa_detect_rate_limit_test.sh
# 前提:   このスクリプトは local-watcher/bin/idd-codex-issue-watcher.sh から
#         qa_detect_rate_limit 関数 1 つだけを sed で切り出して eval で読み込み、
#         idd-codex-issue-watcher.sh のトップレベル副作用は回避する。
#
# 期待動作: 全 fixture が Req どおりの結果を返せば PASS、1 件でも失敗すれば
#           exit 1 で全体失敗。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
# #180 Part 2 で qa_detect_rate_limit は modules/quota-aware.sh へ分離された。
# 関数抽出の探索元に quota-aware.sh も含める。
QUOTA_AWARE_SH="$SCRIPT_DIR/../bin/modules/quota-aware.sh"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/qa_detect_rate_limit"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi
if [ ! -f "$QUOTA_AWARE_SH" ]; then
  echo "ERROR: cannot find quota-aware.sh at $QUOTA_AWARE_SH" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 2
fi

# idd-codex-issue-watcher.sh / modules から qa_detect_rate_limit() のみを抽出する。
# awk で「関数開始行」から最初の単独 `}` までを抜き出す。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script" "$QUOTA_AWARE_SH"
}

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "qa_detect_rate_limit")"

if ! declare -F qa_detect_rate_limit >/dev/null; then
  echo "ERROR: qa_detect_rate_limit not loaded" >&2
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

# fixture を qa_detect_rate_limit に流し、最終検出行（または "$path<TAB>$epoch"）を返す。
# 検出が無ければ空文字列を返す。
detect_last_line() {
  local fx="$1"
  qa_detect_rate_limit < "$FIXTURE_DIR/$fx" | tail -n 1
}

# 検出全行を返す（複数検出を assert したい時用）。
detect_all_lines() {
  local fx="$1"
  qa_detect_rate_limit < "$FIXTURE_DIR/$fx"
}

# ─── テストケース ───

echo "--- qa_detect_rate_limit cases ---"

# Req 1.1, 1.3: 現行スキーマ（rate_limit_info.status=rejected, ISO 8601 reset） →
#               rate_limit_event_v2 + epoch
# 注: このフィクスチャは末尾に synthetic 429 result も含み、result 行に rate_limit_info
# は付かない（実 CLI 挙動の代表ケース）。tail -1 は synthetic_429_result + 空 epoch。
out=$(detect_last_line "v2-rate-limit-event-rejected.jsonl")
assert_eq "v2-rate-limit-event-rejected (tail-1) (Req 3.1, 3.2)" \
  "$(printf 'synthetic_429_result\t')" \
  "$out"

all=$(detect_all_lines "v2-rate-limit-event-rejected.jsonl" | tr '\n' ';')
assert_eq "v2-rate-limit-event-rejected (all) (Req 1.1, 1.3, 3.1)" \
  "rate_limit_event_v2	1778821200;synthetic_429_result	;" \
  "$all"

# Req 1.1: numeric epoch（ネスト位置にある数値型 reset 値）も受理する
out=$(detect_last_line "v2-numeric-epoch.jsonl")
assert_eq "v2-numeric-epoch (Req 1.1, 1.3)" \
  "$(printf 'rate_limit_event_v2\t1747375200')" \
  "$out"

# Req 1.4: 現行スキーマで reset 時刻が欠落 → path のみ、epoch 空
out=$(detect_last_line "v2-no-reset.jsonl")
assert_eq "v2-no-reset (Req 1.4)" \
  "$(printf 'rate_limit_event_v2\t')" \
  "$out"

# Req 2.1: 旧スキーマ（top-level status==exceeded） → rate_limit_event_v1 + epoch
out=$(detect_last_line "v1-rate-limit-event-exceeded.jsonl")
assert_eq "v1-rate-limit-event-exceeded (Req 2.1)" \
  "$(printf 'rate_limit_event_v1\t1778821200')" \
  "$out"

# Req 2.2: 旧スキーマで reset_at（snake case）も受理する
out=$(detect_last_line "v1-reset-at-snake.jsonl")
assert_eq "v1-reset-at-snake (Req 2.2)" \
  "$(printf 'rate_limit_event_v1\t1778821200')" \
  "$out"

# Req 3.1: synthetic 429 result（rate_limit_info 同居） → synthetic_429_result + epoch
out=$(detect_last_line "synthetic-429-result.jsonl")
assert_eq "synthetic-429-result (Req 3.1)" \
  "$(printf 'synthetic_429_result\t1778821200')" \
  "$out"

# Req 3.2: synthetic 429 result で reset 不在 → path のみ、epoch 空
out=$(detect_last_line "synthetic-429-no-reset.jsonl")
assert_eq "synthetic-429-no-reset (Req 3.2)" \
  "$(printf 'synthetic_429_result\t')" \
  "$out"

# Req 3.4: 通常 result（is_error:false） + allowed の rate_limit_event は検出されない
out=$(detect_last_line "normal-success.jsonl")
assert_eq "normal-success (Req 3.4)" "" "$out"

# Req 5.1〜5.4: 解析失敗の混入行があっても以後の検出は継続する（既存 Req 2.5 互換）
out=$(detect_last_line "v2-rate-limit-malformed-line.jsonl")
assert_eq "v2-rate-limit-malformed-line (Req 5.4 / NFR resilience)" \
  "$(printf 'rate_limit_event_v2\t1778821200')" \
  "$out"

# Issue #12: Codex CLI の usage-limit fatal message は usage_limit_fatal として検出する。
# 自然言語 reset 時刻の epoch 化は qa_run_codex_stage 側で行うため、detector は message を
# 第 3 フィールドに保持する。
out=$(detect_last_line "usage-limit-with-reset.jsonl")
assert_eq "usage-limit-with-reset path (Issue #12 Req 6)" \
  "usage_limit_fatal" \
  "$(printf '%s\n' "$out" | awk -F '\t' '{print $1}')"
assert_eq "usage-limit-with-reset detector epoch is empty before wrapper parse (Issue #12 Req 6)" \
  "" \
  "$(printf '%s\n' "$out" | awk -F '\t' '{print $2}')"
message_field="$(printf '%s\n' "$out" | awk -F '\t' '{print $3}')"
if printf '%s\n' "$message_field" | grep -q "You've hit your usage limit" \
   && printf '%s\n' "$message_field" | grep -q "try again at "; then
  assert_eq "usage-limit-with-reset message retained (Issue #12 Req 6)" "true" "true"
else
  assert_eq "usage-limit-with-reset message retained (Issue #12 Req 6)" "true" "false"
fi

out=$(detect_last_line "usage-limit-no-reset.jsonl")
assert_eq "usage-limit-no-reset path (Issue #12 Option B)" \
  "usage_limit_fatal" \
  "$(printf '%s\n' "$out" | awk -F '\t' '{print $1}')"
assert_eq "usage-limit-no-reset detector epoch empty (Issue #12 Option B)" \
  "" \
  "$(printf '%s\n' "$out" | awk -F '\t' '{print $2}')"

out=$(detect_last_line "normal-error.jsonl")
assert_eq "normal-error is not quota-related (Issue #12 Req 5)" "" "$out"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
