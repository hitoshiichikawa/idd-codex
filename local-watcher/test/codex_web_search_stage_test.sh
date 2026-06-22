#!/usr/bin/env bash
#
# 用途: codex_wants_web_search（#17）の stage 判定とトグルを検証する。
#   - Debugger stage のみ --search 付与対象
#   - 他 stage は対象外
#   - CODEX_DEBUGGER_WEB_SEARCH=false で無効化（後方互換）
#
# 実行: bash local-watcher/test/codex_web_search_stage_test.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
[ -f "$WATCHER_SH" ] || { echo "ERROR: watcher not found" >&2; exit 2; }

extract_function() {
  awk -v fn="${2}() {" '$0==fn{i=1} i{print} i&&$0=="}"{i=0}' "$1"
}
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "codex_wants_web_search")"
declare -F codex_wants_web_search >/dev/null || { echo "ERROR: fn not loaded" >&2; exit 2; }

PASS=0; FAIL=0
assert_rc() { # label expected_rc stage [envassign]
  local label="$1" exp="$2" stage="$3"; local rc=0
  ( codex_wants_web_search "$stage" ) || rc=$?
  if [ "$rc" = "$exp" ]; then echo "PASS: $label"; PASS=$((PASS+1));
  else echo "FAIL: $label (expected rc=$exp got $rc)"; FAIL=$((FAIL+1)); fi
}

CODEX_DEBUGGER_WEB_SEARCH=true
assert_rc "Debugger-* → 付与(rc0)" 0 "Debugger-after-round1-1.1"
assert_rc "Debugger* → 付与(rc0)" 0 "Debugger"
assert_rc "StageA(Developer) → 非付与(rc1)" 1 "StageA"
assert_rc "Reviewer → 非付与(rc1)" 1 "Reviewer-r1-a1"
assert_rc "Triage → 非付与(rc1)" 1 "Triage"

# トグル off で Debugger でも非付与
CODEX_DEBUGGER_WEB_SEARCH=false
assert_rc "toggle=false で Debugger も非付与(rc1)" 1 "Debugger-after-round1-1.1"
CODEX_DEBUGGER_WEB_SEARCH=true

echo "──────────────"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1; echo "ALL GREEN"
