#!/usr/bin/env bash
# auto-rebase.sh — watcher の Auto Rebase 制御プロセッサモジュール
#
# 用途:
#   idd-codex-issue-watcher.sh から切り出した、コンフリクトした approved PR の自動 Rebase
#   プロセッサ（Phase D / #17）を集約する。
#   `codex-needs-rebase` + approved な open PR を Codex 経由で rebase し、変更ファイルが
#   MECHANICAL_PATHS allowlist に閉じている場合は approve を維持して auto-merge に到達
#   させる。allowlist 外の差分（= semantic 判断含む）が出た場合は approving review を
#   review dismissal API で剥がし、`codex-ready-for-review` に戻して再レビューを誘導する。
#   `AUTO_REBASE_MODE=codex` を明示したリポジトリでのみ起動し、未設定 / off / 不正値の
#   リポジトリは導入前と完全に同一の挙動を維持する（opt-in）。
#   - ar_fetch_candidates / ar_build_prompt / ar_run_codex_rebase / ar_classify_diff
#   - ar_apply_mechanical / ar_dismiss_all_approvals / ar_apply_semantic
#   - ar_escalate_to_failed / ar_handle_pr / process_auto_rebase
#   semantic 自動解決（#103 / D-12, `AUTO_REBASE_SEMANTIC=on` + `FULL_AUTO_ENABLED` 配下）:
#   - ar_semantic_auto_enabled / ar_count_semantic_attempts / ar_semantic_budget_available
#   - ar_escalate_to_needs_decisions / ar_apply_semantic_auto
#
# 配置先:
#   $HOME/bin/idd-codex-modules/auto-rebase.sh（install.sh が local-watcher/bin/idd-codex-modules/ から配置する）
#
# 依存:
#   - 本モジュールは idd-codex-issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー（ar_log / ar_warn / ar_error）は core_utils.sh にあるため再定義しない。
#   - グローバル変数（$AUTO_REBASE_MODE / $AUTO_REBASE_GIT_TIMEOUT / allowlist 設定 /
#     $LABEL_NEEDS_REBASE / $LABEL_FAILED / $LABEL_NEEDS_DECISIONS / $BASE_BRANCH /
#     $AUTO_REBASE_SEMANTIC / $AUTO_REBASE_SEMANTIC_MAX / full_auto_enabled()(#97) 等）は
#     本体冒頭の Config ブロックで定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - 外部 CLI: gh / git / codex / jq。
#
# セットアップ参照先:
#   README.md（ディレクトリ構成・modules 化 migration note） / install.sh（配置ロジック）

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase D: Auto Rebase Processor (#17)
#   `codex-needs-rebase` + approved な open PR を Codex 経由で rebase し、変更ファイルが
#   `MECHANICAL_PATHS` allowlist に閉じている場合は approve を維持して auto-merge
#   に到達させる。allowlist 外の差分（= semantic 判断含む）が出た場合は approving
#   review を review dismissal API で剥がし、`codex-ready-for-review` に戻して再レビュー
#   を誘導する。新規 opt-in 機能。`AUTO_REBASE_MODE=codex` を明示したリポジトリ
#   でのみ起動し、未設定 / `off` / 不正値のリポジトリは導入前と完全に同一の挙動を
#   維持する（Req 1.1, 1.3, NFR 1.1）。
#
#   既存 Phase A 系列との競合排除（Req 3.1〜3.3）は、Re-check（先行）→ Phase A 本体
#   → Phase D の直列順序により構造的に保証される（design.md「順序根拠」参照）。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ─────────────────────────────────────────────────────────────────────────────
# ar_fetch_candidates: server-side + client-side の二段フィルタで候補 PR を返す
#   出力: stdout に jq 配列形式の JSON 1 行（候補なしなら "[]"）
#   戻り値: 0 = 正常（候補ゼロ件含む）、1 = API エラー（呼び出し側で WARN）
#
#   Req 2.1: codex-needs-rebase + 1 件以上 approving review + open
#   Req 2.2: codex-failed 付き除外（同じ PR の再試行を抑止 / Req 8.4）
#   Req 2.3: draft 除外
#   Req 2.4: fork PR 除外（head repo owner == base repo owner）
#   Req 2.5: head branch pattern 整合（既存 MERGE_QUEUE_HEAD_PATTERN を再利用）
# ─────────────────────────────────────────────────────────────────────────────
ar_fetch_candidates() {
  local repo_owner="${REPO%%/*}"
  local prs_json
  # Server-side filter（Phase A Re-check と同パターン）。
  if ! prs_json=$(timeout "$AUTO_REBASE_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "review:approved label:\"$LABEL_NEEDS_REBASE\" -label:\"$LABEL_FAILED\" -draft:true" \
      --json number,headRefName,baseRefName,labels,url,isDraft,reviewDecision,headRepositoryOwner,title \
      --limit 100 2>/dev/null); then
    ar_warn "対象 PR 一覧の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    echo "[]"
    return 1
  fi

  # Client-side filter（server filter の保険 + head pattern + fork 除外）。
  #   - isDraft / reviewDecision の再確認
  #   - head ref prefix (MERGE_QUEUE_HEAD_PATTERN): 人間の手書き PR を巻き込まない
  #   - head repo owner == base repo owner: fork PR を除外
  echo "$prs_json" | jq \
    --arg pattern "$MERGE_QUEUE_HEAD_PATTERN" \
    --arg owner "$repo_owner" \
    '[.[]
      | select(.isDraft == false)
      | select(.reviewDecision == "APPROVED")
      | select(.headRefName | test($pattern))
      | select((.headRepositoryOwner.login // "") == $owner)
    ]'
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_build_prompt: idd-codex-auto-rebase-prompt.tmpl のプレースホルダ展開
#   入力: $1=pr_number, $2=pr_title, $3=pr_url, $4=head_ref, $5=base_ref
#   出力: stdout に展開後の prompt 本文
#   戻り値: 0=成功、1=template が無い
#
#   Req 4.1: Codex rebase 試行に必要な PR コンテキストを 1 round で渡す
#   既存 pi_build_iteration_prompt の awk 置換方式を踏襲（単一行値のみ扱う）。
#   複数行値は不要なため、ENVIRON 経由の特殊扱いはしない（template が小さい）。
# ─────────────────────────────────────────────────────────────────────────────
ar_build_prompt() {
  local pr_number="$1"
  local pr_title="$2"
  local pr_url="$3"
  local head_ref="$4"
  local base_ref="$5"

  if [ ! -f "$AUTO_REBASE_TEMPLATE" ]; then
    ar_warn "template not found: $AUTO_REBASE_TEMPLATE"
    return 1
  fi

  awk \
    -v repo="$REPO" \
    -v pr_number="$pr_number" \
    -v pr_title="$pr_title" \
    -v pr_url="$pr_url" \
    -v head_ref="$head_ref" \
    -v base_ref="$base_ref" \
    -v base_branch="$BASE_BRANCH" \
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
      line = $0
      line = repl(line, "{{REPO}}", repo)
      line = repl(line, "{{PR_NUMBER}}", pr_number)
      line = repl(line, "{{PR_TITLE}}", pr_title)
      line = repl(line, "{{PR_URL}}", pr_url)
      line = repl(line, "{{HEAD_REF}}", head_ref)
      line = repl(line, "{{BASE_REF}}", base_ref)
      line = repl(line, "{{BASE_BRANCH}}", base_branch)
      print line
    }
    ' "$AUTO_REBASE_TEMPLATE"
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_run_codex_rebase: Codex CLI を 1 回起動して conflict 解消 rebase を試行し、
#   成功すれば force-with-lease push する。Phase A の mq_try_rebase_pr の (subshell
#   + trap) パターンを踏襲しつつ、rebase 実行を Codex に委ねる。
#
#   入力: $1=pr_number, $2=pr_title, $3=pr_url, $4=head_ref, $5=base_ref
#   出力 (stdout 1 行): 成功時 "<before_sha> <after_sha>"、失敗時 空文字
#   戻り値:
#     0 : rebase + push 成功
#     1 : Codex が conflict を解消できず終了（dirty 残置 / clean だが before==after）
#     2 : timeout（exit 124）
#     3 : push 失敗
#     4 : fetch / checkout 失敗
#     5 : rebase 不要（既に base が祖先、skip 候補）
#
#   Req 4.1, 4.2, 4.3, 4.5, 4.6, NFR 5.1, NFR 5.2, NFR 5.3
# ─────────────────────────────────────────────────────────────────────────────
ar_run_codex_rebase() {
  local pr_number="$1"
  local pr_title="$2"
  local pr_url="$3"
  local head_ref="$4"
  local base_ref="$5"

  # ログファイルは 1 PR ごとに分ける（タイムスタンプで一意化）
  local log_file
  log_file="${LOG_DIR}/auto-rebase-${pr_number}-$(date +%Y%m%d-%H%M%S).log"

  local result_file
  if ! result_file=$(idd_secure_mktemp "auto-rebase-result-${pr_number}"); then
    ar_warn "PR #${pr_number}: auto-rebase result secure tempfile の作成に失敗"
    return 1
  fi

  (
    set +e
    # サブシェル終了時は必ず元の base branch checkout に戻す（NFR 5.2）
    # shellcheck disable=SC2064
    trap "git rebase --abort >/dev/null 2>&1; git checkout '${BASE_BRANCH}' >/dev/null 2>&1" EXIT

    # Req 4.3 前提: base/head 両方を最新化（API 状態と一致させる）
    if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" git fetch origin "$head_ref" "$base_ref" >/dev/null 2>&1; then
      exit 4
    fi

    # head branch を origin に同期して checkout（既存ローカルあれば force リセット）
    if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" git checkout -B "$head_ref" "origin/${head_ref}" >/dev/null 2>&1; then
      exit 4
    fi

    # Req 4.2 前段: rebase 前 SHA を記録
    local before_sha
    before_sha=$(git rev-parse HEAD 2>/dev/null) || exit 4
    echo "before=${before_sha}" >>"$log_file"

    # 既に base が head の祖先なら rebase 不要（skip 候補）。Phase A 本体が拾える
    # ケースを Phase D で重複処理しないための短絡。
    if git merge-base --is-ancestor "origin/${base_ref}" "origin/${head_ref}" 2>/dev/null; then
      # skip 用 sentinel として before==after を出力して exit 5
      printf '%s %s\n' "$before_sha" "$before_sha" >"$result_file"
      exit 5
    fi

    # Codex prompt を組み立て
    local prompt
    if ! prompt=$(ar_build_prompt "$pr_number" "$pr_title" "$pr_url" "$head_ref" "$base_ref"); then
      exit 4
    fi

    # Req 4.1 / NFR 5.1: Codex CLI を timeout 付きで起動。実行形式は watcher 本体の
    # codex_exec_prompt に集約し、Auto Rebase だけ CODEX_EXEC_TIMEOUT_SEC で外側 timeout を渡す。
    CODEX_EXEC_TIMEOUT_SEC="$AUTO_REBASE_MAX_TURNS_SEC" \
      codex_exec_prompt "AutoRebase-${pr_number}" "$AUTO_REBASE_MODEL" "$prompt" \
        >>"$log_file" 2>&1
    local codex_rc=$?

    # Req 4.5: timeout (exit 124) 検知
    if [ "$codex_rc" -eq 124 ]; then
      git rebase --abort >/dev/null 2>&1 || true
      exit 2
    fi

    # Codex 終了後の working tree が dirty なら conflict 未解消（半端な状態）
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      git rebase --abort >/dev/null 2>&1 || true
      exit 1
    fi

    # Req 4.2 後段: rebase 後 SHA を記録
    local after_sha
    after_sha=$(git rev-parse HEAD 2>/dev/null) || exit 1
    echo "after=${after_sha}" >>"$log_file"

    # before == after で base が head の祖先のままなら、Codex が rebase 実行を
    # サボった可能性。skip 扱いにして次サイクルに委ねる（保守的）。
    if [ "$before_sha" = "$after_sha" ]; then
      if git merge-base --is-ancestor "origin/${base_ref}" "origin/${head_ref}" 2>/dev/null; then
        printf '%s %s\n' "$before_sha" "$after_sha" >"$result_file"
        exit 5
      fi
      # before==after だが base が祖先でない = rebase が走らなかった conflict
      exit 1
    fi

    # Req 4.6 / NFR 5.3: 安全な force push のみ使用（`--force` 単独は使わない）
    if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
        git push --force-with-lease origin "$head_ref" >>"$log_file" 2>&1; then
      exit 3
    fi

    printf '%s %s\n' "$before_sha" "$after_sha" >"$result_file"
    exit 0
  )
  local rc=$?

  # サブシェル外でも安全側に倒して base branch に戻す（NFR 5.2）
  git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true

  # 成功 / skip 時のみ stdout に SHA を出力（呼び出し側が parse する）
  case $rc in
    0|5)
      if [ -f "$result_file" ]; then
        cat "$result_file"
      fi
      ;;
  esac
  rm -f "$result_file" 2>/dev/null || true

  return "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_classify_diff: rebase 後 head と base 間の累積 diff の path 集合を
#   `MECHANICAL_PATHS` allowlist と照合し `mechanical` / `semantic` を判定。
#
#   入力: $1=pr_number, $2=base_ref, $3=head_ref
#   出力 (stdout):
#     1 行目: `mechanical` or `semantic`
#     2 行目: semantic の場合は最初の unmatched path（取得できれば）。mechanical
#             では 2 行目を出さない
#   戻り値: 0=正常、1=`git diff` 失敗（呼び出し側は保守的に `semantic` 扱い）
#
#   Req 5.1, 5.2, 5.3, 5.4, 5.5
# ─────────────────────────────────────────────────────────────────────────────
ar_classify_diff() {
  local pr_number="$1"
  local base_ref="$2"
  local head_ref="$3"

  # Req 5.4: MECHANICAL_PATHS が空なら全件 semantic（保守的判定）
  if [ -z "$MECHANICAL_PATHS" ]; then
    ar_log "PR #${pr_number}: classification=semantic (MECHANICAL_PATHS 未設定)"
    echo "semantic"
    return 0
  fi

  # 変更 path 一覧を取得（base..head の累積 diff）
  local diff_range="origin/${base_ref}..origin/${head_ref}"
  local changed_paths
  if ! changed_paths=$(timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      git diff --name-only "$diff_range" 2>/dev/null); then
    # 取得失敗時も保守的に semantic
    ar_log "PR #${pr_number}: classification=semantic (git diff 失敗)"
    echo "semantic"
    return 1
  fi

  if [ -z "$changed_paths" ]; then
    # 変更ファイルゼロは想定外（呼び出し側で skip 判定済みだが、念のため semantic に倒す）
    ar_log "PR #${pr_number}: classification=semantic (変更ファイルなし、保守的扱い)"
    echo "semantic"
    return 0
  fi

  if [ -z "${MECHANICAL_PATHS:-}" ]; then
    ar_log "PR #${pr_number}: classification=semantic (MECHANICAL_PATHS 未設定、保守的扱い)"
    echo "semantic"
    return 0
  fi

  # MECHANICAL_PATHS をカンマ区切りで配列展開
  local -a patterns=()
  local IFS=','
  read -ra patterns <<< "$MECHANICAL_PATHS"
  IFS=$' \t\n'

  # 各 path について「いずれかの pattern に一致」を確認
  local path matched pattern first_unmatched=""
  local match_count=0
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    matched=false
    for pattern in "${patterns[@]}"; do
      # 前後空白除去
      pattern="${pattern# }"
      pattern="${pattern% }"
      [ -z "$pattern" ] && continue
      # POSIX bash の path matching (`==` + glob)。
      # 右辺の変数 glob 比較は意図的なので SC2053 を局所無効化。
      # shellcheck disable=SC2053
      if [[ "$path" == $pattern ]]; then
        matched=true
        break
      fi
    done
    if [ "$matched" = "false" ]; then
      # Req 5.3: 1 件でも一致しない → 即 semantic（保守的判定）
      first_unmatched="$path"
      break
    fi
    match_count=$((match_count + 1))
  done <<< "$changed_paths"

  if [ -n "$first_unmatched" ]; then
    # Req 5.5: 判定結果と最初の unmatched path をログに含める
    ar_log "PR #${pr_number}: classification=semantic unmatch=${first_unmatched}"
    echo "semantic"
    echo "$first_unmatched"
    return 0
  fi

  # Req 5.2: 全 path 一致 → mechanical
  ar_log "PR #${pr_number}: classification=mechanical paths=${match_count}"
  echo "mechanical"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_apply_mechanical: mechanical 判定後の副作用（codex-needs-rebase 除去のみ）を実行。
#   approve への副作用なし（Req 6.1）、追加コメント投稿なし（Req 6.3）。設計意図は
#   「lockfile-only 等の機械的 rebase は人間 noise を最小化する」。
#
#   入力: $1=pr_number
#   戻り値: 0=成功、1=label 除去 API 失敗（呼び出し側で WARN）
#
#   Req 6.1, 6.2, 6.3, 6.4
# ─────────────────────────────────────────────────────────────────────────────
ar_apply_mechanical() {
  local pr_number="$1"

  # Req 6.2: codex-needs-rebase ラベルを除去（唯一の副作用）。
  # Phase A と同 timeout を適用。GitHub の `--remove-label` は対象ラベルが
  # 既に無い場合も成功扱いとなるため、冪等性が保たれる。
  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" --remove-label "$LABEL_NEEDS_REBASE" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: codex-needs-rebase ラベル除去に失敗"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_dismiss_all_approvals: PR の approving review を全件 review dismissal API
#   (`gh api -X PUT .../reviews/{id}/dismissals`) で dismiss する。
#   `gh pr review --request-changes` 形式の別レビュー投稿方式は使わない（Req 7.5）。
#
#   入力: $1=pr_number
#   戻り値: 0=全 approving review の dismissal が成功（または対象なし）、
#           1=1 件でも失敗（呼び出し側で escalate に流す）
#
#   Error Handling: dismissal API が 422 を返す場合（既に dismissed 等）は当該
#   review を skip して次の review へ進む（business logic エラーとして個別 skip）。
#   それ以外の non-zero は全体失敗扱い。
# ─────────────────────────────────────────────────────────────────────────────
ar_dismiss_all_approvals() {
  local pr_number="$1"

  # 1. PR の review 一覧を取得
  local reviews_json
  if ! reviews_json=$(timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh api "/repos/${REPO}/pulls/${pr_number}/reviews" 2>/dev/null); then
    ar_warn "PR #${pr_number}: review 一覧の取得に失敗"
    return 1
  fi

  # 2. state == APPROVED の review id を抽出
  local approved_ids
  approved_ids=$(echo "$reviews_json" | jq -r '[.[] | select(.state == "APPROVED") | .id] | .[]' 2>/dev/null || true)
  if [ -z "$approved_ids" ]; then
    # 対象なし（既に全部 dismissed / 状態が異なる）。冪等的に成功扱い。
    ar_log "PR #${pr_number}: dismissal 対象の approving review なし（既に dismissed の可能性）"
    return 0
  fi

  # 3. 各 review id について dismissal API を呼ぶ
  local id rc=0
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    local stderr_file
    if ! stderr_file=$(idd_secure_mktemp "auto-rebase-dismiss-stderr-${pr_number}-${id}"); then
      ar_warn "PR #${pr_number}: review id=${id} dismissal stderr secure tempfile の作成に失敗"
      rc=1
      continue
    fi
    if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
        gh api -X PUT "/repos/${REPO}/pulls/${pr_number}/reviews/${id}/dismissals" \
        -f message="Phase D semantic rebase: re-review required" >/dev/null 2>"$stderr_file"; then
      # 422 (Unprocessable Entity) は既に dismissed の可能性が高い。skip 扱い。
      if grep -q "HTTP 422" "$stderr_file" 2>/dev/null; then
        ar_log "PR #${pr_number}: review id=${id} は既に dismissed の可能性 (HTTP 422、skip)"
      else
        ar_warn "PR #${pr_number}: review id=${id} の dismissal に失敗"
        rc=1
      fi
    fi
    rm -f "$stderr_file" 2>/dev/null || true
  done <<< "$approved_ids"

  return "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_apply_semantic: semantic 判定時の副作用を実行。
#   1. ar_dismiss_all_approvals で approve を全件 dismiss
#   2. codex-needs-rebase 除去
#   3. codex-ready-for-review 付与
#   4. 説明コメント投稿（rebase 実施 / semantic 判定 / dismissal / 再レビュー誘導）
#
#   入力: $1=pr_number, $2=pr_url, $3=before_sha, $4=after_sha,
#         $5=first_unmatched_path（空可）
#   戻り値:
#     0 : 全成功
#     1 : dismissal 失敗（呼び出し側で escalate `dismissal-failed` 経路）
#     2 : label / comment 失敗（部分成功、WARN 後 semantic 扱いは継続）
#
#   Req 7.1, 7.2, 7.3, 7.4
# ─────────────────────────────────────────────────────────────────────────────
ar_apply_semantic() {
  local pr_number="$1"
  local pr_url="$2"
  local before_sha="$3"
  local after_sha="$4"
  local first_unmatched="${5:-}"

  # 1. approving review をすべて dismiss
  if ! ar_dismiss_all_approvals "$pr_number"; then
    return 1
  fi

  local partial_fail=0

  # 2. codex-needs-rebase 除去
  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" --remove-label "$LABEL_NEEDS_REBASE" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: codex-needs-rebase ラベル除去に失敗（semantic 経路）"
    partial_fail=1
  fi

  # 3. codex-ready-for-review 付与
  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" --add-label "$LABEL_READY" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: codex-ready-for-review ラベル付与に失敗"
    partial_fail=1
  fi

  # 4. 説明コメント投稿（Req 7.4）
  local unmatched_line=""
  if [ -n "$first_unmatched" ]; then
    unmatched_line="- 最初に検出された allowlist 外パス: \`${first_unmatched}\`"
  fi

  local comment_body
  read -r -d '' comment_body <<EOF || true
## Phase D: semantic rebase により再レビューが必要です

watcher (Phase D Auto Rebase Processor) が本 PR の \`codex-needs-rebase\` 状態に対して
Codex による rebase を実行しました。rebase 後の変更ファイルのうち \`MECHANICAL_PATHS\`
allowlist に含まれない path が検出されたため、**semantic な書き換えを含む rebase**と
判定しました。

### 実施内容

- rebase 前 head SHA: \`${before_sha}\`
- rebase 後 head SHA: \`${after_sha}\`
${unmatched_line}
- 既存 approving review を **review dismissal API** で全件取り消しました
- \`codex-needs-rebase\` を除去し \`codex-ready-for-review\` を付与しました

### 次のアクション（人間レビュワー向け）

Codex が rebase 過程で書き換えた内容は人間レビューを通っていません。差分を確認し、
妥当であれば **再度 approve** してください。allowlist の見直しが必要な場合は
\`MECHANICAL_PATHS\` 環境変数の設定値も併せて検討してください。

---

_本コメントは Phase D Auto Rebase Processor が自動投稿しました。本機能の挙動を変更する
場合は \`AUTO_REBASE_MODE\` を \`off\` に切り替えてください。_

<!-- idd-codex:auto-rebase pr=${pr_number} -->
EOF

  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: semantic 説明コメントの投稿に失敗（${pr_url}）"
    partial_fail=1
  fi

  if [ "$partial_fail" -eq 1 ]; then
    return 2
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_escalate_to_failed: `codex-failed` ラベルを付与し、原因種別と手動復旧手順を
#   含むコメントを 1 件投稿する。`codex-needs-rebase` ラベルには触らない（Req 8.1）。
#
#   入力: $1=pr_number, $2=reason
#     reason ∈ { "conflict-unresolved", "timeout", "push-failed",
#                "dismissal-failed", "fetch-failed" }
#   戻り値: 0=成功、1=失敗（WARN）
#
#   Req 4.4, 4.5, 7.6, 8.1, 8.2, 8.3, 8.4
# ─────────────────────────────────────────────────────────────────────────────
ar_escalate_to_failed() {
  local pr_number="$1"
  local reason="$2"

  local reason_desc recovery
  case "$reason" in
    conflict-unresolved)
      reason_desc="Codex が conflict を解消できませんでした（working tree が dirty 残置、または rebase 自体が走らなかった可能性）"
      recovery="手動で \`gh pr checkout ${pr_number} && git rebase origin/${BASE_BRANCH}\` を実施し、conflict を解消してから force-with-lease push してください"
      ;;
    timeout)
      reason_desc="Codex rebase が \`${AUTO_REBASE_MAX_TURNS_SEC}\` 秒の timeout を超過しました"
      recovery="PR 規模が大きい場合は手動 rebase を推奨します。次回サイクルで再試行したい場合は \`codex-failed\` ラベルを手動で外してください"
      ;;
    push-failed)
      reason_desc="rebase は成功しましたが \`git push --force-with-lease\` に失敗しました（リモートが先行している可能性）"
      recovery="\`gh pr checkout ${pr_number} && git pull --rebase origin ${BASE_BRANCH}\` でリモートを取り込んでから手動 push してください"
      ;;
    dismissal-failed)
      reason_desc="semantic 判定後に approving review の dismissal API が失敗しました"
      recovery="GitHub の Reviews UI から手動で approve を取り消し、変更内容を再レビューしてください。watcher の token が PR review dismissal 権限を持っているか（admin / maintain ロール相当）も確認してください"
      ;;
    fetch-failed)
      reason_desc="rebase に到達する前に \`git fetch\` / \`git checkout\` が失敗しました"
      recovery="ネットワーク疎通とリモート ref の存在を確認してください。次回サイクルで自動再試行はしません（\`codex-failed\` 解除が必要）"
      ;;
    *)
      reason_desc="未知の失敗理由: ${reason}"
      recovery="watcher の log（\`auto-rebase:\` prefix）を確認し、手動で復旧してください"
      ;;
  esac

  local label_rc=0
  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" --add-label "$LABEL_FAILED" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: codex-failed ラベル付与に失敗（理由: ${reason}）"
    label_rc=1
  fi

  local comment_body
  read -r -d '' comment_body <<EOF || true
## Phase D: Codex rebase が失敗しました（人間エスカレーション）

watcher (Phase D Auto Rebase Processor) が本 PR の \`codex-needs-rebase\` 状態に対して
Codex による rebase を実行しましたが、**失敗した**ためエスカレーションします。

### 失敗種別

\`${reason}\`

### 詳細

${reason_desc}

### 推奨復旧手順

${recovery}

---

_本コメントは Phase D Auto Rebase Processor が自動投稿しました。\`codex-failed\`
ラベルが付いている間、本機能は同一 PR への rebase 再試行を行いません（Req 8.4）。
復旧後は \`codex-failed\` ラベルを手動で外してください。_

<!-- idd-codex:auto-rebase pr=${pr_number} reason=${reason} -->
EOF

  local comment_rc=0
  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: codex-failed エスカレーションコメント投稿に失敗"
    comment_rc=1
  fi

  if [ "$label_rc" -ne 0 ] || [ "$comment_rc" -ne 0 ]; then
    return 1
  fi
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════
# Issue #103 / D-12: semantic conflict 自動解決（二重ゲート再発火 + needs-decisions
#   フォールバック）。`AUTO_REBASE_SEMANTIC=on` かつ `FULL_AUTO_ENABLED=true` のときのみ
#   semantic 判定の disposition を「人間待ち（ar_apply_semantic）」から「自動続行
#   （ar_apply_semantic_auto）」に切り替える。OFF（既定）では一切の挙動変化なし。
# ═════════════════════════════════════════════════════════════════════════════

# semantic auto-resolution 用 audit marker（budget カウントに用いる。汎用 auto-rebase
# marker `idd-codex:auto-rebase` とは別 namespace にして自動解決回数だけを数える）。
AR_SEMANTIC_MARKER="idd-codex:auto-rebase-semantic"

# ─────────────────────────────────────────────────────────────────────────────
# ar_semantic_auto_enabled: semantic 自動解決が有効か（純粋判定 / 副作用なし）
#   戻り値: 0 = AUTO_REBASE_SEMANTIC=on かつ full_auto_enabled / 1 = それ以外
# ─────────────────────────────────────────────────────────────────────────────
ar_semantic_auto_enabled() {
  [ "${AUTO_REBASE_SEMANTIC:-off}" = "on" ] || return 1
  full_auto_enabled || return 1
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_count_semantic_attempts: 同一 PR の過去 semantic 自動解決回数を marker から数える
#   入力: $1=pr_number
#   出力: stdout に整数。gh 取得失敗時は AUTO_REBASE_SEMANTIC_MAX を返し budget 枯渇へ倒す
#         （数えられない → 安全側で自動続行しない）。
# ─────────────────────────────────────────────────────────────────────────────
ar_count_semantic_attempts() {
  local pr_number="$1"
  local comments_json
  if ! comments_json=$(timeout "$AUTO_REBASE_GIT_TIMEOUT" gh pr view "$pr_number" \
      --repo "$REPO" --json comments 2>/dev/null); then
    ar_warn "PR #${pr_number}: 過去コメント取得に失敗（budget 枯渇扱い＝自動続行しない）"
    printf '%s' "$AUTO_REBASE_SEMANTIC_MAX"
    return 0
  fi
  local count
  count=$(printf '%s' "$comments_json" | jq -r --arg m "$AR_SEMANTIC_MARKER" --arg n "$pr_number" '
    [ (.comments // [])[] | select((.body // "") | contains($m + " pr=" + $n)) ] | length
  ' 2>/dev/null || echo "")
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  printf '%s' "$count"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_semantic_budget_available: 無限解決ループ防止（自動解決回数 < MAX か）
#   入力: $1=pr_number
#   戻り値: 0 = まだ自動解決可（prior < MAX）/ 1 = budget 枯渇（needs-decisions へ）
# ─────────────────────────────────────────────────────────────────────────────
ar_semantic_budget_available() {
  local pr_number="$1"
  local prior
  prior=$(ar_count_semantic_attempts "$pr_number")
  [[ "$prior" =~ ^[0-9]+$ ]] || prior="$AUTO_REBASE_SEMANTIC_MAX"
  [ "$prior" -lt "$AUTO_REBASE_SEMANTIC_MAX" ] || return 1
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_escalate_to_needs_decisions: 解決不能 semantic を人間へフォールバック（D-12）
#   入力: $1=pr_number, $2=reason ∈ { conflict-unresolved, budget-exhausted,
#         dismissal-failed, unknown }
#   `codex-needs-rebase` を除去（rebase 候補から外す）+ `codex-needs-decisions` 付与 +
#   原因と復旧手順のコメント 1 件。`codex-failed` は付与しない（D-12: 人間判断待ち）。
#   戻り値: 0=成功 / 1=失敗（WARN）
# ─────────────────────────────────────────────────────────────────────────────
ar_escalate_to_needs_decisions() {
  local pr_number="$1"
  local reason="$2"

  local reason_desc recovery
  case "$reason" in
    conflict-unresolved)
      reason_desc="Codex が semantic conflict を自動解決できませんでした（working tree が dirty 残置 / rebase 不成立）"
      recovery="手動で \`gh pr checkout ${pr_number} && git rebase origin/${BASE_BRANCH}\` を実施し conflict を解消するか、設計判断が必要なら本 Issue/PR で方針を決定してください" ;;
    budget-exhausted)
      reason_desc="同一 PR への semantic 自動解決が通算上限（${AUTO_REBASE_SEMANTIC_MAX} 回）に到達しました（無限解決ループ防止）"
      recovery="自動解決を繰り返しても merge に至っていません。conflict の根本原因（設計のズレ等）を人間が判断してください" ;;
    dismissal-failed)
      reason_desc="semantic 自動解決後に approving review の dismissal API が失敗しました"
      recovery="GitHub の Reviews UI から手動で approve を取り消し、再レビューしてください。watcher token の dismissal 権限も確認してください" ;;
    *)
      reason_desc="semantic 自動解決の未知の失敗: ${reason}"
      recovery="watcher log（\`auto-rebase:\` prefix）を確認し、手動で復旧してください" ;;
  esac

  local label_rc=0
  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" \
      --remove-label "$LABEL_NEEDS_REBASE" \
      --add-label "$LABEL_NEEDS_DECISIONS" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: codex-needs-decisions フォールバックのラベル操作に失敗（理由: ${reason}）"
    label_rc=1
  fi

  local comment_body
  read -r -d '' comment_body <<EOF || true
## Phase D: semantic conflict を人間判断へフォールバック（#103 / D-12）

watcher (Auto Rebase Processor / semantic 自動解決) が本 PR の semantic conflict を
自動解決できなかったため、\`codex-needs-decisions\` を付与して人間判断にエスカレーションします。

### 失敗種別

\`${reason}\`

### 詳細

${reason_desc}

### 推奨対応

${recovery}

---

_本コメントは Auto Rebase Processor (semantic 自動解決 / #103) が自動投稿しました。
\`codex-needs-decisions\` を外すと watcher が再評価します。semantic 自動解決を止めたい
場合は \`AUTO_REBASE_SEMANTIC=off\` に切り替えてください。_

<!-- ${AR_SEMANTIC_MARKER} pr=${pr_number} reason=${reason} -->
EOF

  local comment_rc=0
  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: needs-decisions フォールバックのコメント投稿に失敗"
    comment_rc=1
  fi

  if [ "$label_rc" -ne 0 ] || [ "$comment_rc" -ne 0 ]; then
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_apply_semantic_auto: semantic 自動解決の disposition（二重ゲート再発火経路）
#   入力: $1=pr_number $2=pr_url $3=before_sha $4=after_sha $5=first_unmatched（空可）
#   1. approving review を全件 dismiss（無検証 merge を防ぐ / 安全策）
#   2. codex-needs-rebase 除去 + codex-ready-for-review 付与（pr-reviewer / auto-merge が
#      新 SHA を再評価＝Issue 02 二重ゲート再発火）
#   3. audit コメント（marker 付き = budget カウント源）を投稿
#   戻り値: 0=成功 / 1=dismissal 失敗（呼び出し側で needs-decisions フォールバック）/
#           2=label/comment 部分失敗（dismissal 成功のため semantic 扱い継続）
#   ※ codex 解決 commit は ar_run_codex_rebase が push 済み。本関数は push しない。
# ─────────────────────────────────────────────────────────────────────────────
ar_apply_semantic_auto() {
  local pr_number="$1"
  local pr_url="$2"
  local before_sha="$3"
  local after_sha="$4"
  local first_unmatched="${5:-}"

  # 1. approve を全件 dismiss（無検証 merge を防ぐ＝二重ゲートが新 SHA で再判定する）
  if ! ar_dismiss_all_approvals "$pr_number"; then
    return 1
  fi

  local partial_fail=0
  # 2. codex-needs-rebase 除去 + codex-ready-for-review 付与
  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" \
      --remove-label "$LABEL_NEEDS_REBASE" \
      --add-label "$LABEL_READY" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: semantic 自動解決のラベル操作に失敗"
    partial_fail=1
  fi

  # 3. audit コメント（marker = budget カウント源）
  local unmatched_line=""
  if [ -n "$first_unmatched" ]; then
    unmatched_line="- 最初に検出された allowlist 外パス: \`${first_unmatched}\`"
  fi
  local comment_body
  read -r -d '' comment_body <<EOF || true
## Phase D: semantic conflict を自動解決し再レビューへ（#103 / D-12）

watcher が本 PR の semantic conflict を Codex で解決し（新規 commit を push）、
既存 approve を dismiss しました。**無検証では merge しません**: 解決 diff は
Issue 02 の二重ゲート（\`codex-review\`（+2nd gate \`claude-review\`））が新 SHA で
再発火し、再レビュー approve + CI green + mergeable に到達した時点で auto-merge されます。

### 実施内容

- rebase 前 head SHA: \`${before_sha}\`
- rebase 後 head SHA: \`${after_sha}\`
${unmatched_line}
- 既存 approving review を dismissal API で全件取り消し（再レビュー必須化）
- \`codex-needs-rebase\` を除去し \`codex-ready-for-review\` を付与

---

_本コメントは Auto Rebase Processor (semantic 自動解決 / #103) が自動投稿しました。
解決を繰り返しても merge に至らない場合は通算 ${AUTO_REBASE_SEMANTIC_MAX} 回で
\`codex-needs-decisions\` へフォールバックします。止めたい場合は \`AUTO_REBASE_SEMANTIC=off\`。_

<!-- ${AR_SEMANTIC_MARKER} pr=${pr_number} -->
EOF

  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: semantic 自動解決の audit コメント投稿に失敗（${pr_url}）"
    partial_fail=1
  fi

  if [ "$partial_fail" -eq 1 ]; then
    return 2
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_handle_pr: 1 PR の Phase D 処理を実行
#   （rebase 試行 → 分類 → mechanical/semantic 後処理 / 失敗時 escalate）
#
#   入力: $1 = pr_json（gh pr list の 1 要素 JSON）
#   戻り値:
#     0  : mechanical 完了
#     1  : semantic 完了
#     2  : failed（codex-failed 付与済み）
#     10 : skip（rebase 不要 / push 待ち UNKNOWN 等、次サイクルに委ねる）
#
#   Req 3.4, 4.4, 4.5, 5.5, 7.6, NFR 2.1, NFR 5.2
# ─────────────────────────────────────────────────────────────────────────────
ar_handle_pr() {
  local pr_json="$1"

  local pr_number head_ref base_ref pr_url pr_title
  pr_number=$(echo "$pr_json" | jq -r '.number')
  head_ref=$(echo "$pr_json"  | jq -r '.headRefName')
  base_ref=$(echo "$pr_json"  | jq -r '.baseRefName')
  pr_url=$(echo "$pr_json"    | jq -r '.url')
  pr_title=$(echo "$pr_json"  | jq -r '.title // ""')

  # 1. Codex rebase を試行
  local rebase_output rebase_rc=0
  rebase_output=$(ar_run_codex_rebase "$pr_number" "$pr_title" "$pr_url" "$head_ref" "$base_ref") || rebase_rc=$?

  case "$rebase_rc" in
    0)
      # 成功（rebase + push 完了）。後続で分類へ進む
      ;;
    5)
      # rebase 不要（既に base が head の祖先）。Re-check が拾うべきケースとして skip
      ar_log "PR #${pr_number}: rebase 不要（already up-to-date with base, skip）action=skip url=${pr_url}"
      return 10
      ;;
    1)
      # 解決不能（codex が conflict を解消できず dirty 残置）。semantic 自動解決 ON 時は
      # codex-failed ではなく codex-needs-decisions へフォールバック（D-12）。
      if ar_semantic_auto_enabled; then
        ar_escalate_to_needs_decisions "$pr_number" "conflict-unresolved" || true
        ar_log "PR #${pr_number}: classification=needs-decisions reason=conflict-unresolved action=escalate url=${pr_url}"
      else
        ar_escalate_to_failed "$pr_number" "conflict-unresolved" || true
        ar_log "PR #${pr_number}: classification=failed reason=conflict-unresolved action=escalate url=${pr_url}"
      fi
      return 2
      ;;
    2)
      ar_escalate_to_failed "$pr_number" "timeout" || true
      ar_log "PR #${pr_number}: classification=failed reason=timeout action=escalate url=${pr_url}"
      return 2
      ;;
    3)
      ar_escalate_to_failed "$pr_number" "push-failed" || true
      ar_log "PR #${pr_number}: classification=failed reason=push-failed action=escalate url=${pr_url}"
      return 2
      ;;
    4)
      ar_escalate_to_failed "$pr_number" "fetch-failed" || true
      ar_log "PR #${pr_number}: classification=failed reason=fetch-failed action=escalate url=${pr_url}"
      return 2
      ;;
    *)
      ar_escalate_to_failed "$pr_number" "conflict-unresolved" || true
      ar_log "PR #${pr_number}: classification=failed reason=unknown(rc=${rebase_rc}) action=escalate url=${pr_url}"
      return 2
      ;;
  esac

  # 2. 成功した SHA を parse（"<before> <after>" の 1 行）
  local before_sha after_sha
  before_sha=$(echo "$rebase_output" | awk '{print $1}')
  after_sha=$(echo "$rebase_output"  | awk '{print $2}')
  if [ -z "$before_sha" ] || [ -z "$after_sha" ]; then
    ar_warn "PR #${pr_number}: rebase 成功だが SHA を parse できず、escalate"
    ar_escalate_to_failed "$pr_number" "conflict-unresolved" || true
    return 2
  fi

  # 3. push 後の head を origin から fetch して classify に使う
  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" git fetch origin "$head_ref" "$base_ref" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: rebase 後の git fetch に失敗"
  fi

  # 4. mechanical / semantic を判定（Req 5.x）
  local classify_output classification first_unmatched=""
  classify_output=$(ar_classify_diff "$pr_number" "$base_ref" "$head_ref")
  classification=$(echo "$classify_output" | sed -n '1p')
  first_unmatched=$(echo "$classify_output" | sed -n '2p')

  # 5. 分類別の後処理
  if [ "$classification" = "mechanical" ]; then
    if ar_apply_mechanical "$pr_number"; then
      ar_log "PR #${pr_number}: classification=mechanical before=${before_sha} after=${after_sha} action=label-removed url=${pr_url}"
      return 0
    else
      ar_log "PR #${pr_number}: classification=mechanical before=${before_sha} after=${after_sha} action=label-remove-failed url=${pr_url}"
      # ラベル除去失敗は failed 扱いにしない（次サイクルで再試行可能 / Error Handling 節）
      return 0
    fi
  fi

  # semantic（または `git diff` 失敗時の保守的 semantic）
  # #103 / D-12: semantic 自動解決が有効なら、人間待ち（ar_apply_semantic）ではなく
  # 二重ゲート再発火経路（ar_apply_semantic_auto）へ切り替える。budget 超過 / dismissal
  # 失敗は codex-needs-decisions フォールバック。OFF（既定）では従来経路で完全に等価。
  if ar_semantic_auto_enabled; then
    if ! ar_semantic_budget_available "$pr_number"; then
      ar_escalate_to_needs_decisions "$pr_number" "budget-exhausted" || true
      ar_log "PR #${pr_number}: classification=needs-decisions reason=budget-exhausted before=${before_sha} after=${after_sha} action=escalate url=${pr_url}"
      return 2
    fi
    local sauto_rc=0
    ar_apply_semantic_auto "$pr_number" "$pr_url" "$before_sha" "$after_sha" "$first_unmatched" || sauto_rc=$?
    case "$sauto_rc" in
      0)
        ar_log "PR #${pr_number}: classification=semantic-auto before=${before_sha} after=${after_sha} unmatch=${first_unmatched:-(unknown)} action=auto-resolve+rereview url=${pr_url}"
        return 1
        ;;
      1)
        ar_escalate_to_needs_decisions "$pr_number" "dismissal-failed" || true
        ar_log "PR #${pr_number}: classification=needs-decisions reason=dismissal-failed before=${before_sha} after=${after_sha} action=escalate url=${pr_url}"
        return 2
        ;;
      2)
        ar_log "PR #${pr_number}: classification=semantic-auto before=${before_sha} after=${after_sha} action=auto-resolve+partial-fail url=${pr_url}"
        return 1
        ;;
      *)
        ar_escalate_to_needs_decisions "$pr_number" "unknown" || true
        ar_log "PR #${pr_number}: classification=needs-decisions reason=unknown-semantic-auto(rc=${sauto_rc}) action=escalate url=${pr_url}"
        return 2
        ;;
    esac
  fi

  local semantic_rc=0
  ar_apply_semantic "$pr_number" "$pr_url" "$before_sha" "$after_sha" "$first_unmatched" || semantic_rc=$?
  case "$semantic_rc" in
    0)
      ar_log "PR #${pr_number}: classification=semantic before=${before_sha} after=${after_sha} unmatch=${first_unmatched:-(unknown)} action=dismissed+ready url=${pr_url}"
      return 1
      ;;
    1)
      # dismissal 失敗 → escalate
      ar_escalate_to_failed "$pr_number" "dismissal-failed" || true
      ar_log "PR #${pr_number}: classification=failed reason=dismissal-failed before=${before_sha} after=${after_sha} action=escalate url=${pr_url}"
      return 2
      ;;
    2)
      # label / comment の部分失敗。dismissal は成功しているので semantic 扱いを維持
      ar_log "PR #${pr_number}: classification=semantic before=${before_sha} after=${after_sha} action=dismissed+partial-fail url=${pr_url}"
      return 1
      ;;
    *)
      ar_escalate_to_failed "$pr_number" "dismissal-failed" || true
      ar_log "PR #${pr_number}: classification=failed reason=unknown-semantic(rc=${semantic_rc}) action=escalate url=${pr_url}"
      return 2
      ;;
  esac
}

process_auto_rebase() {
  # Req 1.1: opt-in gate（未設定 / `off` / 不正値で起動しない）
  if [ "$AUTO_REBASE_MODE" = "off" ]; then
    return 0
  fi

  # NFR 5.2 / Phase A pattern: 想定外の dirty working tree を検知したら ERROR で
  # サイクル中止（後続 Processor を阻害しないよう 0 return）
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    ar_error "dirty working tree を検出しました。Phase D Auto Rebase Processor をスキップします。"
    return 0
  fi

  # Req 1.4: サイクル開始時に有効値をログ出力
  ar_log "サイクル開始 (mode=${AUTO_REBASE_MODE}, paths=${MECHANICAL_PATHS:-(empty)}, max_prs=${AUTO_REBASE_MAX_PRS}, model=${AUTO_REBASE_MODEL}, max_turns=${AUTO_REBASE_MAX_TURNS}, timeout=${AUTO_REBASE_MAX_TURNS_SEC}s)"

  # Req 2.1〜2.5 / Req 8.4: 候補 PR 取得（API エラー時は空配列を扱う）
  local prs_json
  prs_json=$(ar_fetch_candidates) || true
  if [ -z "$prs_json" ]; then
    prs_json="[]"
  fi

  local total
  total=$(echo "$prs_json" | jq 'length' 2>/dev/null || echo 0)
  local target_count="$total"
  local skipped_overflow=0
  if [ "$total" -gt "$AUTO_REBASE_MAX_PRS" ]; then
    target_count="$AUTO_REBASE_MAX_PRS"
    skipped_overflow=$((total - AUTO_REBASE_MAX_PRS))
    ar_log "対象候補 ${total} 件中、上限 ${AUTO_REBASE_MAX_PRS} 件のみ処理（${skipped_overflow} 件は次回持ち越し）"
  else
    ar_log "対象候補 ${total} 件、処理対象 ${target_count} 件"
  fi

  local mechanical=0 semantic=0 failed=0 skipped=0

  if [ "$target_count" -gt 0 ]; then
    local pr_iter
    pr_iter=$(echo "$prs_json" | jq -c ".[0:${target_count}][]")

    if [ -n "$pr_iter" ]; then
      while IFS= read -r pr_json; do
        local rc=0
        ar_handle_pr "$pr_json" || rc=$?
        case "$rc" in
          0)  mechanical=$((mechanical + 1)) ;;
          1)  semantic=$((semantic + 1)) ;;
          2)  failed=$((failed + 1)) ;;
          10) skipped=$((skipped + 1)) ;;
          *)  failed=$((failed + 1)) ;;
        esac
      done <<< "$pr_iter"
    fi
  fi

  # Req 3.4 / NFR 2.2: サマリ行 1 件
  ar_log "サマリ: mechanical=${mechanical}, semantic=${semantic}, failed=${failed}, skip=${skipped}, overflow=${skipped_overflow}"

  # NFR 5.2 / Phase A pattern: 念のため最終確認で base branch に戻す
  git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
}
