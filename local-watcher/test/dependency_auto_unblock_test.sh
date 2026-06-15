#!/usr/bin/env bash
#
# 用途: `codex-blocked` Issue の依存が解消されたときに、Dependency Auto-Unblock
#       Processor が opt-in 下で `codex-blocked` を解除し、未解決・停止ラベル・
#       重複コメントを安全に扱うことを検証する。Issue #56 回帰テスト。
#
# 配置先: local-watcher/test/dependency_auto_unblock_test.sh
# 依存:   bash 4+, jq
# 実行:   bash local-watcher/test/dependency_auto_unblock_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0

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

log="${GH_CALL_LOG:?}"

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  printf '%s\n' "${GH_ISSUE_LIST_JSON:-[]}"
  exit 0
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "edit" ]; then
  printf 'issue edit %s\n' "${*:3}" >> "$log"
  exit 0
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "comment" ]; then
  issue_num="${3:-}"
  printf 'issue comment %s\n' "$issue_num" >> "$log"
  while [ "$#" -gt 0 ]; do
    if [ "${1:-}" = "--body" ]; then
      printf '%s\n' "${2:-}" >> "${GH_COMMENT_BODY_FILE:?}"
      exit 0
    fi
    shift
  done
  exit 0
fi

if [ "${1:-}" = "api" ]; then
  path="${2:-}"
  case "$path" in
    repos/owner/repo/issues/104/comments)
      printf '%s\n' '<!-- idd-codex:dependency-auto-unblock:#104 -->'
      exit 0
      ;;
    repos/owner/repo/issues/*/comments)
      printf '%s\n' ''
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
export BASE_BRANCH="main"
export PROMOTION_TARGET_BRANCH="main"
export LABEL_TRIGGER="codex-auto-dev"
export LABEL_BLOCKED="codex-blocked"
export LABEL_FAILED="codex-failed"
export LABEL_NEEDS_DECISIONS="codex-needs-decisions"
export LABEL_AWAITING_DESIGN="codex-awaiting-design-review"
export LABEL_READY="codex-ready-for-review"
export LABEL_PICKED="codex-picked-up"
export LABEL_CLAIMED="codex-claimed"
export LABEL_NEEDS_ITERATION="codex-needs-iteration"
export LABEL_NEEDS_REBASE="codex-needs-rebase"
export LABEL_NEEDS_QUOTA_WAIT="codex-needs-quota-wait"
export LABEL_STAGED_FOR_RELEASE="codex-staged-for-release"
export LABEL_ST_FAILED="codex-st-failed"
export LABEL_AWAITING_SLOT="codex-awaiting-slot"
export DEPENDENCY_AUTO_UNBLOCK_ENABLED="true"
export DEPENDENCY_AUTO_UNBLOCK_LIMIT="20"
export DRR_GH_TIMEOUT="60"
export GH_CALL_LOG="$TMPROOT/gh-calls.log"
export GH_COMMENT_BODY_FILE="$TMPROOT/comment-body.log"

touch "$GH_CALL_LOG" "$GH_COMMENT_BODY_FILE"

# Dependency Resolver / Auto-Unblock 関数だけを読み込む。watcher のトップレベル副作用は実行しない。
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
    17|18)
      cat <<'EOF_JSON'
{"data":{"repository":{"issue":{"state":"CLOSED","labels":{"nodes":[]},"closedByPullRequestsReferences":{"nodes":[{"number":70,"state":"MERGED"}]}}}}}
EOF_JSON
      ;;
    16)
      cat <<'EOF_JSON'
{"data":{"repository":{"issue":{"state":"OPEN","labels":{"nodes":[]},"closedByPullRequestsReferences":{"nodes":[]}}}}}
EOF_JSON
      ;;
    *)
      cat <<'EOF_JSON'
{"data":{"repository":{"issue":{"state":"OPEN","labels":{"nodes":[]},"closedByPullRequestsReferences":{"nodes":[]}}}}}
EOF_JSON
      ;;
  esac
}

reset_logs() {
  : > "$GH_CALL_LOG"
  : > "$GH_COMMENT_BODY_FILE"
}

echo "--- dependency auto-unblock resolved dependencies ---"

reset_logs
export GH_ISSUE_LIST_JSON='[
  {"number":101,"title":"blocked resolved","body":"Depends on: #17 #18","labels":[{"name":"codex-blocked"}]}
]'
dr_process_auto_unblock >/tmp/dependency-auto-unblock-101.out
calls=$(cat "$GH_CALL_LOG")
comment=$(cat "$GH_COMMENT_BODY_FILE")
assert_contains "resolved dependencies remove codex-blocked" "--remove-label codex-blocked" "$calls"
assert_contains "resolved dependencies add codex-auto-dev" "--add-label codex-auto-dev" "$calls"
assert_contains "resolved dependencies post marker comment" "<!-- idd-codex:dependency-auto-unblock:#101 -->" "$comment"

echo "--- dependency auto-unblock unresolved dependency stays blocked ---"

reset_logs
export GH_ISSUE_LIST_JSON='[
  {"number":102,"title":"blocked unresolved","body":"Depends on: #16","labels":[{"name":"codex-blocked"}]}
]'
dr_process_auto_unblock >/tmp/dependency-auto-unblock-102.out
calls=$(cat "$GH_CALL_LOG")
assert_not_contains "unresolved dependency does not edit labels" "issue edit 102" "$calls"
assert_not_contains "unresolved dependency does not comment" "issue comment 102" "$calls"

echo "--- dependency auto-unblock hold label guard ---"

reset_logs
export GH_ISSUE_LIST_JSON='[
  {"number":103,"title":"blocked failed","body":"Depends on: #17","labels":[{"name":"codex-blocked"},{"name":"codex-failed"}]}
]'
dr_process_auto_unblock >/tmp/dependency-auto-unblock-103.out
calls=$(cat "$GH_CALL_LOG")
assert_not_contains "hold label skips label edit" "issue edit 103" "$calls"
assert_not_contains "hold label skips comment" "issue comment 103" "$calls"

echo "--- dependency auto-unblock duplicate comment guard ---"

reset_logs
export GH_ISSUE_LIST_JSON='[
  {"number":104,"title":"blocked resolved duplicate marker","body":"Depends on: #17","labels":[{"name":"codex-blocked"}]}
]'
dr_process_auto_unblock >/tmp/dependency-auto-unblock-104.out
calls=$(cat "$GH_CALL_LOG")
comment=$(cat "$GH_COMMENT_BODY_FILE")
assert_contains "duplicate marker case still removes codex-blocked" "issue edit 104" "$calls"
assert_not_contains "duplicate marker suppresses new comment" "issue comment 104" "$calls"
assert_not_contains "duplicate marker leaves comment body empty" "dependency-auto-unblock:#104" "$comment"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
