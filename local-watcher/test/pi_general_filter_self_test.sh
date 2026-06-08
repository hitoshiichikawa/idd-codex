#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-modules/pr-iteration.sh の PR Iteration 一般コメント
#       自己投稿フィルタ (pi_general_filter_self) を fixture で検証するスモークテスト。
#       Issue #2 で追加。
#
#       検出条件:
#         - `idd-codex:pr-reviewer` marker 付きコメントは残す
#         - `idd-codex:pr-iteration` 系 marker 付きコメントは除外する
#
# 配置先: local-watcher/test/pi_general_filter_self_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/pi_general_filter_self_test.sh
# 前提:   pr-iteration.sh から pi_general_filter_self() のみを awk で切り出して
#         eval で読み込み、トップレベル副作用は回避する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_ITERATION_SH="$SCRIPT_DIR/../bin/idd-codex-modules/pr-iteration.sh"

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
eval "$(extract_function "$PR_ITERATION_SH" "pi_general_filter_self")"

if ! declare -F pi_general_filter_self >/dev/null; then
  echo "ERROR: pi_general_filter_self not loaded" >&2
  exit 2
fi

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

echo "--- pi_general_filter_self cases (Issue #2) ---"

input_json='[
  {
    "id": 1,
    "body": "VERDICT: codex-needs-iteration\n\n<!-- idd-codex:pr-reviewer sha=abc123 kind=impl tool=codex -->"
  },
  {
    "id": 2,
    "body": ":robot: PR Iteration Processor が処理を開始しました\n<!-- idd-codex:pr-iteration-processing round=1 -->"
  },
  {
    "id": 3,
    "body": "manual follow-up without marker"
  },
  {
    "id": 4,
    "body": "legacy body marker\n<!-- idd-codex:pr-iteration round=2 last-run=2026-06-08T12:00:00Z -->"
  },
  {
    "id": 5,
    "body": "quota warning\n<!-- idd-codex:pr-iteration-529-warning round=3 -->"
  }
]'

out=$(printf '%s\n' "$input_json" | pi_general_filter_self)

assert_eq "reviewer marker と manual comment だけが残る" \
  "1,3" \
  "$(printf '%s\n' "$out" | jq -r 'map(.id) | join(",")')"

assert_eq "reviewer verdict comment の本文が保持される" \
  "true" \
  "$(printf '%s\n' "$out" | jq -r 'any(.[]; (.body // "") | contains("VERDICT: codex-needs-iteration"))')"

assert_eq "PR Iteration processing marker は除外される" \
  "false" \
  "$(printf '%s\n' "$out" | jq -r 'any(.[]; (.body // "") | contains("idd-codex:pr-iteration-processing"))')"

assert_eq "PR Iteration body/警告 marker は除外される" \
  "false" \
  "$(printf '%s\n' "$out" | jq -r 'any(.[]; (.body // "") | contains("idd-codex:pr-iteration round=") or contains("idd-codex:pr-iteration-529-warning"))')"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
