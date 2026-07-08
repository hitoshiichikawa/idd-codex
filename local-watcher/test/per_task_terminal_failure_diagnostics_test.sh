#!/usr/bin/env bash
#
# 用途: per-task terminal failure 時の review-notes.md / debugger-notes.md 保全診断を、
#       fake origin + fake gh で検証する shell-level regression test。
# 配置先: local-watcher/test/per_task_terminal_failure_diagnostics_test.sh
# 依存:   bash 4+, git, awk
# 実行:   bash local-watcher/test/per_task_terminal_failure_diagnostics_test.sh

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
eval "$(extract_function "$WATCHER_SH" "pt_artifact_state_line")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_artifact_content_block")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_build_terminal_failure_diagnostics")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "mark_issue_failed")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "dbg_log")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "validate_debugger_notes")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "run_debugger_stage")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "run_per_task_loop")"
# ── watcher refactor 追従: run_debugger_stage が依存する secure tempfile helper を追加ロード ──
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$SCRIPT_DIR/../bin/idd-codex-modules/core_utils.sh" "idd_secure_mktemp")"
# run_per_task_loop の startup guard（numeric checkbox marker 検査）helper も追加。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_has_watcher_compatible_tasks")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_fail_no_compatible_tasks")"

for fn in pt_artifact_state_line pt_artifact_content_block pt_build_terminal_failure_diagnostics mark_issue_failed dbg_log validate_debugger_notes run_debugger_stage run_per_task_loop; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded from idd-codex-issue-watcher.sh" >&2
    exit 2
  fi
done

TMPROOT=$(mktemp -d)
cleanup() {
  chmod -R u+rwX "$TMPROOT" 2>/dev/null || true
  rm -rf "$TMPROOT" 2>/dev/null || true
}
trap cleanup EXIT

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

LAST_GH_COMMENT_BODY=""
gh() {
  if [ "${1:-}" = "issue" ] && [ "${2:-}" = "edit" ]; then
    return 0
  fi
  if [ "${1:-}" = "issue" ] && [ "${2:-}" = "comment" ]; then
    local prev=""
    for arg in "$@"; do
      if [ "$prev" = "--body" ]; then
        LAST_GH_COMMENT_BODY="$arg"
      fi
      prev="$arg"
    done
    return 0
  fi
  return 0
}

rs_set_result() { :; }
codex_log_detect_529() { return 1; }
build_recovery_hint() { printf 'RECOVERY_HINT'; }
build_debugger_prompt() { printf 'debugger prompt'; }
codex_exec_prompt() { :; }
qa_handle_quota_exceeded() { :; }
qa_run_codex_stage() {
  return "${FAKE_QA_RC:-0}"
}
pt_warn() { :; }
pt_log() { printf '[pt] %s\n' "$*"; }
pt_extract_pending_tasks() { printf '1.2\n'; }
run_per_task_implementer() { return 0; }
pt_check_task_completed() { return 0; }
detect_blocked_marker() {
  printf 'fixture blocked reason\n'
  return 0
}
detect_debugger_already_invoked() { return 1; }

setup_work_with_upstream() {
  local case_id="$1"
  local work="$TMPROOT/work-$case_id"
  local bare="$TMPROOT/bare-$case_id.git"

  git init --bare --quiet "$bare"
  git init --quiet "$work"
  (
    cd "$work"
    git config user.email "test@example.com"
    git config user.name "Test"
    git config commit.gpgsign false
    git remote add origin "$bare"
    mkdir -p docs/specs/38--bug-per-task-terminal-failure-reviewer
    echo "initial" > README.md
    git add README.md
    git commit --quiet -m "init"
    git branch -m work-branch
    git push --quiet -u origin work-branch
  )
  echo "$work"
}

reset_state() {
  LAST_GH_COMMENT_BODY=""
}

NUMBER="38"
REPO="owner/test"
MODE="impl"
LABEL_CLAIMED="codex-claimed"
LABEL_PICKED="codex-picked-up"
LABEL_FAILED="codex-failed"
SPEC_DIR_REL="docs/specs/38--bug-per-task-terminal-failure-reviewer"
LOG="$TMPROOT/test-watcher.log"
BRANCH="work-branch"
REPO_SLUG="owner-test"
DEBUGGER_MODEL="debugger-test-model"
DEBUGGER_MAX_TURNS="5"
export NUMBER REPO MODE LABEL_CLAIMED LABEL_PICKED LABEL_FAILED SPEC_DIR_REL LOG BRANCH
export REPO_SLUG DEBUGGER_MODEL DEBUGGER_MAX_TURNS

echo "--- per-task terminal failure diagnostics cases ---"

# Case 1: per-task-reviewer-reject3 + untracked review-notes.md を diagnostic commit + push で保全する。
WORK=$(setup_work_with_upstream "case1")
REPO_DIR="$WORK"
export REPO_DIR
cat > "$WORK/$SPEC_DIR_REL/review-notes.md" <<'EOF'
# Review Notes

Finding: task 1.2 still fails.

RESULT: reject
EOF
reset_state
: > "$LOG"
pushd "$WORK" >/dev/null
mark_issue_failed "per-task-reviewer-reject3" "terminal reject body"
popd >/dev/null

assert_contains "Case 1: failure comment に per-task stage" \
  "stage: \`per-task-reviewer-reject3\`" "$LAST_GH_COMMENT_BODY"
assert_contains "Case 1: failure-time artifact state は untracked" \
  'review-notes.md`: exists=yes tracked=no untracked=yes' "$LAST_GH_COMMENT_BODY"
assert_contains "Case 1: diagnostic commit pushed を明示" \
  "status: \`diagnostic-commit-pushed\`" "$LAST_GH_COMMENT_BODY"
assert_contains "Case 1: diagnostic commit SHA を明示" \
  'diagnostic commit SHA:' "$LAST_GH_COMMENT_BODY"
assert_contains "Case 1: current branch を明示" \
  "current branch: \`work-branch\`" "$LAST_GH_COMMENT_BODY"
assert_contains "Case 1: local HEAD SHA を明示" \
  'local HEAD SHA:' "$LAST_GH_COMMENT_BODY"
assert_contains "Case 1: origin branch HEAD SHA を明示" \
  'origin branch HEAD SHA:' "$LAST_GH_COMMENT_BODY"
assert_contains "Case 1: ahead count を明示" \
  'ahead count:' "$LAST_GH_COMMENT_BODY"
assert_contains "Case 1: worktree path を明示" \
  "worktree path: \`$WORK\`" "$LAST_GH_COMMENT_BODY"
REMOTE_REVIEW=$(git -C "$TMPROOT/bare-case1.git" show "work-branch:$SPEC_DIR_REL/review-notes.md")
assert_contains "Case 1: remote branch に review-notes.md が保存された" \
  "Finding: task 1.2 still fails." "$REMOTE_REVIEW"

# Case 2: commit 済みだが未 push の review-notes.md も branch push verify で保全する。
WORK=$(setup_work_with_upstream "case2")
REPO_DIR="$WORK"
export REPO_DIR
cat > "$WORK/$SPEC_DIR_REL/review-notes.md" <<'EOF'
# Review Notes

Committed but not pushed reviewer content.

RESULT: reject
EOF
(
  cd "$WORK"
  git add "$SPEC_DIR_REL/review-notes.md"
  git commit --quiet -m "docs(review): add reviewer notes"
)
reset_state
: > "$LOG"
pushd "$WORK" >/dev/null
mark_issue_failed "per-task-reviewer-reject3" "terminal reject body"
popd >/dev/null

assert_contains "Case 2: clean artifact state を明示" \
  'review-notes.md`: exists=yes tracked=yes untracked=no staged=no unstaged=no uncommitted=no' "$LAST_GH_COMMENT_BODY"
assert_contains "Case 2: ahead branch push を明示" \
  "status: \`branch-ahead-pushed\`" "$LAST_GH_COMMENT_BODY"
REMOTE_COMMITTED_REVIEW=$(git -C "$TMPROOT/bare-case2.git" show "work-branch:$SPEC_DIR_REL/review-notes.md")
assert_contains "Case 2: remote branch に commit 済み review-notes.md が保存された" \
  "Committed but not pushed reviewer content." "$REMOTE_COMMITTED_REVIEW"

# Case 3: per-task run_debugger_stage の debugger-failed 経路で untracked debugger-notes.md を保全する。
WORK=$(setup_work_with_upstream "case3")
REPO_DIR="$WORK"
export REPO_DIR
cat > "$WORK/$SPEC_DIR_REL/debugger-notes.md" <<'EOF'
# Debugger Notes

## Task 1.2
Root cause: missing guard.
EOF
reset_state
: > "$LOG"
FAKE_QA_RC=7
export FAKE_QA_RC
pushd "$WORK" >/dev/null
if run_debugger_stage "round2-reject" "1.2" "$WORK/$SPEC_DIR_REL/review-notes.md"; then
  echo "FAIL: Case 3: run_debugger_stage should fail on codex non-zero"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
popd >/dev/null

assert_contains "Case 3: failure comment に debugger-failed stage" \
  "失敗 stage: debugger-failed" "$LAST_GH_COMMENT_BODY"
assert_contains "Case 3: diagnostic block に per-task debugger-failed stage" \
  "stage: \`per-task-debugger-failed\`" "$LAST_GH_COMMENT_BODY"
assert_contains "Case 3: debugger artifact state は untracked" \
  'debugger-notes.md`: exists=yes tracked=no untracked=yes' "$LAST_GH_COMMENT_BODY"
assert_contains "Case 3: debugger diagnostic commit pushed を明示" \
  "status: \`diagnostic-commit-pushed\`" "$LAST_GH_COMMENT_BODY"
REMOTE_DEBUGGER=$(git -C "$TMPROOT/bare-case3.git" show "work-branch:$SPEC_DIR_REL/debugger-notes.md")
assert_contains "Case 3: remote branch に debugger-notes.md が保存された" \
  "Root cause: missing guard." "$REMOTE_DEBUGGER"
unset FAKE_QA_RC

# Case 4: per-task loop から入る debugger-notes-invalid 経路でも diagnostic commit を実行する。
WORK=$(setup_work_with_upstream "case4")
REPO_DIR="$WORK"
export REPO_DIR
cat > "$WORK/$SPEC_DIR_REL/tasks.md" <<'EOF'
# Tasks

- [ ] 1.2 Fixture task
  - _Requirements: 1.1_
EOF
cat > "$WORK/$SPEC_DIR_REL/debugger-notes.md" <<'EOF'
# Debugger Notes

## Task 1.2
### 根本原因
invalid fixture missing required sections.
EOF
reset_state
: > "$LOG"
FAKE_QA_RC=0
DEBUGGER_ENABLED=true
export FAKE_QA_RC DEBUGGER_ENABLED
pushd "$WORK" >/dev/null
if run_per_task_loop; then
  echo "FAIL: Case 4: run_per_task_loop should fail on invalid debugger-notes.md"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
popd >/dev/null

assert_contains "Case 4: failure comment に debugger-notes-invalid stage" \
  "失敗 stage: debugger-notes-invalid" "$LAST_GH_COMMENT_BODY"
assert_contains "Case 4: diagnostic block に per-task debugger-notes-invalid stage" \
  "stage: \`per-task-debugger-notes-invalid\`" "$LAST_GH_COMMENT_BODY"
assert_contains "Case 4: invalid debugger artifact state は untracked" \
  'debugger-notes.md`: exists=yes tracked=no untracked=yes' "$LAST_GH_COMMENT_BODY"
assert_contains "Case 4: invalid debugger diagnostic commit pushed を明示" \
  "status: \`diagnostic-commit-pushed\`" "$LAST_GH_COMMENT_BODY"
REMOTE_INVALID_DEBUGGER=$(git -C "$TMPROOT/bare-case4.git" show "work-branch:$SPEC_DIR_REL/debugger-notes.md")
assert_contains "Case 4: remote branch に invalid debugger-notes.md が保存された" \
  "invalid fixture missing required sections." "$REMOTE_INVALID_DEBUGGER"
unset FAKE_QA_RC
unset DEBUGGER_ENABLED

# Case 5: diagnostic commit が失敗した場合、Issue コメントに artifact content fallback を残す。
WORK=$(setup_work_with_upstream "case5")
REPO_DIR="$WORK"
export REPO_DIR
(
  cd "$WORK"
  cat > .git/hooks/pre-commit <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x .git/hooks/pre-commit
)
cat > "$WORK/$SPEC_DIR_REL/review-notes.md" <<'EOF'
# Review Notes

Fallback-visible reviewer content.

RESULT: reject
EOF
reset_state
: > "$LOG"
pushd "$WORK" >/dev/null
mark_issue_failed "per-task-reviewer-reject3" "terminal reject body"
popd >/dev/null

assert_contains "Case 5: diagnostic commit failure を明示" \
  "status: \`diagnostic-commit-failed-fallback\`" "$LAST_GH_COMMENT_BODY"
assert_contains "Case 5: fallback issue comment を明示" \
  "fallback issue comment: \`yes\`" "$LAST_GH_COMMENT_BODY"
assert_contains "Case 5: commit failure detail を明示" \
  'diagnostic commit failure:' "$LAST_GH_COMMENT_BODY"
assert_contains "Case 5: fallback に review-notes.md content を含める" \
  "Fallback-visible reviewer content." "$LAST_GH_COMMENT_BODY"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
