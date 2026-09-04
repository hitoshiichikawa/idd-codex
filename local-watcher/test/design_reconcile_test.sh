#!/usr/bin/env bash
#
# 用途: design-reconcile.sh（Issue #180）を stub で検証する。
#   - gate（DESIGN_NOOP_RECONCILE_ENABLED=false 厳密一致のみ無効）
#   - dnr_has_label（完全一致）/ dnr_find_open_design_pr（strict prefix / 最大番号）
#   - dnr_find_design_pr_with_retry（merged 優先 / open / none / error / eventual consistency の bounded retry）
#   - dnr_reconcile_after_design の分岐:
#       awaiting 済み → no-op / claim 無し → no-op / merged → claim 除去 + コメント /
#       open → awaiting 補完 / none → _slot_mark_failed(design-no-pr) rc=1 / API 失敗 → fail-open
#   - dnr_refresh_base_ref（git fetch origin $BASE_BRANCH / 失敗 fail-open / gate off）
#
# 配置先: local-watcher/test/design_reconcile_test.sh
# 依存:   bash 4+, jq, mktemp
# 実行:   bash local-watcher/test/design_reconcile_test.sh

# 環境変数は source したモジュール関数が参照するため、静的解析の未使用警告（SC2034）を抑止する。
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/design-reconcile.sh"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
[ -f "$MODULE_SH" ] || { echo "ERROR: not found: $MODULE_SH" >&2; exit 2; }
[ -f "$WATCHER_SH" ] || { echo "ERROR: not found: $WATCHER_SH" >&2; exit 2; }

# 本モジュールは関数定義のみで副作用が無いため source で読む。
# shellcheck disable=SC1090
. "$MODULE_SH"
for fn in dnr_is_enabled dnr_issue_label_names dnr_has_label dnr_find_open_design_pr dnr_find_design_pr_with_retry dnr_refresh_base_ref dnr_reconcile_after_design; do
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done

# ─── 共有グローバル ───
REPO="owner/repo"; REPO_DIR="/tmp/fake-repo-dir"; BASE_BRANCH="develop"
LABEL_CLAIMED="codex-claimed"; LABEL_PICKED="codex-picked-up"; LABEL_AWAITING_DESIGN="codex-awaiting-design-review"
LABEL_FAILED="codex-failed"
DRR_GH_TIMEOUT=5
DNR_PR_LOOKUP_RETRY_SLEEP=0
NUMBER=117; IDD_SLOT_NUMBER=1; LOG=""
export REPO REPO_DIR BASE_BRANCH LABEL_CLAIMED LABEL_PICKED LABEL_AWAITING_DESIGN LABEL_FAILED NUMBER IDD_SLOT_NUMBER LOG

# ─── stub ───
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CALL_LOG="$TMP/calls.log"; LOG_CAP="$TMP/log.cap"; MARK_LOG="$TMP/mark.log"
GH_LABELS_RESPONSE='{"labels":[]}'; GH_LABELS_RC=0
GH_PR_LIST_RESPONSE='[]'; GH_PR_LIST_RC=0
GH_EDIT_RC=0; GH_COMMENT_RC=0
MERGED_PR=""; MERGED_RC=0
GIT_RC=0
# attempt 依存挙動（eventual consistency 再現）: 行ごとに「merged_out|merged_rc|prlist_json|prlist_rc」
SEQ_FILE="$TMP/seq"; : >"$SEQ_FILE"

timeout() { shift; "$@"; }
sleep() { printf 'sleep %s\n' "$*" >>"$CALL_LOG"; }
gh() {
  printf 'gh %s\n' "$*" >>"$CALL_LOG"
  case "$1 $2" in
    "issue view") printf '%s' "$GH_LABELS_RESPONSE"; return "$GH_LABELS_RC" ;;
    "pr list")
      if [ -s "$SEQ_FILE" ]; then
        local line; line=$(head -1 "$SEQ_FILE")
        local prj prrc; prj=$(printf '%s' "$line" | cut -d'|' -f3); prrc=$(printf '%s' "$line" | cut -d'|' -f4)
        printf '%s' "$prj"; return "${prrc:-0}"
      fi
      printf '%s' "$GH_PR_LIST_RESPONSE"; return "$GH_PR_LIST_RC" ;;
    "issue edit") return "$GH_EDIT_RC" ;;
    "issue comment") return "$GH_COMMENT_RC" ;;
  esac
  return 0
}
drr_find_merged_design_pr() {
  printf 'drr_find_merged_design_pr %s\n' "$*" >>"$CALL_LOG"
  if [ -s "$SEQ_FILE" ]; then
    local line; line=$(head -1 "$SEQ_FILE"); sed -i '1d' "$SEQ_FILE"
    local m mrc; m=$(printf '%s' "$line" | cut -d'|' -f1); mrc=$(printf '%s' "$line" | cut -d'|' -f2)
    printf '%s' "$m"; return "${mrc:-0}"
  fi
  printf '%s' "$MERGED_PR"; return "$MERGED_RC"
}
_slot_mark_failed() { printf '%s|%s\n' "$1" "$2" >>"$MARK_LOG"; }
git() { printf 'git %s\n' "$*" >>"$CALL_LOG"; return "$GIT_RC"; }
dnr_log()  { printf 'LOG %s\n' "$*" >>"$LOG_CAP"; }
dnr_warn() { printf 'WARN %s\n' "$*" >>"$LOG_CAP"; }
dnr_error(){ printf 'ERROR %s\n' "$*" >>"$LOG_CAP"; }

reset_state() {
  : >"$CALL_LOG"; : >"$LOG_CAP"; : >"$MARK_LOG"; : >"$SEQ_FILE"
  GH_LABELS_RESPONSE='{"labels":[]}'; GH_LABELS_RC=0
  GH_PR_LIST_RESPONSE='[]'; GH_PR_LIST_RC=0
  GH_EDIT_RC=0; GH_COMMENT_RC=0
  MERGED_PR=""; MERGED_RC=0; GIT_RC=0
  unset DESIGN_NOOP_RECONCILE_ENABLED
}
labels_json() { local out='[' first=1 l; for l in "$@"; do [ $first = 1 ] || out="$out,"; out="$out{\"name\":\"$l\"}"; first=0; done; printf '{"labels":%s]}' "$out"; }
calls() { grep -c -- "$1" "$CALL_LOG" 2>/dev/null || true; }
call_line() { grep -- "$1" "$CALL_LOG" | head -1; }

PASS_COUNT=0; FAIL_COUNT=0
assert_eq() { local l="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l"; echo "  exp=$(printf '%q' "$e") act=$(printf '%q' "$a")"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }
assert_contains() { local l="$1" h="$2" n="$3"; case "$h" in *"$n"*) echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1));; *) echo "FAIL: $l ('$n' 不在: $(printf '%q' "$h" | cut -c1-300))"; FAIL_COUNT=$((FAIL_COUNT+1));; esac; }
assert_not_contains() { local l="$1" h="$2" n="$3"; case "$h" in *"$n"*) echo "FAIL: $l ('$n' が存在)"; FAIL_COUNT=$((FAIL_COUNT+1));; *) echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1));; esac; }
rc_of() { local fn="$1"; shift; local r=0; "$fn" "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }

# ════════════════════════════════════════════════════════════════════════════
echo "--- 1. dnr_is_enabled（=false 厳密一致のみ無効 / 既定 有効）---"
unset DESIGN_NOOP_RECONCILE_ENABLED; assert_eq "未設定 → 有効(0)" "0" "$(rc_of dnr_is_enabled)"
DESIGN_NOOP_RECONCILE_ENABLED=true;  assert_eq "true → 有効(0)" "0" "$(rc_of dnr_is_enabled)"
DESIGN_NOOP_RECONCILE_ENABLED=false; assert_eq "false → 無効(1)" "1" "$(rc_of dnr_is_enabled)"
DESIGN_NOOP_RECONCILE_ENABLED=FALSE; assert_eq "FALSE → 有効(0)（厳密一致外）" "0" "$(rc_of dnr_is_enabled)"
DESIGN_NOOP_RECONCILE_ENABLED=0;     assert_eq "0 → 有効(0)" "0" "$(rc_of dnr_is_enabled)"
unset DESIGN_NOOP_RECONCILE_ENABLED

echo ""; echo "--- 2. dnr_has_label（完全一致）---"
NAMES=$'codex-auto-dev\ncodex-claimed'
assert_eq "含む → 0" "0" "$(rc_of dnr_has_label "$NAMES" codex-claimed)"
assert_eq "部分一致は不可 → 1" "1" "$(rc_of dnr_has_label "$NAMES" codex-claim)"
assert_eq "含まない → 1" "1" "$(rc_of dnr_has_label "$NAMES" codex-picked-up)"
assert_eq "空一覧 → 1" "1" "$(rc_of dnr_has_label "" codex-claimed)"

echo ""; echo "--- 3. dnr_issue_label_names ---"
reset_state
GH_LABELS_RESPONSE=$(labels_json codex-auto-dev codex-claimed)
assert_eq "ラベル名を 1 行 1 件で返す" $'codex-auto-dev\ncodex-claimed' "$(dnr_issue_label_names 117)"
GH_LABELS_RC=1
assert_eq "API 失敗 → rc 1" "1" "$(rc_of dnr_issue_label_names 117)"

echo ""; echo "--- 4. dnr_find_open_design_pr（strict prefix / 最大番号）---"
reset_state
GH_PR_LIST_RESPONSE='[{"number":118,"headRefName":"codex/issue-117-design-foo"},{"number":200,"headRefName":"codex/issue-1170-design-bar"},{"number":119,"headRefName":"codex/issue-117-impl-foo"}]'
assert_eq "issue 117 の design PR のみ（1170 / impl は除外）" "118" "$(dnr_find_open_design_pr 117)"
assert_eq "issue 1170 → 200" "200" "$(dnr_find_open_design_pr 1170)"
assert_eq "該当なし → 空" "" "$(dnr_find_open_design_pr 5)"
GH_PR_LIST_RESPONSE='[{"number":118,"headRefName":"codex/issue-117-design-foo"},{"number":130,"headRefName":"codex/issue-117-design-foo-v2"}]'
assert_eq "複数一致は最大番号" "130" "$(dnr_find_open_design_pr 117)"
GH_PR_LIST_RC=1
assert_eq "API 失敗 → rc 1" "1" "$(rc_of dnr_find_open_design_pr 117)"
assert_contains "gh pr list は --state open で呼ばれる" "$(call_line 'gh pr list')" "--state open"

echo ""; echo "--- 5. dnr_find_design_pr_with_retry ---"
reset_state; MERGED_PR=118
assert_eq "merged あり → 'merged 118'（open は照会しない）" "merged 118" "$(dnr_find_design_pr_with_retry 117)"
assert_eq "merged 検出時は pr list 未呼出" "0" "$(calls 'gh pr list')"
reset_state; GH_PR_LIST_RESPONSE='[{"number":121,"headRefName":"codex/issue-117-design-x"}]'
assert_eq "merged 無し + open あり → 'open 121'" "open 121" "$(dnr_find_design_pr_with_retry 117)"
reset_state
assert_eq "どちらも無し → 'none'（bounded retry 後）" "none" "$(dnr_find_design_pr_with_retry 117)"
assert_eq "none 確定まで merged 照会は 2 回" "2" "$(calls 'drr_find_merged_design_pr')"
assert_eq "none 確定まで sleep は 1 回" "1" "$(calls 'sleep')"
reset_state; MERGED_RC=1; GH_PR_LIST_RC=1
assert_eq "両 API 失敗 → 'error'（retry せず即返）" "error" "$(dnr_find_design_pr_with_retry 117)"
assert_eq "error は 1 回で打ち切り" "1" "$(calls 'drr_find_merged_design_pr')"
reset_state
# eventual consistency: 1 回目 none、2 回目 open
printf '%s\n' '|0|[]|0' '|0|[{"number":122,"headRefName":"codex/issue-117-design-late"}]|0' >"$SEQ_FILE"
assert_eq "1 回目 none → 2 回目 open を拾う" "open 122" "$(dnr_find_design_pr_with_retry 117)"
reset_state
printf '%s\n' '|0|[]|0' '118|0|[]|0' >"$SEQ_FILE"
assert_eq "1 回目 none → 2 回目 merged を拾う" "merged 118" "$(dnr_find_design_pr_with_retry 117)"

echo ""; echo "--- 6. dnr_reconcile_after_design: 正常遷移済み（awaiting あり）→ no-op ---"
reset_state
GH_LABELS_RESPONSE=$(labels_json codex-auto-dev codex-awaiting-design-review)
assert_eq "rc 0" "0" "$(rc_of dnr_reconcile_after_design 117)"
assert_eq "gh issue edit 未呼出" "0" "$(calls 'gh issue edit')"
assert_eq "PR 照会も未呼出" "0" "$(calls 'drr_find_merged_design_pr')"
assert_contains "ログ state=awaiting-design-review" "$(cat "$LOG_CAP")" "state=awaiting-design-review"

echo ""; echo "--- 7. claim 系ラベル無し → no-op ---"
reset_state
GH_LABELS_RESPONSE=$(labels_json codex-auto-dev)
assert_eq "rc 0" "0" "$(rc_of dnr_reconcile_after_design 117)"
assert_eq "gh issue edit 未呼出" "0" "$(calls 'gh issue edit')"

echo ""; echo "--- 8. design no-op（claimed 残留 + merged 設計 PR）→ claim 除去 + コメント ---"
reset_state
GH_LABELS_RESPONSE=$(labels_json codex-auto-dev codex-claimed); MERGED_PR=118
assert_eq "rc 0" "0" "$(rc_of dnr_reconcile_after_design 117)"
EDIT=$(call_line 'gh issue edit')
assert_contains "codex-claimed を除去" "$EDIT" "--remove-label codex-claimed"
assert_contains "codex-picked-up も除去（念のため）" "$EDIT" "--remove-label codex-picked-up"
assert_not_contains "awaiting は付与しない（merge 済みのため）" "$EDIT" "--add-label"
assert_eq "コメント 1 件" "1" "$(calls 'gh issue comment')"
assert_contains "コメント marker kind=merged" "$(cat "$CALL_LOG")" "idd-codex:design-reconcile issue=117 kind=merged pr=118"
assert_contains "ログ state=design-noop" "$(cat "$LOG_CAP")" "state=design-noop"
assert_eq "codex-failed へは遷移しない" "0" "$(grep -c . "$MARK_LOG" || true)"
assert_eq "git は呼ばない" "0" "$(calls 'git ')"

echo ""; echo "--- 9. picked-up のみ残留 + merged → 同様に除去 ---"
reset_state
GH_LABELS_RESPONSE=$(labels_json codex-auto-dev codex-picked-up); MERGED_PR=118
assert_eq "rc 0" "0" "$(rc_of dnr_reconcile_after_design 117)"
assert_eq "gh issue edit 1 回" "1" "$(calls 'gh issue edit')"

echo ""; echo "--- 10. ラベル遷移漏れ（claimed 残留 + open 設計 PR）→ awaiting 補完 ---"
reset_state
GH_LABELS_RESPONSE=$(labels_json codex-auto-dev codex-claimed)
GH_PR_LIST_RESPONSE='[{"number":121,"headRefName":"codex/issue-117-design-x"}]'
assert_eq "rc 0" "0" "$(rc_of dnr_reconcile_after_design 117)"
EDIT=$(call_line 'gh issue edit')
assert_contains "codex-claimed を除去" "$EDIT" "--remove-label codex-claimed"
assert_contains "awaiting-design-review を付与" "$EDIT" "--add-label codex-awaiting-design-review"
assert_contains "コメント marker kind=open" "$(cat "$CALL_LOG")" "idd-codex:design-reconcile issue=117 kind=open pr=121"
assert_eq "codex-failed へは遷移しない" "0" "$(grep -c . "$MARK_LOG" || true)"

echo ""; echo "--- 11. 設計 PR が open / merged いずれも無し → design-no-pr で codex-failed ---"
reset_state
GH_LABELS_RESPONSE=$(labels_json codex-auto-dev codex-claimed)
assert_eq "rc 1（呼び出し側は失敗として扱う）" "1" "$(rc_of dnr_reconcile_after_design 117)"
assert_contains "_slot_mark_failed が design-no-pr で呼ばれる" "$(cat "$MARK_LOG")" "design-no-pr|"
assert_contains "失敗コメントに Issue #180 の説明" "$(cat "$MARK_LOG")" "Issue #180"
assert_eq "ラベル編集は行わない（_slot_mark_failed に委ねる）" "0" "$(calls 'gh issue edit')"
assert_contains "WARN state=design-no-pr" "$(cat "$LOG_CAP")" "state=design-no-pr"

echo ""; echo "--- 12. fail-open: API 失敗系 ---"
reset_state
GH_LABELS_RC=1
assert_eq "ラベル取得失敗 → rc 0（skip）" "0" "$(rc_of dnr_reconcile_after_design 117)"
assert_eq "edit なし" "0" "$(calls 'gh issue edit')"
assert_contains "WARN ラベル取得に失敗" "$(cat "$LOG_CAP")" "ラベル取得に失敗"
reset_state
GH_LABELS_RESPONSE=$(labels_json codex-claimed); MERGED_RC=1; GH_PR_LIST_RC=1
assert_eq "PR 検出両 API 失敗 → rc 0（skip / reaper に委ねる）" "0" "$(rc_of dnr_reconcile_after_design 117)"
assert_eq "edit なし" "0" "$(calls 'gh issue edit')"
assert_eq "codex-failed へは遷移しない" "0" "$(grep -c . "$MARK_LOG" || true)"
reset_state
GH_LABELS_RESPONSE=$(labels_json codex-claimed); MERGED_PR=118; GH_EDIT_RC=1
assert_eq "merged だが edit API 失敗 → rc 0（WARN）" "0" "$(rc_of dnr_reconcile_after_design 117)"
assert_eq "コメントは投稿しない（ラベル未補正のため）" "0" "$(calls 'gh issue comment')"
reset_state
GH_LABELS_RESPONSE=$(labels_json codex-claimed); MERGED_PR=118; GH_COMMENT_RC=1
assert_eq "コメント API 失敗でも rc 0（ラベルは補正済み）" "0" "$(rc_of dnr_reconcile_after_design 117)"
assert_contains "WARN コメント投稿 API 失敗" "$(cat "$LOG_CAP")" "コメント投稿 API 失敗"

echo ""; echo "--- 13. gate off → 完全 no-op ---"
reset_state
DESIGN_NOOP_RECONCILE_ENABLED=false
GH_LABELS_RESPONSE=$(labels_json codex-claimed); MERGED_PR=118
assert_eq "reconcile rc 0" "0" "$(rc_of dnr_reconcile_after_design 117)"
assert_eq "gh 未呼出" "0" "$(calls 'gh ')"
assert_eq "refresh rc 0" "0" "$(rc_of dnr_refresh_base_ref 117 118)"
assert_eq "git 未呼出" "0" "$(calls 'git ')"
unset DESIGN_NOOP_RECONCILE_ENABLED

echo ""; echo "--- 14. dnr_refresh_base_ref ---"
reset_state
assert_eq "rc 0" "0" "$(rc_of dnr_refresh_base_ref 117 118)"
assert_eq "git fetch origin \$BASE_BRANCH を REPO_DIR で 1 回" "git -C /tmp/fake-repo-dir fetch origin develop" "$(call_line 'git ')"
assert_contains "ログに merged-design-pr" "$(cat "$LOG_CAP")" "merged-design-pr=#118"
reset_state; GIT_RC=1
assert_eq "fetch 失敗でも rc 0（fail-open）" "0" "$(rc_of dnr_refresh_base_ref 117 118)"
assert_contains "WARN 再 fetch に失敗" "$(cat "$LOG_CAP")" "再 fetch に失敗"
reset_state
( BASE_BRANCH=""; dnr_refresh_base_ref 117 118 )
assert_eq "BASE_BRANCH 空 → git 未呼出（skip）" "0" "$(calls 'git ')"
assert_contains "WARN skip" "$(cat "$LOG_CAP")" "refresh skip"

echo ""; echo "--- 15. 本体配線 ---"
assert_contains "REQUIRED_MODULES に design-reconcile.sh" "$(grep -E '^REQUIRED_MODULES=' "$WATCHER_SH")" '"design-reconcile.sh"'
assert_contains "design rc=0 分岐で dnr_reconcile_after_design を呼ぶ" "$(grep -c 'dnr_reconcile_after_design "\$NUMBER"' "$WATCHER_SH")" "1"
assert_contains "DRR ラベル除去成功後に dnr_refresh_base_ref を呼ぶ" "$(grep -c 'dnr_refresh_base_ref "\$issue_number" "\$merged_pr_number"' "$WATCHER_SH")" "1"
assert_contains "Config に DESIGN_NOOP_RECONCILE_ENABLED 既定 true" "$(grep -E '^DESIGN_NOOP_RECONCILE_ENABLED=' "$WATCHER_SH")" ':-true}'
assert_contains "design STEPS に no-op 例外の契約" "$(grep -c 'watcher が merge 済みを検出し、次回 impl-resume に進める' "$WATCHER_SH")" "1"

echo ""; echo "──────────────"
echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
echo "ALL GREEN"
