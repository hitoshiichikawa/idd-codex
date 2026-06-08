#!/usr/bin/env bash
#
# 用途: Dependency Resolver が multi-branch gitflow 運用で
#       codex-staged-for-release / base branch merged managed PR を
#       development-resolved として扱うことを検証する。Issue #6 task 1 回帰テスト。
#
# 配置先: local-watcher/test/dependency_resolver_gitflow_test.sh
# 依存:   bash 4+, jq
# 実行:   bash local-watcher/test/dependency_resolver_gitflow_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
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

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

FAKEBIN="$TMPROOT/fakebin"
mkdir -p "$FAKEBIN"
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

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  args=" $* "
  case "$args" in
    *"codex/issue-15-impl in:head"*)
      printf '%s\n' '[
        {"number":51,"headRefName":"codex/issue-15-impl-old","baseRefName":"main","headRepositoryOwner":{"login":"owner"},"mergedAt":"2026-06-01T00:00:00Z"},
        {"number":57,"headRefName":"codex/issue-15-impl-feed","baseRefName":"develop","headRepositoryOwner":{"login":"owner"},"mergedAt":"2026-06-02T00:00:00Z"},
        {"number":58,"headRefName":"codex/issue-15-impl-fork","baseRefName":"develop","headRepositoryOwner":{"login":"someone"},"mergedAt":"2026-06-03T00:00:00Z"}
      ]'
      exit 0
      ;;
    *)
      printf '%s\n' '[]'
      exit 0
      ;;
  esac
fi

echo "unexpected gh invocation: $*" >&2
exit 99
EOF_GH
chmod +x "$FAKEBIN/gh"

export PATH="$FAKEBIN:$PATH"
export REPO="owner/repo"
export BASE_BRANCH="develop"
export PROMOTION_TARGET_BRANCH="main"
export LABEL_STAGED_FOR_RELEASE="codex-staged-for-release"
export LABEL_BLOCKED="codex-blocked"
export LABEL_CLAIMED="codex-claimed"
export DRR_GH_TIMEOUT="60"

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
    15)
      cat <<'EOF_JSON'
{"data":{"repository":{"issue":{"state":"OPEN","labels":{"nodes":[]},"closedByPullRequestsReferences":{"nodes":[]}}}}}
EOF_JSON
      ;;
    16)
      cat <<'EOF_JSON'
{"data":{"repository":{"issue":{"state":"OPEN","labels":{"nodes":[]},"closedByPullRequestsReferences":{"nodes":[]}}}}}
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

dr_apply_block() {
  local _issue_num="$1"
  local unresolved="$2"
  printf '%s\n' "$unresolved" > "$TMPROOT/applied-block.txt"
  return 0
}

echo "--- dr_resolve_one multi-branch reasons ---"

assert_eq "staged label resolves open dependency" \
  "resolved|staged-for-release" \
  "$(dr_resolve_one 14)"

assert_eq "base branch merged managed PR resolves open dependency" \
  "resolved|base-merged|#57" \
  "$(dr_resolve_one 15)"

assert_eq "multi-branch open dependency without staged label or merged PR remains unresolved" \
  "open|open" \
  "$(dr_resolve_one 16)"

echo "--- dr_check_dependencies reason logging ---"

check_log=$(dr_check_dependencies 99 $'Depends on: #14 #15 #17' "" 2>"$TMPROOT/dr-check.err") || rc=$?
rc="${rc:-0}"
assert_eq "all development-resolved dependencies allow triage" "0" "$rc"
assert_contains "log records staged-for-release reason" "#14(staged-for-release)" "$check_log"
assert_contains "log records base-merged reason and PR number" "#15(base-merged:#57)" "$check_log"
assert_contains "log records existing closing-pr reason" "#17(closing-pr)" "$check_log"

echo "--- single-branch compatibility ---"

BASE_BRANCH="main"
PROMOTION_TARGET_BRANCH="main"
assert_eq "single-branch closing PR path remains resolved" \
  "resolved|closing-pr" \
  "$(dr_resolve_one 17)"

echo "--- unresolved comment wording ---"

comment=$(dr_format_unresolved_comment $'#16|open\n#18|api error')
assert_contains "comment labels dependency issue explicitly" "依存先: #16 / 状態: open" "$comment"
assert_not_contains "comment no longer emits bare bullet issue number" "- #16 (open)" "$comment"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
