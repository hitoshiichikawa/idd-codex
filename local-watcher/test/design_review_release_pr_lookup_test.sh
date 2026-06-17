#!/usr/bin/env bash
#
# 用途: Design Review Release Processor が merged 設計 PR を headRefName の strict prefix
#       で検出し、GitHub PR search の `in:head` 不安定性に依存しないことを検証する。
#
# 配置先: local-watcher/test/design_review_release_pr_lookup_test.sh
# 依存:   bash 4+, jq
# 実行:   bash local-watcher/test/design_review_release_pr_lookup_test.sh

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

assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  needle  : $(printf '%q' "$needle")"
    echo "  haystack: $(printf '%q' "$haystack")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    echo "FAIL: $label"
    echo "  unexpected needle: $(printf '%q' "$needle")"
    echo "  haystack         : $(printf '%q' "$haystack")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

export REPO="owner/repo"
export DRR_GH_TIMEOUT="60"
export GH_CALL_LOG="$TMPROOT/gh-calls.log"
export GH_FAKE_MODE="success"
touch "$GH_CALL_LOG"

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "drr_find_merged_design_pr")"

# shellcheck disable=SC2317
timeout() {
  shift
  "$@"
}

# shellcheck disable=SC2317
gh() {
  printf '%s\n' "$*" >> "$GH_CALL_LOG"

  if [ "${GH_FAKE_MODE:-success}" = "fail" ]; then
    return 42
  fi

  if [ "${1:-}" != "pr" ] || [ "${2:-}" != "list" ]; then
    echo "unexpected gh invocation: $*" >&2
    return 99
  fi

  # 旧実装の `--search "... in:head"` は GitHub 側で headRefName を安定して拾えない。
  # 回帰検証として、search 経由なら merged 設計 PR が存在しても空配列にする。
  local arg
  for arg in "$@"; do
    if [ "$arg" = "--search" ]; then
      printf '[]\n'
      return 0
    fi
  done

  cat <<'JSON'
[
  {"number": 88, "headRefName": "codex/issue-36-design-other", "mergedAt": "2026-06-17T00:00:00Z"},
  {"number": 94, "headRefName": "codex/issue-37-design-optimistic-read-and-star-state-synchroni", "mergedAt": "2026-06-17T05:59:18Z"},
  {"number": 95, "headRefName": "codex/issue-37-design-optimistic-read-and-star-state-sync-v2", "mergedAt": "2026-06-17T06:00:00Z"},
  {"number": 101, "headRefName": "codex/issue-137-design-prefix-near-miss", "mergedAt": "2026-06-17T07:00:00Z"}
]
JSON
}

echo "--- design review release merged PR lookup ---"

: > "$GH_CALL_LOG"
result=$(drr_find_merged_design_pr 37)
calls=$(cat "$GH_CALL_LOG")
assert_eq "merged design PR は headRefName strict prefix で最大 PR 番号を返す" "95" "$result"
assert_contains "merged PR は広めに取得するため limit=100 を使う" "--limit 100" "$calls"
assert_not_contains "GitHub search の in:head には依存しない" "--search" "$calls"

: > "$GH_CALL_LOG"
result=$(drr_find_merged_design_pr 13)
assert_eq "near-miss issue 番号は strict prefix で除外される" "" "$result"

: > "$GH_CALL_LOG"
GH_FAKE_MODE="fail"
rc=0
drr_find_merged_design_pr 37 >/dev/null || rc=$?
assert_eq "gh pr list failure は API error として return 1" "1" "$rc"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
