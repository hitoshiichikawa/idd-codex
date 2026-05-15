#!/usr/bin/env bash
# =============================================================================
# idd-codex bootstrap installer (curl | bash 対応)
#
# このスクリプトは idd-codex を `$HOME/.idd-codex` にクローン（既にあれば更新）し、
# そのうえで同梱の `install.sh` を起動します。
#
# 使い方（すべて推奨順）:
#
# 1) 対話モード（ターミナル直実行）:
#      bash <(curl -fsSL https://raw.githubusercontent.com/hitoshiichikawa/idd-codex/main/setup.sh)
#
# 2) curl パイプ + 引数指定（非対話）:
#      curl -fsSL https://raw.githubusercontent.com/hitoshiichikawa/idd-codex/main/setup.sh \
#        | bash -s -- --repo /path/to/your-project --local
#
# 3) curl パイプ（対話、対応可能なシェル限定）:
#      curl -fsSL https://raw.githubusercontent.com/hitoshiichikawa/idd-codex/main/setup.sh | bash
#      → stdin を /dev/tty に再接続して install.sh の対話プロンプトに入る
#
# オプション（install.sh に転送される）:
#   --repo /path/to/your-project   対象リポジトリにテンプレートを配置
#   --local                        ローカル PC に watcher をインストール
#   --all --repo /path             両方
#   -h | --help                    install.sh のヘルプを表示
#
# 環境変数で挙動を上書き:
#   IDD_CODEX_REPO_URL   クローン元 URL（デフォルト: upstream の main）
#   IDD_CODEX_BRANCH     チェックアウトするブランチ／タグ（デフォルト: main）
#   IDD_CODEX_DIR        クローン先パス（デフォルト: $HOME/.idd-codex）
#
# セキュリティ注意:
#   `curl | bash` はスクリプトが実行前に任意コードを走らせるため、接続先を十分信頼できる
#   場合のみ利用してください。監査したい場合は `curl -fsSL <URL> -o setup.sh` で一度
#   ダウンロードして中身を確認してから `bash setup.sh` を実行するのが安全です。
# =============================================================================

set -euo pipefail

IDD_CODEX_REPO_URL="${IDD_CODEX_REPO_URL:-https://github.com/hitoshiichikawa/idd-codex.git}"
IDD_CODEX_BRANCH="${IDD_CODEX_BRANCH:-main}"
IDD_CODEX_DIR="${IDD_CODEX_DIR:-$HOME/.idd-codex}"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<'HELP'
idd-codex bootstrap installer

Usage:
  bash setup.sh --repo /path/to/your-project --local
  bash setup.sh --all --repo /path/to/your-project
  bash setup.sh --help

Environment:
  IDD_CODEX_REPO_URL   clone source URL
  IDD_CODEX_BRANCH     branch or tag to checkout
  IDD_CODEX_DIR        local clone directory

All other options are forwarded to install.sh after idd-codex is cloned or updated.
HELP
  exit 0
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# sudo 実行の検知と警告
#   idd-codex は $HOME 配下にユーザースコープで配置するため sudo は不要。
#   sudo で実行するとファイル所有者が root になり、後からユーザーで更新できなくなる。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then
  echo "⚠️  sudo で実行されています。idd-codex はユーザースコープ（\$HOME 配下）に" >&2
  echo "   インストールする前提のため sudo は不要です。続行するとファイル所有者が" >&2
  echo "   root になり、通常ユーザーで更新できなくなる可能性があります。" >&2
  echo "   sudo を外して再実行してください。" >&2
  exit 1
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 前提コマンドチェック
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
for cmd in git bash; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' が見つかりません。先にインストールしてください。" >&2
    exit 1
  fi
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 非対話実行（curl パイプ）で引数なしだと install.sh の対話プロンプトに stdin が
# 届かず即エラー／無応答になる。args なしの curl | bash は早期エラーで停止し、
# 代替手段を案内する（`bash <(curl ...)` か、手動インストール）。
#
# 以前は `exec </dev/tty` で stdin を tty に付け替える実装だったが、tmux / screen /
# 特定ターミナル環境で `exec </dev/tty` 自体が無応答になるケースが確認されたため削除。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [ ! -t 0 ] && [ $# -eq 0 ]; then
  cat >&2 <<'PIPE_NO_ARGS'
Error: curl | bash で引数なし実行されました。install.sh が対話プロンプトに入りますが、
       curl パイプ経由では stdin がすでに消費されているため応答できません。

次のいずれかで再実行してください:

  # 1) 引数を付けて非対話実行（カレントディレクトリに配置 + watcher）
  curl -fsSL https://raw.githubusercontent.com/hitoshiichikawa/idd-codex/main/setup.sh \
    | bash -s -- --all

  # 2) プロセス置換でターミナル stdin を保持したまま対話実行
  bash <(curl -fsSL https://raw.githubusercontent.com/hitoshiichikawa/idd-codex/main/setup.sh)

  # 3) 手動インストール（最も確実）
  git clone --depth 1 https://github.com/hitoshiichikawa/idd-codex.git ~/.idd-codex
  bash ~/.idd-codex/install.sh
PIPE_NO_ARGS
  exit 2
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# git 認証プロンプト回避
#   idd-codex は public repo なので認証は不要。credential helper の誤動作で
#   プロンプトが出ると `curl | bash` の stdin では応答できず無限待ちになるため、
#   GIT_TERMINAL_PROMPT=0 でプロンプト自体を無効化して即エラーにする。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
export GIT_TERMINAL_PROMPT=0

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# クローン（未取得） or 更新（既存）
#   --progress で進捗を表示（--quiet だと無応答に見えるため）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [ -d "$IDD_CODEX_DIR/.git" ]; then
  echo "📦 既存のクローンを更新: $IDD_CODEX_DIR (branch=$IDD_CODEX_BRANCH)"
  git -C "$IDD_CODEX_DIR" fetch --depth 1 origin "$IDD_CODEX_BRANCH"
  git -C "$IDD_CODEX_DIR" checkout "$IDD_CODEX_BRANCH" 2>/dev/null || true
  git -C "$IDD_CODEX_DIR" reset --hard "origin/$IDD_CODEX_BRANCH"
else
  # 既存の非 git ディレクトリがある場合は安全のため停止
  if [ -e "$IDD_CODEX_DIR" ]; then
    echo "Error: '$IDD_CODEX_DIR' は git リポジトリではありません。移動または削除してから再実行してください。" >&2
    exit 1
  fi
  echo "📦 idd-codex をクローン: $IDD_CODEX_DIR (branch=$IDD_CODEX_BRANCH)"
  if ! git clone --progress --depth 1 --branch "$IDD_CODEX_BRANCH" \
       "$IDD_CODEX_REPO_URL" "$IDD_CODEX_DIR"; then
    echo "" >&2
    echo "Error: git clone に失敗しました。" >&2
    echo "  - ネットワーク接続を確認してください" >&2
    echo "  - プロキシ設定がある場合は https_proxy 環境変数をセットしてください" >&2
    echo "  - IDD_CODEX_REPO_URL を fork に変えている場合は URL / 認証を確認してください" >&2
    exit 1
  fi
fi

echo ""
echo "🚀 install.sh を起動します"
echo ""
exec bash "$IDD_CODEX_DIR/install.sh" "$@"
