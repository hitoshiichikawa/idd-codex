#!/usr/bin/env bash
#
# 用途: cost-estimate.sh（Issue #176）を検証する。
#   - gate（COST_ESTIMATE_ENABLED=false 厳密一致のみ無効 / 既定 有効）
#   - ce_model_from_args（codex_exec_prompt 契約 / -m / --model / -m= / 判定不能）
#   - ce_price_table_entries（既定表 3 行 / override 追加・後勝ち / 不正 entry は WARN + skip）
#   - ce_lookup_price（完全一致優先 / 最長 prefix 一致 / 未知は空 / 空 model は空）
#   - ce_estimate_usd（cached 差分計算 / 0 token / cached > input の防御）
#   - ce_stage_cost_suffix + run 合算（priced / unknown / none）
#   - qa_log_token_usage 統合: 既存 `stage tokens` 行の末尾に model= cost_usd= が併記され、
#     無効時 / モジュール未ロード時は従来行と byte 一致（後方互換）
#   - rs_emit 統合: run-summary 行末尾に cost-usd= / cost-unknown-stages= が追加され、無効時は不変
#
# 配置先: local-watcher/test/cost_estimate_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/cost_estimate_test.sh

# 環境変数は source したモジュール関数が参照するため、静的解析の未使用警告（SC2034）を抑止する。
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/cost-estimate.sh"
QA_SH="$SCRIPT_DIR/../bin/idd-codex-modules/quota-aware.sh"
RS_SH="$SCRIPT_DIR/../bin/idd-codex-modules/run-summary.sh"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
for f in "$MODULE_SH" "$QA_SH" "$RS_SH" "$WATCHER_SH"; do [ -f "$f" ] || { echo "ERROR: not found: $f" >&2; exit 2; }; done

extract_function() {
  local script="$1" fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# shellcheck disable=SC1090
. "$MODULE_SH"
for fn in ce_is_enabled ce_model_from_args ce_price_table_entries ce_lookup_price ce_estimate_usd ce_stage_cost_suffix ce_reset_run_totals ce_record_stage_cost ce_run_summary_suffix; do
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done
# shellcheck disable=SC1090
eval "$(extract_function "$QA_SH" "qa_log_token_usage")"
# shellcheck disable=SC1090
eval "$(extract_function "$RS_SH" "rs_init")"
# shellcheck disable=SC1090
eval "$(extract_function "$RS_SH" "rs_emit")"
for fn in qa_log_token_usage rs_init rs_emit; do
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done

REPO="owner/repo"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CAP="$TMP/qa.cap"; WARN_CAP="$TMP/warn.cap"
qa_log()  { printf '%s\n' "$*" >>"$CAP"; }
ce_log()  { :; }
ce_warn() { printf '%s\n' "$*" >>"$WARN_CAP"; }
ce_error(){ printf 'ERROR %s\n' "$*" >>"$WARN_CAP"; }
reset_caps() { : >"$CAP"; : >"$WARN_CAP"; unset COST_ESTIMATE_ENABLED COST_ESTIMATE_PRICE_TABLE; }
warn_count() { grep -c . "$WARN_CAP" 2>/dev/null || true; }

PASS_COUNT=0; FAIL_COUNT=0
assert_eq() { local l="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l"; echo "  exp=$(printf '%q' "$e") act=$(printf '%q' "$a")"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }
assert_contains() { local l="$1" h="$2" n="$3"; case "$h" in *"$n"*) echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1));; *) echo "FAIL: $l ('$n' 不在: $(printf '%q' "$h" | cut -c1-300))"; FAIL_COUNT=$((FAIL_COUNT+1));; esac; }
assert_not_contains() { local l="$1" h="$2" n="$3"; case "$h" in *"$n"*) echo "FAIL: $l ('$n' が存在)"; FAIL_COUNT=$((FAIL_COUNT+1));; *) echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1));; esac; }
rc_of() { local fn="$1"; shift; local r=0; "$fn" "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }

# ════════════════════════════════════════════════════════════════════════════
echo "--- 1. ce_is_enabled ---"
unset COST_ESTIMATE_ENABLED; assert_eq "未設定 → 有効(0)" "0" "$(rc_of ce_is_enabled)"
COST_ESTIMATE_ENABLED=true;  assert_eq "true → 有効(0)" "0" "$(rc_of ce_is_enabled)"
COST_ESTIMATE_ENABLED=false; assert_eq "false → 無効(1)" "1" "$(rc_of ce_is_enabled)"
COST_ESTIMATE_ENABLED=FALSE; assert_eq "FALSE → 有効(0)（厳密一致外）" "0" "$(rc_of ce_is_enabled)"
COST_ESTIMATE_ENABLED=0;     assert_eq "0 → 有効(0)" "0" "$(rc_of ce_is_enabled)"
unset COST_ESTIMATE_ENABLED

echo ""; echo "--- 2. ce_model_from_args ---"
assert_eq "codex_exec_prompt 契約 → 第 3 引数" "gpt-5.6-terra" "$(ce_model_from_args codex_exec_prompt StageA gpt-5.6-terra "long prompt with spaces")"
assert_eq "-m <model>" "gpt-5.6-luna" "$(ce_model_from_args codex exec -C /x -m gpt-5.6-luna --json -)"
assert_eq "--model <model>" "gpt-5.6-sol" "$(ce_model_from_args codex exec --model gpt-5.6-sol)"
assert_eq "-m=<model>" "gpt-5.6-terra" "$(ce_model_from_args codex exec -m=gpt-5.6-terra)"
assert_eq "モデル指定なし → 空" "" "$(ce_model_from_args codex exec --json)"
assert_eq "引数なし → 空" "" "$(ce_model_from_args)"

echo ""; echo "--- 3. ce_price_table_entries ---"
reset_caps
ENTRIES="$(ce_price_table_entries)"
assert_eq "既定表は 3 行" "3" "$(printf '%s\n' "$ENTRIES" | grep -c .)"
assert_contains "sol 単価" "$ENTRIES" "gpt-5.6-sol 5 0.5 30"
assert_contains "terra 単価" "$ENTRIES" "gpt-5.6-terra 2.5 0.25 15"
assert_contains "luna 単価" "$ENTRIES" "gpt-5.6-luna 1 0.1 6"
assert_eq "既定表で WARN なし" "0" "$(warn_count)"
reset_caps
COST_ESTIMATE_PRICE_TABLE="gpt-5.5=1.25:0.125:10, gpt-5.6-terra=3:0.3:18 ,bad-entry,gpt-x=1:2,gpt-y=a:b:c,we/ird=1:1:1"
ENTRIES="$(ce_price_table_entries)"
assert_contains "override で新モデル追加" "$ENTRIES" "gpt-5.5 1.25 0.125 10"
assert_contains "override は空白トリムされる" "$ENTRIES" "gpt-5.6-terra 3 0.3 18"
assert_not_contains "'=' 無し entry は skip" "$ENTRIES" "bad-entry"
assert_not_contains "2 値 entry は skip" "$ENTRIES" "gpt-x"
assert_not_contains "非数値 entry は skip" "$ENTRIES" "gpt-y"
assert_not_contains "不正文字 model は skip" "$ENTRIES" "we/ird"
assert_eq "不正 entry 4 件それぞれ WARN" "4" "$(warn_count)"
assert_contains "WARN に形式説明" "$(cat "$WARN_CAP")" "model=input:cached:output"

echo ""; echo "--- 4. ce_lookup_price ---"
reset_caps
assert_eq "完全一致 terra" "2.5 0.25 15" "$(ce_lookup_price gpt-5.6-terra)"
assert_eq "派生 ID は最長 prefix 一致" "2.5 0.25 15" "$(ce_lookup_price gpt-5.6-terra-2026-09-01)"
assert_eq "未知モデルは空" "" "$(ce_lookup_price gpt-5.5)"
assert_eq "部分文字列（prefix でない）は不一致" "" "$(ce_lookup_price my-gpt-5.6-terra)"
assert_eq "空 model は空" "" "$(ce_lookup_price "")"
COST_ESTIMATE_PRICE_TABLE="gpt-5.6-terra=3:0.3:18"
assert_eq "override は既定より優先（後勝ち）" "3 0.3 18" "$(ce_lookup_price gpt-5.6-terra)"
COST_ESTIMATE_PRICE_TABLE="gpt-5.6=9:0.9:90"
assert_eq "完全一致キーがあれば短い prefix より優先" "2.5 0.25 15" "$(ce_lookup_price gpt-5.6-terra)"
assert_eq "完全一致が無ければ最長 prefix（gpt-5.6-terra > gpt-5.6）" "2.5 0.25 15" "$(ce_lookup_price gpt-5.6-terra-x)"
assert_eq "gpt-5.6-mini は gpt-5.6 prefix にだけ一致" "9 0.9 90" "$(ce_lookup_price gpt-5.6-mini)"
unset COST_ESTIMATE_PRICE_TABLE

echo ""; echo "--- 5. ce_estimate_usd ---"
assert_eq "1M 非キャッシュ input のみ (terra) → 2.5000" "2.5000" "$(ce_estimate_usd 1000000 0 0 2.5 0.25 15)"
assert_eq "1M 全 cached input → 0.2500" "0.2500" "$(ce_estimate_usd 1000000 1000000 0 2.5 0.25 15)"
assert_eq "1M output → 15.0000" "15.0000" "$(ce_estimate_usd 0 0 1000000 2.5 0.25 15)"
assert_eq "混合: 実測値（#175 task1）→ 1.3463" "1.3463" "$(ce_estimate_usd 3192273 3045632 14555 2.5 0.25 15)"
assert_eq "0 token → 0.0000" "0.0000" "$(ce_estimate_usd 0 0 0 2.5 0.25 15)"
assert_eq "cached > input の不整合は全量 cached 扱い" "0.2500" "$(ce_estimate_usd 1000000 2000000 0 2.5 0.25 15)"
assert_eq "引数欠落は 0 扱い" "0.0000" "$(ce_estimate_usd)"

echo ""; echo "--- 6. ce_stage_cost_suffix + run 合算 ---"
reset_caps; ce_reset_run_totals
assert_eq "terra priced" " model=gpt-5.6-terra cost_usd=1.3463" "$(ce_stage_cost_suffix gpt-5.6-terra 3192273 3045632 14555)"
ce_stage_cost_suffix gpt-5.6-terra 3192273 3045632 14555 >/dev/null
assert_eq "未知モデル → unknown" " model=gpt-5.5 cost_usd=unknown" "$(ce_stage_cost_suffix gpt-5.5 100 0 10)"
ce_stage_cost_suffix gpt-5.5 100 0 10 >/dev/null
assert_eq "空モデル → model=unknown cost_usd=unknown" " model=unknown cost_usd=unknown" "$(ce_stage_cost_suffix "" 100 0 10)"
ce_stage_cost_suffix "" 100 0 10 >/dev/null
assert_eq "改行入りモデル名は丸められる" " model=gpt?x cost_usd=unknown" "$(ce_stage_cost_suffix $'gpt\nx' 1 0 0)"
ce_stage_cost_suffix $'gpt\nx' 1 0 0 >/dev/null
assert_eq "合算: priced 1 / unknown 3" " cost-usd=1.3463 cost-unknown-stages=3" "$(ce_run_summary_suffix)"
ce_stage_cost_suffix gpt-5.6-luna 1000000 0 0 >/dev/null
assert_eq "合算は加算される（+1.0000）" " cost-usd=2.3463 cost-unknown-stages=3" "$(ce_run_summary_suffix)"
ce_reset_run_totals
assert_eq "stage 無し → none" " cost-usd=none cost-unknown-stages=0" "$(ce_run_summary_suffix)"
ce_record_stage_cost unknown
assert_eq "unknown のみ → unknown" " cost-usd=unknown cost-unknown-stages=1" "$(ce_run_summary_suffix)"
COST_ESTIMATE_ENABLED=false
assert_eq "無効時 suffix は空" "" "$(ce_stage_cost_suffix gpt-5.6-terra 1 0 0)"
assert_eq "無効時 run-summary suffix は空" "" "$(ce_run_summary_suffix)"
unset COST_ESTIMATE_ENABLED

echo ""; echo "--- 7. qa_log_token_usage 統合（既存行末尾へ併記 / 後方互換）---"
reset_caps; ce_reset_run_totals
cat >"$TMP/s1.jsonl" <<'EOF'
{"type":"turn.completed","usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}
EOF
qa_log_token_usage "StageA" "$TMP/s1.jsonl" "gpt-5.6-terra"
assert_eq "行末尾に model / cost_usd が併記" "stage tokens label=StageA input=1000000 cached_input=0 output=0 reasoning=0 total=1000000 turns=1 model=gpt-5.6-terra cost_usd=2.5000" "$(cat "$CAP")"
reset_caps
qa_log_token_usage "StageA" "$TMP/s1.jsonl" "gpt-5.5"
assert_contains "未知モデルは cost_usd=unknown（token 集計は従来どおり）" "$(cat "$CAP")" "total=1000000 turns=1 model=gpt-5.5 cost_usd=unknown"
reset_caps
qa_log_token_usage "StageA" "$TMP/s1.jsonl"
assert_contains "model 未指定 → model=unknown cost_usd=unknown" "$(cat "$CAP")" "model=unknown cost_usd=unknown"
reset_caps
COST_ESTIMATE_ENABLED=false
qa_log_token_usage "StageA" "$TMP/s1.jsonl" "gpt-5.6-terra"
assert_eq "無効時は従来行と byte 一致" "stage tokens label=StageA input=1000000 cached_input=0 output=0 reasoning=0 total=1000000 turns=1" "$(cat "$CAP")"
unset COST_ESTIMATE_ENABLED
reset_caps
cat >"$TMP/s4.jsonl" <<'EOF'
{"type":"thread.started","thread_id":"t4"}
EOF
qa_log_token_usage "StageC" "$TMP/s4.jsonl" "gpt-5.6-terra"
assert_eq "turn.completed 無しはログしない（従来どおり）" "" "$(cat "$CAP")"
# モジュール未ロード相当: ce_stage_cost_suffix を一時的に隠す
reset_caps
_saved_fn="$(declare -f ce_stage_cost_suffix)"
unset -f ce_stage_cost_suffix
qa_log_token_usage "StageA" "$TMP/s1.jsonl" "gpt-5.6-terra"
assert_eq "cost-estimate 未ロード時は従来行と byte 一致" "stage tokens label=StageA input=1000000 cached_input=0 output=0 reasoning=0 total=1000000 turns=1" "$(cat "$CAP")"
eval "$_saved_fn"

echo ""; echo "--- 8. rs_emit 統合 ---"
reset_caps
date() { printf '2026-09-04 12:00:00\n'; }
rs_init
ce_stage_cost_suffix gpt-5.6-terra 1000000 0 0 >/dev/null
ce_stage_cost_suffix gpt-5.5 1 0 0 >/dev/null
RS_LINE="$(rs_emit)"
assert_contains "run-summary 末尾に cost-usd / cost-unknown-stages" "$RS_LINE" "result=unknown cost-usd=2.5000 cost-unknown-stages=1"
assert_contains "既存 key 群は不変" "$RS_LINE" "run-summary: issue=#? mode=unknown stages=none reviewer=n/a stage-a-verify=n/a scaffolding=unknown errors=no degraded-events=none warnings=none result=unknown"
rs_init
assert_eq "rs_init で合算がリセットされる" " cost-usd=none cost-unknown-stages=0" "$(ce_run_summary_suffix)"
COST_ESTIMATE_ENABLED=false
RS_LINE="$(rs_emit)"
assert_eq "無効時 run-summary は従来フォーマットと一致" "[2026-09-04 12:00:00] [owner/repo] run-summary: issue=#? mode=unknown stages=none reviewer=n/a stage-a-verify=n/a scaffolding=unknown errors=no degraded-events=none warnings=none result=unknown" "$RS_LINE"
unset COST_ESTIMATE_ENABLED
unset -f date

echo ""; echo "--- 9. 本体配線 ---"
assert_contains "REQUIRED_MODULES に cost-estimate.sh" "$(grep -E '^REQUIRED_MODULES=' "$WATCHER_SH")" '"cost-estimate.sh"'
assert_contains "Config に COST_ESTIMATE_ENABLED 既定 true" "$(grep -E '^COST_ESTIMATE_ENABLED=' "$WATCHER_SH")" ':-true}'
assert_contains "qa_run_codex_stage が model を抽出して渡す" "$(extract_function "$QA_SH" "qa_run_codex_stage")" 'qa_log_token_usage "$stage_label" "$stream_file" "$_qa_model"'
assert_contains "qa_run_codex_stage は ce_model_from_args を declare -F でガード" "$(extract_function "$QA_SH" "qa_run_codex_stage")" 'declare -F ce_model_from_args'

echo ""; echo "──────────────"
echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
echo "ALL GREEN"
