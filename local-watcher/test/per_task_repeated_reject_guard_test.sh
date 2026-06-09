#!/usr/bin/env bash
#
# 用途: per-task retry の連続 reject warning-only guard を検証する。
#       Issue #37 task 4 で導入。
#
# 配置先: local-watcher/test/per_task_repeated_reject_guard_test.sh
# 依存:   bash 4+, awk, grep, git
# 実行:   bash local-watcher/test/per_task_repeated_reject_guard_test.sh

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
eval "$(extract_function "$WATCHER_SH" "pt_collect_reject_fingerprints")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_collect_changed_test_paths")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_fingerprint_in_set")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_reject_category_needs_test_diff")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_build_repeated_reject_warning")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_record_repeated_reject_warning_artifact")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_build_repeated_reject_redo_context")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_run_repeated_reject_warning_redo")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_extract_learnings")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "build_per_task_implementer_prompt")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "build_per_task_reviewer_prompt")"

for fn in pt_collect_reject_fingerprints pt_collect_changed_test_paths pt_build_repeated_reject_warning pt_record_repeated_reject_warning_artifact pt_build_repeated_reject_redo_context pt_run_repeated_reject_warning_redo pt_extract_learnings build_per_task_implementer_prompt build_per_task_reviewer_prompt; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

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

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

LOG="$TMPROOT/watcher.log"
REPO_DIR="$TMPROOT/repo"
SPEC_DIR_REL="docs/specs/37-repeated-reject"
REPO="owner/test"
NUMBER="37"
TITLE="[Enhancement] per-task repeated reject guard"
URL="https://github.com/owner/test/issues/37"
BODY="Issue body"
BRANCH="codex/issue-37-repeated-reject"
BASE_BRANCH="main"
export LOG REPO_DIR SPEC_DIR_REL REPO NUMBER TITLE URL BODY BRANCH BASE_BRANCH

cm_build_prompt_block() {
  return 0
}

mkdir -p "$REPO_DIR"
cd "$REPO_DIR"
git init -q
git checkout -q -b main
git config user.email "test@example.com"
git config user.name "Test User"

mkdir -p src local-watcher/test "$SPEC_DIR_REL"
printf 'echo initial\n' >src/app.sh
git add src/app.sh
git commit -q -m "chore: initial"
base_sha=$(git rev-parse HEAD)

review_notes="$TMPROOT/review-notes.md"
cat >"$review_notes" <<'EOF'
# Review Notes

## Findings

### Finding 1
- **Target**: 5.2（必須）
- **Category**: missing test
- **Detail**: Req 5.2 の test がありません。
- **Required Action**: per-task guard の test を追加する。

### Finding 2
- **Target**: 5.3
- **Category**: AC 未カバー
- **Detail**: Req 5.3 の AC が未確認です。
- **Required Action**: AC assertion を追加する。

### Finding 3
- **Target**: local-watcher/bin/idd-codex-issue-watcher.sh
- **Category**: boundary 逸脱
- **Detail**: boundary 外です。
- **Required Action**: scope を戻す。

RESULT: reject
EOF

echo "--- reject fingerprint collection ---"

fingerprints=$(pt_collect_reject_fingerprints "$review_notes")
assert_contains "fingerprints include missing test target" $'missing test\t5.2' "$fingerprints"
assert_contains "fingerprints include AC target" $'AC 未カバー\t5.3' "$fingerprints"
assert_contains "fingerprints include boundary target" $'boundary 逸脱\tlocal-watcher/bin/idd-codex-issue-watcher.sh' "$fingerprints"

echo ""
echo "--- changed test path collection ---"

printf 'echo production change\n' >>src/app.sh
git add src/app.sh
git commit -q -m "feat: production change"
prod_sha=$(git rev-parse HEAD)

changed_tests=$(pt_collect_changed_test_paths "$base_sha" "$prod_sha" || true)
assert_eq "production-only diff has no changed test paths" "" "$changed_tests"

printf 'echo test change\n' >local-watcher/test/repeated_guard_test.sh
git add local-watcher/test/repeated_guard_test.sh
git commit -q -m "test: add repeated guard fixture"
test_sha=$(git rev-parse HEAD)

changed_tests=$(pt_collect_changed_test_paths "$prod_sha" "$test_sha" || true)
assert_contains "test diff detects local-watcher/test path" "local-watcher/test/repeated_guard_test.sh" "$changed_tests"

echo ""
echo "--- warning block generation ---"

warning=$(pt_build_repeated_reject_warning "4" "2" "$fingerprints" "" || true)
assert_contains "warning block has heading" "## Repeated Reject Warning" "$warning"
assert_contains "warning block includes task ID" "Task ID: \`4\`" "$warning"
assert_contains "warning block includes next reviewer round" "Next Reviewer round: \`2\`" "$warning"
assert_contains "warning block includes missing test fingerprint" "Category: \`missing test\`; Target requirement: \`5.2\`" "$warning"
assert_contains "warning block includes AC fingerprint" "Category: \`AC 未カバー\`; Target requirement: \`5.3\`" "$warning"
assert_not_contains "warning block excludes boundary fingerprint" "boundary 逸脱" "$warning"
assert_contains "warning is logged for operator" "repeated-reject-warning next_round=2 category=missing test target=5.2 changed_test_paths=none" "$(cat "$LOG")"

prompt=$(build_per_task_reviewer_prompt "4" "$base_sha" "$test_sha" "2" "RESULT: reject" "$warning")
assert_contains "reviewer prompt includes warning block" "## Repeated Reject Warning" "$prompt"

impl_notes="$REPO_DIR/$SPEC_DIR_REL/impl-notes.md"
cat >"$impl_notes" <<'EOF'
# Implementation Notes

## Implementation Notes

### Task 4

- 採用方針: fixture baseline。
EOF
pt_record_repeated_reject_warning_artifact "4" "2" "$warning" "$impl_notes"
impl_notes_body=$(cat "$impl_notes")
assert_contains "developer artifact has warning heading" "Repeated Reject Warning（Task 4 / before Reviewer round 2）" "$impl_notes_body"
assert_contains "developer artifact includes missing test fingerprint" "Category: \`missing test\`; Target requirement: \`5.2\`" "$impl_notes_body"
assert_contains "developer artifact includes AC fingerprint" "Category: \`AC 未カバー\`; Target requirement: \`5.3\`" "$impl_notes_body"
assert_contains "developer artifact includes changed test none" "Changed test paths since prior reject: \`(none)\`" "$impl_notes_body"
assert_contains "developer artifact is logged for operator" "repeated-reject-warning developer-artifact=impl-notes next_round=2" "$(cat "$LOG")"

pt_record_repeated_reject_warning_artifact "4" "2" "$warning" "$impl_notes"
artifact_count=$(grep -Fc "idd-codex:repeated-reject-warning task=4 round=2" "$impl_notes")
assert_eq "developer artifact is replaced idempotently" "2" "$artifact_count"

impl_prompt=$(build_per_task_implementer_prompt "4")
assert_contains "implementer prompt includes developer-visible warning artifact" "Repeated Reject Warning（Task 4 / before Reviewer round 2）" "$impl_prompt"

echo ""
echo "--- warning redo orchestration ---"

ORCH_ORDER=""
ORCH_CONTEXT_FILE="$TMPROOT/warning-redo-context.md"
run_per_task_implementer() {
  local task_id="$1"
  local redo_context="${2:-}"
  ORCH_ORDER="${ORCH_ORDER}implementer-warning-redo:${task_id}"$'\n'
  printf '%s' "$redo_context" > "$ORCH_CONTEXT_FILE"
  return 0
}
pt_check_task_completed() {
  local tasks_md="$1"
  local task_id="$2"
  : "$tasks_md"
  ORCH_ORDER="${ORCH_ORDER}check-completed:${task_id}"$'\n'
  return 0
}
pt_mark_no_progress_failed() {
  return 1
}
mark_issue_failed() {
  return 1
}
run_per_task_reviewer() {
  local task_id="$1"
  local round="$2"
  ORCH_ORDER="${ORCH_ORDER}reviewer:${round}:${task_id}"$'\n'
  return 0
}

pt_run_repeated_reject_warning_redo "4" "2" "$warning" "$REPO_DIR/$SPEC_DIR_REL/tasks.md"
run_per_task_reviewer "4" "2" "$warning"
assert_eq "warning redo runs before reviewer" $'implementer-warning-redo:4\ncheck-completed:4\nreviewer:2:4\n' "$ORCH_ORDER"
warning_redo_context=$(cat "$ORCH_CONTEXT_FILE")
assert_contains "warning redo context has heading" "## Repeated Reject Warning Context" "$warning_redo_context"
assert_contains "warning redo context includes task ID" "Task ID: \`4\`" "$warning_redo_context"
assert_contains "warning redo context includes next round" "Next Reviewer round: \`2\`" "$warning_redo_context"
assert_contains "warning redo context includes redo kind" "Redo kind: \`repeated-reject-warning\`" "$warning_redo_context"
assert_contains "warning redo context includes changed test none" "Changed test paths since prior reject: \`(none)\`" "$warning_redo_context"
assert_contains "warning redo context includes missing test target" "Category: \`missing test\`; Target requirement: \`5.2\`" "$warning_redo_context"
assert_contains "warning redo context includes AC target" "Category: \`AC 未カバー\`; Target requirement: \`5.3\`" "$warning_redo_context"
assert_contains "warning redo context injection is logged" "redo-context injected kind=repeated-reject-warning round=2" "$(cat "$LOG")"

ORCH_ORDER=""
pt_run_repeated_reject_warning_redo "4" "2" "" "$REPO_DIR/$SPEC_DIR_REL/tasks.md"
assert_eq "empty warning skips warning redo" "" "$ORCH_ORDER"

: >"$LOG"
warning=$(pt_build_repeated_reject_warning "4" "2" "$fingerprints" "$changed_tests" || true)
assert_eq "changed test path suppresses warning block" "" "$warning"
assert_eq "changed test path suppresses warning log" "" "$(cat "$LOG")"

echo ""
echo "--- repeated overlap filtering ---"

prior_fingerprints=$'missing test\t5.2\nmissing test\t5.3'
current_fingerprints=$'missing test\t5.2\nmissing test\t5.4'
warning=$(pt_build_repeated_reject_warning "4" "3" "$current_fingerprints" "" "$prior_fingerprints" || true)
assert_contains "round 3 warning keeps overlapping fingerprint" "Target requirement: \`5.2\`" "$warning"
assert_not_contains "round 3 warning excludes non-overlapping fingerprint" "Target requirement: \`5.4\`" "$warning"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
