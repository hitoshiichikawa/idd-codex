#!/usr/bin/env bash
# merge-queue.sh — watcher の Merge Queue 制御プロセッサモジュール
#
# 用途:
#   idd-codex-issue-watcher.sh から切り出した approved PR のマージ順序制御・再チェックプロセッサを
#   集約する。
#   Phase A 本体（process_merge_queue）: approve 済み open PR の mergeability を能動検知し、
#     CONFLICTING には codex-needs-rebase ラベル + 状況コメント、MERGEABLE かつ base が古い場合は
#     ローカル自動 rebase + force-with-lease push を行う。
#   Phase A Re-check（process_merge_queue_recheck）: codex-needs-rebase 付き approved PR を別レーンで
#     再評価し、mergeable=MERGEABLE に戻った PR のラベルを自動除去する。
#   - mq_pr_has_label / mq_handle_conflict / mq_try_rebase_pr / process_merge_queue
#   - mqr_log / mqr_warn / mqr_error : merge-queue-recheck 専用ロガー
#     （core_utils.sh には無く本体由来のため本モジュールへ移す）
#   - process_merge_queue_recheck
#
# 配置先:
#   $HOME/bin/idd-codex-modules/merge-queue.sh（install.sh が local-watcher/bin/idd-codex-modules/ から配置する）
#
# 依存:
#   - 本モジュールは idd-codex-issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー（mq_log / mq_warn / mq_error）は core_utils.sh にあるため再定義しない。
#     mqr_* は本体由来のため本モジュールに移す（core_utils.sh は変更しない）。
#   - グローバル変数（$MERGE_QUEUE_ENABLED / $MERGE_QUEUE_RECHECK_ENABLED /
#     $MERGE_QUEUE_GIT_TIMEOUT / $LABEL_NEEDS_REBASE / $MERGE_QUEUE_BASE_BRANCH 等）は
#     本体冒頭の Config ブロックで定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - 外部 CLI: gh / git / jq。
#
# セットアップ参照先:
#   README.md（ディレクトリ構成・modules 化 migration note） / install.sh（配置ロジック）

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase A: Merge Queue Processor
#   approve 済み open PR の mergeability を能動的に検知し:
#     - CONFLICTING: codex-needs-rebase ラベル + 状況コメント（人間判断に回す）
#     - MERGEABLE かつ base が古い: ローカルで自動 rebase + force-with-lease push
#   標準機能としてデフォルト有効（#112）。無効化は MERGE_QUEUE_ENABLED=false で明示。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# PR ラベル一覧に特定ラベルが含まれるかを判定（jq で labels 配列を走査）
mq_pr_has_label() {
  local pr_json="$1"
  local label="$2"
  echo "$pr_json" | jq -e --arg l "$label" '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1
}

# PR JSON の GitHub formal review approval を判定する。
mq_pr_review_decision_approved() {
  local pr_json="$1"
  printf '%s\n' "$pr_json" | jq -e '.reviewDecision == "APPROVED"' >/dev/null 2>&1
}

# PR Reviewer comment marker 群から current head SHA に対する marker approval を解決する。
# stdout: approved|idd-codex-marker / rejected|iteration-marker / rejected|stale-marker /
#         rejected|malformed-marker / rejected|none
mq_resolve_marker_approval_signal() {
  local comments_json="$1"
  local head_sha="$2"

  local marker_state
  if ! marker_state=$(printf '%s\n' "$comments_json" | jq -r --arg sha "$head_sha" '
    def has_approve_verdict:
      test("(^|[\r\n])[[:space:]]*VERDICT:[[:space:]]*approve[[:space:]]*($|[\r\n])"; "i");
    def has_blocking_verdict:
      test("(^|[\r\n])[[:space:]]*VERDICT:[[:space:]]*(codex-needs-iteration|reject|rejected)[[:space:]]*($|[\r\n])"; "i");
    def marker_attr_verdict:
      if test("verdict=(approve|iteration|codex-needs-iteration|reject|rejected)"; "i") then
        (match("verdict=(approve|iteration|codex-needs-iteration|reject|rejected)"; "i").captures[0].string | ascii_downcase)
      else "" end;
    def marker_record:
      . as $body
      | "idd-codex:pr-reviewer[[:space:]][^>]*sha=([^[:space:]>]+)[^>]*kind=review" as $marker_pattern
      | if (($body | test($marker_pattern)) | not) then
          {valid: false, malformed: true, sha: "", verdict: "none"}
        else
          ($body | match($marker_pattern)) as $m
          | (has_approve_verdict) as $body_approve
          | (has_blocking_verdict) as $body_blocking
          | (marker_attr_verdict) as $attr_verdict
          | ($attr_verdict == "approve") as $attr_approve
          | ($attr_verdict == "iteration" or $attr_verdict == "codex-needs-iteration" or
             $attr_verdict == "reject" or $attr_verdict == "rejected") as $attr_blocking
          | {valid: true,
             malformed: false,
             sha: $m.captures[0].string,
             verdict:
               (if ($body_blocking or $attr_blocking) then "blocking"
                elif ($body_approve or $attr_approve) then "approve"
                else "none" end)}
        end;
    [
      (.[]?.body // "")
      | select(test("idd-codex:pr-reviewer"; "i") and test("kind=review"; "i"))
      | marker_record
    ] as $records
    | if any($records[]; .valid and .sha == $sha and .verdict == "blocking") then
        "current-blocking"
      elif any($records[]; .valid and .sha == $sha and .verdict == "approve") then
        "current-approve"
      elif any($records[]; .valid and .sha != $sha and .verdict == "approve") then
        "stale-approve"
      elif any($records[]; .malformed) then
        "malformed"
      else
        "none"
      end
  ' 2>/dev/null); then
    mq_warn "PR Reviewer marker comments の解析に失敗しました"
    printf 'unknown|api-error'
    return 1
  fi

  case "$marker_state" in
    current-approve)
      printf 'approved|idd-codex-marker'
      ;;
    current-blocking)
      printf 'rejected|iteration-marker'
      ;;
    stale-approve)
      printf 'rejected|stale-marker'
      ;;
    malformed)
      mq_warn "PR Reviewer marker comment に malformed marker を検出しました"
      printf 'rejected|malformed-marker'
      ;;
    *)
      printf 'rejected|none'
      ;;
  esac
}

# GitHub reviewDecision と PR Reviewer current-SHA marker から Merge Queue approval を解決する。
# stdout: approved|github / approved|idd-codex-marker / rejected|... / unknown|...
# rc: 0=approved/rejected を安全に解決, 1=API failure 等により unknown（merge しない）
mq_resolve_approval_signal() {
  local pr_json="$1"

  if mq_pr_review_decision_approved "$pr_json"; then
    printf 'approved|github'
    return 0
  fi

  local pr_number head_sha
  pr_number=$(printf '%s\n' "$pr_json" | jq -r '.number // empty' 2>/dev/null || echo "")
  head_sha=$(printf '%s\n' "$pr_json" | jq -r '.headRefOid // empty' 2>/dev/null || echo "")
  if [ -z "$pr_number" ] || [ -z "$head_sha" ]; then
    mq_warn "approval resolver: PR number または headRefOid が取得できません"
    printf 'unknown|invalid-pr-json'
    return 1
  fi

  local comments_json timeout_sec
  timeout_sec="${MERGE_QUEUE_GIT_TIMEOUT:-60}"
  if ! comments_json=$(timeout "$timeout_sec" \
      gh api "/repos/${REPO}/issues/${pr_number}/comments" 2>/dev/null); then
    mq_warn "PR #${pr_number}: approval resolver のコメント取得に失敗（not-approved として扱います）"
    printf 'unknown|api-error'
    return 1
  fi

  local record rc=0
  record=$(mq_resolve_marker_approval_signal "$comments_json" "$head_sha") || rc=$?
  printf '%s' "$record"
  return "$rc"
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
  read -r -d '' comment_body <<EOF || true
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
#   独立に制御可能。標準機能としてデフォルト有効化（#112）。無効化したい場合は
#   MERGE_QUEUE_RECHECK_ENABLED=false を明示する。ラベル除去のみを副作用とし、
#   再 rebase / コメント投稿は Phase A 本体に委譲。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# merge-queue-recheck 専用ロガー（Phase A 本体の `merge-queue:` と区別する prefix）。
# AC 5.5 / 5.6 / NFR 3.2: `merge-queue-recheck:` prefix と既存 timestamp 書式に統一。
# Issue #119 Req 1.3 / 1.6: 時刻 prefix と processor prefix の間に `[$REPO]` を挿入。
mqr_log() {
  echo "[$(date '+%F %T')] [$REPO] merge-queue-recheck: $*"
}
mqr_warn() {
  echo "[$(date '+%F %T')] [$REPO] merge-queue-recheck: WARN: $*" >&2
}
mqr_error() {
  echo "[$(date '+%F %T')] [$REPO] merge-queue-recheck: ERROR: $*" >&2
}

process_merge_queue_recheck() {
  # AC 1.2 / 1.3 / 3.1 / 3.3: opt-out gate（#112 以降デフォルト有効 / MERGE_QUEUE_ENABLED とは独立）
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
