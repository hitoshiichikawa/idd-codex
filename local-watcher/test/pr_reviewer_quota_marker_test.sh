#!/usr/bin/env bash
#
# 用途: PR Reviewer 由来の quota wait marker と PR Iteration resume の分離、
#       usage-limit fatal から quota wait へ退避する PR Reviewer 経路を検証する。
# 配置先: local-watcher/test/pr_reviewer_quota_marker_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/pr_reviewer_quota_marker_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_UTILS_SH="$SCRIPT_DIR/../bin/idd-codex-modules/core_utils.sh"
QUOTA_AWARE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/quota-aware.sh"
MODEL_PREFLIGHT_SH="$SCRIPT_DIR/../bin/idd-codex-modules/model-preflight.sh"
PR_REVIEWER_SH="$SCRIPT_DIR/../bin/idd-codex-modules/pr-reviewer.sh"
PR_ITERATION_SH="$SCRIPT_DIR/../bin/idd-codex-modules/pr-iteration.sh"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/pr_reviewer_usage_limit"

if [ ! -f "$CORE_UTILS_SH" ]; then
  echo "ERROR: cannot find core_utils.sh at $CORE_UTILS_SH" >&2
  exit 2
fi
if [ ! -f "$QUOTA_AWARE_SH" ]; then
  echo "ERROR: cannot find quota-aware.sh at $QUOTA_AWARE_SH" >&2
  exit 2
fi
if [ ! -f "$MODEL_PREFLIGHT_SH" ]; then
  echo "ERROR: cannot find model-preflight.sh at $MODEL_PREFLIGHT_SH" >&2
  exit 2
fi
if [ ! -f "$PR_REVIEWER_SH" ]; then
  echo "ERROR: cannot find pr-reviewer.sh at $PR_REVIEWER_SH" >&2
  exit 2
fi
if [ ! -f "$PR_ITERATION_SH" ]; then
  echo "ERROR: cannot find pr-iteration.sh at $PR_ITERATION_SH" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 2
fi
if [ ! -f "$FIXTURE_DIR/usage-limit-with-reset-stderr.jsonl" ]; then
  echo "ERROR: cannot find PR Reviewer usage-limit fixture" >&2
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
eval "$(extract_function "$CORE_UTILS_SH" "qa_format_iso8601")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$CORE_UTILS_SH" "pr_log")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$CORE_UTILS_SH" "pr_warn")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$CORE_UTILS_SH" "pr_error")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$QUOTA_AWARE_SH" "qa_detect_rate_limit")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$QUOTA_AWARE_SH" "qa_extract_usage_limit_reset_epoch")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$QUOTA_AWARE_SH" "qa_persist_reset_time")"
# shellcheck source=../bin/idd-codex-modules/model-preflight.sh
. "$MODEL_PREFLIGHT_SH"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_reviewer_quota_marker_reset")"
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
eval "$(extract_function "$PR_REVIEWER_SH" "pr_build_marker")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_post_error_comment")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_detect_usage_limit_reset_epoch")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_handle_quota_wait")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_run_review_for_pr")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_SH" "pi_pr_has_pr_reviewer_quota_marker")"

for fn in idd_secure_mktemp qa_format_iso8601 pr_log pr_warn pr_error qa_detect_rate_limit \
  qa_extract_usage_limit_reset_epoch qa_persist_reset_time \
  mp_detect_model_error mp_build_last_config_error_summary \
  pr_reviewer_quota_marker_reset pr_default_prompt pr_build_prompt_file \
  pr_placeholder_reject_reason pr_validate_placeholder_value \
  pr_substitute_placeholders pr_build_marker pr_post_error_comment pr_detect_usage_limit_reset_epoch \
  pr_handle_quota_wait pr_run_review_for_pr pi_pr_has_pr_reviewer_quota_marker; do
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

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
comments_file="$tmp_dir/comments.json"
labels_file="$tmp_dir/labels.txt"
export LOG_DIR="$tmp_dir/logs"
mkdir -p "$LOG_DIR"
printf '[]\n' > "$comments_file"
: > "$labels_file"

cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "api" ]; then
  cat "$PR_REVIEWER_QUOTA_TEST_COMMENTS"
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
    printf '%s\n' "$add_label" >> "$PR_REVIEWER_QUOTA_TEST_LABELS"
  fi
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
  tmp="${PR_REVIEWER_QUOTA_TEST_COMMENTS}.tmp"
  jq --arg body "$body" '. + [{"body": $body}]' "$PR_REVIEWER_QUOTA_TEST_COMMENTS" > "$tmp"
  mv "$tmp" "$PR_REVIEWER_QUOTA_TEST_COMMENTS"
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 99
STUB
chmod +x "$tmp_dir/gh"

export PATH="$tmp_dir:$PATH"
export PR_REVIEWER_QUOTA_TEST_COMMENTS="$comments_file"
export PR_REVIEWER_QUOTA_TEST_LABELS="$labels_file"
export REPO="owner/repo"
export BASE_BRANCH="main"
export LABEL_NEEDS_QUOTA_WAIT="codex-needs-quota-wait"
export PR_REVIEWER_GIT_TIMEOUT=5
export PR_REVIEWER_EXEC_TIMEOUT=5
export PR_REVIEWER_CODEX_CMD='codex --prompt {PROMPT_FILE}'
export REVIEWER_MODEL="gpt-5.4-old"
export PR_ITERATION_GIT_TIMEOUT=5
export LOG_DIR="$tmp_dir/logs"
export QUOTA_RESET_STATE_FILE="$tmp_dir/quota-reset-times.json"

echo "--- pr_reviewer quota marker cases ---"

printf '%s\n' '[{"body":"<!-- idd-codex:pr-reviewer-quota-wait reset=1778821200 sha=abc tool=codex -->"}]' > "$comments_file"
out=$(pr_reviewer_quota_marker_reset 57 || true)
assert_eq "wait marker returns reset epoch" "1778821200" "$out"
rc=0
pi_pr_has_pr_reviewer_quota_marker 57 || rc=$?
assert_eq "wait marker makes PR Iteration skip reviewer wait" "0" "$rc"

printf '%s\n' '[
  {"body":"<!-- idd-codex:pr-reviewer-quota-wait reset=1778821200 sha=abc tool=codex -->"},
  {"body":"<!-- idd-codex:pr-reviewer-quota-resume reset=1778821200 -->"}
]' > "$comments_file"
rc=0
pr_reviewer_quota_marker_reset 57 >/dev/null || rc=$?
assert_eq "resume marker clears active reviewer wait" "1" "$rc"
rc=0
pi_pr_has_pr_reviewer_quota_marker 57 || rc=$?
assert_eq "resume marker allows PR Iteration quota resume later" "1" "$rc"

echo ""
echo "--- pr_run_review_for_pr usage-limit quota wait case ---"

pr_already_processed() {
  return 1
}

pr_record_exec_fail() {
  return 0
}

pr_execute_review_command() {
  local _head_ref="$1"
  local _resolved_cmd="$2"
  local _tool="$3"
  local out_file="$4"
  local err_file="$5"
  local result_file="$6"

  : > "$out_file"
  case "${PR_REVIEWER_QUOTA_TEST_MODE:-quota}" in
    model-error)
      printf 'Error: unsupported model gpt-5.4-old\n' > "$err_file"
      printf 'ran:42:clean\n' > "$result_file"
      ;;
    *)
      cat "$FIXTURE_DIR/usage-limit-with-reset-stderr.jsonl" > "$err_file"
      printf 'ran:1:clean\n' > "$result_file"
      ;;
  esac
  return 0
}

printf '[]\n' > "$comments_file"
: > "$labels_file"
rm -f "$QUOTA_RESET_STATE_FILE"

expected_epoch=$(pr_detect_usage_limit_reset_epoch "$FIXTURE_DIR/usage-limit-with-reset-stderr.jsonl")
if [[ "$expected_epoch" =~ ^[0-9]+$ ]]; then
  assert_eq "fixture から reset epoch を抽出できる" "true" "true"
else
  assert_eq "fixture から reset epoch を抽出できる" "true" "false"
fi

pr_json='{"number":57,"headRefName":"codex/issue-12-quota","baseRefName":"main","headRefOid":"abc123","url":"https://github.com/owner/repo/pull/57"}'
rc=0
pr_run_review_for_pr "$pr_json" "codex" >/dev/null 2>&1 || rc=$?
assert_eq "usage-limit fatal の PR Reviewer は quota wait skip rc=2" "2" "$rc"
assert_eq "codex-needs-quota-wait ラベルを付与する" \
  "true" \
  "$(grep -qx 'codex-needs-quota-wait' "$labels_file" && echo true || echo false)"
assert_eq "PR Reviewer quota reset を永続化する" \
  "$expected_epoch" \
  "$(jq -r '."pr-reviewer-57" // ""' "$QUOTA_RESET_STATE_FILE")"
assert_eq "quota wait コメント marker を投稿する" \
  "true" \
  "$(jq -r 'any(.[]; (.body // "") | contains("idd-codex:pr-reviewer-quota-wait reset="))' "$comments_file")"
assert_eq "exec-failed コメントを投稿しない" \
  "false" \
  "$(jq -r 'any(.[]; (.body // "") | contains("exec-failed"))' "$comments_file")"

echo ""
echo "--- pr_run_review_for_pr model config error case ---"

export PR_REVIEWER_QUOTA_TEST_MODE="model-error"
printf '[]\n' > "$comments_file"
: > "$labels_file"
rm -f "$QUOTA_RESET_STATE_FILE"
mp_clear_last_config_error

rc=0
pr_run_review_for_pr "$pr_json" "codex" >/dev/null 2>&1 || rc=$?
assert_eq "model error の PR Reviewer は exec-error rc=3" "3" "$rc"
model_comment_body="$(jq -r '.[0].body // ""' "$comments_file")"
assert_eq "model error は quota wait label を付与しない" \
  "false" \
  "$(grep -qx 'codex-needs-quota-wait' "$labels_file" && echo true || echo false)"
assert_eq "model error comment includes setting-error wording" \
  "true" \
  "$(printf '%s' "$model_comment_body" | grep -Fq 'モデル設定エラーの可能性' && echo true || echo false)"
assert_eq "model error comment includes sanitized reason" \
  "true" \
  "$(printf '%s' "$model_comment_body" | grep -Fq 'unsupported-model' && echo true || echo false)"
assert_eq "model error comment includes reviewer model" \
  "true" \
  "$(printf '%s' "$model_comment_body" | grep -Fq 'gpt-5.4-old' && echo true || echo false)"
assert_eq "model error public comment uses correlation token" \
  "true" \
  "$(printf '%s' "$model_comment_body" | grep -Fq 'correlation:' && printf '%s' "$model_comment_body" | grep -Fq 'diagnostic' && echo true || echo false)"
assert_eq "model error public comment omits raw stderr line" \
  "false" \
  "$(printf '%s' "$model_comment_body" | grep -Fq 'Error: unsupported model' && echo true || echo false)"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
