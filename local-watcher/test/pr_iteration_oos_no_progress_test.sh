#!/usr/bin/env bash
#
# 用途: PR Iteration out-of-scope 第 3 判定 (#146 / idd-claude #437 移植) の内容ベース
#       早期打ち切り側関数群（pi_detect_developer_oos_marker / pi_oos_fingerprint /
#       pi_read_oos_no_progress_streak / pi_read_oos_fingerprint /
#       pi_next_oos_no_progress_streak / pi_write_marker の oos 拡張）を検証するスモークテスト。
#
#       検証ケース:
#         Section A: pi_detect_developer_oos_marker（Developer 構造化マーカー検出）
#           (A.1) codex --json JSONL（item.completed / agent_message）の行頭マーカー → 検出
#           (A.2) spec-stale 語彙 / 前後空白許容 → 検出
#           (A.3) 行中言及（前置きに続く同一行）→ 非検出（偽装的な部分一致）
#           (A.4) 語彙外（OUT-OF-SCOPE: designer / foo）→ 非検出
#           (A.5) マーカーなし / ログ不在 / 空パス → 空（従来 round 進行）
#           (A.6) proto 形式（msg.type=agent_message / message フィールド）→ 検出
#           (A.7) plain text ログ fallback → 検出
#         Section B: pi_oos_fingerprint（内容ベース同一性キー）
#           (B.1) 同一内容・順序違い → 同一 fingerprint（順序非依存）
#           (B.2) 内容変化 → fingerprint 変化
#           (B.3) SHA 非依存（decisions に sha を含めても内容同一なら同一）
#           (B.4) 空入力 / out-of-scope なし → 安定ハッシュ（毎回同一）
#         Section C: marker の読み書き（oos フィールドの永続化と後方互換）
#           (C.1) 5 フィールド marker から oos streak / fingerprint を読める
#           (C.2) 既存 3 フィールド marker（oos キーなし）→ 0 / 空（後方互換）
#           (C.3) 空 body → 0 / 空
#           (C.4) pi_write_marker: gate ON + oos 引数 → 5 フィールド marker を書く
#           (C.5) pi_write_marker: gate OFF → oos 引数があっても従来 3 フィールド（byte 互換）
#           (C.6) pi_write_marker: gate ON + oos 引数なし → 従来 3 フィールド
#         Section D: pi_next_oos_no_progress_streak（純粋関数）
#           (D.1) fingerprint 同一 → prev+1
#           (D.2) fingerprint 変化 → 0 リセット
#           (D.3) prev / current が空 → 0（初回 / 取得失敗の安全側）
#           (D.4) prev_streak 非数値 → 1（防御的）
#
# 配置先: local-watcher/test/pr_iteration_oos_no_progress_test.sh
# 依存:   bash 4+, awk, jq, mktemp, sha256sum または cksum
# 実行:   bash local-watcher/test/pr_iteration_oos_no_progress_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_ITERATION_SH="$SCRIPT_DIR/../bin/idd-codex-modules/pr-iteration.sh"

if [ ! -f "$PR_ITERATION_SH" ]; then
  echo "ERROR: cannot find pr-iteration.sh at $PR_ITERATION_SH" >&2
  exit 2
fi

extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

for fn in pi_detect_developer_oos_marker pi_oos_fingerprint \
          pi_read_oos_no_progress_streak pi_read_oos_fingerprint \
          pi_next_oos_no_progress_streak pi_write_marker; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$PR_ITERATION_SH" "$fn")"
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# ── stub state ──
STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT
WARN_LOG="$STATE_DIR/warn.log"
GH_VIEW_BODY_FILE="$STATE_DIR/view_body.txt"
GH_EDIT_BODY_FILE="$STATE_DIR/edit_body.txt"

reset_stub_state() {
  : > "$WARN_LOG"
  : > "$GH_VIEW_BODY_FILE"
  : > "$GH_EDIT_BODY_FILE"
}

# shellcheck disable=SC2317
pi_warn() { echo "$*" >>"$WARN_LOG"; }

# timeout stub: 最初の引数（秒数）を捨てて残りを実行
# shellcheck disable=SC2317
timeout() {
  shift
  "$@"
}

# gh stub: pr view は fixture body、pr edit は --body の値を capture
# shellcheck disable=SC2317
gh() {
  case "${1:-} ${2:-}" in
    "pr view")
      cat "$GH_VIEW_BODY_FILE"
      return 0
      ;;
    "pr edit")
      local prev=""
      local arg
      for arg in "$@"; do
        if [ "$prev" = "--body" ]; then
          printf '%s' "$arg" >"$GH_EDIT_BODY_FILE"
        fi
        prev="$arg"
      done
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

export REPO="owner/test-repo"
export PR_ITERATION_GIT_TIMEOUT=5

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

assert_ne() {
  local label="$1"
  local not_expected="$2"
  local actual="$3"
  if [ "$not_expected" != "$actual" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  should differ from: $(printf '%q' "$not_expected")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

echo "--- Section A: pi_detect_developer_oos_marker ---"

# A.1: codex --json JSONL（item.completed 形式）
LOG_A1="$STATE_DIR/a1.jsonl"
jq -nc '{type:"item.completed", item:{id:"item_1", item_type:"agent_message",
  text:"指摘 3 は design.md の確定契約と矛盾します。\nOUT-OF-SCOPE: design\n根拠: Components 節の契約 X。"}}' >"$LOG_A1"
assert_eq "A.1: JSONL agent_message 中の行頭マーカー（design）を検出" \
  "design" "$(pi_detect_developer_oos_marker "$LOG_A1")"

# A.2: spec-stale + 前後空白許容
LOG_A2="$STATE_DIR/a2.jsonl"
jq -nc '{type:"item.completed", item:{id:"item_1", item_type:"agent_message",
  text:"本文\nOUT-OF-SCOPE:   spec-stale  \n続き"}}' >"$LOG_A2"
assert_eq "A.2: spec-stale（前後空白許容）を検出" \
  "spec-stale" "$(pi_detect_developer_oos_marker "$LOG_A2")"

# A.3: 行中言及は非検出（行頭アンカー）
LOG_A3="$STATE_DIR/a3.jsonl"
jq -nc '{type:"item.completed", item:{id:"item_1", item_type:"agent_message",
  text:"参考: OUT-OF-SCOPE: design と書くと打ち切りになります"}}' >"$LOG_A3"
assert_eq "A.3: 行中言及（行頭でない）は非検出" \
  "" "$(pi_detect_developer_oos_marker "$LOG_A3")"

# A.4: 語彙外は非検出
LOG_A4="$STATE_DIR/a4.jsonl"
jq -nc '{type:"item.completed", item:{id:"item_1", item_type:"agent_message",
  text:"OUT-OF-SCOPE: designer\nOUT-OF-SCOPE: foo"}}' >"$LOG_A4"
assert_eq "A.4: 語彙外（designer / foo）は非検出" \
  "" "$(pi_detect_developer_oos_marker "$LOG_A4")"

# A.5: マーカーなし / ログ不在 / 空パス
LOG_A5="$STATE_DIR/a5.jsonl"
jq -nc '{type:"item.completed", item:{id:"item_1", item_type:"agent_message", text:"通常の返信のみ"}}' >"$LOG_A5"
assert_eq "A.5a: マーカーなしは空" "" "$(pi_detect_developer_oos_marker "$LOG_A5")"
assert_eq "A.5b: ログ不在は空（fail-safe）" "" "$(pi_detect_developer_oos_marker "$STATE_DIR/nonexistent.log")"
assert_eq "A.5c: 空パスは空（fail-safe）" "" "$(pi_detect_developer_oos_marker "")"

# A.6: proto 形式（msg.type=agent_message / message フィールド）
LOG_A6="$STATE_DIR/a6.jsonl"
jq -nc '{id:"0", msg:{type:"agent_message", message:"根拠説明\nOUT-OF-SCOPE: design"}}' >"$LOG_A6"
assert_eq "A.6: proto 形式（msg.message）も検出" \
  "design" "$(pi_detect_developer_oos_marker "$LOG_A6")"

# A.7: plain text ログ fallback
LOG_A7="$STATE_DIR/a7.log"
printf '%s\n%s\n' "通常のテキストログ" "OUT-OF-SCOPE: spec-stale" >"$LOG_A7"
assert_eq "A.7: plain text ログでも行頭マーカーを検出（fallback）" \
  "spec-stale" "$(pi_detect_developer_oos_marker "$LOG_A7")"

echo "--- Section B: pi_oos_fingerprint ---"

DEC_1='{
  "decisions": [
    {"verdict":"out-of-scope","severity":"high","file":"a.sh","message":"m1"},
    {"verdict":"out-of-scope","severity":"low","file":"b.sh","message":"m2"},
    {"verdict":"legitimate","severity":"low","file":"x.sh","message":"in-scope は素材に含めない"}
  ]
}'
DEC_1_REORDERED='{
  "decisions": [
    {"verdict":"out-of-scope","severity":"low","file":"b.sh","message":"m2"},
    {"verdict":"out-of-scope","severity":"high","file":"a.sh","message":"m1"}
  ]
}'
DEC_2='{
  "decisions": [
    {"verdict":"out-of-scope","severity":"high","file":"a.sh","message":"m1-changed"},
    {"verdict":"out-of-scope","severity":"low","file":"b.sh","message":"m2"}
  ]
}'

fp1=$(pi_oos_fingerprint "$DEC_1")
fp1r=$(pi_oos_fingerprint "$DEC_1_REORDERED")
fp2=$(pi_oos_fingerprint "$DEC_2")
assert_eq "B.1: 同一内容・順序違いは同一 fingerprint（順序非依存 / in-scope 非影響）" "$fp1" "$fp1r"
assert_ne "B.2: 内容変化で fingerprint が変わる" "$fp1" "$fp2"

DEC_1_WITH_SHA=$(printf '%s' "$DEC_1" | jq -c '. + {sha: "deadbeef"}')
assert_eq "B.3: head SHA 相当の付随フィールドは fingerprint に影響しない" \
  "$fp1" "$(pi_oos_fingerprint "$DEC_1_WITH_SHA")"

fp_empty1=$(pi_oos_fingerprint "")
fp_empty2=$(pi_oos_fingerprint "{}")
assert_eq "B.4: 空入力 / out-of-scope なしは安定ハッシュ" "$fp_empty1" "$fp_empty2"

echo "--- Section C: marker の読み書き ---"

BODY_5FIELD='PR 本文です。

<!-- idd-codex:pr-iteration round=3 last-run=2026-07-08T00:00:00Z no-progress-streak=1 oos-no-progress-streak=2 oos-fingerprint=cafe01 -->'
BODY_3FIELD='PR 本文です。

<!-- idd-codex:pr-iteration round=3 last-run=2026-07-08T00:00:00Z no-progress-streak=1 -->'

assert_eq "C.1a: 5 フィールド marker から oos streak を読める" \
  "2" "$(pi_read_oos_no_progress_streak "$BODY_5FIELD")"
assert_eq "C.1b: 5 フィールド marker から oos fingerprint を読める" \
  "cafe01" "$(pi_read_oos_fingerprint "$BODY_5FIELD")"
assert_eq "C.2a: 既存 3 フィールド marker は oos streak=0（後方互換）" \
  "0" "$(pi_read_oos_no_progress_streak "$BODY_3FIELD")"
assert_eq "C.2b: 既存 3 フィールド marker は oos fingerprint 空（後方互換）" \
  "" "$(pi_read_oos_fingerprint "$BODY_3FIELD")"
assert_eq "C.3a: 空 body は 0" "0" "$(pi_read_oos_no_progress_streak "")"
assert_eq "C.3b: 空 body は空" "" "$(pi_read_oos_fingerprint "")"

# C.4: gate ON + oos 引数 → 5 フィールド
export PR_ITERATION_OOS_ENABLED="true"
reset_stub_state
printf '%s' "$BODY_3FIELD" >"$GH_VIEW_BODY_FILE"
pi_write_marker "404" "4" "0" "1" "cafe02" >/dev/null 2>&1 || true
written=$(cat "$GH_EDIT_BODY_FILE")
case "$written" in
  *"oos-no-progress-streak=1 oos-fingerprint=cafe02 -->"*)
    assert_eq "C.4: gate ON + oos 引数で 5 フィールド marker を書く" "ok" "ok" ;;
  *)
    assert_eq "C.4: gate ON + oos 引数で 5 フィールド marker を書く" "5field" "$written" ;;
esac

# C.5: gate OFF → oos 引数があっても 3 フィールド（byte 互換）
export PR_ITERATION_OOS_ENABLED="false"
reset_stub_state
printf '%s' "$BODY_3FIELD" >"$GH_VIEW_BODY_FILE"
pi_write_marker "404" "4" "0" "1" "cafe02" >/dev/null 2>&1 || true
written=$(cat "$GH_EDIT_BODY_FILE")
case "$written" in
  *"oos-no-progress-streak"*)
    assert_eq "C.5: gate OFF では oos フィールドを書かない（3 フィールド維持）" "3field" "$written" ;;
  *"no-progress-streak=0 -->"*)
    assert_eq "C.5: gate OFF では oos フィールドを書かない（3 フィールド維持）" "ok" "ok" ;;
  *)
    assert_eq "C.5: gate OFF では oos フィールドを書かない（3 フィールド維持）" "3field-marker" "$written" ;;
esac

# C.6: gate ON + oos 引数なし → 3 フィールド
export PR_ITERATION_OOS_ENABLED="true"
reset_stub_state
printf '%s' "$BODY_3FIELD" >"$GH_VIEW_BODY_FILE"
pi_write_marker "404" "4" "0" >/dev/null 2>&1 || true
written=$(cat "$GH_EDIT_BODY_FILE")
case "$written" in
  *"oos-no-progress-streak"*)
    assert_eq "C.6: gate ON でも oos 引数なしなら 3 フィールド" "3field" "$written" ;;
  *"no-progress-streak=0 -->"*)
    assert_eq "C.6: gate ON でも oos 引数なしなら 3 フィールド" "ok" "ok" ;;
  *)
    assert_eq "C.6: gate ON でも oos 引数なしなら 3 フィールド" "3field-marker" "$written" ;;
esac

# C.7: 5 フィールド旧 marker が既存でも sed 置換で 1 つに集約される（後方互換の逆方向）
export PR_ITERATION_OOS_ENABLED="false"
reset_stub_state
printf '%s' "$BODY_5FIELD" >"$GH_VIEW_BODY_FILE"
pi_write_marker "404" "4" "0" >/dev/null 2>&1 || true
written=$(cat "$GH_EDIT_BODY_FILE")
marker_count=$(printf '%s' "$written" | grep -c 'idd-codex:pr-iteration round=' || true)
assert_eq "C.7: 旧 5 フィールド marker も置換で 1 つに集約（gate OFF で 3 フィールド化）" \
  "1" "$marker_count"
case "$written" in
  *"oos-no-progress-streak"*)
    assert_eq "C.7: gate OFF の書き戻しに oos フィールドは残らない" "no-oos" "$written" ;;
  *)
    assert_eq "C.7: gate OFF の書き戻しに oos フィールドは残らない" "ok" "ok" ;;
esac

echo "--- Section D: pi_next_oos_no_progress_streak ---"

assert_eq "D.1: fingerprint 同一なら prev+1" "3" "$(pi_next_oos_no_progress_streak "cafe" "cafe" "2")"
assert_eq "D.2: fingerprint 変化なら 0 リセット" "0" "$(pi_next_oos_no_progress_streak "cafe" "beef" "2")"
assert_eq "D.3a: prev 空なら 0（初回 round）" "0" "$(pi_next_oos_no_progress_streak "" "cafe" "2")"
assert_eq "D.3b: current 空なら 0（取得失敗の安全側）" "0" "$(pi_next_oos_no_progress_streak "cafe" "" "2")"
assert_eq "D.4: prev_streak 非数値なら 1（防御的）" "1" "$(pi_next_oos_no_progress_streak "cafe" "cafe" "abc")"

echo ""
echo "RESULT: PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
