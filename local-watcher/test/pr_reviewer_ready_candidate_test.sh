#!/usr/bin/env bash
#
# 用途: pr-reviewer.sh の ready PR 候補抽出回帰を検証する。
#       Issue #150: codex-ready-for-review の open managed PR をレビュー候補から落とさない。
#
# 配置先: local-watcher/test/pr_reviewer_ready_candidate_test.sh
# 依存:   bash 4+, jq
# 実行:   bash local-watcher/test/pr_reviewer_ready_candidate_test.sh

set -euo pipefail
# shellcheck disable=SC2034  # eval で抽出した関数が参照する環境変数をこのテスト内で定義する。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_REVIEWER_SH="$SCRIPT_DIR/../bin/idd-codex-modules/pr-reviewer.sh"
[ -f "$PR_REVIEWER_SH" ] || { echo "ERROR: not found: $PR_REVIEWER_SH" >&2; exit 2; }

extract_function() {
  local script="$1" fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_fetch_candidate_prs")"
declare -F pr_fetch_candidate_prs >/dev/null || { echo "ERROR: pr_fetch_candidate_prs not loaded" >&2; exit 2; }

export REPO="owner/repo"
export PR_REVIEWER_GIT_TIMEOUT=5
export PR_REVIEWER_HEAD_PATTERN='^codex/'
LABEL_READY="codex-ready-for-review"
SHA40="$(printf 'a%.0s' {1..40})"
GH_PR_LIST_RESPONSE="[]"
LOG_FILE="$(mktemp)"

timeout() { shift; "$@"; }
gh() {
  case "$1 $2" in
    "pr list") printf '%s' "$GH_PR_LIST_RESPONSE" ;;
  esac
  return 0
}
pr_log() { printf 'LOG %s\n' "$*" >>"$LOG_FILE"; }
pr_warn() { printf 'WARN %s\n' "$*" >>"$LOG_FILE"; }
pr_error() { printf 'ERR %s\n' "$*" >>"$LOG_FILE"; }

PASS_COUNT=0
FAIL_COUNT=0
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  exp=$(printf '%q' "$expected") act=$(printf '%q' "$actual")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "PASS: $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
    *)
      echo "FAIL: $label ('$needle' 不在)"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
  esac
}

ready_pr() {
  jq -nc --arg sha "$SHA40" --arg label "$LABEL_READY" '{
    number: 24,
    headRefName: "codex/issue-9-impl-ipad-iphone",
    headRefOid: $sha,
    baseRefName: "develop",
    isDraft: false,
    url: "https://example.invalid/pr/24",
    headRepositoryOwner: {login: "owner"},
    labels: [{name: $label}],
    reviewDecision: null,
    statusCheckRollup: []
  }'
}

draft_pr() {
  jq -nc --arg sha "$SHA40" --arg label "$LABEL_READY" '{
    number: 25,
    headRefName: "codex/issue-25-impl-x",
    headRefOid: $sha,
    baseRefName: "develop",
    isDraft: true,
    url: "https://example.invalid/pr/25",
    headRepositoryOwner: {login: "owner"},
    labels: [{name: $label}],
    reviewDecision: null,
    statusCheckRollup: []
  }'
}

fork_pr() {
  jq -nc --arg sha "$SHA40" --arg label "$LABEL_READY" '{
    number: 26,
    headRefName: "codex/issue-26-impl-x",
    headRefOid: $sha,
    baseRefName: "develop",
    isDraft: false,
    url: "https://example.invalid/pr/26",
    headRepositoryOwner: {login: "external"},
    labels: [{name: $label}],
    reviewDecision: null,
    statusCheckRollup: []
  }'
}

unmanaged_pr() {
  jq -nc --arg sha "$SHA40" --arg label "$LABEL_READY" '{
    number: 27,
    headRefName: "feature/manual",
    headRefOid: $sha,
    baseRefName: "develop",
    isDraft: false,
    url: "https://example.invalid/pr/27",
    headRepositoryOwner: {login: "owner"},
    labels: [{name: $label}],
    reviewDecision: null,
    statusCheckRollup: []
  }'
}

GH_PR_LIST_RESPONSE="$(jq -c -n \
  --argjson ready "$(ready_pr)" \
  --argjson draft "$(draft_pr)" \
  --argjson fork "$(fork_pr)" \
  --argjson unmanaged "$(unmanaged_pr)" \
  '[$ready, $draft, $fork, $unmanaged]')"

out="$(pr_fetch_candidate_prs)"
assert_eq "Req 1.1 / 5.1: ready open managed PR を候補に含める" "24" "$(jq -r '.[0].number' <<<"$out")"
assert_eq "Req 1.3: reviewDecision/statusCheckRollup 空でも候補から除外しない" "1" "$(jq -r 'length' <<<"$out")"
assert_contains "Req 4.1: candidate totals に候補数を出す" "$(cat "$LOG_FILE")" "candidate totals:"
assert_contains "Req 4.1: head pattern 除外数を区別できる" "$(cat "$LOG_FILE")" "excluded-by-head-pattern=1"
assert_contains "Req 4.1: draft 除外数を区別できる" "$(cat "$LOG_FILE")" "draft=1"
assert_contains "Req 4.1: fork 除外数を区別できる" "$(cat "$LOG_FILE")" "fork=1"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
