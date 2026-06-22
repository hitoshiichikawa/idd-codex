#!/usr/bin/env bash
# core_utils.sh — watcher の低レベル共通ユーティリティモジュール
#
# 用途:
#   idd-codex-issue-watcher.sh から切り出した低レベル共通ユーティリティを集約する。
#   - processor 系の低レベルロガー（qa_log / mq_log / ar_log / pp_log / pi_log / drr_log 系）
#   - 日付フォーマット取得（qa_format_iso8601）
#   - per-slot git worktree 管理（_worktree_path / _worktree_is_registered /
#     _worktree_ensure / _worktree_reset / _worktree_inject_codex）
#   - per-slot 非ブロッキング flock 管理（_slot_lock_path / _slot_acquire / _slot_release）
#   - SLOT_INIT_HOOK 起動 wrapper（_hook_invoke）
#
# 配置先:
#   $HOME/bin/idd-codex-modules/core_utils.sh（install.sh が local-watcher/bin/idd-codex-modules/ から配置する）
#
# 依存:
#   - 本モジュールは idd-codex-issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$REPO / $REPO_DIR / $BASE_BRANCH / $WORKTREE_BASE_DIR / $REPO_SLUG /
#     $SLOT_LOCK_DIR / $PARALLEL_SLOTS / ${SLOT_INIT_HOOK}）は本体冒頭で定義済み。
#   - worktree / slot ユーティリティ内の dispatcher_log / dispatcher_warn は本体に残る関数への
#     前方参照（bash の遅延評価により呼び出し時＝source 完了後に解決される）。
#   - 外部 CLI: date / git / flock / mktemp / tail。
#
# セットアップ参照先:
#   README.md（ディレクトリ構成・modules 化 migration note） / install.sh（配置ロジック）

# quota-aware 専用ロガー（既存 mq_log / pi_log と同形式 / NFR 1.1, 1.2）
# Issue #119 Req 1.5 / 1.6 / NFR 2.2: 時刻 prefix と processor prefix の間に
# `[$REPO]` を 1 つだけ挿入し、複数リポ運用時に `grep "\[owner/name\]"` で
# 該当 repo のサイクル全行を抽出できるようにする。`[$REPO]` 以外のフォーマット
# は本要件導入前と完全に同一（Req 2.4）。
qa_log() {
  echo "[$(date '+%F %T')] [$REPO] quota-aware: $*"
}
qa_warn() {
  echo "[$(date '+%F %T')] [$REPO] quota-aware: WARN: $*" >&2
}
qa_error() {
  echo "[$(date '+%F %T')] [$REPO] quota-aware: ERROR: $*" >&2
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

# merge-queue 専用ロガー（識別用 prefix と timestamp 形式を Issue Watcher と揃える）
# Issue #119 Req 1.2 / 1.6: 時刻 prefix と processor prefix の間に `[$REPO]` を挿入。
mq_log() {
  echo "[$(date '+%F %T')] [$REPO] merge-queue: $*"
}
mq_warn() {
  echo "[$(date '+%F %T')] [$REPO] merge-queue: WARN: $*" >&2
}
mq_error() {
  echo "[$(date '+%F %T')] [$REPO] merge-queue: ERROR: $*" >&2
}

# auto-rebase 専用ロガー（Phase A `mq_log` と同一の `[$REPO]` 3 段 prefix）。
# Issue #119 Req 1.x: 時刻 prefix と processor prefix の間に `[$REPO]` を挿入。
ar_log() {
  echo "[$(date '+%F %T')] [$REPO] auto-rebase: $*"
}
ar_warn() {
  echo "[$(date '+%F %T')] [$REPO] auto-rebase: WARN: $*" >&2
}
ar_error() {
  echo "[$(date '+%F %T')] [$REPO] auto-rebase: ERROR: $*" >&2
}

# auto-merge 専用ロガー（#99 / `mq_log` と同一の `[$REPO]` 3 段 prefix）。
am_log() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge: $*"
}
am_warn() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge: WARN: $*" >&2
}
am_error() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge: ERROR: $*" >&2
}

# design auto-merge 専用ロガー（#100 / `am_log` と同一書式）。
amd_log() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge-design: $*"
}
amd_warn() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge-design: WARN: $*" >&2
}
amd_error() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge-design: ERROR: $*" >&2
}

# promote-pipeline 専用ロガー（Phase A `mq_log` と同一の書式：
# `[YYYY-MM-DD HH:MM:SS] [$REPO] promote-pipeline:` prefix。Req 5.1.1, 5.1.5）。
pp_log() {
  echo "[$(date '+%F %T')] [$REPO] promote-pipeline: $*"
}
pp_warn() {
  echo "[$(date '+%F %T')] [$REPO] promote-pipeline: WARN: $*" >&2
}
pp_error() {
  echo "[$(date '+%F %T')] [$REPO] promote-pipeline: ERROR: $*" >&2
}

# pr-iteration 専用ロガー（識別用 prefix と timestamp 形式を Issue Watcher と揃える）
# Issue #119 Req 1.1 / 1.6: 時刻 prefix と processor prefix の間に `[$REPO]` を挿入。
pi_log() {
  echo "[$(date '+%F %T')] [$REPO] pr-iteration: $*"
}
pi_warn() {
  echo "[$(date '+%F %T')] [$REPO] pr-iteration: WARN: $*" >&2
}
pi_error() {
  echo "[$(date '+%F %T')] [$REPO] pr-iteration: ERROR: $*" >&2
}

# Issue #119 Req 1.4 / 1.6: 時刻 prefix と processor prefix の間に `[$REPO]` を挿入。
drr_log() {
  echo "[$(date '+%F %T')] [$REPO] design-review-release: $*"
}
drr_warn() {
  echo "[$(date '+%F %T')] [$REPO] design-review-release: WARN: $*" >&2
}
drr_error() {
  echo "[$(date '+%F %T')] [$REPO] design-review-release: ERROR: $*" >&2
}

# pr-reviewer 専用ロガー（識別用 prefix と timestamp 形式を Issue Watcher と揃える）
# Issue #261 Req NFR 3.1: 時刻 prefix と processor prefix の間に `[$REPO]` を挿入。
pr_log() {
  echo "[$(date '+%F %T')] [$REPO] pr-reviewer: $*"
}
pr_warn() {
  echo "[$(date '+%F %T')] [$REPO] pr-reviewer: WARN: $*" >&2
}
pr_error() {
  echo "[$(date '+%F %T')] [$REPO] pr-reviewer: ERROR: $*" >&2
}

# failed-recovery 専用ロガー（識別用 prefix と timestamp 形式を Issue Watcher と揃える）
# Issue #101: 時刻 prefix と processor prefix の間に `[$REPO]` を挿入。
fr_log() {
  echo "[$(date '+%F %T')] [$REPO] failed-recovery: $*"
}
fr_warn() {
  echo "[$(date '+%F %T')] [$REPO] failed-recovery: WARN: $*" >&2
}
fr_error() {
  echo "[$(date '+%F %T')] [$REPO] failed-recovery: ERROR: $*" >&2
}

# needs-decisions-auto 専用ロガー（識別用 prefix と timestamp 形式を Issue Watcher と揃える）
# Issue #102: 時刻 prefix と processor prefix の間に `[$REPO]` を挿入。
nda_log() {
  echo "[$(date '+%F %T')] [$REPO] needs-decisions-auto: $*"
}
nda_warn() {
  echo "[$(date '+%F %T')] [$REPO] needs-decisions-auto: WARN: $*" >&2
}
nda_error() {
  echo "[$(date '+%F %T')] [$REPO] needs-decisions-auto: ERROR: $*" >&2
}

# secure tempfile helper（Issue #52 Req 5）
#
# prompt / JSON / stderr / quota reset state などを置く一時ファイルを、repo ごとに
# 分離済みの private tmp root（既定: $LOG_DIR/tmp）配下へ non-predictable name で
# 作成する。mktemp 失敗時は predictable `/tmp/...-$$` 等へ fallback せず fail closed
# し、呼び出し元が current operation を失敗扱いにできるよう非 0 を返す。
#
# Args:
#   $1 = human-readable label（basename に使う前に safe charset へ正規化）
# Stdout:
#   作成済み tempfile の絶対 path
# Returns:
#   0 = created / 1 = failed（stderr に operator-visible reason）
idd_secure_mktemp() {
  local label="${1:-tmp}"
  local tmp_root="${IDD_CODEX_TMP_DIR:-}"
  if [ -z "$tmp_root" ]; then
    if [ -n "${LOG_DIR:-}" ]; then
      tmp_root="$LOG_DIR/tmp"
    else
      local uid_part="${UID:-}"
      if [ -z "$uid_part" ]; then
        uid_part="$(id -u 2>/dev/null || printf 'unknown')"
      fi
      tmp_root="${TMPDIR:-/tmp}/idd-codex-${uid_part}/tmp"
    fi
  fi

  if [ -L "$tmp_root" ]; then
    echo "secure-tempfile: ERROR: tmp root is a symlink: $tmp_root" >&2
    return 1
  fi
  if [ -e "$tmp_root" ] && [ ! -d "$tmp_root" ]; then
    echo "secure-tempfile: ERROR: tmp root is not a directory: $tmp_root" >&2
    return 1
  fi
  if ! mkdir -p "$tmp_root" 2>/dev/null; then
    echo "secure-tempfile: ERROR: failed to create tmp root: $tmp_root" >&2
    return 1
  fi
  if ! chmod 700 "$tmp_root" 2>/dev/null; then
    echo "secure-tempfile: ERROR: failed to set owner-only mode on tmp root: $tmp_root" >&2
    return 1
  fi

  local mode=""
  if mode=$(stat -c '%a' "$tmp_root" 2>/dev/null); then
    :
  elif mode=$(stat -f '%Lp' "$tmp_root" 2>/dev/null); then
    :
  else
    echo "secure-tempfile: ERROR: failed to inspect tmp root mode: $tmp_root" >&2
    return 1
  fi
  if [ "$mode" != "700" ]; then
    echo "secure-tempfile: ERROR: tmp root is not owner-only mode=0${mode}: $tmp_root" >&2
    return 1
  fi

  local safe_label
  safe_label="$(printf '%s' "$label" | tr -cs 'A-Za-z0-9_.-' '-' | sed -e 's/^-*//' -e 's/-*$//')"
  if [ -z "$safe_label" ]; then
    safe_label="tmp"
  fi

  local tmp_file
  if ! tmp_file=$(umask 077; mktemp "$tmp_root/idd-${safe_label}-XXXXXX" 2>/dev/null); then
    echo "secure-tempfile: ERROR: mktemp failed in private tmp root: $tmp_root" >&2
    return 1
  fi
  chmod 600 "$tmp_file" 2>/dev/null || true
  printf '%s\n' "$tmp_file"
}

# ─── Issue #259: Codex API 529 Overloaded detector ───
#
# Codex API の一時的な過負荷 (HTTP 529 Overloaded) は codex CLI の stream-json
# 出力に Codex API のエラー JSON 断片として現れる。代表的なシグネチャ:
#   - `"api_error_status":529`
#   - `"error_status":529`
#   - `"status":529`（HTTP 5xx の直書き）
#   - `"type":"overloaded_error"`
#   - `"Overloaded"`（人間可読 message）
#
# 設計判断:
#   - false-positive を避けるため、`529` 単独の数値検出はせず、必ず `status[:.]?\s*529`
#     形式（JSON key の隣接）に限定する。
#   - `Overloaded` は API の一般的な過負荷文言と被るため、case-insensitive ではなく
#     大文字 O 始まりの単語境界一致で検出する。
#   - ファイル不在 / 読み取り不能 / 空ファイルは検出なし扱い（後段の警告コメント
#     投稿を抑止して既存挙動を妨げない / Req 1.5 / 2.4 / 4.4）。
#   - 副作用なし（純粋な検査関数）。失敗系含めて呼び出し元の既存処理を継続させる
#     ため、grep が失敗してもエラー伝播させない。
#
# 引数: $1 = 検査対象のログファイルパス
# 戻り値:
#   0 = 529 痕跡を検知（呼び出し元で警告メッセージを付加する）
#   1 = 検知なし（既存メッセージのみ）
#   2 = ファイル不在 / 読み取り不能（検知なし相当として扱うが grep スキップ。
#       呼び出し元はログ可観測性のため 1 と区別したい場合に参照可能）
# 出力: stdout には何も書かない。
#
# Requirements: 1.1, 1.5, 2.1, 2.4, 3.1, 3.2, 4.4, NFR 1.1
codex_log_detect_529() {
  local log_path="${1:-}"
  if [ -z "$log_path" ]; then
    return 2
  fi
  if [ ! -f "$log_path" ] || [ ! -r "$log_path" ]; then
    return 2
  fi
  # 検出パターン群:
  #   - `"api_error_status":529` / `"error_status":529` / `"status":529`
  #     （JSON key の直後 colon ＋ optional whitespace ＋ 529。`status: 529` の plain
  #     text 表記もカバーする）
  #   - `"type":"overloaded_error"` （Anthropic API の標準 error type 文字列）
  #   - 単独の "Overloaded" 単語境界（HTTP 529 の reason phrase）
  # grep 自体は終了コード 1（一致なし）で問題ないため `|| true` で吸収し、
  # set -euo pipefail 配下でも安全に動作するようにする。
  if grep -qE '"(api_error_status|error_status|status)"\s*:\s*529' "$log_path" 2>/dev/null; then
    return 0
  fi
  if grep -qE '\bstatus\s*:\s*529\b' "$log_path" 2>/dev/null; then
    return 0
  fi
  if grep -qE '"type"\s*:\s*"overloaded_error"' "$log_path" 2>/dev/null; then
    return 0
  fi
  if grep -qE '\bOverloaded\b' "$log_path" 2>/dev/null; then
    return 0
  fi
  return 1
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
# Issue #295: root 所有 docker bind-mount 生成物（`frontend/node_modules/` /
# `frontend/.next/` 等）が残った場合、`git clean -fdx` が EACCES で非 0 終了する。
# 旧実装は stderr を `/dev/null` に握り潰しており、失敗理由が SLOT_LOG に残らず
# 無関係な次 Issue に `codex-failed` が付く偽陽性が発生していた。本改修は:
#   - 失敗時 stderr を SLOT_LOG（呼び出し元サブシェルが stderr→tee で SLOT_LOG に
#     合流させているため、stderr を素通しすれば自動的に SLOT_LOG に追記される）に
#     残す（Req 1.1, 1.2, 1.3）。成功時は stdout/stderr とも従来どおり静か（Req 1.4）
#   - `WORKTREE_DOCKER_CLEANUP_ENABLED=true` opt-in 時のみ docker 経路で root 所有
#     artifact を削除する escalation を追加（Req 2 / Req 3）
#   - docker 経路が使えない／失敗した場合は `git worktree remove --force` →
#     `git worktree add --detach` の fallback で worktree を作り直す（Req 4）
#   - 通常ケース（root 所有 artifact なし）は追加処理を起動しない（Req 5.1）
#
# Req 1.1, 1.2, 1.3, 1.4, 3.4, 5.1, 5.2, 5.3, 5.4
_worktree_reset() {
  local wt="$1"
  if [ ! -d "$wt" ]; then
    return 1
  fi
  # NOTE (Issue #167): ここで以前行っていた per-slot の
  #   `git -C "$wt" fetch origin --prune`
  # は削除した。複数 slot worktree は同一 $REPO_DIR の .git オブジェクト DB / refs を
  # 共有するため、PARALLEL_SLOTS>1 で複数 slot がほぼ同時に fetch すると
  # refs/remotes/origin/<branch>.lock / packed-refs.lock の取得競争が起き、
  # 競合に負けた側の fetch が非 0 終了する。set -euo pipefail 下では本関数が失敗扱いと
  # なり、無実の Issue に偽陽性の codex-failed ラベルとエラーコメントが付いていた。
  # origin 参照の最新化は親プロセスがサイクル冒頭（本ファイル冒頭付近の
  # `cd "$REPO_DIR"; git fetch origin --prune`）で 1 回だけ実行済みであり、slot worktree は
  # その origin/$BASE_BRANCH 参照を共有して読むため、per-slot fetch なしでも reset 起点は
  # 確保できる（親 fetch から slot 起動までの遅延による ref stale は許容範囲）。
  #
  # 1. detached HEAD を origin/$BASE_BRANCH に強制移動。
  #    ここを `git reset --hard origin/$BASE_BRANCH` だけで済ませると、前回 Issue の
  #    branch が checkout されたままの slot を再利用した場合に、その branch ref 自体を
  #    base branch へ動かしてしまう。reset 前に必ず detached に戻し、古い Issue branch を
  #    汚染しない（Issue #58）。
  if ! git -C "$wt" checkout --detach --force "origin/${BASE_BRANCH}" >/dev/null; then
    echo "[$(date '+%F %T')] worktree-reset: git checkout --detach failed (wt=$wt, base=origin/${BASE_BRANCH})" >&2
    return 1
  fi

  # 2. origin/$BASE_BRANCH に強制移動。
  #    Issue #295: stderr は SLOT_LOG に残すため `2>/dev/null` を外す（Req 1.1, 1.3）。
  #    成功時 git reset --hard は stderr に書かないため標準出力量は増えない（Req 1.4）。
  if ! git -C "$wt" reset --hard "origin/${BASE_BRANCH}" >/dev/null; then
    echo "[$(date '+%F %T')] worktree-reset: git reset --hard failed (wt=$wt)" >&2
    return 1
  fi

  # 3. untracked + ignored を消去（前回 Issue の build artifact / node_modules を残さない）。
  #    EACCES 起因の失敗を検出して escalated cleanup に分岐するため、stderr を tmp file に
  #    キャプチャしてから内容を SLOT_LOG（>&2 経由）にも転写する。
  local clean_stderr=""
  if ! clean_stderr="$(idd_secure_mktemp "worktree-reset-clean-stderr")"; then
    echo "[$(date '+%F %T')] worktree-reset: ERROR: secure stderr tempfile creation failed (wt=$wt)" >&2
    return 1
  fi
  local clean_rc=0
  git -C "$wt" clean -fdx >/dev/null 2>"$clean_stderr" || clean_rc=$?

  if [ "$clean_rc" -eq 0 ]; then
    # 成功パス: tmp file が空である前提（git clean は成功時 stderr に書かない）。
    # ただし fail-safe で tmp file が非空の場合は SLOT_LOG に転写しておく。
    if [ -n "$clean_stderr" ] && [ -s "$clean_stderr" ]; then
      cat "$clean_stderr" >&2 || true
    fi
    if [ -n "$clean_stderr" ]; then
      rm -f "$clean_stderr" 2>/dev/null || true
    fi
    return 0
  fi

  # 失敗パス: stderr を SLOT_LOG（>&2）に転写（Req 1.2, 1.3）。
  if [ -n "$clean_stderr" ] && [ -s "$clean_stderr" ]; then
    echo "[$(date '+%F %T')] worktree-reset: git clean -fdx failed (wt=$wt, rc=$clean_rc):" >&2
    cat "$clean_stderr" >&2 || true
  else
    echo "[$(date '+%F %T')] worktree-reset: git clean -fdx failed (wt=$wt, rc=$clean_rc, no stderr captured)" >&2
  fi

  # EACCES / permission 起因か判定（Req 3.1, 3.5）。
  # tmp file が無い／読めない場合は permission 失敗とは判定できないため従来どおり return 1。
  local is_perm_fail=0
  if [ -n "$clean_stderr" ] && [ -s "$clean_stderr" ]; then
    if grep -qE 'EACCES|[Pp]ermission denied|Operation not permitted' "$clean_stderr" 2>/dev/null; then
      is_perm_fail=1
    fi
  fi
  if [ -n "$clean_stderr" ]; then
    rm -f "$clean_stderr" 2>/dev/null || true
  fi

  if [ "$is_perm_fail" -ne 1 ]; then
    # permission 起因でなければ従来どおり非 0 終了（Req 3.5）。
    return 1
  fi

  echo "[$(date '+%F %T')] worktree-reset: permission-denied detected, starting escalated cleanup (wt=$wt)" >&2

  # 3. Docker 経路（opt-in / Req 2 / Req 3.2）。
  #    `WORKTREE_DOCKER_CLEANUP_ENABLED=true`（lowercase 完全一致のみ有効 / NFR 4.1）
  #    かつ docker コマンドが利用可能なときのみ起動。
  #    成功時は再度 reset を試みて、なお失敗なら worktree 再作成 fallback に進む。
  if [ "${WORKTREE_DOCKER_CLEANUP_ENABLED:-false}" = "true" ]; then
    if command -v docker >/dev/null 2>&1; then
      if _worktree_reset_docker_cleanup "$wt"; then
        # docker cleanup 成功 → 通常パスで再度 reset + clean を試行。
        # ここでの stderr も SLOT_LOG に流す（>/dev/null だけで stderr は素通し）。
        if git -C "$wt" reset --hard "origin/${BASE_BRANCH}" >/dev/null \
          && git -C "$wt" clean -fdx >/dev/null; then
          echo "[$(date '+%F %T')] worktree-reset: docker cleanup + retry reset 成功 (wt=$wt)" >&2
          return 0
        fi
        echo "[$(date '+%F %T')] worktree-reset: docker cleanup 後の reset/clean が再度失敗 (wt=$wt)" >&2
      else
        echo "[$(date '+%F %T')] worktree-reset: docker cleanup 試行が失敗 (wt=$wt)" >&2
      fi
    else
      echo "[$(date '+%F %T')] worktree-reset: WORKTREE_DOCKER_CLEANUP_ENABLED=true だが docker コマンド未検出、fallback へ (wt=$wt)" >&2
    fi
  else
    echo "[$(date '+%F %T')] worktree-reset: WORKTREE_DOCKER_CLEANUP_ENABLED=true 未宣言、docker 経路 skip して fallback へ (wt=$wt)" >&2
  fi

  # 4. worktree 再作成 fallback（Req 4）。
  if _worktree_reset_recreate "$wt"; then
    echo "[$(date '+%F %T')] worktree-reset: worktree 再作成 fallback で復旧 (wt=$wt)" >&2
    return 0
  fi
  echo "[$(date '+%F %T')] worktree-reset: ERROR: escalated cleanup 全経路が失敗 (wt=$wt) — _worktree_reset を非 0 終了" >&2
  return 1
}

# `WORKTREE_DOCKER_CLEANUP_ENABLED=true` の opt-in 時に呼ばれる docker 経路。
# 一時的な busybox コンテナを `--rm` で起動し、worktree 配下の root 所有 artifact を削除する。
#
# 引数: $1 = worktree 絶対パス
# 戻り値: 0 = cleanup 成功 / 1 = 失敗（docker 起動失敗 / コンテナ rm 失敗）
# 副作用: docker pull が発生し得る（ローカルキャッシュに無い場合）。
#
# 設計判断:
#   - イメージは `busybox` をデフォルトとし、`WORKTREE_DOCKER_CLEANUP_IMAGE` で差し替え可
#     （airgap 環境 / 社内 registry 利用向け）。
#   - bind-mount で worktree の `.` を `/wt` に mount し、worktree の `.git` を巻き込まない
#     よう `.git` 自体は除外して `find /wt -mindepth 1 -maxdepth 1` 列挙で削る。
#   - host の uid/gid は与えない（コンテナは root として動かして root 所有 artifact を消す
#     ことが目的）。
#   - コンテナのネットワークは不要なので `--network=none` を付ける。
#
# Req 2.4, 3.2, 3.3
_worktree_reset_docker_cleanup() {
  local wt="$1"
  local image="${WORKTREE_DOCKER_CLEANUP_IMAGE:-busybox}"
  # `.git` ディレクトリ／ファイル（worktree の場合は file pointer）は絶対に消さない。
  # それ以外の最上位エントリを列挙してすべて rm -rf する。
  # `sh -c` のスクリプトは固定文字列で組み立て、worktree パスは bind-mount に閉じ込めて
  # シェル展開させない（NFR 2.3 / 安全性）。
  # stdout/stderr とも素通しして SLOT_LOG（呼び出し元サブシェルが tee）に流す。
  if ! docker run --rm --network=none \
    -v "$wt":/wt \
    "$image" \
    sh -c 'set -e; cd /wt && find . -mindepth 1 -maxdepth 1 ! -name ".git" -exec rm -rf {} +'; then
    return 1
  fi
  return 0
}

# Docker cleanup が利用不可／失敗したときの最終 fallback として、worktree を作り直す
# （Req 4）。
#
# 引数: $1 = worktree 絶対パス
# 戻り値: 0 = 再作成成功 / 1 = 失敗
# 副作用: `git worktree remove --force` で git 側登録解除 → 既存 dir を rm（root 所有
#   artifact が残っていれば rm も EACCES で失敗し得るが、その場合は明示的に return 1）
#   → `git worktree add --detach <wt> origin/$BASE_BRANCH` で再登録。
#
# Req 4.1, 4.2, 4.3, 4.4, 4.5
_worktree_reset_recreate() {
  local wt="$1"
  echo "[$(date '+%F %T')] worktree-reset: 再作成 fallback 開始 (wt=$wt)" >&2

  # git worktree remove --force（git 側の登録解除）。
  # 既存登録が無くても `git worktree prune` で吸収できるよう、失敗は warn 扱い。
  if ! git -C "$REPO_DIR" worktree remove --force "$wt" >/dev/null 2>&1; then
    echo "[$(date '+%F %T')] worktree-reset: git worktree remove --force が失敗（既存未登録の可能性、prune で継続） (wt=$wt)" >&2
    git -C "$REPO_DIR" worktree prune >/dev/null 2>&1 || true
  fi

  # 残存 dir を rm -rf。root 所有 artifact が残っているとここも EACCES で失敗するため、
  # 失敗時は明示エラーで return 1（Req 4.4）。stderr は呼び出し元サブシェルが SLOT_LOG に
  # tee しているため素通しで OK。
  if [ -e "$wt" ]; then
    if ! rm -rf "$wt"; then
      echo "[$(date '+%F %T')] worktree-reset: ERROR: 既存 worktree dir の rm に失敗（root 所有残存の可能性） (wt=$wt)" >&2
      return 1
    fi
  fi

  # worktree を再登録（origin/$BASE_BRANCH から detached HEAD）。
  if ! git -C "$REPO_DIR" worktree add --detach "$wt" "origin/${BASE_BRANCH}" >/dev/null; then
    echo "[$(date '+%F %T')] worktree-reset: ERROR: git worktree add 再作成に失敗 (wt=$wt)" >&2
    return 1
  fi
  echo "[$(date '+%F %T')] worktree-reset: 再作成 fallback 完了 (wt=$wt, base=origin/${BASE_BRANCH})" >&2
  return 0
}

# gitignore 運用 repo 向けに、worktree reset 直後の slot worktree へ
# REPO_DIR のローカル `.codex/` を注入する（Issue #237）。
#
# 背景:
#   `.codex/` を gitignore して足場を public repo に出さない運用 repo では、
#   `.codex/` が commit されないため _worktree_reset の `git reset --hard` +
#   `git clean -fdx` 後の worktree に `.codex/agents` `.codex/rules` が現れず、
#   agent がルール・定義を読めない degraded 状態になる。本関数は reset 完了後・
#   agent 起動前のタイミングで REPO_DIR（install.sh が `.codex/` を最新化した
#   ローカルクローン）から worktree へ `.codex/` をコピーして健全化する。
#
# 採用方式: auto-detect（worktree に `.codex/` が無い場合のみ注入）。
#   - tracked 運用 repo は `.codex/` が commit 済み → reset 後 worktree に必ず
#     存在 → 注入は走らず NO-OP（Req 2.1 / 2.3）。env gate を持たないが、
#     auto-detect により tracked 運用 repo の挙動は外形的に不変（Req 2.4）。
#   - これはローカルファイルコピーであり外部サービス呼び出しではないため、
#     opt-in gate は不要（AGENTS.md「opt-in gate なしで新しい外部サービス
#     呼び出しを有効化」禁止事項の対象外）。
#
# 引数:
#   $1 = 注入元 REPO_DIR（_slot_run_issue で REPO_DIR が worktree へ上書きされる
#        前に捕捉した元の REPO_DIR）
#   $2 = 注入先 worktree 絶対パス
# 戻り値: 常に 0（fail-open。注入失敗で _slot_run_issue を倒さない / Req 3.2, 3.3）
# 副作用: 条件成立時に $2/.codex を $1/.codex の内容で作成する（commit はしない）
#
# worktree の最終 scaffolding 状態を run サマリへ記録する薄いヘルパ（Issue #239）。
#
# `_worktree_inject_codex` の各 return パス直前で呼び、worktree に
# `.codex/agents` `.codex/rules` の両 dir が実体として揃っているかを判定して
# `rs_set_scaffolding ok|missing` を記録する。注入元 `.codex/` 不在 / cp 失敗の
# rm 後はどちらも両 dir 不在 → missing、tracked 運用 / cp 成功は実体を見て判定する。
#
# 引数:
#   $1 = 判定対象 worktree 絶対パス
# 戻り値: 常に 0（fail-open。記録失敗で _worktree_inject_codex / _slot_run_issue を
#         倒さない / NFR 4.1）
# 副作用: rs_set_scaffolding による run サマリ用状態変数代入のみ（標準出力に何も足さない）
#
# Req 5.1, 5.2, 5.3, NFR 1.2, NFR 4.1
_worktree_record_scaffolding() {
  local wt="$1"
  # run-summary.sh 未 source の文脈でも注入処理を倒さない fail-open ガード（NFR 4.1）。
  command -v rs_set_scaffolding >/dev/null 2>&1 || return 0
  if [ -d "$wt/.codex/agents" ] && [ -d "$wt/.codex/rules" ]; then
    rs_set_scaffolding ok || true
  else
    rs_set_scaffolding missing || true
  fi
  return 0
}

# Req 1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 2.3, 2.4, 3.1, 3.2, 3.3, 4.1, 4.2, 4.3, 4.4, NFR 3.1
_worktree_inject_codex() {
  local src_repo_dir="$1"
  local wt="$2"

  # NO-OP 条件 1（Req 2.1）: worktree に既に `.codex/` がある = tracked 運用 repo。
  # 上書きせず即 return（auto-detect による既存挙動非変更 / 冪等性 Req 4.1 も担保）。
  if [ -e "$wt/.codex" ]; then
    _worktree_record_scaffolding "$wt"
    return 0
  fi
  # NO-OP 条件 2（Req 2.2）: 注入元 REPO_DIR に `.codex/` が無い → 何もしない。
  if [ ! -d "$src_repo_dir/.codex" ]; then
    _worktree_record_scaffolding "$wt"
    return 0
  fi

  # `.codex/` のみをコピーする（Req 4.2 / 4.4: 他 tracked / untracked ファイルや
  # `.github/scripts/idd-codex-labels.sh` を巻き込まない）。
  # `cp -a` で mode / timestamps / symlink を保持（Req 4 / rsync は依存 CLI 保証外）。
  if cp -a "$src_repo_dir/.codex" "$wt/" 2>/dev/null; then
    slot_log ".codex を REPO_DIR から worktree へ注入 (src=$src_repo_dir/.codex)"
    _worktree_record_scaffolding "$wt"
    return 0
  fi

  # fail-open（Req 3.1, 3.2, 3.3）: コピー失敗時は warn のみ出して継続する。
  # 中途半端にコピーされた `.codex/` が残ると次回 auto-detect が NO-OP 化して
  # 不完全状態を温存しうるため、ベストエフォートで除去してから継続する。
  rm -rf "$wt/.codex" 2>/dev/null || true
  slot_warn ".codex の注入に失敗しました（継続します / src=$src_repo_dir/.codex）"
  _worktree_record_scaffolding "$wt"
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
  if ! stderr_tmp="$(idd_secure_mktemp "slot-init-hook-stderr")"; then
    echo "[$(date '+%F %T')] slot-${n}: ERROR: secure stderr tempfile creation failed" >&2
    return 1
  fi
  local rc=0

  # IDD_SLOT_NUMBER / IDD_SLOT_WORKTREE / PARALLEL_SLOTS / REPO / REPO_DIR を export
  # して子プロセスに引き継ぐ。直接 exec のみ（Req 5.5: shell 展開なし）。
  #
  # Issue #170 Req 1.2: stderr 捕捉は同期リダイレクト `2>"$stderr_tmp"` で行う。
  # 旧実装の非同期プロセス置換 `2> >(tee -a "$stderr_tmp" >&2)` は、フック終了直後の
  # `tail -c 2000` 読み出しと tee の flush の間にレースを生じ、失敗ログ末尾が欠落
  # しうる。同期リダイレクトでフック終了時に一時ファイルが確定したのち、Req 1.4 を
  # 満たすため `cat "$stderr_tmp" >&2` で stderr を従来どおり運用者へ流す。
  IDD_SLOT_NUMBER="$n" \
    IDD_SLOT_WORKTREE="$wt" \
    PARALLEL_SLOTS="$PARALLEL_SLOTS" \
    REPO="$REPO" \
    REPO_DIR="$REPO_DIR" \
    "$SLOT_INIT_HOOK" 2>"$stderr_tmp" || rc=$?
  # フック終了後（一時ファイル確定後）に同期で stderr へ転記する。
  # `set -euo pipefail` 下で cat 失敗が誤って _hook_invoke を致命化しないよう
  # `|| true` でガードする（Req 1.4: stderr 観測性維持 / NFR 3.1）。
  if [ -s "$stderr_tmp" ]; then
    cat "$stderr_tmp" >&2 || true
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
