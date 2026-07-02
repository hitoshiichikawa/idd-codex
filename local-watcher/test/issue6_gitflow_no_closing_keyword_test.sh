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
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BIN_DIR="$SCRIPT_DIR/../bin"
WATCHER_SH="$BIN_DIR/idd-codex-issue-watcher.sh"
CORE_UTILS_SH="$BIN_DIR/idd-codex-modules/core_utils.sh"
PROMOTE_PIPELINE_SH="$BIN_DIR/idd-codex-modules/promote-pipeline.sh"

if [ ! -f "$WATCHER_SH" ] || [ ! -f "$CORE_UTILS_SH" ] || [ ! -f "$PROMOTE_PIPELINE_SH" ]; then
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
  if grep -Fq -- "$needle" <<< "$haystack"; then
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
  if grep -Fq -- "$needle" <<< "$haystack"; then
    echo "FAIL: $label"
    echo "  unexpected needle: $(printf '%q' "$needle")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

assert_not_line() {
  local label="$1" needle="$2" haystack="$3"
  if grep -Fxq -- "$needle" <<< "$haystack"; then
    echo "FAIL: $label"
    echo "  unexpected line: $(printf '%q' "$needle")"
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
  },
  {
    "number":106,
    "headRepositoryOwner":{"login":"owner"},
    "isCrossRepository":false,
    "headRefName":"codex/issue-5-design-home-screen",
    "baseRefName":"develop",
    "title":"design(#5): home screen",
    "body":"Refs #5",
    "mergeCommit":{"oid":"sha106"},
    "closingIssuesReferences":[{"number":5}],
    "mergedAt":"2026-06-06T00:00:00Z",
    "updatedAt":"2026-06-06T00:00:00Z"
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

# Dependency Resolver 関数だけを読み込む。watcher のトップレベル副作用は実行しない。
dr_block=$(awk '
  /^dr_log\(\)/ {in_block=1}
  /^# 1 Issue を 1 slot worktree で処理する Worker 本体。/ {in_block=0}
  in_block {print}
' "$WATCHER_SH")
eval "$dr_block"

dr_gh_graphql_closed_by() {
  local _owner="$1"
  local _repo="$2"
  local dep_num="$3"
  case "$dep_num" in
    14)
      cat <<'EOF_JSON'
{"data":{"repository":{"issue":{"state":"OPEN","labels":{"nodes":[{"name":"codex-staged-for-release"}]},"closedByPullRequestsReferences":{"nodes":[]}}}}}
EOF_JSON
      ;;
    17)
      cat <<'EOF_JSON'
{"data":{"repository":{"issue":{"state":"CLOSED","labels":{"nodes":[]},"closedByPullRequestsReferences":{"nodes":[{"number":70,"state":"MERGED"}]}}}}}
EOF_JSON
      ;;
    *)
      cat <<'EOF_JSON'
{"data":{"repository":{"issue":{"state":"OPEN","labels":{"nodes":[]},"closedByPullRequestsReferences":{"nodes":[]}}}}}
EOF_JSON
      ;;
  esac
}

echo "--- dependency resolver multi-branch compatibility ---"

assert_eq "staged label resolves open dependency" \
  "resolved|staged-for-release" \
  "$(dr_resolve_one 14)"
assert_eq "base merged managed PR resolves open dependency" \
  "resolved|base-merged|#102" \
  "$(dr_resolve_one 20)"
assert_eq "unmanaged body reference remains unresolved" \
  "open|open" \
  "$(dr_resolve_one 22)"

BASE_BRANCH="main"
PROMOTION_TARGET_BRANCH="main"
assert_eq "single-branch closing PR remains resolved" \
  "resolved|closing-pr" \
  "$(dr_resolve_one 17)"
BASE_BRANCH="develop"
PROMOTION_TARGET_BRANCH="main"

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

design_rows=$(pp_pr_issue_candidate_rows '{
  "number":106,
  "headRepositoryOwner":{"login":"owner"},
  "isCrossRepository":false,
  "headRefName":"codex/issue-5-design-home-screen",
  "title":"design(#5): home screen",
  "body":"Refs #5",
  "closingIssuesReferences":[{"number":5}]
}' "owner")
assert_eq "design PR references are excluded from auto-label candidates" "" "$design_rows"

echo "--- promote auto-label collection ---"

promote_err="$TMPROOT/promote.err"
promote_out="$(pp_collect_merged_issues 2>"$promote_err")"
assert_eq "promote stdout lists staged issues only" $'18\n20\n21\n24\n25' "$promote_out"
edit_log=$(sort -n "$EDIT_LOG")
assert_eq "auto-label edits skip already-labeled issue" $'18\n20\n24\n25' "$edit_log"
assert_not_line "design PR is not auto-labeled" "5" "$edit_log"
assert_not_contains "unmanaged plain reference is not auto-labeled" "22" "$edit_log"
assert_not_contains "fork PR is not auto-labeled" "23" "$edit_log"
promote_log="$(cat "$promote_err")"
assert_contains "auto-label log reports managed head/title sources" "resolver_sources=head,title" "$promote_log"
assert_contains "auto-label log reports managed body source" "resolver_sources=body-plain" "$promote_log"
assert_contains "auto-label log reports design PR skip" "pr=#106 issue=#5 headRefName=codex/issue-5-design-home-screen design-pr auto-label skip" "$promote_log"

echo "--- promote merge SHA resolver ---"

closed_sha=$(pp_resolve_merge_sha 30)
assert_eq "closedByPullRequestsReferences path remains compatible" "sha300" "$closed_sha"

managed_sha=$(pp_resolve_merge_sha 20)
assert_eq "no-closing managed PR fallback resolves merge sha" "sha102" "$managed_sha"

assert_failure "unmanaged body reference does not resolve merge sha" pp_resolve_merge_sha 22

echo "--- PjM and README static policy ---"

PROJECT_MANAGER_MD="$REPO_ROOT/.codex/agents/project-manager.md"
PROJECT_MANAGER_TEMPLATE_MD="$REPO_ROOT/repo-template/.codex/agents/project-manager.md"
README_MD="$REPO_ROOT/README.md"

assert_success "project-manager root/template definitions stay byte-identical" \
  diff -q "$PROJECT_MANAGER_MD" "$PROJECT_MANAGER_TEMPLATE_MD"

project_manager_text="$(cat "$PROJECT_MANAGER_MD")"
readme_text="$(cat "$README_MD")"
assert_contains "PjM detects multi-branch before task completion state" \
  "if resolved_base != promotion_target:" "$project_manager_text"
assert_contains "PjM uses Refs for multi-branch final/design-less impl" \
  "最終 PR / design-less impl でも auto-close しない" "$project_manager_text"
assert_contains "README documents multi-branch Refs exception" \
  "multi-branch / Gitflow 例外" "$readme_text"
assert_contains "README documents managed PR no-closing resolver" \
  "GitHub closing keyword だけに依存せず" "$readme_text"
assert_contains "README documents design PR auto-label exclusion" \
  "設計 PR merge は対象外" "$readme_text"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
