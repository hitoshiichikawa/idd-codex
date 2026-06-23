#!/usr/bin/env bash
#
# 用途: _stage_checkpoint_has_resumable_state（idd-claude #383 移植）を検証する。
#       4 観点 OR（impl PR / origin impl ブランチ / impl-notes / review-notes）で
#       resumable state を観測し、実在 → 0 / 全不在確定 → 1 / 観測失敗 → 2（safe-side）を
#       返すこと、不正 issue 番号で 2 を返すことを stub で確認する。
#       これにより、fresh issue（umbrella spec 番号衝突）の slug-guard 誤発火
#       （needs-decisions 誤爆ループ）が防がれる。
#
# 配置先: local-watcher/test/stage_checkpoint_resumable_state_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/stage_checkpoint_resumable_state_test.sh

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

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "_stage_checkpoint_has_resumable_state")"
declare -F _stage_checkpoint_has_resumable_state >/dev/null || { echo "ERROR: fn not loaded" >&2; exit 2; }

# ─── 共有グローバル ───
NUMBER=5; REPO_DIR="/tmp/fake-wt"; LOG="/dev/null"

# ─── stub（観測手段を制御）───
FIND_PR_RC=1; LS_REMOTE_OUT=""; LS_REMOTE_RC=0; IMPL_TRACKED=0; REVIEW_TRACKED=0; LS_TREE_RC=0
timeout() { shift; "$@"; }
stage_checkpoint_find_impl_pr() { [ "${FIND_PR_RC}" = "0" ] && echo "42,OPEN"; return "${FIND_PR_RC}"; }
git() {
  case "$*" in
    *ls-remote*)
      [ -n "$LS_REMOTE_OUT" ] && printf '%s\n' "$LS_REMOTE_OUT"
      return "${LS_REMOTE_RC}" ;;
    *ls-tree*impl-notes.md*)
      [ "${LS_TREE_RC}" != "0" ] && return "${LS_TREE_RC}"
      [ "$IMPL_TRACKED" = "1" ] && echo "docs/specs/5-x/impl-notes.md"; return 0 ;;
    *ls-tree*review-notes.md*)
      [ "${LS_TREE_RC}" != "0" ] && return "${LS_TREE_RC}"
      [ "$REVIEW_TRACKED" = "1" ] && echo "docs/specs/5-x/review-notes.md"; return 0 ;;
  esac
  return 0
}

reset_obs() { FIND_PR_RC=1; LS_REMOTE_OUT=""; LS_REMOTE_RC=0; IMPL_TRACKED=0; REVIEW_TRACKED=0; LS_TREE_RC=0; NUMBER=5; }

PASS_COUNT=0; FAIL_COUNT=0
assert_eq() { local l="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l"; echo "  exp=$e act=$a"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }
rc_of() { local r=0; _stage_checkpoint_has_resumable_state "/tmp/fake-wt/docs/specs/5-x" >/dev/null 2>&1 || r=$?; echo "$r"; }

echo "--- 1. 各観点が実在 → resumable(0) ---"
reset_obs; FIND_PR_RC=0;       assert_eq "(a) impl PR あり → 0" "0" "$(rc_of)"
reset_obs; LS_REMOTE_OUT="abc123 refs/heads/codex/issue-5-impl-x"; assert_eq "(b) impl ブランチあり → 0" "0" "$(rc_of)"
reset_obs; IMPL_TRACKED=1;     assert_eq "(c) impl-notes tracked → 0" "0" "$(rc_of)"
reset_obs; REVIEW_TRACKED=1;   assert_eq "(d) review-notes tracked → 0" "0" "$(rc_of)"

echo ""; echo "--- 2. 全観点 確定的に不在 → fresh(1)（誤 block しない核心）---"
reset_obs; assert_eq "PR/branch/notes すべて不在 → 1（guard skip）" "1" "$(rc_of)"

echo ""; echo "--- 3. 観測失敗 → safe-side(2)（guard 発火側へ倒す）---"
reset_obs; FIND_PR_RC=2;       assert_eq "impl PR 取得 API エラー → 2" "2" "$(rc_of)"
reset_obs; LS_REMOTE_RC=1;     assert_eq "ls-remote 失敗 → 2" "2" "$(rc_of)"
reset_obs; LS_TREE_RC=128;     assert_eq "ls-tree 失敗 → 2" "2" "$(rc_of)"
reset_obs; NUMBER="abc";       assert_eq "不正 issue 番号 → 2" "2" "$(rc_of)"

echo ""; echo "--- 4. 優先順位: 実在観点が 1 つでもあれば失敗観点より優先で 0 ---"
reset_obs; FIND_PR_RC=0; LS_REMOTE_RC=1; assert_eq "impl PR あり + ls-remote 失敗 → 0（実在優先）" "0" "$(rc_of)"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
