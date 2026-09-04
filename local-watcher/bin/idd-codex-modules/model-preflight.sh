#!/usr/bin/env bash
# shellcheck shell=bash
# model-preflight.sh — Codex model と CLI version の preflight 判定モジュール (#175)
#
# 用途:
#   Codex CLI 起動前に、指定 model が要求する最低 Codex CLI version を満たすか判定する。
#   また、Codex CLI 実行後の stream / stderr artifact から model-not-found 系の設定エラーを
#   分類し、既存 failure handler が escalation comment へ補足できる markdown fragment を提供する。
#
# 配置先:
#   $HOME/bin/idd-codex-modules/model-preflight.sh（install.sh が local-watcher/bin/idd-codex-modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - `idd_extract_semver` / `idd_compare_semver` は core_utils.sh で定義済み。
#   - グローバル変数（$REPO / $CODEX_BIN / $MODEL_PREFLIGHT_ENABLED /
#     $MODEL_PREFLIGHT_MIN_VERSIONS）は本体 Config ブロックで定義または環境から供給される。
#
# セットアップ参照先:
#   README.md（モデル preflight / troubleshooting） / install.sh（配置ロジック）

MP_MODEL_CONFIG_ERROR_RC=78

mp_log() {
  echo "[$(date '+%F %T')] [${REPO:-?}] model-preflight: $*" >&2
}

mp_warn() {
  echo "[$(date '+%F %T')] [${REPO:-?}] model-preflight: WARN: $*" >&2
}

mp_error() {
  echo "[$(date '+%F %T')] [${REPO:-?}] model-preflight: ERROR: $*" >&2
}

mp_clear_last_config_error() {
  MP_LAST_CONFIG_ERROR_KIND=""
  MP_LAST_CONFIG_ERROR_STAGE=""
  MP_LAST_CONFIG_ERROR_MODEL=""
  MP_LAST_CONFIG_ERROR_REASON=""
  MP_LAST_CONFIG_ERROR_ARTIFACT=""
}

mp_sanitize_token() {
  printf '%s' "${1:-unknown}" | tr -c 'A-Za-z0-9_.=+/-' '_'
}

mp_sanitize_excerpt() {
  local value="${1:-}"
  value="$(printf '%s' "$value" | tr '\r\n\t' '   ')"
  value="${value:0:180}"
  printf '%s' "$value"
}

mp_record_config_error() {
  local kind="$1"
  local stage_label="$2"
  local model_id="$3"
  local reason="$4"
  local artifact="${5:-}"

  MP_LAST_CONFIG_ERROR_KIND="$kind"
  MP_LAST_CONFIG_ERROR_STAGE="$stage_label"
  MP_LAST_CONFIG_ERROR_MODEL="$model_id"
  MP_LAST_CONFIG_ERROR_REASON="$reason"
  MP_LAST_CONFIG_ERROR_ARTIFACT="$artifact"
}

mp_is_enabled() {
  [ "${MODEL_PREFLIGHT_ENABLED:-true}" != "false" ]
}

mp_default_min_versions() {
  printf '%s' 'gpt-5.6-*:0.144.0'
}

mp_trim() {
  local value="${1:-}"
  while [ -n "$value" ]; do
    case "${value:0:1}" in
      " "|$'\t'|$'\r'|$'\n') value="${value:1}" ;;
      *) break ;;
    esac
  done
  while [ -n "$value" ]; do
    case "${value: -1}" in
      " "|$'\t'|$'\r'|$'\n') value="${value:0:${#value}-1}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$value"
}

mp_min_versions_spec() {
  if [ "${MODEL_PREFLIGHT_MIN_VERSIONS+x}" = "x" ]; then
    printf '%s' "$MODEL_PREFLIGHT_MIN_VERSIONS"
  else
    mp_default_min_versions
  fi
}

mp_warn_malformed_entry() {
  local entry="$1"
  local reason="$2"
  mp_warn "malformed MODEL_PREFLIGHT_MIN_VERSIONS entry skipped reason=${reason} entry=${entry}"
}

mp_is_valid_min_version() {
  local min_version="$1"
  local rc=0
  idd_compare_semver "$min_version" "0.0.0" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 2 ]
}

mp_model_matches_pattern() {
  local model_id="$1"
  local pattern="$2"
  # MODEL_PREFLIGHT_MIN_VERSIONS の pattern は shell glob として扱う契約。
  # shellcheck disable=SC2254
  case "$model_id" in
    $pattern) return 0 ;;
    *) return 1 ;;
  esac
}

mp_entry_required_version_for_model() {
  local entry="$1"
  local model_id="$2"
  local pattern min_version

  entry="$(mp_trim "$entry")"
  if [ -z "$entry" ]; then
    return 1
  fi
  if [ "$entry" = "${entry#*:}" ]; then
    mp_warn_malformed_entry "$entry" "missing-colon"
    return 1
  fi

  pattern="$(mp_trim "${entry%%:*}")"
  min_version="$(mp_trim "${entry#*:}")"
  if [ -z "$pattern" ]; then
    mp_warn_malformed_entry "$entry" "empty-pattern"
    return 1
  fi
  if [ -z "$min_version" ]; then
    mp_warn_malformed_entry "$entry" "empty-version"
    return 1
  fi
  if [ "$min_version" != "${min_version%%:*}" ]; then
    mp_warn_malformed_entry "$entry" "too-many-fields"
    return 1
  fi
  if ! mp_is_valid_min_version "$min_version"; then
    mp_warn_malformed_entry "$entry" "invalid-version"
    return 1
  fi

  if mp_model_matches_pattern "$model_id" "$pattern"; then
    printf '%s' "$min_version"
    return 0
  fi
  return 1
}

# model ID に対応する最低 Codex CLI version を解決する。
# MODEL_PREFLIGHT_MIN_VERSIONS が設定されている場合は既定 map の代わりに override map を使う。
# Args:
#   $1 = model id
# Stdout:
#   minimum version if known; empty if unknown
# Returns:
#   0 always（malformed entry は WARN して skip）
mp_required_version_for_model() {
  local model_id="${1:-}"
  local spec entry required matched_required=""

  spec="$(mp_min_versions_spec)"
  [ -z "$spec" ] && return 0

  local old_ifs="$IFS"
  IFS=','
  # shellcheck disable=SC2206
  local -a entries=($spec)
  IFS="$old_ifs"

  for entry in "${entries[@]}"; do
    required="$(mp_entry_required_version_for_model "$entry" "$model_id" || true)"
    if [ -n "$required" ] && [ -z "$matched_required" ]; then
      matched_required="$required"
    fi
  done
  if [ -n "$matched_required" ]; then
    printf '%s' "$matched_required"
  fi
  return 0
}

mp_extract_codex_version() {
  local codex_bin="${CODEX_BIN:-codex}"
  local raw_version detected

  if ! command -v "$codex_bin" >/dev/null 2>&1 && [ ! -x "$codex_bin" ]; then
    return 1
  fi

  if ! raw_version="$("$codex_bin" --version 2>&1)"; then
    return 2
  fi
  detected="$(idd_extract_semver "$raw_version" || true)"
  if [ -z "$detected" ]; then
    printf '%s' "$raw_version"
    return 3
  fi
  printf '%s' "$detected"
  return 0
}

mp_log_fail_fast() {
  local stage_label="$1"
  local model_id="$2"
  local current_version="$3"
  local required_version="$4"
  local reason="$5"

  mp_error "fail-fast stage=${stage_label} model=${model_id} current=${current_version} required=${required_version} reason=${reason}"
  mp_error "設定エラーの可能性があります。Codex CLI を更新してください: codex update"
  mp_record_config_error "preflight" "$stage_label" "$model_id" "$reason" ""
}

# Codex 起動前の model version preflight。
# Args:
#   $1 = stage label
#   $2 = model id
# Returns:
#   0 = pass / unknown / disabled
#   78 = model config error fail-fast
mp_preflight_model() {
  local stage_label="${1:-unknown}"
  local model_id="${2:-}"

  if ! mp_is_enabled; then
    mp_log "disabled stage=${stage_label} model=${model_id} reason=env-opt-out"
    return 0
  fi

  local required_version
  required_version="$(mp_required_version_for_model "$model_id")"
  if [ -z "$required_version" ]; then
    return 0
  fi

  local current_version codex_rc=0 compare_rc=0
  current_version="$(mp_extract_codex_version)" || codex_rc=$?
  case "$codex_rc" in
    0) ;;
    1)
      mp_log_fail_fast "$stage_label" "$model_id" "unavailable" "$required_version" "codex-command-not-found"
      return "$MP_MODEL_CONFIG_ERROR_RC"
      ;;
    2)
      mp_log_fail_fast "$stage_label" "$model_id" "unavailable" "$required_version" "codex-version-command-failed"
      return "$MP_MODEL_CONFIG_ERROR_RC"
      ;;
    3)
      mp_log_fail_fast "$stage_label" "$model_id" "unparseable" "$required_version" "version-unparseable"
      mp_error "codex --version raw output: ${current_version}"
      return "$MP_MODEL_CONFIG_ERROR_RC"
      ;;
    *)
      mp_log_fail_fast "$stage_label" "$model_id" "unavailable" "$required_version" "codex-version-unknown-error"
      return "$MP_MODEL_CONFIG_ERROR_RC"
      ;;
  esac

  idd_compare_semver "$current_version" "$required_version" >/dev/null 2>&1 || compare_rc=$?
  case "$compare_rc" in
    0)
      mp_log "preflight ok stage=${stage_label} model=${model_id} current=${current_version} required=${required_version}"
      return 0
      ;;
    1)
      mp_log_fail_fast "$stage_label" "$model_id" "$current_version" "$required_version" "codex-cli-version-insufficient"
      return "$MP_MODEL_CONFIG_ERROR_RC"
      ;;
    *)
      mp_log_fail_fast "$stage_label" "$model_id" "$current_version" "$required_version" "semver-compare-invalid"
      return "$MP_MODEL_CONFIG_ERROR_RC"
      ;;
  esac
}

mp_detect_model_error_line() {
  local line="${1:-}"
  local lower
  lower="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"

  case "$lower" in
    *"model not found"*) printf '%s\n' "model-not-found"; return 0 ;;
    *"unsupported model"*) printf '%s\n' "unsupported-model"; return 0 ;;
    *"unknown model"*) printf '%s\n' "unknown-model"; return 0 ;;
    *"model"*"does not exist"*) printf '%s\n' "model-does-not-exist"; return 0 ;;
    *"model"*"not available for your account"*) printf '%s\n' "model-not-available-for-account"; return 0 ;;
    *"not available for your account"*"model"*) printf '%s\n' "model-not-available-for-account"; return 0 ;;
    *) return 1 ;;
  esac
}

# Codex stderr / stream artifact から model 設定エラー候補を検出する。
# Args:
#   $1 = model id
#   $2... = artifact path
# Stdout:
#   <reason>\t<sanitized excerpt>\t<artifact path>
# Returns:
#   0 = detected
#   1 = not detected
#   2 = no readable artifact
mp_detect_model_error() {
  local model_id="${1:-}"
  shift || true

  local artifact line reason readable="false"
  for artifact in "$@"; do
    [ -n "$artifact" ] || continue
    [ -r "$artifact" ] || continue
    readable="true"
    while IFS= read -r line || [ -n "$line" ]; do
      reason="$(mp_detect_model_error_line "$line" || true)"
      if [ -n "$reason" ]; then
        printf '%s\t%s\t%s\n' "$reason" "$(mp_sanitize_excerpt "$line")" "$artifact"
        return 0
      fi
    done < "$artifact"
  done

  if [ "$readable" = "true" ]; then
    return 1
  fi
  mp_warn "model error classifier skipped reason=artifact-unreadable model=${model_id}"
  return 2
}

mp_classify_stage_model_error() {
  local stage_label="$1"
  local model_id="$2"
  shift 2

  local detected="" rc=0 reason excerpt artifact
  detected="$(mp_detect_model_error "$model_id" "$@")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi

  IFS=$'\t' read -r reason excerpt artifact <<<"$detected"
  mp_record_config_error "post-run" "$stage_label" "$model_id" "$reason" "$artifact"
  mp_error "model-config-error stage=$(mp_sanitize_token "$stage_label") model=$(mp_sanitize_token "$model_id") reason=$(mp_sanitize_token "$reason") artifact=${artifact} excerpt=$(mp_sanitize_excerpt "$excerpt")"
  return 0
}

mp_classify_codex_failure() {
  local stage_label="$1"
  local model_id="$2"
  local codex_rc="$3"
  shift 3

  if [ "$codex_rc" -eq "${MP_MODEL_CONFIG_ERROR_RC:-78}" ]; then
    local artifact="${1:-}"
    mp_record_config_error "preflight" "$stage_label" "${model_id:-unknown}" "model-preflight-failed" "$artifact"
    mp_error "model-config-error stage=$(mp_sanitize_token "$stage_label") model=$(mp_sanitize_token "${model_id:-unknown}") reason=model-preflight-failed artifact=${artifact}"
    return 0
  fi

  if [ "$codex_rc" -ne 0 ] && [ -n "$model_id" ]; then
    mp_classify_stage_model_error "$stage_label" "$model_id" "$@"
    return $?
  fi

  mp_clear_last_config_error
  return 1
}

mp_build_config_error_summary() {
  local kind="$1"
  local stage_label="$2"
  local model_id="$3"
  local reason="$4"
  local artifact="${5:-}"
  local safe_kind safe_stage safe_model safe_reason safe_artifact
  safe_kind="$(mp_sanitize_token "$kind")"
  safe_stage="$(mp_sanitize_token "$stage_label")"
  safe_model="$(mp_sanitize_token "$model_id")"
  safe_reason="$(mp_sanitize_token "$reason")"
  safe_artifact="${artifact//\`/_}"

  cat <<EOF

---

### モデル設定エラーの可能性

- stage: \`${safe_stage}\`
- model: \`${safe_model}\`
- kind: \`${safe_kind}\`
- reason: \`${safe_reason}\`
EOF
  if [ -n "$artifact" ]; then
    printf '%s\n' "- diagnostic artifact: \`${safe_artifact}\`"
  fi
  cat <<'EOF'
- recommended action: `codex update` を実行して Codex CLI を更新し、指定 model ID / `MODEL_PREFLIGHT_MIN_VERSIONS` / 各 `*_MODEL` env var を確認してください。
EOF
}

mp_build_last_config_error_summary() {
  if [ -z "${MP_LAST_CONFIG_ERROR_KIND:-}" ]; then
    return 0
  fi
  mp_build_config_error_summary \
    "$MP_LAST_CONFIG_ERROR_KIND" \
    "${MP_LAST_CONFIG_ERROR_STAGE:-unknown}" \
    "${MP_LAST_CONFIG_ERROR_MODEL:-unknown}" \
    "${MP_LAST_CONFIG_ERROR_REASON:-unknown}" \
    "${MP_LAST_CONFIG_ERROR_ARTIFACT:-}"
}

mp_clear_last_config_error
