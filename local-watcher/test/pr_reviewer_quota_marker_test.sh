#!/usr/bin/env bash
#
# 用途: PR Reviewer 由来の quota wait marker と PR Iteration resume の分離を検証する。
# 配置先: local-watcher/test/pr_reviewer_quota_marker_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/pr_reviewer_quota_marker_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_REVIEWER_SH="$SCRIPT_DIR/../bin/modules/pr-reviewer.sh"
PR_ITERATION_SH="$SCRIPT_DIR/../bin/modules/pr-iteration.sh"

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
eval "$(extract_function "$PR_REVIEWER_SH" "pr_reviewer_quota_marker_reset")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_SH" "pi_pr_has_pr_reviewer_quota_marker")"

for fn in pr_reviewer_quota_marker_reset pi_pr_has_pr_reviewer_quota_marker; do
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

cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "api" ]; then
  cat "$PR_REVIEWER_QUOTA_TEST_COMMENTS"
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 99
STUB
chmod +x "$tmp_dir/gh"

export PATH="$tmp_dir:$PATH"
export PR_REVIEWER_QUOTA_TEST_COMMENTS="$comments_file"
export REPO="owner/repo"
export PR_REVIEWER_GIT_TIMEOUT=5
export PR_ITERATION_GIT_TIMEOUT=5

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
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
