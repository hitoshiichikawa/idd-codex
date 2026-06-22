#!/usr/bin/env bash
#
# 用途: needs-decisions-auto.sh の mode 正規化 / classification fail-safe 畳み込み /
#       第一推奨抽出 / budget ガード / **3 モード × safe/human-only マトリクス**（最重要:
#       human-only は all-auto でも自動続行しない）/ 安全側フォールバック / 自動続行副作用を
#       検証する。Issue #102 / D-08・D-09。
#
# 配置先: local-watcher/test/needs_decisions_auto_test.sh
# 依存:   bash 4+, awk, grep, jq, mktemp
# 実行:   bash local-watcher/test/needs_decisions_auto_test.sh
# 前提:   needs-decisions-auto.sh から nda_* を、watcher から full_auto_enabled を awk 抽出 → eval。
#         gh / timeout / logger を stub。Triage JSON は実 jq + 実一時ファイルで評価する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/needs-decisions-auto.sh"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
for f in "$MODULE_SH" "$WATCHER_SH"; do
  [ -f "$f" ] || { echo "ERROR: not found: $f" >&2; exit 2; }
done

extract_function() {
  local script="$1" fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

REAL_FNS=(
  nda_resolve_mode_enabled nda_extract_classification nda_extract_first_recommendation
  nda_count_prior_auto_continues nda_budget_available nda_auto_continue nda_evaluate_auto_continue
)
for fn in "${REAL_FNS[@]}"; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$MODULE_SH" "$fn")"
done
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "full_auto_enabled")"

for fn in "${REAL_FNS[@]}" full_auto_enabled; do
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done

# ─── 共有グローバル ───
REPO="owner/repo"; NUMBER=42; LABEL_CLAIMED="codex-claimed"
NEEDS_DECISIONS_AUTO_MAX=4; NEEDS_DECISIONS_GIT_TIMEOUT=5
NDA_COMMENT_MARKER="idd-codex:needs-decisions-auto"

# ─── trace 変数 / stub ───
GH_CALL_LOG=""; GH_COMMENTS_RESPONSE='{"comments":[]}'; GH_VIEW_RC=0
timeout() { shift; "$@"; }
gh() {
  printf 'gh %s\n' "$*" >>"$GH_CALL_LOG"
  case "$1 $2" in
    "issue view") [ "$GH_VIEW_RC" -ne 0 ] && return "$GH_VIEW_RC"; printf '%s' "$GH_COMMENTS_RESPONSE" ;;
  esac
  return 0
}
nda_log()  { :; }
nda_warn() { :; }
nda_error(){ :; }

reset_state() { GH_CALL_LOG="$(mktemp)"; GH_COMMENTS_RESPONSE='{"comments":[]}'; GH_VIEW_RC=0; }
calls() { grep -c "$1" "$GH_CALL_LOG" 2>/dev/null || true; }

# Triage JSON ビルダー
# 単一 decision: $1=classification（空なら field 省略）, $2=recommendation（空なら省略）
triage_single() {
  local cls="$1" rec="$2"
  local dec='{"topic":"t","question":"q","options":["A","B"],"impact":"i"}'
  [ -n "$rec" ] && dec=$(printf '%s' "$dec" | jq -c --arg r "$rec" '. + {recommendation:$r}')
  [ -n "$cls" ] && dec=$(printf '%s' "$dec" | jq -c --arg c "$cls" '. + {classification:$c}')
  local f; f="$(mktemp)"
  jq -nc --argjson d "$dec" '{status:"codex-needs-decisions",decisions:[$d]}' > "$f"
  printf '%s' "$f"
}
# 2 decisions: $1,$2 = classification of each
triage_pair() {
  local f; f="$(mktemp)"
  jq -nc --arg c1 "$1" --arg c2 "$2" '
    {status:"codex-needs-decisions",decisions:[
      {topic:"t1",recommendation:"r1",classification:$c1},
      {topic:"t2",recommendation:"r2",classification:$c2}]}' > "$f"
  printf '%s' "$f"
}

PASS_COUNT=0; FAIL_COUNT=0
assert_eq() { local l="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l"; echo "  exp=$(printf '%q' "$e") act=$(printf '%q' "$a")"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }
rc_of() { local fn="$1"; shift; local r=0; "$fn" "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }
# 現在シェルで評価（trace 変数保持）
EVAL_RC=0
eval_guard() { EVAL_RC=0; nda_evaluate_auto_continue "$1" >/dev/null 2>&1 || EVAL_RC=$?; }

# ════════════════════════════════════════════════════════════════════════════
echo "--- 1. nda_resolve_mode_enabled（mode 正規化）---"
NEEDS_DECISIONS_MODE=all-human; assert_eq "all-human → halt(1)"  "1" "$(rc_of nda_resolve_mode_enabled)"
NEEDS_DECISIONS_MODE=classified; assert_eq "classified → eval(0)" "0" "$(rc_of nda_resolve_mode_enabled)"
NEEDS_DECISIONS_MODE=all-auto;  assert_eq "all-auto → eval(0)"   "0" "$(rc_of nda_resolve_mode_enabled)"
NEEDS_DECISIONS_MODE=bogus;     assert_eq "不正値 → halt(1)"     "1" "$(rc_of nda_resolve_mode_enabled)"
unset NEEDS_DECISIONS_MODE;     assert_eq "未設定 → halt(1)"     "1" "$(rc_of nda_resolve_mode_enabled)"

echo ""; echo "--- 2. nda_extract_classification（fail-safe 畳み込み）---"
f=$(triage_single "safe" "r");       assert_eq "全 safe → safe"          "safe"       "$(nda_extract_classification "$f")"; rm -f "$f"
f=$(triage_single "human-only" "r"); assert_eq "human-only → human-only"  "human-only" "$(nda_extract_classification "$f")"; rm -f "$f"
f=$(triage_single "" "r");           assert_eq "tag 欠落 → human-only"    "human-only" "$(nda_extract_classification "$f")"; rm -f "$f"
f=$(triage_single "bogus" "r");      assert_eq "不明値 → human-only"      "human-only" "$(nda_extract_classification "$f")"; rm -f "$f"
f=$(triage_pair "safe" "human-only");assert_eq "混在(safe+human) → human-only" "human-only" "$(nda_extract_classification "$f")"; rm -f "$f"
f=$(triage_pair "safe" "safe");      assert_eq "全 safe(複数) → safe"     "safe"       "$(nda_extract_classification "$f")"; rm -f "$f"
echo '{"status":"ready","decisions":[]}' > /tmp/nda_empty.json
assert_eq "空 decisions → human-only" "human-only" "$(nda_extract_classification /tmp/nda_empty.json)"; rm -f /tmp/nda_empty.json
printf 'broken{{' > /tmp/nda_broken.json
assert_eq "破損 JSON → human-only" "human-only" "$(nda_extract_classification /tmp/nda_broken.json)"; rm -f /tmp/nda_broken.json
assert_eq "ファイル無し → human-only" "human-only" "$(nda_extract_classification /tmp/nonexistent-nda.json)"

echo ""; echo "--- 3. nda_extract_first_recommendation ---"
f=$(triage_single "safe" "進めて OK");  assert_eq "推奨あり → rc 0"  "0" "$(rc_of nda_extract_first_recommendation "$f")"
assert_eq "推奨あり → 値取得" "進めて OK" "$(nda_extract_first_recommendation "$f")"; rm -f "$f"
f=$(triage_single "safe" "");            assert_eq "推奨空 → rc 1"   "1" "$(rc_of nda_extract_first_recommendation "$f")"; rm -f "$f"
assert_eq "ファイル無し → rc 1" "1" "$(rc_of nda_extract_first_recommendation /tmp/nonexistent-nda.json)"

echo ""; echo "--- 4. budget ガード（marker カウント）---"
reset_state
assert_eq "marker 0 件 → 続行可(0)" "0" "$(rc_of nda_budget_available 42)"
# marker 4 件 → 枯渇
mk='<!-- idd-codex:needs-decisions-auto issue=42 mode=classified -->'
GH_COMMENTS_RESPONSE=$(jq -nc --arg m "$mk" '{comments:[{body:$m},{body:$m},{body:$m},{body:$m}]}')
assert_eq "marker 4 件(=MAX) → 枯渇(1)" "1" "$(rc_of nda_budget_available 42)"
GH_COMMENTS_RESPONSE=$(jq -nc --arg m "$mk" '{comments:[{body:$m},{body:$m},{body:$m}]}')
assert_eq "marker 3 件(<MAX) → 続行可(0)" "0" "$(rc_of nda_budget_available 42)"
# 別 Issue の marker は数えない
GH_COMMENTS_RESPONSE=$(jq -nc '{comments:[{body:"<!-- idd-codex:needs-decisions-auto issue=99 mode=classified -->"}]}')
assert_eq "別 issue marker は無視 → 続行可(0)" "0" "$(rc_of nda_budget_available 42)"
# gh 取得失敗 → 安全側（枯渇）
reset_state; GH_VIEW_RC=1
assert_eq "gh 失敗 → 安全側 枯渇(1)" "1" "$(rc_of nda_budget_available 42)"

echo ""; echo "--- 5. nda_evaluate_auto_continue: 3 モード × safe/human-only マトリクス（最重要）---"
FULL_AUTO_ENABLED=true
# all-human は常に halt
reset_state; NEEDS_DECISIONS_MODE=all-human; f=$(triage_single "safe" "r"); eval_guard "$f"
assert_eq "all-human + safe → halt(1)" "1" "$EVAL_RC"; rm -f "$f"
# classified
reset_state; NEEDS_DECISIONS_MODE=classified; f=$(triage_single "safe" "r"); eval_guard "$f"
assert_eq "classified + safe → 続行(0)" "0" "$EVAL_RC"; rm -f "$f"
reset_state; NEEDS_DECISIONS_MODE=classified; f=$(triage_single "human-only" "r"); eval_guard "$f"
assert_eq "classified + human-only → halt(1)【安全境界】" "1" "$EVAL_RC"; rm -f "$f"
# all-auto（human-only は all-auto でも halt = 最重要）
reset_state; NEEDS_DECISIONS_MODE=all-auto; f=$(triage_single "safe" "r"); eval_guard "$f"
assert_eq "all-auto + safe → 続行(0)" "0" "$EVAL_RC"; rm -f "$f"
reset_state; NEEDS_DECISIONS_MODE=all-auto; f=$(triage_single "human-only" "r"); eval_guard "$f"
assert_eq "all-auto + human-only → halt(1)【最重要・自動続行しない】" "1" "$EVAL_RC"; rm -f "$f"

echo ""; echo "--- 6. nda_evaluate_auto_continue: 安全側フォールバック ---"
# full_auto OFF
reset_state; FULL_AUTO_ENABLED=false; NEEDS_DECISIONS_MODE=all-auto; f=$(triage_single "safe" "r"); eval_guard "$f"
assert_eq "full_auto OFF → halt(1)" "1" "$EVAL_RC"; rm -f "$f"
FULL_AUTO_ENABLED=true
# 推奨欠落 → halt
reset_state; NEEDS_DECISIONS_MODE=classified; f=$(triage_single "safe" ""); eval_guard "$f"
assert_eq "safe だが推奨欠落 → halt(1)" "1" "$EVAL_RC"; rm -f "$f"
# 分類欠落 → human-only 畳み → halt
reset_state; NEEDS_DECISIONS_MODE=all-auto; f=$(triage_single "" "r"); eval_guard "$f"
assert_eq "classification 欠落 → halt(1)" "1" "$EVAL_RC"; rm -f "$f"
# budget 枯渇 → halt
reset_state; NEEDS_DECISIONS_MODE=classified
GH_COMMENTS_RESPONSE=$(jq -nc --arg m "$mk" '{comments:[{body:$m},{body:$m},{body:$m},{body:$m}]}')
f=$(triage_single "safe" "r"); eval_guard "$f"
assert_eq "budget 枯渇 + safe → halt(1)" "1" "$EVAL_RC"; rm -f "$f"

echo ""; echo "--- 7. nda_auto_continue 副作用（コメント + claim 除去・needs-decisions 不付与）---"
reset_state; NEEDS_DECISIONS_MODE=classified; f=$(triage_single "safe" "進めて OK")
r=$(rc_of nda_auto_continue "$f" "進めて OK")
assert_eq "auto_continue → rc 0" "0" "$r"
assert_eq "audit コメント投稿" "1" "$(calls 'issue comment')"
assert_eq "codex-claimed 除去" "1" "$(calls 'remove-label codex-claimed')"
assert_eq "codex-needs-decisions は付与しない" "0" "$(calls 'add-label codex-needs-decisions')"
rm -f "$f"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
