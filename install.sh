#!/usr/bin/env bash
# =============================================================================
# idd-codex install helper
#
# このスクリプトは idd-codex の各ファイルを適切な場所にコピーします。
# 対象リポジトリへの配置・ローカル PC へのインストール・両方を選択可能。
#
# 使い方:
#   ./install.sh                             # 対話モードで聞きながら進める
#   ./install.sh --repo /path/to/your-project
#   ./install.sh --repo                      # カレントディレクトリ (./) に配置
#   ./install.sh --local                     # ローカル watcher のみインストール
#   ./install.sh --all                       # カレントディレクトリ + ローカル watcher
#   ./install.sh --all --repo /path/to/project
#
# オプション（既存フラグと組み合わせ可）:
#   --dry-run        実コピーせず、予定操作を [DRY-RUN] プレフィクスで列挙
#                    （ファイルシステムを変更しない。出力分類は実実行時と一致）
#   --force          .codex/agents/ / .codex/rules/ について、内容差分があれば
#                    .bak once-only 退避して強制上書き（既存 *.bak は保護）。
#                    AGENTS.md は --force だけでは上書きしない（consumer 固有の
#                    記述を保護するため）。既存 AGENTS.md は据え置き、template を
#                    AGENTS.md.org として並置（差分時のみ）= --force なしと同一挙動。
#   --force-codex-md  AGENTS.md を template で明示上書きする（.bak once-only 退避 +
#                    上書き）。AGENTS.md.org は作らない。--force と併用すると
#                    agents/rules も AGENTS.md も上書きされる。
#   --no-labels      対象リポジトリ配置時に走る GitHub ラベル自動セットアップを完全に skip
#                    （`IDD_CODEX_SKIP_LABELS=true` env でも同等の opt-out が可能）
# =============================================================================

set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# sudo で実行されていないか警告
#   idd-codex は $HOME 配下にユーザースコープで配置するため sudo は不要。
#   sudo で実行するとファイル所有者が root になり、後からユーザーで更新できなくなる。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then
  echo "⚠️  sudo で実行されています。idd-codex はユーザースコープ（\$HOME 配下）に"
  echo "   インストールする前提のため、sudo は不要です。"
  echo "   このまま続行すると \$HOME 配下のファイルが root 所有になり、通常ユーザーで"
  echo "   更新・削除できなくなる可能性があります。"
  echo ""
  read -r -p "   このまま続行しますか？ [y/N]: " yn
  if [[ ! "$yn" =~ ^[Yy]$ ]]; then
    echo "   中断しました。sudo を外して再実行してください。"
    exit 1
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_TEMPLATE_DIR="$SCRIPT_DIR/repo-template"
LOCAL_WATCHER_DIR="$SCRIPT_DIR/local-watcher"

# 冪等性 / dry-run 制御フラグ（後段の引数パースで上書き可能）
DRY_RUN=false
FORCE=false
# AGENTS.md を template で明示上書きするオプトインフラグ（Issue #208 / Req 2）。
#   false（既定）: --force の有無に関わらず AGENTS.md は据え置き + 差分時 .org 並置。
#   true（--force-codex-md 指定時）: AGENTS.md.bak once-only 退避 + template 上書き。
FORCE_AGENTS_MD=false

# ラベル自動セットアップ opt-out 制御
#   true: ラベルセットアップを完全に skip（`--no-labels` または
#         `IDD_CODEX_SKIP_LABELS=true` env で有効化）
#   false: 既定（対象リポジトリ配置時にラベルセットアップを試行する）
SKIP_LABELS=false
case "${IDD_CODEX_SKIP_LABELS:-}" in
  true|TRUE|True|1|yes|YES) SKIP_LABELS=true ;;
esac

REPO_PATH=""
INSTALL_LOCAL=false
INSTALL_REPO=false

# 引数パース
while [[ $# -gt 0 ]]; do
  case $1 in
    --repo)
      # --repo の次がフラグ（- で始まる）または存在しない場合はカレントディレクトリを採用
      if [ $# -ge 2 ] && [[ ! "${2:-}" =~ ^- ]] && [ -n "${2:-}" ]; then
        REPO_PATH="$2"
        shift 2
      else
        REPO_PATH="."
        shift
      fi
      INSTALL_REPO=true
      ;;
    --local)
      INSTALL_LOCAL=true
      shift
      ;;
    --all)
      INSTALL_LOCAL=true
      INSTALL_REPO=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --force-codex-md)
      FORCE_AGENTS_MD=true
      shift
      ;;
    --no-labels)
      SKIP_LABELS=true
      shift
      ;;
    -h|--help)
      sed -n '3,28p' "$0"
      exit 0
      ;;
    *)
      echo "未知のオプション: $1" >&2
      exit 1
      ;;
  esac
done

# ─────────────────────────────────────────────────────────────
# ヘルパー関数群
#   引数パースの後に定義し、後段の setup_repo / setup_local_watcher 相当ブロックから
#   呼び出される。すべて DRY_RUN / FORCE をグローバル変数として参照する。
# ─────────────────────────────────────────────────────────────

# log_action <NEW|OVERWRITE|SKIP|BACKUP> <path> [<note>]
#   配置・上書き・スキップ・バックアップを統一フォーマットで stdout に記録する。
#   DRY_RUN=true の場合は "[DRY-RUN]" prefix、それ以外は "[INSTALL]" prefix を使う。
log_action() {
  local action="$1"
  local path="$2"
  local note="${3:-}"
  local prefix
  if [ "$DRY_RUN" = "true" ]; then
    prefix="[DRY-RUN]"
  else
    prefix="[INSTALL]"
  fi
  if [ -n "$note" ]; then
    printf '%s %-9s %s %s\n' "$prefix" "$action" "$path" "$note"
  else
    printf '%s %-9s %s\n' "$prefix" "$action" "$path"
  fi
}

# files_equal <path_a> <path_b>
#   2 ファイルの内容同一性判定。
#   return: 0=同一 / 1=差分あり / 2=どちらか不在 or 比較不能
files_equal() {
  local a="$1"
  local b="$2"
  if [ ! -f "$a" ] || [ ! -f "$b" ]; then
    return 2
  fi
  if cmp -s "$a" "$b"; then
    return 0
  else
    return 1
  fi
}

# classify_action <src> <dest>
#   stdout に "NEW" / "SKIP" / "OVERWRITE" を返す。
#   - dest 不在 → NEW
#   - dest 存在 + 内容同一 → SKIP
#   - dest 存在 + 内容差分 → OVERWRITE
classify_action() {
  local src="$1"
  local dest="$2"
  if [ ! -e "$dest" ]; then
    echo "NEW"
    return 0
  fi
  if files_equal "$src" "$dest"; then
    echo "SKIP"
  else
    echo "OVERWRITE"
  fi
}

# ensure_dir <path>
#   mkdir -p の dry-run 対応版。dry-run 時はディレクトリも作らない。
ensure_dir() {
  local path="$1"
  if [ "$DRY_RUN" = "true" ]; then
    return 0
  fi
  mkdir -p "$path"
}

# copy_template_file <src> <dest> [--executable]
#   単一ファイルの NEW / SKIP / OVERWRITE 配置（meta ファイル用、`.bak` は作らない）。
#   既存があっても内容差分があれば無条件で OVERWRITE する。
#   --executable 指定時は配置後に `chmod +x` を実行する。
copy_template_file() {
  local src="$1"
  local dest="$2"
  local executable=false
  if [ "${3:-}" = "--executable" ]; then
    executable=true
  fi

  if [ ! -f "$src" ]; then
    echo "Error: source file not found: $src" >&2
    return 1
  fi

  local action
  action="$(classify_action "$src" "$dest")"

  local note=""
  if [ "$executable" = "true" ]; then
    note="(chmod +x)"
  fi

  case "$action" in
    NEW)
      log_action "NEW" "$dest" "$note"
      if [ "$DRY_RUN" = "false" ]; then
        ensure_dir "$(dirname "$dest")"
        cp "$src" "$dest"
        if [ "$executable" = "true" ]; then
          chmod +x "$dest"
        fi
      fi
      ;;
    SKIP)
      log_action "SKIP" "$dest" "(identical to template)"
      ;;
    OVERWRITE)
      log_action "OVERWRITE" "$dest" "$note"
      if [ "$DRY_RUN" = "false" ]; then
        cp "$src" "$dest"
        if [ "$executable" = "true" ]; then
          chmod +x "$dest"
        fi
      fi
      ;;
  esac
}

# copy_local_runtime_file <src> <dest> [--executable]
#   ローカル実行時にユーザーが編集し得るファイルの safe-overwrite 処理。
#   対象: $HOME/bin/idd-codex-issue-watcher.sh と macOS launchd plist。
#   差分あり既存ファイルは <dest>.bak に一度だけ退避し、既存 .bak は上書きしない。
copy_local_runtime_file() {
  local src="$1"
  local dest="$2"
  local executable=false
  if [ "${3:-}" = "--executable" ]; then
    executable=true
  fi

  if [ ! -f "$src" ]; then
    echo "Error: source file not found: $src" >&2
    return 1
  fi

  local action
  action="$(classify_action "$src" "$dest")"

  local note=""
  if [ "$executable" = "true" ]; then
    note="(chmod +x)"
  fi

  case "$action" in
    NEW)
      log_action "NEW" "$dest" "$note"
      if [ "$DRY_RUN" = "false" ]; then
        ensure_dir "$(dirname "$dest")"
        cp "$src" "$dest"
        if [ "$executable" = "true" ]; then
          chmod +x "$dest"
        fi
      fi
      ;;
    SKIP)
      log_action "SKIP" "$dest" "(identical to template)"
      ;;
    OVERWRITE)
      local bak="$dest.bak"
      local bak_name
      bak_name="$(basename "$dest").bak"
      if [ ! -f "$bak" ]; then
        log_action "BACKUP" "$dest" "→ $bak_name (custom edits detected)"
        if [ "$DRY_RUN" = "false" ]; then
          cp "$dest" "$bak"
        fi
        log_action "OVERWRITE" "$dest" "$note"
        if [ "$DRY_RUN" = "false" ]; then
          cp "$src" "$dest"
          if [ "$executable" = "true" ]; then
            chmod +x "$dest"
          fi
        fi
      else
        if [ "$FORCE" = "true" ]; then
          log_action "SKIP" "$bak" "(existing .bak preserved even with --force)"
          log_action "OVERWRITE" "$dest" "$note"
          if [ "$DRY_RUN" = "false" ]; then
            cp "$src" "$dest"
            if [ "$executable" = "true" ]; then
              chmod +x "$dest"
            fi
          fi
        else
          log_action "SKIP" "$dest" "(existing .bak found, use --force to overwrite)"
        fi
      fi
      ;;
  esac
}

# render_guard_profile_config <template> <hook_path>
#   Codex Guard profile template の placeholder を hook path に literal replacement する。
#   sed delimiter / replacement syntax を通さず、# / \ / & / space を path data として扱う。
render_guard_profile_config() {
  local template_path="$1"
  local hook_path="$2"
  local placeholder="__IDD_CODEX_GUARD_HOOK_PATH__"

  if [ ! -f "$template_path" ]; then
    echo "Error: guard profile template not found: $template_path" >&2
    return 1
  fi

  case "$hook_path" in
    *"'"*|*$'\n'*)
      echo "Error: guard hook path contains characters unsupported by TOML literal string" >&2
      return 1
      ;;
  esac

  local template_content
  if ! template_content="$(cat "$template_path")"; then
    echo "Error: failed to read guard profile template: $template_path" >&2
    return 1
  fi

  if [[ "$template_content" != *"$placeholder"* ]]; then
    echo "Error: guard profile template missing $placeholder" >&2
    return 1
  fi

  awk -v placeholder="$placeholder" -v replacement="$hook_path" '
    {
      line = $0
      rendered = ""
      while ((pos = index(line, placeholder)) > 0) {
        rendered = rendered substr(line, 1, pos - 1) replacement
        line = substr(line, pos + length(placeholder))
      }
      print rendered line
    }
  ' "$template_path"
}

# copy_glob_to_homebin <src_dir> <pattern> <dest_dir> [--executable]
#   `<src_dir>/<pattern>` にマッチする全ファイルを <dest_dir> に配置する。
#   nullglob を一時的に有効化し、マッチ 0 件は SKIP ログを出して exit 0 で継続する。
copy_glob_to_homebin() {
  local src_dir="$1"
  local pattern="$2"
  local dest_dir="$3"
  local executable_flag=""
  if [ "${4:-}" = "--executable" ]; then
    executable_flag="--executable"
  fi

  ensure_dir "$dest_dir"

  # nullglob を一時的に有効化（マッチ 0 件で空配列扱いにする）
  local prev_nullglob
  if shopt -q nullglob; then
    prev_nullglob=on
  else
    prev_nullglob=off
  fi
  shopt -s nullglob

  # `$pattern` は意図的に glob 展開させたいためクォートしない
  # shellcheck disable=SC2206
  local files=( "$src_dir"/$pattern )
  local count=${#files[@]}

  if [ "$count" -eq 0 ]; then
    log_action "SKIP" "$src_dir/$pattern" "(no files matched)"
  else
    local src
    for src in "${files[@]}"; do
      local dest
      dest="$dest_dir/$(basename "$src")"
      if [ -n "$executable_flag" ]; then
        copy_template_file "$src" "$dest" --executable
      else
        copy_template_file "$src" "$dest"
      fi
    done
  fi

  # nullglob を呼び出し前の状態に戻す
  if [ "$prev_nullglob" = "off" ]; then
    shopt -u nullglob
  fi
}

# copy_local_watcher_scripts <src_dir> <dest_dir>
#   local-watcher/bin/*.sh を配置する。ユーザー編集対象の watcher 本体だけ
#   copy_local_runtime_file を使い、将来追加される補助 *.sh は従来どおり template として扱う。
copy_local_watcher_scripts() {
  local src_dir="$1"
  local dest_dir="$2"

  ensure_dir "$dest_dir"

  local prev_nullglob
  if shopt -q nullglob; then
    prev_nullglob=on
  else
    prev_nullglob=off
  fi
  shopt -s nullglob

  local files=( "$src_dir"/*.sh )
  local count=${#files[@]}

  if [ "$count" -eq 0 ]; then
    log_action "SKIP" "$src_dir/*.sh" "(no files matched)"
  else
    local src
    for src in "${files[@]}"; do
      local dest name
      name="$(basename "$src")"
      dest="$dest_dir/$name"
      if [ "$name" = "idd-codex-issue-watcher.sh" ]; then
        copy_local_runtime_file "$src" "$dest" --executable
      else
        copy_template_file "$src" "$dest" --executable
      fi
    done
  fi

  if [ "$prev_nullglob" = "off" ]; then
    shopt -u nullglob
  fi
}

# backup_codex_md_once <repo_path>
#   AGENTS.md.bak を初回 1 回のみ作成し、再実行で内容を変えない once-only 規律を実装。
#   - AGENTS.md 不在 → noop
#   - AGENTS.md.bak 不在 → BACKUP（初回バックアップ）
#   - AGENTS.md.bak 既存 → SKIP（既存 .bak を温存）
backup_codex_md_once() {
  local repo_path="$1"
  local src="$repo_path/AGENTS.md"
  local bak="$repo_path/AGENTS.md.bak"

  if [ ! -f "$src" ]; then
    return 0
  fi

  if [ ! -f "$bak" ]; then
    log_action "BACKUP" "$src" "→ AGENTS.md.bak"
    if [ "$DRY_RUN" = "false" ]; then
      cp "$src" "$bak"
    fi
  else
    log_action "SKIP" "$bak" "(existing .bak preserved)"
  fi
}

# copy_with_hybrid_overwrite <src> <dest>
#   1 ファイル単位のハイブリッド safe-overwrite 処理（agents / rules / AGENTS.md 共用）。
#   - dest 不在 → NEW（無条件配置、template 進化に追従）
#   - dest 存在 + 内容同一 → SKIP `(identical to template)`
#   - dest 存在 + 内容差分:
#     - <dest>.bak 不在 → BACKUP `<dest> → <name>.bak` + OVERWRITE
#     - <dest>.bak 既存 + FORCE=false → SKIP `(existing .bak found, use --force to overwrite)`
#     - <dest>.bak 既存 + FORCE=true  → SKIP の .bak（once-only 規律保護）+ OVERWRITE
copy_with_hybrid_overwrite() {
  local src="$1"
  local dest="$2"

  if [ ! -f "$src" ]; then
    echo "Error: source file not found: $src" >&2
    return 1
  fi

  local action
  action="$(classify_action "$src" "$dest")"

  case "$action" in
    NEW)
      log_action "NEW" "$dest"
      if [ "$DRY_RUN" = "false" ]; then
        ensure_dir "$(dirname "$dest")"
        cp "$src" "$dest"
      fi
      ;;
    SKIP)
      log_action "SKIP" "$dest" "(identical to template)"
      ;;
    OVERWRITE)
      local bak="$dest.bak"
      local bak_name
      bak_name="$(basename "$dest").bak"
      if [ ! -f "$bak" ]; then
        # .bak 不在 → 初回退避してから上書き（once-only）
        local backup_note
        if [ "$FORCE" = "true" ]; then
          backup_note="→ $bak_name (--force)"
        else
          backup_note="→ $bak_name (custom edits detected)"
        fi
        log_action "BACKUP" "$dest" "$backup_note"
        if [ "$DRY_RUN" = "false" ]; then
          cp "$dest" "$bak"
        fi
        log_action "OVERWRITE" "$dest"
        if [ "$DRY_RUN" = "false" ]; then
          cp "$src" "$dest"
        fi
      else
        # .bak 既存 → once-only 規律で再退避しない
        if [ "$FORCE" = "true" ]; then
          log_action "SKIP" "$bak" "(existing .bak preserved even with --force)"
          log_action "OVERWRITE" "$dest"
          if [ "$DRY_RUN" = "false" ]; then
            cp "$src" "$dest"
          fi
        else
          log_action "SKIP" "$dest" "(existing .bak found, use --force to overwrite)"
        fi
      fi
      ;;
  esac
}

# copy_agents_rules <src_dir> <dest_dir>
#   `.codex/agents/*.md` および `.codex/rules/*.md` のハイブリッド safe-overwrite 配置。
#   各 .md ファイルに対して copy_with_hybrid_overwrite を適用する。
#   nullglob を一時的に有効化し、マッチ 0 件は SKIP ログを出して exit 0 で継続。
copy_agents_rules() {
  local src_dir="$1"
  local dest_dir="$2"

  ensure_dir "$dest_dir"

  local prev_nullglob
  if shopt -q nullglob; then
    prev_nullglob=on
  else
    prev_nullglob=off
  fi
  shopt -s nullglob

  local files=( "$src_dir"/*.md )
  local count=${#files[@]}

  if [ "$count" -eq 0 ]; then
    log_action "SKIP" "$src_dir/*.md" "(no files matched)"
  else
    local src
    for src in "${files[@]}"; do
      local dest
      dest="$dest_dir/$(basename "$src")"
      copy_with_hybrid_overwrite "$src" "$dest"
    done
  fi

  if [ "$prev_nullglob" = "off" ]; then
    shopt -u nullglob
  fi
}

# AGENTS_MD_ORG_TOUCHED
#   `copy_codex_md_with_org` が `AGENTS.md.org` を NEW / OVERWRITE した場合に
#   "true" を立てるグローバルフラグ（Req 6.1）。配置完了サマリ末尾の merge
#   ガイドメッセージ表示判定に使う。SKIP / 既存 AGENTS.md 不在 /
#   `--force-codex-md` 経路では立てない（Req 6.2）。
AGENTS_MD_ORG_TOUCHED=false

# copy_codex_md_with_org <src> <dest>
#   AGENTS.md 専用の安全配置ロジック（Issue #87 / #208）。
#   既存 AGENTS.md が編集済みであることを前提に、template を `.org` として
#   並置することで「ユーザー記述が主、template は参考」という関係に反転する。
#
#   AGENTS.md の template 上書きは `--force-codex-md`（FORCE_AGENTS_MD=true）でのみ
#   行う。`--force`（FORCE=true）単体では AGENTS.md を上書きしない（Req 1, 2.4）。
#
#   - dest 不在 + FORCE_AGENTS_MD=any        → NEW（template を AGENTS.md として配置、.org は作らない）
#   - dest 存在 + 内容同一                   → SKIP（.org も作らない）
#   - dest 存在 + 差分あり + FORCE_AGENTS_MD=false:
#     - dest.org 不在                        → NEW dest.org（template を並置、本体は据え置き）
#     - dest.org 存在 + 内容同一             → SKIP dest.org
#     - dest.org 存在 + 差分あり             → OVERWRITE dest.org（最新 template に追従）
#   - dest 存在 + 差分あり + FORCE_AGENTS_MD=true:
#     既存 backup_codex_md_once の挙動に委譲（.bak once-only 退避 + template で上書き）。
#     `.org` は触らない（Req 2.3）。
#
#   既存 `AGENTS.md.bak` は本関数では一切触らない（Req 4.1, 4.2, 4.3）。
copy_codex_md_with_org() {
  local src="$1"
  local dest="$2"
  local org="$dest.org"
  local org_name
  org_name="$(basename "$dest").org"

  if [ ! -f "$src" ]; then
    echo "Error: source file not found: $src" >&2
    return 1
  fi

  # FORCE_AGENTS_MD 指定時は従来の --force 挙動（明示オプトイン上書き / Req 2）。
  # backup_codex_md_once → copy_template_file 相当のシーケンスを再現するため、
  # 呼び出し側で backup_codex_md_once を先に呼ぶ前提を保ち、本関数では
  # template で上書きするだけに留める。--force 単体（FORCE_AGENTS_MD=false）では
  # この分岐に入らず、下の通常経路（据え置き + .org 並置）を通る（Req 1）。
  if [ "$FORCE_AGENTS_MD" = "true" ]; then
    # `.org` は --force-codex-md 経路では作らない / 触らない（Req 2.3）
    local action
    action="$(classify_action "$src" "$dest")"
    case "$action" in
      NEW)
        log_action "NEW" "$dest"
        if [ "$DRY_RUN" = "false" ]; then
          ensure_dir "$(dirname "$dest")"
          cp "$src" "$dest"
        fi
        ;;
      SKIP)
        log_action "SKIP" "$dest" "(identical to template)"
        ;;
      OVERWRITE)
        log_action "OVERWRITE" "$dest" "(--force-codex-md)"
        if [ "$DRY_RUN" = "false" ]; then
          cp "$src" "$dest"
        fi
        ;;
    esac
    return 0
  fi

  # 通常経路（--force-codex-md なし。--force 単体もここを通る / Req 1）
  local action
  action="$(classify_action "$src" "$dest")"

  case "$action" in
    NEW)
      # AGENTS.md 不在: template を AGENTS.md としてそのまま配置。
      # `.org` は作らない（Req 1.2）。
      log_action "NEW" "$dest"
      if [ "$DRY_RUN" = "false" ]; then
        ensure_dir "$(dirname "$dest")"
        cp "$src" "$dest"
      fi
      ;;
    SKIP)
      # 既存 AGENTS.md が template と同一: 何も触らない（Req 2.5）。
      log_action "SKIP" "$dest" "(identical to template)"
      ;;
    OVERWRITE)
      # 既存 AGENTS.md は据え置き、template を `.org` として並置（Req 2.1）。
      # 本体側は変更しないので OVERWRITE ログは出さず、SKIP として明示する。
      log_action "SKIP" "$dest" "(existing kept, template placed as $org_name)"

      local org_action
      if [ ! -e "$org" ]; then
        # `.org` 不在: 新規並置（Req 2.2）
        log_action "NEW" "$org"
        if [ "$DRY_RUN" = "false" ]; then
          cp "$src" "$org"
        fi
        AGENTS_MD_ORG_TOUCHED=true
      else
        org_action="$(classify_action "$src" "$org")"
        case "$org_action" in
          SKIP)
            # `.org` 既存 + 内容同一（Req 2.3）
            log_action "SKIP" "$org" "(identical to template)"
            ;;
          OVERWRITE)
            # `.org` 既存 + 差分あり: template の最新内容で更新（Req 2.4）
            log_action "OVERWRITE" "$org" "(refresh from template)"
            if [ "$DRY_RUN" = "false" ]; then
              cp "$src" "$org"
            fi
            AGENTS_MD_ORG_TOUCHED=true
            ;;
          NEW)
            # 通常 to-here ない経路だが念のため（org が存在するのに NEW 判定なら
            # ファイルではなくディレクトリの可能性 → 安全側でエラー）
            echo "Error: $org exists but is not a regular file" >&2
            return 1
            ;;
        esac
      fi
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────
# ラベル自動セットアップ（Issue #85）
#   テンプレート配置完了直後に対象リポジトリ向けラベルを冪等作成する。
#   gh 不在 / 未認証 / 権限なし / API 失敗時は skip し install 全体を止めない（fail-soft）。
#   `--no-labels` または `IDD_CODEX_SKIP_LABELS=true` で完全 opt-out。
#   `--dry-run` 時は API 呼び出しせず、これから走る予定だけを表示する。
# ─────────────────────────────────────────────────────────────

# log_label_action <STATUS> <message>
#   ラベルセットアップ系の出力を grep 可能な統一書式で記録する（NFR 2.3）。
#   STATUS は OK / SKIP / DRY-RUN / FAIL のいずれか。
log_label_action() {
  local status="$1"
  local message="$2"
  printf '%s %-9s [labels] %s\n' "[INSTALL]" "$status" "$message"
}

# print_label_manual_command <repo_or_path>
#   skip 時にユーザーが手動実行できる完全コマンド文字列を 1 ブロックで提示する（Req 3.5, 3.6）。
#   引数:
#     - owner/repo 形式が解決できていれば --repo 付き、解決できていなければ
#       repo path に cd してからの実行例の両方を出す
print_label_manual_command() {
  local repo="$1"
  local repo_path="$2"
  cat <<MANUAL
   手動でラベル一括作成を実行するには:
       cd $repo_path
       bash .github/scripts/idd-codex-labels.sh
     または repo 外から:
       bash $repo_path/.github/scripts/idd-codex-labels.sh${repo:+ --repo $repo}
MANUAL
}

# resolve_repo_slug <repo_path>
#   対象 repo path から `owner/repo` を解決する（fail-soft）。
#   解決順序:
#     1. gh repo view --json nameWithOwner
#     2. git -C remote get-url origin → 正規表現抽出
#   いずれも失敗したら空文字列を stdout に返す（呼び出し側で skip 判断）。
resolve_repo_slug() {
  local repo_path="$1"
  local slug=""

  if command -v gh >/dev/null 2>&1; then
    if slug=$(gh repo view --json nameWithOwner -q .nameWithOwner -R "$repo_path" 2>/dev/null); then
      if [ -n "$slug" ]; then
        printf '%s' "$slug"
        return 0
      fi
    fi
  fi

  # gh が解決できない / repo path 内が clone 済みでない場合: git remote から推測
  local remote=""
  if remote=$(git -C "$repo_path" remote get-url origin 2>/dev/null); then
    # SSH / HTTPS / git 形式すべて対応
    # 例: git@github.com:owner/repo.git → owner/repo
    #     https://github.com/owner/repo.git → owner/repo
    slug=$(printf '%s\n' "$remote" \
      | sed -E -e 's#^[^:]+://[^/]+/##' \
              -e 's#^git@[^:]+:##' \
              -e 's#\.git$##' \
              -e 's#/$##')
    if printf '%s' "$slug" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
      printf '%s' "$slug"
      return 0
    fi
  fi

  return 1
}

# setup_repo_labels <repo_path>
#   対象 repo へのラベル一括作成を起動する。fail-soft 設計のため、エラーが起きても
#   exit 0 で戻る。出力は log_label_action / print_label_manual_command に集約する。
setup_repo_labels() {
  local repo_path="$1"
  local labels_script="$repo_path/.github/scripts/idd-codex-labels.sh"

  echo ""
  echo "🏷  GitHub ラベル自動セットアップ"

  # opt-out: --no-labels / IDD_CODEX_SKIP_LABELS
  if [ "$SKIP_LABELS" = "true" ]; then
    log_label_action "SKIP" "opt-out (--no-labels / IDD_CODEX_SKIP_LABELS)"
    print_label_manual_command "" "$repo_path"
    return 0
  fi

  # gh 未インストール → skip
  #   dry-run でも gh 不在を可視化したいので最初に判定する
  if ! command -v gh >/dev/null 2>&1; then
    log_label_action "SKIP" "gh CLI not found"
    print_label_manual_command "" "$repo_path"
    return 0
  fi

  # 対象 repo slug 解決（Req 1.1, 1.5）
  #   dry-run でも実 git remote から解決可能なので先に行う
  local repo_slug=""
  if ! repo_slug=$(resolve_repo_slug "$repo_path"); then
    repo_slug=""
  fi
  if [ -z "$repo_slug" ]; then
    log_label_action "SKIP" "could not resolve owner/repo from $repo_path"
    print_label_manual_command "" "$repo_path"
    return 0
  fi

  # dry-run: 実 API 呼び出しせず、予定を表示する（Req 5.4）
  #   dry-run 下ではラベルスクリプト自体は配置されない可能性があるため、ここで早期 return
  if [ "$DRY_RUN" = "true" ]; then
    log_label_action "DRY-RUN" "would run: bash $labels_script --repo $repo_slug"
    return 0
  fi

  # gh 認証チェック（Req 3.2）
  if ! gh auth status >/dev/null 2>&1; then
    log_label_action "SKIP" "gh CLI is not authenticated (run: gh auth login)"
    print_label_manual_command "" "$repo_path"
    return 0
  fi

  # 配置されたラベルスクリプトの存在確認（自分自身が配置したはずだが念のため）
  if [ ! -f "$labels_script" ]; then
    log_label_action "SKIP" "labels script not found: $labels_script"
    return 0
  fi

  # 実行: 既存 idd-codex-labels.sh の interface を変更せず呼び出す（Req 6.3）
  #   - --repo owner/name を渡す
  #   - --force は付けない（既存ラベルの color/description を上書きしない）（Req 2.5）
  #   - bash で起動（実行ビット欠落でも動かせる保険）
  echo "   対象: $repo_slug"
  local labels_output=""
  local labels_rc=0
  if labels_output=$(bash "$labels_script" --repo "$repo_slug" 2>&1); then
    labels_rc=0
  else
    labels_rc=$?
  fi

  # 全行をユーザーに見せる
  printf '%s\n' "$labels_output"

  # 集計行を取り出して要約（Req 5.1）
  local created exists updated failed
  created=$(printf '%s\n' "$labels_output" | sed -n 's/^[[:space:]]*新規作成:[[:space:]]*//p' | tail -n1)
  exists=$(printf '%s\n' "$labels_output" | sed -n 's/^[[:space:]]*既存スキップ:[[:space:]]*//p' | tail -n1)
  updated=$(printf '%s\n' "$labels_output" | sed -n 's/^[[:space:]]*上書き更新:[[:space:]]*//p' | tail -n1)
  failed=$(printf '%s\n' "$labels_output" | sed -n 's/^[[:space:]]*失敗:[[:space:]]*//p' | tail -n1)

  if [ "$labels_rc" -eq 0 ]; then
    log_label_action "OK" "created=${created:-?} exists=${exists:-?} updated=${updated:-?} failed=${failed:-0}"
    return 0
  fi

  # rc != 0: API / 権限 / レート制限などで一部または全部失敗（Req 3.3, 3.4）
  log_label_action "FAIL" "label setup partially failed (created=${created:-?} failed=${failed:-?}, rc=$labels_rc)"
  print_label_manual_command "$repo_slug" "$repo_path"
  # fail-soft: install 全体は止めない
  return 0
}

# ─────────────────────────────────────────────────────────────
# 履歴持ち込み（inherited specs / codex branches）検出（Issue #115）
#   fork や `git push --mirror` で履歴を持ち込んだ repo に install すると、
#   引き継がれた古い `docs/specs/<N>-*/` ディレクトリや `codex/issue-<N>-*`
#   ブランチが新しい Issue 番号と衝突して watcher が誤動作することがある。
#   配置完了直後にその兆候を検出してユーザーに警告する。
#
#   設計判断（Developer 確定）:
#   - 例示件数: 各カテゴリ先頭 3 件まで、超過分は `(+N more)` で件数を示す
#   - D-3 の Issue 母集合: open + closed（`gh issue list --state all`）
#   - すべて fail-soft。検出処理失敗時は skip 理由を 1 行 stderr に残して継続
#   - `--local` 単独時は呼ばれない（呼び出し側 if $INSTALL_REPO ブロック内で起動）
# ─────────────────────────────────────────────────────────────

# INHERITED_WARNED_PREVIOUSLY
#   warn_inherited が 1 度でも発火したかを記録するグローバル。
#   検出ブロックの末尾「無視しても install は完了している」案内を 1 度だけ
#   出すために使う。
INHERITED_WARNED_PREVIOUSLY=false

# inherited_prefix
#   警告行のプレフィックスを `--dry-run` の値で切り替えて返す（Req 4.2 / 4.3）。
inherited_prefix() {
  if [ "$DRY_RUN" = "true" ]; then
    printf '[DRY-RUN] WARNING:'
  else
    printf '[INSTALL] WARNING:'
  fi
}

# inherited_skip_log <reason>
#   検出処理が skip された理由を 1 行 stderr に残す（Req 3.4 / NFR 2.1）。
#   grep 可能な書式: `[INSTALL] INFO: [inherited] <reason>`。
inherited_skip_log() {
  local reason="$1"
  local prefix
  if [ "$DRY_RUN" = "true" ]; then
    prefix="[DRY-RUN]"
  else
    prefix="[INSTALL]"
  fi
  echo "$prefix INFO: [inherited] $reason" >&2
}

# warn_inherited <category> <message...>
#   警告本文を stderr に出力し、INHERITED_WARNED_PREVIOUSLY を立てる。
#   category は `docs-specs` / `codex-branches` / `orphan-branches` 等。
warn_inherited() {
  local category="$1"
  shift
  local prefix
  prefix="$(inherited_prefix)"
  echo "$prefix [$category] $*" >&2
  INHERITED_WARNED_PREVIOUSLY=true
}

# detect_inherited_specs <target-repo-dir>
#   `docs/specs/<N>-*/` 形式（先頭が数字 + ハイフン）のディレクトリを検出して
#   警告する（Req 1.1, 2.2）。母集合 0 件なら何もしない（Req 2.1）。
detect_inherited_specs() {
  local repo_path="$1"
  local specs_dir="$repo_path/docs/specs"

  if [ ! -d "$specs_dir" ]; then
    return 0
  fi

  # nullglob を一時的に有効化（マッチ 0 件で空配列扱い）
  local prev_nullglob
  if shopt -q nullglob; then
    prev_nullglob=on
  else
    prev_nullglob=off
  fi
  shopt -s nullglob

  local entries=( "$specs_dir"/[0-9]*-* )
  local matched=()
  local entry name
  for entry in "${entries[@]}"; do
    if [ -d "$entry" ]; then
      name="$(basename "$entry")"
      # 念のため `<数字>-<...>` パターンを正規表現で再確認（false positive 防止）
      if printf '%s' "$name" | grep -Eq '^[0-9]+-'; then
        matched+=( "$name" )
      fi
    fi
  done

  if [ "$prev_nullglob" = "off" ]; then
    shopt -u nullglob
  fi

  local count=${#matched[@]}
  if [ "$count" -eq 0 ]; then
    return 0
  fi

  warn_inherited "docs-specs" \
    "inherited な docs/specs/ ディレクトリが ${count} 件検出されました。fork/mirror clone で履歴を持ち込んだ場合、watcher が古い spec を resume 対象に選ぶ事故が起きる可能性があります。"

  # 先頭 3 件を提示（Req 5.2、Developer 確定）
  local i=0
  local shown=0
  local prefix
  prefix="$(inherited_prefix)"
  for name in "${matched[@]}"; do
    if [ "$shown" -ge 3 ]; then
      break
    fi
    echo "$prefix [docs-specs]   - docs/specs/$name/" >&2
    shown=$((shown + 1))
    i=$((i + 1))
  done
  if [ "$count" -gt 3 ]; then
    echo "$prefix [docs-specs]   (+$((count - 3)) more)" >&2
  fi
}

# _list_codex_issue_branches <target-repo-dir>
#   対象 repo の origin 上の `codex/issue-<N>-*` ブランチ名を 1 行 1 件で stdout に返す。
#   exit code:
#     0   : 取得成功（0 件含む）
#     10  : origin remote が存在しない（clean repo / local-only。skip ログは出さない）
#     1+  : git ls-remote の失敗（到達不能 / 認証エラー等。skip ログ対象）
_list_codex_issue_branches() {
  local repo_path="$1"

  # origin remote 存在チェック（Req 2.3）
  #   - 未設定の場合は固有 exit code 10 を返し、呼び出し側で「clean repo」と区別する
  #   - Req 8.3（clean 新規 repo の出力差分ゼロ）を満たすため skip ログは出さない
  if ! git -C "$repo_path" remote get-url origin >/dev/null 2>&1; then
    return 10
  fi

  # ls-remote で origin 側の codex/issue-* ブランチ一覧を取得
  #   - timeout を付けて 10 秒以内に終わるよう保護（NFR 1.1 / 1.2）。
  #     timeout コマンドが無い環境では普通に実行する（fail-soft）。
  local raw=""
  local rc=0
  if command -v timeout >/dev/null 2>&1; then
    if ! raw=$(timeout 10 git -C "$repo_path" ls-remote --heads origin 'codex/issue-*' 2>/dev/null); then
      rc=$?
      return "$rc"
    fi
  else
    if ! raw=$(git -C "$repo_path" ls-remote --heads origin 'codex/issue-*' 2>/dev/null); then
      rc=$?
      return "$rc"
    fi
  fi

  # `<sha>\trefs/heads/<branch>` から branch 名のみ抽出
  printf '%s\n' "$raw" \
    | awk '{ print $2 }' \
    | sed -E 's#^refs/heads/##' \
    | grep -E '^codex/issue-[0-9]+-(design|impl)-' \
    || true
}

# INHERITED_BRANCHES
#   detect_inherited_codex_branches が検出したブランチ名を改行区切りで格納する
#   グローバル変数。command substitution subshell を避けて呼び出し元から
#   参照できるようにするため使う（INHERITED_WARNED_PREVIOUSLY を親シェルで
#   立てるため）。
INHERITED_BRANCHES=""

# detect_inherited_codex_branches <target-repo-dir>
#   `codex/issue-<N>-(design|impl)-*` 形式のブランチを origin に対して検出して
#   警告する（Req 1.2, 2.3）。母集合 0 件なら何もしない（Req 2.1）。
#   検出に失敗（到達不能 / 認証エラー等）した場合は skip 理由を 1 行残して継続
#   （Req 3.2, 3.4）。origin remote が未設定（clean repo / local-only）の場合は
#   skip ログ自体も出さず無音で抜ける（Req 8.3）。
#
#   副作用: グローバル変数 INHERITED_BRANCHES に検出結果を格納する
#           （後続の D-3 で再利用。subshell 化を避けるためグローバル経由）
#   exit:   0=成功（0 件含む） / 1=取得失敗で skip
detect_inherited_codex_branches() {
  local repo_path="$1"
  INHERITED_BRANCHES=""

  local branches=""
  local rc=0
  branches=$(_list_codex_issue_branches "$repo_path") || rc=$?
  if [ "$rc" -eq 10 ]; then
    # origin 未設定: clean / local-only repo として無音で抜ける（Req 8.3）
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    inherited_skip_log "git ls-remote が失敗しました（rc=$rc, 到達不能 / 認証エラーの可能性）。D-2 / D-3 の検出を skip します"
    return 1
  fi

  # 空行を除去して件数を数える
  local cleaned=""
  cleaned=$(printf '%s\n' "$branches" | sed '/^$/d')

  if [ -z "$cleaned" ]; then
    # 0 件: D-2 / D-3 ともに警告対象なし。stdout には何も出さず exit 0。
    return 0
  fi

  local count
  count=$(printf '%s\n' "$cleaned" | wc -l | tr -d ' ')

  warn_inherited "codex-branches" \
    "inherited な codex/issue-* ブランチが ${count} 件検出されました。fork/mirror clone で履歴を持ち込んだ場合、watcher が古いブランチを resume 対象に選ぶ事故が起きる可能性があります。"

  # 先頭 3 件を提示
  local prefix
  prefix="$(inherited_prefix)"
  local shown=0
  local branch
  while IFS= read -r branch; do
    if [ -z "$branch" ]; then
      continue
    fi
    if [ "$shown" -ge 3 ]; then
      break
    fi
    echo "$prefix [codex-branches]   - $branch" >&2
    shown=$((shown + 1))
  done <<< "$cleaned"

  if [ "$count" -gt 3 ]; then
    echo "$prefix [codex-branches]   (+$((count - 3)) more)" >&2
  fi

  # 後続の D-3 で再利用するためグローバル変数に格納する
  INHERITED_BRANCHES="$cleaned"
  return 0
}

# detect_orphan_codex_branches <target-repo-dir> <branches-stdin>
#   detect_inherited_codex_branches の検出結果（stdin で受ける）から `<N>` を
#   抽出し、現存 Issue 番号集合（open + closed）と突合する。
#   過半数（> 50%）が現存 Issue に無ければ orphan として警告（Req 1.3, 2.3）。
#   GitHub Issue 一覧取得が失敗した場合は本判定のみを skip し、install 全体は継続（Req 3.3）。
detect_orphan_codex_branches() {
  local repo_path="$1"
  local branches_input="$2"  # 改行区切りのブランチ名

  if [ -z "$branches_input" ]; then
    return 0
  fi

  # ブランチ名から <N> を抽出（重複排除）
  local issue_nums=""
  issue_nums=$(printf '%s\n' "$branches_input" \
    | sed -nE 's#^codex/issue-([0-9]+)-.*#\1#p' \
    | sort -u)

  if [ -z "$issue_nums" ]; then
    return 0
  fi

  local total
  total=$(printf '%s\n' "$issue_nums" | wc -l | tr -d ' ')

  # gh が無い / 未認証なら D-3 のみ skip（D-1, D-2 は影響しない / Req 3.3）
  if ! command -v gh >/dev/null 2>&1; then
    inherited_skip_log "gh CLI が見つからず D-3（Issue 番号突合）を skip します"
    return 0
  fi
  if ! gh auth status >/dev/null 2>&1; then
    inherited_skip_log "gh CLI が未認証のため D-3（Issue 番号突合）を skip します"
    return 0
  fi

  # repo slug の解決（既存 helper を再利用、fail-soft）
  local repo_slug=""
  if ! repo_slug=$(resolve_repo_slug "$repo_path"); then
    repo_slug=""
  fi
  if [ -z "$repo_slug" ]; then
    inherited_skip_log "owner/repo を解決できず D-3（Issue 番号突合）を skip します"
    return 0
  fi

  # 現存 Issue 一覧を取得（open + closed、Developer 確定）
  #   - 最大 1000 件を取得（NFR 1.1 を満たすため十分大きいが上限を切る）
  #   - timeout を 10 秒で打ち切る（NFR 1.1 / 1.2）
  local existing_nums=""
  local rc=0
  local cmd_prefix=""
  if command -v timeout >/dev/null 2>&1; then
    cmd_prefix="timeout 10"
  fi
  # `$cmd_prefix` を意図的に分割展開して `timeout 10 gh ...` の 2 トークンとして
  # 渡したいため SC2086 を disable する。空文字列の場合は単に `gh ...` になる。
  # shellcheck disable=SC2086
  if ! existing_nums=$($cmd_prefix gh issue list --repo "$repo_slug" --state all --limit 1000 --json number --jq '.[].number' 2>/dev/null); then
    rc=$?
    inherited_skip_log "gh issue list 失敗（rc=${rc}）。D-3（Issue 番号突合）を skip します"
    return 0
  fi

  # 一致しない件数をカウント
  local n
  local missing=0
  local missing_examples=()
  while IFS= read -r n; do
    if [ -z "$n" ]; then
      continue
    fi
    if printf '%s\n' "$existing_nums" | grep -Fxq -- "$n"; then
      :
    else
      missing=$((missing + 1))
      if [ "${#missing_examples[@]}" -lt 3 ]; then
        missing_examples+=( "$n" )
      fi
    fi
  done <<< "$issue_nums"

  # 過半数（> 50%）が現存しなければ警告（Req 1.3）
  #   total * 2 > total + missing*2 すなわち missing*2 > total を整数演算で判定
  if [ "$missing" -gt 0 ] && [ $((missing * 2)) -gt "$total" ]; then
    warn_inherited "orphan-branches" \
      "codex/issue-* ブランチの過半数（${missing}/${total}）が対象 repo の現存 Issue 番号に存在しません。fork/mirror clone 由来の可能性が高いです。"
    local prefix
    prefix="$(inherited_prefix)"
    local ex
    local shown=0
    for ex in "${missing_examples[@]}"; do
      if [ "$shown" -ge 3 ]; then
        break
      fi
      echo "$prefix [orphan-branches]   - Issue #${ex}（現存しない）" >&2
      shown=$((shown + 1))
    done
    if [ "$missing" -gt 3 ]; then
      echo "$prefix [orphan-branches]   (+$((missing - 3)) more)" >&2
    fi
  fi
}

# print_inherited_footer
#   検出ブロックで 1 件以上警告が出ていた場合のみ、末尾に
#   「無視しても install は完了している」旨と README / QUICK-HOWTO 参照を 1 度だけ出す。
print_inherited_footer() {
  if [ "$INHERITED_WARNED_PREVIOUSLY" != "true" ]; then
    return 0
  fi
  local prefix
  prefix="$(inherited_prefix)"
  cat >&2 <<INHERITED_FOOTER
$prefix ─────────────────────────────────────────────────────
$prefix この警告を無視しても install 自体は正常完了しています（exit 0）。
$prefix 推奨対応:
$prefix   - 古い docs/specs/<N>-*/ ディレクトリを確認し、不要なら削除してください
$prefix   - 古い codex/issue-* ブランチを git push origin --delete <branch> で削除してください
$prefix 詳細手順: README.md / QUICK-HOWTO.md の「fork / mirror clone から導入するときの注意」節
$prefix ─────────────────────────────────────────────────────
INHERITED_FOOTER
}

# detect_inherited_artifacts <target-repo-dir>
#   検出 3 関数を順に呼び出すエントリポイント。
#   - D-1（docs/specs/）と D-2 / D-3（codex branches）は独立に判定する
#   - D-2 失敗時は D-3 も skip（D-2 のブランチ一覧が D-3 の入力になるため）
#   - すべて警告が無ければ stdout/stderr に何も出さない（false positive ゼロ）
detect_inherited_artifacts() {
  local repo_path="$1"

  # D-1: docs/specs/<N>-*/
  detect_inherited_specs "$repo_path"

  # D-2: origin の codex/issue-* ブランチ
  #   - 取得成功時に branches をグローバル変数 INHERITED_BRANCHES に格納し、D-3 で再利用
  #   - 取得失敗時は D-2 関数内で skip ログを出し、D-3 も skip する
  #   - command substitution の subshell を避けてグローバル経由で渡すことで、
  #     INHERITED_WARNED_PREVIOUSLY を親シェル側で正しく立てる
  if detect_inherited_codex_branches "$repo_path"; then
    # D-3: 現存 Issue 番号集合と突合（INHERITED_BRANCHES が空なら早期 return される）
    detect_orphan_codex_branches "$repo_path" "$INHERITED_BRANCHES"
  fi

  # 警告が 1 件でも出ていれば末尾フッターを 1 度だけ出す
  print_inherited_footer
}

# 対話モード（引数なし）
if ! $INSTALL_LOCAL && ! $INSTALL_REPO; then
  echo "=== idd-codex install ==="
  echo ""
  read -r -p "対象リポジトリにテンプレートを配置しますか？ [y/N]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    read -r -p "  対象リポジトリのパス [Enter でカレント (./): " REPO_PATH
    REPO_PATH="${REPO_PATH:-./}"
    REPO_PATH="${REPO_PATH/#\~/$HOME}"
    INSTALL_REPO=true
  fi
  read -r -p "ローカル PC に watcher をインストールしますか？ [y/N]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    INSTALL_LOCAL=true
  fi
fi

# ─────────────────────────────────────────────────────────────
# 対象リポジトリへの配置
# ─────────────────────────────────────────────────────────────
if $INSTALL_REPO; then
  # --all などで --repo が明示されなかった場合はカレントディレクトリをデフォルトに
  REPO_PATH="${REPO_PATH:-.}"

  if [ ! -d "$REPO_PATH" ]; then
    echo "Error: リポジトリパスが存在しません: $REPO_PATH" >&2
    exit 1
  fi

  # 絶対パスに正規化（ログ表示とメッセージの一貫性のため）
  REPO_PATH_ABS="$(cd "$REPO_PATH" && pwd)"

  echo ""
  echo "📦 対象リポジトリにファイルを配置: $REPO_PATH_ABS"
  REPO_PATH="$REPO_PATH_ABS"

  # AGENTS.md の挙動分岐（Issue #87 / #208）：
  #   - `--force-codex-md` あり: 明示上書き（`.bak` once-only 退避 + template で上書き）
  #   - `--force-codex-md` なし: 既存 AGENTS.md は据え置き、template を `AGENTS.md.org`
  #     として並置（`--force` 単体でもこちら / Req 1, 2.4）
  # `.bak` once-only 退避は `--force-codex-md` 経路でのみ意味があるため、その時だけ呼ぶ。
  # 既存 `AGENTS.md.bak` はそれ以外の経路では一切触らない（Req 4.1, 4.2, 4.3）。
  if [ "$FORCE_AGENTS_MD" = "true" ]; then
    backup_codex_md_once "$REPO_PATH"
  fi
  copy_codex_md_with_org \
    "$REPO_TEMPLATE_DIR/AGENTS.md" \
    "$REPO_PATH/AGENTS.md"

  copy_agents_rules "$REPO_TEMPLATE_DIR/.codex/agents" "$REPO_PATH/.codex/agents"
  copy_agents_rules "$REPO_TEMPLATE_DIR/.codex/rules"  "$REPO_PATH/.codex/rules"

  copy_template_file \
    "$REPO_TEMPLATE_DIR/.github/ISSUE_TEMPLATE/idd-codex-feature.yml" \
    "$REPO_PATH/.github/ISSUE_TEMPLATE/idd-codex-feature.yml"

  copy_template_file \
    "$REPO_TEMPLATE_DIR/.github/scripts/idd-codex-labels.sh" \
    "$REPO_PATH/.github/scripts/idd-codex-labels.sh" \
    --executable

  cat <<REPO_HINT

  ✅ 配置完了。次の手順:

     1. AGENTS.md をプロジェクト固有の内容に編集（技術スタック・規約など）
     2. git add / commit / push
     3. GitHub ラベルを一括作成: 直後にこの install.sh が自動実行します
        （skip 時のメッセージが出た場合のみ手動 fallback してください。
         opt-out したい場合は --no-labels を付けて再実行）
     4. ローカル watcher をインストールして cron / launchd に登録
        （GitHub Actions 版は Codex 向けの公式・検証済み経路が固まるまで配布しません）
     5. Branch protection（任意）:
          gh api -X PUT repos/<owner>/<repo>/branches/main/protection \\
            -f required_pull_request_reviews.required_approving_review_count=1 \\
            -F enforce_admins=false
REPO_HINT

  # AGENTS.md.org の merge ガイド（Req 6.1, 6.2）
  #   `.org` を NEW / OVERWRITE した場合のみ表示。既存 AGENTS.md 不在で
  #   `.org` を作らなかったケースや、SKIP しかなかったケースでは表示しない。
  if [ "$AGENTS_MD_ORG_TOUCHED" = "true" ]; then
    cat <<'AGENTS_MD_ORG_HINT'

  📝 AGENTS.md.org（最新 template 並置）の merge ガイド:

     既存の AGENTS.md は変更されていません。最新 template を AGENTS.md.org
     として並置しました。差分を確認して必要な箇所だけ手動で取り込んでください。

       diff AGENTS.md AGENTS.md.org              # 差分確認
       diff -u AGENTS.md.org AGENTS.md           # template を base に左右反転
       vimdiff AGENTS.md AGENTS.md.org           # 対話的に merge
       # merge 完了後、必要なら AGENTS.md.org は削除して構いません
       #   （次回 install で template が更新されていれば再作成されます）

     どうしても template で完全上書きしたい場合は、`./install.sh --repo <path> --force-codex-md`
     を使用してください（既存 AGENTS.md は AGENTS.md.bak に once-only 退避されます）。
     注: `--force` 単体は agents / rules のみを上書きし、AGENTS.md は据え置きます。
AGENTS_MD_ORG_HINT
  fi

  # ラベル自動セットアップ（Issue #85）
  #   - 配置完了直後にラベルを冪等作成して、初回 cron で claim ラベル付与に
  #     失敗しないようにする
  #   - fail-soft: 失敗・skip しても install 全体は exit 0 で完走する
  #   - 新ラベルの再 install 伝播（Issue #185）: 直前の copy_template_file で最新の
  #     idd-codex-labels.sh が再配置されるため、template にラベルが追加された後に
  #     install.sh を再実行すると setup_repo_labels が全 LABELS をループし、未存在の
  #     ラベル（codex-awaiting-slot 等）だけを新規作成する。既存ラベルは skip され冪等性を保つ。
  setup_repo_labels "$REPO_PATH"

  # 履歴持ち込みの検出と警告（Issue #115）
  #   - 配置完了直後に、fork/mirror clone 由来の古い docs/specs/ や
  #     codex/issue-* ブランチを検出してユーザーに警告する
  #   - fail-soft: 検出処理が失敗しても install 全体は exit 0 で完走する
  #   - clean な新規 repo では何も出力しない（false positive ゼロ保証）
  detect_inherited_artifacts "$REPO_PATH"
fi

# ─────────────────────────────────────────────────────────────
# ローカル PC への watcher インストール
# ─────────────────────────────────────────────────────────────
if $INSTALL_LOCAL; then
  echo ""
  echo "📦 ローカル PC に watcher をインストール"

  ensure_dir "$HOME/bin"
  ensure_dir "$HOME/.idd-codex/issue-watcher/logs"

  # local-watcher/bin/ 配下の *.sh / *.tmpl をワイルドカードで一括配置。
  # 新規 *.tmpl / *.sh が追加された場合に install.sh を書き換えなくて済む。
  # 配置されるテンプレート例: idd-codex-triage-prompt.tmpl / idd-codex-iteration-prompt.tmpl /
  #   idd-codex-iteration-prompt-design.tmpl（#35 設計 PR 用）
  copy_local_watcher_scripts "$LOCAL_WATCHER_DIR/bin" "$HOME/bin"
  copy_glob_to_homebin "$LOCAL_WATCHER_DIR/bin" "*.tmpl" "$HOME/bin"

  # local-watcher/bin/idd-codex-modules/ 配下の *.sh を $HOME/bin/idd-codex-modules/ へ配置（#177 Part 1）。
  # idd-codex-issue-watcher.sh の動的モジュールローダ（REQUIRED_MODULES）が同階層 idd-codex-modules/ を source する。
  # 必須モジュール（core_utils.sh 等）が欠落すると watcher は起動時に exit 1 で停止するため、
  # 本体 *.sh と同じタイミングで冪等配置する。新規モジュール追加時も install.sh 改修は不要。
  if [ -d "$LOCAL_WATCHER_DIR/bin/idd-codex-modules" ]; then
    ensure_dir "$HOME/bin/idd-codex-modules"
    copy_glob_to_homebin "$LOCAL_WATCHER_DIR/bin/idd-codex-modules" "*.sh" "$HOME/bin/idd-codex-modules" --executable
  fi

  # Optional Codex PreToolUse Guard Hook (#294)。
  # hook script は idd-codex user-scope install dir に配置し、Codex profile config は
  # `${CODEX_HOME:-$HOME/.codex}/idd-codex-guard.config.toml` に生成する。watcher は
  # `IDD_CODEX_HOOKS_ENABLED=true` の時だけ `--profile idd-codex-guard` を付与するため、
  # 本配置だけでは既存挙動は変わらない。
  if [ -d "$LOCAL_WATCHER_DIR/hooks" ]; then
    IDD_CODEX_HOOKS_INSTALL_DIR="${IDD_CODEX_HOOKS_INSTALL_DIR:-$HOME/.idd-codex/hooks}"
    IDD_CODEX_HOOKS_PROFILE_NAME="${IDD_CODEX_HOOKS_PROFILE_NAME:-idd-codex-guard}"
    CODEX_CONFIG_DIR="${CODEX_HOME:-$HOME/.codex}"
    ensure_dir "$IDD_CODEX_HOOKS_INSTALL_DIR"
    ensure_dir "$CODEX_CONFIG_DIR"
    copy_glob_to_homebin "$LOCAL_WATCHER_DIR/hooks" "*.sh" "$IDD_CODEX_HOOKS_INSTALL_DIR" --executable
    copy_glob_to_homebin "$LOCAL_WATCHER_DIR/hooks" "*.md" "$IDD_CODEX_HOOKS_INSTALL_DIR"

    _guard_config_template="$LOCAL_WATCHER_DIR/hooks/idd-codex-guard.config.toml"
    _guard_config_dest="$CODEX_CONFIG_DIR/${IDD_CODEX_HOOKS_PROFILE_NAME}.config.toml"
    _guard_hook_dest="$IDD_CODEX_HOOKS_INSTALL_DIR/idd-codex-guard.sh"
    if [ -f "$_guard_config_template" ]; then
      if ! _guard_expected="$(render_guard_profile_config "$_guard_config_template" "$_guard_hook_dest")"; then
        exit 1
      fi
      # template と generated config は placeholder 展開の分だけ内容が異なるため、既存 dest が
      # generated 内容と一致するかは後段で直接比較する。ここではログ分類用に使う。
      if [ -f "$_guard_config_dest" ]; then
        if [ "$_guard_expected" = "$(cat "$_guard_config_dest")" ]; then
          _guard_action="SKIP"
        else
          _guard_action="OVERWRITE"
        fi
      else
        _guard_action="NEW"
      fi
      case "$_guard_action" in
        SKIP)
          log_action "SKIP" "$_guard_config_dest" "(identical to generated profile)"
          ;;
        NEW|OVERWRITE)
          log_action "$_guard_action" "$_guard_config_dest" "(generated Codex profile)"
          if [ "$DRY_RUN" = "false" ]; then
            printf '%s\n' "$_guard_expected" >"$_guard_config_dest"
          fi
          ;;
      esac
    fi
    unset _guard_config_template _guard_config_dest _guard_hook_dest _guard_action _guard_expected
  fi

  # macOS: launchd
  if [ "$(uname)" = "Darwin" ]; then
    ensure_dir "$HOME/Library/LaunchAgents"
    copy_local_runtime_file \
      "$LOCAL_WATCHER_DIR/LaunchAgents/com.local.idd-codex-issue-watcher.plist" \
      "$HOME/Library/LaunchAgents/com.local.idd-codex-issue-watcher.plist"

    cat <<'LAUNCHD_HINT'

  ✅ 配置完了。次の手順:

     1. plist の EnvironmentVariables を対象リポジトリに合わせて編集
       （$EDITOR ~/Library/LaunchAgents/com.local.idd-codex-issue-watcher.plist）
          - REPO      : owner/your-repo
          - REPO_DIR  : ローカルの git clone のパス

     2. launchd に登録（ユーザースコープ、sudo 不要）
          launchctl load   ~/Library/LaunchAgents/com.local.idd-codex-issue-watcher.plist
          launchctl start  com.local.idd-codex-issue-watcher

     3. ログ確認
          tail -f /tmp/idd-codex-issue-watcher.stderr.log

     4. 複数リポジトリを並行稼働させる場合は plist を repo ごとにコピーして
        Label / REPO / REPO_DIR / StandardOut/ErrorPath を書き換える
        （README.md 「複数リポジトリ運用」参照）

  ※ いずれも sudo 不要。ユーザー $HOME 配下に閉じた設定のため、
     sudo で実行するとファイル所有者が root になり逆に動作しなくなる可能性があります。
LAUNCHD_HINT
  else
    cat <<'CRON_HINT'

  ✅ 配置完了。次の手順:

     1. ~/bin/idd-codex-issue-watcher.sh の先頭 Config（TRIAGE_MODEL 等）を必要に応じて編集
        ※ REPO / REPO_DIR は cron 側で env var として渡すのでファイル編集は不要

     2. cron に登録（**ユーザー crontab**、sudo 不要）
          crontab -e

        以下の行を追記（単一 repo 例）:
          */2 * * * * REPO=owner/your-repo REPO_DIR=$HOME/work/your-repo $HOME/bin/idd-codex-issue-watcher.sh >> $HOME/.idd-codex/issue-watcher/cron.log 2>&1

        複数 repo を並行稼働させる場合（lock/log は REPO から自動分離されます）:
          */2 * * * * REPO=owner/repo-a REPO_DIR=$HOME/work/repo-a $HOME/bin/idd-codex-issue-watcher.sh >> $HOME/.idd-codex/issue-watcher/cron.log 2>&1
          */3 * * * * REPO=owner/repo-b REPO_DIR=$HOME/work/repo-b $HOME/bin/idd-codex-issue-watcher.sh >> $HOME/.idd-codex/issue-watcher/cron.log 2>&1

     3. 動作確認
          tail -f $HOME/.idd-codex/issue-watcher/cron.log
          ls $HOME/.idd-codex/issue-watcher/logs/

  ※ システム全体の /etc/crontab ではなくユーザー crontab（crontab -e）を使ってください。
     sudo は不要、かつ sudo で install.sh を走らせると $HOME 配下のファイル所有者が
     root になり、通常ユーザーで更新・削除できなくなります。
CRON_HINT
  fi

  # 前提ツールチェック
  echo ""
  echo "🔍 前提ツールをチェック:"
  MISSING=()
  for cmd in gh jq codex git flock; do
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "  ✅ $cmd: $(command -v "$cmd")"
    else
      echo "  ❌ $cmd が見つかりません"
      MISSING+=("$cmd")
    fi
  done

  if [ ${#MISSING[@]} -gt 0 ]; then
    echo ""
    echo "  以下のコマンドをインストールしてください: ${MISSING[*]}"
    if [ "$(uname)" = "Darwin" ]; then
      echo "  macOS の場合: brew install gh jq util-linux"
      echo "  Codex CLI:  OpenAI の公式手順に従って codex コマンドをインストールしてください"
    fi
  fi
fi

echo ""
echo "🎉 idd-codex のインストールが完了しました。"
echo "   詳細は README.md を参照してください。"
