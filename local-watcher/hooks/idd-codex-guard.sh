#!/usr/bin/env bash
# idd-codex-guard.sh
#
# 用途: Codex CLI の PreToolUse フックとして起動され、Bash / apply_patch /
#       Edit / Write / NotebookEdit ツール呼び出しを検査して以下のいずれかに該当すれば deny する。
#       - G1: base ブランチ (`$IDD_HOOK_BASE_BRANCH`) 宛の push（`HEAD:base` /
#             `:base` / `+base` / `-C path` / 暗黙 remote / `--delete` を含む）
#       - G2: 無条件 force push（`-f` / `--force` / refspec 先頭 `+`）。
#             `--force-with-lease(=...)` は base 以外なら allow。
#       - G0: guard install dir (`$IDD_CODEX_HOOKS_DIR`、既定 `$HOME/.idd-codex/hooks`)
#             または generated profile config (`$IDD_CODEX_HOOKS_CONFIG_FILE`) への
#             Edit / Write / NotebookEdit / apply_patch、および Bash 経由の mutation
#             コマンド（`rm` / `mv` / `sed -i` / `chmod` / リダイレクト / `tee`）。
#
# 配置先: $IDD_CODEX_HOOKS_DIR/idd-codex-guard.sh
#          （install.sh が user-scope `$HOME/.idd-codex/hooks/` 既定で配置）
#
# 依存: bash 4+, jq
#
# 環境変数契約:
#   IDD_HOOK_BASE_BRANCH          base ブランチ名。未設定で `main` フォールバック
#   IDD_CODEX_HOOKS_DIR           guard install dir。未設定で `$HOME/.idd-codex/hooks`
#   IDD_CODEX_HOOKS_CONFIG_FILE   generated Codex profile config
#   IDD_HOOK_LOG                  設定時は 1 行 append（任意）
#
# stdin / stdout:
#   stdin  : Codex PreToolUse JSON（`tool_name` / `tool_input` を含む）
#   stdout : decision JSON
#            - deny: hookSpecificOutput.permissionDecision = "deny"
#            - allow: {}
#   exit code: 常に 0（allow も deny も exit 0。エラーは fail-closed で deny JSON）
#
# セットアップ参照先: README.md（同ディレクトリ）

set -euo pipefail

hook_log() {
  local log_path="${IDD_HOOK_LOG:-}"
  [ -z "$log_path" ] && return 0
  printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" >>"$log_path" 2>/dev/null || true
}

emit_allow() {
  printf '{}\n'
  hook_log "allow" "${1:-}"
  exit 0
}

emit_deny() {
  local reason="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg reason "$reason" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
  else
    local escaped="${reason//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$escaped"
  fi
  hook_log "deny" "$reason"
  exit 0
}

emit_deny_fail_closed() {
  emit_deny "guard hook internal error: $1"
}

trim_trailing_slashes() {
  local p="$1"
  while [ ${#p} -gt 1 ] && [ "${p: -1}" = "/" ]; do
    p="${p%/}"
  done
  printf '%s' "$p"
}

resolve_hooks_dir() {
  trim_trailing_slashes "${IDD_CODEX_HOOKS_DIR:-$HOME/.idd-codex/hooks}"
}

resolve_config_file() {
  local default_config="${CODEX_HOME:-$HOME/.codex}/idd-codex-guard.config.toml"
  printf '%s' "${IDD_CODEX_HOOKS_CONFIG_FILE:-$default_config}"
}

normalize_path() {
  local p="$1"
  # shellcheck disable=SC2088
  local tilde_slash='~/'
  # shellcheck disable=SC2088
  local tilde='~'
  if [ "${p:0:2}" = "$tilde_slash" ]; then
    p="$HOME/${p:2}"
  elif [ "$p" = "$tilde" ]; then
    p="$HOME"
  fi
  trim_trailing_slashes "$p"
}

is_protected_path() {
  local target_path="$1"
  local hooks_dir config_file normalized
  hooks_dir="$(resolve_hooks_dir)"
  config_file="$(normalize_path "$(resolve_config_file)")"
  normalized="$(normalize_path "$target_path")"
  case "$normalized" in
    "$hooks_dir"|"$hooks_dir"/*|"$config_file")
      return 0
      ;;
  esac
  return 1
}

check_g0_path() {
  local target_path="$1"
  local normalized
  normalized="$(normalize_path "$target_path")"
  if is_protected_path "$normalized"; then
    emit_deny "guard self-mutation denied: path=$normalized"
  fi
}

command_mentions_protected_path() {
  local cmd="$1"
  local hooks_dir config_file
  hooks_dir="$(resolve_hooks_dir)"
  config_file="$(normalize_path "$(resolve_config_file)")"
  # shellcheck disable=SC2088
  local tilde_hooks='~/.idd-codex/hooks'
  # shellcheck disable=SC2016
  local home_hooks='$HOME/.idd-codex/hooks'
  # shellcheck disable=SC2088
  local tilde_config='~/.codex/idd-codex-guard.config.toml'
  # shellcheck disable=SC2016
  local codex_home_config='$CODEX_HOME/idd-codex-guard.config.toml'
  if [[ "$cmd" == *"$hooks_dir"* ]] || [[ "$cmd" == *"$config_file"* ]] \
       || [[ "$cmd" == *"$tilde_hooks"* ]] || [[ "$cmd" == *"$home_hooks"* ]] \
       || [[ "$cmd" == *"$tilde_config"* ]] || [[ "$cmd" == *"$codex_home_config"* ]]; then
    return 0
  fi
  return 1
}

check_g0_bash() {
  local cmd="$1"
  command_mentions_protected_path "$cmd" || return 0

  if [[ "$cmd" =~ (^|[[:space:];&|])(rm|mv|chmod|tee)([[:space:]]|$) ]] \
       || [[ "$cmd" =~ sed[[:space:]]+-i ]] \
       || [[ "$cmd" =~ [[:space:]]\>\>?[[:space:]] ]] \
       || [[ "$cmd" =~ [[:space:]]\>\>?$ ]] \
       || [[ "$cmd" =~ cat[[:space:]]+\> ]]; then
    emit_deny "guard self-mutation denied: protected path mentioned in mutating Bash command"
  fi
}

check_g0_patch_payload() {
  local payload="$1"
  command_mentions_protected_path "$payload" || return 0
  emit_deny "guard self-mutation denied: protected path mentioned in apply_patch payload"
}

extract_push_tokens() {
  PUSH_TOKENS=()
  local -a in=("$@")
  local n=${#in[@]}
  [ "$n" -lt 2 ] && return 0
  [ "${in[0]}" != "git" ] && return 0

  local i=1
  while [ "$i" -lt "$n" ]; do
    local tok="${in[$i]}"
    case "$tok" in
      -C)
        i=$((i + 2))
        ;;
      --git-dir=*|--work-tree=*|--namespace=*)
        i=$((i + 1))
        ;;
      --git-dir|--work-tree|--namespace)
        i=$((i + 2))
        ;;
      -c)
        i=$((i + 2))
        ;;
      -c=*|--config-env=*)
        i=$((i + 1))
        ;;
      --exec-path=*|--exec-path)
        i=$((i + 1))
        ;;
      --*|-*)
        i=$((i + 1))
        ;;
      push)
        local j=$((i + 1))
        while [ "$j" -lt "$n" ]; do
          PUSH_TOKENS+=("${in[$j]}")
          j=$((j + 1))
        done
        return 0
        ;;
      *)
        return 0
        ;;
    esac
  done
}

extract_dst_from_refspec() {
  local rs="$1"
  [ "${rs:0:1}" = "+" ] && rs="${rs:1}"
  if [[ "$rs" == *:* ]]; then
    printf '%s' "${rs#*:}"
  else
    printf '%s' "$rs"
  fi
}

refspec_has_plus_prefix() {
  [ "${1:0:1}" = "+" ]
}

analyze_push() {
  local base_branch="${IDD_HOOK_BASE_BRANCH:-main}"
  local -a tokens=("$@")
  local n=${#tokens[@]}
  [ "$n" -eq 0 ] && return 0

  local has_force=0
  local has_delete=0
  local i=0
  while [ "$i" -lt "$n" ]; do
    case "${tokens[$i]}" in
      -f|--force)
        has_force=1
        ;;
      --force-with-lease|--force-with-lease=*)
        ;;
      -d|--delete)
        has_delete=1
        ;;
    esac
    i=$((i + 1))
  done

  local -a positional=()
  i=0
  while [ "$i" -lt "$n" ]; do
    local t="${tokens[$i]}"
    case "$t" in
      -*)
        ;;
      *)
        positional+=("$t")
        ;;
    esac
    i=$((i + 1))
  done

  local -a refspecs=()
  local p_count=${#positional[@]}
  if [ "$p_count" -eq 0 ]; then
    :
  elif [ "$p_count" -eq 1 ]; then
    local p0="${positional[0]}"
    if [[ "$p0" == *:* ]] || [ "${p0:0:1}" = "+" ]; then
      refspecs+=("$p0")
    elif [ "$p0" = "$base_branch" ] || [ "$p0" = "refs/heads/$base_branch" ]; then
      refspecs+=("$p0")
    elif [ "$has_delete" -eq 1 ]; then
      refspecs+=("$p0")
    fi
  else
    local p0="${positional[0]}"
    if [[ "$p0" == *:* ]] || [ "${p0:0:1}" = "+" ]; then
      refspecs=("${positional[@]}")
    else
      refspecs=("${positional[@]:1}")
    fi
  fi

  local rs
  for rs in "${refspecs[@]:-}"; do
    [ -z "$rs" ] && continue
    local dst
    dst="$(extract_dst_from_refspec "$rs")"
    case "$dst" in
      refs/heads/*)
        dst="${dst#refs/heads/}"
        ;;
    esac
    if [ "$dst" = "$base_branch" ]; then
      emit_deny "base branch push denied: ref=$rs (base=$base_branch)"
    fi
  done

  if [ "$has_delete" -eq 1 ]; then
    local pp
    for pp in "${positional[@]:-}"; do
      [ -z "$pp" ] && continue
      if [ "$pp" = "$base_branch" ] || [ "$pp" = "refs/heads/$base_branch" ]; then
        emit_deny "base branch push denied: --delete $pp (base=$base_branch)"
      fi
    done
  fi

  if [ "$has_force" -eq 1 ]; then
    emit_deny "unconditional force push denied: use --force-with-lease"
  fi

  for rs in "${refspecs[@]:-}"; do
    [ -z "$rs" ] && continue
    if refspec_has_plus_prefix "$rs"; then
      emit_deny "unconditional force push denied: refspec '+' prefix in '$rs' (use --force-with-lease)"
    fi
  done
}

parse_top_level_tokens() {
  local cmd="$1"
  TOKENS=()
  local i=0
  local n=${#cmd}
  local cur=""
  local in_single=0
  local in_double=0

  while [ "$i" -lt "$n" ]; do
    local c="${cmd:$i:1}"

    if [ "$in_single" -eq 1 ]; then
      if [ "$c" = "'" ]; then
        in_single=0
      else
        cur+="$c"
      fi
      i=$((i + 1))
      continue
    fi

    if [ "$in_double" -eq 1 ]; then
      if [ "$c" = '"' ]; then
        in_double=0
      elif [ "$c" = "\\" ] && [ $((i + 1)) -lt "$n" ]; then
        cur+="${cmd:$((i + 1)):1}"
        i=$((i + 2))
        continue
      else
        cur+="$c"
      fi
      i=$((i + 1))
      continue
    fi

    case "$c" in
      "'")
        in_single=1
        ;;
      '"')
        in_double=1
        ;;
      "\\")
        if [ $((i + 1)) -lt "$n" ]; then
          cur+="${cmd:$((i + 1)):1}"
          i=$((i + 1))
        fi
        ;;
      " "|$'\t')
        if [ -n "$cur" ]; then
          TOKENS+=("$cur")
          cur=""
        fi
        ;;
      $'\n'|";")
        if [ -n "$cur" ]; then
          TOKENS+=("$cur")
          cur=""
        fi
        return 0
        ;;
      "&"|"|")
        if [ -n "$cur" ]; then
          TOKENS+=("$cur")
          cur=""
        fi
        return 0
        ;;
      *)
        cur+="$c"
        ;;
    esac
    i=$((i + 1))
  done

  if [ -n "$cur" ]; then
    TOKENS+=("$cur")
  fi
}

main() {
  if ! command -v jq >/dev/null 2>&1; then
    emit_deny_fail_closed "jq not found in PATH"
  fi

  local input
  input="$(cat || true)"
  [ -z "$input" ] && emit_allow "empty input"

  local tool_name
  if ! tool_name="$(printf '%s' "$input" | jq -er '.tool_name // empty')"; then
    emit_deny_fail_closed "failed to parse PreToolUse JSON (tool_name)"
  fi
  [ -z "$tool_name" ] && emit_allow "no tool_name"

  case "$tool_name" in
    Edit|Write)
      local file_path
      file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
      [ -n "$file_path" ] && check_g0_path "$file_path"
      emit_allow "$tool_name file_path ok"
      ;;
    NotebookEdit)
      local notebook_path
      notebook_path="$(printf '%s' "$input" | jq -r '.tool_input.notebook_path // .tool_input.file_path // empty')"
      [ -n "$notebook_path" ] && check_g0_path "$notebook_path"
      emit_allow "NotebookEdit path ok"
      ;;
    apply_patch|ApplyPatch)
      local file_path patch_payload
      file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
      [ -n "$file_path" ] && check_g0_path "$file_path"
      patch_payload="$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.patch // .tool_input.input // empty')"
      [ -n "$patch_payload" ] && check_g0_patch_payload "$patch_payload"
      emit_allow "apply_patch ok"
      ;;
    Bash|Shell|shell)
      local command_str
      command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
      [ -z "$command_str" ] && emit_allow "$tool_name empty command"

      check_g0_bash "$command_str"

      TOKENS=()
      parse_top_level_tokens "$command_str"

      if [ "${#TOKENS[@]}" -ge 1 ] && [ "${TOKENS[0]}" = "git" ]; then
        PUSH_TOKENS=()
        extract_push_tokens "${TOKENS[@]}"
        if [ -n "${PUSH_TOKENS[*]:-}" ]; then
          analyze_push "${PUSH_TOKENS[@]}"
        fi
      fi

      emit_allow "$tool_name ok"
      ;;
    *)
      emit_allow "tool_name=$tool_name not in scope"
      ;;
  esac
}

main "$@"
