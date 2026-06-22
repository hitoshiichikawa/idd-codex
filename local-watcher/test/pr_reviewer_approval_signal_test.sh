#!/usr/bin/env bash
#
# 用途: PR Reviewer の approve verdict、formal review 投稿、marker fallback を検証する。
# 配置先: local-watcher/test/pr_reviewer_approval_signal_test.sh
# 依存:   bash 4+, jq
# 実行:   bash local-watcher/test/pr_reviewer_approval_signal_test.sh

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
eval "$(extract_function "$PR_REVIEWER_SH" "pr_build_marker")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_default_prompt")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_build_prompt_file")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_placeholder_reject_reason")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_validate_placeholder_value")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_substitute_placeholders")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_post_review_comment")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_detect_usage_limit_reset_epoch")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_detect_iteration_keyword")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_detect_approval_keyword")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_resolve_review_verdict")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_try_post_formal_approval")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_add_iteration_label")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_run_review_for_pr")"

for fn in idd_secure_mktemp pr_log pr_warn pr_error pr_build_marker pr_default_prompt \
  pr_build_prompt_file pr_placeholder_reject_reason pr_validate_placeholder_value \
  pr_substitute_placeholders pr_post_review_comment \
  pr_detect_usage_limit_reset_epoch pr_detect_iteration_keyword \
  pr_detect_approval_keyword pr_resolve_review_verdict \
  pr_try_post_formal_approval pr_add_iteration_label pr_run_review_for_pr; do
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

assert_file_contains() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if grep -Fq "$pattern" "$file"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected substring: $pattern"
    echo "  file: $file"
    echo "  content:"
    sed 's/^/    /' "$file" || true
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
comments_file="$tmp_dir/comments.json"
formal_file="$tmp_dir/formal-reviews.txt"
labels_file="$tmp_dir/labels.txt"
export LOG_DIR="$tmp_dir/logs"
mkdir -p "$LOG_DIR"
printf '[]\n' > "$comments_file"
: > "$formal_file"
: > "$labels_file"

cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "review" ]; then
  body_file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --body-file)
        shift
        body_file="${1:-}"
        ;;
    esac
    shift || true
  done
  if [ "${PR_REVIEWER_APPROVAL_SIGNAL_TEST_FORMAL_FAIL:-false}" = "true" ]; then
    echo "GraphQL: Resource not accessible by integration" >&2
    exit 22
  fi
  cat "$body_file" >> "$PR_REVIEWER_APPROVAL_SIGNAL_TEST_FORMAL"
  printf '\n---\n' >> "$PR_REVIEWER_APPROVAL_SIGNAL_TEST_FORMAL"
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
  tmp="${PR_REVIEWER_APPROVAL_SIGNAL_TEST_COMMENTS}.tmp"
  jq --arg body "$body" '. + [{"body": $body}]' "$PR_REVIEWER_APPROVAL_SIGNAL_TEST_COMMENTS" > "$tmp"
  mv "$tmp" "$PR_REVIEWER_APPROVAL_SIGNAL_TEST_COMMENTS"
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "edit" ]; then
  add_label=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --add-label)
        shift
        add_label="${1:-}"
        ;;
    esac
    shift || true
  done
  if [ -n "$add_label" ]; then
    printf '%s\n' "$add_label" >> "$PR_REVIEWER_APPROVAL_SIGNAL_TEST_LABELS"
  fi
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 99
STUB
chmod +x "$tmp_dir/gh"

export PATH="$tmp_dir:$PATH"
export PR_REVIEWER_APPROVAL_SIGNAL_TEST_COMMENTS="$comments_file"
export PR_REVIEWER_APPROVAL_SIGNAL_TEST_FORMAL="$formal_file"
export PR_REVIEWER_APPROVAL_SIGNAL_TEST_LABELS="$labels_file"
export REPO="owner/repo"
export BASE_BRANCH="main"
export LABEL_NEEDS_ITERATION="codex-needs-iteration"
export PR_REVIEWER_GIT_TIMEOUT=5
export PR_REVIEWER_EXEC_TIMEOUT=5
export PR_REVIEWER_CODEX_CMD='codex --prompt {PROMPT_FILE}'
export PR_REVIEWER_ITERATION_PATTERN='^[[:space:]]*VERDICT:[[:space:]]*codex-needs-iteration[[:space:]]*$'

pr_already_processed() {
  return 1
}

pr_execute_review_command() {
  local _head_ref="$1"
  local _resolved_cmd="$2"
  local _tool="$3"
  local out_file="$4"
  local err_file="$5"
  local result_file="$6"

  printf '%s\n' "$PR_REVIEWER_APPROVAL_SIGNAL_TEST_REVIEW_TEXT" > "$out_file"
  : > "$err_file"
  printf 'ran:0:clean\n' > "$result_file"
  return 0
}

reset_state() {
  printf '[]\n' > "$comments_file"
  : > "$formal_file"
  : > "$labels_file"
  export PR_REVIEWER_APPROVAL_SIGNAL_TEST_FORMAL_FAIL="false"
}

pr_json='{"number":57,"headRefName":"codex/issue-13-approve","baseRefName":"main","headRefOid":"abc123","url":"https://github.com/owner/repo/pull/57"}'

echo "--- verdict parser cases ---"

assert_eq "approve verdict を解決する" \
  "approve" \
  "$(pr_resolve_review_verdict 57 $'## 結論\nVERDICT: approve')"
assert_eq "iteration verdict を解決する" \
  "iteration" \
  "$(pr_resolve_review_verdict 57 $'## 結論\nVERDICT: codex-needs-iteration')"
assert_eq "approve と iteration の混在は conflict" \
  "conflict" \
  "$(pr_resolve_review_verdict 57 $'VERDICT: approve\nVERDICT: codex-needs-iteration')"
assert_eq "verdict なしは none" \
  "none" \
  "$(pr_resolve_review_verdict 57 $'## 結論\n指摘なし')"

echo ""
echo "--- pr_run_review_for_pr approval signal cases ---"

reset_state
export PR_REVIEWER_APPROVAL_SIGNAL_TEST_REVIEW_TEXT=$'## 概要\napprove case\n## 結論\nVERDICT: approve'
rc=0
pr_run_review_for_pr "$pr_json" "codex" >/dev/null 2>&1 || rc=$?
assert_eq "approve は正常終了する" "0" "$rc"
assert_eq "formal approval を投稿する" \
  "true" \
  "$(grep -q 'VERDICT: approve' "$formal_file" && echo true || echo false)"
assert_eq "approve comment marker を残す" \
  "true" \
  "$(jq -r 'any(.[]; (.body // "") | contains("idd-codex:pr-reviewer sha=abc123 kind=review tool=codex"))' "$comments_file")"
assert_eq "approve では iteration label を付けない" \
  "false" \
  "$(grep -qx 'codex-needs-iteration' "$labels_file" && echo true || echo false)"

reset_state
export PR_REVIEWER_APPROVAL_SIGNAL_TEST_FORMAL_FAIL="true"
export PR_REVIEWER_APPROVAL_SIGNAL_TEST_REVIEW_TEXT=$'## 概要\nfallback case\n## 結論\nVERDICT: approve'
fallback_stderr="$tmp_dir/formal-fallback.stderr"
rc=0
pr_run_review_for_pr "$pr_json" "codex" >/dev/null 2>"$fallback_stderr" || rc=$?
assert_eq "formal approval 失敗でも正常終了する" "0" "$rc"
assert_eq "formal approval 失敗時も marker comment を残す" \
  "true" \
  "$(jq -r 'any(.[]; (.body // "") | contains("idd-codex:pr-reviewer sha=abc123 kind=review tool=codex"))' "$comments_file")"
assert_file_contains "formal approval 失敗時に WARN を出す" \
  "WARN: PR #57: GitHub formal approval 投稿に失敗" "$fallback_stderr"
assert_file_contains "formal approval 失敗理由を WARN に含める" \
  "GraphQL: Resource not accessible by integration" "$fallback_stderr"
assert_file_contains "formal approval fallback 継続を WARN に含める" \
  "marker approval fallback を継続" "$fallback_stderr"
assert_file_contains "formal approval WARN に tool と sha を含める" \
  "tool=codex sha=abc123" "$fallback_stderr"

reset_state
export PR_REVIEWER_APPROVAL_SIGNAL_TEST_REVIEW_TEXT=$'## 概要\niteration case\n## 結論\nVERDICT: codex-needs-iteration'
rc=0
pr_run_review_for_pr "$pr_json" "codex" >/dev/null 2>&1 || rc=$?
assert_eq "iteration は正常終了する" "0" "$rc"
assert_eq "iteration では formal approval を投稿しない" \
  "false" \
  "$(grep -q 'VERDICT:' "$formal_file" && echo true || echo false)"
assert_eq "iteration label を付ける" \
  "true" \
  "$(grep -qx 'codex-needs-iteration' "$labels_file" && echo true || echo false)"

reset_state
export PR_REVIEWER_APPROVAL_SIGNAL_TEST_REVIEW_TEXT=$'## 概要\nmixed case\n## 結論\nVERDICT: approve\nVERDICT: codex-needs-iteration'
rc=0
pr_run_review_for_pr "$pr_json" "codex" >/dev/null 2>&1 || rc=$?
assert_eq "mixed verdict は正常終了する" "0" "$rc"
assert_eq "mixed verdict では formal approval を投稿しない" \
  "false" \
  "$(grep -q 'VERDICT:' "$formal_file" && echo true || echo false)"
assert_eq "mixed verdict は iteration label を付ける" \
  "true" \
  "$(grep -qx 'codex-needs-iteration' "$labels_file" && echo true || echo false)"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
