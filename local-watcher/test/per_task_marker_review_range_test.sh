#!/usr/bin/env bash
#
# 用途: per-task Reviewer range 解決で、task done marker 後の corrective commit が
#       silent に除外されないことを検証する。Issue #23 回帰テスト。
#
# 配置先: local-watcher/test/per_task_marker_review_range_test.sh
# 依存:   bash 4+, awk, git, grep
# 実行:   bash local-watcher/test/per_task_marker_review_range_test.sh

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

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_resolve_diff_range")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_build_diff_range_resolve_diagnostic")"

if ! declare -F pt_resolve_diff_range >/dev/null; then
  echo "ERROR: pt_resolve_diff_range not loaded" >&2
  exit 2
fi
if ! declare -F pt_build_diff_range_resolve_diagnostic >/dev/null; then
  echo "ERROR: pt_build_diff_range_resolve_diagnostic not loaded" >&2
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
  if grep -Fq -- "$needle" <<<"$haystack"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  needle: $(printf '%q' "$needle")"
    echo "  in    : $(printf '%q' "$haystack")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

echo "--- pt_resolve_diff_range post-marker corrective commit (Issue #23 Req 5.1) ---"

git -C "$TMPROOT" init -q
git -C "$TMPROOT" config user.email "idd-codex-test@example.invalid"
git -C "$TMPROOT" config user.name "idd-codex test"
git -C "$TMPROOT" checkout -q -b main

printf '%s\n' "base" >"$TMPROOT/file.txt"
git -C "$TMPROOT" add file.txt
git -C "$TMPROOT" commit -q -m "chore: base"
base_sha=$(git -C "$TMPROOT" rev-parse HEAD)

git -C "$TMPROOT" checkout -q -b codex/issue-23-test
printf '%s\n' "implementation" >"$TMPROOT/file.txt"
git -C "$TMPROOT" add file.txt
git -C "$TMPROOT" commit -q -m "fix(watcher): initial task implementation"

git -C "$TMPROOT" commit -q --allow-empty -m "docs(tasks): mark 1 as done"
marker_sha=$(git -C "$TMPROOT" rev-parse HEAD)

printf '%s\n' "corrective fix" >"$TMPROOT/fix.txt"
git -C "$TMPROOT" add fix.txt
git -C "$TMPROOT" commit -q -m "fix(watcher): corrective commit after marker"
head_sha=$(git -C "$TMPROOT" rev-parse HEAD)

stderr_file="$TMPROOT/resolve.err"
range_line=$(cd "$TMPROOT" && BASE_BRANCH=main pt_resolve_diff_range "1" 2>"$stderr_file")
range_start=$(printf '%s' "$range_line" | cut -f1)
range_end=$(printf '%s' "$range_line" | cut -f2)
stderr_out=$(cat "$stderr_file")

assert_eq "Req 5.1: range_start は base SHA" "$base_sha" "$range_start"
assert_eq "Req 5.1: marker 後 corrective commit がある場合 range_end は HEAD" "$head_sha" "$range_end"
assert_contains "Req 2.2 / 3.4: post-marker include 診断を stderr に残す" \
  "post-marker-commits-included task=1 marker=${marker_sha} end=${head_sha} count=1" \
  "$stderr_out"
assert_contains "Req 5.1: resolved range の diff に corrective commit の変更が含まれる" \
  "fix.txt" \
  "$(git -C "$TMPROOT" diff --name-only "${range_start}..${range_end}")"

post_marker_diagnostic=$(cd "$TMPROOT" && BASE_BRANCH=main pt_build_diff_range_resolve_diagnostic "1")
assert_contains "Req 3.4: 診断に affected range を含める" \
  "- affected range: \`${marker_sha}..${head_sha}\`" \
  "$post_marker_diagnostic"
assert_contains "Req 3.4: 診断に marker 後 commit 数を含める" \
  "- marker 後 commit: 1 commit(s)" \
  "$post_marker_diagnostic"

missing_marker_diagnostic=$(cd "$TMPROOT" && BASE_BRANCH=main pt_build_diff_range_resolve_diagnostic "2")
assert_contains "Req 3.4: marker 不在時の unsafe reason を明示する" \
  "- unsafe reason: \`marker-not-found\`" \
  "$missing_marker_diagnostic"
assert_contains "Req 3.4: marker 不在時も直近 marker 候補を出す" \
  "docs(tasks): mark 1 as done" \
  "$missing_marker_diagnostic"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
