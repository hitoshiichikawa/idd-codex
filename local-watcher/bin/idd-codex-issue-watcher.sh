#!/usr/bin/env bash
# =============================================================================
# idd-codex local issue watcher
#
# GitHub Issue をポーリングし、codex-auto-dev ラベルが付いた未処理 Issue を検出して
# Codex でローカル実行する。
#
# 3 つのモードを状態機械で管理:
#   - design        : PM → Architect → PjM（設計 PR 作成、codex-awaiting-design-review 付与）
#   - impl          : PM → Developer → PjM（小〜中規模、Architect 不要）
#   - impl-resume   : Developer → PjM（設計 PR が merge 済みで docs/specs/<N>-*/ が main に存在）
#
# ラベルによる状態遷移:
#   codex-auto-dev  → codex-claimed (Dispatcher claim) → Triage
#                              → (codex-needs-decisions | codex-awaiting-design-review | codex-picked-up)
#                              → codex-ready-for-review / codex-failed
#
# Stage Checkpoint Resume 経路 (#68, opt-in):
#   STAGE_CHECKPOINT_ENABLED=true で impl / impl-resume の Stage A/B/C 失敗時に
#   完了済み Stage を成果物（impl-notes.md / review-notes.md / 既存 impl PR）の
#   存在で観測し、未完了 Stage 以降のみを再実行する。デフォルト false で従来挙動と
#   完全一致（NFR 1.1）。判定根拠は `stage-checkpoint:` prefix のログで観測可能。
#
# 配置先: ~/bin/idd-codex-issue-watcher.sh
# 依存  : gh / jq / codex / flock / git
#
# セットアップ: このファイル冒頭の ━━━ Config ━━━ ブロックを編集し、
#   launchd (macOS) または cron (Linux) に登録する。README.md を参照。
# =============================================================================

set -euo pipefail

# cron / launchd は対話シェルの profile を読まないため PATH が最小限になり、
# ~/.local/bin や /usr/local/bin にインストールした codex / gh が見つからない。
# 一般的なインストール先を先頭に足しておき、どの起動経路でも同じ挙動にする。
export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Config（環境に合わせて書き換える）
#
# 複数リポジトリ運用:
#   REPO / REPO_DIR は環境変数で上書き可能。各 repo の cron / launchd エントリから
#   env var を渡せば、このスクリプト 1 ファイルを使い回せる。
#   LOCK_FILE / LOG_DIR / TRIAGE_FILE は REPO から自動派生するため衝突しない。
#
#   cron 例:
#     */2 * * * * PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin REPO=owner/a REPO_DIR=$HOME/work/a /usr/bin/env bash -lc '$HOME/bin/idd-codex-issue-watcher.sh'
#     */3 * * * * PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin REPO=owner/b REPO_DIR=$HOME/work/b /usr/bin/env bash -lc '$HOME/bin/idd-codex-issue-watcher.sh'
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# env var で上書き可能（未設定なら下のデフォルトを使う）
REPO="${REPO:-owner/your-repo}"
REPO_DIR="${REPO_DIR:-$HOME/work/your-repo}"

# REPO から repo-unique な slug を導出（lock / log / 一時ファイルの隔離に使う）
REPO_SLUG="$(echo "$REPO" | tr '/' '-')"

LABEL_TRIGGER="codex-auto-dev"
LABEL_CLAIMED="codex-claimed"
LABEL_PICKED="codex-picked-up"
LABEL_NEEDS_DECISIONS="codex-needs-decisions"
LABEL_AWAITING_DESIGN="codex-awaiting-design-review"
LABEL_READY="codex-ready-for-review"
LABEL_FAILED="codex-failed"
LABEL_SKIP_TRIAGE="codex-skip-triage"
LABEL_NEEDS_REBASE="codex-needs-rebase"
LABEL_NEEDS_ITERATION="codex-needs-iteration"
LABEL_NEEDS_QUOTA_WAIT="codex-needs-quota-wait"
LABEL_STAGED_FOR_RELEASE="codex-staged-for-release"

# ─── Base branch 設定 (#89) ───
# watcher 経路（local cron）と Actions 経路の base branch を 1 つの env で切り替える
# ための単一の真実源。未設定時は "main" を採用し、本機能導入前と完全に等価な挙動を維持
# する（Req 1.2, 7.2, NFR 1.1）。gitflow 運用（develop 起点）には cron / launchd 側で
# `BASE_BRANCH=develop` を渡す。詳細は README の「ブランチ運用と BASE_BRANCH」節を参照。
BASE_BRANCH="${BASE_BRANCH:-main}"

# ─── Phase A: Merge Queue Processor 設定 ───
# 既存運用への影響を避けるため、初回導入は opt-in（デフォルト false）。
# 有効化するには cron / launchd 側で MERGE_QUEUE_ENABLED=true を渡す。
MERGE_QUEUE_ENABLED="${MERGE_QUEUE_ENABLED:-false}"
# 1 サイクルで処理する PR 数の上限（残りは次回サイクルに持ち越し）。
MERGE_QUEUE_MAX_PRS="${MERGE_QUEUE_MAX_PRS:-5}"
# git 操作の個別タイムアウト（秒）。watcher の最短実行間隔（既定 2 分）の半分以内を目安。
MERGE_QUEUE_GIT_TIMEOUT="${MERGE_QUEUE_GIT_TIMEOUT:-60}"
# Merge Queue が rebase / merge 試行する base branch 名。env var 名は後方互換のため
# 変更しない（NFR 1.2 / Req 2.4）。未設定時は BASE_BRANCH の連鎖 default を採用する
# （Req 2.1, 2.2, 2.3）。明示設定すれば BASE_BRANCH と異なる base を merge queue だけに
# 適用できる（基本は "main"。レガシー repo で master の場合等）。
MERGE_QUEUE_BASE_BRANCH="${MERGE_QUEUE_BASE_BRANCH:-${BASE_BRANCH}}"
# head branch prefix: 自動 rebase を許可する head ref のプレフィックス。
# idd-codex が作成する PR は `codex/issue-N-*` パターン。人間が書いた PR を
# 巻き込まないよう、デフォルトで `codex/` 始まりだけを対象にする。
# 複数許可したい場合はパイプ区切り正規表現で上書き（例: '^(codex|bot)/'）。
MERGE_QUEUE_HEAD_PATTERN="${MERGE_QUEUE_HEAD_PATTERN:-^codex/}"

# ─── Merge Queue Re-check Processor 設定 (#27) ───
# `codex-needs-rebase` 付き approved PR を別レーンで再評価し、`mergeable=MERGEABLE` に
# 戻った PR のラベルを自動除去する。Phase A 本体（MERGE_QUEUE_ENABLED）とは
# 独立に opt-in 制御するため、デフォルトは false。
MERGE_QUEUE_RECHECK_ENABLED="${MERGE_QUEUE_RECHECK_ENABLED:-false}"
# 1 サイクルで再評価する PR 数の上限（残りは次回サイクルに持ち越し）。
MERGE_QUEUE_RECHECK_MAX_PRS="${MERGE_QUEUE_RECHECK_MAX_PRS:-20}"

# ─── PR Iteration Processor 設定 (#26) ───
# `codex-needs-iteration` ラベル付き PR をレビューコメントに基づいて自動で iterate する。
# 既存運用への影響を避けるため、初回導入は opt-in（デフォルト false）。
# 有効化するには cron / launchd 側で PR_ITERATION_ENABLED=true を渡す。
PR_ITERATION_ENABLED="${PR_ITERATION_ENABLED:-false}"
# Iteration 専用モデル ID（既存 DEV_MODEL とは独立して上書き可能）。
PR_ITERATION_DEV_MODEL="${PR_ITERATION_DEV_MODEL:-gpt-5.5}"
# 1 iteration あたりの Codex 実行 turn 数上限（NFR 1.1）。
PR_ITERATION_MAX_TURNS="${PR_ITERATION_MAX_TURNS:-60}"
# 1 サイクルで処理する PR 数の上限（残りは次回サイクルに持ち越し、AC 1.6 / NFR 1.2）。
PR_ITERATION_MAX_PRS="${PR_ITERATION_MAX_PRS:-3}"
# 1 PR あたりの累計 iteration 上限。到達時は codex-failed に昇格（AC 7.2）。
PR_ITERATION_MAX_ROUNDS="${PR_ITERATION_MAX_ROUNDS:-3}"
# 自動 iteration を許可する head ref のプレフィックス正規表現（impl PR 用）。
# 既定値は idd-codex 管理 branch のみに厳格化する。idd-codex と併存できるよう、
# `claude/` branch は既定では絶対に拾わない。
PR_ITERATION_HEAD_PATTERN="${PR_ITERATION_HEAD_PATTERN:-^codex/issue-[0-9]+-impl-}"
# 各 git / gh 操作の個別タイムアウト（秒、NFR 1.3）。
PR_ITERATION_GIT_TIMEOUT="${PR_ITERATION_GIT_TIMEOUT:-60}"
# Iteration プロンプトテンプレートの配置先（install.sh --local が配置、impl PR 用）。
ITERATION_TEMPLATE="${ITERATION_TEMPLATE:-$HOME/bin/idd-codex-iteration-prompt.tmpl}"

# ─── PR Iteration Processor 設定: 設計 PR 拡張 (#35) ───
# 設計 PR (`codex/issue-<N>-design-<slug>`) にも `codex-needs-iteration` で反復対応する
# opt-in フラグ。既定 false で本機能は無効、impl PR の挙動は #26 導入時と完全同一。
# 有効化するには cron / launchd 側で PR_ITERATION_DESIGN_ENABLED=true を渡す
# （AC 4.1 / 4.4 / 5.1）。
PR_ITERATION_DESIGN_ENABLED="${PR_ITERATION_DESIGN_ENABLED:-false}"
# 設計 PR の head branch pattern（jq の test() 互換 POSIX ERE）。
# idd-codex PjM テンプレートが作る設計 PR は `codex/issue-<N>-design-<slug>` 形式（AC 4.2）。
PR_ITERATION_DESIGN_HEAD_PATTERN="${PR_ITERATION_DESIGN_HEAD_PATTERN:-^codex/issue-[0-9]+-design-}"
# 設計 PR 用 Iteration テンプレートの配置先（install.sh --local が配置）。
ITERATION_TEMPLATE_DESIGN="${ITERATION_TEMPLATE_DESIGN:-$HOME/bin/idd-codex-iteration-prompt-design.tmpl}"

# ─── Design Review Release Processor 設定 (#40) ───
# 設計 PR が merge された Issue から `codex-awaiting-design-review` ラベルを自動除去し、
# ステータスコメントを 1 件投稿する。既存運用（人間が手動でラベルを外す運用）を
# 壊さないため、初回導入は opt-in（デフォルト false）。
# 有効化するには cron / launchd 側で DESIGN_REVIEW_RELEASE_ENABLED=true を渡す。
DESIGN_REVIEW_RELEASE_ENABLED="${DESIGN_REVIEW_RELEASE_ENABLED:-false}"
# 1 サイクルで処理する Issue 数の上限（残りは次回サイクルに持ち越し、AC 5.1 / 5.2）。
DESIGN_REVIEW_RELEASE_MAX_ISSUES="${DESIGN_REVIEW_RELEASE_MAX_ISSUES:-10}"
# 設計 PR の head branch 規約（jq の test() 互換 POSIX ERE）。
# idd-codex PjM テンプレートが作る設計 PR は `codex/issue-<N>-design-<slug>` 形式。
DESIGN_REVIEW_RELEASE_HEAD_PATTERN="${DESIGN_REVIEW_RELEASE_HEAD_PATTERN:-^codex/issue-[0-9]+-design-}"
# 各 gh 操作の個別タイムアウト（秒、AC 5.4）。専用 env var は導入せず、
# Phase A の MERGE_QUEUE_GIT_TIMEOUT を流用してデフォルト 60 秒。
DRR_GH_TIMEOUT="${DRR_GH_TIMEOUT:-${MERGE_QUEUE_GIT_TIMEOUT:-60}}"

# ─── Stage Checkpoint 設定 (#68) ───
# impl / impl-resume の Stage A/B/C 単位で完了 checkpoint を成果物
# （impl-notes.md / review-notes.md / 既存 impl PR）の有無で観測し、失敗 Stage 以降
# のみを再実行する opt-in 機能。既存運用への影響を避けるため、初回導入は opt-in
# （デフォルト false）。`true` のみが opt-in で、空文字 / `0` / `False` / typo は
# すべて opt-out として解釈される（Req 3.3、安全側）。
# 有効化するには cron / launchd 側で STAGE_CHECKPOINT_ENABLED=true を渡す。
STAGE_CHECKPOINT_ENABLED="${STAGE_CHECKPOINT_ENABLED:-false}"

# LOG_DIR と LOCK_FILE は REPO_SLUG を挟むことで repo ごとに分離。
# 環境変数で明示上書きもできる。
LOG_DIR="${LOG_DIR:-$HOME/.idd-codex/issue-watcher/logs/$REPO_SLUG}"
LOCK_FILE="${LOCK_FILE:-/tmp/idd-codex-issue-watcher-${REPO_SLUG}.lock}"

# モデル設定
TRIAGE_MODEL="${TRIAGE_MODEL:-gpt-5.4-mini}"   # Triage は軽量モデルで十分
DEV_MODEL="${DEV_MODEL:-gpt-5.5}"
TRIAGE_MAX_TURNS="${TRIAGE_MAX_TURNS:-15}"
DEV_MAX_TURNS="${DEV_MAX_TURNS:-60}"
TRIAGE_REASONING_EFFORT="${TRIAGE_REASONING_EFFORT:-medium}"
DEV_REASONING_EFFORT="${DEV_REASONING_EFFORT:-high}"

# ─── Reviewer role 設定 (#20 Phase 1) ───
# impl 系モード（impl / impl-resume）の Developer 完了後に独立 context で起動する
# Reviewer 役割用の env。既存の TRIAGE_* / DEV_* と独立に扱う。
REVIEWER_MODEL="${REVIEWER_MODEL:-gpt-5.5}"
REVIEWER_MAX_TURNS="${REVIEWER_MAX_TURNS:-30}"
REVIEWER_REASONING_EFFORT="${REVIEWER_REASONING_EFFORT:-high}"

# ─── Codex CLI 設定 ───
# npm / Homebrew の wrapper が壊れている環境でも固定パスを指定できるようにする。
CODEX_BIN="${CODEX_BIN:-codex}"
CODEX_UNSAFE_BYPASS="${CODEX_UNSAFE_BYPASS:-true}"
CODEX_SANDBOX="${CODEX_SANDBOX:-danger-full-access}"
CODEX_APPROVAL_POLICY="${CODEX_APPROVAL_POLICY:-never}"
CODEX_EPHEMERAL="${CODEX_EPHEMERAL:-true}"
CODEX_LAST_MESSAGE_DIR="${CODEX_LAST_MESSAGE_DIR:-$LOG_DIR/codex-last-messages}"

# ─── Quota-Aware Watcher 設定 (#66) ───
# Codex の 5 時間ローリング quota を Codex CLI の `rate_limit_event` JSON で
# 検知し、quota 起因の停止と他失敗を `codex-needs-quota-wait` ラベルで分離する。
# reset 経過後に Quota Resume Processor が自動でラベル除去して通常 pickup に戻す。
# 既存運用への影響を避けるため、初回導入は opt-in（デフォルト false / Req 1.3, 1.5）。
# 有効化するには cron / launchd 側で QUOTA_AWARE_ENABLED=true を渡す。
QUOTA_AWARE_ENABLED="${QUOTA_AWARE_ENABLED:-false}"
# reset 予定時刻 + 本秒数を経過するまで `codex-needs-quota-wait` を除去しない（NFR 3.3:
# 同 cron tick 内で付与/除去を往復させない構造的抑止）。
QUOTA_RESUME_GRACE_SEC="${QUOTA_RESUME_GRACE_SEC:-60}"

# ─── Phase C: Issue 並列化 (worktree slot + dispatcher, #16) ───
# 入口（codex-auto-dev Issue 処理）の並列度を制御する env var 群。
# 既存運用との後方互換のため、すべてデフォルトで本機能導入前と同一挙動になるよう配置:
#   - PARALLEL_SLOTS 未設定 → 直列（slot=1）動作。slot-2 以降の lock / worktree は作成しない
#   - SLOT_INIT_HOOK 未設定 → フック非起動（本機能導入前と同一）
#   - WORKTREE_BASE_DIR / SLOT_LOCK_DIR は通常上書き不要。テスト用に override 可能。
# 詳細: docs/specs/16-phase-c-worktree-slot-dispatcher/design.md
PARALLEL_SLOTS="${PARALLEL_SLOTS:-1}"
SLOT_INIT_HOOK="${SLOT_INIT_HOOK:-}"
WORKTREE_BASE_DIR="${WORKTREE_BASE_DIR:-$HOME/.idd-codex/issue-watcher/worktrees}"
SLOT_LOCK_DIR="${SLOT_LOCK_DIR:-$HOME/.idd-codex/issue-watcher}"

# ─── impl-resume 保護 (Issue #67) ───
# `impl-resume` モードで対象ブランチが origin に既存する場合、当該ブランチの commit を
# 保持したまま resume する opt-in 機能。既存運用への影響を避けるため初回導入は opt-in
# （デフォルト false）。`true` の場合のみ、既存 origin branch から resume + fast-forward
# 制約 push + 非 fast-forward 検出時の `codex-failed` 安全停止が有効化される。
# `false` の場合は本機能導入前と完全に等価な挙動（origin/$BASE_BRANCH 起点での強制リセット +
# `git push --force-with-lease`）を維持する（Req 1.1, 1.2, 4.4, NFR 1.1）。
IMPL_RESUME_PRESERVE_COMMITS="${IMPL_RESUME_PRESERVE_COMMITS:-false}"
# Developer がタスクを完了した時点で `tasks.md` の対応する未完了マーカー (`- [ ]`) を
# 完了マーカー (`- [x]`) に書き換え、`docs(tasks): mark <id> as done` で commit する
# 規約を有効化するフラグ。既定 `true` だが、`IMPL_RESUME_PRESERVE_COMMITS=false`
# （opt-in 機能 OFF）の状態では Developer prompt 注入経路を通らないため、結果的に
# 進捗追跡指示は注入されない（NFR 1.1 を構造的に保証）。`false` に明示すると
# `IMPL_RESUME_PRESERVE_COMMITS=true` の場合でも進捗マーカー更新指示を抑止できる
# （Req 3.1, 3.2, 3.6）。
IMPL_RESUME_PROGRESS_TRACKING="${IMPL_RESUME_PROGRESS_TRACKING:-true}"

# Triage プロンプトテンプレート
TRIAGE_TEMPLATE="${TRIAGE_TEMPLATE:-$HOME/bin/idd-codex-triage-prompt.tmpl}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 前提ツールチェック
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
for cmd in gh jq git flock timeout; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Error: $cmd が見つかりません。PATH を確認してください。" >&2
    exit 1
  }
done

command -v "$CODEX_BIN" >/dev/null 2>&1 || {
  echo "Error: Codex CLI が見つかりません: $CODEX_BIN" >&2
  echo "  CODEX_BIN=/path/to/codex を指定するか、PATH を確認してください。" >&2
  exit 1
}

[ -f "$TRIAGE_TEMPLATE" ] || {
  echo "Error: Triage テンプレートが見つかりません: $TRIAGE_TEMPLATE" >&2
  exit 1
}

# PR Iteration が有効化されている時のみ template の存在を必須化（opt-in gate）。
# 無効化（既定）時は template 未配置でも watcher 全体を起動できるよう、無条件チェックを避ける。
if [ "$PR_ITERATION_ENABLED" = "true" ] && [ ! -f "$ITERATION_TEMPLATE" ]; then
  echo "Error: Iteration テンプレートが見つかりません: $ITERATION_TEMPLATE" >&2
  echo "  install.sh --local 再実行で配置されます。" >&2
  exit 1
fi

# 設計 PR Iteration が有効化されている時のみ design 用 template を必須化（#35 AC 2.2）。
if [ "$PR_ITERATION_ENABLED" = "true" ] \
   && [ "$PR_ITERATION_DESIGN_ENABLED" = "true" ] \
   && [ ! -f "$ITERATION_TEMPLATE_DESIGN" ]; then
  echo "Error: 設計 PR 用 Iteration テンプレートが見つかりません: $ITERATION_TEMPLATE_DESIGN" >&2
  echo "  install.sh --local 再実行で配置されます。" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
mkdir -p "$CODEX_LAST_MESSAGE_DIR"

# 解決済み base branch を起動時 log に出力（Req 1.7 / NFR 4.1）。
# 運用者が cron mailer / log で `base-branch=...` を grep できるよう、
# 既定値（main）でも明示的に出力する。
echo "[$(date '+%F %T')] base-branch=${BASE_BRANCH} merge-queue-base=${MERGE_QUEUE_BASE_BRANCH}"

codex_reasoning_effort_for_stage() {
  local stage="$1"
  case "$stage" in
    Triage) echo "$TRIAGE_REASONING_EFFORT" ;;
    Reviewer-*) echo "$REVIEWER_REASONING_EFFORT" ;;
    *) echo "$DEV_REASONING_EFFORT" ;;
  esac
}

codex_exec_prompt() {
  local stage_label="$1"
  local model="$2"
  local prompt="$3"
  local effort
  effort="$(codex_reasoning_effort_for_stage "$stage_label")"

  local safe_stage
  safe_stage="$(printf '%s' "$stage_label" | tr -cs '[:alnum:]_.-' '-')"
  local last_message_file="$CODEX_LAST_MESSAGE_DIR/${NUMBER:-unknown}-${safe_stage}-$(date +%Y%m%d-%H%M%S).txt"

  local args=(
    exec
    -C "$REPO_DIR"
    -m "$model"
    --json
    --output-last-message "$last_message_file"
    -c "model_reasoning_effort=\"$effort\""
  )

  if [ "$CODEX_EPHEMERAL" = "true" ]; then
    args+=(--ephemeral)
  fi

  if [ "$CODEX_UNSAFE_BYPASS" = "true" ]; then
    args+=(--dangerously-bypass-approvals-and-sandbox)
  else
    args+=(--sandbox "$CODEX_SANDBOX")
  fi

  if [ "$CODEX_UNSAFE_BYPASS" = "true" ]; then
    printf '%s' "$prompt" | "$CODEX_BIN" "${args[@]}" -
  else
    printf '%s' "$prompt" | "$CODEX_BIN" \
      --ask-for-approval "$CODEX_APPROVAL_POLICY" \
      "${args[@]}" -
  fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 多重起動防止
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exec 200>"$LOCK_FILE"
flock -n 200 || {
  echo "[$(date '+%F %T')] 他のインスタンスが実行中のためスキップ"
  exit 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# リポジトリを最新化
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
cd "$REPO_DIR"
git fetch origin --prune
git checkout "$BASE_BRANCH"
git pull --ff-only origin "$BASE_BRANCH"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Quota-Aware Watcher Helpers (#66)
#   Codex の 5 時間ローリング quota 超過を、Stage 実行中の Codex CLI が出す
#   `rate_limit_event` (status=exceeded) JSON で検知する。検知時は当該 Issue を
#   `codex-needs-quota-wait` 状態にし、reset 予定時刻を Issue body の hidden marker として
#   永続化。次サイクル以降の Quota Resume Processor が reset+grace 経過した Issue
#   からラベルを除去して通常 pickup ループに戻す。
#
#   QUOTA_AWARE_ENABLED=false（既定）では本セクションの全関数は呼ばれるが、
#   gate 早期 return で副作用を一切起こさない。Stage Wrapper も `"$@"` 素通しで
#   既存挙動 100% 互換（Req 1.1, NFR 2.1）。
#
#   設計参照: docs/specs/66-feat-watcher-codex-max-quota-rate-limit/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# quota-aware 専用ロガー（既存 mq_log / pi_log と同形式 / NFR 1.1, 1.2）
qa_log() {
  echo "[$(date '+%F %T')] quota-aware: $*"
}
qa_warn() {
  echo "[$(date '+%F %T')] quota-aware: WARN: $*" >&2
}
qa_error() {
  echo "[$(date '+%F %T')] quota-aware: ERROR: $*" >&2
}

# epoch 秒 → ISO 8601 (タイムゾーン付き) 文字列。GNU date / BSD date 両対応。
# 失敗時は epoch をそのまま返す（escalation コメントの整合性維持）。
# Args: $1 = epoch seconds (integer)
# Stdout: ISO 8601 string with TZ offset (e.g. "2026-04-29T15:00:00+09:00")
qa_format_iso8601() {
  local epoch="$1"
  local out=""
  # GNU date (Linux): -d @epoch -Iseconds
  if out=$(date -d "@${epoch}" -Iseconds 2>/dev/null) && [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  # BSD date (macOS): -r epoch +format
  if out=$(date -r "${epoch}" "+%Y-%m-%dT%H:%M:%S%z" 2>/dev/null) && [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  # フォールバック: epoch をそのまま返す
  printf '%s' "$epoch"
}

# stdin の stream-json（1 行 1 JSON）を fold し、quota 枯渇イベントを検出して
# `<detection_path>\t<reset_epoch>` 形式の TSV を 1 検出 1 行で stdout に出力する
# （Req 1.1〜1.4, 2.1〜2.2, 3.1〜3.4, 5.1〜5.4 / Issue #66 Req 2.x との後方互換）。
#
# 検出経路（detection_path フィールド値）:
#   - `rate_limit_event_v2`  : 現行 Codex CLI スキーマ
#                              `type==rate_limit_event` かつ
#                              `rate_limit_info.status == "rejected"`
#                              （Issue #104 Bug 1 / Req 1.1）
#   - `rate_limit_event_v1`  : 旧スキーマ
#                              `type==rate_limit_event` かつ `status == "exceeded"`
#                              （Req 2.1 / Issue #66 互換維持）
#   - `synthetic_429_result` : quota 枯渇直撃時の synthetic result 行
#                              `type==result` かつ `is_error == true` かつ
#                              `api_error_status == 429`
#                              （Issue #104 Bug 2 / Req 3.1）
#
# Reset 時刻フィールド探索順（現行 / 旧スキーマ揺れと synthetic 429 同居を許容）:
#   1) .rate_limit_info.resetsAt / .resets_at / .reset_at  （現行スキーマ ネスト位置 / Req 1.3）
#   2) .resetsAt / .reset_at / .resets_at                  （旧スキーマ top-level / Req 2.2）
#   値の型が数値ならそのまま epoch、ISO 8601 文字列なら `fromdateiso8601` で epoch 化。
#   いずれも取得できなければ空（呼び出し側で reset 欠落 fallback / Req 1.4, 3.2）。
#
# 出力契約:
#   - 1 検出 1 行: `<detection_path>\t<epoch_or_empty>`
#   - 解析失敗（非 JSON / schema 違い）の行は無視して継続（Req 2.5 / Issue #66）
#   - allowed のみ / 通常 result（is_error:false）は無視（Req 3.4）
#   - 同一 stream に複数検出があっても全件出力（呼び出し側で `tail -1` 等を選択）
#
# 実装メモ: jq は default だと stdin を "concatenated JSON" として一括 parse する
# ため、無効な 1 行があると stream 全体が fatal で止まる。stream を停止させない
# 要件（Req 2.5）を満たすため、`-R`（raw input）で 1 行ずつ受け取り、各行を
# `try fromjson catch null` で個別 parse する。
qa_detect_rate_limit() {
  jq -R -r '
    # 入力 1 行を JSON object に折りたたむ。fromjson 失敗 / 非 object は捨てる。
    . as $line
    | (try ($line | fromjson) catch null)
    | select(type == "object") as $j

    # detection_path を 3 経路で識別（先頭で優先度を決定し、最初に match した
    # 経路を採用）。マッチしなければ empty で当該行を捨てる。
    | (
        if ($j.type? == "rate_limit_event")
           and (($j.rate_limit_info? // {}).status? == "rejected") then
          "rate_limit_event_v2"
        elif ($j.type? == "rate_limit_event")
             and ($j.status? == "exceeded") then
          "rate_limit_event_v1"
        elif ($j.type? == "result")
             and ($j.is_error? == true)
             and ($j.api_error_status? == 429) then
          "synthetic_429_result"
        else
          empty
        end
      ) as $path

    # reset epoch 候補値: 現行スキーマ ネスト → 旧スキーマ top-level の順で探索。
    # 値が無ければ null を bind（empty を bind すると jq 仕様により当該行が消える）。
    | (
        ($j.rate_limit_info? // {})
        | (.resetsAt // .resets_at // .reset_at // null)
      ) as $nested
    | (
        $j
        | (.resetsAt // .reset_at // .resets_at // null)
      ) as $top
    | (if $nested != null then $nested else $top end) as $raw

    # epoch 化: number はそのまま floor、string は ISO 8601 → epoch、それ以外は空。
    | (
        if $raw == null then ""
        elif ($raw | type) == "number" then ($raw | floor | tostring)
        elif ($raw | type) == "string" then
          (try ($raw | fromdateiso8601 | tostring)
            catch (try ($raw | tonumber | floor | tostring) catch ""))
        else "" end
      ) as $epoch_str

    # 出力: <detection_path>\t<epoch_or_empty>
    | "\($path)\t\($epoch_str)"
  ' 2>/dev/null
}

# 既存 6 stage の Codex 呼び出しを横断ラップする Stage Wrapper（Req 1.1, 1.2,
# 2.1, NFR 2.1）。
#
# 引数: <stage_label> <reset_file> -- <command> [args...]
# Returns:
#   0     : Codex 正常終了 + quota 検出なし（既存挙動互換）
#   99    : quota 検出（reset epoch が $reset_file に書かれている）
#   N≠0,99: Codex 自体の非ゼロ exit（quota 以外の失敗、既存フロー委譲）
#
# 副作用:
#   - $LOG（呼び出し側で設定済み）に stream 出力を追記
#   - $reset_file は空（quota 検出なし）または epoch 1 行
qa_run_codex_stage() {
  local stage_label="$1"
  local reset_file="$2"
  shift 2
  # 引数 separator '--' を skip
  if [ "${1:-}" = "--" ]; then
    shift
  fi

  # opt-out: 既存挙動の素通し実行。tee も解析も走らない（Req 1.1, NFR 2.1）。
  if [ "$QUOTA_AWARE_ENABLED" != "true" ]; then
    "$@"
    return $?
  fi

  # opt-in: stream-json を tee で 2 系統に分岐
  #   系統 1: 既存 $LOG への append（観測ログを破壊しない）
  #   系統 2: qa_detect_rate_limit への pipe → 検出 TSV を中間ファイルに書き出し
  : > "$reset_file"
  local detect_file="${reset_file}.detect"
  : > "$detect_file"
  qa_log "stage start label=$stage_label"

  # set -e / pipefail 配下で個別の非 0 exit を握り潰すため、PIPESTATUS を即座に
  # 配列コピーしてから判断する。`|| true` は PIPESTATUS を 0 で上書きしてしまう
  # ため使えない（Issue #104 で発覚 / 既存 Issue #66 実装の latent bug 修正）。
  # set +e/-e で囲って pipefail 起因の即時 exit を一時的に抑止し、
  # PIPESTATUS[0] = Codex 本体 exit code を確実に取り出す。
  local codex_rc=0
  set +e
  "$@" 2>&1 | tee -a "$LOG" | qa_detect_rate_limit > "$detect_file"
  local _qa_pipestatus=("${PIPESTATUS[@]}")
  set -e
  codex_rc="${_qa_pipestatus[0]:-0}"

  # 検出 TSV を解釈する。
  # 優先順位:
  #   1) epoch を持つ検出のうち最新行を採用 → exit 99 経路（reset 永続化に必要）
  #   2) 1 が無く epoch なし検出のみある場合 → 既存フロー fallback + warn
  #      （quota 枯渇は事実だが reset 不明では Resume Processor が機能しないため、
  #      codex_rc を透過。Stage C は別途 PR 実在 verify で虚偽成功を防ぐ /
  #      Req 1.4 / Req 3.2 / Issue #66 後方互換）
  #   3) 検出ゼロ → codex_rc 透過
  if [ -s "$detect_file" ]; then
    local _epoch_line _path _epoch
    _epoch_line=$(awk -F '\t' 'NF >= 2 && $2 ~ /^[0-9]+$/ { last = $0 } END { print last }' "$detect_file")
    if [ -n "$_epoch_line" ]; then
      _path="${_epoch_line%%$'\t'*}"
      _epoch="${_epoch_line#*$'\t'}"
      _epoch=$(printf '%s' "$_epoch" | tr -d '[:space:]')
      printf '%s\n' "$_epoch" > "$reset_file"
      qa_log "stage detected exceeded label=$stage_label path=${_path} reset_epoch=$_epoch"
      rm -f "$detect_file"
      return 99
    fi

    # epoch 付き検出ゼロだが、検出経路だけは観測できたケース
    local _last_line
    _last_line=$(tail -1 "$detect_file")
    _path="${_last_line%%$'\t'*}"
    qa_warn "stage detected without reset label=$stage_label path=${_path} (既存フローに委譲 / codex_rc=$codex_rc)"
    : > "$reset_file"
  fi
  rm -f "$detect_file"
  return "$codex_rc"
}

# Issue body の hidden marker として reset 予定時刻を 1 件のみ保持する形で
# 永続化する（Req 4.1, 4.3）。既存 marker 行があれば全削除してから新値を追記。
#
# Args: $1 = issue number, $2 = reset epoch (integer)
# Return: 0 = persisted, 1 = gh failure (warn only, do not fail caller)
qa_persist_reset_time() {
  local issue_number="$1"
  local epoch="$2"
  local body
  if ! body=$(gh issue view "$issue_number" --repo "$REPO" --json body --jq '.body' 2>/dev/null); then
    return 1
  fi
  # 既存 marker 行を全削除（複数あったとしても落とす）
  local cleaned
  cleaned=$(printf '%s\n' "$body" | sed -E '/<!-- idd-codex:quota-reset:[0-9]+:v1 -->/d')
  # body 末尾を空行 1 つで区切って marker を 1 行追記
  local new_body
  new_body=$(printf '%s\n\n<!-- idd-codex:quota-reset:%s:v1 -->' "$cleaned" "$epoch")
  if ! gh issue edit "$issue_number" --repo "$REPO" --body "$new_body" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# Issue body から hidden marker を読み出して reset epoch を返す（Req 4.2, 4.4）。
# marker 不在 / 不正値 / API 失敗いずれの場合も数値以外を返さない。
#
# Args: $1 = issue number
# Stdout: epoch (integer) on success, empty on failure
# Return: 0 = found, 1 = absent or malformed (caller must skip removal)
qa_load_reset_time() {
  local issue_number="$1"
  local body
  if ! body=$(gh issue view "$issue_number" --repo "$REPO" --json body --jq '.body' 2>/dev/null); then
    return 1
  fi
  local epoch
  epoch=$(printf '%s' "$body" \
    | sed -nE 's/.*<!-- idd-codex:quota-reset:([0-9]+):v1 -->.*/\1/p' \
    | tail -1)
  if [[ "$epoch" =~ ^[0-9]+$ ]]; then
    printf '%s' "$epoch"
    return 0
  fi
  return 1
}

# escalation コメント本文を組み立てる（design.md 「Escalation Comment Template」を逐語使用）。
# Args: $1 = stage label, $2 = epoch, $3 = ISO 8601 string
# Stdout: コメント本文（markdown）
qa_build_escalation_comment() {
  local stage_label="$1" epoch="$2" iso8601="$3"
  cat <<EOF
## ⏸️ Codex quota exceeded（quota wait）

watcher が \`${stage_label}\` 実行中に Codex CLI から \`rate_limit_event (status=exceeded)\` を検知しました。
当該 Issue を一時的に **\`codex-needs-quota-wait\`** 状態にしています。Codex の 5 時間ローリング quota
が reset された後、watcher が自動的に通常 pickup ループへ戻します。

### 検知情報

- 検知 Stage: \`${stage_label}\`
- reset 予定時刻 (UNIX epoch): \`${epoch}\`
- reset 予定時刻 (ISO 8601): \`${iso8601}\`
- 適用 grace 秒数: \`${QUOTA_RESUME_GRACE_SEC}\` 秒（reset 後この秒数を経過するまで pickup を抑止）

### 自動復帰の条件

- 次サイクルの Quota Resume Processor が、現在時刻が \`reset 予定時刻 + grace\` を超えていることを
  検知すると、\`codex-needs-quota-wait\` ラベルを自動除去します
- ラベル除去後の cron tick で Dispatcher が通常 pickup 候補として再選定します
- \`codex-failed\` ラベルは付与していません（quota 起因と他失敗の混同を避けるため、Req 3.2）

### 手動介入したい場合

- 即時再開: \`codex-needs-quota-wait\` ラベルを手動で外すと次サイクルで pickup されます
- quota 起因でないと判断する場合: 当該 Issue body の \`<!-- idd-codex:quota-reset:...:v1 -->\` 行を
  削除した上で \`codex-needs-quota-wait\` を \`codex-failed\` に手動付け替えしてください

---

_本コメントは Quota-Aware Watcher（Issue #66）が自動投稿しました。_
EOF
}

# quota 検知時の副作用（永続化 → ラベル付け替え → escalation コメント → ログ）を
# 1 関数で原子的に実行する（Req 3.1, 3.2, 3.3, 3.4, 3.7, 4.1, NFR 1.1, 1.2）。
# `codex-failed` は **付与しない**（Req 3.2）。
#
# Args: $1 = issue number, $2 = stage label, $3 = reset epoch
# Return: 0 always（副作用失敗は warn でログ、呼び出し側はラベル付与済み前提で続行）
qa_handle_quota_exceeded() {
  local issue_number="$1" stage_label="$2" epoch="$3"
  local iso8601
  iso8601=$(qa_format_iso8601 "$epoch")

  # 1. 永続化（失敗してもラベル付与に進む。次 tick で再判定可能）
  if ! qa_persist_reset_time "$issue_number" "$epoch"; then
    qa_warn "issue=$issue_number stage=$stage_label reset 永続化に失敗（ラベル付与は継続）"
  fi

  # 2. ラベル付け替え（codex-claimed / codex-picked-up を除去 → codex-needs-quota-wait 付与。
  #    codex-failed は付与しない / Req 3.2）
  if ! gh issue edit "$issue_number" --repo "$REPO" \
      --remove-label "$LABEL_CLAIMED" \
      --remove-label "$LABEL_PICKED" \
      --add-label "$LABEL_NEEDS_QUOTA_WAIT" >/dev/null 2>&1; then
    qa_warn "issue=$issue_number stage=$stage_label ラベル付け替えに失敗"
  fi

  # 3. escalation コメント
  local comment_body
  comment_body=$(qa_build_escalation_comment "$stage_label" "$epoch" "$iso8601")
  if ! gh issue comment "$issue_number" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1; then
    qa_warn "issue=$issue_number stage=$stage_label escalation コメント投稿に失敗"
  fi

  # 4. ログ（NFR 1.1, 1.2 / grep 可能形式）
  qa_log "exceeded issue=#$issue_number stage=$stage_label reset_epoch=$epoch reset_iso=$iso8601 grace_sec=$QUOTA_RESUME_GRACE_SEC"
  return 0
}

# Quota Resume Processor: cron tick 冒頭で `codex-needs-quota-wait` 付き Issue を走査し、
# reset+grace 経過分のラベルを自動除去する（Req 5.1〜5.6, NFR 3.1〜3.3）。
#
# - opt-out 時は即時 return 0（NFR 2.1）
# - 0 件時は API 1 回で return 0（NFR 3.1）
# - 各 Issue で reset 取得失敗 / 不正値はラベル維持（Req 4.4）
# - API 失敗は warn 吸収して return 0 を保証（Req 5.6）
process_quota_resume() {
  if [ "$QUOTA_AWARE_ENABLED" != "true" ]; then
    return 0
  fi
  qa_log "Resume Processor 開始 (grace=${QUOTA_RESUME_GRACE_SEC}s)"

  local issues_json
  if ! issues_json=$(gh issue list --repo "$REPO" \
        --label "$LABEL_NEEDS_QUOTA_WAIT" --state open \
        --json number --limit 50 2>/dev/null); then
    qa_warn "codex-needs-quota-wait Issue 取得に失敗（後続 Processor 継続）"
    return 0
  fi

  local count
  count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null || echo 0)
  if [ "$count" -eq 0 ]; then
    qa_log "対象 Issue なし"
    return 0
  fi

  local now_epoch
  now_epoch=$(date -u +%s)

  local issue_number reset_epoch threshold
  while IFS= read -r issue_number; do
    [ -z "$issue_number" ] && continue
    if ! reset_epoch=$(qa_load_reset_time "$issue_number"); then
      qa_warn "issue=$issue_number reset 時刻読み出し失敗 → ラベル維持（Req 4.4）"
      continue
    fi
    threshold=$((reset_epoch + QUOTA_RESUME_GRACE_SEC))
    if [ "$now_epoch" -lt "$threshold" ]; then
      qa_log "issue=#$issue_number waiting reset_epoch=$reset_epoch now=$now_epoch wait_sec=$((threshold - now_epoch))"
      continue
    fi
    if gh issue edit "$issue_number" --repo "$REPO" \
        --remove-label "$LABEL_NEEDS_QUOTA_WAIT" >/dev/null 2>&1; then
      qa_log "resumed issue=#$issue_number reset_epoch=$reset_epoch reset_iso=$(qa_format_iso8601 "$reset_epoch") elapsed_sec=$((now_epoch - reset_epoch))"
    else
      qa_warn "issue=$issue_number ラベル除去に失敗（次サイクルで再評価）"
    fi
  done < <(printf '%s' "$issues_json" | jq -r '.[].number')

  return 0
}

# Quota Resume Processor を全 Processor の先頭で実行する（Req 5.1, 5.6 / NFR 3.2）。
# 失敗時も後続 Processor を阻害しないよう || qa_warn で吸収。
process_quota_resume || qa_warn "process_quota_resume が想定外のエラーで終了しました（後続 Processor は継続）"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase A: Merge Queue Processor
#   approve 済み open PR の mergeability を能動的に検知し:
#     - CONFLICTING: codex-needs-rebase ラベル + 状況コメント（人間判断に回す）
#     - MERGEABLE かつ base が古い: ローカルで自動 rebase + force-with-lease push
#   既存運用との後方互換のため MERGE_QUEUE_ENABLED=true で opt-in。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# merge-queue 専用ロガー（識別用 prefix と timestamp 形式を Issue Watcher と揃える）
mq_log() {
  echo "[$(date '+%F %T')] merge-queue: $*"
}
mq_warn() {
  echo "[$(date '+%F %T')] merge-queue: WARN: $*" >&2
}
mq_error() {
  echo "[$(date '+%F %T')] merge-queue: ERROR: $*" >&2
}

# PR ラベル一覧に特定ラベルが含まれるかを判定（jq で labels 配列を走査）
mq_pr_has_label() {
  local pr_json="$1"
  local label="$2"
  echo "$pr_json" | jq -e --arg l "$label" '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1
}

# CONFLICTING PR にラベル + 状況コメントを投稿（重複抑止つき）
# 失敗しても次の PR に進むよう、戻り値ではなく内部で WARN を出す
mq_handle_conflict() {
  local pr_number="$1"
  local pr_json="$2"
  local pr_url
  pr_url=$(echo "$pr_json" | jq -r '.url')

  # AC 2.2: 既に codex-needs-rebase が付いている場合はラベル付与/コメントとも skip
  if mq_pr_has_label "$pr_json" "$LABEL_NEEDS_REBASE"; then
    mq_log "PR #${pr_number}: CONFLICTING (already labeled, skip)"
    return 0
  fi

  # AC 2.4: conflict したファイル粒度を含めるため、PR の変更ファイル一覧を取得。
  # mergeable=CONFLICTING の段階では merge できないため、簡易的に PR の files
  # 一覧（最大 50 件）をコメントに含める。Phase B 以降で staging branch 経由の
  # 真の conflict ファイル特定に置き換える前提。
  local files_json
  if ! files_json=$(timeout "$MERGE_QUEUE_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" --json files 2>/dev/null); then
    files_json='{"files":[]}'
  fi
  local files_md
  files_md=$(echo "$files_json" | jq -r '
    (.files // []) | map("- `" + .path + "`") |
    if length == 0 then "_(変更ファイル一覧の取得に失敗しました)_"
    elif length > 50 then (.[0:50] | join("\n")) + "\n- _(他 " + ((length - 50) | tostring) + " 件)_"
    else join("\n") end
  ')

  local comment_body
  comment_body=$(cat <<EOF
## 🔀 自動マージ前 conflict 検知 (Phase A)

approve 済みの本 PR について、watcher が \`${MERGE_QUEUE_BASE_BRANCH}\` との merge 試行で **conflict** を検知しました。
\`codex-needs-rebase\` ラベルを付与しています。

### 推奨アクション

- 手動で base を最新化してください（例: \`gh pr checkout ${pr_number} && git pull --rebase origin ${MERGE_QUEUE_BASE_BRANCH} && git push --force-with-lease\`）
- または semantic conflict の自動解消を待ちたい場合は Phase D（#17）の導入を検討してください

### 変更ファイル（参考）

実際の conflict 範囲は \`git merge-tree\` 等で確認してください。本 PR が触っているファイルの一覧:

${files_md}

---

_本コメントは Phase A Merge Queue Processor が自動投稿しました。conflict が解消し \`codex-needs-rebase\` ラベルが手動で外されると、次回サイクルで再度判定されます。_
EOF
)

  # AC 2.1: codex-needs-rebase 付与
  if ! gh pr edit "$pr_number" --repo "$REPO" --add-label "$LABEL_NEEDS_REBASE" >/dev/null 2>&1; then
    # AC 2.5: ラベル付与失敗 → WARN、後続 PR は継続
    mq_warn "PR #${pr_number}: codex-needs-rebase ラベル付与に失敗"
    return 1
  fi
  # AC 2.3: ステータスコメント 1 件投稿
  if ! gh pr comment "$pr_number" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1; then
    # AC 2.5: コメント投稿失敗 → WARN、後続 PR は継続（ラベルは残す）
    mq_warn "PR #${pr_number}: 状況コメント投稿に失敗（ラベルは付与済み）"
    return 1
  fi
  mq_log "PR #${pr_number}: CONFLICTING -> labeled+commented (${pr_url})"
  return 0
}

# MERGEABLE PR を最新の base に自動 rebase して force-with-lease push する。
# 失敗したら codex-needs-rebase に格下げする。サブシェルで実行し、trap で必ず base branch に戻す。
# 戻り値: 0=rebase+push 成功, 1=conflict 経由 codex-needs-rebase 化, 2=その他失敗（push 失敗等）
mq_try_rebase_pr() {
  local pr_number="$1"
  local head_ref="$2"
  local base_ref="$3"
  local pr_json="$4"

  (
    set +e
    # サブシェル終了時は必ず元の base branch checkout に戻す（NFR 2.2）
    # shellcheck disable=SC2064
    trap "git rebase --abort >/dev/null 2>&1; git checkout '${MERGE_QUEUE_BASE_BRANCH}' >/dev/null 2>&1" EXIT

    # AC 3.1 / 3.5: 既に祖先関係を満たしているなら rebase 不要
    if git merge-base --is-ancestor "origin/${base_ref}" "origin/${head_ref}" 2>/dev/null; then
      exit 10  # skip 用の特別 exit code
    fi

    # head ブランチを fresh に checkout（既存ローカルブランチがあれば force リセット）
    if ! timeout "$MERGE_QUEUE_GIT_TIMEOUT" git checkout -B "$head_ref" "origin/${head_ref}" >/dev/null 2>&1; then
      mq_warn "PR #${pr_number}: head branch '${head_ref}' の checkout に失敗"
      exit 2
    fi

    # AC 3.1: rebase 試行
    if ! timeout "$MERGE_QUEUE_GIT_TIMEOUT" git rebase "origin/${base_ref}" >/dev/null 2>&1; then
      # AC 3.3: conflict なら abort して codex-needs-rebase 化
      git rebase --abort >/dev/null 2>&1 || true
      exit 1
    fi

    # AC 3.2 / NFR 2.1: 安全な force push
    if ! timeout "$MERGE_QUEUE_GIT_TIMEOUT" \
        git push --force-with-lease origin "$head_ref" >/dev/null 2>&1; then
      # AC 3.4: push 失敗（リモート先行等）→ WARN、当該 PR をスキップ
      mq_warn "PR #${pr_number}: force-with-lease push に失敗（リモートが進んだ可能性）"
      exit 2
    fi
    exit 0
  )
  local rc=$?
  # サブシェル外でも安全側に倒して base branch に戻す（AC 3.6 / NFR 2.2）
  git checkout "$MERGE_QUEUE_BASE_BRANCH" >/dev/null 2>&1 || true

  case $rc in
    0)
      mq_log "PR #${pr_number}: MERGEABLE stale -> rebase+push OK"
      return 0
      ;;
    1)
      # rebase conflict → codex-needs-rebase 化
      mq_handle_conflict "$pr_number" "$pr_json"
      return 1
      ;;
    10)
      mq_log "PR #${pr_number}: MERGEABLE up-to-date (skip rebase)"
      return 10
      ;;
    *)
      return 2
      ;;
  esac
}

process_merge_queue() {
  # AC 5.1: opt-out gate
  if [ "$MERGE_QUEUE_ENABLED" != "true" ]; then
    return 0
  fi

  # NFR 2.3: 想定外の dirty working tree を検知したら ERROR を出してサイクル中止
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    mq_error "dirty working tree を検出しました。Merge Queue Processor をスキップします。"
    return 0
  fi

  mq_log "サイクル開始 (max=${MERGE_QUEUE_MAX_PRS}, base=${MERGE_QUEUE_BASE_BRANCH}, timeout=${MERGE_QUEUE_GIT_TIMEOUT}s)"

  # AC 1.2 / 1.3 / 1.4 / 1.6 / 1.7: approved かつ codex-needs-rebase / codex-failed が付いていない
  # 非 draft の PR。さらに head branch が MERGE_QUEUE_HEAD_PATTERN に合致し、
  # head repo owner が base repo owner と同一（= fork PR を除外）のものに限定。
  # GitHub search 構文で server side フィルタ（API call 削減・NFR 1.2）
  local repo_owner="${REPO%%/*}"
  local prs_json
  if ! prs_json=$(timeout "$MERGE_QUEUE_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "review:approved -label:\"$LABEL_NEEDS_REBASE\" -label:\"$LABEL_FAILED\" -draft:true" \
      --json number,headRefName,baseRefName,mergeable,mergeStateStatus,labels,url,isDraft,reviewDecision,headRepositoryOwner \
      --limit 50 2>/dev/null); then
    mq_warn "approved PR の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    return 0
  fi

  # クライアント側フィルタ:
  #   - isDraft / reviewDecision の再確認（server filter の保険）
  #   - head ref prefix (MERGE_QUEUE_HEAD_PATTERN): 人間の手書き PR を巻き込まない
  #   - head repo owner == base repo owner: fork PR を除外
  prs_json=$(echo "$prs_json" | jq \
    --arg pattern "$MERGE_QUEUE_HEAD_PATTERN" \
    --arg owner "$repo_owner" \
    '[.[]
      | select(.isDraft == false)
      | select(.reviewDecision == "APPROVED")
      | select(.headRefName | test($pattern))
      | select((.headRepositoryOwner.login // "") == $owner)
    ]')

  local total
  total=$(echo "$prs_json" | jq 'length')
  local target_count="$total"
  local skipped_overflow=0
  if [ "$total" -gt "$MERGE_QUEUE_MAX_PRS" ]; then
    target_count="$MERGE_QUEUE_MAX_PRS"
    skipped_overflow=$((total - MERGE_QUEUE_MAX_PRS))
    # AC 4.3: 上限超過分は次回に持ち越し
    mq_log "対象候補 ${total} 件中、上限 ${MERGE_QUEUE_MAX_PRS} 件のみ処理（${skipped_overflow} 件は次回持ち越し）"
  else
    # AC 6.1: サイクル開始時に件数をログ
    mq_log "対象候補 ${total} 件、処理対象 ${target_count} 件"
  fi

  if [ "$target_count" -eq 0 ]; then
    mq_log "サマリ: rebase+push=0, conflict=0, skip=0, fail=0, overflow=${skipped_overflow}"
    return 0
  fi

  local rebased=0
  local conflicted=0
  local skipped=0
  local failed=0

  # 先頭 N 件のみ処理（後ろは持ち越し）
  local pr_iter
  pr_iter=$(echo "$prs_json" | jq -c ".[0:${target_count}][]")

  # AC 4.3: target_count > 0 なので pr_iter は最低 1 行を持つ前提だが、念のため空ガード
  if [ -z "$pr_iter" ]; then
    mq_log "サマリ: rebase+push=0, conflict=0, skip=0, fail=0, overflow=${skipped_overflow}"
    return 0
  fi

  while IFS= read -r pr_json; do
    local pr_number head_ref base_ref mergeable merge_state url
    pr_number=$(echo "$pr_json" | jq -r '.number')
    head_ref=$(echo "$pr_json"  | jq -r '.headRefName')
    base_ref=$(echo "$pr_json"  | jq -r '.baseRefName')
    mergeable=$(echo "$pr_json" | jq -r '.mergeable')
    merge_state=$(echo "$pr_json" | jq -r '.mergeStateStatus')
    url=$(echo "$pr_json" | jq -r '.url')

    # AC 1.5 / 6.2: 各 PR の mergeable 判定をログ
    mq_log "PR #${pr_number}: mergeable=${mergeable}, state=${merge_state}, head=${head_ref}, base=${base_ref}"

    case "$mergeable" in
      CONFLICTING)
        if mq_handle_conflict "$pr_number" "$pr_json"; then
          conflicted=$((conflicted + 1))
        else
          failed=$((failed + 1))
        fi
        ;;
      MERGEABLE)
        # PR の base ref が対象 base ブランチ以外なら自動 rebase の対象外（安全側）
        if [ "$base_ref" != "$MERGE_QUEUE_BASE_BRANCH" ]; then
          mq_log "PR #${pr_number}: base=${base_ref} は ${MERGE_QUEUE_BASE_BRANCH} 以外、自動 rebase スキップ"
          skipped=$((skipped + 1))
          continue
        fi
        local rc=0
        mq_try_rebase_pr "$pr_number" "$head_ref" "$base_ref" "$pr_json" || rc=$?
        case $rc in
          0)  rebased=$((rebased + 1)) ;;
          1)  conflicted=$((conflicted + 1)) ;;
          10) skipped=$((skipped + 1)) ;;
          *)  failed=$((failed + 1)) ;;
        esac
        ;;
      UNKNOWN|"")
        # GitHub が mergeable を未計算の場合は次回サイクルに委ねる
        mq_log "PR #${pr_number}: mergeable 未確定 (${mergeable:-null})、次回サイクルに委ねます"
        skipped=$((skipped + 1))
        ;;
      *)
        mq_log "PR #${pr_number}: 未知の mergeable=${mergeable} (${url})、スキップ"
        skipped=$((skipped + 1))
        ;;
    esac
  done <<< "$pr_iter"

  # AC 6.3: サマリ行
  mq_log "サマリ: rebase+push=${rebased}, conflict=${conflicted}, skip=${skipped}, fail=${failed}, overflow=${skipped_overflow}"

  # AC 3.6 / NFR 2.2: 念のため最終確認で base branch checkout に戻す
  git checkout "$MERGE_QUEUE_BASE_BRANCH" >/dev/null 2>&1 || true
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase A: Merge Queue Re-check Processor (#27)
#   `codex-needs-rebase` 付き approved PR を別レーンで再評価し、`mergeable=MERGEABLE` に
#   戻った PR のラベルを自動除去する。Phase A 本体（process_merge_queue）とは
#   独立に opt-in 制御するため、MERGE_QUEUE_RECHECK_ENABLED=true で起動。
#   ラベル除去のみを副作用とし、再 rebase / コメント投稿は Phase A 本体に委譲。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# merge-queue-recheck 専用ロガー（Phase A 本体の `merge-queue:` と区別する prefix）。
# AC 5.5 / 5.6 / NFR 3.2: `merge-queue-recheck:` prefix と既存 timestamp 書式に統一。
mqr_log() {
  echo "[$(date '+%F %T')] merge-queue-recheck: $*"
}
mqr_warn() {
  echo "[$(date '+%F %T')] merge-queue-recheck: WARN: $*" >&2
}
mqr_error() {
  echo "[$(date '+%F %T')] merge-queue-recheck: ERROR: $*" >&2
}

process_merge_queue_recheck() {
  # AC 1.2 / 1.3 / 3.1 / 3.3: opt-in gate（MERGE_QUEUE_ENABLED とは独立）
  if [ "$MERGE_QUEUE_RECHECK_ENABLED" != "true" ]; then
    return 0
  fi

  mqr_log "サイクル開始 (max=${MERGE_QUEUE_RECHECK_MAX_PRS}, timeout=${MERGE_QUEUE_GIT_TIMEOUT}s)"

  # AC 1.4 / 1.5 / 1.6: approved かつ codex-needs-rebase ラベル付き、codex-failed 無し、非 draft。
  # AC 4.3 / 4.4: server-side フィルタで API call を最小化、Phase A と同一 timeout を適用。
  local repo_owner="${REPO%%/*}"
  local prs_json
  if ! prs_json=$(timeout "$MERGE_QUEUE_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "review:approved label:\"$LABEL_NEEDS_REBASE\" -label:\"$LABEL_FAILED\" -draft:true" \
      --json number,headRefName,baseRefName,mergeable,labels,url,isDraft,reviewDecision,headRepositoryOwner \
      --limit 100 2>/dev/null); then
    # AC 4.5: タイムアウト / エラー時は WARN を出して以降スキップ（後続処理は継続）
    mqr_warn "対象 PR 一覧の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    return 0
  fi

  # AC 1.5 / 1.6 / 1.7 / 1.8: クライアント側フィルタ（server filter の保険）
  #   - isDraft / reviewDecision の再確認
  #   - head ref prefix (MERGE_QUEUE_HEAD_PATTERN): 人間の手書き PR を巻き込まない
  #   - head repo owner == base repo owner: fork PR を除外
  prs_json=$(echo "$prs_json" | jq \
    --arg pattern "$MERGE_QUEUE_HEAD_PATTERN" \
    --arg owner "$repo_owner" \
    '[.[]
      | select(.isDraft == false)
      | select(.reviewDecision == "APPROVED")
      | select(.headRefName | test($pattern))
      | select((.headRepositoryOwner.login // "") == $owner)
    ]')

  local total
  total=$(echo "$prs_json" | jq 'length')
  local target_count="$total"
  local skipped_overflow=0
  if [ "$total" -gt "$MERGE_QUEUE_RECHECK_MAX_PRS" ]; then
    target_count="$MERGE_QUEUE_RECHECK_MAX_PRS"
    skipped_overflow=$((total - MERGE_QUEUE_RECHECK_MAX_PRS))
    # AC 4.2 / 5.1: 上限超過分は次回に持ち越し
    mqr_log "対象候補 ${total} 件中、上限 ${MERGE_QUEUE_RECHECK_MAX_PRS} 件のみ処理（${skipped_overflow} 件は次回持ち越し）"
  else
    # AC 5.1: サイクル開始時に件数をログ
    mqr_log "対象候補 ${total} 件、処理対象 ${target_count} 件"
  fi

  if [ "$target_count" -eq 0 ]; then
    # AC 5.4: サマリ行（ゼロ件でも明示）
    mqr_log "サマリ: label-removed=0, conflicting=0, unknown-skip=0, fail=0, overflow=${skipped_overflow}"
    return 0
  fi

  local removed=0
  local conflicting=0
  local unknown_skip=0
  local failed=0

  local pr_iter
  pr_iter=$(echo "$prs_json" | jq -c ".[0:${target_count}][]")

  if [ -z "$pr_iter" ]; then
    mqr_log "サマリ: label-removed=0, conflicting=0, unknown-skip=0, fail=0, overflow=${skipped_overflow}"
    return 0
  fi

  while IFS= read -r pr_json; do
    local pr_number head_ref base_ref mergeable url
    pr_number=$(echo "$pr_json" | jq -r '.number')
    head_ref=$(echo "$pr_json"  | jq -r '.headRefName')
    base_ref=$(echo "$pr_json"  | jq -r '.baseRefName')
    mergeable=$(echo "$pr_json" | jq -r '.mergeable')
    url=$(echo "$pr_json" | jq -r '.url')

    # AC 5.2: 各 PR の mergeable 判定をログ（PR 番号 / mergeable / アクション）
    case "$mergeable" in
      MERGEABLE)
        # AC 2.1 / NFR 2.1: ラベル除去（唯一の副作用）。Phase A と同一 timeout を適用。
        if timeout "$MERGE_QUEUE_GIT_TIMEOUT" \
            gh pr edit "$pr_number" --repo "$REPO" --remove-label "$LABEL_NEEDS_REBASE" >/dev/null 2>&1; then
          # AC 2.2 / 5.3: 成功 INFO ログ（要件文言を含める）
          mqr_log "PR #${pr_number}: mergeable=MERGEABLE -> label removed (conflict resolved, re-evaluating next cycle) (${url})"
          removed=$((removed + 1))
        else
          # AC 2.6: ラベル除去 API がエラーを返した場合は WARN、後続 PR は継続
          mqr_warn "PR #${pr_number}: codex-needs-rebase ラベル除去に失敗（${url}）"
          failed=$((failed + 1))
        fi
        ;;
      CONFLICTING)
        # AC 2.3 / NFR 2.2: 状態変更なし（再ラベル / コメント追記なし）
        mqr_log "PR #${pr_number}: mergeable=CONFLICTING -> kept (head=${head_ref}, base=${base_ref})"
        conflicting=$((conflicting + 1))
        ;;
      UNKNOWN|null|"")
        # AC 2.4 / NFR 2.2: UNKNOWN / null は次回サイクルに委ねる
        mqr_log "PR #${pr_number}: mergeable=${mergeable:-null} -> skip (next cycle)"
        unknown_skip=$((unknown_skip + 1))
        ;;
      *)
        # NFR 2.2: 未知の値もラベル除去を行わずスキップ
        mqr_log "PR #${pr_number}: mergeable=${mergeable} (未知) -> skip"
        unknown_skip=$((unknown_skip + 1))
        ;;
    esac
  done <<< "$pr_iter"

  # AC 5.4: サマリ行
  mqr_log "サマリ: label-removed=${removed}, conflicting=${conflicting}, unknown-skip=${unknown_skip}, fail=${failed}, overflow=${skipped_overflow}"
}

# AC 1.1: Phase A 本体ループの直前に Re-check Processor を 1 回起動
process_merge_queue_recheck || mqr_warn "process_merge_queue_recheck が想定外のエラーで終了しました（後続処理は継続）"

# AC 1.1: ピックアップ済み Issue の処理ループに入る前に 1 回だけ起動
process_merge_queue || mq_warn "process_merge_queue が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PR Iteration Processor (#26)
#   `codex-needs-iteration` ラベルが付いた idd-codex 管理下 PR を fresh context の Codex で
#   反復対応する。Phase A と同じ flock 境界内で直列実行され、対象 PR 集合は
#   server-side label query で Phase A と直交させている（AC 8.4）。
#
#   既存運用との後方互換のため PR_ITERATION_ENABLED=true で opt-in。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# pr-iteration 専用ロガー（識別用 prefix と timestamp 形式を Issue Watcher と揃える）
pi_log() {
  echo "[$(date '+%F %T')] pr-iteration: $*"
}
pi_warn() {
  echo "[$(date '+%F %T')] pr-iteration: WARN: $*" >&2
}
pi_error() {
  echo "[$(date '+%F %T')] pr-iteration: ERROR: $*" >&2
}

# PR ラベル一覧に特定ラベルが含まれるかを判定（jq で labels 配列を走査）
pi_pr_has_label() {
  local pr_json="$1"
  local label="$2"
  echo "$pr_json" | jq -e --arg l "$label" '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_fetch_candidate_prs: server-side + client-side の二段フィルタで候補 PR を返す
#   出力: stdout に jq 配列形式の JSON 1 行（候補なしなら "[]"）
#   AC 1.1, 1.2, 1.3, 1.4, 1.5, 8.4
# ─────────────────────────────────────────────────────────────────────────────
pi_fetch_candidate_prs() {
  local repo_owner="${REPO%%/*}"
  local prs_json
  # AC 1.1 / 1.4 / 1.5 / 8.4: codex-needs-iteration 付き、codex-failed / codex-needs-rebase 無し、非 draft
  if ! prs_json=$(timeout "$PR_ITERATION_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "label:\"$LABEL_NEEDS_ITERATION\" -label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_REBASE\" -draft:true" \
      --json number,headRefName,baseRefName,isDraft,url,labels,headRepositoryOwner,body \
      --limit 50 2>/dev/null); then
    pi_warn "codex-needs-iteration PR の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    echo "[]"
    return 0
  fi

  # AC 1.2 / 1.3 / 1.4: クライアント側フィルタ（server filter の保険 + head pattern + fork 除外）
  # #35 AC 4.4 / 5.1: design pattern は PR_ITERATION_DESIGN_ENABLED=true のときのみ OR 条件に
  # 含める。false（既定）なら impl pattern のみで絞り込み、設計 PR は candidate 段階で除外される
  # （= 本機能導入前と完全同一の挙動）。
  echo "$prs_json" | jq \
    --arg impl_pattern "$PR_ITERATION_HEAD_PATTERN" \
    --arg design_pattern "$PR_ITERATION_DESIGN_HEAD_PATTERN" \
    --arg design_enabled "$PR_ITERATION_DESIGN_ENABLED" \
    --arg owner "$repo_owner" \
    '[.[]
      | select(.isDraft == false)
      | select((.headRepositoryOwner.login // "") == $owner)
      | select(
          (.headRefName | test($impl_pattern))
          or
          ($design_enabled == "true" and (.headRefName | test($design_pattern)))
        )
    ]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_read_round_counter: PR body から hidden marker の round 数を取得
#   入力: $1=pr_number
#   出力: stdout に round 数（marker 無しなら 0）
#   AC 7.1, 7.4
# ─────────────────────────────────────────────────────────────────────────────
pi_read_round_counter() {
  local pr_number="$1"
  local body
  if ! body=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null); then
    pi_warn "PR #${pr_number}: body 取得に失敗、round=0 として扱います"
    echo "0"
    return 0
  fi
  # marker 形式: <!-- idd-codex:pr-iteration round=N last-run=... -->
  # 複数検出時は最後（最新）の数値を採用 = fail-safe
  local round
  round=$(echo "$body" \
    | grep -oE 'idd-codex:pr-iteration round=[0-9]+' \
    | grep -oE '[0-9]+$' \
    | tail -1)
  echo "${round:-0}"
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_read_last_run: PR body から hidden marker の last-run ISO8601 タイムスタンプを抽出
#   入力: $1=pr_body（gh pr view --json body --jq '.body // ""' で取得済みの文字列）
#   出力: stdout に last-run の ISO8601 文字列（例: "2026-04-25T12:34:56Z"）。
#         marker / last-run キーが無ければ空文字列を出力。
#   返り値: 0 固定（呼び出し元で空文字列を初回 round 扱いにする）
#   AC #55 Req 2.3, 2.4 / 4.1
#
#   marker 形式: <!-- idd-codex:pr-iteration round=N last-run=ISO8601 -->
#   複数検出時は最後（最新）の値を採用（pi_read_round_counter の `tail -1` と整合）。
#   読み取り専用であり、書き込み側は pi_post_processing_marker のまま温存（後方互換性）。
# ─────────────────────────────────────────────────────────────────────────────
pi_read_last_run() {
  local pr_body="${1-}"
  if [ -z "$pr_body" ]; then
    echo ""
    return 0
  fi
  local last_run
  # 1. marker 行を抽出 → 2. `last-run=...` 部分のみを抽出 → 3. 末尾を採用
  #    値部分はスペース・`>` 以外を許容（pi_post_processing_marker は ISO8601 UTC を打刻するが、
  #    fail-safe としてスペース直前 / `>` 直前まで拾う）。
  last_run=$(echo "$pr_body" \
    | grep -oE 'idd-codex:pr-iteration round=[0-9]+ last-run=[^ >]+' \
    | sed -E 's|.*last-run=||' \
    | tail -1)
  echo "${last_run:-}"
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_filter_self: watcher 自身の自動投稿コメントを除外（marker ベース）
#   入力: stdin に一般コメント JSON 配列
#   出力: stdout にフィルタ後の JSON 配列
#   AC #55 Req 2.1, 2.7
#
#   判定: comment.body 中に `idd-codex:` で始まる HTML hidden marker を含むなら
#   watcher 投稿として除外する。GitHub user 同一性に依存しない（cron 実行ホストが
#   異なる GitHub user で動いていても確実に除外できる）。`@codex` 文字列には
#   一切依存しない（Req 2.7）。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_filter_self() {
  jq '[.[] | select((.body // "") | contains("idd-codex:") | not)]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_filter_resolved: 過去 round で対応済みと判定できるコメントを除外
#   入力: $1=last_run (ISO8601 string, 空文字列 = 初回 round)
#         stdin に一般コメント JSON 配列
#   出力: stdout にフィルタ後の JSON 配列
#   AC #55 Req 2.2, 2.3, 2.4, 2.5, 2.7
#
#   判定: last_run が空文字列なら no-op（全件採用 = 初回 round, Req 2.4）。
#         last_run が指定されている場合は `created_at > last_run` のコメントのみ採用。
#         境界（`==`）は採用側に倒さず除外する（fail-safe、設計判断 Req 2.3 解釈）。
#         比較は ISO8601 lex compare（GitHub の created_at は UTC `Z` 終端で揃う）。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_filter_resolved() {
  local last_run="${1-}"
  jq --arg last_run "$last_run" \
    '[.[] | select($last_run == "" or (.created_at // "") > $last_run)]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_filter_event_style: GitHub system 由来の event-style コメントを除外
#   入力: stdin に一般コメント JSON 配列
#   出力: stdout にフィルタ後の JSON 配列
#   AC #55 Req 2.6, 2.7
#
#   判定: user.type == "Bot" のコメント、および body が空のコメントを除外する。
#         /repos/.../issues/<n>/comments は基本的にユーザーコメントしか返さないため
#         保険的なフィルタだが、Req 2.6 を観測可能に保つために独立化する。
#         watcher 自身の投稿は marker で既に除外済みのため、ここで Bot を全体除外しても
#         二重除外にならず安全。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_filter_event_style() {
  jq '[.[] | select((.user.type // "") != "Bot" and (.body // "") != "")]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_truncate: 件数上限超過時に古い順 drop で削減
#   入力: $1=limit (件数上限)
#         stdin に一般コメント JSON 配列
#   出力: stdout に削減後の JSON 配列
#   AC #55 Req 3.1, 3.4
#
#   アルゴリズム:
#     1. 入力配列 length が limit 以下 → no-op（Req 3.4）
#     2. length > limit → created_at 昇順ソート → 末尾 limit 件を採用（古い順 drop）
#       新しいコメントが残るため、レビュワーが直近に追加した指摘を優先できる。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_truncate() {
  local limit="${1:-50}"
  jq --argjson limit "$limit" \
    'if length <= $limit then . else (sort_by(.created_at // "") | .[-$limit:]) end'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_collect_general_comments: 一般コメント収集 + 3 段フィルタ + 削減のオーケストレーション
#   入力: $1=pr_number
#         $2=pr_body (gh pr view --json body --jq '.body // ""' で取得済みの文字列)
#   出力: stdout に JSON 配列文字列。要素スキーマ:
#         { id, user, body, url, created_at }
#         取得失敗時 / コメント 0 件時は "[]"。
#   返り値: 0 固定（エラーは degraded path = "[]" + WARN ログに倒す）
#   AC #55 Req 1.1, 1.2, 1.5, 2.5, 3.2, 4.2, 4.3, 4.4, 4.6, 6.2, NFR 1.1, NFR 1.2,
#         NFR 2.1, NFR 2.2
#
#   設計判断:
#     - kind（design/impl）に依存する分岐を持たない（impl/design PR で共通呼び出し、Req 6.2）
#     - @codex 文字列を判定式に使わない（Req 2.7、`@codex` mention 必須を opt-out で
#       復活させる新規 env var を追加しない、Req 4.4）
#     - 上限値は内部定数 PI_GENERAL_MAX_COMMENTS（既定 50、env override 可）
#       README には載せない（運用上 default で十分、Req 4.4 の対象外）
#     - サマリは 1 行で出力し、truncate 発動時のみ pi_warn、それ以外は pi_log（NFR 2.2）
# ─────────────────────────────────────────────────────────────────────────────
pi_collect_general_comments() {
  local pr_number="$1"
  local pr_body="${2-}"
  local limit="${PI_GENERAL_MAX_COMMENTS:-50}"

  # 1. GitHub API から raw 一般コメントを取得（既存と同じ timeout / fall-back 方式）
  local raw_general
  if ! raw_general=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh api "/repos/${REPO}/issues/${pr_number}/comments" 2>/dev/null); then
    pi_warn "PR #${pr_number}: 一般コメント取得に失敗、空配列で続行"
    echo "[]"
    return 0
  fi

  # 2. 射影: { id, user, body, url, created_at } のスキーマに整形（Req 6.2 / Data Model）
  local projected
  if ! projected=$(echo "$raw_general" | jq '[.[] | {
        id,
        user: (.user.login // ""),
        body: (.body // ""),
        url: .html_url,
        created_at: (.created_at // ""),
        "_meta_user_type": (.user.type // "")
      }]' 2>/dev/null); then
    pi_warn "PR #${pr_number}: 一般コメント JSON の整形に失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local fetched
  fetched=$(echo "$projected" | jq 'length' 2>/dev/null || echo "0")

  # 3. last-run TS を抽出（marker 不在時は空文字列 = 初回 round）
  local last_run
  last_run=$(pi_read_last_run "$pr_body")

  # 4. フィルタを順次適用しながら各段の length を測定
  #    順序: self → resolved → event_style → truncate
  local after_self after_resolved after_event final
  local filter_event_input

  # event_style filter は射影段で残した _meta_user_type を user.type の代理として使う
  # （元 jq schema を {id,user,body,url,created_at} に保つ理由: prompt template 互換）
  if ! after_self=$(echo "$projected" | pi_general_filter_self 2>/dev/null); then
    pi_warn "PR #${pr_number}: 自己投稿フィルタに失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local count_self
  count_self=$(echo "$after_self" | jq 'length' 2>/dev/null || echo "0")

  if ! after_resolved=$(echo "$after_self" | pi_general_filter_resolved "$last_run" 2>/dev/null); then
    pi_warn "PR #${pr_number}: 過去 round フィルタに失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local count_resolved
  count_resolved=$(echo "$after_resolved" | jq 'length' 2>/dev/null || echo "0")

  # event_style フィルタは _meta_user_type を user.type 相当に詰め直してから判定する
  filter_event_input=$(echo "$after_resolved" | jq '[.[] | . + {user: {type: ._meta_user_type, login: (.user)}}]' 2>/dev/null || echo "[]")
  if ! after_event=$(echo "$filter_event_input" | pi_general_filter_event_style 2>/dev/null); then
    pi_warn "PR #${pr_number}: event-style フィルタに失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  # スキーマ復元: user は文字列 (login) のみに戻し、_meta_user_type も落とす
  after_event=$(echo "$after_event" | jq '[.[] | {id, user: (.user.login // ""), body, url, created_at}]' 2>/dev/null || echo "[]")
  local count_event
  count_event=$(echo "$after_event" | jq 'length' 2>/dev/null || echo "0")

  if ! final=$(echo "$after_event" | pi_general_truncate "$limit" 2>/dev/null); then
    pi_warn "PR #${pr_number}: truncate に失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local count_final
  count_final=$(echo "$final" | jq 'length' 2>/dev/null || echo "0")

  # 5. サマリ 1 行ログ
  local filtered_self filtered_resolved filtered_event truncated
  filtered_self=$((fetched - count_self))
  filtered_resolved=$((count_self - count_resolved))
  filtered_event=$((count_resolved - count_event))
  truncated=$((count_event - count_final))

  # サマリは stderr に出力する（本関数の stdout は JSON 配列に予約されているため）。
  # pi_warn は元々 stderr 直行、pi_log は stdout のため明示的に >&2 で逃がす。
  if [ "$truncated" -gt 0 ]; then
    pi_warn "PR #${pr_number} general comments: fetched=${fetched}, filtered_self=${filtered_self}, filtered_resolved=${filtered_resolved}, filtered_event=${filtered_event}, truncated=${truncated} (limit=${limit}), final=${count_final}"
  else
    pi_log "PR #${pr_number} general comments: fetched=${fetched}, filtered_self=${filtered_self}, filtered_resolved=${filtered_resolved}, filtered_event=${filtered_event}, truncated=0, final=${count_final}" >&2
  fi

  echo "$final"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_post_processing_marker: PR body に hidden marker を書き込み + 着手表明コメント投稿
#   入力: $1=pr_number, $2=new_round
#   AC 6.1, 7.1
#   戻り値: 0=成功, 1=失敗（呼び出し元で iteration を中断）
# ─────────────────────────────────────────────────────────────────────────────
pi_post_processing_marker() {
  local pr_number="$1"
  local new_round="$2"
  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  local body
  if ! body=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null); then
    pi_warn "PR #${pr_number}: body 取得に失敗、marker 更新をスキップ"
    return 1
  fi

  local marker="<!-- idd-codex:pr-iteration round=${new_round} last-run=${now} -->"
  local new_body
  if echo "$body" | grep -qE 'idd-codex:pr-iteration round=[0-9]+'; then
    # 既存 marker を最新 marker で置換（複数あった場合も全部 1 つに集約）
    new_body=$(echo "$body" | sed -E "s|<!-- idd-codex:pr-iteration round=[0-9]+ last-run=[^>]*-->|${marker}|g")
  else
    # 末尾に追記（前置の改行で見やすく）
    new_body="${body}

${marker}"
  fi

  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" --body "$new_body" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: PR body の hidden marker 更新に失敗"
    return 1
  fi

  # AC 6.1: 着手表明コメント
  local processing_msg
  processing_msg=$(printf '%s\n%s' \
    ":robot: PR Iteration Processor が処理を開始しました (round ${new_round}/${PR_ITERATION_MAX_ROUNDS})。" \
    "<!-- idd-codex:pr-iteration-processing round=${new_round} -->")
  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$processing_msg" >/dev/null 2>&1; then
    # コメント投稿失敗はラベル誤遷移のリスクがないため WARN のみ（marker は付いた）
    pi_warn "PR #${pr_number}: 着手表明コメントの投稿に失敗（marker は更新済み）"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_finalize_labels: 成功時のラベル遷移（AC 6.2 / 6.4）
#   --remove-label と --add-label を同一コマンドで指定し原子的に実行
# ─────────────────────────────────────────────────────────────────────────────
pi_finalize_labels() {
  local pr_number="$1"
  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" gh pr edit "$pr_number" --repo "$REPO" \
      --remove-label "$LABEL_NEEDS_ITERATION" \
      --add-label "$LABEL_READY" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: ラベル遷移 (codex-needs-iteration -> codex-ready-for-review) に失敗"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_finalize_labels_design: 設計 PR 用のラベル遷移（#35 AC 3.1）
#   codex-needs-iteration 除去 + codex-awaiting-design-review 付与を 1 コマンドで原子的に発行
# ─────────────────────────────────────────────────────────────────────────────
pi_finalize_labels_design() {
  local pr_number="$1"
  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" gh pr edit "$pr_number" --repo "$REPO" \
      --remove-label "$LABEL_NEEDS_ITERATION" \
      --add-label "$LABEL_AWAITING_DESIGN" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: ラベル遷移 (codex-needs-iteration -> codex-awaiting-design-review) に失敗"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_classify_pr_kind: branch 名 + env vars から PR の iteration 種別を判定
#   入力: $1 = head_ref
#   出力: stdout に "design" / "impl" / "none" / "ambiguous" のいずれか
#   返り値: 0
#
#   優先順序（#35 AC 1.1〜1.4 / 4.4）:
#     1. impl pattern と design pattern の両方に合致 → ambiguous
#     2. design pattern のみ合致 + DESIGN_ENABLED=true → design
#     3. design pattern のみ合致 + DESIGN_ENABLED!=true → none（opt-out gate）
#     4. impl pattern のみ合致 → impl
#     5. どちらにも合致しない → none
#
#   副作用なし（純粋関数）。同一入力に対して同一結果。
# ─────────────────────────────────────────────────────────────────────────────
pi_classify_pr_kind() {
  local head_ref="$1"
  local matches_impl=false
  local matches_design=false

  if [[ "$head_ref" =~ $PR_ITERATION_HEAD_PATTERN ]]; then
    matches_impl=true
  fi
  if [[ "$head_ref" =~ $PR_ITERATION_DESIGN_HEAD_PATTERN ]]; then
    matches_design=true
  fi

  if [ "$matches_impl" = "true" ] && [ "$matches_design" = "true" ]; then
    echo "ambiguous"
    return 0
  fi
  if [ "$matches_design" = "true" ]; then
    if [ "$PR_ITERATION_DESIGN_ENABLED" = "true" ]; then
      echo "design"
    else
      echo "none"
    fi
    return 0
  fi
  if [ "$matches_impl" = "true" ]; then
    echo "impl"
    return 0
  fi
  echo "none"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_select_template: kind から prompt template ファイルパスを返す（#35 AC 2.x）
#   入力: $1 = kind ("design" / "impl")
#   出力: stdout に template ファイルパス
#   返り値: 0=ok, 1=template 未配置（呼び出し元で iteration を中断）
# ─────────────────────────────────────────────────────────────────────────────
pi_select_template() {
  local kind="$1"
  local path=""
  case "$kind" in
    design) path="$ITERATION_TEMPLATE_DESIGN" ;;
    impl)   path="$ITERATION_TEMPLATE" ;;
    *)
      pi_warn "pi_select_template: 未知の kind=${kind}"
      return 1
      ;;
  esac
  if [ ! -f "$path" ]; then
    pi_warn "pi_select_template: template not found for kind=${kind}: ${path}"
    return 1
  fi
  echo "$path"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# build_recovery_hint (Issue #65 Req 3.1〜3.4)
#
# `codex-failed` ラベル付与時に escalation コメントへ含める「手動復旧手順」共通
# 文字列を組み立てる。
#
# 事故事例（2026-04-29 / Issue #52 復旧時 PR #62 orphan 化）の再発を防ぐため、
# 以下を必ず含める:
#   - ラベル操作の正しい順序: `codex-ready-for-review` 先付与 → `codex-failed` 除去
#   - 順序逆転で再 pickup → 既存 PR が orphan 化するリスク注意
#   - PR 無し時は `codex-failed` 除去のみで再 pickup される旨
#
# 入力: $1 = pr_present ("yes"|"no"|"unknown"; 既定 "unknown")
# 出力: stdout に markdown 文字列（escalation コメント本文の末尾に append される想定）
# 副作用: なし（純粋関数）
#
# 呼び出し側: mark_issue_failed / _slot_mark_failed / pi_escalate_to_failed
# ─────────────────────────────────────────────────────────────────────────────
build_recovery_hint() {
  local pr_present="${1:-unknown}"
  case "$pr_present" in
    yes|no|unknown) ;;
    *) pr_present="unknown" ;;
  esac

  cat <<'EOF'

---

### 手動復旧の正しい手順 (Issue #65)

ラベル操作の順序を間違えると、watcher が次サイクルで再 pickup し、既存の
PR を `force-push` で破壊する事故が起こります（過去事例: PR #62 orphan 化）。

EOF

  case "$pr_present" in
    yes)
      cat <<'EOF'
**この Issue には既に PR が紐付いています**。復旧する場合は順序が重要です:

1. `codex-ready-for-review` ラベルを **先に付与** する
2. その後で `codex-failed` ラベルを除去する

`codex-failed` を先に外すと、`codex-auto-dev` のみが残った状態になり、watcher が次
サイクルで再 pickup → impl-resume が起動して既存 PR が `force-push` 破壊
される可能性があります。

なお watcher 側にも Pre-Claim Filter が組まれているため、linked impl PR が
OPEN/MERGED の場合は claim が抑止されますが、二重ガードのために順序は厳守
してください。

EOF
      ;;
    no)
      cat <<'EOF'
**この Issue には現時点で PR が紐付いていません**。復旧する場合:

- `codex-failed` を除去すると次サイクルで watcher が再 pickup します
  （PR が無ければ Pre-Claim Filter は素通りするため、impl/Triage が再起動
  されます）
- これ以上自動再実行したくない場合は `codex-failed` を残したまま
  `codex-auto-dev` を外す方法もあります

EOF
      ;;
    *)
      cat <<'EOF'
**復旧手順は PR の有無で分岐します**:

- PR が既に作成済みの場合: `codex-ready-for-review` を **先に付与** してから
  `codex-failed` を除去する。順序を逆にすると watcher が次サイクルで再
  pickup し、impl-resume が起動して既存 PR が `force-push` 破壊される
  可能性があります。
- PR が無い場合: `codex-failed` を除去すると次サイクルで再 pickup される
  ため、自動再実行を望まないときは `codex-auto-dev` も外す。

watcher 側にも Pre-Claim Filter（linked impl PR が OPEN/MERGED なら claim
を抑止）が組まれていますが、二重ガードのため順序は厳守してください。

EOF
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_escalate_to_failed: 上限到達時の codex-failed 昇格 + エスカレコメント
#   入力: $1=pr_number, $2=round, $3=max_rounds
#   AC 7.2, 7.3
# ─────────────────────────────────────────────────────────────────────────────
pi_escalate_to_failed() {
  local pr_number="$1"
  local round="$2"
  local max_rounds="$3"

  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" gh pr edit "$pr_number" --repo "$REPO" \
      --remove-label "$LABEL_NEEDS_ITERATION" \
      --add-label "$LABEL_FAILED" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: codex-failed 昇格時のラベル遷移に失敗"
    return 1
  fi

  local escalation_body
  escalation_body=$(cat <<EOF
## :rotating_light: PR Iteration 上限到達 (#26 PR Iteration Processor)

本 PR の累計自動 iteration 回数が上限 (\`PR_ITERATION_MAX_ROUNDS=${max_rounds}\`) に達しました。
\`codex-needs-iteration\` ラベルを除去し、\`codex-failed\` ラベルに付け替えています。

### これまでの状況

- 累計 iteration: ${round} round
- 上限値: ${max_rounds} round
- 上限到達のため自動 iteration を停止

### 次に人間が取るべきアクション

1. これまでのレビューコメントと自動修正履歴を読み、Codex の判断を確認する
2. 必要に応じて手動で修正 commit を積む
3. 自動 iteration を再開したい場合:
   - PR 本文の \`<!-- idd-codex:pr-iteration round=N ... -->\` 行を **手動で削除**（カウンタリセット）
   - \`codex-failed\` ラベルを除去
   - \`codex-needs-iteration\` ラベルを付け直す
4. これ以上自動 iteration を行わない場合は \`codex-failed\` を残したまま手動レビューに移行

---

_本コメントは PR Iteration Processor (#26) が自動投稿しました。_
EOF
)
  # Issue #65 Req 3.1/3.2/3.3/3.4: 手動復旧手順を末尾に append。
  # pi_escalate_to_failed は PR Iteration（codex-needs-iteration ラベル付き PR）からの遷移
  # であり、文脈上 PR が必ず存在するため pr_present="yes" を渡す。
  escalation_body="${escalation_body}
$(build_recovery_hint "yes")"

  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$escalation_body" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: エスカレコメントの投稿に失敗（ラベル遷移は完了済み）"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_build_iteration_prompt: 指定 template に変数を注入
#   入力: $1=pr_number, $2=pr_json, $3=round, $4=template_path（省略時は impl 用既定）
#   出力: stdout に prompt 文字列
#   AC 3.1, 3.2, 3.3, 3.4, 3.5（#26）/ #35 で kind 引数の代わりに template path を受け取る
# ─────────────────────────────────────────────────────────────────────────────
pi_build_iteration_prompt() {
  local pr_number="$1"
  local pr_json="$2"
  local round="$3"
  # #35: template path を呼び出し元から渡す。省略時は impl 用 template を使う（後方互換）。
  local tmpl_path="${4:-$ITERATION_TEMPLATE}"

  local pr_title pr_url head_ref base_ref pr_body
  pr_title=$(echo "$pr_json" | jq -r '.title // ""')
  pr_url=$(echo "$pr_json"   | jq -r '.url // ""')
  head_ref=$(echo "$pr_json" | jq -r '.headRefName // ""')
  base_ref=$(echo "$pr_json" | jq -r '.baseRefName // ""')
  pr_body=$(echo "$pr_json"  | jq -r '.body // ""')

  # title が JSON で取れていない場合（pr_json は --json title を含まないかも）は gh で補完
  if [ -z "$pr_title" ]; then
    pr_title=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" --json title --jq '.title // ""' 2>/dev/null || echo "")
  fi

  # 関連 Issue 番号: head branch (`codex/issue-N-...`) → PR body の順で抽出
  local issue_number=""
  issue_number=$(echo "$head_ref" | grep -oE 'issue-[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  if [ -z "$issue_number" ]; then
    issue_number=$(echo "$pr_body" | grep -oE '#[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  fi

  local spec_dir=""
  local requirements_md="(関連 Issue が見つからないか、対応する requirements.md が存在しません)"
  if [ -n "$issue_number" ]; then
    local found
    found=$(ls -d "${REPO_DIR}/docs/specs/${issue_number}-"* 2>/dev/null | head -1 || true)
    if [ -n "$found" ] && [ -f "${found}/requirements.md" ]; then
      spec_dir="docs/specs/$(basename "$found")"
      requirements_md=$(cat "${found}/requirements.md")
    fi
  fi

  # PR diff は prompt に inline で埋め込まない（Issue #97: 大差分時の `Argument list
  # too long` 回避のため、`PI_PR_DIFF` 環境変数も廃止。Iteration 役割が
  # template の指示に従い、自身で `gh pr diff <N> --repo <REPO>` および
  # `git diff <base>..<head> -- <path>` を Bash ツールで実行して取得する設計に切り替えた）

  # AC 3.1: 最新 review の line コメントを取得（reviews 配列の最後の要素 = 時系列で最新）
  local line_comments_json="[]"
  local reviews_json latest_review_id
  if reviews_json=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh api "/repos/${REPO}/pulls/${pr_number}/reviews" 2>/dev/null); then
    latest_review_id=$(echo "$reviews_json" | jq -r 'if length > 0 then (.[length-1].id|tostring) else "" end')
    if [ -n "$latest_review_id" ]; then
      local raw_line
      if raw_line=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
          gh api "/repos/${REPO}/pulls/${pr_number}/reviews/${latest_review_id}/comments" 2>/dev/null); then
        line_comments_json=$(echo "$raw_line" | jq '[.[] | {id, path, line, user: (.user.login // ""), body}]')
      fi
    fi
  fi

  # #55: 一般コメント収集（mention 篩い分けを撤廃 + 自己投稿 / 過去 round / system 除外
  #     + 大量時 truncate）。kind に依存せず impl/design 共通で同一ロジックを通す（Req 6.2）。
  local general_comments_json
  general_comments_json=$(pi_collect_general_comments "$pr_number" "$pr_body")

  # template に変数を注入する。
  # 単一行値（PR 番号 / タイトル / URL 等）は awk -v で渡し、行内の {{KEY}} を文字列置換。
  # 複数行値（LINE_COMMENTS_JSON / GENERAL_COMMENTS_JSON / REQUIREMENTS_MD）は awk -v で
  # 改行を扱えないため、export 経由で ENVIRON[] から取得し、「行全体が {{KEY}} のみ」の
  # テンプレ行をブロックごと置換する（template はその前提で書かれている）。
  # NOTE (#97): PR diff は MAX_ARG_STRLEN (131,072 B) 超過で execve() が E2BIG を返す
  # 事案を避けるため env 経由でも渡さない。Iteration 役割が Bash で取得する。
  if [ ! -f "$tmpl_path" ]; then
    pi_warn "template not found: $tmpl_path"
    return 1
  fi

  # 改行入り値を子プロセスに渡すため export
  export PI_LINE_JSON="$line_comments_json"
  export PI_GENERAL_JSON="$general_comments_json"
  export PI_REQS_MD="$requirements_md"

  awk \
    -v repo="$REPO" \
    -v pr_number="$pr_number" \
    -v pr_title="$pr_title" \
    -v pr_url="$pr_url" \
    -v head_ref="$head_ref" \
    -v base_ref="$base_ref" \
    -v round="$round" \
    -v max_rounds="$PR_ITERATION_MAX_ROUNDS" \
    -v issue_number="${issue_number:-(none)}" \
    -v spec_dir="${spec_dir:-(none)}" \
    '
    function repl(s, key, val,    out, idx) {
      out = ""
      while ((idx = index(s, key)) > 0) {
        out = out substr(s, 1, idx-1) val
        s = substr(s, idx + length(key))
      }
      return out s
    }
    {
      # 行全体が複数行プレースホルダの場合は ENVIRON 経由で展開
      if ($0 == "{{LINE_COMMENTS_JSON}}")    { print ENVIRON["PI_LINE_JSON"]; next }
      if ($0 == "{{GENERAL_COMMENTS_JSON}}") { print ENVIRON["PI_GENERAL_JSON"]; next }
      if ($0 == "{{REQUIREMENTS_MD}}")       { print ENVIRON["PI_REQS_MD"]; next }
      line = $0
      line = repl(line, "{{REPO}}", repo)
      line = repl(line, "{{PR_NUMBER}}", pr_number)
      line = repl(line, "{{PR_TITLE}}", pr_title)
      line = repl(line, "{{PR_URL}}", pr_url)
      line = repl(line, "{{HEAD_REF}}", head_ref)
      line = repl(line, "{{BASE_REF}}", base_ref)
      line = repl(line, "{{ROUND}}", round)
      line = repl(line, "{{MAX_ROUNDS}}", max_rounds)
      line = repl(line, "{{ISSUE_NUMBER}}", issue_number)
      line = repl(line, "{{SPEC_DIR}}", spec_dir)
      print line
    }
    ' "$tmpl_path"
  local awk_rc=$?

  unset PI_LINE_JSON PI_GENERAL_JSON PI_REQS_MD
  return $awk_rc
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_run_iteration: 1 PR 分の iteration を実行（fresh context Codex 起動）
#   入力: $1=pr_json
#   戻り値: 0=success(commit+push or reply-only), 1=failure, 2=escalated(round上限到達),
#           3=skip (kind=none/ambiguous, #35)
#   AC 3.6, 4.x, 5.x, 6.2, 6.3, 7.x, 8.3, 9.2, NFR 1.1, NFR 1.3 (#26)
#   #35: kind 判定で design / impl を分岐し、template と finalize 関数を切り替える
# ─────────────────────────────────────────────────────────────────────────────
pi_run_iteration() {
  local pr_json="$1"
  local pr_number head_ref base_ref pr_url
  pr_number=$(echo "$pr_json" | jq -r '.number')
  head_ref=$(echo "$pr_json"  | jq -r '.headRefName')
  base_ref=$(echo "$pr_json"  | jq -r '.baseRefName')
  pr_url=$(echo "$pr_json"    | jq -r '.url')

  # #35 AC 1.1〜1.4 / 4.4: kind 判定（design / impl / none / ambiguous）
  local kind
  kind=$(pi_classify_pr_kind "$head_ref")

  case "$kind" in
    none)
      pi_log "PR #${pr_number}: kind=none head=${head_ref} (does not match design/impl pattern), skip"
      return 3
      ;;
    ambiguous)
      pi_warn "PR #${pr_number}: kind=ambiguous head=${head_ref} (matches both design and impl pattern), skip"
      return 3
      ;;
    design|impl) : ;;
    *)
      pi_warn "PR #${pr_number}: kind=${kind} (unknown), skip"
      return 3
      ;;
  esac

  # #35 AC 2.x: kind に応じた template path を取得
  local tmpl_path
  if ! tmpl_path=$(pi_select_template "$kind"); then
    pi_warn "PR #${pr_number}: kind=${kind} 用 template が取得できず iteration 中止"
    return 1
  fi

  local round
  round=$(pi_read_round_counter "$pr_number")

  # AC 7.2 (#26): 上限到達なら escalate（kind 共通、#35 AC 3.4 / 6.5）
  if [ "$round" -ge "$PR_ITERATION_MAX_ROUNDS" ]; then
    pi_log "PR #${pr_number}: kind=${kind} round=${round} >= max=${PR_ITERATION_MAX_ROUNDS}, codex-failed に昇格"
    pi_escalate_to_failed "$pr_number" "$round" "$PR_ITERATION_MAX_ROUNDS" || true
    return 2
  fi

  local next_round=$((round + 1))

  # AC 6.1: 着手表明（marker 更新 + コメント、kind 非依存、#35 AC 6.1 / 6.5）
  if ! pi_post_processing_marker "$pr_number" "$next_round"; then
    pi_warn "PR #${pr_number}: kind=${kind} 着手表明に失敗、iteration 中止"
    return 1
  fi

  pi_log "PR #${pr_number}: kind=${kind} round=${next_round}/${PR_ITERATION_MAX_ROUNDS} 着手 (${pr_url})"

  # サブシェル + trap で必ず base branch に戻す（AC 8.3）
  local rc=0
  (
    set +e
    # shellcheck disable=SC2064
    trap "git checkout '${BASE_BRANCH}' >/dev/null 2>&1" EXIT

    # head branch を fresh に checkout（origin の最新状態に追従、AC 4.4）
    if ! timeout "$PR_ITERATION_GIT_TIMEOUT" git fetch origin "$head_ref" >/dev/null 2>&1; then
      pi_warn "PR #${pr_number}: git fetch origin ${head_ref} に失敗"
      exit 1
    fi
    if ! timeout "$PR_ITERATION_GIT_TIMEOUT" git checkout -B "$head_ref" "origin/${head_ref}" >/dev/null 2>&1; then
      pi_warn "PR #${pr_number}: head branch '${head_ref}' の checkout に失敗"
      exit 1
    fi

    # prompt を生成（#35: kind に応じた template path を渡す）
    local prompt
    if ! prompt=$(pi_build_iteration_prompt "$pr_number" "$pr_json" "$next_round" "$tmpl_path"); then
      pi_warn "PR #${pr_number}: prompt 組み立てに失敗"
      exit 1
    fi

    # AC 3.6: fresh context で起動（resume は使わない）
    local pi_log_file
    pi_log_file="$LOG_DIR/pr-iteration-${kind}-${pr_number}-round${next_round}-$(date +%Y%m%d-%H%M%S).log"
    if ! codex_exec_prompt "PR-iteration-${kind}-r${next_round}" "$PR_ITERATION_DEV_MODEL" "$prompt" \
        >> "$pi_log_file" 2>&1; then
      pi_warn "PR #${pr_number}: kind=${kind} Codex 実行が失敗 (log: ${pi_log_file})"
      exit 1
    fi
    pi_log "PR #${pr_number}: kind=${kind} Codex 実行完了 (log: ${pi_log_file})"
    exit 0
  )
  rc=$?
  # 保険: 呼び出し元でも base branch に戻す
  git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true

  if [ $rc -eq 0 ]; then
    # AC 6.2 (#26) / #35 AC 3.1 / 3.2: kind に応じたラベル遷移
    local finalize_ok=false
    case "$kind" in
      design)
        if pi_finalize_labels_design "$pr_number"; then
          pi_log "PR #${pr_number}: kind=${kind} round=${next_round} action=success (codex-needs-iteration -> codex-awaiting-design-review)"
          finalize_ok=true
        fi
        ;;
      impl)
        if pi_finalize_labels "$pr_number"; then
          pi_log "PR #${pr_number}: kind=${kind} round=${next_round} action=success (codex-needs-iteration -> codex-ready-for-review)"
          finalize_ok=true
        fi
        ;;
    esac
    if [ "$finalize_ok" = "true" ]; then
      return 0
    fi
    pi_warn "PR #${pr_number}: kind=${kind} ラベル遷移失敗、codex-needs-iteration を残置"
    return 1
  else
    # AC 6.3 (#26) / #35 AC 3.3: 失敗 → codex-needs-iteration を残し WARN
    pi_log "PR #${pr_number}: kind=${kind} round=${next_round} action=fail (codex-needs-iteration を残置)"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# process_pr_iteration: PR Iteration Processor のエントリ関数
#   AC 1.6, 2.1, 2.2, 8.5, 9.1, 9.3, NFR 1.2, NFR 2.3
# ─────────────────────────────────────────────────────────────────────────────
process_pr_iteration() {
  # AC 2.1: opt-in gate
  if [ "$PR_ITERATION_ENABLED" != "true" ]; then
    return 0
  fi

  # NFR 2.3 / AC 8.5: dirty working tree 検知
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    pi_error "dirty working tree を検出しました。PR Iteration Processor をスキップします。"
    return 0
  fi

  pi_log "サイクル開始 (max_prs=${PR_ITERATION_MAX_PRS}, max_rounds=${PR_ITERATION_MAX_ROUNDS}, model=${PR_ITERATION_DEV_MODEL}, design_enabled=${PR_ITERATION_DESIGN_ENABLED}, timeout=${PR_ITERATION_GIT_TIMEOUT}s)"

  local prs_json
  prs_json=$(pi_fetch_candidate_prs)
  local total
  total=$(echo "$prs_json" | jq 'length')

  # #35 NFR 3.2: 候補 PR の design / impl 内訳をログに記録（kind=ambiguous も含む）。
  # candidate 段階では impl pattern OR (DESIGN_ENABLED=true AND design pattern) で絞られる
  # ため、ここでは bash 側で同じ正規表現照合を行って breakdown を出す。
  local design_count=0
  local impl_count=0
  local ambiguous_count=0
  if [ "$total" -gt 0 ]; then
    local breakdown
    breakdown=$(echo "$prs_json" | jq -r \
      --arg impl_pattern "$PR_ITERATION_HEAD_PATTERN" \
      --arg design_pattern "$PR_ITERATION_DESIGN_HEAD_PATTERN" \
      --arg design_enabled "$PR_ITERATION_DESIGN_ENABLED" \
      '[.[] | .headRefName] as $heads
       | reduce $heads[] as $h ({"design":0, "impl":0, "ambiguous":0};
           if ($h | test($impl_pattern)) and ($h | test($design_pattern))
             then .ambiguous += 1
           elif ($h | test($design_pattern)) and ($design_enabled == "true")
             then .design += 1
           elif ($h | test($impl_pattern))
             then .impl += 1
           else . end)
       | "\(.design) \(.impl) \(.ambiguous)"')
    # shellcheck disable=SC2086
    set -- $breakdown
    design_count="${1:-0}"
    impl_count="${2:-0}"
    ambiguous_count="${3:-0}"
  fi

  local target_count="$total"
  local skipped_overflow=0

  if [ "$total" -gt "$PR_ITERATION_MAX_PRS" ]; then
    target_count="$PR_ITERATION_MAX_PRS"
    skipped_overflow=$((total - PR_ITERATION_MAX_PRS))
    pi_log "対象候補 ${total} 件中、上限 ${PR_ITERATION_MAX_PRS} 件のみ処理（${skipped_overflow} 件は次回持ち越し、内訳: design=${design_count}, impl=${impl_count}, ambiguous=${ambiguous_count}）"
  else
    pi_log "対象候補 ${total} 件、処理対象 ${target_count} 件（内訳: design=${design_count}, impl=${impl_count}, ambiguous=${ambiguous_count}）"
  fi

  if [ "$target_count" -eq 0 ]; then
    pi_log "サマリ: success=0, fail=0, skip=0, escalated=0, overflow=${skipped_overflow} (design=0, impl=0)"
    return 0
  fi

  local success=0
  local fail=0
  local skip=0
  local escalated=0

  local pr_iter
  pr_iter=$(echo "$prs_json" | jq -c ".[0:${target_count}][]")

  if [ -z "$pr_iter" ]; then
    pi_log "サマリ: success=0, fail=0, skip=0, escalated=0, overflow=${skipped_overflow} (design=0, impl=0)"
    return 0
  fi

  while IFS= read -r pr_json; do
    local rc=0
    pi_run_iteration "$pr_json" || rc=$?
    case $rc in
      0)  success=$((success + 1)) ;;
      2)  escalated=$((escalated + 1)) ;;
      3)  skip=$((skip + 1)) ;;       # #35: kind=none / ambiguous は skip としてカウント
      *)  fail=$((fail + 1)) ;;
    esac
    # 各 PR 処理後に保険で base branch に戻す
    git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
  done <<< "$pr_iter"

  # #35 NFR 3.1 / 3.2: サマリにも design / impl 内訳を出して grep 集計可能にする
  pi_log "サマリ: success=${success}, fail=${fail}, skip=${skip}, escalated=${escalated}, overflow=${skipped_overflow} (design=${design_count}, impl=${impl_count})"

  # 念のため最終確認で base branch に戻す
  git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Design Review Release Processor (#40)
#
# `codex-awaiting-design-review` ラベルが付いた Issue について、リンクされた設計 PR
# （head branch が `^codex/issue-<N>-design-` 規約）が merged 状態なら、
# Issue からラベルを除去してステータスコメントを 1 件投稿する。
#
# 既存運用（人間が手動でラベルを外す運用）を壊さないため opt-in
# （DESIGN_REVIEW_RELEASE_ENABLED=true で有効化、デフォルト false）。
# 既存 LOCK_FILE / LOG_DIR / exit code / cron 登録文字列は不変。
# Phase A / Re-check / PR Iteration と同じ flock 境界内で直列実行する。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

drr_log() {
  echo "[$(date '+%F %T')] design-review-release: $*"
}
drr_warn() {
  echo "[$(date '+%F %T')] design-review-release: WARN: $*" >&2
}
drr_error() {
  echo "[$(date '+%F %T')] design-review-release: ERROR: $*" >&2
}

# 与えられた Issue が、本機能が以前のサイクルで投稿したステータスコメントを既に
# 持っているかを判定する（hidden HTML marker による既処理判定）。
#   入力: $1 = issue_number
#   出力: stdout に "true" or "false"
#   返り値: 0 = 判定成功 / 1 = API エラー or タイムアウト（呼び出し元で WARN）
# AC 4.2 / 4.3 / 4.4 / 5.3 / 5.4
drr_already_processed() {
  local issue_number="$1"
  local comments_json
  if ! comments_json=$(timeout "$DRR_GH_TIMEOUT" \
      gh issue view "$issue_number" --repo "$REPO" --json comments 2>/dev/null); then
    return 1
  fi
  local marker_re="idd-codex:design-review-release issue=${issue_number}"
  if echo "$comments_json" | jq -e --arg re "$marker_re" \
      '.comments // [] | map(.body // "") | any(test($re))' >/dev/null 2>&1; then
    echo "true"
  else
    echo "false"
  fi
  return 0
}

# 与えられた Issue 番号にリンクされた、head branch が DESIGN_REVIEW_RELEASE_HEAD_PATTERN
# にマッチし、かつ body に `Refs #<issue_number>` を含む merged PR の番号を返す。
# 複数件マッチ時は最大番号 = 最新を採用する。
#   入力: $1 = issue_number
#   出力: stdout に PR 番号、該当無しなら空文字
#   返り値: 0 = 検出 or 該当無し（共に正常） / 1 = API エラー or タイムアウト
# AC 2.2 / 2.3 / 2.4 / 2.5 / 2.6 / 5.3 / 5.4 / NFR 2.2
drr_find_merged_design_pr() {
  local issue_number="$1"
  local prs_json
  # head pattern を server-side クエリで一次絞り込み（in:head + 規約 prefix）。
  # 複数件マッチを許容するため limit=20。
  # 注意（Issue #80）: GitHub の text search はトークン分解（"codex" / "issue" / "${N}" /
  # "design" の各語）で他 Issue 用の merged 設計 PR もヒットさせるため、ここでは候補
  # 取得（noisy）に留め、最終一致判定は後段の jq で issue 番号 fix の strict prefix で行う。
  if ! prs_json=$(timeout "$DRR_GH_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state merged \
      --search "is:pr is:merged codex/issue-${issue_number}-design- in:head" \
      --json number,headRefName,mergedAt \
      --limit 20 2>/dev/null); then
    return 1
  fi

  # Issue #80: head 名を issue 番号で strict 比較する（旧 `^codex/issue-[0-9]+-design-`
  # では他 Issue 用 PR が通過していた）。body の `Refs #N` 検査は cross-reference
  # （Architect が design PR 本文で別 Issue を参照する）と衝突して誤検知の原因に
  # なっていたため drop。head が `codex/issue-${N}-design-<slug>` で始まることを
  # 唯一の同定条件とする。
  # 同 issue 番号の merged 設計 PR が複数ある場合（再 design 等）は、PR 番号最大
  # （= 最新と看做す）を採用。
  local strict_head_prefix="codex/issue-${issue_number}-design-"
  local pr_number
  pr_number=$(echo "$prs_json" | jq -r \
    --arg prefix "$strict_head_prefix" \
    '[(. // [])[]
      | select(.headRefName | startswith($prefix))
      | .number
    ] | sort | last // ""' 2>/dev/null || echo "")
  echo "$pr_number"
  return 0
}

# 確定した除去対象 Issue に対し、`codex-awaiting-design-review` ラベル除去 + ステータス
# コメント投稿を順次実行する。PR 側操作・push・close は一切行わない（NFR 2.1 / 2.3）。
#   入力: $1 = issue_number, $2 = merged_pr_number
#   返り値: 0 = ラベル除去 + コメント投稿 成功 / 1 = いずれかが失敗
# AC 3.1 / 3.2 / 3.3 / 3.4 / 3.5 / 3.6 / 5.3 / 5.4 / 6.7 / 7.6
drr_remove_label_and_comment() {
  local issue_number="$1"
  local merged_pr_number="$2"

  # AC 3.1 / 3.4: ラベル除去。失敗時はコメントを投稿しない。
  if ! timeout "$DRR_GH_TIMEOUT" gh issue edit "$issue_number" \
      --repo "$REPO" \
      --remove-label "$LABEL_AWAITING_DESIGN" >/dev/null 2>&1; then
    drr_warn "Issue #${issue_number}: ラベル除去 API 失敗（タイムアウト or 4xx/5xx）。コメント投稿は skip し、次サイクルで再試行します。"
    return 1
  fi

  # AC 3.2 / 3.3 / 4.3: ステータスコメント本文（末尾に hidden marker を含む）。
  local body
  body=$(cat <<EOF
## 自動: 設計 PR merge を検出

設計 PR #${merged_pr_number} が merged されました。
本 Issue から \`codex-awaiting-design-review\` ラベルを自動除去しました。

次回 cron tick で Developer が **impl-resume モード**で自動起動し、
\`docs/specs/<N>-<slug>/\` 配下の design.md / tasks.md に従って実装 PR を作成します。

---

_本コメントは \`local-watcher/bin/idd-codex-issue-watcher.sh\` の Design Review Release Processor が
投稿しました。\`DESIGN_REVIEW_RELEASE_ENABLED=true\` で有効化されています。_

<!-- idd-codex:design-review-release issue=${issue_number} pr=${merged_pr_number} -->
EOF
)

  # AC 3.5: コメント投稿失敗時もラベルは除去済み。次サイクルで Issue は impl-resume へ進める。
  if ! timeout "$DRR_GH_TIMEOUT" gh issue comment "$issue_number" \
      --repo "$REPO" \
      --body "$body" >/dev/null 2>&1; then
    drr_warn "Issue #${issue_number}: ステータスコメント投稿 API 失敗（ラベルは除去済み、後続 Issue 処理は継続）。"
    return 1
  fi

  return 0
}

# Design Review Release Processor のエントリ関数。
# 1 watcher サイクル内で `codex-awaiting-design-review` 付き Issue を検出し、
# 設計 PR が merged なら ラベル除去 + コメント投稿を順次実行する。
# AC 1.1 / 1.4 / 2.1 / 2.7 / 4.1 / 4.4 / 4.5 / 5.2 / 5.5 / 6.1 / 6.2 / 6.3 / 7.5
process_design_review_release() {
  # AC 1.1 / 1.4 / 7.5: opt-in gate（無効化時は完全スキップ）
  if [ "$DESIGN_REVIEW_RELEASE_ENABLED" != "true" ]; then
    return 0
  fi

  drr_log "サイクル開始 (max_issues=${DESIGN_REVIEW_RELEASE_MAX_ISSUES}, head_pattern=${DESIGN_REVIEW_RELEASE_HEAD_PATTERN}, timeout=${DRR_GH_TIMEOUT}s)"

  # AC 2.1 / 2.7 / 4.1 / 4.5: server-side filter で `codex-awaiting-design-review` を必須に、
  # `codex-failed` / `codex-needs-decisions` を除外。人間が先に手動除去した Issue は候補に上がらない。
  # Issue #54 Req 1.1 / 5.1: PR 専用ラベル `codex-needs-iteration` が Issue 側に誤付与された
  # ケースは Documentation Set 全体で「PR 適用」と一貫させるため、ここでも候補から除外する。
  local issues_json
  if ! issues_json=$(timeout "$DRR_GH_TIMEOUT" gh issue list \
      --repo "$REPO" \
      --state open \
      --search "label:\"$LABEL_AWAITING_DESIGN\" -label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_NEEDS_ITERATION\"" \
      --json number,title,url,labels \
      --limit 100 2>/dev/null); then
    drr_warn "候補 Issue 取得 API 失敗（タイムアウト or 4xx/5xx）。本サイクルの Design Review Release Processor は skip。"
    return 0
  fi

  # client-side fail-safe filter: label 配列に `codex-awaiting-design-review` あり、
  # `codex-failed` / `codex-needs-decisions` なし（server-side filter の二重ガード）。
  local filtered_json
  filtered_json=$(echo "$issues_json" | jq -c \
    --arg awaiting "$LABEL_AWAITING_DESIGN" \
    --arg failed "$LABEL_FAILED" \
    --arg needs_decisions "$LABEL_NEEDS_DECISIONS" \
    '[(. // [])[]
      | select((.labels // []) | map(.name) | index($awaiting))
      | select(((.labels // []) | map(.name) | index($failed)) | not)
      | select(((.labels // []) | map(.name) | index($needs_decisions)) | not)
    ]' 2>/dev/null || echo "[]")

  local total
  total=$(echo "$filtered_json" | jq 'length' 2>/dev/null || echo 0)
  local target_count="$total"
  local skipped_overflow=0

  if [ "$total" -gt "$DESIGN_REVIEW_RELEASE_MAX_ISSUES" ]; then
    target_count="$DESIGN_REVIEW_RELEASE_MAX_ISSUES"
    skipped_overflow=$((total - DESIGN_REVIEW_RELEASE_MAX_ISSUES))
    drr_log "対象候補 ${total} 件中、上限 ${DESIGN_REVIEW_RELEASE_MAX_ISSUES} 件のみ処理（${skipped_overflow} 件は次回持ち越し: overflow=${skipped_overflow}）"
  else
    drr_log "対象候補 ${total} 件、処理対象 ${target_count} 件、overflow=${skipped_overflow}"
  fi

  if [ "$target_count" -eq 0 ]; then
    drr_log "サマリ: removed=0, kept=0, skip=0, fail=0, overflow=${skipped_overflow}"
    return 0
  fi

  local issue_iter
  issue_iter=$(echo "$filtered_json" | jq -c ".[0:${target_count}][]" 2>/dev/null || echo "")
  if [ -z "$issue_iter" ]; then
    drr_log "サマリ: removed=0, kept=0, skip=0, fail=0, overflow=${skipped_overflow}"
    return 0
  fi

  local removed=0
  local kept=0
  local skipped=0
  local failed=0
  # AC 4.4: 同一サイクル内での重複処理ガード（gh issue list の結果は一意のはずだが念のため）
  local processed_numbers=""

  while IFS= read -r issue_json; do
    [ -z "$issue_json" ] && continue
    local issue_number
    issue_number=$(echo "$issue_json" | jq -r '.number' 2>/dev/null || echo "")
    if [ -z "$issue_number" ] || [ "$issue_number" = "null" ]; then
      drr_warn "Issue 番号の解析に失敗: ${issue_json}"
      failed=$((failed + 1))
      continue
    fi

    # AC 4.4: 同一サイクル内で同一 Issue を 2 回処理しない
    case " $processed_numbers " in
      *" $issue_number "*)
        drr_log "Issue #${issue_number}: 同一サイクル内で既に処理済み、skip"
        skipped=$((skipped + 1))
        continue
        ;;
    esac
    processed_numbers="$processed_numbers $issue_number"

    # AC 4.2 / 4.3: 既処理判定（hidden marker チェック）
    local already
    if ! already=$(drr_already_processed "$issue_number"); then
      drr_warn "Issue #${issue_number}: 既処理判定 API 失敗、当該 Issue を skip し次 Issue へ"
      failed=$((failed + 1))
      continue
    fi
    if [ "$already" = "true" ]; then
      drr_log "Issue #${issue_number}: action=skip (already processed)"
      skipped=$((skipped + 1))
      continue
    fi

    # AC 2.2 / 2.3 / 2.4 / 2.5 / 2.6: merged 設計 PR の検出
    local merged_pr_number
    if ! merged_pr_number=$(drr_find_merged_design_pr "$issue_number"); then
      drr_warn "Issue #${issue_number}: PR 検出 API 失敗、当該 Issue を skip し次 Issue へ"
      failed=$((failed + 1))
      continue
    fi
    if [ -z "$merged_pr_number" ]; then
      # AC 2.5 / 2.6: リンク PR 0 件 or merged 0 件 → kept
      drr_log "Issue #${issue_number}: merged-design-pr=none, action=kept"
      kept=$((kept + 1))
      continue
    fi

    # AC 3.1 / 3.2 / 3.3: ラベル除去 + ステータスコメント投稿
    if drr_remove_label_and_comment "$issue_number" "$merged_pr_number"; then
      drr_log "Issue #${issue_number}: merged-design-pr=#${merged_pr_number}, action=label removed + commented"
      removed=$((removed + 1))
    else
      drr_log "Issue #${issue_number}: merged-design-pr=#${merged_pr_number}, action=fail"
      failed=$((failed + 1))
    fi
  done <<< "$issue_iter"

  drr_log "サマリ: removed=${removed}, kept=${kept}, skip=${skipped}, fail=${failed}, overflow=${skipped_overflow}"
  return 0
}

# Phase A 直後に PR Iteration Processor を実行（AC 8.1 / 8.2: 同一 flock 内で直列実行）
process_pr_iteration || pi_warn "process_pr_iteration が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# Design Review Release Processor を Issue 処理ループの直前に実行（#40 AC 1.3 / 1.5）
process_design_review_release || drr_warn "process_design_review_release が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Stage Checkpoint Module (#68) — impl / impl-resume の Stage 単位 resume
#
# Stage A/B/C の完了 checkpoint を成果物（impl-notes.md / review-notes.md /
# 既存 impl PR）の存在で観測し、failed Stage 以降のみを再実行する opt-in 機能。
# `STAGE_CHECKPOINT_ENABLED=true` のときのみ run_impl_pipeline 冒頭から呼び出される。
#
# 関数群:
#   - sc_log / sc_warn / sc_error               : `stage-checkpoint:` prefix logger
#   - stage_checkpoint_has_impl_notes           : Stage A 完了観測（branch HEAD tracked）
#   - stage_checkpoint_read_review_result       : Stage B 完了観測（review-notes.md）
#   - stage_checkpoint_find_impl_pr             : Stage C 完了観測（既存 impl PR）
#   - stage_checkpoint_resolve_resume_point     : decision table → START_STAGE 決定
#
# 設計参照: docs/specs/68-feat-watcher-stage-checkpoint-reviewer-p/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Stage Checkpoint 専用ロガー（既存 mq_log / pi_log / rv_log と同形式）。
# `stage-checkpoint:` prefix で grep 抽出可能（NFR 2.2）。warn / error は stderr へ。
sc_log() {
  echo "[$(date '+%F %T')] stage-checkpoint: $*"
}
sc_warn() {
  echo "[$(date '+%F %T')] stage-checkpoint: WARN: $*" >&2
}
sc_error() {
  echo "[$(date '+%F %T')] stage-checkpoint: ERROR: $*" >&2
}

# ─── stage_checkpoint_has_impl_notes ───
#
# Stage A 完了 checkpoint（impl-notes.md）の **当該 Issue branch HEAD 上での tracked**
# を判定する。working tree のみに存在し未 commit のファイルは不採用とする
# （Req 4.1, 4.2, 4.4 / 部分実行を許さない、Req 5.1）。
#
# 入力: 環境変数 REPO_DIR / SPEC_DIR_REL（呼び出し元 _slot_run_issue が設定済み）
# 戻り値: 0 = checkpoint 採用 / 1 = 不採用（不在 or untracked）
# 副作用: なし
stage_checkpoint_has_impl_notes() {
  local rel="$SPEC_DIR_REL/impl-notes.md"
  local path="$REPO_DIR/$rel"
  [ -f "$path" ] || return 1
  # branch HEAD で tracked であることを確認（main 由来 or 未 commit ファイルは不採用）。
  # `git ls-tree --name-only HEAD -- <path>` は tracked なら path をそのまま echo し、
  # untracked なら空出力。`>/dev/null` で出力を捨て、exit code のみで判定。
  local out
  out=$(git -C "$REPO_DIR" ls-tree --name-only HEAD -- "$rel" 2>/dev/null || true)
  [ -n "$out" ]
}

# ─── stage_checkpoint_read_review_result ───
#
# Stage B 完了 checkpoint（review-notes.md）の RESULT 行を抽出する。
# 既存 parse_review_result を再利用し、契約は変更しない（Req 1.2, 4.3, 4.4）。
# branch HEAD tracked チェックを先行して、未 commit / main 由来の残骸は不採用とする。
#
# 入力: 環境変数 REPO_DIR / SPEC_DIR_REL
# 戻り値: 0 = approve / 1 = reject / 2 = 不在 or RESULT 行欠落 or untracked
# stdout: parse_review_result と同形式の TSV `<result>\t<categories>\t<targets>`
#         （戻り値 2 のときは何も出力しない）
stage_checkpoint_read_review_result() {
  local rel="$SPEC_DIR_REL/review-notes.md"
  local path="$REPO_DIR/$rel"
  [ -f "$path" ] || return 2
  local tracked
  tracked=$(git -C "$REPO_DIR" ls-tree --name-only HEAD -- "$rel" 2>/dev/null || true)
  [ -n "$tracked" ] || return 2
  local parsed
  parsed=$(parse_review_result "$path") || return 2
  local result
  result=$(echo "$parsed" | cut -f1)
  echo "$parsed"
  case "$result" in
    approve) return 0 ;;
    reject)  return 1 ;;
    *)       return 2 ;;
  esac
}

# ─── stage_checkpoint_find_impl_pr ───
#
# Stage C 完了（impl PR の存在）を観測する。OPEN / MERGED / CLOSED いずれの状態でも
# 「Stage C 後の状態」とみなして自動進行を停止する（Req 1.3, 2.6）。CLOSED は人間判断に
# よる close と解釈し、自動再開はしない。
#
# 入力: 環境変数 REPO / BRANCH
# 戻り値: 0 = 既存 impl PR あり / 1 = なし / 2 = gh API エラー
# stdout: `<pr_number>,<state>`（複数の場合は最新 1 件のみ）
stage_checkpoint_find_impl_pr() {
  local prs
  prs=$(gh pr list --repo "$REPO" --head "$BRANCH" --state all \
        --json number,state --limit 5 2>/dev/null) || return 2
  local found
  found=$(echo "$prs" | jq -r '[.[] | select(.state == "OPEN" or .state == "MERGED" or .state == "CLOSED")] | .[0] // empty' 2>/dev/null || true)
  [ -n "$found" ] || return 1
  echo "$found" | jq -r '"\(.number),\(.state)"' 2>/dev/null || return 2
  return 0
}

# ─── stage_checkpoint_resolve_resume_point ───
#
# Stage A/B/C の checkpoint を観測し、START_STAGE を 1 つに決定する。
# 出力 domain: A / B / C / TERMINAL_OK / TERMINAL_FAILED。
#
# Decision Table（design.md と同期、設計参照: docs/specs/68-*/design.md）:
#   既存 PR あり                                      → TERMINAL_OK
#   impl-notes 無 / review-notes 有 (任意)            → A (INCONSISTENT, Req 5.1)
#   impl-notes 無 / review-notes 無                   → A (Req 2.2)
#   impl-notes 有 / review-notes 無                   → B (Req 2.3)
#   impl-notes 有 / review-notes parse 失敗            → B (Req 4.3)
#   impl-notes 有 / RESULT=approve                     → C (Req 2.4)
#   impl-notes 有 / RESULT=reject (round=2 と推定)     → TERMINAL_FAILED (Req 2.5)
#   impl-notes 有 / RESULT=reject (round=1 と推定)     → A (D-3, INCONSISTENT 扱い)
#
# round=1 / round=2 判別: review-notes.md 内 `<!-- idd-codex:review round=N -->`
# を grep。いずれも見つからなければ INCONSISTENT として Stage A から再実行する
# （safe fallback）。
#
# 入力: 環境変数 NUMBER / BRANCH / REPO / REPO_DIR / SPEC_DIR_REL / LOG
# 副作用:
#   - グローバル変数 START_STAGE に "A" / "B" / "C" / "TERMINAL_OK" / "TERMINAL_FAILED" を代入
#   - $LOG / stdout に 1 ブロックの判定根拠ログを sc_log で出力（NFR 2.1, NFR 2.2）
# 戻り値:
#   0 = 判定成功（START_STAGE 設定済）
#   1 = 内部エラー（START_STAGE="A" にフォールバック、Req 5.4）
stage_checkpoint_resolve_resume_point() {
  # 内部エラーの安全側フォールバックのため、エラーを補足できるよう || true で個別ガード。
  # START_STAGE は呼び出し元 run_impl_pipeline（task 4）が読み取る共有変数。
  # task 3 単独では read 側が無いため SC2034 を一括抑制（task 4 で消える）。
  # shellcheck disable=SC2034
  START_STAGE="A"

  sc_log "--- begin resolve (issue=#$NUMBER branch=$BRANCH) ---" >> "$LOG"
  sc_log "input: spec_dir=$SPEC_DIR_REL" >> "$LOG"

  # 1) 既存 impl PR を最優先で検出（Req 2.6: TERMINAL_OK）。
  local pr_info pr_rc
  pr_info=$(stage_checkpoint_find_impl_pr 2>/dev/null) && pr_rc=0 || pr_rc=$?
  case "$pr_rc" in
    0)
      sc_log "input: existing-impl-pr=$pr_info" >> "$LOG"
      START_STAGE="TERMINAL_OK"
      sc_log "decision: START_STAGE=TERMINAL_OK reason=existing-impl-pr" >> "$LOG"
      sc_log "--- end resolve ---" >> "$LOG"
      return 0
      ;;
    1)
      sc_log "input: existing-impl-pr=none" >> "$LOG"
      ;;
    *)
      sc_warn "gh pr list failed (rc=$pr_rc) → safe fallback: existing-impl-pr=unknown" >> "$LOG"
      sc_log "input: existing-impl-pr=unknown" >> "$LOG"
      # gh API エラーは判定継続（fallback="A"）。Stage A 再実行は安全（Req 5.4）
      ;;
  esac

  # 2) impl-notes.md tracked 判定（Stage A 完了 checkpoint）。
  local has_impl="no"
  if stage_checkpoint_has_impl_notes; then
    has_impl="yes"
  fi
  sc_log "input: impl-notes.md tracked=$has_impl" >> "$LOG"

  # 3) review-notes.md tracked + RESULT 行 parse（Stage B 完了 checkpoint）。
  # stdout 側の TSV は本箇所では未使用（result/round は別途 grep で取得）。
  local rev_rc=0
  stage_checkpoint_read_review_result >/dev/null 2>&1 || rev_rc=$?
  local rev_result="(none)"
  case "$rev_rc" in
    0) rev_result="approve" ;;
    1) rev_result="reject" ;;
    *) rev_result="(missing-or-unparsed)" ;;
  esac
  # tracked 判定（rev_rc から逆算するのではなく、ls-tree で実態を直接観測する）。
  local rev_path="$REPO_DIR/$SPEC_DIR_REL/review-notes.md"
  local rev_tracked="no"
  if [ -f "$rev_path" ]; then
    local rev_ls_out
    rev_ls_out=$(git -C "$REPO_DIR" ls-tree --name-only HEAD -- "$SPEC_DIR_REL/review-notes.md" 2>/dev/null || true)
    [ -n "$rev_ls_out" ] && rev_tracked="yes"
  fi
  # round 判定: review-notes.md 内に round=N が無ければ "unknown"（INCONSISTENT 扱い）
  local rev_round="unknown"
  if [ "$has_impl" = "yes" ] && [ -f "$rev_path" ]; then
    if grep -q '^<!-- idd-codex:review round=2' "$rev_path" 2>/dev/null \
       || grep -q '^round=2$' "$rev_path" 2>/dev/null; then
      rev_round="2"
    elif grep -q '^<!-- idd-codex:review round=1' "$rev_path" 2>/dev/null \
       || grep -q '^round=1$' "$rev_path" 2>/dev/null; then
      rev_round="1"
    fi
  fi
  sc_log "input: review-notes.md tracked=$rev_tracked result=$rev_result round=$rev_round" >> "$LOG"

  # 4) Decision Table（評価順序: 矛盾検出 → 通常分岐）。
  if [ "$has_impl" = "no" ]; then
    if [ "$rev_rc" -eq 2 ]; then
      # impl-notes 無 / review-notes 無 → 通常の Stage A (Req 2.2)
      START_STAGE="A"
      sc_log "decision: START_STAGE=A reason=no-checkpoint" >> "$LOG"
    else
      # impl-notes 無 / review-notes 有 → INCONSISTENT (Req 5.1)
      START_STAGE="A"
      sc_log "decision: START_STAGE=A reason=inconsistent-review-notes-without-impl-notes" >> "$LOG"
    fi
    sc_log "--- end resolve ---" >> "$LOG"
    return 0
  fi

  # ここから has_impl=yes 系
  case "$rev_rc" in
    2)
      # review-notes 不在 or 解釈不能 → Stage B から再実行 (Req 2.3, 4.3)
      START_STAGE="B"
      sc_log "decision: START_STAGE=B reason=impl-notes-only-or-review-unparsed" >> "$LOG"
      ;;
    0)
      # approve → Stage C (Req 2.4)
      START_STAGE="C"
      sc_log "decision: START_STAGE=C reason=approve+no-pr" >> "$LOG"
      ;;
    1)
      # reject → round で分岐 (D-3, Req 2.5)
      case "$rev_round" in
        2)
          START_STAGE="TERMINAL_FAILED"
          sc_log "decision: START_STAGE=TERMINAL_FAILED reason=round2-reject-residual" >> "$LOG"
          ;;
        1)
          # round=1 reject の中断状態は同 tick 完結前提が破れた状況 → Stage A 再実行 (D-3)
          # shellcheck disable=SC2034
          START_STAGE="A"
          sc_log "decision: START_STAGE=A reason=round1-reject-mid-tick-fallback" >> "$LOG"
          ;;
        *)
          # round=N が読み取れない（手動編集 / 旧フォーマット）→ INCONSISTENT 扱い
          # shellcheck disable=SC2034
          START_STAGE="A"
          sc_log "decision: START_STAGE=A reason=reject-with-unknown-round" >> "$LOG"
          ;;
      esac
      ;;
  esac

  sc_log "--- end resolve ---" >> "$LOG"
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Reviewer Gate (#20 Phase 1) — impl 系モード stage 分割パイプライン
#
# 既存の impl / impl-resume モードは DEV_PROMPT 1 回で PM + Developer + PjM を
# 直列起動していたが、Reviewer 役割を独立 context で挟むため、以下の
# stage に分割する:
#
#   Stage A  : PM + Developer（ただし impl-resume では PM をスキップ）
#   Stage B  : Reviewer (round=1)
#   Stage A' : Developer 再実行（reject 時のみ、最大 1 回）
#   Stage B' : Reviewer (round=2、reject 時のみ)
#   Stage C  : PjM（PR 作成）
#
# 各 stage は `codex exec` の独立プロセスで起動。stage 間の context 共有は
# しない（要件 2.2「独立 Codex セッション」）。Reviewer 判定は
# `docs/specs/<N>-<slug>/review-notes.md` の最終 RESULT 行で受け渡す。
#
# 元設計: Reviewer gate を独立 Codex セッションとして扱う。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Reviewer / Pipeline 専用ロガー（既存 mq_log / pi_log と同形式）
rv_log() {
  echo "[$(date '+%F %T')] reviewer: $*"
}
rv_dev_log() {
  echo "[$(date '+%F %T')] developer: $*"
}

# ─── Prompt Builders（Stage A / A' / B / C 用 4 関数）───
#
# 既存 DEV_PROMPT の組み立てパターン（heredoc + 変数展開）を踏襲する。
# 入力は環境変数（NUMBER / TITLE / URL / BODY / BRANCH / SPEC_DIR_REL /
# MODE / ARCHITECT_REASON）と関数引数。stdout に prompt 文字列を出力する。

# ─── _assert_base_branch_resolved ───
#
# Issue #96 Req 1.5: PR 作成系プロンプト（Stage C / design-review）を組み立てる直前に
# 解決済み `BASE_BRANCH` の実値が空文字でないことを検証する防御的ガード。
# 通常パスでは起動直後の `BASE_BRANCH="${BASE_BRANCH:-main}"` で必ず非空になるため
# 発火しないが、コード変更で誤って空文字を導入した場合に PR 作成段階で爆破するためのもの。
#
# 失敗時の挙動: stderr にエラー出力し、戻り値 1 を返す。呼び出し側（pipeline / design 分岐）が
# `_slot_mark_failed` で `codex-failed` ラベルを付与して人間にエスカレーションする。
_assert_base_branch_resolved() {
  if [ -z "${BASE_BRANCH:-}" ]; then
    echo "Error: BASE_BRANCH が空または未定義です。PR 作成プロンプトを組み立てられません（Issue #96 Req 1.5）" >&2
    return 1
  fi
  return 0
}

# Stage A: PM + Developer（impl では PM 起動、impl-resume では Developer のみ）
# 既存 DEV_PROMPT の STEPS から「PjM 起動」を除外したもの。
build_dev_prompt_a() {
  local mode="$1"
  local flow_label
  local steps

  case "$mode" in
    impl)
      flow_label="PM → Developer（Reviewer ゲート前）"
      steps=$(cat <<EOF
1. `.codex/agents/product-manager.md` の役割指示に従い、要件定義を \`${SPEC_DIR_REL}/requirements.md\` に保存
   - Issue 本文と既存コメント（\`gh issue view ${NUMBER} --comments\`）を必ず読む
   - 人間がコメントで回答済みの決定事項は requirements に反映する
2. `.codex/agents/developer.md` の役割指示に従い、実装＋テスト＋コミット
   - 入力: \`${SPEC_DIR_REL}/requirements.md\`
   - 規約は AGENTS.md に従う
   - 実装ノートを \`${SPEC_DIR_REL}/impl-notes.md\` に保存

**重要**: 本ステージでは PR 作成（Project Manager 役割）を行わないこと。
Developer 完了後、独立 context の Reviewer 役割が起動して AC / test / boundary を
独立レビューします。Reviewer の approve 後にオーケストレーターが PjM を起動して PR を作成します。
EOF
)
      ;;
    impl-resume)
      flow_label="Developer（Reviewer ゲート前 / 設計 PR merge 済み）"
      steps=$(cat <<EOF
1. `.codex/agents/developer.md` の役割指示に従い、実装＋テスト＋コミット
   - 入力: \`${SPEC_DIR_REL}/requirements.md\` / \`${SPEC_DIR_REL}/design.md\` / \`${SPEC_DIR_REL}/tasks.md\`
   - design.md / tasks.md は設計 PR で人間レビュー済み（${BASE_BRANCH} に merge 済み）。**書き換えないこと**
   - tasks.md の numeric ID 順にタスクを消化する
   - 矛盾や疑問があれば PR 本文「確認事項」に記載（書き換えはしない）
   - 規約は AGENTS.md に従う
   - 実装ノートを \`${SPEC_DIR_REL}/impl-notes.md\` に保存

**重要**: 本ステージでは PR 作成（Project Manager 役割）を行わないこと。
Developer 完了後、独立 context の Reviewer 役割が起動して AC / test / boundary を
独立レビューします。Reviewer の approve 後にオーケストレーターが PjM を起動して PR を作成します。
EOF
)
      ;;
  esac

  # Issue #67: impl-resume + IMPL_RESUME_PRESERVE_COMMITS=true 時のみ追加注入する
  # 「resume 指示」セクションと、`IMPL_RESUME_PROGRESS_TRACKING` の値による
  # `tasks.md` 進捗マーカー更新指示の分岐。既存 prompt の Step 1 / 制約節は変更せず、
  # 末尾に節を追加するだけ（既存挙動と差分等価 / NFR 1.1）。
  #
  # `RESUME_PRESERVE` は `_resume_branch_init` が export している（Slot Runner 内）。
  # `IMPL_RESUME_PROGRESS_TRACKING` は cron / launchd 経由で渡される env 値。
  # `_resume_normalize_flag` で 2 値正規化（Req 3.6: "false" 完全一致のみ false、
  # それ以外は true）。
  local resume_section=""
  if [ "$mode" = "impl-resume" ] && [ "${RESUME_PRESERVE:-false}" = "true" ]; then
    local tracking
    tracking=$(_resume_normalize_flag tracking_default_on "${IMPL_RESUME_PROGRESS_TRACKING:-}")

    local progress_block
    if [ "$tracking" = "true" ]; then
      progress_block=$(cat <<'EOF'
### tasks.md 進捗追跡（IMPL_RESUME_PROGRESS_TRACKING=true）

- 各タスクが完了した時点で `tasks.md` の対応する未完了マーカー行 `- [ ] N.M ...` を
  `- [x] N.M ...` に書き換えること
- 進捗マーカー更新は **専用 commit** として積む:
  - commit メッセージ: `docs(tasks): mark <task-id> as done`（例: `docs(tasks): mark 1.2 as done`）
  - 当該 commit には `tasks.md` 以外のファイルを含めない
- **書き換え禁止領域**: タスク本文 / `_Requirements:_` / `_Boundary:_` / `_Depends:_` /
  タスク順序 / 親タスクのインデント / deferrable 印 `- [ ]*`（アスタリスク付き）
- 親タスク（例: `- [ ] 1.`）は、その配下の全子タスクが `- [x]` になったタイミングで親側も
  `- [x]` に更新する（deferrable 子タスク `- [ ]*` は未完了のまま親完了を判定可能）
- すべてのタスクが完了済み（未完了マーカー `- [ ]` が残っていない）なら、追加実装を行わず
  impl-notes.md にその旨を記録すること
EOF
)
    else
      progress_block=$(cat <<'EOF'
### tasks.md 進捗追跡（IMPL_RESUME_PROGRESS_TRACKING=false）

- 本サイクルでは `tasks.md` の進捗マーカー（`- [ ]` ↔ `- [x]`）を **書き換えない**
- 通常通り numeric ID 順にタスクを消化し、impl-notes.md に進捗の根拠を記録する
EOF
)
    fi

    resume_section=$(cat <<EOF

## 既存 commit からの resume（IMPL_RESUME_PRESERVE_COMMITS=true）

このサイクルは **既存の作業ブランチからの resume** で起動されました。
worktree は \`origin/${BASE_BRANCH}\` から fresh init されておらず、\`origin/${BRANCH}\` の先端から
checkout されています。**過去 Developer / 人間が積んだ commit を温存してください**。

- 作業前に必ず \`git log --oneline ${BASE_BRANCH}..HEAD\` で既存 commit を確認すること
- \`git reset\` / \`git rebase\` / branch の切り替えは **禁止**
- 未完了タスクの判定基準: \`tasks.md\` の \`- [ ]\` 行（未完了マーカー）の先頭から再開
- 既存 commit と矛盾する変更が必要な場合は、既存 commit を打ち消す追加 commit を積む
  か、impl-notes.md の「確認事項」に矛盾内容を記載して人間判断を仰ぐ

${progress_block}
EOF
)
  fi

  cat <<EOF
あなたはこのリポジトリの Codex オーケストレーターです。
以下の Issue を ${flow_label} のフローで進めてください。
Codex では Claude Code の subagent 機構を使わないため、各手順では指定された
`.codex/agents/*.md` の役割指示を読んだ上で、その役割として作業してください。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- Body  : |
${BODY}

## 作業ブランチ
${BRANCH}（${BASE_BRANCH} から派生・push 済み・現在チェックアウト中）

## 作業ディレクトリ
${SPEC_DIR_REL}/

## 進め方
${steps}

## 制約
- ${BASE_BRANCH} に直接 push しないこと
- 既存のテストを壊さないこと
- 不明点は推測せず、impl-notes.md の「確認事項」セクションに列挙すること
- **PR は作成しないこと**（次の Reviewer ステージで独立レビューを受けます）
${resume_section}
EOF
}

# Stage A' (Developer 再実行用): Reviewer reject の Findings を inline で渡し、
# Developer に是正を依頼する。PM は再起動しない（要件は不変）。
build_dev_prompt_redo() {
  local review_notes_path="$1"
  local review_notes_content
  if [ -f "$review_notes_path" ]; then
    review_notes_content=$(cat "$review_notes_path")
  else
    review_notes_content="(review-notes.md が見つかりません)"
  fi

  cat <<EOF
あなたはこのリポジトリの Codex オーケストレーターです。
直前の Reviewer 役割が reject を出したため、`.codex/agents/developer.md` の役割指示に従って Developer として再実装してください。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}

## 作業ブランチ
${BRANCH}（追加 commit を積んでください。reset / branch 切り替えは禁止）

## 作業ディレクトリ
${SPEC_DIR_REL}/

## Reviewer の reject 理由（review-notes.md より）

\`\`\`markdown
${review_notes_content}
\`\`\`

## 進め方

1. `.codex/agents/developer.md` の役割指示に従い、上記 Findings の **Required Action** を順に実施する
   - 要件（requirements.md）は変更しない（PM への差し戻し相当の事象があれば impl-notes.md の
     「確認事項」に記載するに留める）
   - 設計（design.md / tasks.md）が存在する場合も書き換えない
   - 是正に必要なテストの追加・修正と、対応する実装変更のみを commit する
2. 完了後 \`${SPEC_DIR_REL}/impl-notes.md\` に是正内容を 1 セクション追記

## 制約
- ${BASE_BRANCH} に直接 push しないこと
- Product Manager / Project Manager 役割の作業はしないこと
  （PM は不要、PjM は次の Reviewer round=2 が approve した後にオーケストレーターが起動）
- **PR は作成しないこと**（再 Reviewer の判定を受けます）
- 既存テストを壊さないこと
EOF
}

# Stage B (Reviewer): reviewer 役割を独立 context で起動し、
# review-notes.md を書かせる。差分は reviewer 自身が Bash ツールで取得する設計
# （Issue #92: 大規模差分時の `Argument list too long` 回避のため、prompt から
# inline diff 全文を撤廃した）。prompt は差分サイズに依存せず固定サイズに収まる。
build_reviewer_prompt() {
  local round="$1"
  local prev_result="$2"   # round=2 のみ意味あり、round=1 は "(none)"
  local head_sha
  head_sha=$(git rev-parse HEAD 2>/dev/null || echo "(unknown)")

  cat <<EOF
あなたはこのリポジトリの Codex オーケストレーターです。
Developer の実装が一段落したため、`.codex/agents/reviewer.md` の役割指示に従う **独立レビュー**
（round=${round} / 最大 2 round）を実施してください。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- REPO  : ${REPO}

## 作業ブランチ / spec ディレクトリ
- BRANCH       : ${BRANCH}
- HEAD commit  : ${head_sha}
- BASE_BRANCH  : ${BASE_BRANCH}
- SPEC_DIR_REL : ${SPEC_DIR_REL}
- ROUND        : ${round}
- PREV_RESULT  : ${prev_result}

## 必読ファイル

Reviewer 役割として、着手前に以下を必ず読んでください:

- \`AGENTS.md\`（特に「テスト規約」と「禁止事項」）
- \`${SPEC_DIR_REL}/requirements.md\`（EARS 形式の AC、numeric ID）
- \`${SPEC_DIR_REL}/tasks.md\`（\`_Requirements:_\` / \`_Boundary:_\` アノテーション）
- \`${SPEC_DIR_REL}/impl-notes.md\`（Developer のテスト結果含む補足）
- \`${SPEC_DIR_REL}/design.md\`（存在する場合）

## 差分の取得（reviewer が Bash で実行）

prompt には差分本文を埋め込みません（Issue #92: 大差分時の \`Argument list too long\`
回避のため）。Reviewer 役割として着手直後に以下を実行し、
全体把握 → 必要箇所のファイル単位詳細の順で差分を取得してください:

1. 全体把握（変更ファイル一覧と統計）:
   \`\`\`bash
   git diff --stat ${BASE_BRANCH}..HEAD
   git log --oneline ${BASE_BRANCH}..HEAD
   \`\`\`
2. ファイル単位の詳細差分（必要に応じて変更ファイルごとに実行）:
   \`\`\`bash
   git diff ${BASE_BRANCH}..HEAD -- <path>
   \`\`\`
3. 差分が空または取得できなかった場合は、その旨を review-notes.md の Summary に明記し、
   AC カバレッジ判定は requirements.md と既存コードの突き合わせで行ってください。

## 進め方

Reviewer 役割として、以下を判定して \`${SPEC_DIR_REL}/review-notes.md\` に
書き出してください（reviewer.md の出力契約に従う）。

- 判定カテゴリ: AC 未カバー / missing test / boundary 逸脱 の 3 つに限定
- 最終行は必ず \`RESULT: approve\` または \`RESULT: reject\` で終わること

## 制約
- requirements.md / design.md / tasks.md / 既存実装コード / テストコードを書き換えないこと
- \`git add\` / \`git commit\` / \`git push\` / \`gh\` を実行しないこと（review-notes.md は次の
  Developer または PjM が commit します）
- スタイル / 命名 / lint / フォーマットの観点での reject はしないこと
EOF
}

# Stage C (PjM): 既存 DEV_PROMPT の PjM 起動部分のみを抜き出し。
# Reviewer の approve を受けた後、project-manager 役割が PR を作成する。
# PR 本文の構造は本機能導入前と等価（要件 6.5）。
#
# Issue #96: PjM への PR 作成指示に、解決済み BASE_BRANCH の **実値** を `--base` 引数として
# 明示する肯定的な指示を含める（Req 1.1, 2.1, 2.2）。プレースホルダ `<BASE_BRANCH>` ではなく、
# 当該サイクルで watcher が解決した BASE_BRANCH 値そのもの（`${BASE_BRANCH}` を heredoc で
# 展開済みの文字列）を埋め込む。空値ガード（Req 1.5）は呼び出し元 `_assert_base_branch_resolved`
# で行う。
build_dev_prompt_c() {
  local mode="$1"
  local design_pr_note=""
  if [ "$mode" = "impl-resume" ]; then
    design_pr_note="   - PR 本文に対応する設計 PR 番号を記載（直近の ${BASE_BRANCH} 上の merge commit から \`git log --oneline --merges\` で探す）"
  else
    design_pr_note='   - 設計 PR は走っていないため「関連 PR: なし」と明記すること'
  fi

  cat <<EOF
あなたはこのリポジトリの Codex オーケストレーターです。
Developer の実装と Reviewer の独立レビュー（approve）が完了しました。
`.codex/agents/project-manager.md` の役割指示に従い、Project Manager として最終 PR を作成してください。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}

## 作業ブランチ
${BRANCH}（実装 commit が積まれた状態。push 済み）

## 作業ディレクトリ
${SPEC_DIR_REL}/

## PR の base ブランチ（必ず明示）
解決済み base ブランチ: \`${BASE_BRANCH}\`

Project Manager は \`gh pr create\` 実行時に **必ず \`--base ${BASE_BRANCH}\`** を
明示してください（GitHub のデフォルト base に依存しないこと）。これは本サイクル開始時に
watcher が \`BASE_BRANCH\` env から解決した実値であり、プレースホルダではありません。
PR 作成後は \`gh pr view <PR> --json baseRefName --jq '.baseRefName'\` で取得した値が
\`${BASE_BRANCH}\` と一致することを検証し、結果（一致 / 不一致 / 修正実施の有無）を
PR 本文の「確認事項」または Issue コメントに 1 行記載してください。不一致時は
\`gh pr edit <PR> --base ${BASE_BRANCH}\` で修正するか、修正不能なら PR 作成失敗扱いとして
Issue に状況を報告してください。

## 進め方

1. \`${SPEC_DIR_REL}/review-notes.md\` を **本ブランチに git add / git commit** してから push する
   - commit メッセージ: \`docs(review): add reviewer notes for #${NUMBER}\`
   - 既に commit 済みなら skip
2. `.codex/agents/project-manager.md` の役割指示に従い、**implementation モード**として PR を作成
   - title: \`feat(#${NUMBER}): <1 行サマリ>\`
   - **base: \`${BASE_BRANCH}\`** （\`gh pr create --base ${BASE_BRANCH}\` を明示すること）
   - PR 本文は project-manager.md の「実装 PR 本文テンプレート」に従う
${design_pr_note}
   - PR 本文の「確認事項」セクションに、必要なら review-notes.md の参照リンクを 1 行記載
   - Issue ラベル: codex-picked-up → codex-ready-for-review に付け替え
   - Issue にコメントで実装 PR リンクを投稿

## 制約
- ${BASE_BRANCH} に直接 push しないこと
- **\`gh pr create\` の \`--base\` を省略しないこと**（GitHub default に依存すると本リポジトリの
  \`BASE_BRANCH\` 設定と乖離する事故が起きる。Issue #96）
- Reviewer の approve 判定を覆さないこと（PR 本文に判定結果を逐語転載しない。review-notes.md の
  参照に留める）
- 仕様変更や追加実装はしないこと（PjM はコードを変更しない）
EOF
}

# ─── extract_review_result_token <path> ───
#
# review-notes.md 全文を scan し、`RESULT: approve` または `RESULT: reject` トークンの
# **最後のマッチ**を採用して `approve` / `reject` を stdout に echo する（Issue #63）。
#
# 抽出ルール（Issue #63 Req 1.x）:
#   - 全文 scan（行頭固定マッチではない）
#   - 行頭・行末のバッククォート / bullet (`-` `*`) / blockquote (`>`) / 引用符 / 空白等の
#     decoration を許容（前後の文字を問わない）
#   - 同一行内に末尾プローズが続いても許容（例: `RESULT: approve ...`）
#   - 複数マッチ時は **ファイル順で最後のマッチ** を採用
#   - lowercase の `approve` / `reject` のみ受理（`Approve` / `APPROVE` は不可、Req 1.7）
#   - "approve" / "reject" の前後は word boundary 相当（後続が単語文字なら不採用）
#
# 戻り値:
#   0 = マッチあり（stdout に approve / reject）
#   1 = マッチなし（stdout は空、ファイル無も含む）
extract_review_result_token() {
  local path="$1"
  [ -f "$path" ] || return 1

  # `RESULT:` の後に 1 個以上の空白、続いて `approve` または `reject`、
  # その直後が単語文字でない（または行末）場合のみマッチ。
  # grep -oE で全マッチを行ごとに抽出 → tail -1 で最後の 1 件を採用。
  # set -euo pipefail 下で grep no-match (rc=1) を呑み込むため `|| true` を付与。
  local matches last
  matches=$(grep -oE 'RESULT:[[:space:]]+(approve|reject)([^[:alnum:]_]|$)' "$path" 2>/dev/null || true)
  [ -n "$matches" ] || return 1
  last=$(printf '%s\n' "$matches" | tail -n 1)

  # 末尾の境界文字を取り除いて approve / reject だけを残す。
  case "$last" in
    *approve*) echo "approve"; return 0 ;;
    *reject*)  echo "reject";  return 0 ;;
  esac
  return 1
}

# ─── parse_review_result <path> ───
#
# review-notes.md から RESULT 行（最後に出現するもの）と Findings の Category / Target を
# 抽出する。RESULT 行抽出は `extract_review_result_token` に委譲し、装飾・インライン記述
# (Issue #63) に耐性を持つ。
# stdout に TSV 1 行で出力: <result>\t<categories>\t<target_ids>
#
# - result      ∈ {approve, reject}
# - categories  = カンマ区切り（reject 時のみ。approve 時は空文字）
# - target_ids  = カンマ区切り requirement ID または `boundary:<component>` 形式
#
# 戻り値:
#   0 = 抽出成功
#   2 = ファイル無 / RESULT トークン欠落 / 値不正
parse_review_result() {
  local path="$1"
  if [ ! -f "$path" ]; then
    return 2
  fi

  local result
  if ! result=$(extract_review_result_token "$path"); then
    return 2
  fi
  case "$result" in
    approve|reject) ;;
    *) return 2 ;;
  esac

  local categories=""
  local target_ids=""
  if [ "$result" = "reject" ]; then
    # Findings ブロックの "**Category**: ..." 行と "**Target**: ..." 行を抽出。
    # Findings は markdown bullet なので、行頭の "- " も含めて許容する。
    categories=$(grep -E '^[[:space:]]*-[[:space:]]+\*\*Category\*\*:' "$path" \
                   | sed -E 's/^[[:space:]]*-[[:space:]]+\*\*Category\*\*:[[:space:]]*//' \
                   | sed -E 's/[[:space:]]+$//' \
                   | paste -sd, - || true)
    target_ids=$(grep -E '^[[:space:]]*-[[:space:]]+\*\*Target\*\*:' "$path" \
                   | sed -E 's/^[[:space:]]*-[[:space:]]+\*\*Target\*\*:[[:space:]]*//' \
                   | sed -E 's/（.*$//' \
                   | sed -E 's/[[:space:]]+$//' \
                   | paste -sd, - || true)
  fi

  printf '%s\t%s\t%s\n' "$result" "$categories" "$target_ids"
  return 0
}

# ─── run_reviewer_stage <round> ───
#
# Reviewer 役割を 1 回起動し、review-notes.md の最終 RESULT 行を抽出して
# 戻り値で結果を呼び出し元に返す。
#
# 入力:
#   $1 = round (1 | 2)
#   環境変数: NUMBER, BRANCH, SPEC_DIR_REL, LOG, REPO_DIR
# 副作用:
#   - $LOG に Reviewer 起動ログ（model / max-turns / 結果）を append
#   - $REPO_DIR/$SPEC_DIR_REL/review-notes.md が Reviewer によって作成 / 上書き
# 戻り値:
#   0 = approve
#   1 = reject
#   2 = 異常終了（Codex crash / parse 失敗 / RESULT 行欠落）
run_reviewer_stage() {
  local round="$1"
  local prev_result="(none)"

  # round=2 の場合、直前 review-notes.md の RESULT 行を Reviewer に伝える。
  # Issue #63: 装飾・インライン記述に耐性のある extract_review_result_token に委譲。
  # トークンが見つからない場合は従来どおり "(none)" を維持して prompt 互換性を保つ。
  local notes_path="$REPO_DIR/$SPEC_DIR_REL/review-notes.md"
  if [ "$round" = "2" ] && [ -f "$notes_path" ]; then
    local _prev_token
    if _prev_token=$(extract_review_result_token "$notes_path"); then
      prev_result="RESULT: $_prev_token"
    fi
  fi

  rv_log "round=$round start (model=$REVIEWER_MODEL, max-turns=$REVIEWER_MAX_TURNS)" >> "$LOG"

  local prompt
  prompt=$(build_reviewer_prompt "$round" "$prev_result")

  echo "--- Reviewer 実行 (round=$round) ---" >> "$LOG"
  # Issue #66: Quota-Aware Watcher 経由で Codex を起動。99 を受領した場合は
  # quota 超過検出として呼び出し側（run_impl_pipeline）に伝搬する。
  local _qa_reset_file_rv _qa_rc_rv=0 _qa_ts_rv _qa_stage_label_rv
  _qa_ts_rv=$(date +%Y%m%d-%H%M%S)
  _qa_reset_file_rv="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-reviewer-r${round}-${_qa_ts_rv}"
  _qa_stage_label_rv="Reviewer-r${round}"
  qa_run_codex_stage "$_qa_stage_label_rv" "$_qa_reset_file_rv" -- \
    codex_exec_prompt "$_qa_stage_label_rv" "$REVIEWER_MODEL" "$prompt" \
      >> "$LOG" 2>&1 || _qa_rc_rv=$?
  case "$_qa_rc_rv" in
    0)
      rm -f "$_qa_reset_file_rv"
      ;;
    99)
      local _qa_epoch_rv
      _qa_epoch_rv=$(cat "$_qa_reset_file_rv")
      qa_handle_quota_exceeded "$NUMBER" "$_qa_stage_label_rv" "$_qa_epoch_rv"
      rm -f "$_qa_reset_file_rv"
      rv_log "round=$round result=quota-exceeded → codex-needs-quota-wait" >> "$LOG"
      return 99
      ;;
    *)
      rm -f "$_qa_reset_file_rv"
      rv_log "round=$round result=error reason=codex-exit-nonzero" >> "$LOG"
      return 2
      ;;
  esac

  # review-notes.md を parse
  local parsed
  if ! parsed=$(parse_review_result "$notes_path"); then
    rv_log "round=$round result=error reason=parse-failed" >> "$LOG"
    return 2
  fi

  local result categories targets
  result=$(echo "$parsed" | cut -f1)
  categories=$(echo "$parsed" | cut -f2)
  targets=$(echo "$parsed" | cut -f3)

  case "$result" in
    approve)
      rv_log "round=$round result=approve verified=$targets" >> "$LOG"
      return 0
      ;;
    reject)
      rv_log "round=$round result=reject categories=$categories targets=$targets" >> "$LOG"
      return 1
      ;;
    *)
      rv_log "round=$round result=error reason=unknown-result" >> "$LOG"
      return 2
      ;;
  esac
}

# ─── Stage 完了直後の push 状態 verify ヘルパー (Issue #106) ───
#
# Stage A / A' / B 完了直後に「ローカル commit が origin に到達しているか」を verify し、
# 未 push を検出したら自動 push を 1 回だけリトライする。リトライ成功時は WARN ログ +
# Issue コメントで観測可能性を維持し、リトライ失敗時は mark_issue_failed 経路で
# codex-failed 化する。
#
# 引数:
#   $1 = stage 識別子（mark_issue_failed に渡す identifier。例: stageA-push-missing
#        / stageA-prime-push-missing / stageB-push-missing。NFR 2.1 / Req 4.4 と整合）
#   $2 = 対象 branch（典型的には $BRANCH）
#   $3 = stage label（ログ可読性のための短い文字列。例: "Stage A" / "Stage A'" / "Stage B"）
#
# 戻り値:
#   0 = ahead == 0（通常成功 / Req 1.3, 2.3, 5.1）、または自動 push リトライ成功
#       （Req 4.2, 4.3）
#   1 = 自動 push リトライ失敗 → mark_issue_failed 既発射、呼び出し側は伝搬 return 1 する
#       （Req 4.4, 4.5）
#
# 副作用:
#   - $LOG に検出経路 / ahead 数 / リトライ結果を WARN 行で記録（NFR 2.1, Req 1.2, 2.2, 3.2）
#   - リトライ成功時に gh issue comment で復旧通知を投稿（Req 4.3, NFR 2.2）
#   - リトライ失敗時に mark_issue_failed "$stage_id" で codex-failed 化（Req 4.4, NFR 2.3）
#
# 設計判断:
#   - `git rev-list --count @{u}..HEAD` で ahead 数を測る。本関数は cwd が slot worktree
#     ($REPO_DIR が指す path) であることを前提とする（_slot_run_issue が cd 済）。
#   - timeout は 30 秒上限（NFR 1.2）。本体 git クエリと push リトライそれぞれに timeout を
#     かける。`command -v timeout` で GNU coreutils の有無を判定し、無い環境
#     （BSD / macOS 標準）では timeout なしで実行する（既存 cron 互換性のため）。
#   - 結果不確定（git rev-list が timeout / 失敗）は「未 push と同等扱い」で安全側に倒す
#     （Req 1.4）。リトライを試み、失敗なら codex-failed 化する。
#   - push オプションは plain `git push origin <branch>` の fast-forward のみ。
#     `--force-with-lease` 等の force 系は **使わない**（既稼働 cron 環境で意図せぬ
#     history 書き換えを防止するため。Open Question 3 の design 確定）。
#   - Stage B の review-notes.md 識別ログ粒度（Req 3.4）は呼び出し側で stage label を
#     "Stage B" と明示し、本関数のログ行に stage label を含めることで観測可能性を担保。
verify_pushed_or_retry() {
  local stage_id="$1"
  local branch="$2"
  local stage_label="$3"

  # ── ahead 数を測定（安全側ロジック付き）──
  # 結果が空 / 取得失敗時は ahead=unknown とし、安全側で push リトライへ進む（Req 1.4）。
  local ahead_count="" rev_rc=0
  local _git_has_timeout=false
  if command -v timeout >/dev/null 2>&1; then
    _git_has_timeout=true
  fi
  if [ "$_git_has_timeout" = "true" ]; then
    ahead_count=$(timeout 30 git rev-list --count "@{u}..HEAD" 2>/dev/null) || rev_rc=$?
  else
    ahead_count=$(git rev-list --count "@{u}..HEAD" 2>/dev/null) || rev_rc=$?
  fi
  # 数値以外（空文字 / エラー）は unknown 扱い
  if ! [[ "$ahead_count" =~ ^[0-9]+$ ]]; then
    ahead_count="unknown"
  fi

  # ── 通常成功ケース: ahead == 0（Req 1.3 / 2.3 / 3.3 / 5.1）──
  if [ "$ahead_count" = "0" ]; then
    return 0
  fi

  # ── ahead > 0 または unknown: WARN ログ → 自動 push リトライ 1 回（Req 4.1, 4.6）──
  qa_warn "${stage_label} push-state verify: ahead=${ahead_count} (rev_rc=${rev_rc}) issue=#${NUMBER:-?} branch=${branch} stage_id=${stage_id}"
  echo "[$(date '+%F %T')] ${stage_label} ahead=${ahead_count} detected → auto-push retry 1/1 (Req 4.1, Issue #106)" >> "$LOG"

  local push_rc=0
  local push_stderr_tmp
  push_stderr_tmp=$(mktemp -t verify-push-XXXXXX.err 2>/dev/null || echo "")
  if [ -n "$push_stderr_tmp" ]; then
    if [ "$_git_has_timeout" = "true" ]; then
      timeout 30 git push origin "$branch" 2>"$push_stderr_tmp" || push_rc=$?
    else
      git push origin "$branch" 2>"$push_stderr_tmp" || push_rc=$?
    fi
  else
    if [ "$_git_has_timeout" = "true" ]; then
      timeout 30 git push origin "$branch" || push_rc=$?
    else
      git push origin "$branch" || push_rc=$?
    fi
  fi

  if [ "$push_rc" -eq 0 ]; then
    # ── リトライ成功（Req 4.2, 4.3）──
    qa_warn "${stage_label} auto-push retry SUCCESS: ahead=${ahead_count} issue=#${NUMBER:-?} branch=${branch} stage_id=${stage_id}"
    echo "[$(date '+%F %T')] ${stage_label} 自動 push リトライ成功 ahead=${ahead_count} → 継続" >> "$LOG"

    # Issue コメント投稿（NFR 2.2: Issue 番号 / stage 識別子 / branch / commit 数を含める）
    local comment_body
    comment_body="⚠️ Issue #${NUMBER:-?} の ${stage_label} 完了直後に未 push commit を検出し、自動 push リトライで復旧しました。

- 対象 stage : \`${stage_id}\`
- 対象 branch: \`${branch}\`
- 復旧 commit 数: ${ahead_count}

Codex の Developer / Reviewer 役割での push 漏れ等が根本原因の可能性があります。詳細は watcher ログ \`${LOG}\` を確認してください。"
    gh issue comment "${NUMBER}" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1 || true

    if [ -n "$push_stderr_tmp" ]; then rm -f "$push_stderr_tmp" 2>/dev/null || true; fi
    return 0
  fi

  # ── リトライ失敗（Req 4.4, 4.5, NFR 2.3）──
  local push_stderr_tail=""
  if [ -n "$push_stderr_tmp" ] && [ -f "$push_stderr_tmp" ]; then
    push_stderr_tail=$(tail -c 1500 "$push_stderr_tmp" 2>/dev/null || true)
  fi
  qa_warn "${stage_label} auto-push retry FAILED: ahead=${ahead_count} push_rc=${push_rc} issue=#${NUMBER:-?} branch=${branch} stage_id=${stage_id} stderr_tail='${push_stderr_tail//$'\n'/ }'"
  echo "[$(date '+%F %T')] ${stage_label} 自動 push リトライ失敗 push_rc=${push_rc} → codex-failed (stage_id=${stage_id})" >> "$LOG"

  local fail_body
  fail_body="${stage_label} 完了直後に未 push commit（ahead=${ahead_count}）を検出し、自動 push リトライを 1 回試みましたが失敗しました（push exit code: ${push_rc}）。

- 対象 stage : \`${stage_id}\`
- 対象 branch: \`${branch}\`
- 未 push commit 数: ${ahead_count}

### 次の手順

1. ローカルで \`git fetch origin\` 後、当該 worktree の HEAD と origin/${branch} の差分を確認
2. 必要に応じ手動で \`git push origin ${branch}\` を実行
3. 問題が解消したら \`codex-failed\` ラベルを外して再 pickup させる"
  if [ -n "$push_stderr_tail" ]; then
    fail_body="${fail_body}

### git push stderr (tail)

\`\`\`
${push_stderr_tail}
\`\`\`"
  fi

  if [ -n "$push_stderr_tmp" ]; then rm -f "$push_stderr_tmp" 2>/dev/null || true; fi

  mark_issue_failed "$stage_id" "$fail_body"
  return 1
}

# ─── Stage C 完了直後の PR 実在 verify ヘルパー (Issue #108) ───
#
# Stage C の Codex 実行が return code 0 で終了した直後に、対象 branch を head と
# する impl PR が GitHub 側で参照可能か `gh pr view --head` で verify する。GitHub の
# eventual consistency により PR 作成直後数十秒は当該クエリが空応答を返すケースが
# 観測されているため、最大 4 回までリトライ可能とし、整合性遅延に起因する
# false negative を吸収する。
#
# 引数:
#   $1 = 対象 branch（典型的には $BRANCH）
#   $2 = Issue 番号（ログ識別用。典型的には $NUMBER）
#
# 戻り値:
#   0 = いずれかの試行で PR URL が取得できた（PR URL を stdout に出力）
#   1 = 4 回すべて空応答 / 非 0 / タイムアウトで PR URL を取得できなかった
#
# 副作用:
#   - 各試行の結果（成功 / 空応答 / 非 0 / タイムアウト）を `$LOG` に記録（NFR 2.1）
#   - 1 回目即時成功時は追加ログを出さない（Req 4.1 / NFR 1.1: 通常成功ケースの
#     外形挙動を本変更前と同一に保つ）
#
# 設計判断:
#   - 試行回数 4 / 待機 (0, 5, 10, 20) 秒 / 1 試行 timeout 15 秒（Req 1.4 / 1.5 / 1.6 /
#     NFR 1.2 / 1.3）。リトライ系列全体で最大 35 + 15*4 = 95 秒となるが、典型
#     ケースでは timeout 上限に到達せず数秒〜十数秒で完了する。Req 1.4 で合計
#     待機時間を 35 秒以内に収める制約は「待機（sleep）の合計」を指し、個々の
#     試行の RTT は別枠とする（Issue #108 本文の整理に準拠）。
#   - 待機は `${STAGEC_VERIFY_SLEEP_CMD:-sleep}` 経由で実行する。テストで `:` 等の
#     no-op コマンドを注入することで実時間待機なしに retry 系列を再現できる
#     （Req 5.6）。env var 名は内部 fixture 用で、本番運用での override は想定しない
#     （AGENTS.md の env var 後方互換性方針には抵触しない / Req 4.2）。
#   - `command -v timeout` で timeout コマンドの存在を確認し、無い環境では timeout
#     なしで gh を実行する（既存 verify_pushed_or_retry と同方針 / 既存 cron
#     互換性のため）。
#   - 成功時の "Stage C 完了 / PR 作成済み" 相当ログは呼び出し側に残し、本関数は
#     PR URL の取得と試行ログのみに責務を絞る。これにより Req 4.1 の「1 回目で
#     PR が確認できたとき本変更前と同じ成功ログ」を呼び出し側 echo で保証する。
verify_stagec_pr_or_retry() {
  local branch="$1"
  local issue_number="$2"

  # 試行間 sleep の注入点（テスト時に `:` 等で no-op 化できる / Req 5.6）
  local _sleep_cmd="${STAGEC_VERIFY_SLEEP_CMD:-sleep}"

  # timeout コマンドの有無で gh 呼び出しを切り替える（既存 verify_pushed_or_retry と同方針）
  local _gh_has_timeout=false
  if command -v timeout >/dev/null 2>&1; then
    _gh_has_timeout=true
  fi

  # 待機スケジュール（即時 / 5 秒 / 10 秒 / 20 秒。合計 35 秒 / Req 1.4）
  local _delays=(0 5 10 20)
  local _max_attempts=4

  local attempt=1
  local pr_url="" rc=0
  while [ "$attempt" -le "$_max_attempts" ]; do
    local _delay="${_delays[$((attempt - 1))]}"
    if [ "$_delay" -gt 0 ]; then
      "$_sleep_cmd" "$_delay"
    fi

    pr_url=""
    rc=0
    if [ "$_gh_has_timeout" = "true" ]; then
      pr_url=$(timeout 15 gh pr view --repo "$REPO" --head "$branch" \
                --json url --jq '.url' 2>/dev/null) || rc=$?
    else
      pr_url=$(gh pr view --repo "$REPO" --head "$branch" \
                --json url --jq '.url' 2>/dev/null) || rc=$?
    fi

    if [ "$rc" -eq 0 ] && [ -n "$pr_url" ]; then
      # 1 回目以降の試行回数判定: N >= 2 の場合のみ「リトライで成功」ログを残す
      # （Req 3.2 / Req 4.1 NFR 1.1 を満たすため 1 回目は無 log で本変更前と外形互換）
      if [ "$attempt" -gt 1 ]; then
        echo "[$(date '+%F %T')] stageC PR verify SUCCESS attempt=${attempt}/${_max_attempts} issue=#${issue_number} branch=${branch} pr_url=${pr_url}" >> "$LOG"
      fi
      printf '%s\n' "$pr_url"
      return 0
    fi

    # 失敗種別を分類してログに残す（NFR 2.1: 試行結果を事後識別可能にする）
    local outcome=""
    if [ "$rc" -eq 124 ]; then
      outcome="timeout"
    elif [ "$rc" -ne 0 ]; then
      outcome="exit=${rc}"
    else
      outcome="empty"
    fi
    # 2 回目以降の試行については Req 3.1 で進捗を 1 行で残すことを要求。
    # 1 回目の失敗も Req 3.3「全リトライ失敗で codex-failed 化」の事後原因特定の
    # ため記録しておく（最終失敗時にまとめて参照できるよう attempt=1 から残す）。
    echo "[$(date '+%F %T')] stageC PR verify attempt=${attempt}/${_max_attempts} outcome=${outcome} issue=#${issue_number} branch=${branch}" >> "$LOG"

    attempt=$((attempt + 1))
  done

  # 全試行失敗（Req 2.1 / 3.3）— 呼び出し側で mark_issue_failed する
  echo "[$(date '+%F %T')] stageC PR verify FAILED after ${_max_attempts} attempts issue=#${issue_number} branch=${branch} last_rc=${rc} last_pr_url='${pr_url:-(empty)}'" >> "$LOG"
  return 1
}

# ─── failure 共通遷移ヘルパー ───
#
# Stage 失敗時の codex-failed 遷移を一元化。引数で原因種別と Issue コメント追加情報を受け取る。
# - $1 = stage 識別子（"stageA" / "stageA-redo" / "stageB" / "stageC" / "reviewer-error" / "reviewer-reject2"）
# - $2 = Issue コメントに追加する補足（reject 理由など。空文字可）
mark_issue_failed() {
  local stage="$1"
  local extra_body="$2"

  # Issue #52: 通常経路では Stage A 開始時点で Issue は codex-picked-up のみ持つ
  # （Slot Runner が Triage 通過時に codex-claimed → codex-picked-up に付け替え済）。
  # 想定外シーケンス（design ルート Stage C 失敗で本ヘルパへ流入する等）でも残置を防ぐ
  # ため、両系統除去で安全側に倒す。gh CLI は未付与ラベルの除去を no-op として扱う。
  gh issue edit "$NUMBER" --repo "$REPO" \
    --remove-label "$LABEL_CLAIMED" --remove-label "$LABEL_PICKED" --add-label "$LABEL_FAILED" || true

  local hostname_val
  hostname_val=$(hostname)
  local body="⚠️ 自動開発が失敗しました（${hostname_val} / モード: $MODE / 失敗 stage: ${stage}）。

ログ: \`$LOG\`"
  if [ -n "$extra_body" ]; then
    body="${body}

${extra_body}"
  fi
  body="${body}

問題を解決してから \`codex-failed\` ラベルを外してください。"

  # Issue #65 Req 3.1/3.2/3.3/3.4: 手動復旧手順を末尾に append。
  # mark_issue_failed は run_impl_pipeline 内の各 stage 失敗から呼ばれ、PR の有無が
  # 文脈で確定しないため pr_present="unknown" を渡す（両ケース併記）。
  body="${body}
$(build_recovery_hint "unknown")"

  gh issue comment "$NUMBER" --repo "$REPO" --body "$body" || true
}

# ─── run_impl_pipeline ───
#
# impl / impl-resume モードの Stage 状態機械を実装する。
#
#   START → Stage A → Stage B(round=1)
#                    ├─ approve → Stage C → TERMINAL_OK
#                    ├─ reject  → Stage A' → Stage B(round=2)
#                    │                       ├─ approve → Stage C → TERMINAL_OK
#                    │                       ├─ reject  → TERMINAL_FAILED (with Issue comment)
#                    │                       └─ error   → TERMINAL_FAILED (with $LOG path)
#                    └─ error   → TERMINAL_FAILED (with $LOG path)
#
#   Stage A / A' / C の非 0 exit は既存 Developer 失敗時遷移と同等メッセージ。
#
# Stage Checkpoint Resume (#68, opt-in): `STAGE_CHECKPOINT_ENABLED=true` のときのみ、
#   関数冒頭で stage_checkpoint_resolve_resume_point を呼び START_STAGE を取得する。
#   START_STAGE ∈ {A, B, C, TERMINAL_OK, TERMINAL_FAILED}。
#     - TERMINAL_OK     → 既存 impl PR 検出。何もせず return 0（自動進行停止、ラベル不変）
#     - TERMINAL_FAILED → round=2 reject 残骸検出。codex-failed 化して return 1
#     - A               → 通常通り Stage A から実行（fallback / no-checkpoint / INCONSISTENT）
#     - B               → Stage A をスキップ（既存 impl-notes.md を再利用）
#     - C               → Stage A / Stage B をスキップ（既存 impl-notes / approve を再利用）
#   既定の `STAGE_CHECKPOINT_ENABLED=false` では resolve は呼ばず、本関数は導入前と
#   1 行も挙動を変えない（NFR 1.1）。
#
# 入力 (環境変数経由): NUMBER, TITLE, BODY, URL, BRANCH, MODE, SPEC_DIR_REL, LOG, REPO,
#                      DEV_MODEL, DEV_MAX_TURNS, REVIEWER_MODEL, REVIEWER_MAX_TURNS,
#                      STAGE_CHECKPOINT_ENABLED (#68 opt-in, default=false)
# 戻り値:
#   0 = pipeline 成功（Stage C も成功 / PR 作成済み）または TERMINAL_OK 相当の停止
#   1 = Stage A / A' / B / B' / C いずれかで失敗 → codex-failed 既に付与済み
run_impl_pipeline() {
  local prompt_a prompt_redo prompt_c
  local rev_rc
  # START_STAGE: opt-in 時は resolve_resume_point が値を上書きする。
  # opt-out（既定）では "A" 固定で従来挙動と完全一致（Req 3.2 / NFR 1.1）。
  local START_STAGE="A"

  # Stage Checkpoint Resume (#68 opt-in): START_STAGE を resolve_resume_point で
  # 上書き。既定 OFF では本ブロックは skip され START_STAGE="A" のままで、
  # 本機能導入前と完全等価な挙動になる（NFR 1.1）。
  if [ "${STAGE_CHECKPOINT_ENABLED:-false}" = "true" ]; then
    if ! stage_checkpoint_resolve_resume_point; then
      sc_warn "resolve 異常 → Stage A 起点で安全フォールバック" >> "$LOG"
      START_STAGE="A"
    fi
    case "$START_STAGE" in
      TERMINAL_OK)
        sc_log "既存 impl PR 検出 → Stage C 再実行を停止 (Req 2.6)" >> "$LOG"
        echo "✅ #$NUMBER: 既存 impl PR を検出（Stage Checkpoint）→ 自動進行を停止" | tee -a "$LOG"
        return 0
        ;;
      TERMINAL_FAILED)
        sc_log "round=2 reject 残骸検出 → codex-failed 化 (Req 2.5)" >> "$LOG"
        echo "❌ #$NUMBER: Reviewer round=2 reject の checkpoint 残骸検出 → codex-failed" | tee -a "$LOG"
        mark_issue_failed "stage-checkpoint-terminal-failed" \
          "Reviewer round=2 reject の checkpoint が当該 branch に残っているため、自動進行を停止します。\`${SPEC_DIR_REL}/review-notes.md\` の RESULT 行を確認し、人間判断で対応してください。"
        return 1
        ;;
    esac
  fi

  # ── Stage A: PM + Developer（impl-resume では PM スキップ / Stage Checkpoint resume 時は skip 可）──
  case "$START_STAGE" in
    A)
      echo "--- Stage A 実行（$MODE / PM + Developer）---" >> "$LOG"
      prompt_a=$(build_dev_prompt_a "$MODE")
      # Issue #66: Quota-Aware Watcher 経由で Codex を起動（Req 1.1, 1.2, 2.1）
      local _qa_reset_file_a _qa_rc_a=0 _qa_ts_a
      _qa_ts_a=$(date +%Y%m%d-%H%M%S)
      _qa_reset_file_a="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-stageA-${_qa_ts_a}"
      qa_run_codex_stage "StageA" "$_qa_reset_file_a" -- \
        codex_exec_prompt "StageA" "$DEV_MODEL" "$prompt_a" \
          >> "$LOG" 2>&1 || _qa_rc_a=$?
      case "$_qa_rc_a" in
        0)
          # Issue #106 Req 1: Stage A 成功宣言の前にローカル HEAD が origin に到達しているか
          # verify する。ahead == 0 なら従来どおり成功メッセージ（Req 1.3 / 5.1）、
          # ahead > 0 なら自動 push リトライ 1 回。リトライ失敗時は codex-failed 化済で
          # return 1 を伝搬する（Req 1.4, 4.4, 4.5）。
          rm -f "$_qa_reset_file_a"
          if ! verify_pushed_or_retry "stageA-push-missing" "$BRANCH" "Stage A"; then
            return 1
          fi
          echo "✅ #$NUMBER: Stage A 完了" | tee -a "$LOG"
          ;;
        99)
          local _qa_epoch_a
          _qa_epoch_a=$(cat "$_qa_reset_file_a")
          qa_handle_quota_exceeded "$NUMBER" "StageA" "$_qa_epoch_a"
          rm -f "$_qa_reset_file_a"
          echo "⏸️ #$NUMBER: Stage A で quota 超過検出 → codex-needs-quota-wait" | tee -a "$LOG"
          return 0
          ;;
        *)
          rm -f "$_qa_reset_file_a"
          echo "❌ #$NUMBER: Stage A 失敗" | tee -a "$LOG"
          mark_issue_failed "stageA" ""
          return 1
          ;;
      esac
      ;;
    B|C)
      sc_log "Stage A をスキップ（START_STAGE=$START_STAGE / 既存 impl-notes.md を再利用）" >> "$LOG"
      echo "⏭️  #$NUMBER: Stage A スキップ（Stage Checkpoint resume）" | tee -a "$LOG"
      ;;
  esac

  # ── Stage B (round=1): Reviewer / Stage A' / Stage B(round=2) ──
  case "$START_STAGE" in
    A|B)
      rev_rc=0
      run_reviewer_stage 1 || rev_rc=$?
      case $rev_rc in
        0)
          # Issue #106 Req 3: Stage B (Reviewer round=1 approve) 完了直後に push 状態 verify。
          # review-notes.md が Reviewer によって commit されているが未 push のケースを検出する
          # （Req 3.4 review-notes.md 識別ログ粒度は stage label "Stage B (round=1 approve)" で表現）。
          if ! verify_pushed_or_retry "stageB-push-missing" "$BRANCH" "Stage B (round=1 approve)"; then
            return 1
          fi
          echo "✅ #$NUMBER: Reviewer round=1 approve" | tee -a "$LOG"
          ;;
        99)
          # Issue #66: Reviewer round=1 で quota 超過検出。run_reviewer_stage 内で
          # qa_handle_quota_exceeded 済 / codex-needs-quota-wait に遷移済 → 正常終了で抜ける。
          echo "⏸️ #$NUMBER: Reviewer round=1 で quota 超過検出 → codex-needs-quota-wait" | tee -a "$LOG"
          return 0
          ;;
        1)
          # Issue #106 Req 3: Stage B (Reviewer round=1 reject) 完了直後にも push 状態 verify。
          # 「reject だが review-notes.md 未 push」状態で Stage A' を起動すると Stage A' 側の
          # build_dev_prompt_redo が origin の古い review-notes.md を参照する事故を防ぐ。
          if ! verify_pushed_or_retry "stageB-push-missing" "$BRANCH" "Stage B (round=1 reject)"; then
            return 1
          fi
          echo "🔁 #$NUMBER: Reviewer round=1 reject → Developer 再実行" | tee -a "$LOG"
          rv_dev_log "redo by reviewer reject (round=1)" >> "$LOG"

          # ── Stage A' (Developer 再実行) ──
          echo "--- Stage A' 実行（Developer 再実行 / Reviewer reject 差し戻し）---" >> "$LOG"
          prompt_redo=$(build_dev_prompt_redo "$REPO_DIR/$SPEC_DIR_REL/review-notes.md")
          # Issue #66: Quota-Aware Watcher 経由で Codex を起動
          local _qa_reset_file_aredo _qa_rc_aredo=0 _qa_ts_aredo
          _qa_ts_aredo=$(date +%Y%m%d-%H%M%S)
          _qa_reset_file_aredo="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-stageA-redo-${_qa_ts_aredo}"
          qa_run_codex_stage "StageA-redo" "$_qa_reset_file_aredo" -- \
            codex_exec_prompt "StageA-redo" "$DEV_MODEL" "$prompt_redo" \
              >> "$LOG" 2>&1 || _qa_rc_aredo=$?
          case "$_qa_rc_aredo" in
            0)
              # Issue #106 Req 2: Stage A' 成功宣言の前にローカル HEAD が origin に到達して
              # いるか verify する（Req 2.1〜2.3, 4.1〜4.5）。
              rm -f "$_qa_reset_file_aredo"
              if ! verify_pushed_or_retry "stageA-prime-push-missing" "$BRANCH" "Stage A'"; then
                return 1
              fi
              echo "✅ #$NUMBER: Stage A' 完了" | tee -a "$LOG"
              ;;
            99)
              local _qa_epoch_aredo
              _qa_epoch_aredo=$(cat "$_qa_reset_file_aredo")
              qa_handle_quota_exceeded "$NUMBER" "StageA-redo" "$_qa_epoch_aredo"
              rm -f "$_qa_reset_file_aredo"
              echo "⏸️ #$NUMBER: Stage A' で quota 超過検出 → codex-needs-quota-wait" | tee -a "$LOG"
              return 0
              ;;
            *)
              rm -f "$_qa_reset_file_aredo"
              echo "❌ #$NUMBER: Stage A' (Developer 再実行) 失敗" | tee -a "$LOG"
              mark_issue_failed "stageA-redo" ""
              return 1
              ;;
          esac

          # ── Stage B (round=2): Reviewer 最終回 ──
          rev_rc=0
          run_reviewer_stage 2 || rev_rc=$?
          case $rev_rc in
            0)
              # Issue #106 Req 3: Stage B (Reviewer round=2 approve) 完了直後の push 状態 verify。
              if ! verify_pushed_or_retry "stageB-push-missing" "$BRANCH" "Stage B (round=2 approve)"; then
                return 1
              fi
              echo "✅ #$NUMBER: Reviewer round=2 approve" | tee -a "$LOG"
              ;;
            99)
              # Issue #66: Reviewer round=2 で quota 超過検出。run_reviewer_stage 内で
              # qa_handle_quota_exceeded 済 / codex-needs-quota-wait に遷移済 → 正常終了で抜ける。
              echo "⏸️ #$NUMBER: Reviewer round=2 で quota 超過検出 → codex-needs-quota-wait" | tee -a "$LOG"
              return 0
              ;;
            1)
              # Issue #106 Req 3.1: Stage B 完了は reject / approve いずれも verify 対象。
              # 本ケース（round=2 reject）はいずれにせよ reviewer-reject2 で codex-failed に
              # 確定するため、verify 自体は best-effort で実行し失敗してもより情報量の多い
              # reviewer-reject2 経路を優先する。ahead > 0 検出時の WARN ログ / 自動 push 復旧
              # コメントは verify_pushed_or_retry 内で出力済（観測可能性は維持）。
              verify_pushed_or_retry "stageB-push-missing" "$BRANCH" "Stage B (round=2 reject)" || true
              # 2 回目 reject → codex-failed + Issue コメントに reject 理由 / 対象 ID を含める
              echo "❌ #$NUMBER: Reviewer round=2 reject → codex-failed" | tee -a "$LOG"
              local parsed2 cat2 tgt2
              parsed2=$(parse_review_result "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" 2>/dev/null || echo "")
              cat2=$(echo "$parsed2" | cut -f2)
              tgt2=$(echo "$parsed2" | cut -f3)
              local reject_body
              reject_body="Reviewer が 2 回連続で reject を出したため、自動 iteration を打ち切り、人間判断に委ねます。

- 対象 requirement ID: ${tgt2:-(unknown)}
- reject カテゴリ: ${cat2:-(unknown)}
- Reviewer 判定詳細: \`${SPEC_DIR_REL}/review-notes.md\` を参照

### 次の手順
1. review-notes.md と watcher ログを読み、Reviewer 判定が妥当か確認
2. 妥当なら手動で修正 commit を積み、\`codex-failed\` を外す
3. Reviewer 判定が誤りなら、Issue コメントで Architect 差し戻しを提案"
              mark_issue_failed "reviewer-reject2" "$reject_body"
              return 1
              ;;
            *)
              # round=2 reviewer error
              echo "❌ #$NUMBER: Reviewer round=2 異常終了 → codex-failed" | tee -a "$LOG"
              mark_issue_failed "reviewer-error" "Reviewer round=2 が異常終了しました（Codex crash / parse 失敗）。\`$LOG\` を確認してください。"
              return 1
              ;;
          esac
          ;;
        *)
          # round=1 reviewer error → codex-failed + Issue コメント (要件 4.8)
          echo "❌ #$NUMBER: Reviewer round=1 異常終了 → codex-failed" | tee -a "$LOG"
          mark_issue_failed "reviewer-error" "Reviewer round=1 が異常終了しました（Codex crash / parse 失敗）。\`$LOG\` を確認してください。"
          return 1
          ;;
      esac
      ;;
    C)
      sc_log "Stage B をスキップ（START_STAGE=C / 既存 review-notes.md approve を再利用）" >> "$LOG"
      echo "⏭️  #$NUMBER: Stage B スキップ（Stage Checkpoint resume）" | tee -a "$LOG"
      ;;
  esac

  # ── Stage C: PjM (PR 作成) ──
  echo "--- Stage C 実行（PjM / PR 作成）---" >> "$LOG"
  # Issue #96 Req 1.5: PR 作成段階に進む前に BASE_BRANCH 実値が空でないことを検証する
  if ! _assert_base_branch_resolved; then
    echo "❌ #$NUMBER: Stage C 中断（BASE_BRANCH 未解決）→ codex-failed" | tee -a "$LOG"
    mark_issue_failed "stageC-base-branch" "解決済み BASE_BRANCH が空文字または未定義のため Stage C を中断しました（Issue #96 Req 1.5）。"
    return 1
  fi
  prompt_c=$(build_dev_prompt_c "$MODE")
  # Issue #66: Quota-Aware Watcher 経由で Codex を起動
  local _qa_reset_file_c _qa_rc_c=0 _qa_ts_c
  _qa_ts_c=$(date +%Y%m%d-%H%M%S)
  _qa_reset_file_c="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-stageC-${_qa_ts_c}"
  qa_run_codex_stage "StageC" "$_qa_reset_file_c" -- \
    codex_exec_prompt "StageC" "$DEV_MODEL" "$prompt_c" \
      >> "$LOG" 2>&1 || _qa_rc_c=$?
  case "$_qa_rc_c" in
    0)
      # Issue #104 Bug 3 / Req 4.1〜4.4: Codex RC=0 + quota 検出なし時点では
      # 「PR が実際に作成されたか」が未確認。PjM 役割が 1 turn で
      # 空転終了しても Codex RC=0 を返すため、PR 実在を gh で verify する。
      # Issue #108: GitHub の eventual consistency による false negative を吸収する
      # ため、verify_stagec_pr_or_retry で最大 4 回までリトライする。1 回目で成功
      # する通常ケースの外形挙動は本変更前と同一（Req 4.1 / NFR 1.1）。
      rm -f "$_qa_reset_file_c"
      local _stagec_pr_url _stagec_verify_rc=0
      _stagec_pr_url=$(verify_stagec_pr_or_retry "$BRANCH" "$NUMBER") || _stagec_verify_rc=$?
      if [ "$_stagec_verify_rc" -eq 0 ] && [ -n "$_stagec_pr_url" ]; then
        # Req 4.3 / Issue #108 Req 3.4: PR 実在確認できた場合は従来どおり成功ログ
        echo "✅ #$NUMBER: Stage C 完了 / PR 作成済み (${_stagec_pr_url})" | tee -a "$LOG"
        return 0
      fi
      # Req 4.2 / 4.4 / Issue #108 Req 2.1: 4 回リトライしても PR 不在の場合は
      # 安全側に倒し codex-failed 化（NFR 2.2: 人間が原因を特定できる粒度のログを残す）
      echo "❌ #$NUMBER: Stage C 完了報告だが対応 PR 不在 → codex-failed (branch=$BRANCH verify_rc=$_stagec_verify_rc, 4 回リトライ後)" | tee -a "$LOG"
      qa_warn "stageC PR verify failed after retry issue=#$NUMBER branch=$BRANCH verify_rc=$_stagec_verify_rc pr_url='${_stagec_pr_url:-(empty)}'"
      mark_issue_failed "stageC-pr-missing" "Stage C の Codex 実行は return code 0 で終了しましたが、対応する impl PR が GitHub 側に検出できませんでした（branch=\`$BRANCH\`、4 回リトライ後）。PjM 役割が 1 turn で空転終了した可能性 / GitHub API 一時障害の可能性のいずれかです。\`$LOG\` を確認してください。"
      return 1
      ;;
    99)
      local _qa_epoch_c
      _qa_epoch_c=$(cat "$_qa_reset_file_c")
      qa_handle_quota_exceeded "$NUMBER" "StageC" "$_qa_epoch_c"
      rm -f "$_qa_reset_file_c"
      echo "⏸️ #$NUMBER: Stage C で quota 超過検出 → codex-needs-quota-wait" | tee -a "$LOG"
      return 0
      ;;
    *)
      rm -f "$_qa_reset_file_c"
      echo "❌ #$NUMBER: Stage C (PjM) 失敗" | tee -a "$LOG"
      mark_issue_failed "stageC" ""
      return 1
      ;;
  esac
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase C: Issue 入口並列化 (worktree slot + dispatcher, #16)
#
# codex-auto-dev Issue 処理ループを Dispatcher / Slot Worker パターンに置き換え、
# 複数 Issue を時間的に重ねて処理できるようにする。
#
# 構成:
#   - _parallel_validate_slots : PARALLEL_SLOTS 検証
#   - Worktree Manager  : per-slot 永続 worktree の初期化・最新化
#   - Slot Lock Manager : per-slot 非ブロッキング flock の取得・解放
#   - Hook Layer        : SLOT_INIT_HOOK の絶対パス起動（eval 不使用）
#   - Slot Runner       : 1 Issue を 1 worktree で処理する Worker
#   - Dispatcher        : Issue 候補取得 → claim → slot 投入 → 全 Worker wait
#
# PARALLEL_SLOTS=1（デフォルト）のとき、slot-2 以降の lock / worktree を作成せず、
# 本機能導入前と外形的に同一挙動になるよう実装する。
#
# 詳細: docs/specs/16-phase-c-worktree-slot-dispatcher/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ─── Phase C: Logger ───
# Dispatcher / Slot Worker / Worktree / Hook 共通の timestamp 形式（既存 mq_log 等と同じ）
dispatcher_log() {
  echo "[$(date '+%F %T')] dispatcher: $*"
}
dispatcher_warn() {
  echo "[$(date '+%F %T')] dispatcher: WARN: $*" >&2
}
dispatcher_error() {
  echo "[$(date '+%F %T')] dispatcher: ERROR: $*" >&2
}

# ─── Pre-Claim Probe Logger (Issue #65) ───
# claim 直前に linked impl PR を検出する Pre-Claim Filter 用 logger。
# 既存 mq_log / pi_log / drr_log / qa_log / sc_log / dispatcher_log と同じ
# `[$(date '+%F %T')] <prefix>: ...` 形式に揃え、識別 prefix `pre-claim-probe:`
# で grep 集計できるようにする（Req NFR 2.1）。
pclp_log() {
  echo "[$(date '+%F %T')] pre-claim-probe: $*"
}
pclp_warn() {
  echo "[$(date '+%F %T')] pre-claim-probe: WARN: $*" >&2
}
pclp_error() {
  echo "[$(date '+%F %T')] pre-claim-probe: ERROR: $*" >&2
}

# ─── check_existing_impl_pr (Issue #65 / Pre-Claim Filter) ───
#
# 与えられた Issue 番号にリンクされた impl PR の有無と state を GraphQL で取得し、
# Dispatcher が当該 Issue を **claim する前** に skip すべきかを判定する。
#
# 事故起点の整理（Issue #65 / 2026-04-29 PR #62 orphan 化）:
#   `codex-failed` 復旧で `codex-failed` のみが除去された Issue は、`codex-auto-dev` が
#   残っているため次 cron tick で再 pickup されてしまう。`_dispatcher_run` は claim
#   直前に linked PR の存在を一切確認していなかったため、impl-resume が起動して
#   既存 PR を `force-push` で破壊する事故が発生する。本関数はその claim 直前の
#   ガードとして機能する。
#
# 入力:  $1 = issue_number（数値）
# 出力:  exit code で判定結果を返す
#        - 0 = pickup 続行 OK（linked impl PR なし or CLOSED のみ）
#        - 1 = skip すべき（OPEN or MERGED の impl PR が存在 / API 失敗 / レート制限）
# 副作用:
#        - 判定結果を pclp_log / pclp_warn で 1 行ログ出力
#          （fixed key=value 形式: `issue=#N pr=#P state=S reason=R` / NFR 2.1〜2.3）
#        - GitHub GraphQL を `timeout "$DRR_GH_TIMEOUT"` で 1 回呼ぶ（NFR 4.1）
#
# Fail-safe: GraphQL 失敗 / timeout / 4xx / 5xx / RATE_LIMITED / 不正レスポンスは
#            **すべて skip 扱い**（exit 1）に倒す。誤って claim して既存 PR を破壊する
#            リスクを最小化するため（Req 1.7 / NFR 4.2）。
#
# 判別ロジック:
#   linked_prs = closedByPullRequestsReferences.nodes（Issue 視点の逆引き field、
#                GitHub は auto-close キーワード
#                `Closes` / `Fixes` / `Resolves` でのみ収集 → impl PR 専用に集約される）
#   for pr in linked_prs:
#     if headRefName が `^codex/issue-${N}-impl(-resume)?-` → impl 採用
#     elif headRefName が `^codex/issue-${N}-design-`     → design として無視 (warn)
#     else                                                  → 未知 pattern → safe-side で
#                                                            impl 扱い (false positive
#                                                            許容、false negative=
#                                                            既存 PR 破壊 を回避)
#   states 集約:
#     OPEN 含む                        → skip (Req 1.2)
#     MERGED 含み OPEN なし            → skip (Req 1.3)
#     CLOSED のみ                      → continue (Req 1.5 / Out of Scope と整合)
#     採用 PR 集合が空                 → continue (Req 1.5 / 通常運用)
#
# Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, NFR 1.5, NFR 2.1, NFR 2.2,
#               NFR 4.1, NFR 4.2
check_existing_impl_pr() {
  local issue_number="$1"

  # 入力検証: 空 / 非数値は呼び出し側のミス。fail-safe で skip + error ログ。
  if [[ ! "$issue_number" =~ ^[1-9][0-9]*$ ]]; then
    pclp_error "skip issue=#${issue_number:-<empty>} reason=invalid-issue-number"
    return 1
  fi

  # $REPO は "owner/repo" 形式（既存 watcher 全体の前提）。GraphQL の引数として分解する。
  local owner repo_name
  owner="${REPO%%/*}"
  repo_name="${REPO##*/}"
  if [ -z "$owner" ] || [ -z "$repo_name" ] || [ "$owner" = "$REPO" ]; then
    pclp_error "skip issue=#${issue_number} reason=invalid-repo-env repo=${REPO:-<empty>}"
    return 1
  fi

  # GraphQL クエリ: Issue 視点の `closedByPullRequestsReferences` で linked PR を取得。
  # （PullRequest 側 `closingIssuesReferences` の Issue 側 reciprocal field。
  # `Issue.closingIssuesReferences` は schema 上存在しないので使えない。）
  # `includeClosedPrs: true` を明示して CLOSED PR も含めて返させる（CLOSED のみなら
  # continue する判定ロジックを正しく機能させるため / Req 1.5）。
  # `first: 20` は idd-codex の typical（impl + impl-resume を数回繰り返しても数件レベル）
  # に対して十分なマージン。
  # shellcheck disable=SC2016  # `$owner` / `$repo` / `$number` は GraphQL 変数記法であり bash 展開ではない（`-F` で値を渡す）
  local query='query($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) {
      issue(number: $number) {
        closedByPullRequestsReferences(first: 20, includeClosedPrs: true) {
          nodes {
            number
            state
            headRefName
          }
        }
      }
    }
  }'

  # `gh api graphql` を timeout でラップ（既存 DRR / Phase A と同じ規律 / NFR 1.1 で
  # 新規 env var を導入しない）。stderr を捕捉してエラー本文をログに残せるようにする。
  local response gh_rc
  response=$(timeout "${DRR_GH_TIMEOUT:-${MERGE_QUEUE_GIT_TIMEOUT:-60}}" \
    gh api graphql \
      -f query="$query" \
      -F owner="$owner" \
      -F repo="$repo_name" \
      -F number="$issue_number" 2>&1) && gh_rc=0 || gh_rc=$?

  if [ "$gh_rc" -ne 0 ]; then
    # レート制限の場合は専用 reason で記録（NFR 4.2）。それ以外は generic な失敗として記録。
    if echo "$response" | grep -qiE 'rate.?limit|RATE_LIMITED|HTTP 429|too many requests'; then
      pclp_warn "skip issue=#${issue_number} reason=rate-limited rc=${gh_rc}"
    else
      pclp_warn "skip issue=#${issue_number} reason=graphql-failed rc=${gh_rc}"
    fi
    return 1
  fi

  # GraphQL は HTTP 200 でも errors を返すケースがあるため明示的に検査する。
  if echo "$response" | jq -e '.errors // empty | length > 0' >/dev/null 2>&1; then
    if echo "$response" | jq -e '.errors // [] | map(.type // "") | any(. == "RATE_LIMITED")' >/dev/null 2>&1; then
      pclp_warn "skip issue=#${issue_number} reason=rate-limited"
    else
      pclp_warn "skip issue=#${issue_number} reason=graphql-errors"
    fi
    return 1
  fi

  # nodes 取得（schema mismatch / null は防衛的に空配列扱い）。
  local nodes_json
  if ! nodes_json=$(echo "$response" | jq -c '.data.repository.issue.closedByPullRequestsReferences.nodes // []' 2>/dev/null); then
    pclp_warn "skip issue=#${issue_number} reason=jq-parse-error"
    return 1
  fi

  # impl PR と判別された PR の (number, state) ペアを抽出する。
  # head pattern マッチング:
  #   - `codex/issue-${N}-design-...`  → design として無視（warn）
  #   - その他すべて                     → impl として採用（safe-side / 未知 pattern も
  #                                       含めて skip 側に倒す）
  # 安全側に倒すことで未知の branch pattern が原因で既存 PR を壊すリスクを排除する。
  # 明示的な impl pattern マッチ判定はせず、design 以外を一括で impl 扱いにする。
  local design_pattern="^codex/issue-${issue_number}-design-"

  # nodes を 1 件ずつ評価して採用/不採用を確定する。
  # bash の連想配列で state ごとに「最初に見つけた PR 番号」を保持する。
  declare -A first_pr_by_state=()
  declare -A best_pr_by_state=()  # MERGED は最大番号 = 最新を採用
  local node total_nodes
  total_nodes=$(echo "$nodes_json" | jq 'length')
  if [ "$total_nodes" -eq 0 ]; then
    pclp_log "continue issue=#${issue_number} reason=no-linked-impl-pr"
    return 0
  fi

  local i=0
  while [ "$i" -lt "$total_nodes" ]; do
    node=$(echo "$nodes_json" | jq -c ".[$i]")
    local pr_num pr_state pr_head
    pr_num=$(echo "$node" | jq -r '.number // empty')
    pr_state=$(echo "$node" | jq -r '.state // empty')
    pr_head=$(echo "$node" | jq -r '.headRefName // empty')
    i=$((i+1))

    # 必須フィールド欠落は防衛的に skip（GraphQL schema は GA 済み API だが念のため）
    if [ -z "$pr_num" ] || [ -z "$pr_state" ]; then
      continue
    fi

    # impl/design 判別
    if [[ "$pr_head" =~ $design_pattern ]]; then
      # design PR が closedByPullRequestsReferences に含まれるのは設計上の異常
      # （PjM template は `Refs #N` を使うため）。warn だけ出して採用しない。
      pclp_warn "ignore issue=#${issue_number} pr=#${pr_num} head=${pr_head} reason=design-pr-in-closing-refs"
      continue
    fi

    # impl pattern に厳密マッチ または unknown pattern は impl として採用する（safe-side）
    # 採用された PR の state を集約する。OPEN は最初に見つけた番号を、MERGED は最大番号を、
    # CLOSED は最初に見つけた番号を採用する。
    case "$pr_state" in
      OPEN)
        if [ -z "${first_pr_by_state[OPEN]:-}" ]; then
          first_pr_by_state[OPEN]="$pr_num"
        fi
        ;;
      MERGED)
        if [ -z "${best_pr_by_state[MERGED]:-}" ] || [ "$pr_num" -gt "${best_pr_by_state[MERGED]}" ]; then
          best_pr_by_state[MERGED]="$pr_num"
        fi
        ;;
      CLOSED)
        if [ -z "${first_pr_by_state[CLOSED]:-}" ]; then
          first_pr_by_state[CLOSED]="$pr_num"
        fi
        ;;
      *)
        # 未知 state（GraphQL schema 拡張等）は防衛的に skip 側に倒す
        pclp_warn "skip issue=#${issue_number} pr=#${pr_num} reason=unknown-pr-state state=${pr_state}"
        return 1
        ;;
    esac
  done

  # state 集約結果から判定（OPEN > MERGED > CLOSED の包含関係 / Req 1.2 / 1.3 / 1.5）
  if [ -n "${first_pr_by_state[OPEN]:-}" ]; then
    pclp_log "skip issue=#${issue_number} pr=#${first_pr_by_state[OPEN]} state=OPEN reason=existing-impl-pr"
    return 1
  fi
  if [ -n "${best_pr_by_state[MERGED]:-}" ]; then
    pclp_log "skip issue=#${issue_number} pr=#${best_pr_by_state[MERGED]} state=MERGED reason=existing-impl-pr"
    return 1
  fi
  if [ -n "${first_pr_by_state[CLOSED]:-}" ]; then
    pclp_log "continue issue=#${issue_number} pr=#${first_pr_by_state[CLOSED]} reason=closed-only"
    return 0
  fi

  # 採用 PR 集合が空（すべての node が design として無視 / フィールド欠落 等）
  pclp_log "continue issue=#${issue_number} reason=no-linked-impl-pr"
  return 0
}

# ─── _parallel_validate_slots ───
#
# PARALLEL_SLOTS が正の整数として解釈できるかを検証する。
# - 0 / 負数 / 非数値 / 空文字 / 先頭ゼロ等の形式違反を拒否する
# - 不正なら ERROR ログを stderr に出力して return 1
# 戻り値: 0 = ok / 1 = invalid
#
# Req 1.3: 不正値時はサイクル中断（呼び出し元で exit 1）
# Req 6.5: timestamp 書式 [YYYY-MM-DD HH:MM:SS] を維持
_parallel_validate_slots() {
  if [[ ! "$PARALLEL_SLOTS" =~ ^[1-9][0-9]*$ ]]; then
    dispatcher_error "PARALLEL_SLOTS は正の整数を指定してください: '$PARALLEL_SLOTS'"
    return 1
  fi
  return 0
}

# ─── Phase C: Worktree Manager ───
#
# Per-slot 永続 worktree を $WORKTREE_BASE_DIR/<repo-slug>/slot-N/ に配置し、
# slot 同士の作業ツリー干渉を物理隔離する（Req 3.5）。
#
# 設計判断:
#   - slot worktree は `git worktree add --detach` で detached HEAD として作成する
#     （Slot Runner が `git checkout -B <branch> $BASE_BRANCH` で新規 branch に
#     切り替える際、他 slot の worktree が同じ local branch を保持していても
#     ブロックされないため）
#   - `git worktree list --porcelain` で冪等性を担保
#   - 破損検出時は <slot-N>.broken-<ts> に退避してから再作成
#   - PARALLEL_SLOTS=1 のときは slot-2 以降の worktree を作らない（呼び出し元で gate）

# slot 番号から worktree ディレクトリの絶対パスを返す。
# 引数: $1 = slot 番号
# Req 3.1, 3.7
_worktree_path() {
  local n="$1"
  echo "$WORKTREE_BASE_DIR/$REPO_SLUG/slot-$n"
}

# 指定 path が現在の repo の git worktree として登録済みかを判定。
# 0 = 登録済み / 非ゼロ = 未登録
_worktree_is_registered() {
  local wt_path="$1"
  # `git worktree list --porcelain` は `worktree <abs_path>` 形式で各 worktree を返す
  git -C "$REPO_DIR" worktree list --porcelain 2>/dev/null \
    | grep -Fx "worktree $wt_path" >/dev/null 2>&1
}

# Per-slot worktree を冪等に確保する。
# 引数: $1 = slot 番号
# 戻り値: 0 = ok（worktree が存在し利用可能） / 1 = 失敗（呼び出し元で codex-failed 化）
# 副作用: $WORKTREE_BASE_DIR/<slug>/slot-N/ を作成または再利用
#
# Req 3.1, 3.2, 3.3, 3.6, 3.7
_worktree_ensure() {
  local n="$1"
  local wt_path
  wt_path="$(_worktree_path "$n")"
  local parent_dir
  parent_dir="$(dirname "$wt_path")"

  if ! mkdir -p "$parent_dir" 2>/dev/null; then
    dispatcher_warn "slot-${n}: worktree 親ディレクトリ作成に失敗: $parent_dir"
    return 1
  fi

  # ケース A: 既に worktree として登録済み → 再利用（Req 3.3）
  if _worktree_is_registered "$wt_path"; then
    if [ -d "$wt_path/.git" ] || [ -f "$wt_path/.git" ]; then
      return 0
    fi
    # 登録は残っているが実体が壊れている → prune してから再作成
    dispatcher_warn "slot-${n}: worktree 登録あり実体欠損、prune して再作成: $wt_path"
    git -C "$REPO_DIR" worktree prune >/dev/null 2>&1 || true
  fi

  # ケース B: dir は存在するが worktree として登録されていない（未初期化 or 破損）
  if [ -e "$wt_path" ]; then
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local broken="${wt_path}.broken-${ts}"
    dispatcher_warn "slot-${n}: 既存ディレクトリを退避して worktree を再作成: $wt_path -> $broken"
    if ! mv "$wt_path" "$broken" 2>/dev/null; then
      dispatcher_warn "slot-${n}: 既存ディレクトリの退避に失敗: $wt_path"
      return 1
    fi
    git -C "$REPO_DIR" worktree prune >/dev/null 2>&1 || true
  fi

  # ケース C: 新規作成（origin/$BASE_BRANCH から detached HEAD として）
  # detached にする理由: 各 slot が `git checkout -B <branch> $BASE_BRANCH` で新規
  # branch に切り替える際、別 slot worktree が同じ local branch を持っていても
  # 弾かれないため。
  if ! git -C "$REPO_DIR" worktree add --detach "$wt_path" "origin/${BASE_BRANCH}" >/dev/null 2>&1; then
    dispatcher_warn "slot-${n}: git worktree add に失敗: $wt_path"
    return 1
  fi
  dispatcher_log "slot-${n}: worktree 作成: $wt_path (detached @ origin/${BASE_BRANCH})"
  return 0
}

# Per-slot worktree を origin/$BASE_BRANCH の最新状態に強制リセットする
# （Issue 投入時に毎回呼ぶ）。
# 引数: $1 = worktree 絶対パス
# 戻り値: 0 = ok / 1 = 失敗
# 副作用: 当該 worktree が origin/$BASE_BRANCH の最新コミットに head=detached、
#   tracked / untracked / ignored すべて消去される
#
# Req 3.4
_worktree_reset() {
  local wt="$1"
  if [ ! -d "$wt" ]; then
    return 1
  fi
  # 1. 最新の origin を取得
  if ! git -C "$wt" fetch origin --prune >/dev/null 2>&1; then
    return 1
  fi
  # 2. detached HEAD を origin/$BASE_BRANCH に強制移動
  if ! git -C "$wt" reset --hard "origin/${BASE_BRANCH}" >/dev/null 2>&1; then
    return 1
  fi
  # 3. untracked + ignored を消去（前回 Issue の build artifact / node_modules を残さない）
  if ! git -C "$wt" clean -fdx >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# ─── Phase C: Slot Lock Manager ───
#
# Per-slot 非ブロッキング flock を提供する。slot 間のロックは別ファイルとし、
# ある slot の処理が他 slot の処理開始をブロックしない（Req 4.4）。
#
# fd 番号: 既存 LOCK_FILE が fd 200 を使うため、衝突回避で 210 + slot_number を使う。
# 従って bash の per-fd 上限以下になるよう、PARALLEL_SLOTS は事実上 ~ 数十程度を想定
# （AGENTS.md には bash 4+ と記載済、bash の fd 上限は通常数百〜数千）。
#
# slot Worker はサブシェル `( ... ) &` で動くため、サブシェル終了で fd は自動解放され、
# 明示的な _slot_release 呼び出しは不要だが命名対称性のため定義する。

# slot 番号から lock file path を返す。
# 引数: $1 = slot 番号
# Req 4.1
_slot_lock_path() {
  local n="$1"
  echo "$SLOT_LOCK_DIR/${REPO_SLUG}-slot-${n}.lock"
}

# 指定 slot の per-slot 非ブロッキング flock を取得する（成功時 fd 210+N が open のまま残る）。
# 引数: $1 = slot 番号
# 戻り値: 0 = acquired / 1 = 既に他プロセスがロック中、または fd open 失敗
# 副作用: 成功時 fd (210+N) が open 状態（呼び出し側スコープで保持される）
#
# Req 4.2, 4.3, 4.4
_slot_acquire() {
  local n="$1"
  local lock_file
  lock_file="$(_slot_lock_path "$n")"
  # parent dir を冪等作成（SLOT_LOCK_DIR は通常 $HOME/.idd-codex/issue-watcher で既存）
  mkdir -p "$(dirname "$lock_file")" 2>/dev/null || return 1
  local fd=$((210 + n))
  # eval を使うのは bash 4.0 互換のため。入力 n は _parallel_validate_slots 通過済の
  # 正整数のみで、外部入力は流入しない（NFR 2.3 のシェル展開リスクなし）。
  # shellcheck disable=SC1083
  if ! eval "exec ${fd}>\"\$lock_file\"" 2>/dev/null; then
    return 1
  fi
  if ! flock -n "$fd" 2>/dev/null; then
    # 既に他プロセスがロック中。fd を閉じて return 1
    eval "exec ${fd}>&-" 2>/dev/null || true
    return 1
  fi
  return 0
}

# 指定 slot の per-slot lock を解放する。
# 引数: $1 = slot 番号
# 戻り値: 常に 0
# サブシェル終了で fd は自動解放されるため通常は呼ぶ必要なし。Dispatcher 側で
# claim 失敗時のロールバックに使う（Req 2.3: ラベル付与失敗で slot lock 解放）。
_slot_release() {
  local n="$1"
  local fd=$((210 + n))
  # shellcheck disable=SC1083
  eval "exec ${fd}>&-" 2>/dev/null || true
  return 0
}

# ─── Phase C: Hook Layer ───
#
# SLOT_INIT_HOOK 起動を担う薄い wrapper。
#
# 安全性（NFR 2.3 / Req 5.5）:
#   - SLOT_INIT_HOOK の値はシェル展開させない（eval / `bash -c` 不使用）
#   - 絶対パスをそのまま起動するのみ。引数文字列の空白分割を許容しない
#   - "/path/to/script.sh --flag" のような引数渡しはサポート外（README に明記、
#     ユーザーは wrapper script を書く）

# SLOT_INIT_HOOK を起動する。未設定なら no-op。
# 引数: $1 = slot 番号, $2 = worktree 絶対パス
# 戻り値: 0 = 起動成功 / 1 = 起動失敗（path 不在 / 非実行可能 / 非ゼロ exit）
# 副作用: hook 子プロセスの stdout / stderr は呼び出し元の標準出力 / エラー出力に流れる
#
# Req 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, NFR 2.3
_hook_invoke() {
  local n="$1"
  local wt="$2"
  if [ -z "${SLOT_INIT_HOOK:-}" ]; then
    return 0
  fi
  if [ ! -x "$SLOT_INIT_HOOK" ]; then
    echo "[$(date '+%F %T')] slot-${n}: ERROR: SLOT_INIT_HOOK が存在しないか実行可能ではありません: $SLOT_INIT_HOOK" >&2
    return 1
  fi

  # stderr を一時ファイルに捕捉して非ゼロ exit 時にログ転記する（Req 5.7）
  local stderr_tmp
  stderr_tmp="$(mktemp -t slot-init-hook-XXXXXX.err 2>/dev/null || echo "")"
  local rc=0

  # IDD_SLOT_NUMBER / IDD_SLOT_WORKTREE / PARALLEL_SLOTS / REPO / REPO_DIR を export
  # して子プロセスに引き継ぐ。直接 exec のみ（Req 5.5: shell 展開なし）。
  if [ -n "$stderr_tmp" ]; then
    IDD_SLOT_NUMBER="$n" \
      IDD_SLOT_WORKTREE="$wt" \
      PARALLEL_SLOTS="$PARALLEL_SLOTS" \
      REPO="$REPO" \
      REPO_DIR="$REPO_DIR" \
      "$SLOT_INIT_HOOK" 2> >(tee -a "$stderr_tmp" >&2) || rc=$?
  else
    IDD_SLOT_NUMBER="$n" \
      IDD_SLOT_WORKTREE="$wt" \
      PARALLEL_SLOTS="$PARALLEL_SLOTS" \
      REPO="$REPO" \
      REPO_DIR="$REPO_DIR" \
      "$SLOT_INIT_HOOK" || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    local tail_text=""
    if [ -n "$stderr_tmp" ] && [ -f "$stderr_tmp" ]; then
      tail_text="$(tail -c 2000 "$stderr_tmp" 2>/dev/null || true)"
    fi
    echo "[$(date '+%F %T')] slot-${n}: ERROR: SLOT_INIT_HOOK が exit code ${rc} で失敗しました: $SLOT_INIT_HOOK" >&2
    if [ -n "$tail_text" ]; then
      echo "[$(date '+%F %T')] slot-${n}: hook stderr (tail):" >&2
      echo "$tail_text" >&2
    fi
  fi

  if [ -n "$stderr_tmp" ]; then
    rm -f "$stderr_tmp" 2>/dev/null || true
  fi

  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  return 0
}

# ─── Phase C: Slot Runner ───
#
# 1 Issue を 1 つの slot worktree で処理する Worker。Dispatcher から
# `( _slot_run_issue $n $issue_json ) &` の形でバックグラウンド fork される。
#
# 設計上の重要点:
#   - サブシェルで動くため、内部の `cd` / 環境変数変更は親に伝播しない（Req 3.5 を構造的に保証）
#   - 入口で _slot_acquire 済を前提（Dispatcher が取得済の lock fd を継承）
#   - claim（codex-picked-up ラベル付与）は Dispatcher 側で完了済（Req 2.2）
#   - 処理シーケンス:
#       1. slot 専用ログファイル open
#       2. _worktree_ensure → 失敗時 codex-failed 化 + return
#       3. cd "$WT"
#       4. _worktree_reset → 失敗時 codex-failed 化 + return
#       5. _hook_invoke → 失敗時 codex-failed 化 + return
#       6. 既存 Issue 処理ロジック（Triage → mode 判定 → Codex 起動）を実行
#   - すべての codex-failed 化は既存 mark_issue_failed パスを再利用（新ラベル不可）
#
# Req 2.7, 3.4, 3.5, 3.6, 5.3, 5.6, 5.7, 6.1, 6.2, 6.5, 7.3, 7.4, NFR 2.1, 2.2, 3.1, 3.2

# slot worker 用ロガー（slot 番号 + Issue 番号を必ず prefix に含める、Req 6.1, NFR 3.1）。
# サブシェル内で IDD_SLOT_NUMBER / NUMBER を読み取って prefix を組み立てる。
slot_log() {
  echo "[$(date '+%F %T')] slot-${IDD_SLOT_NUMBER:-?}: #${NUMBER:-?}: $*"
}
slot_warn() {
  echo "[$(date '+%F %T')] slot-${IDD_SLOT_NUMBER:-?}: #${NUMBER:-?}: WARN: $*" >&2
}
slot_error() {
  echo "[$(date '+%F %T')] slot-${IDD_SLOT_NUMBER:-?}: #${NUMBER:-?}: ERROR: $*" >&2
}

# claim 系ラベル（codex-claimed / codex-picked-up）を codex-failed に置き換える
# 共通フロー（Worktree / Hook / その他サブシェル内エラー用）。run_impl_pipeline 内の
# mark_issue_failed と同じ操作を slot worker 文脈で再現する（mark_issue_failed は
# MODE / LOG 等を要求するため代用しない）。
#
# Issue #52: 両系統除去で post-Triage / pre-Triage どちらの失敗にも対応する。
# - pre-Triage 失敗時点では Issue は codex-claimed のみ持つ
# - post-Triage（impl 着手後）失敗時点では Issue は codex-picked-up のみ持つ
# - design ルートで Stage C 失敗等の想定外シーケンスでも残置を防ぐため両方除去する
# gh CLI は未付与ラベルの除去を no-op として扱うため安全（既存 || true で吸収）。
#
# 引数: $1 = stage 識別子, $2 = Issue コメントに追加する補足
_slot_mark_failed() {
  local stage="$1"
  local extra="$2"
  gh issue edit "$NUMBER" --repo "$REPO" \
    --remove-label "$LABEL_CLAIMED" --remove-label "$LABEL_PICKED" --add-label "$LABEL_FAILED" >/dev/null 2>&1 || true
  local hostname_val
  hostname_val=$(hostname)
  local body="⚠️ 自動開発が失敗しました（${hostname_val} / slot=${IDD_SLOT_NUMBER:-?} / 失敗 stage: ${stage}）。"
  if [ -n "$extra" ]; then
    body="${body}

${extra}"
  fi
  if [ -n "${LOG:-}" ]; then
    body="${body}

ログ: \`$LOG\`"
  fi
  body="${body}

問題を解決してから \`codex-failed\` ラベルを外してください。"

  # Issue #65 Req 3.1/3.2/3.3/3.4: 手動復旧手順を末尾に append。
  # _slot_mark_failed は worktree / Hook / Triage 失敗等から呼ばれ、PR の有無が
  # 文脈で確定しないため pr_present="unknown" を渡す（両ケース併記）。
  body="${body}
$(build_recovery_hint "unknown")"
  gh issue comment "$NUMBER" --repo "$REPO" --body "$body" >/dev/null 2>&1 || true
}

# ─── impl-resume 保護ヘルパ群 (Issue #67) ───
#
# `IMPL_RESUME_PRESERVE_COMMITS=true` 配下で:
#   - `_resume_normalize_flag`            : env 値の strict 正規化（純粋関数）
#   - `_resume_detect_existing_branch`    : origin に branch があるかを ls-remote で判定
#   - `_resume_branch_init`               : impl-resume 用 branch 初期化の Strategy 分岐
#   - `_resume_push`                      : fast-forward 制約 push と non-ff 検出
#   - `_resume_mark_nonff_failed`         : non-ff 専用 codex-failed 遷移ヘルパ
#
# `_slot_mark_failed` / `slot_log` / `slot_warn` を再利用するため、それらの定義より
# 後ろ、`_slot_run_issue` より前に配置する（forward reference を避ける）。
# 設計詳細: docs/specs/67-feat-watcher-impl-resume-branch-commit-f/design.md

# env var の生値を厳密に "true" / "false" に正規化する純粋関数（副作用なし）。
# 引数:
#   $1 = mode（"preserve_default_off" | "tracking_default_on"）
#   $2 = 生 env 値（unset を許容 = 空文字として渡す）
# stdout: "true" または "false"
# 戻り値: 常に 0
#
# Req 1.3 / 3.6: 受理値は完全一致 "true" / "false" のみ。それ以外（空 / "True" /
# "1" / "yes" 等の typo）は安全側に倒す:
#   - preserve_default_off: "true" 完全一致のみ true、それ以外は false
#   - tracking_default_on : "false" 完全一致のみ false、それ以外（空文字含む）は true
_resume_normalize_flag() {
  local mode="$1"
  local raw="${2:-}"
  case "$mode" in
    preserve_default_off)
      if [ "$raw" = "true" ]; then
        echo "true"
      else
        echo "false"
      fi
      ;;
    tracking_default_on)
      if [ "$raw" = "false" ]; then
        echo "false"
      else
        echo "true"
      fi
      ;;
    *)
      # 不明な mode は安全側に倒して false を返す（呼び出し元の bug を表面化させる）
      echo "false"
      ;;
  esac
}

# 対象 branch が origin に存在するかを `git ls-remote --exit-code` で検出する。
# 引数: $1 = branch name（例: "codex/issue-67-impl-..."）
# 戻り値:
#   0 = origin に存在
#   1 = 不在 / 検出失敗（ネットワーク失敗・タイムアウトを含めて呼び出し元では同等扱い）
# 副作用: なし（git ls-remote は read-only）
#
# Req 2.1, 2.2: PR の有無とは独立に branch 存在の真実値を取得する。`gh pr list` には
# 依存しない（設計論点 1: PR が close 済 / 未作成のケースで false negative を避ける）。
# 失敗時は安全側に倒して fresh-init 経路に倒す（NFR 2.1: WARN ログ）。
# timeout 30 秒は既存 MERGE_QUEUE_GIT_TIMEOUT より短め。watcher 全体の cron 周期
# （最短 2 分）を圧迫しないため。
_resume_detect_existing_branch() {
  local branch="$1"
  if [ -z "$branch" ]; then
    return 1
  fi
  # `git ls-remote --exit-code` は ref 不在で exit code 2 を返す。timeout は 30 秒。
  # ネットワーク失敗等の予期せぬ exit code はすべて「不在」として fail-safe。
  if timeout 30 git ls-remote --exit-code --heads origin "refs/heads/$branch" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# `impl-resume` モードの branch 初期化を opt-in flag によって 2 戦略のいずれかに
# ディスパッチする。既存の `git checkout -B "$BRANCH" "origin/$BASE_BRANCH"` +
# `git push -u origin "$BRANCH" --force-with-lease` シーケンスを内包する。
#
# 入力（環境変数経由）:
#   BRANCH                          : codex/issue-N-impl-<slug> 形式
#   IMPL_RESUME_PRESERVE_COMMITS    : "true" / "false" / unset
#   MODE                            : "impl-resume" 前提（呼び出し元で gate 済み）
# 戻り値:
#   0 = init 成功（HEAD = $BRANCH、push 済み）
#   非 0 = 失敗（呼び出し元で _slot_mark_failed 既に発射済み）
# 副作用:
#   - git checkout -B（local branch 作成）
#   - git push -u origin（fast-forward または force-with-lease。flag 値で分岐）
#   - SLOT_LOG / 標準出力にイベントログ追記
#   - 失敗時は _slot_mark_failed が gh issue edit + comment を発射
#   - 呼び出し後 RESUME_PRESERVE 変数を export（後段 prompt builder が参照）
#
# Req 1.1, 1.2, 2.1, 2.2, 2.3, 2.5, 4.4, NFR 1.3, NFR 2.1
#
# 戦略:
#   PRESERVE=false（既定）→ 既存挙動: checkout -B BRANCH origin/$BASE_BRANCH + force-with-lease push
#   PRESERVE=true + branch 存在 → checkout -B BRANCH origin/BRANCH + fast-forward push
#   PRESERVE=true + branch 不在 → checkout -B BRANCH origin/$BASE_BRANCH + fast-forward push
#
# 注意: opt-in パスの fast-forward push と non-ff 検出ロジックは task 3.1 / 3.2 で
# `_resume_push` / `_resume_mark_nonff_failed` 関数に切り出す（PR 履歴上の独立性確保のため、
# 本 task では inline で git push を呼ぶ最小実装）。
_resume_branch_init() {
  local preserve
  preserve=$(_resume_normalize_flag preserve_default_off "${IMPL_RESUME_PRESERVE_COMMITS:-}")
  export RESUME_PRESERVE="$preserve"

  if [ "$preserve" != "true" ]; then
    # ── 既定パス: 本機能導入前と完全に等価な挙動 ──
    # worktree は detached HEAD で起動するため -B で新規 branch 作成
    # （local $BASE_BRANCH を持たない）
    if ! git checkout -B "$BRANCH" "origin/${BASE_BRANCH}"; then
      slot_warn "branch 作成に失敗: $BRANCH"
      _slot_mark_failed "branch-checkout" "ブランチ \`$BRANCH\` の作成に失敗しました。"
      return 1
    fi
    if ! git push -u origin "$BRANCH" --force-with-lease; then
      slot_warn "branch push に失敗: $BRANCH"
      _slot_mark_failed "branch-push" "ブランチ \`$BRANCH\` の push に失敗しました。"
      return 1
    fi
    slot_log "resume-mode=legacy-force-push branch=$BRANCH"
    return 0
  fi

  # ── opt-in パス: PRESERVE=true ──
  # origin に branch が存在するか判定。存在すればそこから resume、不在なら
  # origin/$BASE_BRANCH 起点。
  local origin_sha=""
  if _resume_detect_existing_branch "$BRANCH"; then
    if ! git checkout -B "$BRANCH" "origin/$BRANCH"; then
      slot_warn "既存 branch resume に失敗: $BRANCH"
      _slot_mark_failed "branch-checkout" "既存 origin branch \`$BRANCH\` からの resume に失敗しました。"
      return 1
    fi
    origin_sha=$(git rev-parse --short=7 "origin/$BRANCH" 2>/dev/null || echo "unknown")
    slot_log "resume-mode=existing-branch branch=$BRANCH origin_sha=$origin_sha"
  else
    if ! git checkout -B "$BRANCH" "origin/${BASE_BRANCH}"; then
      slot_warn "branch 作成に失敗: $BRANCH"
      _slot_mark_failed "branch-checkout" "ブランチ \`$BRANCH\` の作成に失敗しました。"
      return 1
    fi
    slot_log "resume-mode=fresh-from-base branch=$BRANCH base=$BASE_BRANCH"
  fi

  # opt-in パスの push は fast-forward 制約付き（_resume_push に委譲）。
  # _resume_push が non-ff を検出した場合は内部で codex-failed 付与済み。
  if ! _resume_push "$BRANCH"; then
    return 1
  fi
  return 0
}

# fast-forward 制約付き push を実行し、stderr から非 fast-forward 検出時は
# 専用 stage `branch-nonff` で codex-failed に遷移する。
# 引数: $1 = branch
# 戻り値:
#   0 = push 成功
#   1 = non-ff reject または push 失敗（codex-failed 付与済み）
# 副作用:
#   - git push -u origin <branch>（force 系オプションを一切付けない）
#   - non-ff 検出時 / 失敗時は _slot_mark_failed が gh issue edit + comment 発射
#
# Req 4.1, 4.2, 4.5: 失敗してもリトライしない / reset / rebase / merge を行わない。
# stderr 解析で "non-fast-forward" / "rejected.*non-fast" / "Updates were rejected"
# パターンを ERE で判定。non-ff 以外の push 失敗（ネットワーク等）は既存 branch-push
# 失敗パスに合流させる。
#
# 注意: non-ff 専用 Issue コメント本文の組み立ては task 3.2 で `_resume_mark_nonff_failed`
# として切り出し予定。本 commit では inline body で _slot_mark_failed "branch-nonff" を呼ぶ。
_resume_push() {
  local branch="$1"
  local stderr_tmp
  stderr_tmp=$(mktemp -t resume-push-XXXXXX.err 2>/dev/null || echo "")

  local rc=0
  if [ -n "$stderr_tmp" ]; then
    git push -u origin "$branch" 2>"$stderr_tmp" || rc=$?
  else
    # mktemp 失敗時のフォールバック（stderr 捕捉できないが push は試みる）
    git push -u origin "$branch" || rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    if [ -n "$stderr_tmp" ]; then
      rm -f "$stderr_tmp" 2>/dev/null || true
    fi
    return 0
  fi

  # 失敗。stderr の内容で non-ff か否かを判別
  local stderr_content=""
  if [ -n "$stderr_tmp" ] && [ -f "$stderr_tmp" ]; then
    stderr_content=$(cat "$stderr_tmp" 2>/dev/null || true)
  fi

  local stderr_tail=""
  if [ -n "$stderr_content" ]; then
    # コメント本文に過剰な行を入れないよう末尾 1500 文字程度に制限
    stderr_tail=$(echo "$stderr_content" | tail -c 1500)
  fi

  # POSIX ERE で non-fast-forward / rejected パターンを検出
  if echo "$stderr_content" | grep -Eq '(non-fast-forward|rejected.*non-fast|Updates were rejected because the (tip|remote))'; then
    slot_warn "non-ff push detected; aborting (branch=$branch)"
    slot_log "resume-failure=non-ff issue=#${NUMBER:-?} branch=$branch"
    _resume_mark_nonff_failed "$branch" "$stderr_tail"
  else
    # non-ff 以外の push 失敗（ネットワーク等）。既存 branch-push 失敗パスに合流。
    slot_warn "push に失敗（non-ff ではない）: $branch"
    slot_log "resume-failure=push-error issue=#${NUMBER:-?} branch=$branch"
    local body="ブランチ \`$branch\` の push に失敗しました（fast-forward 制約付き push）。"
    if [ -n "$stderr_tail" ]; then
      body="$body

\`\`\`
$stderr_tail
\`\`\`"
    fi
    _slot_mark_failed "branch-push" "$body"
  fi

  if [ -n "$stderr_tmp" ]; then
    rm -f "$stderr_tmp" 2>/dev/null || true
  fi
  return 1
}

# non-ff 専用の `codex-failed` 遷移ヘルパ。
# 既存 `_slot_mark_failed` の薄い wrapper として、Issue コメントに「force-push 抑制で
# 停止した」旨と人間操作手順を記載する。
# 引数:
#   $1 = branch
#   $2 = stderr の tail（任意。診断情報として Issue コメントに含める）
# 戻り値: 常に 0
#
# Req 4.2, 4.3, NFR 2.2: 運用者がログ単独で原因と Issue 番号を特定できる粒度で記録。
# 既存 stage 識別子セット（branch-checkout / branch-push 等）に branch-nonff を追加。
_resume_mark_nonff_failed() {
  local branch="$1"
  local stderr_tail="${2:-}"
  local body="自動 force-push を抑制したため停止しました（impl-resume 保護機能）。

- 対象 branch: \`$branch\`
- 対象 Issue : #${NUMBER:-?}
- 検出理由 : non-fast-forward push（既存 origin branch に対し remote がローカル HEAD の祖先ではない）

### 次の手順

1. ローカルで \`git fetch origin\` 後、当該 branch の差分を確認
2. 必要なら手動で merge / rebase / cherry-pick で衝突解消
3. 解消できたら本 Issue から \`codex-failed\` ラベルを除去すると次サイクルで再 pickup されます

> 注意: 本機能は \`IMPL_RESUME_PRESERVE_COMMITS=true\` でのみ動作します。
> 強制 fresh が必要なら \`IMPL_RESUME_PRESERVE_COMMITS=false\` に戻すか、
> \`git push origin :$branch\` で origin branch を削除してから再 pickup してください。"

  if [ -n "$stderr_tail" ]; then
    body="$body

### git stderr (tail)

\`\`\`
$stderr_tail
\`\`\`"
  fi

  _slot_mark_failed "branch-nonff" "$body"
  return 0
}

# 1 Issue を 1 slot worktree で処理する Worker 本体。
# サブシェル `( _slot_run_issue n issue_json ) &` から呼び出される前提。
#
# 引数:
#   $1 = slot 番号
#   $2 = Issue JSON (gh issue list の 1 要素)
# 戻り値:
#   0 = 成功 / 非ゼロ = 失敗（既に codex-failed ラベルへ遷移済み）
#
# 副作用:
#   - サブシェル内で NUMBER / TITLE / BODY / URL / LABELS / TS / LOG / SLUG /
#     SPEC_DIR_REL / MODE / BRANCH などのグローバル変数を設定（親には伝播しない）
#   - $WT に cd（サブシェル内）
#   - codex / gh / git の副作用は Issue ラベル遷移として外部観測可能
_slot_run_issue() {
  # slot 識別子をサブシェル内で見えるよう export（slot_log / _hook_invoke が参照）
  export IDD_SLOT_NUMBER="$1"
  local issue="$2"

  # ── Issue メタデータ抽出 ──
  NUMBER=$(echo "$issue" | jq -r '.number')
  TITLE=$(echo "$issue"  | jq -r '.title')
  BODY=$(echo "$issue"   | jq -r '.body // ""')
  URL=$(echo "$issue"    | jq -r '.url')
  LABELS=$(echo "$issue" | jq -r '.labels[].name')
  TS=$(date +%Y%m%d-%H%M%S)
  LOG="$LOG_DIR/issue-${NUMBER}-${TS}.log"

  # idd-codex と同一 repo に併存する前提のため、Codex 側 trigger と Codex 側 trigger が
  # 同じ Issue に同時付与されている場合は Codex 側だけ停止する。
  if echo "$LABELS" | grep -qx "auto-dev"; then
    _slot_mark_failed "namespace-conflict" \
      "同じ Issue に idd-claude の \`auto-dev\` と idd-codex の \`${LABEL_TRIGGER}\` が同時に付いています。二重実行を避けるため Codex 側だけ停止しました。どちらか一方の trigger ラベルに整理してください。"
    return 1
  fi

  # slot 運用ログ（worktree 初期化・hook 結果など）。Issue ログとは別系統で残す（Req 6.2）。
  local SLOT_LOG="$LOG_DIR/slot-${IDD_SLOT_NUMBER}-${NUMBER}-${TS}.log"
  # 以降の slot_log 行は stdout (cron mailer) と SLOT_LOG の両方に書き出す
  exec > >(tee -a "$SLOT_LOG") 2>&1

  slot_log "Worker 起動 (LOG=$LOG SLOT_LOG=$SLOT_LOG)"

  # ── Worktree 初期化（per-slot 永続 worktree）──
  local WT
  WT="$(_worktree_path "$IDD_SLOT_NUMBER")"
  export IDD_SLOT_WORKTREE="$WT"

  if ! _worktree_ensure "$IDD_SLOT_NUMBER"; then
    slot_warn "worktree 初期化に失敗 (path=$WT)"
    _slot_mark_failed "worktree-ensure" "Slot ${IDD_SLOT_NUMBER} の worktree 初期化に失敗しました（path=\`$WT\`）。"
    return 1
  fi
  slot_log "worktree 確保 OK (path=$WT)"

  # サブシェル内で worktree に cd（親には伝播しない、Req 3.5）
  if ! cd "$WT"; then
    slot_warn "worktree への cd に失敗 (path=$WT)"
    _slot_mark_failed "worktree-cd" "worktree path への cd に失敗しました: \`$WT\`"
    return 1
  fi

  # Issue #76: slot worktree が REPO_DIR の意味を担う。サブシェル内で上書きするため
  # parent cron / launchd 側の REPO_DIR には伝播せず、後段の parse_review_result /
  # stage_checkpoint_* / `git -C "$REPO_DIR"` 系すべてが slot worktree を参照するようになる。
  # 既存 cron 起動文字列を変更する必要はない。
  REPO_DIR="$WT"

  # ── Worktree を origin/$BASE_BRANCH 最新へ強制リセット ──
  if ! _worktree_reset "$WT"; then
    slot_warn "worktree reset に失敗 (path=$WT)"
    _slot_mark_failed "worktree-reset" "Slot ${IDD_SLOT_NUMBER} の worktree を origin/${BASE_BRANCH} にリセットできませんでした。"
    return 1
  fi
  slot_log "worktree reset OK (origin/${BASE_BRANCH} 最新化 + clean -fdx)"

  # ── SLOT_INIT_HOOK 起動（reset 後・Codex 起動前に 1 度だけ）──
  if ! _hook_invoke "$IDD_SLOT_NUMBER" "$WT"; then
    slot_warn "SLOT_INIT_HOOK の起動に失敗"
    _slot_mark_failed "slot-init-hook" "SLOT_INIT_HOOK が失敗しました（詳細はログ参照）。SLOT_INIT_HOOK=\`${SLOT_INIT_HOOK:-(unset)}\`"
    return 1
  fi
  if [ -n "${SLOT_INIT_HOOK:-}" ]; then
    slot_log "SLOT_INIT_HOOK 完了"
  fi

  # ── 既存 Issue 処理ロジックを実行 ──
  # ここから下は本機能導入前の Issue ループ本体と等価。サブシェル内で動くため
  # NUMBER / MODE / LOG 等のグローバル変数変更は親に伝播しない（Req 3.5 を構造的に保証）。
  echo "=== Processing #$NUMBER: $TITLE (slot-${IDD_SLOT_NUMBER}) ===" | tee -a "$LOG"

  # ── 既存 spec ディレクトリの検出（設計 PR merge 済みか）と slug 決定 ──
  local EXISTING_SPEC_DIR
  EXISTING_SPEC_DIR=$(ls -d "$WT/docs/specs/${NUMBER}-"* 2>/dev/null | head -1 || true)
  local HAS_EXISTING_SPEC=false
  if [ -n "$EXISTING_SPEC_DIR" ] && [ -f "$EXISTING_SPEC_DIR/requirements.md" ]; then
    HAS_EXISTING_SPEC=true
    SLUG=$(basename "$EXISTING_SPEC_DIR" | sed "s/^${NUMBER}-//")
    echo "📂 既存 spec 検出: $EXISTING_SPEC_DIR (slug=$SLUG)" | tee -a "$LOG"
  else
    SLUG=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' \
          | sed -E 's/[^a-z0-9]+/-/g' | cut -c1-40 | sed -E 's/-+$//')
  fi
  SPEC_DIR_REL="docs/specs/${NUMBER}-${SLUG}"

  # ── モード判定（design / impl / impl-resume）──
  NEEDS_ARCHITECT="false"
  ARCHITECT_REASON=""
  MODE=""

  if $HAS_EXISTING_SPEC; then
    echo "✅ #$NUMBER: 設計レビュー済み（spec dir あり） → impl-resume モード" | tee -a "$LOG"
    MODE="impl-resume"
  elif echo "$LABELS" | grep -qx "$LABEL_SKIP_TRIAGE"; then
    echo "codex-skip-triage ラベルがあるため Triage をスキップ → impl モード" | tee -a "$LOG"
    ARCHITECT_REASON="Triage をスキップ（軽微な変更扱い）"
    MODE="impl"
  else
    # ── Triage フェーズ ──
    local TRIAGE_FILE="/tmp/triage-${REPO_SLUG}-${NUMBER}-${TS}.json"
    rm -f "$TRIAGE_FILE"

    local TITLE_SAFE="${TITLE//|/\\|}"
    local TRIAGE_PROMPT
    TRIAGE_PROMPT=$(sed \
      -e "s|{{NUMBER}}|${NUMBER}|g" \
      -e "s|{{TITLE}}|${TITLE_SAFE}|g" \
      -e "s|{{URL}}|${URL}|g" \
      -e "s|{{FILE}}|${TRIAGE_FILE}|g" \
      "$TRIAGE_TEMPLATE")

    echo "--- Triage 実行 ---" >> "$LOG"
    # Issue #66: Quota-Aware Watcher 経由で Codex を起動。opt-out 時は素通し
    # （既存挙動互換）、opt-in 時は rate_limit_event 検知で exit 99 を返す。
    local _qa_reset_file_triage="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-triage-${TS}"
    local _qa_rc_triage=0
    qa_run_codex_stage "Triage" "$_qa_reset_file_triage" -- \
      codex_exec_prompt "Triage" "$TRIAGE_MODEL" "$TRIAGE_PROMPT" \
        >> "$LOG" 2>&1 || _qa_rc_triage=$?
    case "$_qa_rc_triage" in
      0)
        : # 正常終了 → 後続処理へ
        ;;
      99)
        # quota 超過検出（opt-in 時のみ発生）→ codex-needs-quota-wait に遷移し、
        # _slot_mark_failed を踏まずに正常終了する（Req 3.1, 3.2）
        local _qa_epoch_triage
        _qa_epoch_triage=$(cat "$_qa_reset_file_triage")
        qa_handle_quota_exceeded "$NUMBER" "Triage" "$_qa_epoch_triage"
        rm -f "$_qa_reset_file_triage"
        slot_log "Triage で quota 超過検出 → codex-needs-quota-wait に遷移"
        return 0
        ;;
      *)
        rm -f "$_qa_reset_file_triage"
        echo "❌ Triage の実行に失敗" | tee -a "$LOG"
        # codex-picked-up は Dispatcher 側で付与済。Triage 失敗時は codex-failed に
        # 遷移して人間判断に委ねる（既存挙動: Triage 失敗時は continue だったが、
        # Phase C ではすでに claim 済のため、ラベルを残置せず codex-failed 化する）。
        _slot_mark_failed "triage" "Triage（Codex 実行）に失敗しました。"
        return 1
        ;;
    esac
    rm -f "$_qa_reset_file_triage"

    if [ ! -f "$TRIAGE_FILE" ]; then
      echo "❌ Triage 結果 JSON が生成されませんでした" | tee -a "$LOG"
      _slot_mark_failed "triage-json" "Triage 結果 JSON が生成されませんでした。"
      return 1
    fi

    local STATUS DECISION_COUNT
    STATUS=$(jq -r '.status' "$TRIAGE_FILE")
    DECISION_COUNT=$(jq '.decisions | length' "$TRIAGE_FILE")
    NEEDS_ARCHITECT=$(jq -r '.needs_architect // false' "$TRIAGE_FILE")
    ARCHITECT_REASON=$(jq -r '.architect_reason // ""' "$TRIAGE_FILE")

    if [ "$STATUS" = "codex-needs-decisions" ] && [ "$DECISION_COUNT" -gt 0 ]; then
      local COMMENT
      COMMENT=$(jq -r '
        "## 🤔 実装着手前に確認が必要な事項\n\n" +
        "Issue 内容を Codex の Product Manager で精査した結果、" +
        "以下の判断は人間に委ねる必要があると判定しました。\n\n" +
        "> " + .rationale + "\n\n" +
        "---\n\n" +
        (.decisions | to_entries | map(
          "### " + ((.key + 1) | tostring) + ". " + .value.topic + "\n\n" +
          "**質問**: " + .value.question + "\n\n" +
          "**選択肢**:\n" +
          (.value.options | map("- " + .) | join("\n")) + "\n\n" +
          "**影響**: " + .value.impact + "\n\n" +
          "**推奨**: " + .value.recommendation + "\n"
        ) | join("\n---\n\n")) +
        "\n\n---\n\n" +
        "## 回答方法\n\n" +
        "1. 各項目についてこの Issue にコメントで回答してください。\n" +
        "2. すべての項目に結論が出たら、この Issue から **`codex-needs-decisions` ラベルを外してください**。\n" +
        "3. ラベルが外れた時点で Codex が自動で再 Triage し、追加論点が無ければ開発に着手します。\n" +
        "4. Triage をスキップして強制着手したい場合は `codex-skip-triage` ラベルを付与してください。"
      ' "$TRIAGE_FILE")

      gh issue comment "$NUMBER" --repo "$REPO" --body "$COMMENT" >/dev/null 2>&1 || true
      # Phase C / Issue #52: claim を取り消す（codex-claimed 除去）+ codex-needs-decisions 付与。
      # 次サイクルで人間が codex-needs-decisions を外したら再ピックアップされる必要があるため、
      # claim 系ラベルを残してはいけない。本機能導入前は codex-picked-up は未付与
      # だったが、Phase C 以降は Dispatcher が claim ラベル（Issue #52 で codex-claimed
      # に分離）を事前に付与しているためここで取り消す。
      gh issue edit "$NUMBER" --repo "$REPO" \
        --remove-label "$LABEL_CLAIMED" \
        --add-label "$LABEL_NEEDS_DECISIONS" >/dev/null 2>&1 || true
      echo "🟡 #$NUMBER: $DECISION_COUNT 件の決定事項を起票しました" | tee -a "$LOG"
      slot_log "Triage 結果: codex-needs-decisions（codex-claimed 取り消し済）"
      return 0
    fi

    if [ "$NEEDS_ARCHITECT" = "true" ]; then
      MODE="design"
      echo "🎨 #$NUMBER: Architect 必要 → design モード（理由: $ARCHITECT_REASON）" | tee -a "$LOG"
    else
      MODE="impl"
      echo "✅ #$NUMBER: Triage 通過（Architect 不要） → impl モード" | tee -a "$LOG"
    fi
  fi

  # ── Issue #52: Triage 通過後のラベル付け替え（codex-claimed → codex-picked-up）──
  # impl / impl-resume モードでは、ここから先「実装フェーズ」に入るため Issue ラベルを
  # codex-picked-up に付け替える。design モードは PjM (design-review) が
  # codex-claimed → codex-awaiting-design-review に直接付け替えるため、ここでは何もしない
  # （Req 8.3 / 設計論点 4 結論: design ルートは codex-picked-up を経由しない）。
  #
  # 単一の PATCH /issues/{n}（--remove-label A --add-label B）で原子的に行うことで
  # NFR 1.2（同時 2 ラベル状態が 5 秒以上続かない）を構造的に満たす。branch 作成より
  # 前に実行するため、後続の長時間操作中はラベル状態が常に正しい。
  if [ "$MODE" = "impl" ] || [ "$MODE" = "impl-resume" ]; then
    if ! gh issue edit "$NUMBER" --repo "$REPO" \
        --remove-label "$LABEL_CLAIMED" \
        --add-label "$LABEL_PICKED" >/dev/null 2>&1; then
      slot_warn "Triage 通過後のラベル付け替えに失敗（codex-claimed → codex-picked-up）"
      _slot_mark_failed "label-handover" "Triage 通過後のラベル付け替え (codex-claimed → codex-picked-up) に失敗しました。"
      return 1
    fi
    slot_log "ラベル付け替え: codex-claimed → codex-picked-up（impl 着手）"
  fi

  # ── ピックアップ表明コメント（claim 表明ラベルは Dispatcher が事前に付与済）──
  gh issue comment "$NUMBER" --repo "$REPO" \
    --body "🤖 ローカル Codex ($(hostname)) が処理を開始しました（slot=${IDD_SLOT_NUMBER} / モード: ${MODE}）。" >/dev/null 2>&1 || true

  # ── ブランチを切る（モードに応じて名前を変える）──
  case "$MODE" in
    design)
      BRANCH="codex/issue-${NUMBER}-design-${SLUG}"
      ;;
    impl|impl-resume)
      BRANCH="codex/issue-${NUMBER}-impl-${SLUG}"
      ;;
  esac
  # impl-resume モードのときだけ Strategy Pattern による branch 初期化に分岐させる
  # （Issue #67）。design / impl モードでは本機能導入前と完全に等価な挙動を維持する
  # （Req 1.1, 1.2, NFR 1.1, NFR 1.2）。`_resume_branch_init` は内部で
  # `IMPL_RESUME_PRESERVE_COMMITS` を見て legacy / preserve 戦略にディスパッチし、
  # 失敗時は `_slot_mark_failed` 既に発射済の状態で非 0 を返す。
  if [ "$MODE" = "impl-resume" ]; then
    if ! _resume_branch_init; then
      return 1
    fi
  else
    # worktree は detached HEAD で起動するため -B で新規 branch 作成
    # （local $BASE_BRANCH を持たない）
    if ! git checkout -B "$BRANCH" "origin/${BASE_BRANCH}"; then
      slot_warn "branch 作成に失敗: $BRANCH"
      _slot_mark_failed "branch-checkout" "ブランチ \`$BRANCH\` の作成に失敗しました。"
      return 1
    fi
    if ! git push -u origin "$BRANCH" --force-with-lease; then
      slot_warn "branch push に失敗: $BRANCH"
      _slot_mark_failed "branch-push" "ブランチ \`$BRANCH\` の push に失敗しました。"
      return 1
    fi
  fi

  # ── モード別ディスパッチ ──
  if [ "$MODE" = "design" ]; then
    # Issue #96 Req 1.5: 設計 PR 作成段階に進む前に BASE_BRANCH 実値が空でないことを検証する
    if ! _assert_base_branch_resolved; then
      echo "❌ #$NUMBER: design 中断（BASE_BRANCH 未解決）→ codex-failed" | tee -a "$LOG"
      _slot_mark_failed "design-base-branch" "解決済み BASE_BRANCH が空文字または未定義のため設計フェーズを中断しました（Issue #96 Req 1.5）。"
      return 1
    fi
    local FLOW_LABEL STEPS DEV_PROMPT
    FLOW_LABEL="PM → Architect → PjM（設計 PR 作成ゲート）"
    STEPS=$(cat <<EOF
1. `.codex/agents/product-manager.md` の役割指示に従い、要件定義を \`${SPEC_DIR_REL}/requirements.md\` に保存
   - Issue 本文と既存コメント（\`gh issue view ${NUMBER} --comments\`）を必ず読む
   - 人間がコメントで回答済みの決定事項は requirements に反映する
2. `.codex/agents/architect.md` の役割指示に従い、設計書とタスク分割を保存
   - Triage 判定理由: ${ARCHITECT_REASON}
   - \`${SPEC_DIR_REL}/design.md\`（モジュール構成・データモデル・公開 IF・処理フロー・リスク）
   - \`${SPEC_DIR_REL}/tasks.md\`（Developer 向けタスク分割、各タスクが独立コミット可能な粒度）
3. `.codex/agents/project-manager.md` の役割指示に従い、**design-review モード**として PR を作成
   - 成果物は ${SPEC_DIR_REL}/ 配下の requirements / design / tasks のみ（実装コードは含めない）
   - title: \`spec(#${NUMBER}): <1 行サマリ>\`
   - **base: \`${BASE_BRANCH}\`** （\`gh pr create --base ${BASE_BRANCH}\` を必ず明示すること。GitHub のデフォルト base に依存しない）
   - Issue ラベル: codex-claimed → codex-awaiting-design-review に付け替え
   - Issue にコメントで設計 PR リンクと案内を投稿

この設計 PR が merge されるまで、実装フェーズには進みません。人間が merge した後、
次回のポーリングで Developer が自動起動し、実装 PR が別途作成されます。
EOF
)

    DEV_PROMPT=$(cat <<EOF
あなたはこのリポジトリの Codex オーケストレーターです。
以下の Issue を ${FLOW_LABEL} のフローで進めてください。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- Body  : |
${BODY}

## 作業ブランチ
${BRANCH}（${BASE_BRANCH} から派生・push 済み・現在チェックアウト中）

## 作業ディレクトリ
${SPEC_DIR_REL}/

## PR の base ブランチ（必ず明示）
解決済み base ブランチ: \`${BASE_BRANCH}\`

Project Manager（design-review モード）は \`gh pr create\` 実行時に
**必ず \`--base ${BASE_BRANCH}\`** を明示してください（GitHub のデフォルト base に依存しないこと）。
これは本サイクル開始時に watcher が \`BASE_BRANCH\` env から解決した実値であり、プレースホルダ
ではありません。PR 作成後は \`gh pr view <PR> --json baseRefName --jq '.baseRefName'\` で
取得した値が \`${BASE_BRANCH}\` と一致することを検証し、結果（一致 / 不一致 / 修正実施の有無）を
PR 本文の「確認事項」または Issue コメントに 1 行記載してください。不一致時は
\`gh pr edit <PR> --base ${BASE_BRANCH}\` で修正するか、修正不能なら PR 作成失敗扱いとして
Issue に状況を報告してください。

## 進め方
${STEPS}

## 制約
- ${BASE_BRANCH} に直接 push しないこと
- **\`gh pr create\` の \`--base\` を省略しないこと**（GitHub default に依存すると本リポジトリの
  \`BASE_BRANCH\` 設定と乖離する事故が起きる。Issue #96）
- 既存のテストを壊さないこと
- 不明点は推測せず、PR 本文の「確認事項」セクションに列挙すること
EOF
)

    echo "--- Development 実行（$MODE）---" >> "$LOG"
    # Issue #66: Quota-Aware Watcher 経由で Codex を起動
    local _qa_reset_file_design _qa_rc_design=0 _qa_ts_design
    _qa_ts_design=$(date +%Y%m%d-%H%M%S)
    _qa_reset_file_design="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-design-${_qa_ts_design}"
    qa_run_codex_stage "design" "$_qa_reset_file_design" -- \
      codex_exec_prompt "design" "$DEV_MODEL" "$DEV_PROMPT" \
        >> "$LOG" 2>&1 || _qa_rc_design=$?
    case "$_qa_rc_design" in
      0)
        echo "✅ #$NUMBER: $MODE 完了" | tee -a "$LOG"
        slot_log "$MODE 完了"
        rm -f "$_qa_reset_file_design"
        return 0
        ;;
      99)
        local _qa_epoch_design
        _qa_epoch_design=$(cat "$_qa_reset_file_design")
        qa_handle_quota_exceeded "$NUMBER" "design" "$_qa_epoch_design"
        rm -f "$_qa_reset_file_design"
        slot_log "$MODE で quota 超過検出 → codex-needs-quota-wait に遷移"
        return 0
        ;;
      *)
        rm -f "$_qa_reset_file_design"
        echo "❌ #$NUMBER: $MODE 失敗" | tee -a "$LOG"
        _slot_mark_failed "$MODE" "design モードでの Codex 実行が失敗しました。"
        return 1
        ;;
    esac
  else
    # impl / impl-resume → Reviewer ゲートを含む stage 分割パイプラインへ
    if run_impl_pipeline; then
      echo "✅ #$NUMBER: $MODE 完了（Reviewer ゲート通過 / PR 作成済み）" | tee -a "$LOG"
      slot_log "$MODE 完了（PR 作成済み）"
      return 0
    else
      echo "❌ #$NUMBER: $MODE 失敗（codex-failed 付与済み）" | tee -a "$LOG"
      slot_log "$MODE 失敗（codex-failed 付与済み）"
      return 1
    fi
  fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase C: Dispatcher
#
# 1 サイクル中に 1 度起動される。Issue 候補をローカルキューに pop し、空き slot を
# 探索して claim（codex-claimed ラベル付与）してから Slot Runner をバックグラウンド
# 起動する。サイクル終端で `wait` により全 Worker 完了を待ち合わせる。
# claim ラベルは Issue #52 で codex-picked-up → codex-claimed に変更した
# （claim/Triage 段階を実装中段階と区別するため）。Triage 通過後の Slot Runner で
# codex-claimed → codex-picked-up に付け替える。
#
# Req 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 6.3, 6.4, 6.5, 7.5, NFR 1.1, NFR 1.2
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Dispatcher が抱える slot_n -> PID マッピング（bash associative array, 4.0+）。
# サブシェル fork 後、_slot_release で fd を閉じてもこの map で「どの slot が誰の
# 子プロセスか」を後で再特定できる。
declare -A _DISPATCHER_SLOT_PIDS

# 完了した子プロセスを slot_pid map から prune する。
# `kill -0 <pid>` が失敗（プロセス不在）なら slot は空いたとみなす。
_dispatcher_reap_finished_slots() {
  local n pid
  for n in "${!_DISPATCHER_SLOT_PIDS[@]}"; do
    pid="${_DISPATCHER_SLOT_PIDS[$n]}"
    if [ -z "$pid" ]; then
      unset '_DISPATCHER_SLOT_PIDS['"$n"']'
      continue
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      # 子プロセス終了済 → slot 解放
      wait "$pid" 2>/dev/null || true
      unset '_DISPATCHER_SLOT_PIDS['"$n"']'
      dispatcher_log "slot-${n}: completed (pid=$pid)"
    fi
  done
}

# 空き slot を探す（reap → 1..PARALLEL_SLOTS で _slot_acquire）。
# 戻り値: 0 = 取得成功（slot 番号を stdout に echo） / 1 = 全 slot busy
_dispatcher_find_free_slot() {
  _dispatcher_reap_finished_slots
  local n
  for ((n=1; n<=PARALLEL_SLOTS; n++)); do
    # 既に PID マップに載っている slot は busy
    if [ -n "${_DISPATCHER_SLOT_PIDS[$n]:-}" ]; then
      continue
    fi
    if _slot_acquire "$n"; then
      echo "$n"
      return 0
    fi
  done
  return 1
}

# 1 サイクル分の Dispatcher を実行する。
# 戻り値: 0 = 正常完了（個々の Worker の成否は Issue ラベル経由で表現）/ 非ゼロ = 致命的失敗
_dispatcher_run() {
  # Req 1.3: PARALLEL_SLOTS 検証 → 不正なら ERROR ログ + exit 1
  if ! _parallel_validate_slots; then
    return 1
  fi

  # Req 7.5: 既存の Issue 取得クエリ（フィルタ・limit 5）を据え置き
  # Issue #54 Req 1.1 / 1.3 / 5.2: PR 専用ラベル `codex-needs-iteration` が誤って Issue 側に
  # 付与されているケースを除外する（人為ミスでの impl-resume 起動 → 既存 PR 破壊事故防止）。
  # Issue #66 Req 3.5 / 3.6: quota wait 中の Issue は再 claim しないよう
  # `codex-needs-quota-wait` を除外条件に追加。既存除外条件の意味・順序は変更しない。
  # Issue #100 Req 2.1: multi-branch 運用で develop に merge 済み・main 到達待ちの
  # Issue（`codex-staged-for-release` 付与）を Triage / Dispatcher / PR Iteration が誤って
  # 再 pickup しないよう除外する。single-branch 運用では本ラベルは付与されない想定なので
  # 影響なし（NFR 1.2: 既存除外条件の意味・順序は変更しない）。
  local issues
  issues=$(gh issue list \
    --repo "$REPO" \
    --label "$LABEL_TRIGGER" \
    --state open \
    --search "-label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_AWAITING_DESIGN\" -label:\"$LABEL_CLAIMED\" -label:\"$LABEL_PICKED\" -label:\"$LABEL_READY\" -label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_ITERATION\" -label:\"$LABEL_NEEDS_QUOTA_WAIT\" -label:\"$LABEL_STAGED_FOR_RELEASE\"" \
    --json number,title,body,url,labels \
    --limit 5)

  local count
  count=$(echo "$issues" | jq 'length')
  if [ "$count" -eq 0 ]; then
    # Req 1.4 / 7.6: PARALLEL_SLOTS=1 + 対象なし時の挙動を本機能導入前と同等に保つ。
    # （prefix dispatcher: は付くが、メッセージ本体は既存と同じ）
    echo "[$(date '+%F %T')] 処理対象の Issue なし"
    return 0
  fi

  # Req 6.3: サイクル開始ログ（処理対象件数 + 利用可能 slot 数）
  dispatcher_log "対象 Issue ${count} 件 / 利用可能 slot ${PARALLEL_SLOTS} 件"

  # Req 1.4 互換のため、PARALLEL_SLOTS=1 のときも従来と同じ（prefix なし）件数 echo を出す。
  # 既存ユーザー / cron の grep 監視を破壊しない（"N 件の Issue を処理します" 行）。
  if [ "$PARALLEL_SLOTS" -eq 1 ]; then
    echo "[$(date '+%F %T')] $count 件の Issue を処理します"
  fi

  # Issue キューを 1 件ずつ pop して slot に投入
  local issue
  while IFS= read -r issue; do
    [ -z "$issue" ] && continue
    local issue_number
    issue_number=$(echo "$issue" | jq -r '.number')

    # ── Pre-Claim Filter (Issue #65 Req 1.1〜1.7) ──
    # claim 直前に linked impl PR を GraphQL で確認し、OPEN/MERGED が存在すれば
    # 当該サイクルを skip する。claim ラベル（codex-claimed）を一切付与しないため、
    # 次サイクル以降の `gh issue list` フィルタからも除外されず、人間が PR を解消
    # するか `codex-auto-dev` を外すまで本 Issue を触らない（事故防止 / Req 1.2 / 1.3）。
    # check_existing_impl_pr 内で skip 判定行は pclp_log/warn で記録済み（NFR 2.1〜2.3）。
    # GraphQL 失敗 / レート制限も内部で skip 側に倒される（fail-safe / Req 1.7 / NFR 4.2）。
    # PR 不在の通常運用では exit 0 で素通り = 本機能導入前と完全等価（NFR 1.5）。
    if ! check_existing_impl_pr "$issue_number"; then
      continue
    fi

    # ── 空き slot 探索（busy なら 1 件完了するまで待機）──
    local slot=""
    while true; do
      if slot=$(_dispatcher_find_free_slot); then
        break
      fi
      # 全 slot busy → 1 件完了を待つ（bash 4.3+ の `wait -n`）
      if [ "${#_DISPATCHER_SLOT_PIDS[@]}" -eq 0 ]; then
        # 子プロセス未起動かつ全 slot 取得失敗 → 取れる slot がない異常事態
        # （他 watcher プロセスが slot lock を握っているなど）
        dispatcher_warn "全 slot がロック中（_slot_acquire いずれも失敗）。Issue #${issue_number} は次サイクルへ持ち越し"
        slot=""
        break
      fi
      wait -n 2>/dev/null || true
      _dispatcher_reap_finished_slots
    done

    if [ -z "$slot" ]; then
      continue
    fi

    # ── claim（codex-claimed ラベル付与）──
    # Issue #52: claim/Triage 段階のラベルを codex-claimed に分離（codex-picked-up は
    # Triage 通過後に Slot Runner が付け替える）。これにより Issue activity 上で
    # claim 済 / Triage 中 / 実装中 が 1 ラベル単位で識別可能になる。
    if ! gh issue edit "$issue_number" --repo "$REPO" --add-label "$LABEL_CLAIMED" >/dev/null 2>&1; then
      # Req 2.3: ラベル付与失敗 → WARN + slot lock 解放 + 次 Issue へ
      dispatcher_warn "Issue #${issue_number}: codex-claimed ラベル付与に失敗、slot-${slot} を解放して次 Issue へ"
      _slot_release "$slot"
      continue
    fi

    # Req 6.4: 投入時刻ログ
    dispatcher_log "dispatched #${issue_number} -> slot-${slot}"

    # ── Slot Runner をバックグラウンド起動 ──
    # サブシェル `( ... ) &` で fork。サブシェルは親の fd を継承するため
    # _slot_acquire で取得した lock fd は subshell が引き続き保持する。
    ( _slot_run_issue "$slot" "$issue" ) &
    local pid=$!
    _DISPATCHER_SLOT_PIDS[$slot]=$pid

    # 親 Dispatcher 側の fd を解放する。これにより、Dispatcher が同 slot を再
    # acquire しようとしたとき、subshell が lock を保持している間は flock -n が
    # 失敗するようになる（claim atomicity の構造的保証）。
    _slot_release "$slot"
  done <<< "$(echo "$issues" | jq -c '.[]')"

  # Req 2.6: サイクル終端で全 Worker を待ち合わせる
  # Slot Runner 内で codex-failed 化等は完結済のため exit code は無視
  if [ "${#_DISPATCHER_SLOT_PIDS[@]}" -gt 0 ]; then
    dispatcher_log "全 Worker 完了を待機中 (${#_DISPATCHER_SLOT_PIDS[@]} 件 in flight)"
    wait
    _dispatcher_reap_finished_slots
  fi

  dispatcher_log "サイクル完了"
  return 0
}

# Dispatcher を起動（既存 Issue 処理ループの置換）。
_dispatcher_run
DISPATCHER_RC=$?
if [ "$DISPATCHER_RC" -ne 0 ]; then
  # Req 1.3: PARALLEL_SLOTS 不正値などで _dispatcher_run が non-zero を返した場合は
  # サイクル中断（既存の ERROR 終了規約 = exit 1 と整合）
  exit "$DISPATCHER_RC"
fi

echo "[$(date '+%F %T')] 完了"
exit 0
