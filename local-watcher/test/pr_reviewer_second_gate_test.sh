#!/usr/bin/env bash
#
# 用途: pr-reviewer.sh の 2nd gate（claude-review / #108）を検証する。
#       gate（PR_REVIEWER_SECOND_GATE=claude × status-check × FULL_AUTO）/ claude 可用性
#       チェック / claude-review status publish（approve→success・else→failure）/
#       pr_run_claude_second_gate の disposition（claude 不在/未認証/実行失敗/空出力 →
#       publish しない・成功 → publish）を stub で確認する。Issue #108 / D-04。
#
# 配置先: local-watcher/test/pr_reviewer_second_gate_test.sh
# 依存:   bash 4+, awk, grep, jq, mktemp
# 実行:   bash local-watcher/test/pr_reviewer_second_gate_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/pr-reviewer.sh"
[ -f "$MODULE_SH" ] || { echo "ERROR: not found: $MODULE_SH" >&2; exit 2; }

extract_function() {
  local script="$1" fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

REAL_FNS=(
  pr_status_check_enabled pr_second_gate_enabled pr_publish_commit_status
  pr_publish_claude_status pr_check_claude_installed pr_check_claude_authenticated
  pr_run_claude_second_gate
)
for fn in "${REAL_FNS[@]}"; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$MODULE_SH" "$fn")"
done
for fn in "${REAL_FNS[@]}"; do
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done

# ─── 共有グローバル ───
REPO="owner/repo"; PR_REVIEWER_GIT_TIMEOUT=5
SHA40="$(printf 'a%.0s' {1..40})"
# pr_run_claude_second_gate が参照（set -u 対策。pr_substitute_placeholders は stub）。
PR_REVIEWER_CLAUDE_CMD="claude -p \"\$(cat '{PROMPT_FILE}')\""
PR_REVIEWER_CLAUDE_AUTH_CMD=""

# ─── stub ───
GH_CALL_LOG=""
timeout() { shift; "$@"; }
gh() { printf 'gh %s\n' "$*" >>"$GH_CALL_LOG"; return 0; }
pr_log()  { :; }
pr_warn() { :; }
pr_error(){ :; }
idd_secure_mktemp() { mktemp -t "idd-pr2-${1:-x}.XXXXXX"; }

reset_state() { GH_CALL_LOG="$(mktemp)"; }
calls() { grep -c "$1" "$GH_CALL_LOG" 2>/dev/null || true; }

PASS_COUNT=0; FAIL_COUNT=0
assert_eq() { local l="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l"; echo "  exp=$(printf '%q' "$e") act=$(printf '%q' "$a")"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }
assert_contains() { local l="$1" h="$2" n="$3"; case "$h" in *"$n"*) echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1));; *) echo "FAIL: $l ('$n' 不在)"; FAIL_COUNT=$((FAIL_COUNT+1));; esac; }
rc_of() { local fn="$1"; shift; local r=0; "$fn" "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }

# ════════════════════════════════════════════════════════════════════════════
echo "--- 1. pr_second_gate_enabled（toggle × status-check × FULL_AUTO）---"
PR_REVIEWER_SECOND_GATE=claude; PR_REVIEWER_STATUS_CHECK_ENABLED=true; FULL_AUTO_ENABLED=true
assert_eq "claude + status + full_auto → 有効(0)" "0" "$(rc_of pr_second_gate_enabled)"
PR_REVIEWER_SECOND_GATE=off
assert_eq "toggle off → 無効(1)" "1" "$(rc_of pr_second_gate_enabled)"
PR_REVIEWER_SECOND_GATE=claude; PR_REVIEWER_STATUS_CHECK_ENABLED=false; FULL_AUTO_ENABLED=true
assert_eq "status-check off → 無効(1)" "1" "$(rc_of pr_second_gate_enabled)"
PR_REVIEWER_SECOND_GATE=claude; PR_REVIEWER_STATUS_CHECK_ENABLED=true; FULL_AUTO_ENABLED=false
assert_eq "full_auto off → 無効(1)" "1" "$(rc_of pr_second_gate_enabled)"
PR_REVIEWER_SECOND_GATE=Claude; PR_REVIEWER_STATUS_CHECK_ENABLED=true; FULL_AUTO_ENABLED=true
assert_eq "Claude(大文字) → 無効(1)" "1" "$(rc_of pr_second_gate_enabled)"

echo ""; echo "--- 2. pr_publish_claude_status（context=claude-review / state mapping）---"
PR_REVIEWER_STATUS_CHECK_ENABLED=true; FULL_AUTO_ENABLED=true
reset_state; r=$(rc_of pr_publish_claude_status 7 "$SHA40" approve "https://x/7")
assert_eq "approve → rc 0" "0" "$r"
assert_contains "context=claude-review" "$(cat "$GH_CALL_LOG")" "context=claude-review"
assert_contains "approve → state=success" "$(cat "$GH_CALL_LOG")" "state=success"
assert_contains "statuses エンドポイント + sha" "$(cat "$GH_CALL_LOG")" "repos/owner/repo/statuses/${SHA40}"
reset_state; pr_publish_claude_status 7 "$SHA40" iteration "https://x/7" >/dev/null 2>&1 || true
assert_contains "iteration → state=failure" "$(cat "$GH_CALL_LOG")" "state=failure"
# gate OFF → publish しない（pr_publish_commit_status の内部 gate）
reset_state; PR_REVIEWER_STATUS_CHECK_ENABLED=false
pr_publish_claude_status 7 "$SHA40" approve "https://x/7" >/dev/null 2>&1 || true
assert_eq "status-check OFF → gh 0 回（publish せず）" "0" "$(calls '^gh ')"
PR_REVIEWER_STATUS_CHECK_ENABLED=true

echo ""; echo "--- 3. claude 可用性チェック ---"
# installed: PATH に fake claude
FAKEBIN="$(mktemp -d)"; printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/claude"; chmod +x "$FAKEBIN/claude"
OLDPATH="$PATH"
PATH="$FAKEBIN:$PATH"; assert_eq "claude が PATH 上 → installed(0)" "0" "$(rc_of pr_check_claude_installed)"
PATH="/var/empty/nonexistent-$$"; assert_eq "claude 不在 → not-installed(1)" "1" "$(rc_of pr_check_claude_installed)"
PATH="$OLDPATH"; rm -rf "$FAKEBIN"
# authenticated: auth cmd
PR_REVIEWER_CLAUDE_AUTH_CMD=""; assert_eq "auth cmd 空 → skip(2)" "2" "$(rc_of pr_check_claude_authenticated)"
PR_REVIEWER_CLAUDE_AUTH_CMD="true"; assert_eq "auth cmd 成功 → ok(0)" "0" "$(rc_of pr_check_claude_authenticated)"
PR_REVIEWER_CLAUDE_AUTH_CMD="false"; assert_eq "auth cmd 失敗 → not-auth(1)" "1" "$(rc_of pr_check_claude_authenticated)"
PR_REVIEWER_CLAUDE_AUTH_CMD=""

echo ""; echo "--- 4. pr_run_claude_second_gate disposition ---"
# leaf を eval 上書きして publish 有無と verdict を記録（SC2218 回避のため eval）。
PUBLISH_LOG=""; INSTALLED_RC=0; AUTH_RC=2; EXEC_RESULT=""; REVIEW_TEXT=""; VERDICT=""
eval 'pr_check_claude_installed() { return "${INSTALLED_RC:-0}"; }'
eval 'pr_check_claude_authenticated() { return "${AUTH_RC:-2}"; }'
eval 'pr_build_prompt_file() { mktemp -t idd-pr2-prompt.XXXXXX; }'
eval 'pr_substitute_placeholders() { printf "claude-cmd"; }'
eval 'pr_execute_review_command() { printf "%s" "$REVIEW_TEXT" > "$4"; printf "%s" "$EXEC_RESULT" > "$6"; }'
eval 'pr_resolve_review_verdict() { printf "%s" "$VERDICT"; }'
eval 'pr_publish_claude_status() { PUBLISH_LOG="${PUBLISH_LOG} $3"; return 0; }'

run_gate() { PUBLISH_LOG=""; pr_run_claude_second_gate 9 "$SHA40" "codex/issue-9-impl-x" "main" "https://x/9" >/dev/null 2>&1 || true; }

INSTALLED_RC=1; run_gate
assert_eq "claude 不在 → publish しない" "" "$PUBLISH_LOG"
INSTALLED_RC=0; AUTH_RC=1; run_gate
assert_eq "未認証 → publish しない" "" "$PUBLISH_LOG"
INSTALLED_RC=0; AUTH_RC=2; EXEC_RESULT="fetch-fail"; run_gate
assert_eq "fetch 失敗 → publish しない" "" "$PUBLISH_LOG"
INSTALLED_RC=0; AUTH_RC=2; EXEC_RESULT="ran:1:clean"; REVIEW_TEXT="x"; run_gate
assert_eq "exec 非ゼロ → publish しない" "" "$PUBLISH_LOG"
INSTALLED_RC=0; AUTH_RC=2; EXEC_RESULT="ran:0:modified"; REVIEW_TEXT="x"; run_gate
assert_eq "workspace-modified → publish しない" "" "$PUBLISH_LOG"
INSTALLED_RC=0; AUTH_RC=2; EXEC_RESULT="ran:0:clean"; REVIEW_TEXT=""; run_gate
assert_eq "空出力 → publish しない" "" "$PUBLISH_LOG"
INSTALLED_RC=0; AUTH_RC=2; EXEC_RESULT="ran:0:clean"; REVIEW_TEXT="VERDICT: approve"; VERDICT="approve"; run_gate
assert_eq "成功 approve → publish(approve)" " approve" "$PUBLISH_LOG"
EXEC_RESULT="ran:0:clean"; REVIEW_TEXT="VERDICT: codex-needs-iteration"; VERDICT="iteration"; run_gate
assert_eq "成功 iteration → publish(iteration)" " iteration" "$PUBLISH_LOG"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
