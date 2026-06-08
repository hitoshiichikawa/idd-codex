#!/usr/bin/env bash
#
# 用途: PR Iteration の no-progress round が success label transition に進まないことを
#       判定関数レベルで検証するスモークテスト。
#
# 配置先: local-watcher/test/pi_no_progress_transition_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/pi_no_progress_transition_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_ITERATION_SH="$SCRIPT_DIR/../bin/idd-codex-modules/pr-iteration.sh"

if [ ! -f "$PR_ITERATION_SH" ]; then
  echo "ERROR: cannot find pr-iteration.sh at $PR_ITERATION_SH" >&2
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
eval "$(extract_function "$PR_ITERATION_SH" "pi_resolve_success_action")"

if ! declare -F pi_resolve_success_action >/dev/null; then
  echo "ERROR: pi_resolve_success_action not loaded" >&2
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

echo "--- pi_resolve_success_action cases (Issue #3) ---"

assert_eq "Req 1.1 / 1.4: no commit + streak below limit は success ではなく hold" \
  "hold" \
  "$(pi_resolve_success_action false 1 3)"

assert_eq "Req 2.2: 入力コメント final=0 相当で no commit の round も hold" \
  "hold" \
  "$(pi_resolve_success_action false 2 3)"

assert_eq "Req 3.2: no commit + streak reaches limit は escalate" \
  "escalate" \
  "$(pi_resolve_success_action false 3 3)"

assert_eq "Req 3.2 boundary: limit=1 では最初の no-progress round で escalate" \
  "escalate" \
  "$(pi_resolve_success_action false 1 1)"

assert_eq "Req 1.1: commit pushed の round のみ success transition 対象" \
  "success" \
  "$(pi_resolve_success_action true 0 3)"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
