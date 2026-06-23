#!/usr/bin/env bash
#
# 用途: stage-a-verify.sh の _sav_exec_with_timeout（Issue F5 / #377 port）を検証する。
#       正常終了 / 非ゼロ終了 / timeout（rc=124）の戻り値、および **timeout 経路で孤児
#       grandchild が process group SIGKILL で確実に回収される**（flock 占有デッドロック
#       の根本原因の解消）ことを確認する。
#
# 配置先: local-watcher/test/sav_timeout_pgkill_test.sh
# 依存:   bash 4+, awk, setsid, timeout, mktemp, sleep
# 実行:   bash local-watcher/test/sav_timeout_pgkill_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/stage-a-verify.sh"
[ -f "$MODULE_SH" ] || { echo "ERROR: not found: $MODULE_SH" >&2; exit 2; }

# setsid が無い環境（一部 macOS 等）では本テストを skip（CI=Linux で担保）。
if ! command -v setsid >/dev/null 2>&1; then
  echo "SKIP: setsid not available (test requires Linux setsid)"
  exit 0
fi

extract_function() {
  local script="$1" fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "_sav_exec_with_timeout")"
declare -F _sav_exec_with_timeout >/dev/null || { echo "ERROR: _sav_exec_with_timeout not loaded" >&2; exit 2; }

sav_warn() { :; }

PASS_COUNT=0; FAIL_COUNT=0
assert_eq() { local l="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l"; echo "  exp=$(printf '%q' "$e") act=$(printf '%q' "$a")"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }
rc_of() { local r=0; "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }

echo "--- 1. 戻り値（正常 / 非ゼロ / timeout）---"
assert_eq "正常終了 → rc 0" "0" "$(rc_of _sav_exec_with_timeout 5 1 bash -c 'exit 0')"
assert_eq "非ゼロ終了 → rc 伝搬(3)" "3" "$(rc_of _sav_exec_with_timeout 5 1 bash -c 'exit 3')"
assert_eq "timeout → rc 124" "124" "$(rc_of _sav_exec_with_timeout 1 1 bash -c 'sleep 10')"

echo ""; echo "--- 2. 孤児 grandchild の process-group SIGKILL 回収（F5 の核心）---"
# verify cmd（bash -c）が grandchild（sleep して sentinel を書く）を background 起動した状態で
# 親が timeout する。setsid + pgid SIGKILL が無ければ grandchild は生き残り sentinel を書く。
# 修正後は pgid 全体 kill で grandchild が消え、sentinel は作られない。
SENTINEL="$(mktemp)"; rm -f "$SENTINEL"
# 親 bash は grandchild を background 起動して自身も sleep（timeout 対象）。
_sav_exec_with_timeout 1 1 bash -c "( sleep 3; echo alive > '$SENTINEL' ) & sleep 10" >/dev/null 2>&1 || true
# grandchild が生きていれば 3 秒後に sentinel を書く。回収済みなら書かれない。十分待つ。
sleep 4
if [ -e "$SENTINEL" ]; then
  echo "FAIL: grandchild が生き残り sentinel を書いた（pgid SIGKILL が効いていない）"
  FAIL_COUNT=$((FAIL_COUNT+1))
  rm -f "$SENTINEL"
else
  echo "PASS: 孤児 grandchild は process-group SIGKILL で回収された（sentinel 不在）"
  PASS_COUNT=$((PASS_COUNT+1))
fi

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
