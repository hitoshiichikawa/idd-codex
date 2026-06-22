#!/usr/bin/env bash
#
# 用途: qa_detect_rate_limit_rollout（#79）を実 codex スキーマの fixture で検証する。
#   codex の rate_limit は stdout でなく session rollout の token_count.rate_limits に出るため、
#   thread_id 経由で rollout を特定し、reached のときだけ binding window の reset epoch を返す。
#
#   検証観点:
#     - 未到達（reached_type=null, used_percent<100） → 空出力（検出なし）
#     - 到達（reached_type 非 null / primary>=100） → primary.resets_at
#     - 到達（secondary>=100, weekly 窓 binding） → secondary.resets_at
#     - 最新 snapshot を採用（tail -1: 旧 reached → 新 not-reached なら空）
#     - thread.started 無し / rollout 不在 → 空（フォールバック）
#
# 実行: bash local-watcher/test/qa_rollout_rate_limit_test.sh
# 依存: bash 4+, jq, find

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/quota-aware.sh"
[ -f "$MODULE_SH" ] || { echo "ERROR: quota-aware.sh not found" >&2; exit 2; }

extract_function() {
  awk -v fn="${2}() {" '$0==fn{i=1} i{print} i&&$0=="}"{i=0}' "$1"
}
# shellcheck disable=SC1090
eval "$(extract_function "$MODULE_SH" "qa_detect_rate_limit_rollout")"
declare -F qa_detect_rate_limit_rollout >/dev/null || { echo "ERROR: fn not loaded" >&2; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CODEX_HOME="$TMP/.codex"
export CODEX_HOME
mkdir -p "$CODEX_HOME/sessions/2026/06/22"

PASS=0; FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1));
  else echo "FAIL: $1 (expected=$(printf %q "$2") actual=$(printf %q "$3"))"; FAIL=$((FAIL+1)); fi
}

# ヘルパ: thread_id の stdout(exec_out) と rollout を生成し、検出結果を返す
TID="019eed00-1111-2222-3333-444455556666"
make_exec_out() {
  local f="$TMP/exec_out.jsonl"
  {
    printf '%s\n' '{"type":"thread.started","thread_id":"'"$TID"'"}'
    printf '%s\n' '{"type":"turn.started"}'
    printf '%s\n' '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"OK"}}'
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'
  } > "$f"
  printf '%s' "$f"
}
write_rollout() { # $1 = jsonl lines (rate_limits events)
  printf '%s\n' "$1" > "$CODEX_HOME/sessions/2026/06/22/rollout-2026-06-22T00-00-00-${TID}.jsonl"
}
rl_event() { # $1=primary_pct $2=primary_reset $3=secondary_pct $4=secondary_reset $5=reached_type(null|"x")
  printf '%s' '{"timestamp":"2026-06-22T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":'"$1"',"window_minutes":300,"resets_at":'"$2"'},"secondary":{"used_percent":'"$3"',"window_minutes":10080,"resets_at":'"$4"'},"rate_limit_reached_type":'"$5"',"plan_type":"prolite","credits":null}}}'
}

EXEC_OUT=$(make_exec_out)

# 1. 未到達（実サンプル相当: primary 69%, secondary 92%, reached=null）→ 空
write_rollout "$(rl_event 69.0 1781262684 92.0 1781522184 null)"
assert_eq "未到達は検出なし（空）" "" "$(qa_detect_rate_limit_rollout "$EXEC_OUT")"

# 2. 到達: reached_type=primary, primary 100% → primary.resets_at
write_rollout "$(rl_event 100.0 1781262684 95.0 1781522184 '"primary"')"
assert_eq "到達(primary) → primary.resets_at" "1781262684" "$(qa_detect_rate_limit_rollout "$EXEC_OUT")"

# 3. 到達: secondary(weekly) 100% binding → secondary.resets_at
write_rollout "$(rl_event 40.0 111 100.0 222 '"secondary"')"
assert_eq "到達(secondary binding) → secondary.resets_at" "222" "$(qa_detect_rate_limit_rollout "$EXEC_OUT")"

# 4. reached_type 非 null だが percent<100 でも検出（reached_type 優先）
write_rollout "$(rl_event 80.0 333 70.0 444 '"primary"')"
assert_eq "reached_type 非 null は percent 不問で検出" "333" "$(qa_detect_rate_limit_rollout "$EXEC_OUT")"

# 5. 最新 snapshot 採用: 旧 reached → 新 not-reached なら空
write_rollout "$(printf '%s\n%s' "$(rl_event 100.0 111 50.0 222 '"primary"')" "$(rl_event 60.0 555 70.0 666 null)")"
assert_eq "最新が未到達なら空（tail -1）" "" "$(qa_detect_rate_limit_rollout "$EXEC_OUT")"

# 6. rollout 不在（thread_id mismatch）→ 空
rm -f "$CODEX_HOME/sessions/2026/06/22/rollout-2026-06-22T00-00-00-${TID}.jsonl"
assert_eq "rollout 不在は空（フォールバック）" "" "$(qa_detect_rate_limit_rollout "$EXEC_OUT")"

# 7. thread.started 無しの exec_out → 空
NO_TID="$TMP/no_tid.jsonl"
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1}}' > "$NO_TID"
assert_eq "thread.started 無しは空" "" "$(qa_detect_rate_limit_rollout "$NO_TID")"

echo "──────────────"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1; echo "ALL GREEN"
