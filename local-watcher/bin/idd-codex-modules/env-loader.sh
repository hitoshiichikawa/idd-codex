#!/usr/bin/env bash
# env-loader.sh — watcher の per-repo env ファイル ローダモジュール（idd-claude #386/F8 移植）
#
# 用途:
#   watcher 起動時に per-repo env ファイルを source して `*_ENABLED` 系フラグを供給し、
#   crontab 行を `REPO` / `REPO_DIR` / `BASE_BRANCH` といった repo 識別系の最小限に保てる
#   ようにする。crontab 行長限界（~1024 文字）で `command too long` が発生する事態を解消する。
#   idd-codex は full-auto 系 gate（AUTO_MERGE_ENABLED / FAILED_RECOVERY_ENABLED /
#   NEEDS_DECISIONS_MODE / AUTO_REBASE_SEMANTIC / BLOCKED_CYCLE_DETECTION_ENABLED /
#   SLACK_NOTIFY_ENABLED / PR_REVIEWER_SECOND_GATE / STALE_PICKUP_REAPER_ENABLED 等）で
#   env var が増えているため、本ローダの価値が高い。
#
#   - el_log / el_warn               : ロガー（既存 *_log / *_warn と同形式の `[$REPO]` 3 段 prefix）
#   - el_resolve_env_file            : `WATCHER_ENV_FILE` → `$HOME/.idd-codex/<REPO_SLUG>.env`
#                                       の探索順で読取可能な絶対パスを 1 つ解決（純粋関数）
#   - el_apply_env_file              : 解決済み env ファイルを 1 行ずつ解釈し、未設定 KEY のみ
#                                       環境変数として export する
#   - el_load                        : 上記 2 つを束ねる public entry point。本体から 1 回だけ呼ぶ
#
#   precedence:
#     - inline cron env > env ファイル。el_apply_env_file 呼出時点で既にプロセス env に
#       存在する変数（`${KEY+x}` が定義済み）は env ファイルで上書きしない。
#     - watcher 本体側の `KEY="${KEY:-default}"` 形式の後方で、本 module 経由で export された
#       KEY も「既存値」として扱われ、ハードコードされた default で上書きされない。
#
#   値評価:
#     - 値文字列に `$HOME` / `$VAR` / `$(...)` を含められる。env ファイルは運用者管理ファイル
#       （信頼境界の内側）として扱い、サニタイズは行わない。
#     - コマンド置換が非 0 終了した場合は当該 KEY を未設定のまま残し、warn + 次行へ継続。
#
#   異常系:
#     - 構文不正行（`=` 欠落 / `KEY` が識別子として無効）は当該行のみ skip + warn。
#     - ファイル読取不能（権限不足等）は warn + 何もせず継続。
#     - 警告メッセージにはパスと行番号を含めるが、**VALUE 本体は含めない**（機密候補の保護）。
#
# 配置先:
#   $HOME/bin/idd-codex-modules/env-loader.sh（install.sh が local-watcher/bin/idd-codex-modules/ から配置）
#
# 依存:
#   - 本モジュールは idd-codex-issue-watcher.sh 本体から、Config ブロック前に **単独 source**
#     される（core_utils.sh より前に動くため、ロガーは core_utils ではなく本モジュールで定義）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$REPO / $REPO_SLUG / $HOME）は本体側で本 module source 前に定義済みである前提。
#   - 外部 CLI: date のみ（ロガー用）。
#   - 関数 prefix `el_` を namespace として採用する。
#
# 移植元: idd-claude #386（PR）`modules/env-loader.sh`。convention path を idd-codex namespace
#   （`$HOME/.idd-codex/<slug>.env`）へ差し替え、ロジックは温存。

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# ロガー（既存 fr_log / sn_log と同形式の 3 段 prefix）
# env ファイル内の値（webhook URL 等の機密候補）は warn 出力にも載せない。呼び出し側は
# KEY 名 / パス / 行番号 / 失敗種別のみを渡す契約。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
el_log() {
  echo "[$(date '+%F %T')] [${REPO:-?}] env-loader: $*"
}
el_warn() {
  echo "[$(date '+%F %T')] [${REPO:-?}] env-loader: WARN: $*" >&2
}

# ─────────────────────────────────────────────────────────────────────────────
# el_resolve_env_file: env ファイルの絶対パスを探索順で解決する
#   探索順:
#     1. `WATCHER_ENV_FILE` が絶対パス + 通常ファイル + 読取可能 → 採用
#     2. `$HOME/.idd-codex/<REPO_SLUG>.env` が同条件を満たす → 採用
#     3. いずれも該当しなければ rc=1（候補なし）
#   stdout: 採用した env ファイルの絶対パス（成功時）/ 戻り値: 0=採用 / 1=候補なし
#   副作用なし（絶対パス + 通常ファイル + 読取権限ありの使用前検証 / path traversal 予防）
# ─────────────────────────────────────────────────────────────────────────────
el_resolve_env_file() {
  local candidate=""

  # 候補 1: WATCHER_ENV_FILE（運用者明示指定）。絶対パスのみ受理（path traversal 予防）。
  if [ -n "${WATCHER_ENV_FILE:-}" ]; then
    case "$WATCHER_ENV_FILE" in
      /*)
        if [ -f "$WATCHER_ENV_FILE" ] && [ -r "$WATCHER_ENV_FILE" ]; then
          printf '%s\n' "$WATCHER_ENV_FILE"
          return 0
        fi
        ;;
    esac
  fi

  # 候補 2: $HOME/.idd-codex/<REPO_SLUG>.env（idd-codex 規約パス・namespace 分離）。
  if [ -n "${HOME:-}" ] && [ -n "${REPO_SLUG:-}" ]; then
    candidate="${HOME}/.idd-codex/${REPO_SLUG}.env"
    if [ -f "$candidate" ] && [ -r "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# el_apply_env_file: 解決済み env ファイルを 1 行ずつ解釈して環境変数を export する
#   引数: $1 = 採用済み env ファイルの絶対パス
#   戻り値: 0 = 通常終了（行 skip 含む）/ 1 = ファイル読取不能
#   副作用: 各 KEY を export（既に env に存在する KEY はスキップ）
#   1 行パース: 空行 / `#` 行 skip → `^[A-Za-z_][A-Za-z0-9_]*=` 検査 → 既定義 skip →
#              `eval` で `$HOME`/`$VAR`/`$(...)` 展開 → export。eval rc!=0 は warn + skip。
#   warn 出力に KEY 名 / パス / 行番号は含めるが、**VALUE 本体は含めない**。
# ─────────────────────────────────────────────────────────────────────────────
el_apply_env_file() {
  local env_file="$1"

  if [ ! -r "$env_file" ]; then
    el_warn "env ファイルが読取不能: $env_file"
    return 1
  fi

  local lineno=0
  local raw key value
  # 最終行に改行がない場合も取りこぼさないよう `|| [ -n "$raw" ]`。
  while IFS= read -r raw || [ -n "$raw" ]; do
    lineno=$((lineno + 1))

    # 行頭の空白を除去（行末はそのまま：VALUE の意図的 trailing space を残す可能性）。
    local stripped="${raw#"${raw%%[![:space:]]*}"}"

    case "$stripped" in
      ''|'#'*) continue ;;
    esac

    if ! [[ "$stripped" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      el_warn "構文不正行 skip: $env_file:$lineno"
      continue
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"

    # precedence: inline cron env > env ファイル。`${KEY+x}` が定義済みなら skip。
    if [ -n "${!key+x}" ]; then
      continue
    fi

    # 値評価: `eval` で展開。`export VAR=$(cmd)` は export の rc を返すため、(1) 単純代入だけを
    # eval してその rc で置換失敗を検出し、(2) 成功した KEY を改めて export する 2 段構成。
    # `2>/dev/null` で system 由来メッセージを握り潰し、評価成功した値は log/warn に出さない。
    if eval "$key=\"$value\"" 2>/dev/null; then
      # shellcheck disable=SC2163  # 動的 KEY を export するため間接 export を使う
      export "$key"
    else
      el_warn "値評価に失敗（コマンド置換不可 / 構文エラー等） skip: $env_file:$lineno KEY=$key"
      unset "$key" 2>/dev/null || true
    fi
  done < "$env_file"

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# el_load: env-loader の public entry point。本体 Config ブロック前から 1 回だけ呼ぶ。
#   戻り値: 常に 0（候補なしは silent / 異常系も警告のみで継続）
#   副作用: 採用した env ファイル経由で KEY を export。採用時に 1 行 stdout ログ（値は出さない）。
#           候補なし時はログを出さない（通常運用の標準ログを増やさない）。
# ─────────────────────────────────────────────────────────────────────────────
el_load() {
  local env_file=""
  if ! env_file="$(el_resolve_env_file)"; then
    return 0
  fi
  el_log "env ファイル採用: $env_file"
  el_apply_env_file "$env_file" || true
  return 0
}
