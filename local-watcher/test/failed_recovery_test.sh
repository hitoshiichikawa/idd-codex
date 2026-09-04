#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# 用途: failed-recovery.sh の gate / 通算budget永続化 / no-progress ガード / quota 待機
#       （budget 不消費）/ 確実な終端通知 / dispatcher 統合を stub で検証する。Issue #101 / D-19。
#
# 配置先: local-watcher/test/failed_recovery_test.sh
# 依存:   bash 4+, awk, grep, jq, mktemp, sed, sha1sum
# 実行:   bash local-watcher/test/failed_recovery_test.sh
# 前提:   failed-recovery.sh から fr_* 関数、watcher から full_auto_enabled を awk 抽出 → eval。
#         codex 実行 / 外部副作用は stub し、state 永続化は実 jq + 実一時ディレクトリで検証する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/failed-recovery.sh"
MODEL_PREFLIGHT_SH="$SCRIPT_DIR/../bin/idd-codex-modules/model-preflight.sh"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
for f in "$MODULE_SH" "$MODEL_PREFLIGHT_SH" "$WATCHER_SH"; do
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
  fr_resolve_gate_enabled fr_should_recover fr_state_path fr_load_state fr_save_state
  fr_compute_failure_signature fr_detect_no_progress fr_build_recovery_prompt
  fr_finalize_success fr_handle_quota fr_run_recovery_attempt
  fr_terminate_max_attempts fr_terminate_no_progress _fr_dispatch_candidate
  fr_fetch_failed_issues fr_fetch_failed_prs process_failed_recovery
  fr_classify_immediate_failure fr_is_terminated fr_filter_terminated_candidates
  fr_terminate_immediate_failure_streak
)
for fn in "${REAL_FNS[@]}"; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$MODULE_SH" "$fn")"
done
# shellcheck source=../bin/idd-codex-modules/model-preflight.sh
. "$MODEL_PREFLIGHT_SH"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "full_auto_enabled")"

for fn in "${REAL_FNS[@]}" mp_classify_codex_failure mp_build_last_config_error_summary full_auto_enabled; do
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done

# ─── 共有グローバル（module top-level 定数 / watcher config を再現）───
REPO="owner/repo"; REPO_SLUG="owner-repo"; BASE_BRANCH="main"; LOG="/dev/null"
LABEL_FAILED="codex-failed"; LABEL_TRIGGER="codex-auto-dev"
LABEL_NEEDS_DECISIONS="codex-needs-decisions"; LABEL_NEEDS_QUOTA_WAIT="codex-needs-quota-wait"
LABEL_BLOCKED="codex-blocked"; LABEL_AWAITING_SLOT="codex-awaiting-slot"
FAILED_RECOVERY_MAX_ATTEMPTS=4; FAILED_RECOVERY_MAX_PRS=3; FAILED_RECOVERY_GIT_TIMEOUT=5
FAILED_RECOVERY_DEV_MODEL="gpt-5.5"
# #137: 本テストの fr_invoke_codex stub は即座に return するため、閾値を 0 にして
# 即時失敗判定を無効化し（elapsed 0 >= 0 → 通常扱い）、従来の budget 消費 semantics を
# 検証する。即時失敗の挙動自体は fr_immediate_fail_budget_test.sh で検証する。
# shellcheck disable=SC2034  # eval 抽出した実関数が参照する
FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS=0
# shellcheck disable=SC2034  # eval 抽出した実関数が参照する
FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK=3
FR_COMMENT_MARKER="idd-codex:failed-recovery"

# ─── trace 変数（stub 呼び出しの記録）───
GH_CALL_LOG=""; STATE_DIR=""
INVOKE_CODEX_RC=0; INVOKE_CODEX_EPOCH=""; INVOKE_CODEX_COUNT=0; INVOKE_CODEX_MODEL_ERROR=false
QUOTA_EXCEEDED_COUNT=0; PERSIST_RESET_COUNT=0; SET_RESULT_LOG=""; COMMENT_LOG=""
COLLECT_CONTEXT=""; DISPATCH_LOG=""
GH_ISSUE_LIST_RESPONSE="[]"; GH_PR_LIST_RESPONSE="[]"; GH_PR_VIEW_RESPONSE="{}"

# ─── stub ───
timeout() { shift; "$@"; }
git() { printf 'git %s\n' "$*" >>"$GH_CALL_LOG"; return 0; }
gh() {
  printf 'gh %s\n' "$*" >>"$GH_CALL_LOG"
  case "$1 $2" in
    "issue list") printf '%s' "$GH_ISSUE_LIST_RESPONSE" ;;
    "pr list")    printf '%s' "$GH_PR_LIST_RESPONSE" ;;
    "pr view")    printf '%s' "$GH_PR_VIEW_RESPONSE" ;;
  esac
  return 0
}
idd_secure_mktemp() { mktemp -t "idd-fr-${1:-x}.XXXXXX"; }
fr_log()  { :; }
fr_warn() { :; }
fr_error(){ :; }
rs_set_result() { printf '%s\n' "$1" >>"$SET_RESULT_LOG"; return 0; }

# 制御可能 stub（orchestrator テスト用）
fr_invoke_codex() {
  INVOKE_CODEX_COUNT=$((INVOKE_CODEX_COUNT + 1))
  local reset_file="$3"
  local model_artifact_file="${5:-}"
  : > "$reset_file"
  [ -n "$INVOKE_CODEX_EPOCH" ] && printf '%s\n' "$INVOKE_CODEX_EPOCH" > "$reset_file"
  if [ "$INVOKE_CODEX_MODEL_ERROR" = "true" ] && [ -n "$model_artifact_file" ]; then
    printf 'fatal: model not found: %s\n' "$FAILED_RECOVERY_DEV_MODEL" > "$model_artifact_file"
  fi
  return "$INVOKE_CODEX_RC"
}
fr_collect_issue_context() { printf '%s' "$COLLECT_CONTEXT"; }
fr_collect_pr_ci_context() { printf '%s' "$COLLECT_CONTEXT"; }
fr_post_attempt_comment() { printf '%s|%s|%s\n' "$1" "$2" "$3" >>"$COMMENT_LOG"; return 0; }
qa_handle_quota_exceeded() { QUOTA_EXCEEDED_COUNT=$((QUOTA_EXCEEDED_COUNT + 1)); return 0; }
qa_persist_reset_time() { PERSIST_RESET_COUNT=$((PERSIST_RESET_COUNT + 1)); return 0; }
# #105: fr_terminate_* が呼ぶ Slack 介入通知（本テストでは no-op stub）。
sn_notify_intervention() { :; }

reset_state() {
  GH_CALL_LOG="$(mktemp)"; SET_RESULT_LOG="$(mktemp)"; COMMENT_LOG="$(mktemp)"
  STATE_DIR="$(mktemp -d)"; FAILED_RECOVERY_STATE_DIR="$STATE_DIR"
  INVOKE_CODEX_RC=0; INVOKE_CODEX_EPOCH=""; INVOKE_CODEX_COUNT=0
  INVOKE_CODEX_MODEL_ERROR=false
  QUOTA_EXCEEDED_COUNT=0; PERSIST_RESET_COUNT=0
  GH_ISSUE_LIST_RESPONSE="[]"; GH_PR_LIST_RESPONSE="[]"; GH_PR_VIEW_RESPONSE="{}"
}
calls() { grep -c "$1" "$GH_CALL_LOG" 2>/dev/null || true; }
state_field() { fr_load_state "$1" "$2" | jq -r "$3"; }

PASS_COUNT=0; FAIL_COUNT=0
assert_eq() { local l="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l"; echo "  exp=$(printf '%q' "$e") act=$(printf '%q' "$a")"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }
assert_ne() { local l="$1" e="$2" a="$3"; if [ "$e" != "$a" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l (両者 '$a')"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }
rc_of() { local fn="$1"; shift; local r=0; "$fn" "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }
# 現在シェルで実行して trace 変数（INVOKE_CODEX_COUNT 等）を保持する（$(...) サブシェル回避）。
ATTEMPT_RC=0
run_attempt() { ATTEMPT_RC=0; fr_run_recovery_attempt "$@" >/dev/null 2>&1 || ATTEMPT_RC=$?; }

# ════════════════════════════════════════════════════════════════════════════
echo "--- 1. fr_resolve_gate_enabled（個別 gate 正規化）---"
FAILED_RECOVERY_ENABLED=true;  assert_eq "true → ON(0)"   "0" "$(rc_of fr_resolve_gate_enabled)"
FAILED_RECOVERY_ENABLED=false; assert_eq "false → OFF(1)" "1" "$(rc_of fr_resolve_gate_enabled)"
FAILED_RECOVERY_ENABLED=True;  assert_eq "True → OFF(1)"  "1" "$(rc_of fr_resolve_gate_enabled)"
FAILED_RECOVERY_ENABLED=1;     assert_eq "1 → OFF(1)"     "1" "$(rc_of fr_resolve_gate_enabled)"
unset FAILED_RECOVERY_ENABLED; assert_eq "未設定 → OFF(1)" "1" "$(rc_of fr_resolve_gate_enabled)"
FAILED_RECOVERY_ENABLED=true

echo ""; echo "--- 2. fr_should_recover（budget 判定）---"
FAILED_RECOVERY_MAX_ATTEMPTS=4
assert_eq "0 < 4 → recover(0)" "0" "$(rc_of fr_should_recover 0)"
assert_eq "3 < 4 → recover(0)" "0" "$(rc_of fr_should_recover 3)"
assert_eq "4 = 4 → stop(1)"    "1" "$(rc_of fr_should_recover 4)"
assert_eq "5 > 4 → stop(1)"    "1" "$(rc_of fr_should_recover 5)"
assert_eq "非整数 → 0 扱い recover(0)" "0" "$(rc_of fr_should_recover abc)"

echo ""; echo "--- 3. fr_state_path（kind prefix で衝突回避）---"
FAILED_RECOVERY_STATE_DIR="/tmp/fr-state"
assert_eq "issue path" "/tmp/fr-state/issue-5.json" "$(fr_state_path issue 5)"
assert_eq "pr path"    "/tmp/fr-state/pr-5.json"    "$(fr_state_path pr 5)"
assert_ne "issue/pr 同番号でも別 path" "$(fr_state_path issue 5)" "$(fr_state_path pr 5)"

echo ""; echo "--- 4. fr_save_state / fr_load_state（budget 永続化・fail-open・history truncate）---"
reset_state
assert_eq "未保存 → {} (fail-open)" "{}" "$(fr_load_state issue 9)"
fr_save_state issue 9 2 "in-progress" "sigAAA" "headBBB"
assert_eq "total_attempts 永続化" "2" "$(state_field issue 9 '.total_attempts')"
assert_eq "last_status 永続化"     "in-progress" "$(state_field issue 9 '.last_status')"
assert_eq "last_failure_signature 永続化" "sigAAA" "$(state_field issue 9 '.last_failure_signature')"
assert_eq "last_head_sha 永続化"   "headBBB" "$(state_field issue 9 '.last_head_sha')"
fr_save_state issue 9 3 "failed" "sigCCC" "headDDD"
assert_eq "再保存で total 更新" "3" "$(state_field issue 9 '.total_attempts')"
assert_eq "history が 2 件に蓄積" "2" "$(state_field issue 9 '.history | length')"
# history が 8 件で truncate される
for i in $(seq 1 12); do fr_save_state issue 8 "$i" "in-progress" "s$i" ""; done
assert_eq "history は最大 8 件" "8" "$(state_field issue 8 '.history | length')"
assert_eq "history truncate は末尾保持(total=12)" "12" "$(state_field issue 8 '.history | last | .total')"
# 破損ファイル → fail-open {}
printf 'not json {{{' > "$STATE_DIR/issue-7.json"
assert_eq "破損ファイル → {} (fail-open)" "{}" "$(fr_load_state issue 7)"

echo ""; echo "--- 5. fr_compute_failure_signature（volatile 正規化で安定 hash）---"
SIG1=$(printf 'Error at 2026-06-22T10:00:00Z run #123 sha 0123456789abcdef0123456789abcdef01234567' | fr_compute_failure_signature)
SIG2=$(printf 'Error at 2026-01-01T23:59:00Z run #999 sha fedcba9876543210fedcba9876543210fedcba98' | fr_compute_failure_signature)
SIG3=$(printf 'totally different failure message' | fr_compute_failure_signature)
assert_eq "timestamp/run/sha 差は同一 signature" "$SIG1" "$SIG2"
assert_ne "異なる失敗は異なる signature"          "$SIG1" "$SIG3"
assert_eq "signature は 40 桁 hex" "40" "${#SIG1}"

echo ""; echo "--- 6. fr_detect_no_progress（境界マトリクス）---"
mkstate() { jq -nc --arg s "$1" --arg h "$2" '{last_failure_signature:$s,last_head_sha:$h}'; }
assert_eq "prev sig 無し → progress(1)"        "1" "$(rc_of fr_detect_no_progress "sigX" "" "$(mkstate '' '')")"
assert_eq "sig 異 → progress(1)"               "1" "$(rc_of fr_detect_no_progress "sigX" "" "$(mkstate 'sigY' '')")"
assert_eq "Issue: sig 一致 → no-progress(0)"   "0" "$(rc_of fr_detect_no_progress "sigX" "" "$(mkstate 'sigX' '')")"
assert_eq "PR: sig 一致+head 前進 → progress(1)" "1" "$(rc_of fr_detect_no_progress "sigX" "headNEW" "$(mkstate 'sigX' 'headOLD')")"
assert_eq "PR: sig 一致+head 同一 → no-progress(0)" "0" "$(rc_of fr_detect_no_progress "sigX" "headSAME" "$(mkstate 'sigX' 'headSAME')")"

echo ""; echo "--- 7. fr_run_recovery_attempt: 正常系（codex 成功 → 復旧）---"
reset_state; COLLECT_CONTEXT="build failed: missing import"; INVOKE_CODEX_RC=0
run_attempt issue 10 ""
assert_eq "成功 → rc 0" "0" "$ATTEMPT_RC"
assert_eq "codex 1 回起動" "1" "$INVOKE_CODEX_COUNT"
assert_eq "budget 1 消費 (total=1)" "1" "$(state_field issue 10 '.total_attempts')"
assert_eq "last_status=succeeded" "succeeded" "$(state_field issue 10 '.last_status')"
assert_eq "codex-failed 除去 (gh issue edit --remove-label)" "1" "$(calls 'issue edit.*remove-label')"

echo ""; echo "--- 8. fr_run_recovery_attempt: 異常系（codex 失敗 → 据え置き・据え置き再試行）---"
reset_state; COLLECT_CONTEXT="lint error E501"; INVOKE_CODEX_RC=1
run_attempt issue 11 ""
assert_eq "失敗 → rc 1" "1" "$ATTEMPT_RC"
assert_eq "budget 1 消費 (total=1)" "1" "$(state_field issue 11 '.total_attempts')"
assert_eq "失敗時は codex-failed を除去しない" "0" "$(calls 'issue edit.*remove-label')"

echo ""; echo "--- 9. fr_run_recovery_attempt: budget 超過 → 即終端(2)・codex 起動なし ---"
reset_state; COLLECT_CONTEXT="ctx"
fr_save_state issue 12 4 "failed" "oldsig" ""   # 既に上限到達
run_attempt issue 12 ""
assert_eq "budget 到達 → rc 2" "2" "$ATTEMPT_RC"
assert_eq "budget 到達 → codex 起動なし" "0" "$INVOKE_CODEX_COUNT"

echo ""; echo "--- 10. fr_run_recovery_attempt: no-progress → 即終端(3)・codex 起動なし ---"
reset_state; COLLECT_CONTEXT="same failure forever"
SIG_NOPROG=$(printf '%s' "$COLLECT_CONTEXT" | fr_compute_failure_signature)
fr_save_state issue 13 1 "failed" "$SIG_NOPROG" ""   # 直前と同一 signature・Issue 経路
run_attempt issue 13 ""
assert_eq "no-progress → rc 3" "3" "$ATTEMPT_RC"
assert_eq "no-progress → codex 起動なし" "0" "$INVOKE_CODEX_COUNT"
assert_eq "no-progress → budget 不消費 (total=1 据え置き)" "1" "$(state_field issue 13 '.total_attempts')"

echo ""; echo "--- 11. fr_run_recovery_attempt: quota reached → 待機・budget 不消費 ---"
reset_state; COLLECT_CONTEXT="some new failure"; INVOKE_CODEX_RC=99; INVOKE_CODEX_EPOCH="2000000000"
fr_save_state issue 14 1 "failed" "prevsig" ""   # prev_total=1
run_attempt issue 14 ""
assert_eq "quota → rc 99" "99" "$ATTEMPT_RC"
assert_eq "quota → budget 不消費 (total=1 に巻き戻し)" "1" "$(state_field issue 14 '.total_attempts')"
assert_eq "quota → last_status=quota-wait" "quota-wait" "$(state_field issue 14 '.last_status')"
assert_eq "quota → baseline signature 据え置き(prevsig)" "prevsig" "$(state_field issue 14 '.last_failure_signature')"
assert_eq "quota(issue) → qa_handle_quota_exceeded 1 回" "1" "$QUOTA_EXCEEDED_COUNT"

echo ""; echo "--- 12. fr_run_recovery_attempt: model config error → budget 不消費 ---"
reset_state; COLLECT_CONTEXT="model config mismatch"; INVOKE_CODEX_RC=78
fr_save_state issue 15 2 "failed" "prevsig" ""
run_attempt issue 15 ""
assert_eq "model preflight rc → rc 1 (codex-failed 据え置き)" "1" "$ATTEMPT_RC"
assert_eq "model preflight rc → budget 不消費 (total=2 に巻き戻し)" "2" "$(state_field issue 15 '.total_attempts')"
assert_eq "model preflight rc → last_status=model-config-error" "model-config-error" "$(state_field issue 15 '.last_status')"
assert_eq "model preflight rc → terminal として扱う" "0" "$(rc_of fr_is_terminated "$(fr_load_state issue 15)")"
assert_eq "model preflight rc → 設定エラー comment" \
  "true" \
  "$(grep -Fq 'モデル設定エラーの可能性' "$COMMENT_LOG" && echo true || echo false)"

reset_state; COLLECT_CONTEXT="retired model"; INVOKE_CODEX_RC=1; INVOKE_CODEX_MODEL_ERROR=true
fr_save_state issue 16 3 "failed" "prevsig2" ""
run_attempt issue 16 ""
assert_eq "model-not-found artifact → rc 1" "1" "$ATTEMPT_RC"
assert_eq "model-not-found artifact → budget 不消費 (total=3 に巻き戻し)" "3" "$(state_field issue 16 '.total_attempts')"
assert_eq "model-not-found artifact → last_status=model-config-error" "model-config-error" "$(state_field issue 16 '.last_status')"
assert_eq "model-not-found artifact → comment has reason" \
  "true" \
  "$(grep -Fq 'model-not-found' "$COMMENT_LOG" && echo true || echo false)"

echo ""; echo "--- 13. fr_run_recovery_attempt: PR quota → qa_handle 経由せず persist+comment ---"
reset_state; COLLECT_CONTEXT="ci red"; INVOKE_CODEX_RC=99; INVOKE_CODEX_EPOCH="2000000000"
PRJSON='{"number":42,"headRefName":"codex/issue-42-impl-x","headRefOid":"sha42"}'
run_attempt pr 42 "$PRJSON"
assert_eq "PR quota → rc 99" "99" "$ATTEMPT_RC"
assert_eq "PR quota → qa_handle_quota_exceeded 呼ばない" "0" "$QUOTA_EXCEEDED_COUNT"
assert_eq "PR quota → qa_persist_reset_time 1 回" "1" "$PERSIST_RESET_COUNT"

echo ""; echo "--- 14. 終端通知（max-attempts / no-progress）---"
reset_state
fr_terminate_max_attempts issue 20 4
assert_eq "max-attempts → rs_set_result(codex-failed) 1 回" "1" "$(grep -c 'codex-failed' "$SET_RESULT_LOG" || true)"
assert_eq "max-attempts → コメント 1 件" "1" "$(grep -c '^issue|20|' "$COMMENT_LOG" || true)"
assert_eq "max-attempts → label 除去しない（据え置き）" "0" "$(calls 'remove-label')"
reset_state
fr_terminate_no_progress pr 21 2 "deadbeefcafe"
assert_eq "no-progress → rs_set_result(codex-failed) 1 回" "1" "$(grep -c 'codex-failed' "$SET_RESULT_LOG" || true)"
assert_eq "no-progress → コメント 1 件" "1" "$(grep -c '^pr|21|' "$COMMENT_LOG" || true)"

echo ""; echo "--- 15. _fr_dispatch_candidate（rc ルーティング）---"
reset_state
# rc 2 → max-attempts 終端
fr_run_recovery_attempt() { return 2; }
fr_save_state issue 30 4 "failed" "s" ""
_fr_dispatch_candidate issue 30 "" >/dev/null 2>&1
assert_eq "rc2 → max-attempts 通知(rs_set_result)" "1" "$(grep -c 'codex-failed' "$SET_RESULT_LOG" || true)"
reset_state
# rc 3 → no-progress 終端
fr_run_recovery_attempt() { return 3; }
fr_save_state issue 31 2 "no-progress" "sigZ" ""
_fr_dispatch_candidate issue 31 "" >/dev/null 2>&1
assert_eq "rc3 → no-progress 通知(rs_set_result)" "1" "$(grep -c 'codex-failed' "$SET_RESULT_LOG" || true)"
reset_state
# rc 99 → 非終端（通知なし）
fr_run_recovery_attempt() { return 99; }
_fr_dispatch_candidate issue 32 "" >/dev/null 2>&1
assert_eq "rc99(quota) → 非終端・rs_set_result なし" "0" "$(grep -c 'codex-failed' "$SET_RESULT_LOG" || true)"
# 復元
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_run_recovery_attempt")"

echo ""; echo "--- 16. process_failed_recovery（二重 opt-in gate）---"
# fetch / dispatch を stub 化して gate 挙動と enumerate を検証。
# eval 上書きで（literal 定義を作らず）、上の section が呼ぶ eval 抽出版の前方参照
# 誤検知（SC2218）を避ける。
eval 'fr_fetch_failed_issues() { printf "%s" "$GH_ISSUE_LIST_RESPONSE"; }'
eval 'fr_fetch_failed_prs() { printf "%s" "$GH_PR_LIST_RESPONSE"; }'
eval '_fr_dispatch_candidate() { printf "%s|%s\n" "$1" "$2" >>"$DISPATCH_LOG"; return 0; }'

reset_state; DISPATCH_LOG="$(mktemp)"
FULL_AUTO_ENABLED=false; FAILED_RECOVERY_ENABLED=true
GH_ISSUE_LIST_RESPONSE='[{"number":1}]'
process_failed_recovery || true
assert_eq "full_auto OFF → dispatch 0 件" "0" "$(grep -c '.' "$DISPATCH_LOG" || true)"

reset_state; DISPATCH_LOG="$(mktemp)"
FULL_AUTO_ENABLED=true; FAILED_RECOVERY_ENABLED=false
GH_ISSUE_LIST_RESPONSE='[{"number":1}]'
process_failed_recovery || true
assert_eq "FAILED_RECOVERY OFF → dispatch 0 件" "0" "$(grep -c '.' "$DISPATCH_LOG" || true)"

reset_state; DISPATCH_LOG="$(mktemp)"
FULL_AUTO_ENABLED=true; FAILED_RECOVERY_ENABLED=true
GH_ISSUE_LIST_RESPONSE='[{"number":101},{"number":102}]'
GH_PR_LIST_RESPONSE='[{"number":42,"headRefName":"codex/issue-42-impl-x","headRefOid":"s"}]'
process_failed_recovery || true
assert_eq "両 gate ON → issue 2 件 dispatch" "2" "$(grep -c '^issue|' "$DISPATCH_LOG" || true)"
assert_eq "両 gate ON → pr 1 件 dispatch" "1" "$(grep -c '^pr|' "$DISPATCH_LOG" || true)"

# PR 処理上限
reset_state; DISPATCH_LOG="$(mktemp)"
FULL_AUTO_ENABLED=true; FAILED_RECOVERY_ENABLED=true; FAILED_RECOVERY_MAX_PRS=2
GH_ISSUE_LIST_RESPONSE='[]'
GH_PR_LIST_RESPONSE='[{"number":1,"headRefName":"h","headRefOid":"s"},{"number":2,"headRefName":"h","headRefOid":"s"},{"number":3,"headRefName":"h","headRefOid":"s"}]'
process_failed_recovery || true
assert_eq "MAX_PRS=2 → pr 2 件のみ dispatch" "2" "$(grep -c '^pr|' "$DISPATCH_LOG" || true)"
FAILED_RECOVERY_MAX_PRS=3

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
