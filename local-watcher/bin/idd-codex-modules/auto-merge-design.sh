#!/usr/bin/env bash
# auto-merge-design.sh — watcher の設計 PR auto-merge プロセッサモジュール (#100)
#
# 用途:
#   設計 PR（head `^codex/issue-.*-design`）に GitHub ネイティブ auto-merge を有効化する。
#   実装 PR 版（auto-merge.sh / #99）の設計 PR 版で、`gh pr merge --auto --squash
#   --delete-branch` で enable し、実 merge は GitHub が必須 status check（CI + 設計レビュー
#   status）全 green + mergeable 到達時に行う。merge 後の `codex-awaiting-design-review`
#   除去は既存 Design Review Release Processor（DESIGN_REVIEW_RELEASE_ENABLED）が担当する。
#
#   設計 PR には `codex-ready-for-review` が付かないため、impl 版（#99）と異なり **positive な
#   ready ラベル必須条件は付けない**（head pattern + 否定ラベル + mergeable で判定）。
#   `AUTO_MERGE_DESIGN_ENABLED` と `FULL_AUTO_ENABLED`（#97）の AND 二重 opt-in。
#
#   ロガー（amd_log / amd_warn / amd_error）は core_utils.sh にあるため再定義しない。
#   関連: README オプション機能一覧 / Issue #100。
#
# 依存グローバル: REPO, LABEL_FAILED, LABEL_NEEDS_DECISIONS, LABEL_NEEDS_ITERATION,
#   AUTO_MERGE_DESIGN_ENABLED, AUTO_MERGE_DESIGN_MAX_PRS, AUTO_MERGE_DESIGN_GIT_TIMEOUT,
#   AUTO_MERGE_DESIGN_HEAD_PATTERN, full_auto_enabled()(#97)

# ─────────────────────────────────────────────────────────────────────────────
# amd_resolve_gate_enabled: AUTO_MERGE_DESIGN_ENABLED 個別 gate 判定（純粋関数）
# ─────────────────────────────────────────────────────────────────────────────
amd_resolve_gate_enabled() {
  case "${AUTO_MERGE_DESIGN_ENABLED:-false}" in
    true) return 0 ;;
    *) return 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# amd_should_enable_for_pr: 1 設計 PR が auto-merge 有効化の対象かを判定する
#   入力: $1 = pr_json
#   戻り値: 0 = enable 対象 / 1 = skip / 2 = 既に auto-merge 有効（冪等 skip）
#   設計 PR は positive ready ラベルを持たないため、head pattern + 否定ラベル + mergeable で判定。
# ─────────────────────────────────────────────────────────────────────────────
amd_should_enable_for_pr() {
  local pr_json="$1"
  local head_ref is_draft mergeable auto_merge has_failed has_nd has_iter

  head_ref=$(printf '%s' "$pr_json" | jq -r '.headRefName // ""')
  is_draft=$(printf '%s' "$pr_json" | jq -r '.isDraft // false')
  mergeable=$(printf '%s' "$pr_json" | jq -r '.mergeable // "UNKNOWN"')
  auto_merge=$(printf '%s' "$pr_json" | jq -r '.autoMergeRequest // "null"')
  has_failed=$(printf '%s' "$pr_json" | jq -r --arg l "$LABEL_FAILED" '.labels // [] | map(.name) | index($l) // "no"')
  has_nd=$(printf '%s' "$pr_json" | jq -r --arg l "$LABEL_NEEDS_DECISIONS" '.labels // [] | map(.name) | index($l) // "no"')
  has_iter=$(printf '%s' "$pr_json" | jq -r --arg l "$LABEL_NEEDS_ITERATION" '.labels // [] | map(.name) | index($l) // "no"')

  # head pattern（設計 PR のみ。impl PR は不一致で自動排他）
  if ! printf '%s' "$head_ref" | grep -qE -- "$AUTO_MERGE_DESIGN_HEAD_PATTERN"; then
    return 1
  fi
  if [ "$is_draft" = "true" ]; then
    return 1
  fi
  # failed / needs-decisions / needs-iteration が付いていたら対象外
  if [ "$has_failed" != "no" ]; then
    return 1
  fi
  if [ "$has_nd" != "no" ]; then
    return 1
  fi
  if [ "$has_iter" != "no" ]; then
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
# amd_enable_auto_merge_for_pr: 1 設計 PR に GitHub native auto-merge を有効化する
#   入力: $1=pr_number $2=head_ref $3=head_sha $4=pr_url
#   戻り値: 0 = 成功 / 1 = 失敗（WARN 済み・継続）
# ─────────────────────────────────────────────────────────────────────────────
amd_enable_auto_merge_for_pr() {
  local pr_number="$1" head_ref="$2" head_sha="$3" pr_url="$4"

  if ! printf '%s' "$pr_number" | grep -qE '^[0-9]+$'; then
    amd_warn "auto-merge 有効化を skip: 不正な pr_number='${pr_number}'"
    return 1
  fi

  local stderr_file rc=0
  stderr_file=$(idd_secure_mktemp "auto-merge-design-${pr_number}" 2>/dev/null || true)
  if [ -n "$stderr_file" ]; then
    timeout "$AUTO_MERGE_DESIGN_GIT_TIMEOUT" \
      gh pr merge --repo "$REPO" --auto --squash --delete-branch -- "$pr_number" \
      >/dev/null 2>"$stderr_file" || rc=$?
  else
    timeout "$AUTO_MERGE_DESIGN_GIT_TIMEOUT" \
      gh pr merge --repo "$REPO" --auto --squash --delete-branch -- "$pr_number" \
      >/dev/null 2>&1 || rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    [ -n "$stderr_file" ] && rm -f "$stderr_file"
    amd_log "PR #${pr_number}: design auto-merge enabled (squash, delete-branch) head=${head_ref} sha=${head_sha} url=${pr_url}"
    return 0
  fi

  local err_tail="" category="api-error"
  if [ -n "$stderr_file" ]; then
    err_tail=$(tail -c 512 "$stderr_file" 2>/dev/null | tr '\n' ' ')
    rm -f "$stderr_file"
  fi
  case "$err_tail" in
    *"could not resolve host"*|*[Nn]etwork*|*timeout*|*"connection"*) category="transport-error" ;;
    *"branch protection"*|*"not allowed"*|*"auto merge"*|*"Auto-merge"*|*"not enabled"*) category="repo-config-rejected" ;;
  esac
  amd_warn "PR #${pr_number}: design auto-merge 有効化に失敗 (${category}, rc=${rc}) stderr='${err_tail}'"
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# process_auto_merge_design: dispatcher エントリ（毎サイクル）
#   gate: full_auto_enabled(#97) AND amd_resolve_gate_enabled
# ─────────────────────────────────────────────────────────────────────────────
process_auto_merge_design() {
  if ! full_auto_enabled; then
    return 0
  fi
  if ! amd_resolve_gate_enabled; then
    amd_log "suppressed by AUTO_MERGE_DESIGN_ENABLED gate (no-op)"
    return 0
  fi

  local repo_owner="${REPO%%/*}"
  local prs_json
  # 設計 PR には positive ready ラベルが無いため、否定ラベル + draft 除外で取得し head pattern で絞る。
  if ! prs_json=$(timeout "$AUTO_MERGE_DESIGN_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" --state open \
      --search "-label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_NEEDS_ITERATION\" -draft:true" \
      --json number,headRefName,headRefOid,baseRefName,mergeable,labels,url,isDraft,headRepositoryOwner,autoMergeRequest \
      --limit 50 2>/dev/null); then
    amd_warn "対象設計 PR 一覧の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    return 0
  fi

  local filtered
  filtered=$(printf '%s' "$prs_json" | jq -c --arg pat "$AUTO_MERGE_DESIGN_HEAD_PATTERN" --arg owner "$repo_owner" \
    '[ .[] | select((.isDraft // false) == false) | select((.headRefName // "") | test($pat)) | select((.headRepositoryOwner.login // "") == $owner) ]' 2>/dev/null || echo "[]")

  local total target_count
  total=$(printf '%s' "$filtered" | jq -r 'length' 2>/dev/null || echo 0)
  if [ "$total" -eq 0 ]; then
    return 0
  fi
  target_count="$total"
  local overflow=0
  if [ "$total" -gt "$AUTO_MERGE_DESIGN_MAX_PRS" ]; then
    target_count="$AUTO_MERGE_DESIGN_MAX_PRS"
    overflow=$((total - AUTO_MERGE_DESIGN_MAX_PRS))
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

    amd_should_enable_for_pr "$pr_json"
    case $? in
      0)
        if amd_enable_auto_merge_for_pr "$pr_number" "$head_ref" "$head_sha" "$pr_url"; then
          enabled=$((enabled + 1))
        else
          failed=$((failed + 1))
        fi
        ;;
      2)
        already=$((already + 1))
        amd_log "PR #${pr_number}: design auto-merge は既に有効（skip）"
        ;;
      *)
        skipped=$((skipped + 1))
        ;;
    esac
  done <<< "$pr_iter"

  amd_log "design auto-merge summary: enabled=${enabled} already-enabled=${already} skipped=${skipped} failed=${failed} overflow=${overflow}"
  return 0
}
