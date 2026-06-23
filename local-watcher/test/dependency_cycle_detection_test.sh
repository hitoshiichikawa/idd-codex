#!/usr/bin/env bash
#
# 用途: Dependency Resolver の cycle 検出（#104 / D-16）を検証する。
#       純粋関数 dr_node_reaches_self / dr_find_cycle_members（no-cycle / 2-cycle /
#       3-cycle / self-loop / disjoint）、dr_escalate_cycle の副作用 + 冪等性、
#       dr_process_auto_unblock の routing（gate off=現行・cycle→needs-decisions・
#       非 cycle→auto_unblock_one）を stub で確認する。
#
# 配置先: local-watcher/test/dependency_cycle_detection_test.sh
# 依存:   bash 4+, awk, grep, jq, mktemp, sort, paste
# 実行:   bash local-watcher/test/dependency_cycle_detection_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
[ -f "$WATCHER_SH" ] || { echo "ERROR: not found: $WATCHER_SH" >&2; exit 2; }

extract_function() {
  local script="$1" fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

REAL_FNS=(
  dr_extract_deps dr_node_reaches_self dr_find_cycle_members
  dr_escalate_cycle dr_process_auto_unblock
)
for fn in "${REAL_FNS[@]}"; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$WATCHER_SH" "$fn")"
done
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "full_auto_enabled")"
for fn in "${REAL_FNS[@]}" full_auto_enabled; do
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done

# ─── 共有グローバル ───
REPO="owner/repo"; LABEL_BLOCKED="codex-blocked"; LABEL_NEEDS_DECISIONS="codex-needs-decisions"
DEPENDENCY_AUTO_UNBLOCK_ENABLED=true; DEPENDENCY_AUTO_UNBLOCK_LIMIT=20; DRR_GH_TIMEOUT=5

# ─── stub ───
GH_CALL_LOG=""; GH_ISSUE_LIST="[]"; COMMENT_EXISTS_RC=1
timeout() { shift; "$@"; }
gh() {
  printf 'gh %s\n' "$*" >>"$GH_CALL_LOG"
  case "$1 $2" in
    "issue list") printf '%s' "$GH_ISSUE_LIST" ;;
  esac
  return 0
}
dr_log()  { :; }
dr_warn() { :; }
dr_error(){ :; }
# dr_escalate_cycle の冪等チェック依存（既存・本 Issue 対象外）。
dr_auto_unblock_comment_exists() { return "$COMMENT_EXISTS_RC"; }

reset_state() { GH_CALL_LOG="$(mktemp)"; COMMENT_EXISTS_RC=1; }
calls() { grep -c "$1" "$GH_CALL_LOG" 2>/dev/null || true; }

PASS_COUNT=0; FAIL_COUNT=0
assert_eq() { local l="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l"; echo "  exp=$(printf '%q' "$e") act=$(printf '%q' "$a")"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }
rc_of() { local fn="$1"; shift; local r=0; "$fn" "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }

# ════════════════════════════════════════════════════════════════════════════
echo "--- 1. dr_node_reaches_self（自分へ戻る経路 = cycle 上か）---"
E2='1 2
2 1'
assert_eq "2-cycle: 1 は自分へ戻る(0)" "0" "$(rc_of dr_node_reaches_self 1 "$E2")"
ECHAIN='1 2
2 3'
assert_eq "chain 1→2→3: 1 は戻らない(1)" "1" "$(rc_of dr_node_reaches_self 1 "$ECHAIN")"
assert_eq "self-loop: 1→1(0)" "0" "$(rc_of dr_node_reaches_self 1 '1 1')"

echo ""; echo "--- 2. dr_find_cycle_members（cycle 上の全ノード）---"
assert_eq "edge 無し → 空" "" "$(dr_find_cycle_members '1,2,3' '')"
assert_eq "2-cycle(1↔2) → 1,2" "1,2" "$(dr_find_cycle_members '1,2' "$E2")"
E3='1 2
2 3
3 1'
assert_eq "3-cycle(1→2→3→1) → 1,2,3" "1,2,3" "$(dr_find_cycle_members '1,2,3' "$E3")"
assert_eq "chain(1→2→3) → 空" "" "$(dr_find_cycle_members '1,2,3' "$ECHAIN")"
assert_eq "self-loop(1→1) → 1" "1" "$(dr_find_cycle_members '1' '1 1')"
EDISJOINT='1 2
2 1
3 4'
assert_eq "disjoint: 1↔2 cycle + 3→4 → 1,2 のみ" "1,2" "$(dr_find_cycle_members '1,2,3,4' "$EDISJOINT")"

echo ""; echo "--- 3. dr_escalate_cycle（codex-blocked→codex-needs-decisions + 冪等）---"
reset_state; COMMENT_EXISTS_RC=1
r=$(rc_of dr_escalate_cycle 5 "5,6")
assert_eq "成功 → rc 0" "0" "$r"
assert_eq "codex-blocked 除去" "1" "$(calls 'remove-label codex-blocked')"
assert_eq "codex-needs-decisions 付与" "1" "$(calls 'add-label codex-needs-decisions')"
assert_eq "コメント投稿" "1" "$(calls 'issue comment')"
# 冪等: marker 既存 → ラベル mutation しない
reset_state; COMMENT_EXISTS_RC=0
r=$(rc_of dr_escalate_cycle 5 "5,6")
assert_eq "marker 既存 → rc 0" "0" "$r"
assert_eq "marker 既存 → ラベル編集なし" "0" "$(calls 'issue edit')"
assert_eq "marker 既存 → コメントなし" "0" "$(calls 'issue comment')"

# ════════════════════════════════════════════════════════════════════════════
echo ""; echo "--- 4. dr_process_auto_unblock routing（cycle pre-pass）---"
# leaf を eval 上書きして「どの Issue がどう処理されたか」を記録（SC2218 回避のため eval）。
ESCALATE_LOG=""; UNBLOCK_LOG=""
eval 'dr_escalate_cycle() { ESCALATE_LOG="${ESCALATE_LOG} $1"; return 0; }'
eval 'dr_auto_unblock_one() { UNBLOCK_LOG="${UNBLOCK_LOG} $1"; return 0; }'

# blocked set: #1↔#2 相互依存（cycle）, #3 は外部依存 #99（非 cycle）
mk_issue() { jq -nc --argjson n "$1" --arg b "$2" '{number:$n,title:"t",body:$b,labels:[{name:"codex-blocked"}]}'; }
GH_ISSUE_LIST=$(jq -nc \
  --argjson a "$(mk_issue 1 'Depends on: #2')" \
  --argjson b "$(mk_issue 2 'Depends on: #1')" \
  --argjson c "$(mk_issue 3 'Depends on: #99')" \
  '[$a,$b,$c]')

run_proc() { ESCALATE_LOG=""; UNBLOCK_LOG=""; dr_process_auto_unblock >/dev/null 2>&1 || true; }

# 4a. gate off（BLOCKED_CYCLE_DETECTION_ENABLED=false）→ cycle 検出せず全件 auto_unblock_one
reset_state; BLOCKED_CYCLE_DETECTION_ENABLED=false; FULL_AUTO_ENABLED=true
run_proc
assert_eq "gate off → escalate なし" "" "$ESCALATE_LOG"
assert_eq "gate off → 全 3 件 auto_unblock_one" " 1 2 3" "$UNBLOCK_LOG"

# 4b. full_auto off → cycle 検出せず
reset_state; BLOCKED_CYCLE_DETECTION_ENABLED=true; FULL_AUTO_ENABLED=false
run_proc
assert_eq "full_auto off → escalate なし" "" "$ESCALATE_LOG"
assert_eq "full_auto off → 全 3 件 auto_unblock_one" " 1 2 3" "$UNBLOCK_LOG"

# 4c. gate on + cycle → #1,#2 を needs-decisions escalate、#3 のみ auto_unblock_one
reset_state; BLOCKED_CYCLE_DETECTION_ENABLED=true; FULL_AUTO_ENABLED=true
run_proc
assert_eq "cycle 検出 → #1,#2 escalate" " 1 2" "$ESCALATE_LOG"
assert_eq "非 cycle #3 のみ auto_unblock_one（cycle member は skip）" " 3" "$UNBLOCK_LOG"

# 4d. gate on + no cycle（全件 外部依存）→ escalate なし・全件 auto_unblock_one
reset_state; BLOCKED_CYCLE_DETECTION_ENABLED=true; FULL_AUTO_ENABLED=true
GH_ISSUE_LIST=$(jq -nc \
  --argjson a "$(mk_issue 1 'Depends on: #50')" \
  --argjson b "$(mk_issue 2 'Depends on: #51')" \
  '[$a,$b]')
run_proc
assert_eq "no cycle → escalate なし" "" "$ESCALATE_LOG"
assert_eq "no cycle → 全 2 件 auto_unblock_one" " 1 2" "$UNBLOCK_LOG"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
