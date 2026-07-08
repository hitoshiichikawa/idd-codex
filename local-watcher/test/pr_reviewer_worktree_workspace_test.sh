#!/usr/bin/env bash
#
# 用途: PR Reviewer が実装用 worktree の head branch checkout と衝突しない
#       detached review workspace を使うこと、および workspace 準備失敗の可視化を検証する。
# 配置先: local-watcher/test/pr_reviewer_worktree_workspace_test.sh
# 依存:   bash 4+, git, jq
# 実行:   bash local-watcher/test/pr_reviewer_worktree_workspace_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_UTILS_SH="$SCRIPT_DIR/../bin/idd-codex-modules/core_utils.sh"
PR_REVIEWER_SH="$SCRIPT_DIR/../bin/idd-codex-modules/pr-reviewer.sh"

if [ ! -f "$CORE_UTILS_SH" ]; then
  echo "ERROR: cannot find core_utils.sh at $CORE_UTILS_SH" >&2
  exit 2
fi
if [ ! -f "$PR_REVIEWER_SH" ]; then
  echo "ERROR: cannot find pr-reviewer.sh at $PR_REVIEWER_SH" >&2
  exit 2
fi
if ! command -v git >/dev/null 2>&1; then
  echo "ERROR: git is required" >&2
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
eval "$(extract_function "$CORE_UTILS_SH" "idd_secure_mktemp")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$CORE_UTILS_SH" "pr_log")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$CORE_UTILS_SH" "pr_warn")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$CORE_UTILS_SH" "pr_error")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_git_error_excerpt")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_classify_review_workspace_failure")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_cleanup_review_workspace")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_execute_review_command")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_run_review_for_pr")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "process_pr_reviewer")"

for fn in idd_secure_mktemp pr_log pr_warn pr_error pr_git_error_excerpt \
  pr_classify_review_workspace_failure pr_cleanup_review_workspace \
  pr_execute_review_command pr_run_review_for_pr process_pr_reviewer; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

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

assert_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected substring: $needle"
    echo "  actual: $haystack"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_file_exists() {
  local label="$1"
  local path="$2"
  if [ -e "$path" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  missing: $path"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT
export LOG_DIR="$tmp_root/logs"
mkdir -p "$LOG_DIR"
export REPO="owner/repo"
export BASE_BRANCH="main"
export PR_REVIEWER_GIT_TIMEOUT=10
export PR_REVIEWER_EXEC_TIMEOUT=10
export PR_REVIEWER_CODEX_CMD="codex-review {PROMPT_FILE}"
export PR_REVIEWER_ANTIGRAVITY_CMD="agy-review {PROMPT_FILE}"

setup_repo_case() {
  local case_dir="$1"
  local origin="$case_dir/origin.git"
  local seed="$case_dir/seed"
  local main_repo="$case_dir/main"
  local branch="codex/issue-132-wt"

  git init --bare --initial-branch=main "$origin" >/dev/null
  git init --initial-branch=main "$seed" >/dev/null
  git -C "$seed" config user.email "test@example.com"
  git -C "$seed" config user.name "Test User"
  printf 'base\n' > "$seed/file.txt"
  git -C "$seed" add file.txt
  git -C "$seed" commit -m "initial" >/dev/null
  git -C "$seed" remote add origin "$origin"
  git -C "$seed" push -u origin main >/dev/null
  git -C "$seed" checkout -b "$branch" >/dev/null
  printf 'feature\n' >> "$seed/file.txt"
  git -C "$seed" commit -am "feature" >/dev/null
  git -C "$seed" push -u origin "$branch" >/dev/null

  git clone "$origin" "$main_repo" >/dev/null 2>&1
  git -C "$main_repo" checkout main >/dev/null 2>&1
  git -C "$main_repo" worktree add "$case_dir/slot" -b "$branch" "origin/$branch" >/dev/null 2>&1
  printf 'keep me\n' > "$case_dir/slot/local-note.txt"

  printf '%s\n%s\n%s\n' "$main_repo" "$case_dir/slot" "$branch"
}

echo "--- PR Reviewer detached review workspace cases ---"
mapfile -t repo_info < <(setup_repo_case "$tmp_root/repo-case")
main_repo="${repo_info[0]}"
slot_wt="${repo_info[1]}"
head_branch="${repo_info[2]}"
expected_sha=$(git -C "$main_repo" rev-parse "origin/$head_branch")

out_file="$tmp_root/out.txt"
err_file="$tmp_root/err.txt"
result_file="$tmp_root/result.txt"
branch_file="$tmp_root/review-branch.txt"
sha_file="$tmp_root/review-sha.txt"
export PR_REVIEWER_WT_BRANCH_FILE="$branch_file"
export PR_REVIEWER_WT_SHA_FILE="$sha_file"
mkdir -p "$tmp_root/review-tmp"
export TMPDIR="$tmp_root/review-tmp"

(
  cd "$main_repo"
  pr_execute_review_command "$head_branch" \
    'printf "review ok\n"; git rev-parse --abbrev-ref HEAD > "$PR_REVIEWER_WT_BRANCH_FILE"; git rev-parse HEAD > "$PR_REVIEWER_WT_SHA_FILE"' \
    "codex" "$out_file" "$err_file" "$result_file"
)

assert_eq "Req 1.1 / 5.1: branch checkout 済み別 worktree があってもレビュー実行へ進む" "ran:0:clean" "$(cat "$result_file")"
assert_eq "Req 1.2: review workspace は detached HEAD で動く" "HEAD" "$(cat "$branch_file")"
assert_eq "Req 1.1: current head SHA をレビューする" "$expected_sha" "$(cat "$sha_file")"
assert_eq "Req 1.3 / 5.2: 実装用 slot は head branch のまま" "$head_branch" "$(git -C "$slot_wt" branch --show-current)"
assert_file_exists "Req 1.3 / 5.2: 実装用 slot の未保存 untracked を破棄しない" "$slot_wt/local-note.txt"
assert_eq "Req 1.4: main repo の checkout 状態を別 PR 用に汚さない" "main" "$(git -C "$main_repo" branch --show-current)"
leftover_review_wt=$(git -C "$main_repo" worktree list --porcelain | grep -F "idd-pr-reviewer." || true)
assert_eq "Req 1.4: 一時 review worktree は cleanup される" "" "$leftover_review_wt"

echo "--- workspace preparation failure handling cases ---"
failure_comment_file="$tmp_root/failure-comment.txt"
failure_log_file="$tmp_root/failure-log.txt"
: > "$failure_comment_file"

pr_already_processed() { return 1; }
pr_exec_fail_limit_reached() { return 1; }
pr_build_prompt_file() {
  mktemp "$tmp_root/prompt.XXXXXX"
}
pr_substitute_placeholders() {
  printf 'true\n'
}
pr_execute_review_command() {
  local out="$4" err="$5" result="$6"
  : > "$out"
  : > "$err"
  printf 'workspace-fail:checkout-conflict\n' > "$result"
  return 0
}
pr_post_error_comment() {
  printf 'pr=%s\nsha=%s\nkind=%s\ndetail=%s\ntool=%s\n' "$1" "$2" "$3" "$4" "$5" > "$failure_comment_file"
  return 0
}
pr_read_exec_fail_streak() { printf '0'; }
pr_record_exec_fail() { printf '1'; }
pr_reset_exec_fail() { :; }
pr_detect_usage_limit_reset_epoch() { printf ''; }
pr_handle_quota_wait() { return 0; }
pr_resolve_review_verdict() { printf 'iteration'; }
pr_try_post_formal_approval() { return 0; }
pr_post_review_comment() { return 0; }
pr_add_iteration_label() { return 0; }
pr_publish_codex_status() { return 0; }
adj_run_for_pr() { return 0; }
adj_warn() { :; }
pr_second_gate_enabled() { return 1; }
adj_gate_enabled() { return 1; }

pr_json=$(jq -nc \
  --arg branch "$head_branch" \
  --arg sha "$expected_sha" \
  '{number:19, headRefName:$branch, baseRefName:"main", headRefOid:$sha, url:"https://example.invalid/pr/19"}')
rc=0
pr_run_review_for_pr "$pr_json" "codex" 2>"$failure_log_file" || rc=$?
assert_eq "Req 2.3 / 5.3: workspace 準備失敗は errored として扱う" "3" "$rc"
assert_contains "Req 2.1: operator log に PR 番号を残す" "$(cat "$failure_log_file")" "PR #19"
assert_contains "Req 2.1: operator log に head branch を残す" "$(cat "$failure_log_file")" "head=$head_branch"
assert_contains "Req 2.1 / 2.2: operator log に checkout 衝突分類を残す" "$(cat "$failure_log_file")" "class=checkout-conflict"
assert_contains "Req 2.3 / 3.2: 人間可視の失敗 marker kind を投稿する" "$(cat "$failure_comment_file")" "kind=workspace-prepare-failed"
assert_contains "Req 2.5: public comment は分類だけを含む" "$(cat "$failure_comment_file")" "failure: \`checkout-conflict\`"

echo "--- PR Reviewer opt-out case ---"
optout_called_file="$tmp_root/optout-called"
pr_fetch_candidate_prs() {
  printf 'called\n' > "$optout_called_file"
  printf '[]\n'
}
export PR_REVIEWER_ENABLED="false"
process_pr_reviewer
if [ -e "$optout_called_file" ]; then
  optout_called="called"
else
  optout_called=""
fi
assert_eq "Req 4.1 / 5.4: PR_REVIEWER_ENABLED!=true では PR を列挙しない" "" "$optout_called"

if [ "$FAIL_COUNT" -ne 0 ]; then
  echo "FAIL: $FAIL_COUNT assertion(s) failed"
  exit 1
fi

echo "PASS: $PASS_COUNT assertion(s) passed"
