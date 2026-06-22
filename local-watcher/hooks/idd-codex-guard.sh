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
#       - G3: read-only-writer role の書き込みスコープ強制（#80）。`$IDD_HOOK_ROLE` が
#             `reviewer` / `debugger` のとき、許可 notes（reviewer→`review-notes.md` /
#             debugger→`debugger-notes.md`）以外への repo 書き込み（Edit / Write /
#             NotebookEdit / apply_patch）を deny する。temp 配下（/tmp 等）と他 role は無制限。
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
#   IDD_HOOK_ROLE                 当該 stage の role（watcher が export / #80 G3）。
#                                 `reviewer` / `debugger` のとき書き込みスコープを強制。未設定/他値で無制限
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

  # Issue #49: 保護パスを参照する segment では、書込・改変につながる動詞／in-place 編集／
  # 任意のリダイレクトを広めに deny する（defense-in-depth）。旧実装は rm/mv/chmod/tee と
  # 空白付きリダイレクトのみで、cp/ln/dd/truncate/install、空白なし `>file`、引用直後の verb を
  # 取りこぼしていた。verb の前置境界に `(` も含め、bash -c ラッパ内は analyze_bash_command の
  # 再帰で raw segment として再評価される。
  local verb_re='(^|[[:space:];&|(])(rm|rmdir|mv|cp|ln|dd|chmod|chown|chgrp|tee|truncate|install|shred|touch|mkdir|ed)([[:space:]]|$)'
  local inplace_re='(sed|perl|ruby|python3?|gawk|awk)[[:space:]]+(-[A-Za-z]*i|--in-place)'
  if [[ "$cmd" =~ $verb_re ]] \
       || [[ "$cmd" =~ $inplace_re ]] \
       || [[ "$cmd" == *">"* ]]; then
    emit_deny "guard self-mutation denied: protected path mentioned in mutating Bash command"
  fi
}

check_g0_patch_payload() {
  local payload="$1"
  command_mentions_protected_path "$payload" || return 0
  emit_deny "guard self-mutation denied: protected path mentioned in apply_patch payload"
}

# ── G3: read-only-writer role の書き込みスコープ強制 (#80) ──
# Codex には Claude のような per-role tool 制限が無く、全 stage が同一 sandbox で走るため、
# Reviewer / Debugger の「成果物 notes 以外を書かない」境界が prose 頼みだった。本 hook は
# watcher が export する $IDD_HOOK_ROLE を見て、reviewer/debugger role のとき、許可された
# notes ファイル（reviewer→review-notes.md / debugger→debugger-notes.md）以外への repo 書き込みを
# deny する。$IDD_HOOK_ROLE が未設定 / 他 role のときは無制限（後方互換）。
# 注: git commit/push 自体は deny しない（per-task reviewer は review-notes.md を commit するため）。
#     書き込み先を notes に限定することで、commit してもソース改変が混入しないことを担保する。

is_temp_path() {
  local n
  n="$(normalize_path "$1")"
  case "$n" in
    /tmp/*|/var/tmp/*|/private/tmp/*) return 0 ;;
  esac
  if [ -n "${TMPDIR:-}" ]; then
    local t
    t="$(normalize_path "$TMPDIR")"
    case "$n" in "$t"/*|"$t") return 0 ;; esac
  fi
  return 1
}

# $1 = role, $2 = basename。許可されていれば 0、そうでなければ 1。
role_allowed_write_basename() {
  case "$1" in
    reviewer) [ "$2" = "review-notes.md" ] ;;
    debugger) [ "$2" = "debugger-notes.md" ] ;;
    *) return 1 ;;
  esac
}

# read-only-writer role が対象パスへ書き込もうとしている場合、許可 notes 以外なら deny。
check_g3_write() {
  local target_path="$1"
  local role="${IDD_HOOK_ROLE:-}"
  case "$role" in
    reviewer|debugger) ;;
    *) return 0 ;;
  esac
  # repo 外の scratch（/tmp 等）は許容（ソース改変ではないため）。
  is_temp_path "$target_path" && return 0
  local normalized base
  normalized="$(normalize_path "$target_path")"
  base="${normalized##*/}"
  if ! role_allowed_write_basename "$role" "$base"; then
    local allowed
    if [ "$role" = "reviewer" ]; then allowed="review-notes.md"; else allowed="debugger-notes.md"; fi
    emit_deny "role write-scope denied: role=$role は $allowed 以外への書き込みが禁止です: path=$target_path (#80)"
  fi
}

# apply_patch payload のヘッダ（*** Update/Add/Delete File: <path>）から対象パスを抽出し各々 check。
check_g3_patch_payload() {
  local payload="$1"
  local role="${IDD_HOOK_ROLE:-}"
  case "$role" in
    reviewer|debugger) ;;
    *) return 0 ;;
  esac
  local path
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    check_g3_write "$path"
  done < <(printf '%s\n' "$payload" | sed -nE 's/^\*\*\* (Update|Add|Delete) File: (.+)$/\2/p')
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
      --force-with-lease|--force-with-lease=*)
        : # lease 付きは base 以外なら許可（既存仕様を維持）
        ;;
      --force)
        has_force=1
        ;;
      --delete)
        has_delete=1
        ;;
      --*)
        : # その他の long option は無視
        ;;
      -*)
        # Issue #49: 束ねた短 flag（-fu / -uf / -fq ...）も検出する。
        # 旧実装は `-f` 完全一致のみで -fu 等を取りこぼしていた。
        case "${tokens[$i]}" in
          *f*) has_force=1 ;;
        esac
        case "${tokens[$i]}" in
          *d*) has_delete=1 ;;
        esac
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

# Issue #49: コマンド文字列を top-level セパレータ（; 改行 && || | &）で「全 segment」に
# 分割する。旧 parse_top_level_tokens は最初のセパレータで return し先頭 segment しか
# 検査しなかったため、`true; git push --force origin main` 等で全規則がバイパスされた。
# クォート（' "）とバックスラッシュエスケープを尊重し、segment 文字列は原文（クォート込み）
# のまま保持する（G0 の substring 判定・後続の tokenize_segment が利用する）。
split_top_level_segments() {
  local cmd="$1"
  SEGMENTS=()
  local i=0
  local n=${#cmd}
  local cur=""
  local in_single=0
  local in_double=0

  while [ "$i" -lt "$n" ]; do
    local c="${cmd:$i:1}"

    if [ "$in_single" -eq 1 ]; then
      cur+="$c"
      [ "$c" = "'" ] && in_single=0
      i=$((i + 1))
      continue
    fi

    if [ "$in_double" -eq 1 ]; then
      cur+="$c"
      if [ "$c" = '"' ]; then
        in_double=0
      elif [ "$c" = "\\" ] && [ $((i + 1)) -lt "$n" ]; then
        cur+="${cmd:$((i + 1)):1}"
        i=$((i + 2))
        continue
      fi
      i=$((i + 1))
      continue
    fi

    case "$c" in
      "'")
        in_single=1
        cur+="$c"
        ;;
      '"')
        in_double=1
        cur+="$c"
        ;;
      "\\")
        cur+="$c"
        if [ $((i + 1)) -lt "$n" ]; then
          cur+="${cmd:$((i + 1)):1}"
          i=$((i + 1))
        fi
        ;;
      $'\n'|";"|"&"|"|")
        SEGMENTS+=("$cur")
        cur=""
        ;;
      *)
        cur+="$c"
        ;;
    esac
    i=$((i + 1))
  done

  SEGMENTS+=("$cur")
}

# 1 つの segment（top-level セパレータを含まない）を whitespace でトークン化する。
# クォート除去・バックスラッシュエスケープを処理し、結果トークンには区切り文字を残さない。
tokenize_segment() {
  local seg="$1"
  TOKENS=()
  local i=0
  local n=${#seg}
  local cur=""
  local has=0
  local in_single=0
  local in_double=0

  while [ "$i" -lt "$n" ]; do
    local c="${seg:$i:1}"

    if [ "$in_single" -eq 1 ]; then
      if [ "$c" = "'" ]; then in_single=0; else cur+="$c"; has=1; fi
      i=$((i + 1))
      continue
    fi

    if [ "$in_double" -eq 1 ]; then
      if [ "$c" = '"' ]; then
        in_double=0
      elif [ "$c" = "\\" ] && [ $((i + 1)) -lt "$n" ]; then
        cur+="${seg:$((i + 1)):1}"
        has=1
        i=$((i + 2))
        continue
      else
        cur+="$c"
        has=1
      fi
      i=$((i + 1))
      continue
    fi

    case "$c" in
      "'") in_single=1; has=1 ;;
      '"') in_double=1; has=1 ;;
      "\\")
        if [ $((i + 1)) -lt "$n" ]; then
          cur+="${seg:$((i + 1)):1}"
          has=1
          i=$((i + 1))
        fi
        ;;
      " "|$'\t')
        if [ "$has" -eq 1 ]; then TOKENS+=("$cur"); cur=""; has=0; fi
        ;;
      *) cur+="$c"; has=1 ;;
    esac
    i=$((i + 1))
  done

  # NOTE: 末尾を `&&` 結合にすると has=0 のとき rc=1 を返し、set -e の呼び出し元を
  # 巻き込んで途中終了する（末尾空白を含む segment で発覚）。if/fi で rc=0 を保証する。
  if [ "$has" -eq 1 ]; then TOKENS+=("$cur"); fi
  return 0
}

# bash/sh -c "<script>" の inline script 引数を取り出す（再帰解析用）。
# script ファイル実行（-c なし）は inline ではないため空を返す。
extract_dash_c_arg() {
  local -a t=("$@")
  local n=${#t[@]}
  local i=1
  while [ "$i" -lt "$n" ]; do
    case "${t[$i]}" in
      -*c)
        # -c / -lc / -ic 等、c を含む短 option クラスタの直後を inline script とみなす
        if [ $((i + 1)) -lt "$n" ]; then printf '%s' "${t[$((i + 1))]}"; fi
        return 0
        ;;
      -*) i=$((i + 1)) ;;
      *) return 0 ;;
    esac
  done
  return 0
}

# 先頭トークンから env / command / builtin / VAR=... 等の wrapper を剥がし、
# 実コマンドの先頭に正規化する。剥がした結果のトークン列を NORM_TOKENS に設定する。
normalize_leading_tokens() {
  local -a toks=("$@")
  local progressed=1
  while [ "$progressed" -eq 1 ] && [ "${#toks[@]}" -gt 0 ]; do
    progressed=0
    local lead="${toks[0]}"
    local base="${lead##*/}"
    case "$base" in
      env)
        toks=("${toks[@]:1}")
        while [ "${#toks[@]}" -gt 0 ]; do
          case "${toks[0]}" in
            *=*|-*) toks=("${toks[@]:1}") ;;
            *) break ;;
          esac
        done
        progressed=1
        ;;
      command|builtin|exec|nohup|nice|time|stdbuf|setsid|timeout|ionice|sudo|doas)
        toks=("${toks[@]:1}")
        while [ "${#toks[@]}" -gt 0 ]; do
          case "${toks[0]}" in
            -*|*=*) toks=("${toks[@]:1}") ;;
            *) break ;;
          esac
        done
        progressed=1
        ;;
      *=*)
        toks=("${toks[@]:1}")
        progressed=1
        ;;
    esac
  done
  NORM_TOKENS=("${toks[@]:-}")
}

# Bash コマンド全体を解析する。全 segment を走査し、segment ごとに
#   - G0 自己改変チェック（raw segment 文字列）
#   - 先頭トークン正規化 → git なら push 解析、bash/sh -c なら inline script を再帰解析
# を行う。深さ制限で再帰爆発を防ぐ。
analyze_bash_command() {
  local cmd="$1"
  local depth="${2:-0}"
  [ "$depth" -ge 6 ] && return 0

  SEGMENTS=()
  split_top_level_segments "$cmd"

  local seg
  for seg in "${SEGMENTS[@]:-}"; do
    [ -z "${seg//[[:space:]]/}" ] && continue

    check_g0_bash "$seg"

    TOKENS=()
    tokenize_segment "$seg"
    [ "${#TOKENS[@]}" -eq 0 ] && continue

    NORM_TOKENS=()
    normalize_leading_tokens "${TOKENS[@]}"
    [ "${#NORM_TOKENS[@]}" -eq 0 ] && continue

    local lead="${NORM_TOKENS[0]}"
    local base="${lead##*/}"
    # 実行ファイルの basename に正規化（/usr/bin/git → git）
    NORM_TOKENS[0]="$base"

    case "$base" in
      git)
        PUSH_TOKENS=()
        extract_push_tokens "${NORM_TOKENS[@]}"
        if [ -n "${PUSH_TOKENS[*]:-}" ]; then
          analyze_push "${PUSH_TOKENS[@]}"
        fi
        ;;
      bash|sh|zsh|dash|ksh|ash)
        local inner
        inner="$(extract_dash_c_arg "${NORM_TOKENS[@]}")"
        [ -n "$inner" ] && analyze_bash_command "$inner" "$((depth + 1))"
        ;;
      xargs)
        local -a rest=("${NORM_TOKENS[@]:1}")
        while [ "${#rest[@]}" -gt 0 ]; do
          case "${rest[0]}" in
            -*) rest=("${rest[@]:1}") ;;
            *) break ;;
          esac
        done
        if [ "${#rest[@]}" -gt 0 ] && [ "${rest[0]##*/}" = "git" ]; then
          rest[0]="git"
          PUSH_TOKENS=()
          extract_push_tokens "${rest[@]}"
          [ -n "${PUSH_TOKENS[*]:-}" ] && analyze_push "${PUSH_TOKENS[@]}"
        fi
        ;;
    esac
  done
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
      [ -n "$file_path" ] && check_g3_write "$file_path"
      emit_allow "$tool_name file_path ok"
      ;;
    NotebookEdit)
      local notebook_path
      notebook_path="$(printf '%s' "$input" | jq -r '.tool_input.notebook_path // .tool_input.file_path // empty')"
      [ -n "$notebook_path" ] && check_g0_path "$notebook_path"
      [ -n "$notebook_path" ] && check_g3_write "$notebook_path"
      emit_allow "NotebookEdit path ok"
      ;;
    apply_patch|ApplyPatch)
      local file_path patch_payload
      file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
      [ -n "$file_path" ] && check_g0_path "$file_path"
      [ -n "$file_path" ] && check_g3_write "$file_path"
      patch_payload="$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.patch // .tool_input.input // empty')"
      [ -n "$patch_payload" ] && check_g0_patch_payload "$patch_payload"
      [ -n "$patch_payload" ] && check_g3_patch_payload "$patch_payload"
      emit_allow "apply_patch ok"
      ;;
    Bash|Shell|shell)
      local command_str
      command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
      [ -z "$command_str" ] && emit_allow "$tool_name empty command"

      # Issue #49: 全 segment を走査し（先頭 segment 限定をやめ）、env/command/絶対パス/
      # bash -c ラッパを正規化・再帰解析した上で G0 / push 規則を適用する。
      analyze_bash_command "$command_str"

      emit_allow "$tool_name ok"
      ;;
    *)
      emit_allow "tool_name=$tool_name not in scope"
      ;;
  esac
}

main "$@"
