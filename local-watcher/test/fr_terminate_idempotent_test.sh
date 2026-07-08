#!/usr/bin/env bash
#
# 用途: failed-recovery.sh の #140（terminate の cross-cycle 冪等化）を stub で検証する。
#       - terminal 到達後の 2 サイクル目で終端コメント・rs_set_result・sn_notify_intervention
#         が再発火しない（fetch 段階の terminal 除外 + terminate 冒頭ガード）
#       - state 破損・欠落時は fail-open（従来の再投稿に退行 / silent fail しない）
#
# 配置先: local-watcher/test/fr_terminate_idempotent_test.sh
# 依存:   bash 4+, awk, grep, jq, mktemp, sed, sha1sum
# 実行:   bash local-watcher/test/fr_terminate_idempotent_test.sh
# 前提:   failed-recovery.sh から fr_* 関数、watcher から full_auto_enabled を awk 抽出 → eval。
#         codex 実行 / 外部副作用は stub し、state 永続化は実 jq + 実一時ディレクトリで検証する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/failed-recovery.sh"
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
  fr_resolve_gate_enabled fr_should_recover fr_state_path fr_load_state fr_save_state
  fr_compute_failure_signature fr_detect_no_progress
  fr_is_terminated fr_filter_terminated_candidates fr_classify_immediate_failure
  fr_finalize_success fr_run_recovery_attempt
  fr_terminate_max_attempts fr_terminate_no_progress fr_terminate_immediate_failure_streak
  _fr_dispatch_candidate fr_fetch_failed_issues fr_fetch_failed_prs process_failed_recovery
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

# ─── 共有グローバル（eval 抽出した実関数が参照する。SC2034 は false-positive）───
# shellcheck disable=SC2034
{
REPO="owner/repo"; REPO_SLUG="owner-repo"; BASE_BRANCH="main"; LOG="/dev/null"
LABEL_FAILED="codex-failed"; LABEL_TRIGGER="codex-auto-dev"
LABEL_NEEDS_DECISIONS="codex-needs-decisions"; LABEL_NEEDS_QUOTA_WAIT="codex-needs-quota-wait"
LABEL_BLOCKED="codex-blocked"; LABEL_AWAITING_SLOT="codex-awaiting-slot"
FAILED_RECOVERY_MAX_ATTEMPTS=4; FAILED_RECOVERY_MAX_PRS=3; FAILED_RECOVERY_GIT_TIMEOUT=5
FAILED_RECOVERY_DEV_MODEL="gpt-5.5"
# 本テストの stub は即 return するため即時失敗判定は閾値 0 で無効化する
# （#140 の検証対象は terminate 冪等化。即時失敗は fr_immediate_fail_budget_test.sh）。
FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS=0
FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK=3
FR_COMMENT_MARKER="idd-codex:failed-recovery"
FULL_AUTO_ENABLED=true; FAILED_RECOVERY_ENABLED=true
}

# ─── trace 変数 / stub ───
GH_CALL_LOG=""; STATE_DIR=""; COMMENT_LOG=""; SET_RESULT_LOG=""; SN_NOTIFY_LOG=""
INVOKE_CODEX_RC=0; INVOKE_CODEX_COUNT=0; COLLECT_CONTEXT=""; FR_LOG_FILE=""
GH_ISSUE_LIST_RESPONSE="[]"

timeout() { shift; "$@"; }
git() { printf 'git %s\n' "$*" >>"$GH_CALL_LOG"; return 0; }
gh() {
  printf 'gh %s\n' "$*" >>"$GH_CALL_LOG"
  case "$1 $2" in
    "issue list") printf '%s' "$GH_ISSUE_LIST_RESPONSE" ;;
    "pr list")    printf '[]' ;;
  esac
  return 0
}
idd_secure_mktemp() { mktemp -t "idd-fr-${1:-x}.XXXXXX"; }
fr_log()  { printf '%s\n' "$*" >>"$FR_LOG_FILE"; }
fr_warn() { :; }
fr_error(){ :; }
rs_set_result() { printf '%s\n' "$1" >>"$SET_RESULT_LOG"; return 0; }
sn_notify_intervention() { printf '%s|%s|%s\n' "$1" "$2" "$3" >>"$SN_NOTIFY_LOG"; return 0; }
fr_invoke_codex() {
  INVOKE_CODEX_COUNT=$((INVOKE_CODEX_COUNT + 1))
  local reset_file="$3"
  : > "$reset_file"
  return "$INVOKE_CODEX_RC"
}
fr_collect_issue_context() { printf '%s' "$COLLECT_CONTEXT"; }
fr_collect_pr_ci_context() { printf '%s' "$COLLECT_CONTEXT"; }
fr_post_attempt_comment() { printf '%s|%s|%s\n' "$1" "$2" "$3" >>"$COMMENT_LOG"; return 0; }
qa_handle_quota_exceeded() { return 0; }
qa_persist_reset_time() { return 0; }
fr_build_recovery_prompt() { printf 'prompt'; }
fr_handle_quota() { return 99; }

# shellcheck disable=SC2034  # eval 抽出した実関数が参照する
reset_state() {
  GH_CALL_LOG="$(mktemp)"; COMMENT_LOG="$(mktemp)"; SET_RESULT_LOG="$(mktemp)"
  SN_NOTIFY_LOG="$(mktemp)"; FR_LOG_FILE="$(mktemp)"
  STATE_DIR="$(mktemp -d)"; FAILED_RECOVERY_STATE_DIR="$STATE_DIR"
  INVOKE_CODEX_RC=0; INVOKE_CODEX_COUNT=0; COLLECT_CONTEXT=""
  GH_ISSUE_LIST_RESPONSE="[]"
}
state_field() { fr_load_state "$1" "$2" | jq -r "$3"; }
comments_for() { grep -c "^${1}|${2}|" "$COMMENT_LOG" 2>/dev/null || true; }

PASS_COUNT=0; FAIL_COUNT=0
assert_eq() { local l="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l"; echo "  exp=$(printf '%q' "$e") act=$(printf '%q' "$a")"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }
rc_of() { local fn="$1"; shift; local r=0; "$fn" "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }

# ════════════════════════════════════════════════════════════════════════════
echo "--- 1. fr_is_terminated（純粋関数）---"
assert_eq "空文字 → 未終端(1)"                "1" "$(rc_of fr_is_terminated '')"
assert_eq "{} → 未終端(1)"                    "1" "$(rc_of fr_is_terminated '{}')"
assert_eq "in-progress → 未終端(1)"           "1" "$(rc_of fr_is_terminated '{"last_status":"in-progress"}')"
assert_eq "succeeded → 未終端(1)"             "1" "$(rc_of fr_is_terminated '{"last_status":"succeeded"}')"
assert_eq "quota-wait → 未終端(1)"            "1" "$(rc_of fr_is_terminated '{"last_status":"quota-wait"}')"
assert_eq "max-attempts → 終端(0)"            "0" "$(rc_of fr_is_terminated '{"last_status":"max-attempts"}')"
assert_eq "no-progress → 終端(0)"             "0" "$(rc_of fr_is_terminated '{"last_status":"no-progress"}')"
assert_eq "immediate-failure-streak → 終端(0)" "0" "$(rc_of fr_is_terminated '{"last_status":"immediate-failure-streak"}')"
assert_eq "終端理由を stdout に出す"           "max-attempts" "$(fr_is_terminated '{"last_status":"max-attempts"}')"
assert_eq "破損 JSON → 未終端(1) fail-open"    "1" "$(rc_of fr_is_terminated 'not json {{{')"

echo ""; echo "--- 2. fr_filter_terminated_candidates（列挙除外・fail-open）---"
reset_state
fr_save_state issue 70 4 "max-attempts" "sig" ""
fr_save_state issue 71 1 "in-progress" "sig" ""
FILTERED=$(fr_filter_terminated_candidates issue '[{"number":70},{"number":71},{"number":72}]')
assert_eq "terminal(70) を除外・非 terminal(71)/state 無し(72) は残す" '[{"number":71},{"number":72}]' "$FILTERED"
assert_eq "除外時に suppressed=enumeration ログ" "1" "$(grep -c 'issue=#70 terminated reason=max-attempts suppressed=enumeration' "$FR_LOG_FILE" || true)"
# 破損 state → fail-open で残す
printf 'broken {{{' > "$STATE_DIR/issue-73.json"
FILTERED=$(fr_filter_terminated_candidates issue '[{"number":73}]')
assert_eq "破損 state → fail-open で候補に残す" '[{"number":73}]' "$FILTERED"
# 不正入力
assert_eq "空入力 → []"        "[]" "$(fr_filter_terminated_candidates issue '')"
assert_eq "非配列 → []"        "[]" "$(fr_filter_terminated_candidates issue '{"number":1}')"
assert_eq "不正 kind → []"     "[]" "$(fr_filter_terminated_candidates bogus '[{"number":1}]')"
assert_eq "number 非数値 → fail-open で残す" '[{"number":"x"}]' "$(fr_filter_terminated_candidates issue '[{"number":"x"}]')"

echo ""; echo "--- 3. max-attempts 終端 → 2 サイクル目で再投稿されない（E2E 2 サイクル）---"
reset_state; COLLECT_CONTEXT="persistent failure"
GH_ISSUE_LIST_RESPONSE='[{"number":80}]'
fr_save_state issue 80 4 "in-progress" "oldsig" ""   # budget 到達済み・未終端
# ── cycle 1: fetch → dispatch → rc 2 → terminate（コメント + rs + sn 各 1 回）
process_failed_recovery >/dev/null 2>&1 || true
assert_eq "cycle1 → 終端コメント 1 件" "1" "$(comments_for issue 80)"
assert_eq "cycle1 → rs_set_result 1 回" "1" "$(grep -c 'codex-failed' "$SET_RESULT_LOG" || true)"
assert_eq "cycle1 → sn_notify 1 回" "1" "$(grep -c '^failed-recovery-budget|' "$SN_NOTIFY_LOG" || true)"
assert_eq "cycle1 → last_status=max-attempts 永続化" "max-attempts" "$(state_field issue 80 '.last_status')"
# ── cycle 2: fetch 段階で terminal 除外 → 再発火なし
process_failed_recovery >/dev/null 2>&1 || true
assert_eq "cycle2 → 終端コメント再投稿なし（1 件のまま）" "1" "$(comments_for issue 80)"
assert_eq "cycle2 → rs_set_result 再発火なし（1 回のまま）" "1" "$(grep -c 'codex-failed' "$SET_RESULT_LOG" || true)"
assert_eq "cycle2 → sn_notify 再発火なし（1 回のまま）" "1" "$(grep -c '^failed-recovery-budget|' "$SN_NOTIFY_LOG" || true)"
assert_eq "cycle2 → codex 起動なし" "0" "$INVOKE_CODEX_COUNT"
assert_eq "cycle2 → suppressed=enumeration ログで観測可能" "1" "$(grep -c 'issue=#80 terminated reason=max-attempts suppressed=enumeration' "$FR_LOG_FILE" || true)"

echo ""; echo "--- 4. no-progress 終端 → 2 サイクル目で再投稿されない（E2E 2 サイクル）---"
reset_state; COLLECT_CONTEXT="same failure forever"
SIG_NP=$(printf '%s' "$COLLECT_CONTEXT" | fr_compute_failure_signature)
GH_ISSUE_LIST_RESPONSE='[{"number":81}]'
fr_save_state issue 81 1 "in-progress" "$SIG_NP" ""   # 直前と同一 signature（Issue 経路）
# ── cycle 1: dispatch → rc 3 → terminate（コメント 1 回）
process_failed_recovery >/dev/null 2>&1 || true
assert_eq "cycle1 → no-progress 終端コメント 1 件" "1" "$(comments_for issue 81)"
assert_eq "cycle1 → last_status=no-progress 永続化" "no-progress" "$(state_field issue 81 '.last_status')"
assert_eq "cycle1 → sn_notify(no-progress) 1 回" "1" "$(grep -c '^failed-recovery-no-progress|' "$SN_NOTIFY_LOG" || true)"
# ── cycle 2: fetch 段階で terminal 除外 → 再発火なし
process_failed_recovery >/dev/null 2>&1 || true
assert_eq "cycle2 → 終端コメント再投稿なし（1 件のまま）" "1" "$(comments_for issue 81)"
assert_eq "cycle2 → sn_notify 再発火なし（1 回のまま）" "1" "$(grep -c '^failed-recovery-no-progress|' "$SN_NOTIFY_LOG" || true)"
assert_eq "cycle2 → codex 起動なし" "0" "$INVOKE_CODEX_COUNT"

echo ""; echo "--- 5. terminate 冒頭ガード（fetch をすり抜けた場合の二重防御）---"
reset_state
fr_save_state issue 82 4 "max-attempts" "sig" ""
fr_terminate_max_attempts issue 82 4
assert_eq "terminal 済み → コメント抑止" "0" "$(comments_for issue 82)"
assert_eq "terminal 済み → rs_set_result 抑止" "0" "$(grep -c 'codex-failed' "$SET_RESULT_LOG" || true)"
assert_eq "terminal 済み → 抑止ログ" "1" "$(grep -c 'issue=#82 terminated reason=max-attempts suppressed=terminate-max-attempts' "$FR_LOG_FILE" || true)"
# no-progress 状態で max-attempts terminate が来ても抑止（terminal 同士は相互に冪等）
reset_state
fr_save_state issue 83 2 "no-progress" "sig" ""
fr_terminate_max_attempts issue 83 4
assert_eq "no-progress 済み → max-attempts terminate も抑止" "0" "$(comments_for issue 83)"

echo ""; echo "--- 6. state 破損・欠落 → fail-open（従来の再投稿に退行 / silent fail なし）---"
reset_state
printf 'corrupted {{{' > "$STATE_DIR/issue-84.json"
fr_terminate_max_attempts issue 84 4
assert_eq "破損 state → 終端コメントは投稿される（fail-open）" "1" "$(comments_for issue 84)"
assert_eq "破損 state → rs_set_result も発火（fail-open）" "1" "$(grep -c 'codex-failed' "$SET_RESULT_LOG" || true)"
assert_eq "破損 state → terminate 後に terminal 永続化で自己回復" "max-attempts" "$(state_field issue 84 '.last_status')"
# state 欠落（ファイル無し）でも fail-open で終端は実行される
reset_state
fr_terminate_max_attempts issue 85 4
assert_eq "state 欠落 → 終端コメントは投稿される（fail-open）" "1" "$(comments_for issue 85)"
assert_eq "state 欠落 → terminal 永続化される" "max-attempts" "$(state_field issue 85 '.last_status')"

echo ""; echo "--- 7. terminal 永続化が既存フィールドを壊さない（後方互換）---"
reset_state
fr_save_state issue 86 4 "in-progress" "sigKEEP" "headKEEP" 2
fr_terminate_max_attempts issue 86 4
assert_eq "max-attempts 永続化 → signature 継承" "sigKEEP" "$(state_field issue 86 '.last_failure_signature')"
assert_eq "max-attempts 永続化 → head_sha 継承" "headKEEP" "$(state_field issue 86 '.last_head_sha')"
assert_eq "max-attempts 永続化 → streak 継承" "2" "$(state_field issue 86 '.immediate_failure_streak')"
assert_eq "max-attempts 永続化 → total 保持" "4" "$(state_field issue 86 '.total_attempts')"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
