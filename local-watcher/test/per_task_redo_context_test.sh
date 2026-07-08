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
eval "$(extract_function "$WATCHER_SH" "pt_log")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_regex_escape")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_extract_review_reject_context")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_extract_debugger_task_section")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_build_redo_context_block")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_extract_learnings")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "build_per_task_implementer_prompt")"
# ── watcher refactor 追従: prompt builder が新規依存する module 関数 / env を追加ロード ──
# build_per_task_{implementer,reviewer}_prompt は build_issue_context_block（watcher）と
# cm_build_prompt_block（context-map module。既定 OFF 時は空文字を返す）を呼ぶ。
# shellcheck source=../bin/idd-codex-modules/context-map.sh
. "$SCRIPT_DIR/../bin/idd-codex-modules/context-map.sh"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "build_issue_context_block")"
LABEL_NEEDS_DECISIONS="${LABEL_NEEDS_DECISIONS:-codex-needs-decisions}"
# pt_build_redo_context_block は idd_secure_mktemp を呼ぶ。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$SCRIPT_DIR/../bin/idd-codex-modules/core_utils.sh" "idd_secure_mktemp")"

if ! declare -F pt_extract_review_reject_context >/dev/null; then
  echo "ERROR: pt_extract_review_reject_context not loaded" >&2
  exit 2
fi
if ! declare -F pt_extract_debugger_task_section >/dev/null; then
  echo "ERROR: pt_extract_debugger_task_section not loaded" >&2
  exit 2
fi
if ! declare -F pt_build_redo_context_block >/dev/null; then
  echo "ERROR: pt_build_redo_context_block not loaded" >&2
  exit 2
fi
if ! declare -F build_per_task_implementer_prompt >/dev/null; then
  echo "ERROR: build_per_task_implementer_prompt not loaded" >&2
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

REPO_DIR="$TMPROOT/repo"
SPEC_DIR_REL="docs/specs/37-redo-context"
LOG="$TMPROOT/watcher.log"
REPO="owner/test"
NUMBER="37"
TITLE="[Enhancement] per-task retry context"
URL="https://github.com/owner/test/issues/37"
BODY="per-task retry context body"
BRANCH="codex/issue-37-redo-context"
BASE_BRANCH="main"
export REPO_DIR SPEC_DIR_REL LOG REPO NUMBER TITLE URL BODY BRANCH BASE_BRANCH

cm_build_prompt_block() {
  return 0
}

mkdir -p "$REPO_DIR/$SPEC_DIR_REL"

review_notes="$TMPROOT/review-notes.md"
approve_notes="$TMPROOT/review-approve.md"
invalid_review_notes="$TMPROOT/review-invalid.md"
debugger_notes="$TMPROOT/debugger-notes.md"
invalid_debugger_notes="$TMPROOT/debugger-invalid.md"
issue23_round1_review_notes="$TMPROOT/issue23-round1-review-notes.md"
issue23_round2_review_notes="$TMPROOT/issue23-round2-review-notes.md"
issue23_debugger_notes="$TMPROOT/issue23-debugger-notes.md"

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

cat >"$issue23_round1_review_notes" <<'EOF'
# Review Notes

<!-- idd-codex:review task=5 round=1 -->

## Findings

### Finding 1
- **Target**: 5.2
- **Category**: missing test
- **Detail**: #23 shape の round 1 で Req 5.2 の Debugger context assertion が未追加です。
- **Required Action**: round 1 redo prompt に Req 5.2 の actionable Reviewer context が含まれることを検証する。

### Finding 2
- **Target**: 5.3
- **Category**: missing test
- **Detail**: #23 shape の round 1 で Finding Closure Matrix contract assertion が未追加です。
- **Required Action**: rejected target requirement / fix commit / test/assertion / verification result の対応を prompt で検証する。

## Summary

Req 5.2 / 5.3 の missing test が round 1 に残っています。

RESULT: reject
EOF

cat >"$issue23_round2_review_notes" <<'EOF'
# Review Notes

<!-- idd-codex:review task=5 round=2 -->

## Findings

### Finding 1
- **Target**: 5.2
- **Category**: missing test
- **Detail**: #23 shape の round 2 でも Debugger Fix Plan context assertion が未追加のままです。
- **Required Action**: Debugger 後 redo prompt に Task 5 の Fix Plan と Req 5.2 の Reviewer context が同時に含まれることを検証する。

### Finding 2
- **Target**: 5.3
- **Category**: missing test
- **Detail**: #23 shape の round 2 でも Finding Closure Matrix prompt contract が未検証です。
- **Required Action**: Matrix が rejected target requirement、fix commit、test/assertion、verification result の対応を要求することを検証する。

## Summary

Req 5.2 / 5.3 の missing test が round 2 にも残っています。

RESULT: reject
EOF

cat >"$issue23_debugger_notes" <<'EOF'
# Debugger Notes (Issue #37)

## Task 5

### 根本原因

Req 5.2 / 5.3 の missing test が round 1 / round 2 の両方に残る #23 shape を fixture として固定できていません。

### 修正手順

1. round 1 reject 後の redo prompt に Reviewer Findings / Required Action が入ることを検証する。
2. round 2 reject 後の Debugger redo prompt に Reviewer context と Debugger Fix Plan が同時に入ることを検証する。
3. Finding Closure Matrix の rejected target requirement / fix commit / test/assertion / verification result contract を検証する。

### 検証方法

per_task_redo_context_test.sh で Req 5.2 / 5.3 の missing test が round 1 / round 2 に残る fixture を実行する。

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
echo "--- redo context block and implementer prompt injection ---"

rc=0
out=$(pt_build_redo_context_block "1" "reviewer-reject" "1" "$review_notes" 2>"$TMPROOT/redo-review.err") || rc=$?
assert_rc "Reviewer redo context block succeeds" 0 "$rc"
assert_contains "Redo block has Retry Context heading" '## Retry Context（watcher 生成 / per-task redo）' "$out"
assert_contains "Redo block identifies reviewer reject kind" "Redo kind: \`reviewer-reject\`" "$out"
assert_contains "Redo block includes Reviewer source label" '### Reviewer Reject Context' "$out"
assert_contains "Redo block includes Req 5.2 actionable target" "Target=\`5.2\`" "$out"
assert_contains "Redo block includes Req 5.3 actionable target" "Target=\`5.3\`" "$out"
assert_contains "Redo block includes Required Action checklist item" 'Required Action=local-watcher/test/per_task_redo_context_test.sh に Req 5.2 の assertion を追加する。' "$out"

prompt=$(build_per_task_implementer_prompt "1" "$out")
assert_contains "Implementer prompt includes injected Retry Context" '## Retry Context（watcher 生成 / per-task redo）' "$prompt"
assert_contains "Implementer prompt keeps reviewer round" "Reviewer round: \`1\`" "$prompt"
assert_contains "Implementer prompt includes Required Action inline" 'Required Action=local-watcher/test/per_task_redo_context_test.sh に Req 5.2 の assertion を追加する。' "$prompt"
assert_contains "Implementer prompt includes Finding Closure Matrix heading" '### Finding Closure Matrix（必須）' "$prompt"
assert_contains "Implementer prompt includes Finding Closure Matrix schema" '| Target requirement | Category | Required Action | Fix commit | Test/assertion | Verification result | Notes / no-change reason |' "$prompt"
assert_contains "Implementer prompt requires rejected target requirement rows" 'rejected target requirement' "$prompt"
assert_contains "Implementer prompt requires fix commit evidence" 'fix commit' "$prompt"
assert_contains "Implementer prompt requires test/assertion evidence" 'test/assertion' "$prompt"
assert_contains "Implementer prompt requires verification result evidence" 'verification result' "$prompt"

rc=0
out=$(pt_build_redo_context_block "1.1" "debugger-fix-plan" "2" "$review_notes" "$debugger_notes" 2>"$TMPROOT/redo-debugger.err") || rc=$?
assert_rc "Debugger redo context block succeeds" 0 "$rc"
assert_contains "Debugger redo block identifies debugger kind" "Redo kind: \`debugger-fix-plan\`" "$out"
assert_contains "Debugger redo block separates Reviewer context" '### Reviewer Reject Context' "$out"
assert_contains "Debugger redo block separates Debugger context" '### Debugger Fix Plan Context' "$out"
assert_contains "Debugger redo block includes Task 1.1 fix plan" '## Task 1.1' "$out"
assert_contains "Debugger redo block includes fix steps" '### 修正手順' "$out"

prompt=$(build_per_task_implementer_prompt "1.1" "$out")
assert_contains "Debugger redo prompt includes Reviewer target" "Target=\`5.2\`" "$prompt"
assert_contains "Debugger redo prompt includes Debugger Task section" '## Task 1.1' "$prompt"
assert_contains "Debugger redo prompt identifies Debugger context source" '### Debugger Fix Plan Context' "$prompt"
assert_contains "Debugger redo prompt keeps Finding Closure Matrix schema" '| Target requirement | Category | Required Action | Fix commit | Test/assertion | Verification result | Notes / no-change reason |' "$prompt"

rc=0
out=$(pt_build_redo_context_block "1" "reviewer-reject" "1" "$approve_notes" 2>"$TMPROOT/redo-diagnostic.err") || rc=$?
assert_rc "Redo context block remains available with diagnostic when review extraction fails" 0 "$rc"
assert_contains "Redo diagnostic block warns against silent rerun" 'This retry must not be treated as a normal same-task rerun.' "$out"
assert_contains "Redo diagnostic block includes extraction reason" 'reason=result-not-reject' "$out"
assert_contains "Redo diagnostic is logged" 'redo-context-unavailable kind=reviewer-reject round=1' "$(cat "$LOG")"

echo ""
echo "--- #23 regression shape redo prompt coverage ---"

rc=0
issue23_round1_block=$(pt_build_redo_context_block "5" "reviewer-reject" "1" "$issue23_round1_review_notes" 2>"$TMPROOT/issue23-round1.err") || rc=$?
assert_rc "#23 round 1 redo context block succeeds" 0 "$rc"
issue23_round1_prompt=$(build_per_task_implementer_prompt "5" "$issue23_round1_block")
assert_contains "#23 round 1 prompt identifies task 5" "Task ID: \`5\`" "$issue23_round1_prompt"
assert_contains "#23 round 1 prompt keeps Reviewer round 1" "Reviewer round: \`1\`" "$issue23_round1_prompt"
assert_contains "#23 round 1 prompt includes Req 5.2 target" "Target=\`5.2\`" "$issue23_round1_prompt"
assert_contains "#23 round 1 prompt includes Req 5.3 target" "Target=\`5.3\`" "$issue23_round1_prompt"
assert_contains "#23 round 1 prompt includes Req 5.2 Required Action" 'round 1 redo prompt に Req 5.2 の actionable Reviewer context が含まれることを検証する。' "$issue23_round1_prompt"
assert_contains "#23 round 1 prompt includes Req 5.3 Matrix Required Action" 'rejected target requirement / fix commit / test/assertion / verification result の対応を prompt で検証する。' "$issue23_round1_prompt"

rc=0
issue23_round2_block=$(pt_build_redo_context_block "5" "debugger-fix-plan" "2" "$issue23_round2_review_notes" "$issue23_debugger_notes" 2>"$TMPROOT/issue23-round2.err") || rc=$?
assert_rc "#23 round 2 Debugger redo context block succeeds" 0 "$rc"
issue23_round2_prompt=$(build_per_task_implementer_prompt "5" "$issue23_round2_block")
assert_contains "#23 round 2 prompt keeps Reviewer context source" '### Reviewer Reject Context' "$issue23_round2_prompt"
assert_contains "#23 round 2 prompt keeps Debugger context source" '### Debugger Fix Plan Context' "$issue23_round2_prompt"
assert_contains "#23 round 2 prompt includes Req 5.2 repeated target" "Target=\`5.2\`" "$issue23_round2_prompt"
assert_contains "#23 round 2 prompt includes Req 5.3 repeated target" "Target=\`5.3\`" "$issue23_round2_prompt"
assert_contains "#23 round 2 prompt includes Debugger Task 5 section" '## Task 5' "$issue23_round2_prompt"
assert_contains "#23 round 2 prompt includes Debugger root cause" 'Req 5.2 / 5.3 の missing test が round 1 / round 2 の両方に残る #23 shape' "$issue23_round2_prompt"
assert_contains "#23 round 2 prompt includes Debugger fix plan" 'round 2 reject 後の Debugger redo prompt に Reviewer context と Debugger Fix Plan が同時に入ることを検証する。' "$issue23_round2_prompt"
assert_contains "#23 Matrix contract maps rejected targets" 'rejected target requirement ごとに' "$issue23_round2_prompt"
assert_contains "#23 Matrix contract requires fix commit" 'fix commit / test/assertion / verification result の対応を明示してください。' "$issue23_round2_prompt"
assert_contains "#23 Matrix contract has canonical schema" '| Target requirement | Category | Required Action | Fix commit | Test/assertion | Verification result | Notes / no-change reason |' "$issue23_round2_prompt"
assert_contains "#23 prompt-only fixture states verification command" 'per_task_redo_context_test.sh で Req 5.2 / 5.3 の missing test が round 1 / round 2 に残る fixture を実行する。' "$issue23_round2_prompt"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
