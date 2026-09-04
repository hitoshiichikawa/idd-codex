#!/usr/bin/env bash
# effort-guard.sh — reasoning effort の allowlist 検証と `ultra` の opt-in ガード（Issue #174）
#
# 用途:
#   GPT-5.6 世代（codex-cli 0.144 系）で `model_reasoning_effort` に `max` と `ultra` が追加された。
#   `ultra` はモデル内部でサブエージェントを並列展開するためトークン消費が他 effort と桁違いに
#   跳ねうる。無人 cron 環境では誤設定（typo / 安易な ultra 指定）によるコスト暴発を運用者が
#   気づく前に垂れ流すリスクがあるため、`*_REASONING_EFFORT` を codex に渡す直前で検証する。
#
#   - eg_default_effort_for_stage : stage_label → 組み込み既定 effort（env override 前の literal 値）
#   - eg_is_allowlisted_effort    : allowlist（minimal / low / medium / high / xhigh / max）判定
#   - eg_ultra_allowed            : `CODEX_ALLOW_ULTRA_EFFORT=true` 厳密一致の opt-in gate
#   - eg_normalize_effort         : 検証 + 正規化の単一エントリ（codex_exec_prompt から呼ぶ）
#
# 既定挙動は完全不変（後方互換）:
#   現行の有効値（medium / high 等）はすべて allowlist 内のため、未設定環境・正しい値の環境では
#   導入前と外形等価。allowlist 外の値 / gate 未通過の `ultra` のみが「当該 stage の既定 effort へ
#   正規化 + WARN ログ」に変わる（silent fail を作らない）。
#
# 配置先:
#   $HOME/bin/idd-codex-modules/effort-guard.sh（install.sh が local-watcher/bin/idd-codex-modules/ から配置）
#
# 依存:
#   - 本モジュールは idd-codex-issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー（eg_log / eg_warn / eg_error）は core_utils.sh にあるため再定義しない。
#   - 環境変数: CODEX_ALLOW_ULTRA_EFFORT（既定 false）。
#   - 関数 prefix `eg_` を namespace として採用する。

# ─── allowlist ───
# codex-cli 0.144 系が受け付ける effort のうち、無人運用で常時許可する値。
# `ultra` は意図的に含めず、eg_ultra_allowed の opt-in gate 経由でのみ通す。
EG_EFFORT_ALLOWLIST="minimal low medium high xhigh max"

# stage_label → 組み込み既定 effort（純粋関数 / 副作用なし）。
# codex_reasoning_effort_for_stage が返す env 反映後の値ではなく、本体 Config ブロックの
# literal 既定（Triage=medium / それ以外=high）を返す。allowlist 外の値を検出したとき、
# 誤設定された env 値へ再帰的に fallback しないための固定 anchor。
#   Args: $1 = stage_label / Stdout: effort 文字列 / Returns: 0
eg_default_effort_for_stage() {
  case "${1:-}" in
    Triage|triage) printf 'medium\n' ;;
    *)             printf 'high\n' ;;
  esac
}

# effort が allowlist に含まれるか（lowercase 厳密一致 / 純粋関数）。
#   Args: $1 = effort / Returns: 0 = allowlisted / 1 = 非許可（空文字・typo・大文字混在・ultra 含む）
eg_is_allowlisted_effort() {
  local effort="${1:-}"
  [ -n "$effort" ] || return 1
  case " $EG_EFFORT_ALLOWLIST " in
    *" $effort "*) return 0 ;;
    *)             return 1 ;;
  esac
}

# `ultra` の opt-in gate。`CODEX_ALLOW_ULTRA_EFFORT=true`（lowercase 厳密一致）のみ 0。
# 未設定 / `TRUE` / `1` / `yes` / typo はすべて 1（安全側）。
eg_ultra_allowed() {
  [ "${CODEX_ALLOW_ULTRA_EFFORT:-false}" = "true" ] || return 1
  return 0
}

# ログ埋め込み用に effort 値を安全な文字集合へ丸める（改行 / 制御文字によるログ破壊防止）。
#   Args: $1 = raw / Stdout: sanitized（最大 40 文字）
eg_sanitize_effort_token() {
  printf '%s' "${1:-}" | tr -c 'A-Za-z0-9_.-' '?' | cut -c1-40
}

# 検証 + 正規化の単一エントリ。stdout に「codex へ実際に渡す effort」を 1 行出力する。
#   Args: $1 = stage_label / $2 = raw effort（codex_reasoning_effort_for_stage の戻り値）
#   Stdout: 正規化済み effort / Returns: 常に 0（fail-open: 判定不能でも既定 effort を返す）
#   副作用: allowlist 外 / gate 未通過 ultra のとき eg_warn（stderr）を 1 行出力する。
#           gate 通過 ultra のときもコスト注意として eg_warn を 1 行出力する。
eg_normalize_effort() {
  local stage_label="${1:-}"
  local raw="${2:-}"
  local fallback safe_raw
  fallback="$(eg_default_effort_for_stage "$stage_label")"

  if eg_is_allowlisted_effort "$raw"; then
    printf '%s\n' "$raw"
    return 0
  fi

  safe_raw="$(eg_sanitize_effort_token "$raw")"
  if [ "$raw" = "ultra" ]; then
    if eg_ultra_allowed; then
      eg_warn "stage=${stage_label} effort=ultra を許可（CODEX_ALLOW_ULTRA_EFFORT=true / トークン消費が桁違いに増える可能性に注意）"
      printf 'ultra\n'
      return 0
    fi
    eg_warn "stage=${stage_label} effort='ultra' は CODEX_ALLOW_ULTRA_EFFORT=true（厳密一致）の opt-in が無いため既定 '${fallback}' に正規化（Issue #174）"
    printf '%s\n' "$fallback"
    return 0
  fi

  eg_warn "stage=${stage_label} effort='${safe_raw}' は allowlist（${EG_EFFORT_ALLOWLIST// //}）外のため既定 '${fallback}' に正規化（Issue #174）"
  printf '%s\n' "$fallback"
  return 0
}
