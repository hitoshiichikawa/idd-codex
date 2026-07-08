#!/usr/bin/env bash
#
# 用途: Issue #139（idd-claude #413 移植）で追加した
#       `pp_remove_ready_for_review_if_present`（idd-codex-modules/promote-pipeline.sh）が、
#       `codex-staged-for-release` 自動付与対象として確定した Issue 集合から
#       `codex-ready-for-review` ラベルを除去する経路を正しく動作させるかを検証する
#       近接テスト。
#
#       対象関数:
#         - pp_remove_ready_for_review_if_present（単独経路 / スキップ / 失敗 WARN）
#
#       検証観点:
#         - codex-ready-for-review 付与済み Issue から除去できる
#         - 既未付与 Issue は gh issue edit を再送せずスキップする
#         - 除去 API 失敗時は WARN ログを 1 行残し、戻り値 0 で fail-continue する
#         - 数値 ID 不正（フラグ注入防止）は gh issue view / edit を呼ばない
#         - 連続呼び出しで 1 件失敗しても後続 Issue の処理が継続する
#
#       既存テスト（issue6_gitflow_no_closing_keyword_test.sh / po_apply_awaiting_slot_test.sh）
#       と同じ extract_function イディオムを踏襲する。gh / pp_log / pp_warn / timeout を stub
#       して呼び出しトレース・ログ出力を観測する。
#
# 配置先: local-watcher/test/pp_remove_ready_for_review_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/pp_remove_ready_for_review_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMOTE_PIPELINE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/promote-pipeline.sh"

if [ ! -f "$PROMOTE_PIPELINE_SH" ]; then
  echo "ERROR: cannot find promote-pipeline.sh at $PROMOTE_PIPELINE_SH" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for this test" >&2
  exit 2
fi

# 対象関数とその依存ヘルパーを 1 関数ずつ隔離抽出して読み込む
# （issue6_gitflow_no_closing_keyword_test.sh とは異なり、こちらは fakebin ではなく
# 関数 stub を使う軽量な extract_function イディオムを採用する）。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 対象関数 + 依存ヘルパー（pp_issue_has_label）を実物で読み込む。
# pp_issue_has_label は gh / jq に依存するが、本テストでは gh を stub する。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PROMOTE_PIPELINE_SH" "pp_remove_ready_for_review_if_present")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PROMOTE_PIPELINE_SH" "pp_issue_has_label")"

if ! declare -F pp_remove_ready_for_review_if_present >/dev/null; then
  echo "ERROR: pp_remove_ready_for_review_if_present not loaded" >&2
  exit 2
fi
if ! declare -F pp_issue_has_label >/dev/null; then
  echo "ERROR: pp_issue_has_label not loaded" >&2
  exit 2
fi

# グローバル env（遅延束縛で extract_function 経由の関数本体から参照される）
# shellcheck disable=SC2034  # 遅延束縛で関数本体が参照
REPO="owner/test-repo"
# shellcheck disable=SC2034  # 同上（pp_remove_ready_for_review_if_present が $LABEL_READY を参照）
LABEL_READY="codex-ready-for-review"
# shellcheck disable=SC2034  # 同上（pp_issue_has_label / pp_remove... が timeout に渡す）
PROMOTE_GIT_TIMEOUT=60

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected: $(printf '%q' "$expected")"
    echo "  actual  : $(printf '%q' "$actual")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "PASS: $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
    *)
      echo "FAIL: $label"
      echo "  expected to contain: $(printf '%q' "$needle")"
      echo "  actual             : $(printf '%q' "$haystack")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
  esac
}

# ─── stub 状態 ───
# gh の振る舞いをケースごとに連想配列で制御:
#   LABELS_FOR_ISSUE   : Issue 番号 → ラベル CSV（"codex-ready-for-review,codex-staged-for-release" 等）
#   EDIT_RC_FOR_ISSUE  : Issue 番号 → `gh issue edit` 終了コード（未定義は 0 = 成功）
# 記録ファイル:
#   $GH_CALL_LOG  : gh の各呼び出しを 1 行ずつ記録
#   $WARN_LOG     : pp_warn の出力を記録
#   $LOG_LOG      : pp_log の出力を記録

reset_stub_state() {
  GH_CALL_LOG="$(mktemp)"
  WARN_LOG="$(mktemp)"
  LOG_LOG="$(mktemp)"
  declare -gA LABELS_FOR_ISSUE=()
  declare -gA EDIT_RC_FOR_ISSUE=()
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$WARN_LOG" "$LOG_LOG"
  unset LABELS_FOR_ISSUE
  unset EDIT_RC_FOR_ISSUE
}

set_labels_for() {
  local issue="$1"
  local labels_csv="$2"
  LABELS_FOR_ISSUE["$issue"]="$labels_csv"
}

set_edit_rc_for() {
  local issue="$1"
  local rc="$2"
  EDIT_RC_FOR_ISSUE["$issue"]="$rc"
}

# pp_log / pp_warn stub: 出力を記録ファイルへ
# stub は extract_function で読み込んだ対象関数から間接的に呼ばれるため SC2317 を抑止。
# shellcheck disable=SC2317
pp_log()  { echo "$*" >>"$LOG_LOG"; }
# shellcheck disable=SC2317
pp_warn() { echo "$*" >>"$WARN_LOG"; }

# timeout stub: 単にコマンドを実行（PROMOTE_GIT_TIMEOUT の挙動は本テストでは無関係）。
# shellcheck disable=SC2317
timeout() {
  shift # 先頭の秒数引数を捨てる
  "$@"
}

# gh stub: サブコマンドを判定して記録 + 制御された出力 / 終了コード
# shellcheck disable=SC2317
gh() {
  local sub="${1:-}"
  local sub2="${2:-}"
  local issue_arg=""
  if [ "$sub" = "issue" ] && { [ "$sub2" = "view" ] || [ "$sub2" = "edit" ]; }; then
    issue_arg="${3:-}"
  fi
  case "$sub" in
    issue)
      case "$sub2" in
        view)
          echo "gh $*" >>"$GH_CALL_LOG"
          local labels="${LABELS_FOR_ISSUE[$issue_arg]:-}"
          local json
          if [ -z "$labels" ]; then
            json='{"labels":[]}'
          else
            json=$(printf '%s' "$labels" | jq -R -s -c '
              split(",") | map({name: (. | gsub("^\\s+|\\s+$"; ""))}) | {labels: .}')
          fi
          printf '%s' "$json"
          return 0
          ;;
        edit)
          echo "gh $*" >>"$GH_CALL_LOG"
          local rc="${EDIT_RC_FOR_ISSUE[$issue_arg]:-0}"
          return "$rc"
          ;;
        *)
          echo "gh $* (unhandled)" >>"$GH_CALL_LOG"
          return 0
          ;;
      esac
      ;;
    *)
      echo "gh $* (unhandled)" >>"$GH_CALL_LOG"
      return 0
      ;;
  esac
}

count_calls() {
  local pattern="$1"
  local n
  n=$( { grep -E "$pattern" "$GH_CALL_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

echo "--- pp_remove_ready_for_review_if_present cases (Issue #139 / idd-claude #413 移植) ---"
echo ""

# ── Case 1: codex-ready-for-review 付与済み Issue から除去する ──
echo "--- Case 1: codex-ready-for-review 付与済みから除去 ---"
reset_stub_state
set_labels_for 42 "codex-ready-for-review,codex-staged-for-release"
pp_remove_ready_for_review_if_present 42
edit_count=$(count_calls "gh issue edit 42 .*--remove-label codex-ready-for-review")
assert_eq "Case 1: codex-ready-for-review 除去のため gh issue edit が 1 回呼ばれる" "1" "$edit_count"
log_out="$(cat "$LOG_LOG")"
assert_contains "Case 1: 除去成功ログを出す" \
  "$log_out" "issue=#42 action=label-remove label=codex-ready-for-review source=auto"
warn_out="$(cat "$WARN_LOG")"
assert_eq "Case 1: 成功時は WARN を出さない" "" "$warn_out"
cleanup_stub_state

# ── Case 2: ready-for-review 未付与 Issue は gh issue edit を呼ばずスキップ ──
echo ""
echo "--- Case 2: codex-ready-for-review 未付与 Issue は edit を呼ばずスキップ ---"
reset_stub_state
set_labels_for 50 "codex-staged-for-release"
pp_remove_ready_for_review_if_present 50
edit_count=$(count_calls "gh issue edit 50")
assert_eq "Case 2: 既未付与 Issue では gh issue edit を呼ばない" "0" "$edit_count"
log_out="$(cat "$LOG_LOG")"
assert_eq "Case 2: 既未付与のスキップでは INFO ログを出さない" "" "$log_out"
warn_out="$(cat "$WARN_LOG")"
assert_eq "Case 2: 既未付与のスキップでは WARN を出さない" "" "$warn_out"
cleanup_stub_state

# ── Case 2b: ラベル完全未付与（空）の Issue も no-op ──
echo ""
echo "--- Case 2b: ラベル完全に無い Issue も edit を呼ばずスキップ ---"
reset_stub_state
set_labels_for 51 ""
pp_remove_ready_for_review_if_present 51
edit_count=$(count_calls "gh issue edit 51")
assert_eq "Case 2b: ラベル無しの Issue では gh issue edit を呼ばない" "0" "$edit_count"
cleanup_stub_state

# ── Case 3: gh issue edit 失敗時の WARN ログ + 戻り値 0（fail-continue） ──
echo ""
echo "--- Case 3: gh issue edit 失敗で WARN ログ 1 行 + 戻り値 0 ---"
reset_stub_state
set_labels_for 77 "codex-ready-for-review"
set_edit_rc_for 77 1
rc=0
pp_remove_ready_for_review_if_present 77 || rc=$?
assert_eq "Case 3: edit 失敗でも戻り値は 0（fail-continue）" "0" "$rc"
warn_out="$(cat "$WARN_LOG")"
warn_count=$(printf '%s\n' "$warn_out" | grep -c "codex-ready-for-review 除去に失敗" || true)
assert_eq "Case 3: 除去失敗 WARN ログを 1 行残す" "1" "$warn_count"
assert_contains "Case 3: WARN ログに対象 Issue 番号 #77 を含む" "$warn_out" "#77"
assert_contains "Case 3: WARN ログに「後続 Issue は継続」を含む" \
  "$warn_out" "後続 Issue は継続"
log_out="$(cat "$LOG_LOG")"
log_count=$(printf '%s\n' "$log_out" | grep -c "action=label-remove" || true)
assert_eq "Case 3: 失敗時は除去成功ログを出さない" "0" "$log_count"
cleanup_stub_state

# ── Case 4: 数値 ID `^[0-9]+$` 不一致は edit を呼ばずスキップ（フラグ注入防止） ──
echo ""
echo "--- Case 4: 不正な Issue 番号は view / edit を呼ばずスキップ ---"
reset_stub_state
pp_remove_ready_for_review_if_present "-1"
view_count=$(count_calls "gh issue view")
edit_count=$(count_calls "gh issue edit")
assert_eq "Case 4: 数値 ID 不正（-1）なら gh issue view を呼ばない" "0" "$view_count"
assert_eq "Case 4: 数値 ID 不正（-1）なら gh issue edit を呼ばない" "0" "$edit_count"
reset_stub_state
pp_remove_ready_for_review_if_present ""
view_count=$(count_calls "gh issue view")
edit_count=$(count_calls "gh issue edit")
assert_eq "Case 4: 空 ID なら gh issue view を呼ばない" "0" "$view_count"
assert_eq "Case 4: 空 ID なら gh issue edit を呼ばない" "0" "$edit_count"
cleanup_stub_state

# ── Case 5: 連続呼び出しで 1 件失敗しても後続 Issue の処理が継続する（fail-continue） ──
echo ""
echo "--- Case 5: 連続呼び出しで 1 件失敗しても 2 件目が成功する ---"
reset_stub_state
set_labels_for 10 "codex-ready-for-review"
set_edit_rc_for 10 1
set_labels_for 20 "codex-ready-for-review,codex-staged-for-release"
set_edit_rc_for 20 0
pp_remove_ready_for_review_if_present 10
pp_remove_ready_for_review_if_present 20
warn_out="$(cat "$WARN_LOG")"
log_out="$(cat "$LOG_LOG")"
assert_contains "Case 5: #10 の失敗 WARN が記録される" "$warn_out" "#10"
assert_contains "Case 5: #20 の成功 LOG が記録される" "$log_out" "#20"
edit_count_10=$(count_calls "gh issue edit 10 .*--remove-label codex-ready-for-review")
edit_count_20=$(count_calls "gh issue edit 20 .*--remove-label codex-ready-for-review")
assert_eq "Case 5: #10 の edit が 1 回試行される" "1" "$edit_count_10"
assert_eq "Case 5: #20 の edit が 1 回試行される（先行失敗で停止しない）" "1" "$edit_count_20"
cleanup_stub_state

# ── Case 6: 同一 Issue を 2 回呼んでも 1 回目除去後の 2 回目はスキップ（冪等性） ──
echo ""
echo "--- Case 6: 同一 Issue を 2 回呼んでも edit 1 回 + skip 1 回（冪等性） ---"
reset_stub_state
set_labels_for 99 "codex-ready-for-review"
pp_remove_ready_for_review_if_present 99
# 1 回目の除去後、Issue 状態は「codex-ready-for-review 無し」に遷移したものとして再シミュレート
set_labels_for 99 ""
pp_remove_ready_for_review_if_present 99
edit_count=$(count_calls "gh issue edit 99 .*--remove-label codex-ready-for-review")
assert_eq "Case 6: 同一 Issue 2 回呼び出しでも除去 edit は 1 回のみ（冪等）" "1" "$edit_count"
log_out="$(cat "$LOG_LOG")"
log_count=$(printf '%s\n' "$log_out" | grep -c "action=label-remove" || true)
assert_eq "Case 6: 除去成功ログも 1 回のみ" "1" "$log_count"
cleanup_stub_state

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
