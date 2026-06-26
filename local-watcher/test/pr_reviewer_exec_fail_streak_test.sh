#!/usr/bin/env bash
#
# 用途: pr-reviewer.sh の exec-fail streak 抑止（idd-claude #403 移植）を検証する。
#       同一 sha の連続 exec 失敗を per-PR state に永続化し、上限到達で外部レビュー呼び出しを
#       抑止する状態機械（read / record(increment・sha 変化で reset) / reset / limit 判定）を
#       確認する。codex exec-failed の無限リトライによる rate-limit 持続を防ぐ核心。
#
# 配置先: local-watcher/test/pr_reviewer_exec_fail_streak_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/pr_reviewer_exec_fail_streak_test.sh

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
for fn in pr_exec_fail_state_path pr_read_exec_fail_streak pr_record_exec_fail pr_reset_exec_fail pr_exec_fail_limit_reached; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$MODULE_SH" "$fn")"
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done

PR_REVIEWER_EXEC_FAIL_LIMIT=3
STATE_DIR=""
idd_secure_mktemp() { mktemp -t "idd-pref-${1:-x}.XXXXXX"; }
pr_warn() { :; }
reset_state() { STATE_DIR="$(mktemp -d)"; PR_REVIEWER_EXEC_FAIL_STATE_DIR="$STATE_DIR"; }

PASS_COUNT=0; FAIL_COUNT=0
assert_eq() { local l="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l (exp=$e act=$a)"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }
rc_of() { local fn="$1"; shift; local r=0; "$fn" "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }

SHA_A="$(printf 'a%.0s' {1..40})"
SHA_B="$(printf 'b%.0s' {1..40})"

echo "--- 1. read（不在 / 不一致 / 破損 → 0）---"
reset_state
assert_eq "state 不在 → 0" "0" "$(pr_read_exec_fail_streak 7 "$SHA_A")"
printf 'not json{{' > "$STATE_DIR/pr-7.json"
assert_eq "破損 → 0 (fail-open)" "0" "$(pr_read_exec_fail_streak 7 "$SHA_A")"

echo ""; echo "--- 2. record（increment / sha 変化で reset）---"
reset_state
assert_eq "1 回目 → 1" "1" "$(pr_record_exec_fail 7 "$SHA_A")"
assert_eq "同 sha 2 回目 → 2" "2" "$(pr_record_exec_fail 7 "$SHA_A")"
assert_eq "read で 2 を返す" "2" "$(pr_read_exec_fail_streak 7 "$SHA_A")"
assert_eq "別 sha では 0（不一致）" "0" "$(pr_read_exec_fail_streak 7 "$SHA_B")"
assert_eq "新 sha で record → 1 にリセット" "1" "$(pr_record_exec_fail 7 "$SHA_B")"
assert_eq "旧 sha streak は上書きで消える(別 PR は独立)" "0" "$(pr_read_exec_fail_streak 7 "$SHA_A")"

echo ""; echo "--- 3. limit 判定（既定 3）---"
reset_state
pr_record_exec_fail 8 "$SHA_A" >/dev/null   # 1
assert_eq "streak 1 < 3 → 未達(1)" "1" "$(rc_of pr_exec_fail_limit_reached 8 "$SHA_A")"
pr_record_exec_fail 8 "$SHA_A" >/dev/null   # 2
pr_record_exec_fail 8 "$SHA_A" >/dev/null   # 3
assert_eq "streak 3 = limit → 到達(0)" "0" "$(rc_of pr_exec_fail_limit_reached 8 "$SHA_A")"
# 新 sha では到達していない（push で自動再開）
assert_eq "新 sha は未達(1)＝push で再開" "1" "$(rc_of pr_exec_fail_limit_reached 8 "$SHA_B")"

echo ""; echo "--- 4. reset（成功時に消去）---"
reset_state
pr_record_exec_fail 9 "$SHA_A" >/dev/null; pr_record_exec_fail 9 "$SHA_A" >/dev/null
assert_eq "reset 前 streak 2" "2" "$(pr_read_exec_fail_streak 9 "$SHA_A")"
pr_reset_exec_fail 9
assert_eq "reset 後 → 0" "0" "$(pr_read_exec_fail_streak 9 "$SHA_A")"
assert_eq "reset 後は未達(1)" "1" "$(rc_of pr_exec_fail_limit_reached 9 "$SHA_A")"

echo ""; echo "--- 5. PR 独立性 ---"
reset_state
pr_record_exec_fail 10 "$SHA_A" >/dev/null; pr_record_exec_fail 10 "$SHA_A" >/dev/null; pr_record_exec_fail 10 "$SHA_A" >/dev/null
assert_eq "PR#10 は到達(0)" "0" "$(rc_of pr_exec_fail_limit_reached 10 "$SHA_A")"
assert_eq "PR#11 は同 sha でも独立で未達(1)" "1" "$(rc_of pr_exec_fail_limit_reached 11 "$SHA_A")"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
