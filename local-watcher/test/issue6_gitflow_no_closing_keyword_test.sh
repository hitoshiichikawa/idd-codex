#!/usr/bin/env bash
#
# 用途: Gitflow no-closing-keyword 運用で Promote Pipeline が managed PR から
#       Issue 番号と merge SHA を解決できることを検証する。Issue #6 回帰テスト。
#
# 配置先: local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh
# 依存:   bash 4+, jq
# 実行:   bash local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/../bin"
CORE_UTILS_SH="$BIN_DIR/idd-codex-modules/core_utils.sh"
PROMOTE_PIPELINE_SH="$BIN_DIR/idd-codex-modules/promote-pipeline.sh"

if [ ! -f "$CORE_UTILS_SH" ] || [ ! -f "$PROMOTE_PIPELINE_SH" ]; then
  echo "ERROR: cannot find promote-pipeline dependencies under $BIN_DIR" >&2
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
  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  needle: $(printf '%q' "$needle")"
    echo "  in    : $(printf '%q' "$haystack")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    echo "FAIL: $label"
    echo "  unexpected needle: $(printf '%q' "$needle")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
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

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

FAKEBIN="$TMPROOT/fakebin"
EDIT_LOG="$TMPROOT/issue-edit.log"
mkdir -p "$FAKEBIN"
: > "$EDIT_LOG"

cat > "$FAKEBIN/timeout" <<'EOF_TIMEOUT'
#!/usr/bin/env bash
set -euo pipefail
shift
exec "$@"
EOF_TIMEOUT
chmod +x "$FAKEBIN/timeout"

cat > "$FAKEBIN/gh" <<'EOF_GH'
#!/usr/bin/env bash
set -euo pipefail

merged_prs_json() {
  cat <<'EOF_JSON'
[
  {
    "number":101,
    "headRepositoryOwner":{"login":"owner"},
    "isCrossRepository":false,
    "headRefName":"feature/closing",
    "baseRefName":"develop",
    "title":"manual closing ref",
    "body":"unmanaged body mentions #66 but closing ref wins",
    "mergeCommit":{"oid":"sha101"},
    "closingIssuesReferences":[{"number":18}],
    "mergedAt":"2026-06-01T00:00:00Z",
    "updatedAt":"2026-06-01T00:00:00Z"
  },
  {
    "number":102,
    "headRepositoryOwner":{"login":"owner"},
    "isCrossRepository":false,
    "headRefName":"codex/issue-20-impl-gitflow-no-close",
    "baseRefName":"develop",
    "title":"fix(#20): no closing keyword",
    "body":"Refs #21",
    "mergeCommit":{"oid":"sha102"},
    "closingIssuesReferences":[],
    "mergedAt":"2026-06-02T00:00:00Z",
    "updatedAt":"2026-06-02T00:00:00Z"
  },
  {
    "number":103,
    "headRepositoryOwner":{"login":"owner"},
    "isCrossRepository":false,
    "headRefName":"feature/manual-reference",
    "baseRefName":"develop",
    "title":"manual note",
    "body":"Refs #22",
    "mergeCommit":{"oid":"sha103"},
    "closingIssuesReferences":[],
    "mergedAt":"2026-06-03T00:00:00Z",
    "updatedAt":"2026-06-03T00:00:00Z"
  },
  {
    "number":104,
    "headRepositoryOwner":{"login":"someone"},
    "isCrossRepository":true,
    "headRefName":"codex/issue-23-impl-fork",
    "baseRefName":"develop",
    "title":"fix(#23): fork should not auto-label",
    "body":"Refs #23",
    "mergeCommit":{"oid":"sha104"},
    "closingIssuesReferences":[{"number":23}],
    "mergedAt":"2026-06-04T00:00:00Z",
    "updatedAt":"2026-06-04T00:00:00Z"
  },
  {
    "number":105,
    "headRepositoryOwner":{"login":"owner"},
    "isCrossRepository":false,
    "headRefName":"codex/manual-title-issue",
    "baseRefName":"develop",
    "title":"fix issue-24 without closing",
    "body":"Refs #25",
    "mergeCommit":{"oid":"sha105"},
    "closingIssuesReferences":[],
    "mergedAt":"2026-06-05T00:00:00Z",
    "updatedAt":"2026-06-05T00:00:00Z"
  }
]
EOF_JSON
}

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  merged_prs_json
  exit 0
fi

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  case "${3:-}" in
    300)
      printf '%s\n' 'sha300'
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  case "${3:-}" in
    21)
      printf '%s\n' '{"labels":[{"name":"codex-staged-for-release"}]}'
      exit 0
      ;;
    30)
      printf '%s\n' '{"closedByPullRequestsReferences":[{"number":300,"state":"MERGED"}],"labels":[]}'
      exit 0
      ;;
    *)
      printf '%s\n' '{"closedByPullRequestsReferences":[],"labels":[]}'
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "edit" ]; then
  printf '%s\n' "${3:-}" >> "${EDIT_LOG:?}"
  exit 0
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  printf '%s\n' '18'
  printf '%s\n' '20'
  printf '%s\n' '21'
  printf '%s\n' '24'
  printf '%s\n' '25'
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 99
EOF_GH
chmod +x "$FAKEBIN/gh"

export PATH="$FAKEBIN:$PATH"
export EDIT_LOG
export REPO="owner/repo"
export BASE_BRANCH="develop"
export PROMOTION_TARGET_BRANCH="main"
export PROMOTE_GIT_TIMEOUT="60"
export LABEL_STAGED_FOR_RELEASE="codex-staged-for-release"

# shellcheck source=/dev/null
source "$CORE_UTILS_SH"
# shellcheck source=/dev/null
source "$PROMOTE_PIPELINE_SH"

echo "--- managed PR issue resolver ---"

managed_rows=$(pp_pr_issue_candidate_rows '{
  "number":102,
  "headRepositoryOwner":{"login":"owner"},
  "isCrossRepository":false,
  "headRefName":"codex/issue-20-impl-gitflow-no-close",
  "title":"fix(#20): no closing keyword",
  "body":"Refs #21",
  "closingIssuesReferences":[]
}' "owner")
assert_contains "managed branch extracts head issue" $'20\thead\t102' "$managed_rows"
assert_contains "managed body plain reference is accepted" $'21\tbody-plain\t102' "$managed_rows"

unmanaged_rows=$(pp_pr_issue_candidate_rows '{
  "number":103,
  "headRepositoryOwner":{"login":"owner"},
  "isCrossRepository":false,
  "headRefName":"feature/manual-reference",
  "title":"manual note",
  "body":"Refs #22",
  "closingIssuesReferences":[]
}' "owner")
assert_eq "unmanaged body plain reference is ignored" "" "$unmanaged_rows"

fork_rows=$(pp_pr_issue_candidate_rows '{
  "number":104,
  "headRepositoryOwner":{"login":"someone"},
  "isCrossRepository":true,
  "headRefName":"codex/issue-23-impl-fork",
  "title":"fix(#23): fork should not auto-label",
  "body":"Refs #23",
  "closingIssuesReferences":[{"number":23}]
}' "owner")
assert_eq "fork PR is excluded" "" "$fork_rows"

echo "--- promote auto-label collection ---"

promote_err="$TMPROOT/promote.err"
promote_out="$(pp_collect_merged_issues 2>"$promote_err")"
assert_eq "promote stdout lists staged issues only" $'18\n20\n21\n24\n25' "$promote_out"
edit_log=$(sort -n "$EDIT_LOG")
assert_eq "auto-label edits skip already-labeled issue" $'18\n20\n24\n25' "$edit_log"
assert_not_contains "unmanaged plain reference is not auto-labeled" "22" "$edit_log"
assert_not_contains "fork PR is not auto-labeled" "23" "$edit_log"
promote_log="$(cat "$promote_err")"
assert_contains "auto-label log reports managed head/title sources" "resolver_sources=head,title" "$promote_log"
assert_contains "auto-label log reports managed body source" "resolver_sources=body-plain" "$promote_log"

echo "--- promote merge SHA resolver ---"

closed_sha=$(pp_resolve_merge_sha 30)
assert_eq "closedByPullRequestsReferences path remains compatible" "sha300" "$closed_sha"

managed_sha=$(pp_resolve_merge_sha 20)
assert_eq "no-closing managed PR fallback resolves merge sha" "sha102" "$managed_sha"

assert_failure "unmanaged body reference does not resolve merge sha" pp_resolve_merge_sha 22

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
