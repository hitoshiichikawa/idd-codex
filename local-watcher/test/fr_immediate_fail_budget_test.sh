#!/usr/bin/env bash
#
# 用途: failed-recovery.sh の #137（即時失敗の attempt budget 除外 + immediate_failure_streak
#       エスカレーション）を stub で検証する。
#       - 即時失敗（rc≠0 かつ elapsed < FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS）→ budget 不消費
#       - streak 到達（FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK）→ max-attempts と区別された
#         `immediate-failure-streak` 専用終端
#       - 通常失敗（elapsed >= 閾値）→ 従来どおり budget 消費 + streak リセット
#
# 配置先: local-watcher/test/fr_immediate_fail_budget_test.sh
# 依存:   bash 4+, awk, grep, jq, mktemp, sed, sha1sum
# 実行:   bash local-watcher/test/fr_immediate_fail_budget_test.sh
# 前提:   failed-recovery.sh から fr_* 関数を awk 抽出 → eval。codex 実行 / 外部副作用は
#         stub し、state 永続化は実 jq + 実一時ディレクトリで検証する（failed_recovery_test.sh
#         と同一パターン）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/failed-recovery.sh"
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
  fr_should_recover fr_state_path fr_load_state fr_save_state
  fr_compute_failure_signature fr_detect_no_progress
  fr_classify_immediate_failure fr_is_terminated
  fr_finalize_success fr_run_recovery_attempt
  fr_terminate_immediate_failure_streak _fr_dispatch_candidate
)
for fn in "${REAL_FNS[@]}"; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$MODULE_SH" "$fn")"
done
for fn in "${REAL_FNS[@]}"; do
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done

# ─── 共有グローバル（eval 抽出した実関数が参照する。SC2034 は false-positive）───
# shellcheck disable=SC2034
{
REPO="owner/repo"; REPO_SLUG="owner-repo"; BASE_BRANCH="main"; LOG="/dev/null"
LABEL_FAILED="codex-failed"
FAILED_RECOVERY_MAX_ATTEMPTS=4; FAILED_RECOVERY_GIT_TIMEOUT=5
FAILED_RECOVERY_DEV_MODEL="gpt-5.5"
FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS=10
FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK=3
FR_COMMENT_MARKER="idd-codex:failed-recovery"
}

# ─── trace 変数 / stub ───
GH_CALL_LOG=""; STATE_DIR=""; COMMENT_LOG=""; SET_RESULT_LOG=""; SN_NOTIFY_LOG=""
INVOKE_CODEX_RC=0; INVOKE_CODEX_COUNT=0; COLLECT_CONTEXT=""
FR_LOG_FILE=""

timeout() { shift; "$@"; }
git() { printf 'git %s\n' "$*" >>"$GH_CALL_LOG"; return 0; }
gh() { printf 'gh %s\n' "$*" >>"$GH_CALL_LOG"; return 0; }
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
fr_handle_quota() {
  # 実装同様: prev 値へ巻き戻して 99 を返す（streak は省略 = 継承）。
  fr_save_state "$1" "$2" "$5" "quota-wait" "${6:-}" "${7:-}" || true
  return 99
}

# shellcheck disable=SC2034  # eval 抽出した実関数が参照する
reset_state() {
  GH_CALL_LOG="$(mktemp)"; COMMENT_LOG="$(mktemp)"; SET_RESULT_LOG="$(mktemp)"
  SN_NOTIFY_LOG="$(mktemp)"; FR_LOG_FILE="$(mktemp)"
  STATE_DIR="$(mktemp -d)"; FAILED_RECOVERY_STATE_DIR="$STATE_DIR"
  INVOKE_CODEX_RC=0; INVOKE_CODEX_COUNT=0; COLLECT_CONTEXT=""
  FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS=10
  FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK=3
}
state_field() { fr_load_state "$1" "$2" | jq -r "$3"; }

PASS_COUNT=0; FAIL_COUNT=0
assert_eq() { local l="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l"; echo "  exp=$(printf '%q' "$e") act=$(printf '%q' "$a")"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }
rc_of() { local fn="$1"; shift; local r=0; "$fn" "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }
ATTEMPT_RC=0
run_attempt() { ATTEMPT_RC=0; fr_run_recovery_attempt "$@" >/dev/null 2>&1 || ATTEMPT_RC=$?; }

# ════════════════════════════════════════════════════════════════════════════
echo "--- 1. fr_classify_immediate_failure（純粋関数・境界値）---"
assert_eq "rc=0 → 通常(1)"                       "1" "$(rc_of fr_classify_immediate_failure 0 0 10)"
assert_eq "rc=1 elapsed=0 < 10 → 即時失敗(0)"     "0" "$(rc_of fr_classify_immediate_failure 1 0 10)"
assert_eq "rc=1 elapsed=9 < 10 → 即時失敗(0)"     "0" "$(rc_of fr_classify_immediate_failure 1 9 10)"
assert_eq "rc=1 elapsed=10 = 10 → 通常(1)"        "1" "$(rc_of fr_classify_immediate_failure 1 10 10)"
assert_eq "rc=1 elapsed=11 > 10 → 通常(1)"        "1" "$(rc_of fr_classify_immediate_failure 1 11 10)"
assert_eq "rc=70(git setup 失敗) 短時間 → 即時失敗(0)" "0" "$(rc_of fr_classify_immediate_failure 70 1 10)"
assert_eq "elapsed 非整数 → 0 扱い即時失敗(0)"     "0" "$(rc_of fr_classify_immediate_failure 1 abc 10)"
assert_eq "threshold 非整数 → 10 扱い(elapsed=9 → 0)" "0" "$(rc_of fr_classify_immediate_failure 1 9 xyz)"
assert_eq "threshold 非整数 → 10 扱い(elapsed=10 → 1)" "1" "$(rc_of fr_classify_immediate_failure 1 10 xyz)"
assert_eq "threshold=0 → elapsed=0 でも通常(1)（無効化）" "1" "$(rc_of fr_classify_immediate_failure 1 0 0)"

echo ""; echo "--- 2. 即時失敗 → budget 不消費（state 巻き戻し）+ streak 加算 ---"
reset_state; COLLECT_CONTEXT="auth error: token expired"; INVOKE_CODEX_RC=1
run_attempt issue 60 ""
assert_eq "即時失敗 → rc 1（次サイクル再試行）" "1" "$ATTEMPT_RC"
assert_eq "即時失敗 → codex は起動された" "1" "$INVOKE_CODEX_COUNT"
assert_eq "即時失敗 → budget 不消費 (total=0 に巻き戻し)" "0" "$(state_field issue 60 '.total_attempts')"
assert_eq "即時失敗 → immediate_failure_streak=1" "1" "$(state_field issue 60 '.immediate_failure_streak')"
assert_eq "即時失敗 → no-progress baseline 巻き戻し（sig 空）" "" "$(state_field issue 60 '.last_failure_signature')"
assert_eq "即時失敗 → 即時失敗コメント投稿（開始+結果=2 件）" "2" "$(grep -c '^issue|60|' "$COMMENT_LOG" || true)"
assert_eq "即時失敗 → codex-failed 除去しない" "0" "$(grep -c 'remove-label' "$GH_CALL_LOG" || true)"

# 2 回目の即時失敗 → streak=2 / budget は 0 のまま
run_attempt issue 60 ""
assert_eq "即時失敗 2 回目 → rc 1" "1" "$ATTEMPT_RC"
assert_eq "即時失敗 2 回目 → budget 不消費 (total=0)" "0" "$(state_field issue 60 '.total_attempts')"
assert_eq "即時失敗 2 回目 → streak=2" "2" "$(state_field issue 60 '.immediate_failure_streak')"

echo ""; echo "--- 3. streak 到達 → rc 4 → 専用終端（max-attempts と区別）---"
# 3 回目の即時失敗で streak=3 = 上限 → rc 4
run_attempt issue 60 ""
assert_eq "即時失敗 3 回目（上限到達）→ rc 4" "4" "$ATTEMPT_RC"
assert_eq "上限到達 → streak=3 永続化" "3" "$(state_field issue 60 '.immediate_failure_streak')"
assert_eq "上限到達 → budget は 0 のまま" "0" "$(state_field issue 60 '.total_attempts')"

# dispatch 経由で fr_terminate_immediate_failure_streak が呼ばれる
_fr_dispatch_candidate issue 60 "" >/dev/null 2>&1
assert_eq "dispatch(rc4) → rs_set_result(codex-failed) 1 回" "1" "$(grep -c 'codex-failed' "$SET_RESULT_LOG" || true)"
assert_eq "dispatch(rc4) → sn_notify(immediate-failure-streak) 1 回" "1" "$(grep -c '^failed-recovery-immediate-failure-streak|' "$SN_NOTIFY_LOG" || true)"
assert_eq "dispatch(rc4) → 終端コメントに immediate-failure-streak 識別子" "1" "$(grep -c 'immediate-failure-streak' "$COMMENT_LOG" || true)"
assert_eq "dispatch(rc4) → 終端コメントは max-attempts 識別子を含まない" "0" "$(grep -c '終端理由: max-attempts' "$COMMENT_LOG" || true)"
assert_eq "dispatch(rc4) → last_status=immediate-failure-streak 永続化" "immediate-failure-streak" "$(state_field issue 60 '.last_status')"
assert_eq "dispatch(rc4) → terminated reason ログ" "1" "$(grep -c 'terminated reason=immediate-failure-streak' "$FR_LOG_FILE" || true)"
assert_eq "dispatch(rc4) → codex-failed ラベル据え置き" "0" "$(grep -c 'remove-label' "$GH_CALL_LOG" || true)"

echo ""; echo "--- 4. streak 上限到達済み state → 事前チェックで codex 起動なし ---"
reset_state; COLLECT_CONTEXT="ctx"
fr_save_state issue 61 0 "in-progress" "" "" 3   # streak=3 = 上限
run_attempt issue 61 ""
assert_eq "事前チェック → rc 4" "4" "$ATTEMPT_RC"
assert_eq "事前チェック → codex 起動なし" "0" "$INVOKE_CODEX_COUNT"

echo ""; echo "--- 5. 通常失敗（閾値以上継続）→ 従来どおり budget 消費 + streak リセット ---"
reset_state; COLLECT_CONTEXT="lint error E501"; INVOKE_CODEX_RC=1
# shellcheck disable=SC2034  # eval 抽出した実関数が参照する
FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS=0   # 閾値 0 = elapsed 0 >= 0 → 通常扱い
fr_save_state issue 62 0 "in-progress" "" "" 2   # 直前まで streak=2 だったとする
run_attempt issue 62 ""
assert_eq "通常失敗 → rc 1" "1" "$ATTEMPT_RC"
assert_eq "通常失敗 → budget 1 消費 (total=1)" "1" "$(state_field issue 62 '.total_attempts')"
assert_eq "通常失敗 → streak を 0 にリセット" "0" "$(state_field issue 62 '.immediate_failure_streak')"

echo ""; echo "--- 6. 成功 → streak リセット + budget 消費（従来どおり）---"
reset_state; COLLECT_CONTEXT="build failed: missing import"; INVOKE_CODEX_RC=0
fr_save_state issue 63 0 "in-progress" "" "" 2
run_attempt issue 63 ""
assert_eq "成功 → rc 0" "0" "$ATTEMPT_RC"
assert_eq "成功 → budget 1 消費 (total=1)" "1" "$(state_field issue 63 '.total_attempts')"
assert_eq "成功 → streak を 0 にリセット" "0" "$(state_field issue 63 '.immediate_failure_streak')"
assert_eq "成功 → last_status=succeeded" "succeeded" "$(state_field issue 63 '.last_status')"

echo ""; echo "--- 7. 後方互換: streak キー欠落 state → 0 継承 ---"
reset_state
# #137 導入前の state（immediate_failure_streak キーなし）を直接書く
mkdir -p "$STATE_DIR"
printf '{"kind":"issue","number":64,"total_attempts":1,"last_status":"in-progress","last_failure_signature":"oldsig","last_head_sha":"","history":[]}\n' > "$STATE_DIR/issue-64.json"
assert_eq "旧 state 読み出し → streak キー欠落は jq // 0 で 0" "0" "$(state_field issue 64 '.immediate_failure_streak // 0')"
# 省略保存（既存呼出側互換）で streak が 0 として追加される
fr_save_state issue 64 2 "in-progress" "sig2" ""
assert_eq "省略保存 → streak=0 が付与される" "0" "$(state_field issue 64 '.immediate_failure_streak')"
# 明示保存 → 指定値
fr_save_state issue 64 2 "in-progress" "sig2" "" 5
assert_eq "明示保存 → streak=5" "5" "$(state_field issue 64 '.immediate_failure_streak')"
# 再び省略保存 → 5 を継承
fr_save_state issue 64 3 "in-progress" "sig3" ""
assert_eq "省略保存 → 直前の streak=5 を継承" "5" "$(state_field issue 64 '.immediate_failure_streak')"
# 不正値は 0 に正規化
fr_save_state issue 64 3 "in-progress" "sig3" "" "abc"
assert_eq "不正値 streak → 0 に正規化" "0" "$(state_field issue 64 '.immediate_failure_streak')"

echo ""; echo "--- 8. quota（rc=99）→ streak を変えない（budget 同様 不消費）---"
reset_state; COLLECT_CONTEXT="new failure ctx"; INVOKE_CODEX_RC=99
fr_save_state issue 65 1 "in-progress" "prevsig" "" 2
run_attempt issue 65 ""
assert_eq "quota → rc 99" "99" "$ATTEMPT_RC"
assert_eq "quota → budget 不消費 (total=1)" "1" "$(state_field issue 65 '.total_attempts')"
assert_eq "quota → streak 据え置き (2)" "2" "$(state_field issue 65 '.immediate_failure_streak')"

echo ""; echo "--- 9. fr_terminate_immediate_failure_streak（不正値・冪等）---"
reset_state
fr_terminate_immediate_failure_streak issue 66 3
assert_eq "終端 → コメント 1 件" "1" "$(grep -c '^issue|66|' "$COMMENT_LOG" || true)"
assert_eq "終端 → last_status 永続化" "immediate-failure-streak" "$(state_field issue 66 '.last_status')"
# 2 回目は冪等ガードで抑止（#140 と同型）
fr_terminate_immediate_failure_streak issue 66 3
assert_eq "終端 2 回目 → コメント再投稿なし（1 件のまま）" "1" "$(grep -c '^issue|66|' "$COMMENT_LOG" || true)"
assert_eq "終端 2 回目 → rs_set_result 追加なし（1 回のまま）" "1" "$(grep -c 'codex-failed' "$SET_RESULT_LOG" || true)"
# streak 非整数 → 0 扱いで終端は継続する（silent fail しない）
reset_state
fr_terminate_immediate_failure_streak issue 67 "notanumber"
assert_eq "streak 非整数 → 0 扱いでコメント投稿" "1" "$(grep -c '^issue|67|' "$COMMENT_LOG" || true)"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
