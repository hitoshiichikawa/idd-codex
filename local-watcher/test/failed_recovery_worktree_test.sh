#!/usr/bin/env bash
#
# 用途: failed recovery preflight (Issue #58) の stale worktree 整理をローカル
#       git worktree で検証するスモークテスト。
#
# 検証観点:
#   - inactive clean slot worktree が対象 branch を checkout 済みなら detached に戻す
#   - dirty / untracked slot worktree は破棄せず codex-needs-decisions に倒す
#   - origin branch が無い local-only branch は破棄せず codex-needs-decisions に倒す
#   - reset-corruption（local branch が origin/main に動いた状態）は origin branch へ復旧可能
#   - local-only commit がある branch は自動 reset せず codex-needs-decisions に倒す
#   - checkout busy recovery は成功 / 失敗とも 1 回だけ試行する
#
# 配置先: local-watcher/test/failed_recovery_worktree_test.sh
# 依存:   bash 4+, git, awk, flock
# 実行:   bash local-watcher/test/failed_recovery_worktree_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
CORE_UTILS_SH="$SCRIPT_DIR/../bin/idd-codex-modules/core_utils.sh"

if [ ! -f "$WATCHER_SH" ] || [ ! -f "$CORE_UTILS_SH" ]; then
  echo "ERROR: cannot find watcher dependencies" >&2
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

# shellcheck source=/dev/null
. "$CORE_UTILS_SH"

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "_failed_recovery_branch_worktrees")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "_failed_recovery_slot_for_worktree")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "_failed_recovery_escalate_needs_decisions")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "_failed_recovery_local_branch_safe_to_reset")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "_failed_recovery_prepare_branch_checkout")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "_failed_recovery_checkout_error_is_worktree_busy")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "_failed_recovery_checkout_branch")"

for fn in \
  _failed_recovery_branch_worktrees \
  _failed_recovery_slot_for_worktree \
  _failed_recovery_escalate_needs_decisions \
  _failed_recovery_local_branch_safe_to_reset \
  _failed_recovery_prepare_branch_checkout \
  _failed_recovery_checkout_error_is_worktree_busy \
  _failed_recovery_checkout_branch; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
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

assert_success() {
  local label="$1"
  shift
  if "$@"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_failure() {
  local label="$1"
  shift
  if "$@"; then
    echo "FAIL: $label"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

git() {
  if [ "${GIT_STUB_CHECKOUT_BUSY:-false}" = "true" ] && [ "${1:-}" = "checkout" ]; then
    GIT_CHECKOUT_COUNT=$((GIT_CHECKOUT_COUNT + 1))
    if [ "$GIT_CHECKOUT_COUNT" -eq 1 ]; then
      echo "fatal: '$BRANCH' is already checked out at '/tmp/stale-slot'" >&2
      return 128
    fi
    return 0
  fi
  command git "$@"
}

slot_log() {
  echo "slot-log: $*" >> "$LOG"
}

slot_warn() {
  echo "slot-warn: $*" >> "$LOG"
}

DECISION_COUNT=0
LAST_DECISION_STATUS=""
LAST_DECISION_BODY=""
mark_issue_needs_decisions() {
  DECISION_COUNT=$((DECISION_COUNT + 1))
  LAST_DECISION_STATUS="$1"
  LAST_DECISION_BODY="$2"
  return 0
}

LAST_RESULT=""
rs_set_result() {
  LAST_RESULT="$1"
  return 0
}

FAILED_COUNT=0
_slot_mark_failed() {
  FAILED_COUNT=$((FAILED_COUNT + 1))
  return 0
}

# shellcheck disable=SC2034
setup_case() {
  local name="$1"
  CASE_ROOT="$TMPROOT/$name"
  ORIGIN="$CASE_ROOT/origin.git"
  REPO_DIR="$CASE_ROOT/repo"
  REPO_SLUG="owner-repo-$name"
  WORKTREE_BASE_DIR="$CASE_ROOT/worktrees"
  SLOT_LOCK_DIR="$CASE_ROOT/locks"
  PARALLEL_SLOTS=2
  BASE_BRANCH="main"
  BRANCH="codex/issue-58-impl-failed-recovery"
  IDD_SLOT_NUMBER=1
  IDD_SLOT_WORKTREE="$WORKTREE_BASE_DIR/$REPO_SLUG/slot-1"
  NUMBER=58
  REPO="owner/repo"
  LABEL_NEEDS_DECISIONS="codex-needs-decisions"
  LOG="$CASE_ROOT/test.log"
  DECISION_COUNT=0
  LAST_DECISION_STATUS=""
  LAST_DECISION_BODY=""
  LAST_RESULT=""
  FAILED_COUNT=0

  mkdir -p "$CASE_ROOT" "$WORKTREE_BASE_DIR/$REPO_SLUG" "$SLOT_LOCK_DIR"
  : > "$LOG"

  git init --bare --quiet "$ORIGIN"
  git init --quiet "$REPO_DIR"
  (
    cd "$REPO_DIR"
    git config user.email "test@example.com"
    git config user.name "Test"
    git config commit.gpgsign false
    git remote add origin "$ORIGIN"
    echo "base" > base.txt
    git add base.txt
    git commit --quiet -m "base"
    git branch -m main
    git push --quiet -u origin main
    git checkout --quiet -B "$BRANCH"
    echo "feature" > feature.txt
    git add feature.txt
    git commit --quiet -m "feature"
    git push --quiet -u origin "$BRANCH"
    git checkout --quiet main
    git fetch --quiet origin
  )

  git -C "$REPO_DIR" worktree add --quiet --detach "$IDD_SLOT_WORKTREE" origin/main
  git -C "$REPO_DIR" worktree add --quiet "$(_worktree_path 2)" "$BRANCH"
  cd "$REPO_DIR"
}

current_branch_or_detached() {
  local wt="$1"
  git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "DETACHED"
}

echo "--- failed recovery stale worktree cases (Issue #58) ---"

setup_case "clean"
rc=0
_failed_recovery_prepare_branch_checkout "$BRANCH" "true" || rc=$?
assert_eq "clean stale slot: prepare succeeds" "0" "$rc"
assert_eq "clean stale slot: slot-2 detached" "DETACHED" "$(current_branch_or_detached "$(_worktree_path 2)")"
assert_success "clean stale slot: current slot can checkout branch" \
  git -C "$IDD_SLOT_WORKTREE" checkout -B "$BRANCH" "origin/$BRANCH"

setup_case "dirty"
echo "local note" > "$(_worktree_path 2)/local.txt"
rc=0
_failed_recovery_prepare_branch_checkout "$BRANCH" "true" || rc=$?
assert_eq "untracked stale slot: prepare escalates with rc=20" "20" "$rc"
assert_eq "untracked stale slot: needs-decisions emitted once" "1" "$DECISION_COUNT"
assert_eq "untracked stale slot: slot-2 remains on branch" "$BRANCH" "$(current_branch_or_detached "$(_worktree_path 2)")"

setup_case "tracked-dirty"
echo "tracked local edit" >> "$(_worktree_path 2)/feature.txt"
rc=0
_failed_recovery_prepare_branch_checkout "$BRANCH" "true" || rc=$?
assert_eq "tracked dirty stale slot: prepare escalates with rc=20" "20" "$rc"
assert_eq "tracked dirty stale slot: needs-decisions emitted once" "1" "$DECISION_COUNT"
assert_eq "tracked dirty stale slot: slot-2 remains on branch" "$BRANCH" "$(current_branch_or_detached "$(_worktree_path 2)")"
assert_eq "tracked dirty stale slot: current slot remains detached" "DETACHED" "$(current_branch_or_detached "$IDD_SLOT_WORKTREE")"

setup_case "local-branch-no-origin"
git -C "$REPO_DIR" push --quiet origin --delete "$BRANCH"
git -C "$REPO_DIR" fetch --quiet --prune origin
rc=0
_failed_recovery_prepare_branch_checkout "$BRANCH" "false" || rc=$?
assert_eq "local branch without origin: prepare escalates with rc=20" "20" "$rc"
assert_eq "local branch without origin: needs-decisions emitted once" "1" "$DECISION_COUNT"
assert_eq "local branch without origin: slot-2 remains on branch" "$BRANCH" "$(current_branch_or_detached "$(_worktree_path 2)")"

setup_case "reset-corruption"
git -C "$(_worktree_path 2)" reset --hard origin/main >/dev/null
rc=0
_failed_recovery_prepare_branch_checkout "$BRANCH" "true" || rc=$?
assert_eq "reset-corruption: prepare succeeds" "0" "$rc"
assert_eq "reset-corruption: slot-2 detached" "DETACHED" "$(current_branch_or_detached "$(_worktree_path 2)")"
assert_success "reset-corruption: current slot restores origin branch" \
  git -C "$IDD_SLOT_WORKTREE" checkout -B "$BRANCH" "origin/$BRANCH"
assert_eq "reset-corruption: restored HEAD equals origin branch" \
  "$(git -C "$REPO_DIR" rev-parse "origin/$BRANCH")" \
  "$(git -C "$IDD_SLOT_WORKTREE" rev-parse HEAD)"

setup_case "local-ahead"
(
  cd "$(_worktree_path 2)"
  echo "local-only" >> feature.txt
  git add feature.txt
  git commit --quiet -m "local-only"
)
rc=0
_failed_recovery_prepare_branch_checkout "$BRANCH" "true" || rc=$?
assert_eq "local-only commits: prepare escalates with rc=20" "20" "$rc"
assert_eq "local-only commits: needs-decisions emitted once" "1" "$DECISION_COUNT"
assert_eq "local-only commits: slot-2 remains on branch" "$BRANCH" "$(current_branch_or_detached "$(_worktree_path 2)")"
assert_eq "local-only commits: current slot remains detached" "DETACHED" "$(current_branch_or_detached "$IDD_SLOT_WORKTREE")"

setup_case "fresh-no-origin-clean"
git -C "$(_worktree_path 2)" checkout --quiet --detach --force origin/main
git -C "$REPO_DIR" branch -D "$BRANCH" >/dev/null
git -C "$REPO_DIR" push --quiet origin --delete "$BRANCH"
git -C "$REPO_DIR" fetch --quiet --prune origin
rc=0
_failed_recovery_prepare_branch_checkout "$BRANCH" "false" || rc=$?
assert_eq "fresh no origin: prepare succeeds without stale branch" "0" "$rc"
assert_eq "fresh no origin: no needs-decisions" "0" "$DECISION_COUNT"
assert_success "fresh no origin: current slot can create branch from base" \
  git -C "$IDD_SLOT_WORKTREE" checkout -B "$BRANCH" "origin/main"

setup_case "fresh-no-origin-local-stale"
git -C "$REPO_DIR" push --quiet origin --delete "$BRANCH"
git -C "$REPO_DIR" fetch --quiet --prune origin
rc=0
_failed_recovery_prepare_branch_checkout "$BRANCH" "false" || rc=$?
assert_eq "fresh local-only stale: prepare escalates with rc=20" "20" "$rc"
assert_eq "fresh local-only stale: needs-decisions emitted once" "1" "$DECISION_COUNT"
assert_eq "fresh local-only stale: slot-2 remains on branch" "$BRANCH" "$(current_branch_or_detached "$(_worktree_path 2)")"

busy_err="$TMPROOT/worktree-busy.err"
printf "fatal: '%s' is already checked out at '/tmp/stale-slot'\n" "$BRANCH" > "$busy_err"
assert_success "checkout error matcher: already checked out at" \
  _failed_recovery_checkout_error_is_worktree_busy "$busy_err"
printf "fatal: '%s' already used by worktree at '/tmp/stale-slot'\n" "$BRANCH" > "$busy_err"
assert_success "checkout error matcher: already used by worktree" \
  _failed_recovery_checkout_error_is_worktree_busy "$busy_err"

PREP_COUNT=0
GIT_CHECKOUT_COUNT=0
GIT_STUB_CHECKOUT_BUSY=true
_failed_recovery_prepare_branch_checkout() {
  PREP_COUNT=$((PREP_COUNT + 1))
  return 0
}
rc=0
_failed_recovery_checkout_branch "$BRANCH" "origin/$BRANCH" "true" "既存 branch resume に失敗" || rc=$?
GIT_STUB_CHECKOUT_BUSY=false
assert_eq "checkout busy retry: succeeds after one recovery" "0" "$rc"
assert_eq "checkout busy retry: recovery attempted once" "1" "$PREP_COUNT"
assert_eq "checkout busy retry: checkout attempted twice" "2" "$GIT_CHECKOUT_COUNT"
assert_eq "checkout busy retry: no failed label" "0" "$FAILED_COUNT"

setup_case "busy-recovery-fails"
PREP_COUNT=0
GIT_CHECKOUT_COUNT=0
GIT_STUB_CHECKOUT_BUSY=true
_failed_recovery_prepare_branch_checkout() {
  PREP_COUNT=$((PREP_COUNT + 1))
  _failed_recovery_escalate_needs_decisions \
    "dirty-stale-worktree" \
    "$1" \
    "/tmp/stale-slot" \
    "stubbed recovery failure"
  return 20
}
rc=0
_failed_recovery_checkout_branch "$BRANCH" "origin/$BRANCH" "true" "既存 branch resume に失敗" || rc=$?
GIT_STUB_CHECKOUT_BUSY=false
assert_eq "checkout busy failed recovery: returns failure" "1" "$rc"
assert_eq "checkout busy failed recovery: recovery attempted once" "1" "$PREP_COUNT"
assert_eq "checkout busy failed recovery: checkout not retried" "1" "$GIT_CHECKOUT_COUNT"
assert_eq "checkout busy failed recovery: needs-decisions emitted once" "1" "$DECISION_COUNT"
assert_eq "checkout busy failed recovery: no failed label" "0" "$FAILED_COUNT"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
