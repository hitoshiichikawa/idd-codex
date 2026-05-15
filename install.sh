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
#                    AGENTS.md は --force 指定時のみ従来挙動（.bak 退避＋ template
#                    で上書き）。--force なしでは既存 AGENTS.md は据え置き、
#                    template を AGENTS.md.org として並置（差分時のみ）。
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
    --no-labels)
      SKIP_LABELS=true
      shift
      ;;
    -h|--help)
      sed -n '3,23p' "$0"
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
#   ガイドメッセージ表示判定に使う。SKIP / 既存 AGENTS.md 不在 / `--force`
#   経路では立てない（Req 6.2）。
AGENTS_MD_ORG_TOUCHED=false

# copy_codex_md_with_org <src> <dest>
#   AGENTS.md 専用の安全配置ロジック（Issue #87）。
#   既存 AGENTS.md が編集済みであることを前提に、template を `.org` として
#   並置することで「ユーザー記述が主、template は参考」という関係に反転する。
#
#   - dest 不在 + FORCE=any                 → NEW（template を AGENTS.md として配置、.org は作らない）
#   - dest 存在 + 内容同一                  → SKIP（.org も作らない）
#   - dest 存在 + 差分あり + FORCE=false:
#     - dest.org 不在                       → NEW dest.org（template を並置、本体は据え置き）
#     - dest.org 存在 + 内容同一            → SKIP dest.org
#     - dest.org 存在 + 差分あり            → OVERWRITE dest.org（最新 template に追従）
#   - dest 存在 + 差分あり + FORCE=true:
#     既存 backup_codex_md_once の挙動に委譲（.bak once-only 退避 + template で上書き）。
#     `.org` は触らない（Req 3.4）。
#
#   既存 `AGENTS.md.bak` は本関数では一切触らない（Req 4.1, 4.2）。
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

  # FORCE 指定時は従来挙動（NFR 1.2 / Req 3.1〜3.4）。
  # backup_codex_md_once → copy_template_file 相当のシーケンスを再現するため、
  # 呼び出し側で backup_codex_md_once を先に呼ぶ前提を保ち、本関数では
  # template で上書きするだけに留める。
  if [ "$FORCE" = "true" ]; then
    # `.org` は --force 経路では作らない / 触らない（Req 3.4）
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
        log_action "OVERWRITE" "$dest" "(--force)"
        if [ "$DRY_RUN" = "false" ]; then
          cp "$src" "$dest"
        fi
        ;;
    esac
    return 0
  fi

  # 通常経路（--force なし）
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

  # AGENTS.md は Issue #87 で挙動を分岐：
  #   - `--force` あり: 従来挙動（`.bak` once-only 退避 + template で上書き）
  #   - `--force` なし: 既存 AGENTS.md は据え置き、template を `AGENTS.md.org` として並置
  # `.bak` once-only 退避は `--force` 経路でのみ意味があるため、その時だけ呼ぶ。
  # 既存 `AGENTS.md.bak` は通常経路では一切触らない（Req 4.1, 4.2）。
  if [ "$FORCE" = "true" ]; then
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
     4. 実行基盤:
        Codex 版はローカル watcher を標準経路にしています。
        GitHub Actions 版は公式の Codex 実行方法を検証してから別途追加してください。
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

     どうしても template で完全上書きしたい場合は、`./install.sh --repo <path> --force`
     を使用してください（既存 AGENTS.md は AGENTS.md.bak に once-only 退避されます）。
AGENTS_MD_ORG_HINT
  fi

  # ラベル自動セットアップ（Issue #85）
  #   - 配置完了直後にラベルを冪等作成して、初回 cron で claim ラベル付与に
  #     失敗しないようにする
  #   - fail-soft: 失敗・skip しても install 全体は exit 0 で完走する
  setup_repo_labels "$REPO_PATH"
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
  # 配置されるテンプレート例: idd-codex-triage-prompt.tmpl /
  #   idd-codex-iteration-prompt*.tmpl（#35 設計 PR 用）
  copy_glob_to_homebin "$LOCAL_WATCHER_DIR/bin" "*.sh"   "$HOME/bin" --executable
  copy_glob_to_homebin "$LOCAL_WATCHER_DIR/bin" "*.tmpl" "$HOME/bin"

  # macOS: launchd
  if [ "$(uname)" = "Darwin" ]; then
    ensure_dir "$HOME/Library/LaunchAgents"
    copy_template_file \
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
          */2 * * * * PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin REPO=owner/your-repo REPO_DIR=$HOME/work/your-repo /usr/bin/env bash -lc '$HOME/bin/idd-codex-issue-watcher.sh' >> $HOME/.idd-codex/issue-watcher/cron.log 2>&1

        複数 repo を並行稼働させる場合（lock/log は REPO から自動分離されます）:
          */2 * * * * PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin REPO=owner/repo-a REPO_DIR=$HOME/work/repo-a /usr/bin/env bash -lc '$HOME/bin/idd-codex-issue-watcher.sh' >> $HOME/.idd-codex/issue-watcher/cron.log 2>&1
          */3 * * * * PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin REPO=owner/repo-b REPO_DIR=$HOME/work/repo-b /usr/bin/env bash -lc '$HOME/bin/idd-codex-issue-watcher.sh' >> $HOME/.idd-codex/issue-watcher/cron.log 2>&1

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
  for cmd in gh jq git flock codex; do
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "  ✅ $cmd: $(command -v "$cmd")"
    else
      echo "  ❌ $cmd が見つかりません"
      MISSING+=("$cmd")
    fi
  done
  if command -v bash >/dev/null 2>&1; then
    BASH_PATH="$(command -v bash)"
    BASH_VERSION_TEXT="$(bash -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null || echo unknown)"
    if bash -c '(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) ))' 2>/dev/null; then
      echo "  ✅ bash: $BASH_PATH ($BASH_VERSION_TEXT)"
    else
      echo "  ❌ bash: $BASH_PATH ($BASH_VERSION_TEXT) - local watcher は bash 4.3+ が必要です"
      MISSING+=("bash>=4.3")
    fi
  else
    echo "  ❌ bash が見つかりません"
    MISSING+=("bash>=4.3")
  fi

  if [ ${#MISSING[@]} -gt 0 ]; then
    echo ""
    echo "  以下のコマンドをインストールしてください: ${MISSING[*]}"
    if [ "$(uname)" = "Darwin" ]; then
      echo "  macOS の場合: brew install gh jq git bash util-linux coreutils"
      echo "  Codex:  https://developers.openai.com/codex/cli/"
    fi
  fi
fi

echo ""
echo "🎉 idd-codex のインストールが完了しました。"
echo "   詳細は README.md を参照してください。"
