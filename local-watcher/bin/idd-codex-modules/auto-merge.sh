#!/usr/bin/env bash
# auto-merge.sh — watcher の実装 PR auto-merge プロセッサモジュール (#99)
#
# 用途:
#   `codex-ready-for-review` の実装 PR に対し GitHub ネイティブ auto-merge を有効化する
#   （`gh pr merge --auto --squash --delete-branch`）。watcher は **直接 merge せず**、
#   実 merge は GitHub が必須 status check（CI + `codex-review`（+2nd gate `claude-review`））
#   全 green + mergeable に到達した時点で squash 実行する。CONFLICTING は本モジュールが
#   触らず、既存 merge-queue / auto-rebase 経路（dispatcher 上で先行）に委譲する。
#
#   完全自動化 kill switch `FULL_AUTO_ENABLED`（#97）と `AUTO_MERGE_ENABLED` の **AND 二重
#   opt-in** で動き、いずれか OFF（既定）では外部副作用ゼロで no-op（導入前と等価）。
#
#   ロガー（am_log / am_warn / am_error）は core_utils.sh にあるため再定義しない。
#   関連: README オプション機能一覧 / Issue #99。
#
# 依存グローバル: REPO, LABEL_READY, LABEL_FAILED, LABEL_NEEDS_DECISIONS,
#   AUTO_MERGE_ENABLED, AUTO_MERGE_MAX_PRS, AUTO_MERGE_GIT_TIMEOUT,
#   AUTO_MERGE_HEAD_PATTERN, full_auto_enabled()(#97)

# ─────────────────────────────────────────────────────────────────────────────
# am_resolve_gate_enabled: AUTO_MERGE_ENABLED 個別 gate の判定（純粋関数）
#   戻り値: 0 = ON（=true 厳密一致）/ 1 = OFF（未設定 / 空 / False / 1 / on / typo）
# ─────────────────────────────────────────────────────────────────────────────
am_resolve_gate_enabled() {
  case "${AUTO_MERGE_ENABLED:-false}" in
    true) return 0 ;;
    *) return 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# am_should_enable_for_pr: 1 PR が auto-merge 有効化の対象かを判定する
#   入力: $1 = pr_json（候補配列の単一要素）
#   戻り値: 0 = enable 対象 / 1 = skip（対象外）/ 2 = 既に auto-merge 有効（冪等 skip）
#   副作用: なし（jq 評価のみ）
# ─────────────────────────────────────────────────────────────────────────────
am_should_enable_for_pr() {
  local pr_json="$1"
  local head_ref is_draft mergeable auto_merge has_ready has_failed has_nd

  head_ref=$(printf '%s' "$pr_json" | jq -r '.headRefName // ""')
  is_draft=$(printf '%s' "$pr_json" | jq -r '.isDraft // false')
  mergeable=$(printf '%s' "$pr_json" | jq -r '.mergeable // "UNKNOWN"')
  auto_merge=$(printf '%s' "$pr_json" | jq -r '.autoMergeRequest // "null"')
  has_ready=$(printf '%s' "$pr_json" | jq -r --arg l "$LABEL_READY" '.labels // [] | map(.name) | index($l) // "no"')
  has_failed=$(printf '%s' "$pr_json" | jq -r --arg l "$LABEL_FAILED" '.labels // [] | map(.name) | index($l) // "no"')
  has_nd=$(printf '%s' "$pr_json" | jq -r --arg l "$LABEL_NEEDS_DECISIONS" '.labels // [] | map(.name) | index($l) // "no"')

  # head pattern（実装 PR のみ）
  if ! printf '%s' "$head_ref" | grep -qE -- "$AUTO_MERGE_HEAD_PATTERN"; then
    return 1
  fi
  # draft は対象外
  if [ "$is_draft" = "true" ]; then
    return 1
  fi
  # ready-for-review 必須
  if [ "$has_ready" = "no" ]; then
    return 1
  fi
  # failed / needs-decisions が付いていたら対象外（人間ゲート）
  if [ "$has_failed" != "no" ]; then
    return 1
  fi
  if [ "$has_nd" != "no" ]; then
    return 1
  fi
  # MERGEABLE 以外（CONFLICTING / UNKNOWN）は触らない（merge-queue/auto-rebase へ委譲）
  if [ "$mergeable" != "MERGEABLE" ]; then
    return 1
  fi
  # 既に auto-merge 有効なら冪等 skip
  if [ "$auto_merge" != "null" ]; then
    return 2
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# am_enable_auto_merge_for_pr: 1 PR に GitHub native auto-merge を有効化する
#   入力: $1=pr_number $2=head_ref $3=head_sha $4=pr_url
#   戻り値: 0 = 有効化成功 / 1 = 失敗（WARN 済み・パイプライン継続）
#   副作用: gh pr merge --auto --squash --delete-branch（実 merge は GitHub 任せ）
# ─────────────────────────────────────────────────────────────────────────────
am_enable_auto_merge_for_pr() {
  local pr_number="$1" head_ref="$2" head_sha="$3" pr_url="$4"

  if ! printf '%s' "$pr_number" | grep -qE '^[0-9]+$'; then
    am_warn "auto-merge 有効化を skip: 不正な pr_number='${pr_number}'"
    return 1
  fi

  local stderr_file rc=0
  stderr_file=$(idd_secure_mktemp "auto-merge-${pr_number}" 2>/dev/null || true)
  if [ -n "$stderr_file" ]; then
    timeout "$AUTO_MERGE_GIT_TIMEOUT" \
      gh pr merge --repo "$REPO" --auto --squash --delete-branch -- "$pr_number" \
      >/dev/null 2>"$stderr_file" || rc=$?
  else
    timeout "$AUTO_MERGE_GIT_TIMEOUT" \
      gh pr merge --repo "$REPO" --auto --squash --delete-branch -- "$pr_number" \
      >/dev/null 2>&1 || rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    [ -n "$stderr_file" ] && rm -f "$stderr_file"
    am_log "PR #${pr_number}: auto-merge enabled (squash, delete-branch) head=${head_ref} sha=${head_sha} url=${pr_url}"
    return 0
  fi

  # 失敗を stderr 内容で分類（silent fail せず WARN）
  local err_tail="" category="api-error"
  if [ -n "$stderr_file" ]; then
    err_tail=$(tail -c 512 "$stderr_file" 2>/dev/null | tr '\n' ' ')
    rm -f "$stderr_file"
  fi
  case "$err_tail" in
    *"could not resolve host"*|*[Nn]etwork*|*timeout*|*"connection"*) category="transport-error" ;;
    *"branch protection"*|*"not allowed"*|*"auto merge"*|*"Auto-merge"*|*"not enabled"*) category="repo-config-rejected" ;;
  esac
  am_warn "PR #${pr_number}: auto-merge 有効化に失敗 (${category}, rc=${rc}) stderr='${err_tail}'"
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# process_auto_merge: dispatcher エントリ（毎サイクル呼ばれる）
#   戻り値: 0 固定（後続 processor を阻害しない / dispatcher fail-continue 契約）
#   gate: full_auto_enabled(#97) AND am_resolve_gate_enabled の AND 二重 opt-in
# ─────────────────────────────────────────────────────────────────────────────
process_auto_merge() {
  # AND 二重 opt-in。kill switch OFF は #97 ログに委ね本関数では無言で return。
  if ! full_auto_enabled; then
    return 0
  fi
  if ! am_resolve_gate_enabled; then
    am_log "suppressed by AUTO_MERGE_ENABLED gate (no-op)"
    return 0
  fi

  local repo_owner="${REPO%%/*}"
  local prs_json
  if ! prs_json=$(timeout "$AUTO_MERGE_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" --state open \
      --search "label:\"$LABEL_READY\" -label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_DECISIONS\" -draft:true" \
      --json number,headRefName,headRefOid,baseRefName,mergeable,labels,url,isDraft,headRepositoryOwner,autoMergeRequest \
      --limit 50 2>/dev/null); then
    am_warn "対象 PR 一覧の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    return 0
  fi

  # client-side: draft 除外 + head pattern + fork 除外
  local filtered
  filtered=$(printf '%s' "$prs_json" | jq -c --arg pat "$AUTO_MERGE_HEAD_PATTERN" --arg owner "$repo_owner" \
    '[ .[] | select((.isDraft // false) == false) | select((.headRefName // "") | test($pat)) | select((.headRepositoryOwner.login // "") == $owner) ]' 2>/dev/null || echo "[]")

  local total target_count
  total=$(printf '%s' "$filtered" | jq -r 'length' 2>/dev/null || echo 0)
  if [ "$total" -eq 0 ]; then
    return 0
  fi
  target_count="$total"
  local overflow=0
  if [ "$total" -gt "$AUTO_MERGE_MAX_PRS" ]; then
    target_count="$AUTO_MERGE_MAX_PRS"
    overflow=$((total - AUTO_MERGE_MAX_PRS))
  fi

  local enabled=0 skipped=0 already=0 failed=0
  local pr_iter
  pr_iter=$(printf '%s' "$filtered" | jq -c ".[0:${target_count}][]" 2>/dev/null || echo "")
  while IFS= read -r pr_json; do
    [ -z "$pr_json" ] && continue
    local pr_number head_ref head_sha pr_url
    pr_number=$(printf '%s' "$pr_json" | jq -r '.number')
    head_ref=$(printf '%s' "$pr_json" | jq -r '.headRefName')
    head_sha=$(printf '%s' "$pr_json" | jq -r '.headRefOid')
    pr_url=$(printf '%s' "$pr_json" | jq -r '.url')

    am_should_enable_for_pr "$pr_json"
    case $? in
      0)
        if am_enable_auto_merge_for_pr "$pr_number" "$head_ref" "$head_sha" "$pr_url"; then
          enabled=$((enabled + 1))
        else
          failed=$((failed + 1))
        fi
        ;;
      2)
        already=$((already + 1))
        am_log "PR #${pr_number}: auto-merge は既に有効（skip）"
        ;;
      *)
        skipped=$((skipped + 1))
        ;;
    esac
  done <<< "$pr_iter"

  am_log "auto-merge summary: enabled=${enabled} already-enabled=${already} skipped=${skipped} failed=${failed} overflow=${overflow}"
  return 0
}
