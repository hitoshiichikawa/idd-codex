#!/usr/bin/env bash
#
# 用途: dispatcher の codex-hotfix 優先ソート jq が compile / 実行でき、
#       hotfix tier 優先 + tier 内 Issue 番号昇順 + number dedup を満たすことを検証する。
#
# 配置先: local-watcher/test/dispatch_hotfix_jq_test.sh
# 依存:   bash 4+, jq
# 実行:   bash local-watcher/test/dispatch_hotfix_jq_test.sh

set -euo pipefail

LABEL_HOTFIX="codex-hotfix"
DISPATCH_LIMIT=5

hotfix_issues='[
  {"number":3,"labels":[{"name":"codex-hotfix"}]},
  {"number":2,"labels":[{"name":"codex-hotfix"}]}
]'

all_issues='[
  {"number":1,"labels":[{"name":"codex-auto-dev"}]},
  {"number":2,"labels":[{"name":"codex-hotfix"}]},
  {"number":4,"labels":null}
]'

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

issues=$(jq -c -n \
  --argjson limit "$DISPATCH_LIMIT" \
  --arg hotfix "$LABEL_HOTFIX" \
  --slurpfile hf <(printf '%s' "$hotfix_issues") \
  --slurpfile al <(printf '%s' "$all_issues") '
  ([ $hf[0][]?, $al[0][]? ])
  | map(. + { _is_hotfix: ((.labels // []) | map(.name) | index($hotfix) != null) })
  | unique_by(.number)
  | sort_by([ (if ._is_hotfix then 0 else 1 end), .number ])
  | .[0:$limit]
  | map(del(._is_hotfix))
')

assert_eq "hotfix tier first, each tier sorted by number" \
  "2,3,1,4" \
  "$(echo "$issues" | jq -r 'map(.number) | join(",")')"

assert_eq "duplicate issue number is removed" \
  "4" \
  "$(echo "$issues" | jq -r 'length')"

assert_eq "temporary sort field is removed" \
  "false" \
  "$(echo "$issues" | jq -r 'any(.[]; has("_is_hotfix"))')"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
