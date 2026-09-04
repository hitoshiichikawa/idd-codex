#!/usr/bin/env bash
# cost-estimate.sh — ティア別単価によるステージ別推定コスト（USD）の可視化（Issue #176）
#
# 用途:
#   quota-aware.sh の `qa_log_token_usage` が集計する per-stage token（input / cached_input / output）に、
#   モデル ID → 単価（per 1M tokens）の対応表を掛けて推定 USD を算出し、既存の
#   `stage tokens label=...` ログ行の末尾に `model=<id> cost_usd=<usd>` を併記する。
#   run-summary（`run-summary:` 1 行）にはサイクル合算 `cost-usd=<sum>` と
#   `cost-unknown-stages=<n>` を末尾に追加する。外部サービス呼び出しは追加しない（純粋なログ拡張）。
#
#   - ce_is_enabled           : `COST_ESTIMATE_ENABLED=false` 厳密一致のみ無効（既定 有効 / observability のみ）
#   - ce_model_from_args      : qa_run_codex_stage に渡された codex コマンド引数からモデル ID を抽出
#   - ce_price_table_entries  : 既定表 + `COST_ESTIMATE_PRICE_TABLE` override を検証済み行として列挙
#   - ce_lookup_price         : モデル ID → "input cached output"（完全一致 → 最長 prefix 一致）
#   - ce_estimate_usd         : token 数 × 単価 → USD（小数 4 桁）
#   - ce_stage_cost_suffix    : ログ行末尾に併記する ` model=... cost_usd=...` を生成し run 合算へ記録
#   - ce_reset_run_totals / ce_record_stage_cost / ce_run_summary_suffix : run-summary 連携
#
# 単価の既定値（per 1M tokens, USD / input : cached_input : output）:
#   出典: Issue #176 記載の GPT-5.6 世代ティア別公表値（2026-07-10 時点。cached input は約 90% 引き）
#     gpt-5.6-sol   = 5.00 : 0.50 : 30.00
#     gpt-5.6-terra = 2.50 : 0.25 : 15.00
#     gpt-5.6-luna  = 1.00 : 0.10 :  6.00
#   価格改定や他モデルの追加は `COST_ESTIMATE_PRICE_TABLE`（env）で override / 追加する
#   （例: `COST_ESTIMATE_PRICE_TABLE="gpt-5.6-terra=2.5:0.25:15,gpt-5.5=1.25:0.125:10"`）。
#   対応表に無いモデルはコスト算出を skip し `cost_usd=unknown` と明示する（silent fail にしない）。
#
# token の意味（codex `turn.completed.usage` / OpenAI Responses API 互換）:
#   - input_tokens は cached_input_tokens を **含む**総 input。非キャッシュ分 = input - cached_input
#   - output_tokens は reasoning_output_tokens を **含む**総 output（reasoning を二重計上しない）
#
# 配置先:
#   $HOME/bin/idd-codex-modules/cost-estimate.sh（install.sh が local-watcher/bin/idd-codex-modules/ から配置）
#
# 依存:
#   - 本モジュールは idd-codex-issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー（ce_log / ce_warn / ce_error）は core_utils.sh にあるため再定義しない。
#   - 外部 CLI: awk。
#   - 関数 prefix `ce_` を namespace として採用する。

CE_DEFAULT_PRICE_TABLE="gpt-5.6-sol=5:0.5:30,gpt-5.6-terra=2.5:0.25:15,gpt-5.6-luna=1:0.1:6"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Gate Layer
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# observability のみで挙動影響ゼロのため既定 有効。`COST_ESTIMATE_ENABLED=false` 厳密一致のみ無効。
#   0 = enabled / 1 = disabled
ce_is_enabled() {
  [ "${COST_ESTIMATE_ENABLED:-true}" != "false" ] || return 1
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Pure helpers
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ログ埋め込み用にモデル ID を安全な文字集合へ丸める（改行 / 空白によるログ破壊防止）。
ce_sanitize_model() {
  printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._:-' '?' | cut -c1-64
}

# qa_run_codex_stage の wrapped command 引数からモデル ID を抽出する（純粋関数）。
#   - 先頭が `codex_exec_prompt` なら第 3 引数（<stage_label> <model> <prompt> の契約）
#   - それ以外は `-m <model>` / `--model <model>` / `-m=<model>` を走査
#   Stdout: モデル ID or 空（判定不能）/ Returns: 0
ce_model_from_args() {
  if [ "${1:-}" = "codex_exec_prompt" ]; then
    printf '%s\n' "${3:-}"
    return 0
  fi
  local prev="" arg
  for arg in "$@"; do
    case "$arg" in
      -m=*|--model=*) printf '%s\n' "${arg#*=}"; return 0 ;;
    esac
    if [ "$prev" = "-m" ] || [ "$prev" = "--model" ]; then
      printf '%s\n' "$arg"
      return 0
    fi
    prev="$arg"
  done
  printf '\n'
  return 0
}

# 単価表エントリを "model input cached output" の行として列挙する。
# 既定表の後に env override を並べる（後勝ち: 同一 model は override が優先）。
# 不正な entry（`=` / `:` 区切り不備・非数値・不正な model 文字）は ce_warn して skip（silent fail にしない）。
#   Stdout: 検証済み行（0 行以上）/ Returns: 0
ce_price_table_entries() {
  local table="${CE_DEFAULT_PRICE_TABLE}"
  if [ -n "${COST_ESTIMATE_PRICE_TABLE:-}" ]; then
    table="${table},${COST_ESTIMATE_PRICE_TABLE}"
  fi
  local entry model prices p_in p_cached p_out
  local IFS=','
  for entry in $table; do
    unset IFS
    entry="${entry//[[:space:]]/}"
    [ -n "$entry" ] || { IFS=','; continue; }
    case "$entry" in
      *=*) ;;
      *) ce_warn "price table entry '$(ce_sanitize_model "$entry")' は 'model=input:cached:output' 形式でないため skip"; IFS=','; continue ;;
    esac
    model="${entry%%=*}"
    prices="${entry#*=}"
    p_in="${prices%%:*}"; prices="${prices#*:}"
    p_cached="${prices%%:*}"; prices="${prices#*:}"
    p_out="${prices%%:*}"
    if ! printf '%s' "$model" | grep -qE '^[A-Za-z0-9._-]+$'; then
      ce_warn "price table entry の model '$(ce_sanitize_model "$model")' に不正文字が含まれるため skip"
      IFS=','; continue
    fi
    if [ "$(printf '%s' "${entry#*=}" | tr -cd ':' | wc -c)" -ne 2 ]; then
      ce_warn "price table entry '${model}' は input:cached:output の 3 値でないため skip"
      IFS=','; continue
    fi
    local v ok=1
    for v in "$p_in" "$p_cached" "$p_out"; do
      printf '%s' "$v" | grep -qE '^[0-9]+(\.[0-9]+)?$' || ok=0
    done
    if [ "$ok" -ne 1 ]; then
      ce_warn "price table entry '${model}' の単価に非数値があるため skip（in=${p_in} cached=${p_cached} out=${p_out}）"
      IFS=','; continue
    fi
    printf '%s %s %s %s\n' "$model" "$p_in" "$p_cached" "$p_out"
    IFS=','
  done
  unset IFS
  return 0
}

# モデル ID から単価を解決する。完全一致を優先し、無ければ「表のキーがモデル ID の prefix」に
# なるものの中で最長のキーを採用する（`gpt-5.6-terra-<date>` 等の派生 ID を吸収）。
#   Args: $1 = model / Stdout: "input cached output" or 空 / Returns: 0
ce_lookup_price() {
  local model="${1:-}"
  [ -n "$model" ] || { printf '\n'; return 0; }
  local best_key="" best_vals="" key p_in p_cached p_out exact_vals=""
  while read -r key p_in p_cached p_out; do
    [ -n "$key" ] || continue
    if [ "$key" = "$model" ]; then
      exact_vals="$p_in $p_cached $p_out"   # 後勝ち（override 優先）
      continue
    fi
    case "$model" in
      "$key"*)
        if [ "${#key}" -ge "${#best_key}" ]; then
          best_key="$key"; best_vals="$p_in $p_cached $p_out"
        fi
        ;;
    esac
  done < <(ce_price_table_entries)
  if [ -n "$exact_vals" ]; then
    printf '%s\n' "$exact_vals"
  else
    printf '%s\n' "$best_vals"
  fi
  return 0
}

# token 数と単価から推定 USD を算出する（小数 4 桁）。
#   Args: $1 = input_tokens $2 = cached_input_tokens $3 = output_tokens
#         $4 = price_input $5 = price_cached $6 = price_output（いずれも per 1M tokens）
#   Stdout: 例 `0.0123` / Returns: 0
ce_estimate_usd() {
  awk -v i="${1:-0}" -v c="${2:-0}" -v o="${3:-0}" -v pi="${4:-0}" -v pc="${5:-0}" -v po="${6:-0}" '
    BEGIN {
      i += 0; c += 0; o += 0
      if (c > i) c = i          # 防御: cached が input を超える不整合は全量 cached とみなす
      uncached = i - c
      usd = (uncached * pi + c * pc + o * po) / 1000000
      printf "%.4f\n", usd
    }'
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# run-summary 連携（サイクル合算）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# run 合算状態を初期化する（rs_init から前方参照で呼ばれる。未呼び出しでも ${VAR:-} で安全）。
ce_reset_run_totals() {
  RUN_SUMMARY_COST_USD_TOTAL='0.0000'
  RUN_SUMMARY_COST_PRICED_STAGES=0
  RUN_SUMMARY_COST_UNKNOWN_STAGES=0
  return 0
}

# 1 stage の推定コストを run 合算へ記録する。
#   Args: $1 = usd（小数）or `unknown`
ce_record_stage_cost() {
  local v="${1:-unknown}"
  if [ "$v" = "unknown" ]; then
    RUN_SUMMARY_COST_UNKNOWN_STAGES=$(( ${RUN_SUMMARY_COST_UNKNOWN_STAGES:-0} + 1 ))
    return 0
  fi
  RUN_SUMMARY_COST_USD_TOTAL=$(awk -v a="${RUN_SUMMARY_COST_USD_TOTAL:-0}" -v b="$v" 'BEGIN { printf "%.4f\n", a + b }')
  RUN_SUMMARY_COST_PRICED_STAGES=$(( ${RUN_SUMMARY_COST_PRICED_STAGES:-0} + 1 ))
  return 0
}

# run-summary 行の末尾に付ける ` cost-usd=<sum|unknown|none> cost-unknown-stages=<n>`（先頭空白込み）。
# 無効時は空文字（run-summary の既存フォーマットを一切変えない）。
ce_run_summary_suffix() {
  ce_is_enabled || { printf ''; return 0; }
  local priced="${RUN_SUMMARY_COST_PRICED_STAGES:-0}" unknown="${RUN_SUMMARY_COST_UNKNOWN_STAGES:-0}"
  local total
  if [ "$priced" -gt 0 ]; then
    total="${RUN_SUMMARY_COST_USD_TOTAL:-0.0000}"
  elif [ "$unknown" -gt 0 ]; then
    total='unknown'
  else
    total='none'
  fi
  printf ' cost-usd=%s cost-unknown-stages=%s' "$total" "$unknown"
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Stage log 連携
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# `stage tokens ...` ログ行の末尾に併記する文字列（先頭空白込み）を生成し、run 合算へ記録する。
#   Args: $1 = model（空なら unknown）$2 = input_tokens $3 = cached_input_tokens $4 = output_tokens
#   Stdout: ` model=<id> cost_usd=<usd|unknown>` / 無効時は空文字 / Returns: 0
ce_stage_cost_suffix() {
  ce_is_enabled || { printf ''; return 0; }
  local model="${1:-}" input="${2:-0}" cached="${3:-0}" output="${4:-0}"
  local safe_model prices usd
  if [ -z "$model" ]; then
    ce_record_stage_cost unknown
    printf ' model=unknown cost_usd=unknown'
    return 0
  fi
  safe_model="$(ce_sanitize_model "$model")"
  prices="$(ce_lookup_price "$model")"
  if [ -z "$prices" ]; then
    ce_record_stage_cost unknown
    printf ' model=%s cost_usd=unknown' "$safe_model"
    return 0
  fi
  # shellcheck disable=SC2086  # prices は "in cached out" の空白区切り 3 値（自前生成・検証済み）
  usd="$(ce_estimate_usd "$input" "$cached" "$output" $prices)"
  ce_record_stage_cost "$usd"
  printf ' model=%s cost_usd=%s' "$safe_model" "$usd"
  return 0
}
