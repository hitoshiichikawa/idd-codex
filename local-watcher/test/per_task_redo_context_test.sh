#!/usr/bin/env bash
#
# 用途: per-task retry 用 Reviewer / Debugger context 抽出 helper を検証する。
#       Issue #37 task 1 で導入。
#
# 配置先: local-watcher/test/per_task_redo_context_test.sh
# 依存:   bash 4+, awk, grep, sed
# 実行:   bash local-watcher/test/per_task_redo_context_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
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
eval "$(extract_function "$WATCHER_SH" "pt_regex_escape")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_extract_review_reject_context")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_extract_debugger_task_section")"

if ! declare -F pt_extract_review_reject_context >/dev/null; then
  echo "ERROR: pt_extract_review_reject_context not loaded" >&2
  exit 2
fi
if ! declare -F pt_extract_debugger_task_section >/dev/null; then
  echo "ERROR: pt_extract_debugger_task_section not loaded" >&2
  exit 2
fi

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
  if grep -Fq -- "$needle" <<<"$haystack"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  needle: $(printf '%q' "$needle")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -Fq -- "$needle" <<<"$haystack"; then
    echo "FAIL: $label"
    echo "  unexpected needle: $(printf '%q' "$needle")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

assert_rc() {
  local label="$1" expected_rc="$2" actual_rc="$3"
  if [ "$expected_rc" -eq "$actual_rc" ]; then
    echo "PASS: $label (rc=$actual_rc)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label (expected rc=$expected_rc, got rc=$actual_rc)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

review_notes="$TMPROOT/review-notes.md"
approve_notes="$TMPROOT/review-approve.md"
invalid_review_notes="$TMPROOT/review-invalid.md"
debugger_notes="$TMPROOT/debugger-notes.md"
invalid_debugger_notes="$TMPROOT/debugger-invalid.md"

cat >"$review_notes" <<'EOF'
# Review Notes

<!-- idd-codex:review round=2 -->

## Findings

### Finding 1
- **Target**: 5.2
- **Category**: missing test
- **Detail**: Req 5.2 の shell fixture が round 1 から未追加のままです。
- **Required Action**: local-watcher/test/per_task_redo_context_test.sh に Req 5.2 の assertion を追加する。

### Finding 2
- **Target**: 5.3（必須）
- **Category**: missing test
- **Detail**: Req 5.3 の Finding Closure Matrix prompt contract が検証されていません。
- **Required Action**: rejected target requirement / fix commit / test/assertion / verification result の文言を検証する。

## Summary

Req 5.2 / 5.3 の missing test が残っています。

RESULT: reject
EOF

cat >"$approve_notes" <<'EOF'
# Review Notes

## Findings

なし。

RESULT: approve
EOF

cat >"$invalid_review_notes" <<'EOF'
# Review Notes

## Findings

### Finding 1
- **Target**: 5.2
- **Category**: missing test
- **Detail**: Required Action が欠落しています。

RESULT: reject
EOF

cat >"$debugger_notes" <<'EOF'
# Debugger Notes (Issue #37)

## Task 1.1

### 根本原因

Req 5.2 / 5.3 の round 2 reject context が redo prompt に渡っていません。

### 修正手順

1. Reviewer Findings を抽出する。
2. Debugger Fix Plan を retry prompt に渡す。

### 検証方法

per_task_redo_context_test.sh で Task 1.1 section だけが抽出されることを確認する。

### 関連参考資料

- Related: #23

## Task 2

### 根本原因

このセクションは抽出されてはいけません。
EOF

cat >"$invalid_debugger_notes" <<'EOF'
# Debugger Notes (Issue #37)

## Task 1.1

### 根本原因

検証方法セクションが欠落しています。

### 修正手順

修正手順のみ。

### 関連参考資料

- Related: #23
EOF

echo "--- reviewer reject context extractor ---"

rc=0
out=$(pt_extract_review_reject_context "1" "2" "$review_notes" 2>"$TMPROOT/review.err") || rc=$?
assert_rc "Reviewer reject context extraction succeeds" 0 "$rc"
assert_contains "Reviewer context includes task ID" "Task ID: \`1\`" "$out"
assert_contains "Reviewer context includes round" "Reviewer round: \`2\`" "$out"
assert_contains "Reviewer context includes Req 5.2 target" "Target=\`5.2\`" "$out"
assert_contains "Reviewer context includes Req 5.3 target without Japanese suffix" "Target=\`5.3\`" "$out"
assert_contains "Reviewer context includes missing test category" "Category=\`missing test\`" "$out"
assert_contains "Reviewer context includes Required Action" 'Required Action=local-watcher/test/per_task_redo_context_test.sh に Req 5.2 の assertion を追加する。' "$out"
assert_contains "Reviewer context keeps raw Findings section" '## Findings' "$out"

rc=0
out=$(pt_extract_review_reject_context "1" "1" "$approve_notes" 2>"$TMPROOT/approve.err") || rc=$?
assert_rc "Reviewer approve notes are rejected as redo context" 1 "$rc"
assert_contains "approve diagnostic identifies result-not-reject" 'reason=result-not-reject' "$(cat "$TMPROOT/approve.err")"
assert_eq "approve failure has empty stdout" "" "$out"

rc=0
out=$(pt_extract_review_reject_context "1" "1" "$invalid_review_notes" 2>"$TMPROOT/invalid-review.err") || rc=$?
assert_rc "Reviewer context fails when Required Action is missing" 1 "$rc"
assert_contains "invalid review diagnostic identifies parse failure" 'reason=finding-field-parse-failed' "$(cat "$TMPROOT/invalid-review.err")"
assert_eq "invalid review failure has empty stdout" "" "$out"

echo ""
echo "--- debugger task section extractor ---"

rc=0
out=$(pt_extract_debugger_task_section "1.1" "$debugger_notes" 2>"$TMPROOT/debugger.err") || rc=$?
assert_rc "Debugger task section extraction succeeds" 0 "$rc"
assert_contains "Debugger context includes Task 1.1 heading" '## Task 1.1' "$out"
assert_contains "Debugger context includes root cause section" '### 根本原因' "$out"
assert_contains "Debugger context includes fix plan section" '### 修正手順' "$out"
assert_contains "Debugger context includes verification section" '### 検証方法' "$out"
assert_contains "Debugger context includes reference section" '### 関連参考資料' "$out"
assert_not_contains "Debugger context excludes next task section" '## Task 2' "$out"

rc=0
out=$(pt_extract_debugger_task_section "1.1" "$invalid_debugger_notes" 2>"$TMPROOT/invalid-debugger.err") || rc=$?
assert_rc "Debugger context fails when required h3 is missing" 1 "$rc"
assert_contains "invalid debugger diagnostic identifies missing section" 'reason=required-section-missing' "$(cat "$TMPROOT/invalid-debugger.err")"
assert_contains "invalid debugger diagnostic lists missing h3" 'missing=検証方法' "$(cat "$TMPROOT/invalid-debugger.err")"
assert_eq "invalid debugger failure has empty stdout" "" "$out"

rc=0
out=$(pt_extract_debugger_task_section "9" "$debugger_notes" 2>"$TMPROOT/missing-task.err") || rc=$?
assert_rc "Debugger context fails for missing task section" 1 "$rc"
assert_contains "missing task diagnostic identifies task-section-missing" 'reason=task-section-missing' "$(cat "$TMPROOT/missing-task.err")"
assert_eq "missing task failure has empty stdout" "" "$out"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
