#!/usr/bin/env bash
# shellcheck shell=bash
# guard-hook.sh — watcher の Codex PreToolUse Guard Hook 注入モジュール (#294)
#
# 用途:
#   Codex CLI の PreToolUse フック機構を利用して base ブランチ宛 push / 無条件 force
#   push / guard install dir の自己改変を機械 deny する初版（G0 + G1 + G2）を、watcher
#   の Codex CLI 起動時に opt-in で配線するためのヘルパ関数を集約する。本モジュールは
#   hook 本体（local-watcher/hooks/idd-codex-guard.sh）を user-scope の
#   `$IDD_CODEX_HOOKS_DIR`（既定 `$HOME/.idd-codex/hooks`）に、Codex profile config を
#   `${CODEX_HOME:-$HOME/.codex}/idd-codex-guard.config.toml` に install.sh が配置している
#   前提のもとで、watcher 側の preflight ゲートと Codex profile 引数構築を担う。
#
# 配置先:
#   $HOME/bin/idd-codex-modules/guard-hook.sh（install.sh が local-watcher/bin/idd-codex-modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$REPO / $BASE_BRANCH / $CODEX_BIN / $IDD_CODEX_HOOKS_ENABLED 等）は
#     本体冒頭の Config ブロックで定義済み。bash の遅延束縛により呼び出し時に解決される。

guard_log() {
  echo "[$(date '+%F %T')] [${REPO:-?}] guard-hook: $*"
}
guard_warn() {
  echo "[$(date '+%F %T')] [${REPO:-?}] guard-hook: WARN: $*" >&2
}
guard_error() {
  echo "[$(date '+%F %T')] [${REPO:-?}] guard-hook: ERROR: $*" >&2
}

guard_is_enabled() {
  [ "${IDD_CODEX_HOOKS_ENABLED:-}" = "true" ]
}

guard_trim_trailing_slashes() {
  local p="$1"
  while [ ${#p} -gt 1 ] && [ "${p: -1}" = "/" ]; do
    p="${p%/}"
  done
  printf '%s' "$p"
}

guard_resolve_dir() {
  guard_trim_trailing_slashes "${IDD_CODEX_HOOKS_DIR:-$HOME/.idd-codex/hooks}"
}

guard_resolve_config_dir() {
  guard_trim_trailing_slashes "${IDD_CODEX_HOOKS_CONFIG_DIR:-${CODEX_HOME:-$HOME/.codex}}"
}

guard_resolve_profile_name() {
  printf '%s' "${IDD_CODEX_HOOKS_PROFILE_NAME:-idd-codex-guard}"
}

guard_resolve_config_file() {
  local config_dir profile_name
  config_dir="$(guard_resolve_config_dir)"
  profile_name="$(guard_resolve_profile_name)"
  printf '%s/%s.config.toml' "$config_dir" "$profile_name"
}

guard_compare_semver() {
  idd_compare_semver "$1" "$2"
}

guard_export_env() {
  export IDD_HOOK_BASE_BRANCH="${BASE_BRANCH:-main}"
  export IDD_CODEX_HOOKS_DIR
  IDD_CODEX_HOOKS_DIR="$(guard_resolve_dir)"
  export IDD_CODEX_HOOKS_CONFIG_FILE
  IDD_CODEX_HOOKS_CONFIG_FILE="$(guard_resolve_config_file)"
}

guard_preflight() {
  if ! guard_is_enabled; then
    return 0
  fi

  guard_export_env

  local min_version="${IDD_CODEX_HOOKS_MIN_VERSION:-0.0.0}"
  if ! command -v "$CODEX_BIN" >/dev/null 2>&1 && [ ! -x "$CODEX_BIN" ]; then
    guard_error "Codex CLI が PATH 上に見つかりません（IDD_CODEX_HOOKS_ENABLED=true 時は必須）: $CODEX_BIN"
    return 11
  fi

  local raw_version detected
  raw_version="$("$CODEX_BIN" --version 2>/dev/null || true)"
  detected="$(idd_extract_semver "$raw_version" || true)"
  if [ -z "$detected" ]; then
    guard_error "codex --version の出力から version を抽出できませんでした（raw='$raw_version'）"
    guard_error "Codex CLI が正常か確認し、IDD_CODEX_HOOKS_MIN_VERSION の前提を見直してください"
    return 11
  fi
  if ! guard_compare_semver "$detected" "$min_version"; then
    guard_error "codex version $detected は最小要件 $min_version を満たしません"
    guard_error "Codex CLI を $min_version 以上に更新するか、IDD_CODEX_HOOKS_MIN_VERSION を緩めてください"
    return 11
  fi
  guard_log "preflight version ok detected=$detected min=$min_version"

  local hooks_dir hook_script hook_config
  hooks_dir="$(guard_resolve_dir)"
  hook_script="$hooks_dir/idd-codex-guard.sh"
  hook_config="$(guard_resolve_config_file)"
  if [ ! -f "$hook_script" ] || [ ! -f "$hook_config" ]; then
    guard_error "guard hook install が不完全です"
    [ ! -f "$hook_script" ] && guard_error "  missing: $hook_script"
    [ ! -f "$hook_config" ] && guard_error "  missing: $hook_config"
    guard_error "install.sh --local を再実行して hook 一式を配置してください"
    return 12
  fi
  if [ ! -x "$hook_script" ]; then
    guard_error "guard hook script に実行権限がありません: $hook_script"
    return 12
  fi
  if ! grep -F "$hook_script" "$hook_config" >/dev/null 2>&1; then
    guard_error "guard hook profile config が hook script を参照していません: $hook_config"
    guard_error "install.sh --local を再実行して generated config を更新してください"
    return 12
  fi
  guard_log "preflight install ok hook=$hook_script config=$hook_config"

  local smoke_input smoke_stdout smoke_rc
  smoke_input='{"tool_name":"Bash","tool_input":{"command":"echo idd-codex-guard-smoke-ok"}}'
  smoke_stdout="$(printf '%s' "$smoke_input" | bash "$hook_script" 2>&1)" && smoke_rc=0 || smoke_rc=$?
  if [ "$smoke_rc" -ne 0 ]; then
    guard_error "guard hook smoke test が非ゼロ exit しました（rc=$smoke_rc）"
    guard_error "  hook stdout/stderr 末尾: $(printf '%s' "$smoke_stdout" | tail -n 3)"
    return 13
  fi
  if printf '%s' "$smoke_stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    guard_error "guard hook smoke test が想定外に deny を返しました"
    guard_error "  hook stdout: $smoke_stdout"
    return 13
  fi
  guard_log "preflight smoke test ok"
  return 0
}

guard_build_args() {
  # shellcheck disable=SC2034  # CODEX_HOOK_ARGS is consumed by issue-watcher.sh call sites
  CODEX_HOOK_ARGS=()
  if ! guard_is_enabled; then
    return 0
  fi
  guard_export_env
  # shellcheck disable=SC2034  # CODEX_HOOK_ARGS is consumed by issue-watcher.sh call sites
  CODEX_HOOK_ARGS=(--profile "$(guard_resolve_profile_name)" --enable hooks --dangerously-bypass-hook-trust)
}
