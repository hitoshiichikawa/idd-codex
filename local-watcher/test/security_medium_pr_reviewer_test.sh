#!/usr/bin/env bash
#
# 用途: Issue #52 task 6 の PR Reviewer placeholder validation と public error redaction を検証する。
# 依存: bash 4+, awk, jq, mktemp
# 実行: bash local-watcher/test/security_medium_pr_reviewer_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CORE_UTILS_SH="$REPO_ROOT/local-watcher/bin/idd-codex-modules/core_utils.sh"
PR_REVIEWER_SH="$REPO_ROOT/local-watcher/bin/idd-codex-modules/pr-reviewer.sh"

[ -f "$CORE_UTILS_SH" ] || { echo "ERROR: core_utils.sh not found" >&2; exit 2; }
[ -f "$PR_REVIEWER_SH" ] || { echo "ERROR: pr-reviewer.sh not found" >&2; exit 2; }
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
eval "$(extract_function "$PR_REVIEWER_SH" "pr_placeholder_reject_reason")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_validate_placeholder_value")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_substitute_placeholders")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_build_marker")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_post_error_comment")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_default_prompt")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_build_prompt_file")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_detect_usage_limit_reset_epoch")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_write_exec_failure_diagnostic")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_run_review_for_pr")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_fetch_candidate_prs")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_resolve_tool")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "process_pr_reviewer")"

for fn in idd_secure_mktemp pr_log pr_warn pr_error \
  pr_placeholder_reject_reason pr_validate_placeholder_value \
  pr_substitute_placeholders pr_build_marker pr_post_error_comment \
  pr_default_prompt pr_build_prompt_file pr_detect_usage_limit_reset_epoch \
  pr_write_exec_failure_diagnostic pr_run_review_for_pr pr_fetch_candidate_prs \
  pr_resolve_tool process_pr_reviewer; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

PASS=0
FAIL=0

pass() {
  echo "  ok: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  NG: $1" >&2
  FAIL=$((FAIL + 1))
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    fail "$label (expected=$(printf '%q' "$expected") actual=$(printf '%q' "$actual"))"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if grep -Fq -- "$needle" <<< "$haystack"; then
    pass "$label"
  else
    fail "$label (missing $(printf '%q' "$needle"))"
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if grep -Fq -- "$needle" <<< "$haystack"; then
    fail "$label (unexpected $(printf '%q' "$needle"))"
  else
    pass "$label"
  fi
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
comments_file="$TMPROOT/comments.json"
pr_list_file="$TMPROOT/pr-list.json"
exec_called_file="$TMPROOT/execute-called"
printf '[]\n' > "$comments_file"
printf '[]\n' > "$pr_list_file"

cat > "$TMPROOT/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  cat "$SECURITY_MEDIUM_PR_REVIEWER_PR_LIST"
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "comment" ]; then
  body=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --body)
        shift
        body="${1:-}"
        ;;
    esac
    shift || true
  done
  tmp="${SECURITY_MEDIUM_PR_REVIEWER_COMMENTS}.tmp"
  jq --arg body "$body" '. + [{"body": $body}]' "$SECURITY_MEDIUM_PR_REVIEWER_COMMENTS" > "$tmp"
  mv "$tmp" "$SECURITY_MEDIUM_PR_REVIEWER_COMMENTS"
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 99
STUB
chmod +x "$TMPROOT/gh"

export PATH="$TMPROOT:$PATH"
export LOG_DIR="$TMPROOT/logs"
export REPO="owner/repo"
export BASE_BRANCH="main"
export PR_REVIEWER_GIT_TIMEOUT=5
export PR_REVIEWER_EXEC_TIMEOUT=5
export PR_REVIEWER_PROMPT="Review {BASE} {HEAD} {PR}"
export PR_REVIEWER_CODEX_CMD="review --base {BASE} --head {HEAD} --pr {PR} --prompt {PROMPT_FILE}"
export PR_REVIEWER_HEAD_PATTERN="^codex/"
export PR_REVIEWER_MAX_PRS=10
export PR_REVIEWER_TOOL="codex"
export PR_REVIEWER_CODEX_ENABLED="false"
export PR_REVIEWER_ANTIGRAVITY_ENABLED="false"
export SECURITY_MEDIUM_PR_REVIEWER_COMMENTS="$comments_file"
export SECURITY_MEDIUM_PR_REVIEWER_PR_LIST="$pr_list_file"
mkdir -p "$LOG_DIR"

pr_already_processed() {
  return 1
}

pr_detect_usage_limit_reset_epoch() {
  printf '\n'
  return 0
}

pr_execute_review_command() {
  local _head_ref="$1"
  local _resolved_cmd="$2"
  local _tool="$3"
  local out_file="$4"
  local err_file="$5"
  local result_file="$6"

  printf 'stdout includes should-not-be-public\n' > "$out_file"
  printf '/home/operator/.config leaked path\nTOKEN=ghp_secret_should_stay_local\n' > "$err_file"
  printf 'ran:42:clean\n' > "$result_file"
  printf 'called\n' > "$exec_called_file"
  return 0
}

reset_state() {
  printf '[]\n' > "$comments_file"
  : > "$exec_called_file"
  rm -f "$exec_called_file"
}

echo "[case1] placeholder validation accepts normal values and rejects unsafe values"
normal_cmd=$(pr_substitute_placeholders \
  "review {BASE} {HEAD} {PR} {PROMPT_FILE}" \
  "main" \
  "codex/issue-52-safe_ref.1" \
  "52" \
  "$TMPROOT/prompt-file")
assert_eq "normal placeholders are substituted" \
  "review main codex/issue-52-safe_ref.1 52 $TMPROOT/prompt-file" \
  "$normal_cmd"

stderr_file="$TMPROOT/placeholder.stderr"
rc=0
pr_substitute_placeholders "review {HEAD}" "main" $'codex/issue-52\nnext' "52" "$TMPROOT/prompt" >"$TMPROOT/out" 2>"$stderr_file" || rc=$?
assert_eq "newline head placeholder is rejected" "1" "$rc"
assert_contains "warning includes field" "$(cat "$stderr_file")" "field=head"
assert_contains "warning includes reason category" "$(cat "$stderr_file")" "reason=newline"
assert_not_contains "warning does not include raw rejected value" "$(cat "$stderr_file")" "next"

assert_eq "glob metacharacter is rejected" \
  "glob" \
  "$(pr_placeholder_reject_reason "head" "codex/issue-*")"
assert_eq "leading dash is rejected as option-like" \
  "leading-option" \
  "$(pr_placeholder_reject_reason "base" "-main")"
assert_eq "non-numeric PR number is rejected" \
  "non-numeric-pr" \
  "$(pr_placeholder_reject_reason "pr" "52;touch")"

echo "[case2] unsafe placeholder skip does not execute review or post public comments"
reset_state
unsafe_pr_json='{"number":52,"headRefName":"-danger","baseRefName":"main","headRefOid":"abc123","url":"https://github.com/owner/repo/pull/52"}'
rc=0
pr_run_review_for_pr "$unsafe_pr_json" "codex" >/dev/null 2>"$TMPROOT/unsafe.stderr" || rc=$?
assert_eq "unsafe placeholder returns skip/failure" "1" "$rc"
assert_eq "unsafe placeholder does not execute review command" "false" "$([ -e "$exec_called_file" ] && echo true || echo false)"
assert_eq "unsafe placeholder does not post public comment" "0" "$(jq 'length' "$comments_file")"
assert_contains "unsafe placeholder is operator-visible" "$(cat "$TMPROOT/unsafe.stderr")" "reason=leading-option"
assert_not_contains "unsafe placeholder warning omits raw value" "$(cat "$TMPROOT/unsafe.stderr")" "-danger"

echo "[case3] exec-failed public comment is redacted and local diagnostics are retained"
reset_state
safe_pr_json='{"number":52,"headRefName":"codex/issue-52-safe","baseRefName":"main","headRefOid":"abc123","url":"https://github.com/owner/repo/pull/52"}'
rc=0
pr_run_review_for_pr "$safe_pr_json" "codex" >/dev/null 2>"$TMPROOT/exec.stderr" || rc=$?
assert_eq "non-quota execution failure returns exec-error" "3" "$rc"
comment_body="$(jq -r '.[0].body' "$comments_file")"
assert_contains "public comment includes stable PR context" "$comment_body" "PR: #52"
assert_contains "public comment includes sha" "$comment_body" "abc123"
assert_contains "public comment includes tool" "$comment_body" "codex"
assert_contains "public comment includes exit code" "$comment_body" "exit: \`42\`"
assert_contains "public comment includes correlation token" "$comment_body" "correlation:"
assert_not_contains "public comment excludes stderr local path" "$comment_body" "/home/operator"
assert_not_contains "public comment excludes token-like stderr" "$comment_body" "ghp_secret_should_stay_local"
assert_not_contains "public comment excludes stdout excerpt" "$comment_body" "should-not-be-public"
assert_contains "local log records retained diagnostic path" "$(cat "$TMPROOT/exec.stderr")" "diagnostic retained path="
diag_path=$(awk -F'path=' '/diagnostic retained path=/ { split($2, a, " "); print a[1]; exit }' "$TMPROOT/exec.stderr")
assert_contains "local diagnostic retains stderr detail" "$(cat "$diag_path")" "ghp_secret_should_stay_local"
assert_contains "local diagnostic retains stdout detail" "$(cat "$diag_path")" "should-not-be-public"

echo "[case4] candidate filtering keeps head pattern and fork exclusion"
cat > "$pr_list_file" <<'JSON'
[
  {"number":10,"headRefName":"codex/issue-52-ok","headRefOid":"a","baseRefName":"main","isDraft":false,"url":"u1","headRepositoryOwner":{"login":"owner"}},
  {"number":11,"headRefName":"feature/manual","headRefOid":"b","baseRefName":"main","isDraft":false,"url":"u2","headRepositoryOwner":{"login":"owner"}},
  {"number":12,"headRefName":"codex/issue-52-fork","headRefOid":"c","baseRefName":"main","isDraft":false,"url":"u3","headRepositoryOwner":{"login":"someone"}},
  {"number":13,"headRefName":"codex/issue-52-draft","headRefOid":"d","baseRefName":"main","isDraft":true,"url":"u4","headRepositoryOwner":{"login":"owner"}}
]
JSON
filtered="$(pr_fetch_candidate_prs)"
assert_eq "head pattern and fork exclusion leave only one PR" "1" "$(jq 'length' <<< "$filtered")"
assert_eq "remaining PR is same-owner codex head" "10" "$(jq -r '.[0].number' <<< "$filtered")"

echo "[case5] disabled PR Reviewer remains no-op"
called_file="$TMPROOT/process-called"
pr_fetch_candidate_prs() {
  printf 'called\n' > "$called_file"
  printf '[]\n'
}
export PR_REVIEWER_ENABLED="false"
process_pr_reviewer
assert_eq "disabled processor does not fetch PRs" "false" "$([ -e "$called_file" ] && echo true || echo false)"
assert_eq "disabled processor does not post comments" "1" "$(jq 'length' "$comments_file")"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
