#!/usr/bin/env bash
#
# 用途: auto-rebase.sh の semantic conflict 自動解決（#103 / D-12）を検証する。
#       gate（AUTO_REBASE_SEMANTIC + FULL_AUTO_ENABLED）/ budget（marker カウント）/
#       自動解決 disposition（dismiss + ready で二重ゲート再発火）/ 解決不能の
#       needs-decisions フォールバック / ar_handle_pr の分岐ルーティング（OFF=現行・
#       mechanical 無干渉）を stub で確認する。
#
# 配置先: local-watcher/test/auto_rebase_semantic_test.sh
# 依存:   bash 4+, awk, grep, jq, mktemp
# 実行:   bash local-watcher/test/auto_rebase_semantic_test.sh
# 前提:   auto-rebase.sh から ar_* を、watcher から full_auto_enabled を awk 抽出 → eval。
#         gh / timeout / git / logger / ar_dismiss_all_approvals を stub。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/auto-rebase.sh"
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

REAL_FNS=(
  ar_semantic_auto_enabled ar_count_semantic_attempts ar_semantic_budget_available
  ar_escalate_to_needs_decisions ar_apply_semantic_auto ar_handle_pr
)
for fn in "${REAL_FNS[@]}"; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$MODULE_SH" "$fn")"
done
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "full_auto_enabled")"

for fn in "${REAL_FNS[@]}" full_auto_enabled; do
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done

# ─── 共有グローバル ───
REPO="owner/repo"; BASE_BRANCH="main"
LABEL_NEEDS_REBASE="codex-needs-rebase"; LABEL_FAILED="codex-failed"
LABEL_READY="codex-ready-for-review"; LABEL_NEEDS_DECISIONS="codex-needs-decisions"
AUTO_REBASE_GIT_TIMEOUT=5; AUTO_REBASE_SEMANTIC_MAX=3
AR_SEMANTIC_MARKER="idd-codex:auto-rebase-semantic"

# ─── stub ───
GH_CALL_LOG=""; GH_COMMENTS_RESPONSE='{"comments":[]}'; GH_VIEW_RC=0; DISMISS_RC=0
timeout() { shift; "$@"; }
git() { printf 'git %s\n' "$*" >>"$GH_CALL_LOG"; return 0; }
gh() {
  printf 'gh %s\n' "$*" >>"$GH_CALL_LOG"
  case "$1 $2" in
    "pr view") [ "$GH_VIEW_RC" -ne 0 ] && return "$GH_VIEW_RC"; printf '%s' "$GH_COMMENTS_RESPONSE" ;;
  esac
  return 0
}
ar_log()  { :; }
ar_warn() { :; }
ar_error(){ :; }
# ar_apply_semantic_auto / ar_escalate_to_needs_decisions の依存（既存・本 Issue 対象外）。
ar_dismiss_all_approvals() { printf 'dismiss %s\n' "$1" >>"$GH_CALL_LOG"; return "$DISMISS_RC"; }

reset_state() { GH_CALL_LOG="$(mktemp)"; GH_COMMENTS_RESPONSE='{"comments":[]}'; GH_VIEW_RC=0; DISMISS_RC=0; }
calls() { grep -c "$1" "$GH_CALL_LOG" 2>/dev/null || true; }

PASS_COUNT=0; FAIL_COUNT=0
assert_eq() { local l="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l"; echo "  exp=$(printf '%q' "$e") act=$(printf '%q' "$a")"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }
rc_of() { local fn="$1"; shift; local r=0; "$fn" "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }

# ════════════════════════════════════════════════════════════════════════════
echo "--- 1. ar_semantic_auto_enabled（二重 opt-in: AUTO_REBASE_SEMANTIC + FULL_AUTO）---"
AUTO_REBASE_SEMANTIC=on;  FULL_AUTO_ENABLED=true;  assert_eq "on + full_auto → 有効(0)" "0" "$(rc_of ar_semantic_auto_enabled)"
AUTO_REBASE_SEMANTIC=off; FULL_AUTO_ENABLED=true;  assert_eq "off → 無効(1)"           "1" "$(rc_of ar_semantic_auto_enabled)"
AUTO_REBASE_SEMANTIC=on;  FULL_AUTO_ENABLED=false; assert_eq "on + full_auto OFF → 無効(1)" "1" "$(rc_of ar_semantic_auto_enabled)"
AUTO_REBASE_SEMANTIC=ON;  FULL_AUTO_ENABLED=true;  assert_eq "ON(大文字) → 無効(1)"    "1" "$(rc_of ar_semantic_auto_enabled)"

echo ""; echo "--- 2. ar_count_semantic_attempts / ar_semantic_budget_available（budget）---"
reset_state
assert_eq "marker 0 件 → count 0" "0" "$(ar_count_semantic_attempts 42)"
mk='<!-- idd-codex:auto-rebase-semantic pr=42 -->'
GH_COMMENTS_RESPONSE=$(jq -nc --arg m "$mk" '{comments:[{body:$m},{body:$m}]}')
assert_eq "marker 2 件 → count 2" "2" "$(ar_count_semantic_attempts 42)"
GH_COMMENTS_RESPONSE=$(jq -nc '{comments:[{body:"<!-- idd-codex:auto-rebase-semantic pr=99 -->"}]}')
assert_eq "別 PR marker は無視 → count 0" "0" "$(ar_count_semantic_attempts 42)"
reset_state; GH_VIEW_RC=1
assert_eq "gh 失敗 → MAX(安全側)" "3" "$(ar_count_semantic_attempts 42)"
# budget 判定
reset_state
assert_eq "prior 0 < MAX → 続行可(0)" "0" "$(rc_of ar_semantic_budget_available 42)"
GH_COMMENTS_RESPONSE=$(jq -nc --arg m "$mk" '{comments:[{body:$m},{body:$m},{body:$m}]}')
assert_eq "prior 3 = MAX → 枯渇(1)" "1" "$(rc_of ar_semantic_budget_available 42)"

echo ""; echo "--- 3. ar_apply_semantic_auto（dismiss + ready + audit marker）---"
reset_state; DISMISS_RC=0
r=$(rc_of ar_apply_semantic_auto 42 "https://x" "beforeSHA" "afterSHA" "src/x.ts")
assert_eq "成功 → rc 0" "0" "$r"
assert_eq "approve dismiss 実行" "1" "$(calls '^dismiss 42')"
assert_eq "codex-needs-rebase 除去" "1" "$(calls 'remove-label codex-needs-rebase')"
assert_eq "codex-ready-for-review 付与" "1" "$(calls 'add-label codex-ready-for-review')"
assert_eq "audit コメント投稿" "1" "$(calls 'pr comment')"
reset_state; DISMISS_RC=1
assert_eq "dismiss 失敗 → rc 1（呼出側で needs-decisions）" "1" "$(rc_of ar_apply_semantic_auto 42 x b a '')"

echo ""; echo "--- 4. ar_escalate_to_needs_decisions（needs-decisions フォールバック・codex-failed 付与しない）---"
reset_state
r=$(rc_of ar_escalate_to_needs_decisions 42 "budget-exhausted")
assert_eq "成功 → rc 0" "0" "$r"
assert_eq "codex-needs-decisions 付与" "1" "$(calls 'add-label codex-needs-decisions')"
assert_eq "codex-needs-rebase 除去" "1" "$(calls 'remove-label codex-needs-rebase')"
assert_eq "codex-failed は付与しない" "0" "$(calls 'add-label codex-failed')"
assert_eq "コメント投稿" "1" "$(calls 'pr comment')"

# ════════════════════════════════════════════════════════════════════════════
echo ""; echo "--- 5. ar_handle_pr 分岐ルーティング（disposition の選択）---"
# leaf を eval 上書きして「どの disposition が呼ばれたか」を記録（SC2218 回避のため eval）。
DISPATCH=""
eval 'ar_run_codex_rebase() { printf "%s\n" "$REBASE_OUT"; return "$REBASE_RC"; }'
eval 'ar_classify_diff() { printf "%s\n" "$CLASSIFY"; }'
eval 'ar_apply_mechanical() { DISPATCH="mechanical"; return 0; }'
eval 'ar_apply_semantic() { DISPATCH="semantic-human"; return 0; }'
eval 'ar_apply_semantic_auto() { DISPATCH="semantic-auto"; return "${SAUTO_RC:-0}"; }'
eval 'ar_escalate_to_failed() { DISPATCH="failed:$2"; return 0; }'
eval 'ar_escalate_to_needs_decisions() { DISPATCH="needs-decisions:$2"; return 0; }'
eval 'ar_semantic_budget_available() { return "${BUDGET_RC:-0}"; }'

PRJSON='{"number":7,"headRefName":"codex/issue-7-impl-x","baseRefName":"main","url":"https://x/7","title":"t"}'
run_handle() { DISPATCH=""; ar_handle_pr "$PRJSON" >/dev/null 2>&1 || true; }

# 5a. mechanical は両モードで現行どおり（本 module 非干渉）
REBASE_RC=0; REBASE_OUT="b a"; CLASSIFY="mechanical"; AUTO_REBASE_SEMANTIC=on; FULL_AUTO_ENABLED=true
run_handle; assert_eq "mechanical → ar_apply_mechanical（semantic-auto ON でも無干渉）" "mechanical" "$DISPATCH"

# 5b. semantic + AUTO_REBASE_SEMANTIC=off → 現行 ar_apply_semantic（人間待ち）
REBASE_RC=0; REBASE_OUT="b a"; CLASSIFY="semantic"; AUTO_REBASE_SEMANTIC=off; FULL_AUTO_ENABLED=true
run_handle; assert_eq "semantic + gate OFF → ar_apply_semantic（現行）" "semantic-human" "$DISPATCH"

# 5c. semantic + full_auto OFF → 現行 ar_apply_semantic
REBASE_RC=0; REBASE_OUT="b a"; CLASSIFY="semantic"; AUTO_REBASE_SEMANTIC=on; FULL_AUTO_ENABLED=false
run_handle; assert_eq "semantic + full_auto OFF → ar_apply_semantic（現行）" "semantic-human" "$DISPATCH"

# 5d. semantic + gate ON + budget あり → ar_apply_semantic_auto
REBASE_RC=0; REBASE_OUT="b a"; CLASSIFY="semantic"; AUTO_REBASE_SEMANTIC=on; FULL_AUTO_ENABLED=true; BUDGET_RC=0; SAUTO_RC=0
run_handle; assert_eq "semantic + gate ON + budget → ar_apply_semantic_auto" "semantic-auto" "$DISPATCH"

# 5e. semantic + gate ON + budget 枯渇 → needs-decisions（自動解決しない）
REBASE_RC=0; REBASE_OUT="b a"; CLASSIFY="semantic"; AUTO_REBASE_SEMANTIC=on; FULL_AUTO_ENABLED=true; BUDGET_RC=1
run_handle; assert_eq "semantic + gate ON + budget 枯渇 → needs-decisions" "needs-decisions:budget-exhausted" "$DISPATCH"

# 5f. semantic-auto の dismiss 失敗 → needs-decisions フォールバック
REBASE_RC=0; REBASE_OUT="b a"; CLASSIFY="semantic"; AUTO_REBASE_SEMANTIC=on; FULL_AUTO_ENABLED=true; BUDGET_RC=0; SAUTO_RC=1
run_handle; assert_eq "semantic-auto dismiss 失敗 → needs-decisions" "needs-decisions:dismissal-failed" "$DISPATCH"
SAUTO_RC=0

# 5g. rebase rc=1（解決不能）+ gate ON → needs-decisions
REBASE_RC=1; REBASE_OUT=""; AUTO_REBASE_SEMANTIC=on; FULL_AUTO_ENABLED=true
run_handle; assert_eq "rebase 解決不能 + gate ON → needs-decisions" "needs-decisions:conflict-unresolved" "$DISPATCH"

# 5h. rebase rc=1（解決不能）+ gate OFF → 現行 codex-failed
REBASE_RC=1; REBASE_OUT=""; AUTO_REBASE_SEMANTIC=off; FULL_AUTO_ENABLED=true
run_handle; assert_eq "rebase 解決不能 + gate OFF → codex-failed（現行）" "failed:conflict-unresolved" "$DISPATCH"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
