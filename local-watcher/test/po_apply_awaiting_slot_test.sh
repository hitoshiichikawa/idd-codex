#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-modules/promote-pipeline.sh の Issue #187（codex-awaiting-slot
#       付与失敗時も見送り理由コメントを投稿する）で組み替えた
#       po_apply_awaiting_slot を fixture で検証するスモークテスト。
#
#       対象関数: po_apply_awaiting_slot（Phase E Path Overlap Checker / #18, #187）
#
#       検証する AC（docs/specs/187-bug-watcher-codex-awaiting-slot-phase-e-185-3/requirements.md）:
#         - Req 1.1 / 1.2: ラベル付与の成否に依存せず sticky comment 投稿/更新を試行する
#         - Req 1.4 / NFR 2.1: 既存 marker 付きコメントがあれば追加投稿せず PATCH で更新する
#         - Req 3.1: ラベル付与失敗時は候補 Issue 番号を含む警告ログを出力する
#         - Req 2.4 / NFR 1.1: 関数の戻り値は 0（呼び出し側の dispatch skip 維持に影響しない）
#
#       既存テスト（pi_max_rounds_kind_test.sh 等）と同じ per-test の *_SH source +
#       awk extract_function イディオムを踏襲する。gh / po_log / po_warn を stub して
#       呼び出し有無・呼び出し引数を記録する方式で挙動を観測する。
#
# 配置先: local-watcher/test/po_apply_awaiting_slot_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/po_apply_awaiting_slot_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMOTE_PIPELINE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/promote-pipeline.sh"

if [ ! -f "$PROMOTE_PIPELINE_SH" ]; then
  echo "ERROR: cannot find promote-pipeline.sh at $PROMOTE_PIPELINE_SH" >&2
  exit 2
fi

# 既存テストと同じイディオム: 対象スクリプトから 1 関数だけを awk で切り出して
# eval で読み込む。トップレベル副作用は回避する。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 対象関数 + 本文整形ヘルパー（po_format_holders_table_md）を実物で読み込む。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PROMOTE_PIPELINE_SH" "po_apply_awaiting_slot")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PROMOTE_PIPELINE_SH" "po_format_holders_table_md")"

if ! declare -F po_apply_awaiting_slot >/dev/null; then
  echo "ERROR: po_apply_awaiting_slot not loaded" >&2
  exit 2
fi
if ! declare -F po_format_holders_table_md >/dev/null; then
  echo "ERROR: po_format_holders_table_md not loaded" >&2
  exit 2
fi

# グローバル env（遅延束縛で extract_function 経由の関数本体から参照される）
# shellcheck disable=SC2034  # 抽出した po_apply_awaiting_slot 本体が遅延束縛で参照
REPO="owner/test-repo"
# shellcheck disable=SC2034  # 同上（po_apply_awaiting_slot が $LABEL_AWAITING_SLOT を参照）
LABEL_AWAITING_SLOT="codex-awaiting-slot"

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

# ─── 各テストケースで使う stub の状態 ───
# gh の振る舞いはケースごとに環境変数で制御する:
#   GH_EDIT_RC               : `gh issue edit` の終了コード（0=成功 / 非0=失敗）
#   GH_VIEW_RC               : `gh issue view` の終了コード
#   GH_VIEW_COMMENTS_JSON    : `gh issue view --json comments` が返す JSON
# 記録ファイル（呼び出しトレース）:
#   $GH_CALL_LOG  : gh の各呼び出しを 1 行ずつ記録
#   $WARN_LOG     : po_warn の出力を記録
#   $LOG_LOG      : po_log の出力を記録

reset_stub_state() {
  GH_EDIT_RC="${1:-0}"
  GH_VIEW_RC="${2:-0}"
  GH_VIEW_COMMENTS_JSON="${3:-'{"comments": []}'}"
  GH_CALL_LOG="$(mktemp)"
  WARN_LOG="$(mktemp)"
  LOG_LOG="$(mktemp)"
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$WARN_LOG" "$LOG_LOG"
}

# po_log / po_warn stub: 出力を記録ファイルへ
# stub は extract_function で読み込んだ対象関数から間接的に呼ばれるため SC2317 を抑止する。
# shellcheck disable=SC2317
po_log()  { echo "$*" >>"$LOG_LOG"; }
# shellcheck disable=SC2317
po_warn() { echo "$*" >>"$WARN_LOG"; }

# gh stub: サブコマンドを判定して記録 + 制御された終了コードを返す
# shellcheck disable=SC2317  # 対象関数から間接的に呼ばれる stub
gh() {
  local sub="${1:-}"
  local sub2="${2:-}"
  case "$sub" in
    issue)
      case "$sub2" in
        edit)
          echo "gh issue edit $*" >>"$GH_CALL_LOG"
          return "${GH_EDIT_RC:-0}"
          ;;
        view)
          echo "gh issue view $*" >>"$GH_CALL_LOG"
          if [ "${GH_VIEW_RC:-0}" -ne 0 ]; then
            return "${GH_VIEW_RC}"
          fi
          printf '%s' "${GH_VIEW_COMMENTS_JSON}"
          return 0
          ;;
        comment)
          echo "gh issue comment $*" >>"$GH_CALL_LOG"
          return 0
          ;;
        *)
          echo "gh issue $* (unhandled)" >>"$GH_CALL_LOG"
          return 0
          ;;
      esac
      ;;
    api)
      echo "gh api $*" >>"$GH_CALL_LOG"
      return 0
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
  # grep -c は no-match 時に exit 1 を返し set -e / pipefail と衝突するため、
  # マッチ行を grep で取り出し（no-match でも true 化）wc -l で件数を数える。
  n=$( { grep "$pattern" "$GH_CALL_LOG" 2>/dev/null || true; } | wc -l)
  # wc -l は前後空白を含むことがあるため整数化
  echo "$((n))"
}

OVERLAP='["local-watcher/","README.md"]'
HOLDERS='{"local-watcher/":[39,40],"README.md":[40]}'

echo "--- po_apply_awaiting_slot cases (Issue #187 Req 1.1 / 1.2 / 1.4 / 3.1 / 2.4) ---"

# ── Case A: ラベル付与失敗でも sticky comment 投稿が試行される（Req 1.1 / 1.2） ──
# gh issue edit を失敗（rc=1）させ、既存 marker コメントは無い状態（新規 create 経路）
reset_stub_state 1 0 '{"comments": []}'
rc=0
po_apply_awaiting_slot 42 "$OVERLAP" "$HOLDERS" || rc=$?
assert_eq "Req 2.4: ラベル付与失敗でも関数戻り値は 0（呼び出し側 dispatch skip に影響しない）" \
  "0" "$rc"
edit_count=$(count_calls "gh issue edit")
comment_count=$(count_calls "gh issue comment")
assert_eq "Req 1.2: ラベル付与（gh issue edit）が 1 回試行される" "1" "$edit_count"
assert_eq "Req 1.1 / 1.2: ラベル付与失敗でも sticky comment 新規投稿が試行される" \
  "1" "$comment_count"
# Req 3.1: 警告ログに候補 Issue 番号 #42 を含む
warn_out="$(cat "$WARN_LOG")"
assert_contains "Req 3.1: ラベル付与失敗時に候補 Issue 番号を含む警告ログを出す" \
  "$warn_out" "#42"
cleanup_stub_state

# ── Case B: ラベル付与失敗 + 既存 marker コメント有り → 追加投稿せず PATCH 更新（Req 1.4 / NFR 2.1） ──
EXISTING_COMMENTS='{"comments":[{"body":"## ⏸️ Dispatch を見送り中\n\n<!-- idd-codex:codex-awaiting-slot:v1 -->","url":"https://github.com/owner/test-repo/issues/42#issuecomment-555111"}]}'
reset_stub_state 1 0 "$EXISTING_COMMENTS"
rc=0
po_apply_awaiting_slot 42 "$OVERLAP" "$HOLDERS" || rc=$?
assert_eq "Req 2.4: 既存 marker 有り + ラベル付与失敗でも戻り値 0" "0" "$rc"
patch_count=$(count_calls "gh api .*PATCH")
comment_count=$(count_calls "gh issue comment")
assert_eq "Req 1.4 / NFR 2.1: 既存 marker 有りなら新規 comment 投稿は 0 回" "0" "$comment_count"
assert_eq "Req 1.4 / NFR 2.1: 既存 marker 有りなら PATCH で 1 回更新する" "1" "$patch_count"
# PATCH 対象 comment id（555111）が解決されていること
patch_call="$(grep 'gh api' "$GH_CALL_LOG" || true)"
assert_contains "Req 1.4: PATCH 対象は既存 comment id (555111)" "$patch_call" "555111"
cleanup_stub_state

# ── Case C: ラベル付与成功時の従来挙動（新規 create）が回帰しない（NFR 2.1） ──
reset_stub_state 0 0 '{"comments": []}'
rc=0
po_apply_awaiting_slot 7 "$OVERLAP" "$HOLDERS" || rc=$?
assert_eq "NFR 2.1: ラベル付与成功時の戻り値 0" "0" "$rc"
edit_count=$(count_calls "gh issue edit")
comment_count=$(count_calls "gh issue comment")
assert_eq "NFR 2.1: ラベル付与成功時にラベル付与が 1 回" "1" "$edit_count"
assert_eq "NFR 2.1: ラベル付与成功 + 既存 marker 無し → 新規 comment 1 回" "1" "$comment_count"
# 成功時は WARN を出さず、付与成功 LOG を出す
warn_out="$(cat "$WARN_LOG")"
log_out="$(cat "$LOG_LOG")"
assert_eq "NFR 2.1: ラベル付与成功時は WARN を出さない" "" "$warn_out"
assert_contains "NFR 2.1: ラベル付与成功時に付与成功ログを出す" "$log_out" "codex-awaiting-slot added candidate=#7"
cleanup_stub_state

# ── Case D: ラベル付与成功 + 既存 marker 有り → 冪等更新（PATCH、追加投稿しない）（NFR 2.1 / Req 1.4） ──
reset_stub_state 0 0 "$EXISTING_COMMENTS"
rc=0
po_apply_awaiting_slot 42 "$OVERLAP" "$HOLDERS" || rc=$?
assert_eq "NFR 2.1: ラベル成功 + 既存 marker 有りでも戻り値 0" "0" "$rc"
patch_count=$(count_calls "gh api .*PATCH")
comment_count=$(count_calls "gh issue comment")
assert_eq "Req 1.4 / NFR 2.1: ラベル成功 + 既存 marker 有りなら新規 comment 0 回" "0" "$comment_count"
assert_eq "Req 1.4 / NFR 2.1: ラベル成功 + 既存 marker 有りなら PATCH 1 回" "1" "$patch_count"
cleanup_stub_state

# ── Case E: ラベル付与失敗 + コメント取得失敗 → best-effort で新規 create を試行、戻り値 0（Req 2.3 / 1.2） ──
reset_stub_state 1 1 ''
rc=0
po_apply_awaiting_slot 99 "$OVERLAP" "$HOLDERS" || rc=$?
assert_eq "Req 2.3: ラベル付与失敗 + コメント取得失敗でも戻り値 0（異常終了しない）" "0" "$rc"
comment_count=$(count_calls "gh issue comment")
assert_eq "Req 1.2: コメント取得失敗時も best-effort で新規 comment 投稿を試行" "1" "$comment_count"
warn_out="$(cat "$WARN_LOG")"
assert_contains "Req 3.1: ラベル付与失敗の警告に候補 Issue 番号 #99 を含む" "$warn_out" "#99"
cleanup_stub_state

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
