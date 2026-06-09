#!/usr/bin/env bash
#
# 用途: per-task Reviewer range 解決で、task done marker 後の corrective commit が
#       silent に除外されないことを検証する。Issue #23 回帰テスト。
#
# 配置先: local-watcher/test/per_task_marker_review_range_test.sh
# 依存:   bash 4+, awk, git, grep
# 実行:   bash local-watcher/test/per_task_marker_review_range_test.sh

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
eval "$(extract_function "$WATCHER_SH" "pt_resolve_diff_range")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_build_diff_range_resolve_diagnostic")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "run_per_task_reviewer")"

if ! declare -F pt_resolve_diff_range >/dev/null; then
  echo "ERROR: pt_resolve_diff_range not loaded" >&2
  exit 2
fi
if ! declare -F pt_build_diff_range_resolve_diagnostic >/dev/null; then
  echo "ERROR: pt_build_diff_range_resolve_diagnostic not loaded" >&2
  exit 2
fi
if ! declare -F run_per_task_reviewer >/dev/null; then
  echo "ERROR: run_per_task_reviewer not loaded" >&2
  exit 2
fi

pt_log() {
  printf '[test] %s\n' "$*"
}

extract_review_result_token() {
  printf 'reject\n'
}

build_per_task_reviewer_prompt() {
  local task_id="$1"
  local range_start="$2"
  local range_end="$3"
  local round="$4"
  local prev_result="$5"

  {
    printf 'task=%s\n' "$task_id"
    printf 'round=%s\n' "$round"
    printf 'range_start=%s\n' "$range_start"
    printf 'range_end=%s\n' "$range_end"
    printf 'prev_result=%s\n' "$prev_result"
  } >"$PROMPT_CAPTURE_FILE"

  printf 'test prompt task=%s round=%s range=%s..%s\n' \
    "$task_id" "$round" "$range_start" "$range_end"
}

qa_run_codex_stage() {
  local _stage="$1"
  local _reset_file="$2"
  shift 2
  if [ "${1:-}" = "--" ]; then
    shift
  fi
  "$@"
}

codex_exec_prompt() {
  local _stage="$1"
  local _model="$2"
  local prompt="$3"
  printf '%s\n' "$prompt" >"$CODEX_PROMPT_CAPTURE_FILE"
}

parse_review_result() {
  local _notes_path="$1"
  printf 'approve\t\t5.2,5.3\n'
}

qa_handle_quota_exceeded() {
  return 0
}

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
    echo "  in    : $(printf '%q' "$haystack")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_log_subject_at() {
  local label="$1" repo="$2" position="$3" expected="$4"
  local actual
  actual=$(git -C "$repo" log --reverse --format=%s | sed -n "${position}p")
  assert_eq "$label" "$expected" "$actual"
}

setup_marker_retry_fixture() {
  local repo="$1"
  local corrective_label="$2"

  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "idd-codex-test@example.invalid"
  git -C "$repo" config user.name "idd-codex test"
  git -C "$repo" checkout -q -b main

  printf '%s\n' "base" >"$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "chore: base"

  git -C "$repo" checkout -q -b codex/issue-23-test
  printf '%s\n' "implementation" >"$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "fix(watcher): initial task implementation"

  git -C "$repo" commit -q --allow-empty -m "docs(tasks): mark 1.1 as done"

  printf '%s\n' "$corrective_label" >"$repo/fix.txt"
  git -C "$repo" add fix.txt
  git -C "$repo" commit -q -m "fix(watcher): ${corrective_label}"
}

run_reviewer_retry_range_case() {
  local label="$1"
  local round="$2"
  local req_id="$3"
  local repo="$TMPROOT/$label"
  setup_marker_retry_fixture "$repo" "$label corrective commit after marker"

  local head_sha log_file prompt_file codex_prompt_file rc=0
  head_sha=$(git -C "$repo" rev-parse HEAD)
  log_file="$repo/reviewer.log"
  prompt_file="$repo/reviewer-prompt.capture"
  codex_prompt_file="$repo/codex-prompt.capture"
  : >"$log_file"

  (
    cd "$repo"
    BASE_BRANCH=main \
      LOG="$log_file" \
      REPO_DIR="$repo" \
      SPEC_DIR_REL="docs/specs/23--bug-per-task-commit-task-marker-review" \
      REVIEWER_MODEL="test-reviewer" \
      REVIEWER_MAX_TURNS="1" \
      REPO_SLUG="idd-codex-test" \
      NUMBER="23" \
      PROMPT_CAPTURE_FILE="$prompt_file" \
      CODEX_PROMPT_CAPTURE_FILE="$codex_prompt_file" \
      run_per_task_reviewer "1.1" "$round"
  ) || rc=$?

  assert_log_subject_at "Req ${req_id}: ${label} fixture は階層 task marker を再現する" \
    "$repo" "3" "docs(tasks): mark 1.1 as done"
  assert_eq "Req ${req_id}: ${label} Reviewer round=${round} は stub approve で成功する" "0" "$rc"
  assert_contains "Req ${req_id}: ${label} Reviewer prompt は task=1.1 を対象にする" \
    "task=1.1" \
    "$(cat "$prompt_file")"
  assert_contains "Req ${req_id}: ${label} Reviewer prompt の range_end は marker 後 HEAD" \
    "range_end=${head_sha}" \
    "$(cat "$prompt_file")"
  assert_contains "Req ${req_id}: ${label} Reviewer 起動前ログに補正後 range を残す" \
    "reviewer start round=${round}" \
    "$(cat "$log_file")"
  assert_contains "Req ${req_id}: ${label} marker 後 commit を silent に除外しない" \
    "post-marker-commits-included task=1.1" \
    "$(cat "$log_file")"
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

echo "--- pt_resolve_diff_range post-marker corrective commit (Issue #23 Req 5.1) ---"

git -C "$TMPROOT" init -q
git -C "$TMPROOT" config user.email "idd-codex-test@example.invalid"
git -C "$TMPROOT" config user.name "idd-codex test"
git -C "$TMPROOT" checkout -q -b main

printf '%s\n' "base" >"$TMPROOT/file.txt"
git -C "$TMPROOT" add file.txt
git -C "$TMPROOT" commit -q -m "chore: base"
base_sha=$(git -C "$TMPROOT" rev-parse HEAD)

git -C "$TMPROOT" checkout -q -b codex/issue-23-test
printf '%s\n' "implementation" >"$TMPROOT/file.txt"
git -C "$TMPROOT" add file.txt
git -C "$TMPROOT" commit -q -m "fix(watcher): initial task implementation"

git -C "$TMPROOT" commit -q --allow-empty -m "docs(tasks): mark 1.1 as done"
marker_sha=$(git -C "$TMPROOT" rev-parse HEAD)

printf '%s\n' "corrective fix" >"$TMPROOT/fix.txt"
git -C "$TMPROOT" add fix.txt
git -C "$TMPROOT" commit -q -m "fix(watcher): corrective commit after marker"
head_sha=$(git -C "$TMPROOT" rev-parse HEAD)

assert_log_subject_at "Req 5.1: fixture commit 1 は base commit" "$TMPROOT" "1" "chore: base"
assert_log_subject_at "Req 5.1: fixture commit 2 は task implementation commit" "$TMPROOT" "2" "fix(watcher): initial task implementation"
assert_log_subject_at "Req 5.1: fixture commit 3 は階層 task marker commit" "$TMPROOT" "3" "docs(tasks): mark 1.1 as done"
assert_log_subject_at "Req 5.1: fixture commit 4 は marker 後 corrective commit" "$TMPROOT" "4" "fix(watcher): corrective commit after marker"

stderr_file="$TMPROOT/resolve.err"
range_line=$(cd "$TMPROOT" && BASE_BRANCH=main pt_resolve_diff_range "1.1" 2>"$stderr_file")
range_start=$(printf '%s' "$range_line" | cut -f1)
range_end=$(printf '%s' "$range_line" | cut -f2)
stderr_out=$(cat "$stderr_file")

assert_eq "Req 5.1: range_start は base SHA" "$base_sha" "$range_start"
assert_eq "Req 5.1: marker 後 corrective commit がある場合 range_end は HEAD" "$head_sha" "$range_end"
assert_contains "Req 2.2 / 3.4: post-marker include 診断を stderr に残す" \
  "post-marker-commits-included task=1.1 marker=${marker_sha} end=${head_sha} count=1" \
  "$stderr_out"
assert_contains "Req 5.1: resolved range の diff に corrective commit の変更が含まれる" \
  "fix.txt" \
  "$(git -C "$TMPROOT" diff --name-only "${range_start}..${range_end}")"

post_marker_diagnostic=$(cd "$TMPROOT" && BASE_BRANCH=main pt_build_diff_range_resolve_diagnostic "1.1")
assert_contains "Req 3.4: 診断に affected range を含める" \
  "- affected range: \`${marker_sha}..${head_sha}\`" \
  "$post_marker_diagnostic"
assert_contains "Req 3.4: 診断に marker 後 commit 数を含める" \
  "- marker 後 commit: 1 commit(s)" \
  "$post_marker_diagnostic"

missing_marker_diagnostic=$(cd "$TMPROOT" && BASE_BRANCH=main pt_build_diff_range_resolve_diagnostic "2")
assert_contains "Req 3.4: marker 不在時の unsafe reason を明示する" \
  "- unsafe reason: \`marker-not-found\`" \
  "$missing_marker_diagnostic"
assert_contains "Req 3.4: marker 不在時も直近 marker 候補を出す" \
  "docs(tasks): mark 1.1 as done" \
  "$missing_marker_diagnostic"

echo ""
echo "--- run_per_task_reviewer retry range guard (Issue #23 Req 5.2 / 5.3) ---"

run_reviewer_retry_range_case "reviewer-reject-retry" "2" "5.2"
run_reviewer_retry_range_case "debugger-guidance-retry" "3" "5.3"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
