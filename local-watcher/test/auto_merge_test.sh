#!/usr/bin/env bash
#
# 用途: auto-merge.sh の gate / 対象判定 / 有効化 / dispatcher 統合を gh・timeout stub で
#       検証する。Issue #99（実装 PR auto-merge）。
#
# 配置先: local-watcher/test/auto_merge_test.sh
# 依存:   bash 4+, awk, grep, jq, mktemp
# 実行:   bash local-watcher/test/auto_merge_test.sh
# 前提:   auto-merge.sh から am_* 関数、watcher から full_auto_enabled を awk 抽出 → eval。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/auto-merge.sh"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
for f in "$MODULE_SH" "$WATCHER_SH"; do
  [ -f "$f" ] || { echo "ERROR: not found: $f" >&2; exit 2; }
done

extract_function() {
  local script="$1" fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

for fn in am_resolve_gate_enabled am_should_enable_for_pr am_enable_auto_merge_for_pr process_auto_merge; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$MODULE_SH" "$fn")"
done
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "full_auto_enabled")"

for fn in am_resolve_gate_enabled am_should_enable_for_pr am_enable_auto_merge_for_pr process_auto_merge full_auto_enabled; do
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done

# ─── 環境 / stub ───
REPO="owner/repo"
LABEL_READY="codex-ready-for-review"; LABEL_FAILED="codex-failed"; LABEL_NEEDS_DECISIONS="codex-needs-decisions"
AUTO_MERGE_MAX_PRS=10; AUTO_MERGE_GIT_TIMEOUT=5; AUTO_MERGE_HEAD_PATTERN='^codex/issue-.*-impl'
SHA40="$(printf 'a%.0s' {1..40})"
GH_CALL_LOG=""; LOG_FILE=""; GH_PR_LIST_RESPONSE="[]"; GH_PR_MERGE_RC=0; GH_PR_MERGE_STDERR=""

timeout() { shift; "$@"; }
gh() {
  printf 'gh %s\n' "$*" >>"$GH_CALL_LOG"
  case "$1 $2" in
    "pr list") printf '%s' "$GH_PR_LIST_RESPONSE" ;;
    "pr merge") [ -n "$GH_PR_MERGE_STDERR" ] && printf '%s' "$GH_PR_MERGE_STDERR" >&2; return "$GH_PR_MERGE_RC" ;;
  esac
  return 0
}
am_log()  { printf 'LOG %s\n'  "$*" >>"$LOG_FILE"; }
am_warn() { printf 'WARN %s\n' "$*" >>"$LOG_FILE"; }
am_error(){ printf 'ERR %s\n'  "$*" >>"$LOG_FILE"; }
idd_secure_mktemp() { mktemp -t "idd-codex-test-${1:-x}.XXXXXX"; }

reset_state() { GH_CALL_LOG="$(mktemp)"; LOG_FILE="$(mktemp)"; GH_PR_MERGE_RC=0; GH_PR_MERGE_STDERR=""; }
calls() { grep -c "$1" "$GH_CALL_LOG" 2>/dev/null || true; }
logs()  { grep -c "$1" "$LOG_FILE" 2>/dev/null || true; }

# PR JSON ビルダー: $1=num $2=head $3=mergeable $4=draft(true/false) $5=labels_csv $6=automerge(null|{..}) $7=owner
build_pr_json() {
  local labels_json="[]"
  [ -n "$5" ] && labels_json=$(printf '%s' "$5" | jq -R 'split(",")|map({name:.})')
  jq -nc --argjson num "$1" --arg head "$2" --arg sha "$SHA40" --arg mergeable "$3" \
    --argjson draft "$4" --argjson labels "$labels_json" --argjson am "${6:-null}" --arg owner "${7:-owner}" \
    '{number:$num,headRefName:$head,headRefOid:$sha,mergeable:$mergeable,isDraft:$draft,labels:$labels,autoMergeRequest:$am,url:"https://x/pr",headRepositoryOwner:{login:$owner}}'
}

PASS_COUNT=0; FAIL_COUNT=0
assert_eq() { local l="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l"; echo "  exp=$(printf '%q' "$e") act=$(printf '%q' "$a")"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }
assert_contains() { local l="$1" h="$2" n="$3"; case "$h" in *"$n"*) echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1));; *) echo "FAIL: $l ('$n' 不在)"; FAIL_COUNT=$((FAIL_COUNT+1));; esac; }
rc_of() { local fn="$1"; shift; local r=0; "$fn" "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }

# ─── 1. gate 正規化 ───
echo "--- am_resolve_gate_enabled ---"
AUTO_MERGE_ENABLED=true;  assert_eq "true → ON(0)"  "0" "$(rc_of am_resolve_gate_enabled)"
AUTO_MERGE_ENABLED=false; assert_eq "false → OFF(1)" "1" "$(rc_of am_resolve_gate_enabled)"
AUTO_MERGE_ENABLED=True;  assert_eq "True → OFF(1)"  "1" "$(rc_of am_resolve_gate_enabled)"
AUTO_MERGE_ENABLED=1;     assert_eq "1 → OFF(1)"     "1" "$(rc_of am_resolve_gate_enabled)"

# ─── 2. am_should_enable_for_pr ───
echo ""; echo "--- am_should_enable_for_pr ---"
assert_eq "impl+ready+MERGEABLE → enable(0)" "0" "$(rc_of am_should_enable_for_pr "$(build_pr_json 1 'codex/issue-1-impl-x' MERGEABLE false "$LABEL_READY")")"
assert_eq "design head → skip(1)"            "1" "$(rc_of am_should_enable_for_pr "$(build_pr_json 1 'codex/issue-1-design-x' MERGEABLE false "$LABEL_READY")")"
assert_eq "draft → skip(1)"                  "1" "$(rc_of am_should_enable_for_pr "$(build_pr_json 1 'codex/issue-1-impl-x' MERGEABLE true "$LABEL_READY")")"
assert_eq "ready ラベル無し → skip(1)"       "1" "$(rc_of am_should_enable_for_pr "$(build_pr_json 1 'codex/issue-1-impl-x' MERGEABLE false '')")"
assert_eq "failed 付き → skip(1)"            "1" "$(rc_of am_should_enable_for_pr "$(build_pr_json 1 'codex/issue-1-impl-x' MERGEABLE false "$LABEL_READY,$LABEL_FAILED")")"
assert_eq "needs-decisions 付き → skip(1)"   "1" "$(rc_of am_should_enable_for_pr "$(build_pr_json 1 'codex/issue-1-impl-x' MERGEABLE false "$LABEL_READY,$LABEL_NEEDS_DECISIONS")")"
assert_eq "CONFLICTING → skip(1)"            "1" "$(rc_of am_should_enable_for_pr "$(build_pr_json 1 'codex/issue-1-impl-x' CONFLICTING false "$LABEL_READY")")"
assert_eq "UNKNOWN → skip(1)"                "1" "$(rc_of am_should_enable_for_pr "$(build_pr_json 1 'codex/issue-1-impl-x' UNKNOWN false "$LABEL_READY")")"
assert_eq "既に auto-merge 有効 → 冪等(2)"   "2" "$(rc_of am_should_enable_for_pr "$(build_pr_json 1 'codex/issue-1-impl-x' MERGEABLE false "$LABEL_READY" '{"enabledAt":"x"}')")"

# ─── 3. am_enable_auto_merge_for_pr ───
echo ""; echo "--- am_enable_auto_merge_for_pr ---"
reset_state; r=$(rc_of am_enable_auto_merge_for_pr 42 codex/issue-42-impl-x "$SHA40" https://x)
assert_eq "成功 → 0" "0" "$r"
assert_contains "gh pr merge --auto"           "$(cat "$GH_CALL_LOG")" "pr merge"
assert_contains "--auto フラグ"                "$(cat "$GH_CALL_LOG")" "--auto"
assert_contains "--squash フラグ"              "$(cat "$GH_CALL_LOG")" "--squash"
assert_contains "--delete-branch フラグ"       "$(cat "$GH_CALL_LOG")" "--delete-branch"
reset_state; r=$(rc_of am_enable_auto_merge_for_pr "abc" codex/issue-1-impl-x "$SHA40" https://x)
assert_eq "非数値 pr → 1"      "1" "$r"
assert_eq "非数値 pr → gh 0 回" "0" "$(calls '^gh ')"
reset_state; GH_PR_MERGE_RC=1; GH_PR_MERGE_STDERR="branch protection rules not satisfied"; r=$(rc_of am_enable_auto_merge_for_pr 42 codex/issue-42-impl-x "$SHA40" https://x)
assert_eq "gh 失敗 → 1" "1" "$r"
assert_eq "gh 失敗 → WARN 1" "1" "$(logs 'auto-merge 有効化に失敗')"

# ─── 4. process_auto_merge 統合 ───
echo ""; echo "--- process_auto_merge（dispatcher entry）---"
# 4a. full_auto OFF → 0 gh
reset_state; FULL_AUTO_ENABLED=false; AUTO_MERGE_ENABLED=true
process_auto_merge || true
assert_eq "full_auto OFF → gh 0 回" "0" "$(calls '^gh ')"
# 4b. AUTO_MERGE OFF → 0 gh
reset_state; FULL_AUTO_ENABLED=true; AUTO_MERGE_ENABLED=false
process_auto_merge || true
assert_eq "AUTO_MERGE OFF → gh 0 回" "0" "$(calls '^gh ')"
assert_eq "AUTO_MERGE OFF → suppression ログ" "1" "$(logs 'suppressed by AUTO_MERGE_ENABLED')"
# 4c. 両 gate ON + 1 valid PR → merge 1 回
reset_state; FULL_AUTO_ENABLED=true; AUTO_MERGE_ENABLED=true
GH_PR_LIST_RESPONSE="$(jq -c -n --argjson p "$(build_pr_json 7 'codex/issue-7-impl-x' MERGEABLE false "$LABEL_READY")" '[$p]')"
process_auto_merge || true
assert_eq "両 gate ON + valid → gh pr merge 1 回" "1" "$(calls 'pr merge')"
# 4d. 両 gate ON + CONFLICTING → merge 0 回（委譲）
reset_state; FULL_AUTO_ENABLED=true; AUTO_MERGE_ENABLED=true
GH_PR_LIST_RESPONSE="$(jq -c -n --argjson p "$(build_pr_json 7 'codex/issue-7-impl-x' CONFLICTING false "$LABEL_READY")" '[$p]')"
process_auto_merge || true
assert_eq "CONFLICTING → gh pr merge 0 回（merge-queue へ委譲）" "0" "$(calls 'pr merge')"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
