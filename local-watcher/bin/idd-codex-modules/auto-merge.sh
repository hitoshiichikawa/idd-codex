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
#   LABEL_NEEDS_ITERATION, LABEL_NEEDS_REBASE,
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

# PR ラベル一覧に特定ラベルが含まれるかを判定する。
am_pr_has_label() {
  local pr_json="$1"
  local label="$2"
  printf '%s' "$pr_json" | jq -e --arg l "$label" '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1
}

# PR Reviewer marker comment 群から current head SHA の approve signal を解決する。
# stdout: approved|idd-codex-marker / rejected|iteration-marker / rejected|stale-marker /
#         rejected|malformed-marker / rejected|none
am_resolve_marker_approval_signal() {
  local comments_json="$1"
  local head_sha="$2"
  local trusted_assoc="${MERGE_QUEUE_TRUSTED_ASSOCIATIONS:-OWNER MEMBER COLLABORATOR}"

  local marker_state
  if ! marker_state=$(printf '%s\n' "$comments_json" | jq -r --arg sha "$head_sha" --arg trusted "$trusted_assoc" '
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
    ($trusted | ascii_upcase | split(" ")) as $trusted_set
    | [
      .[]?
      | select(((.author_association // "") | ascii_upcase) as $a | ($trusted_set | any(. == $a)))
      | (.body // "")
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
    am_warn "PR Reviewer marker comments の解析に失敗しました"
    printf 'unknown|marker-parse-error'
    return 1
  fi

  case "$marker_state" in
    current-approve) printf 'approved|idd-codex-marker' ;;
    current-blocking) printf 'rejected|iteration-marker' ;;
    stale-approve) printf 'rejected|stale-marker' ;;
    malformed)
      am_warn "PR Reviewer marker comment に malformed marker を検出しました"
      printf 'rejected|malformed-marker'
      ;;
    *) printf 'rejected|none' ;;
  esac
}

# GitHub reviewDecision と PR Reviewer current-SHA marker から review approval を解決する。
# stdout: approved|github-review / approved|idd-codex-marker / rejected|... / unknown|...
am_resolve_review_approval_signal() {
  local pr_json="$1"

  if printf '%s' "$pr_json" | jq -e '.reviewDecision == "APPROVED"' >/dev/null 2>&1; then
    printf 'approved|github-review'
    return 0
  fi

  local pr_number head_sha
  pr_number=$(printf '%s' "$pr_json" | jq -r '.number // empty' 2>/dev/null || echo "")
  head_sha=$(printf '%s' "$pr_json" | jq -r '.headRefOid // empty' 2>/dev/null || echo "")
  if [ -z "$pr_number" ] || [ -z "$head_sha" ]; then
    am_warn "review gate: PR number または headRefOid が取得できません"
    printf 'unknown|invalid-pr-json'
    return 1
  fi

  local comments_json
  if ! comments_json=$(timeout "$AUTO_MERGE_GIT_TIMEOUT" \
      gh api "/repos/${REPO}/issues/${pr_number}/comments" 2>/dev/null); then
    am_warn "PR #${pr_number}: review gate のコメント取得に失敗（auto-merge skip）"
    printf 'unknown|comments-api-error'
    return 1
  fi

  am_resolve_marker_approval_signal "$comments_json" "$head_sha"
}

# current head の statusCheckRollup から review gate status の成功を解決する。
# stdout: approved|status:<context> / rejected|status-* / unknown|status-malformed
am_resolve_status_gate_signal() {
  local pr_json="$1"
  local status_state
  if ! status_state=$(printf '%s' "$pr_json" | jq -r '
    def entries: (.statusCheckRollup // []);
    def item_name: (.context // .name // "");
    def raw_state: (.conclusion // .state // .status // .bucket // "");
    def norm_state: (raw_state | ascii_upcase);
    def is_success: (norm_state == "SUCCESS" or norm_state == "PASSED" or norm_state == "PASS");
    def is_pending: (norm_state == "PENDING" or norm_state == "EXPECTED" or
                     norm_state == "QUEUED" or norm_state == "IN_PROGRESS" or
                     norm_state == "WAITING" or norm_state == "REQUESTED");
    if ((.statusCheckRollup // null) == null) then
      "missing"
    elif ((entries | type) != "array") then
      "malformed"
    elif ((entries | length) == 0) then
      "empty"
    elif any(entries[]; (is_success | not)) then
      (if any(entries[]; is_pending) then "pending" else "failure" end)
    elif any(entries[]; ((item_name == "codex-review" or item_name == "claude-review") and is_success)) then
      "success"
    else
      "no-review-status"
    end
  ' 2>/dev/null); then
    am_warn "review gate: statusCheckRollup の解析に失敗（auto-merge skip）"
    printf 'unknown|status-malformed'
    return 1
  fi

  case "$status_state" in
    success) printf 'approved|status:review-check' ;;
    malformed)
      am_warn "review gate: statusCheckRollup が配列ではありません（auto-merge skip）"
      printf 'unknown|status-malformed'
      return 1
      ;;
    *) printf 'rejected|status-%s' "$status_state" ;;
  esac
}

# review approval と current-head status の両方が揃った場合だけ auto-merge を許可する。
# stdout: approved|<approval-source>+<status-source> / rejected|... / unknown|...
am_resolve_review_gate_for_pr() {
  local pr_json="$1"

  local approval_record approval_rc=0
  approval_record=$(am_resolve_review_approval_signal "$pr_json") || approval_rc=$?
  local approval_state approval_source
  approval_state="${approval_record%%|*}"
  approval_source="${approval_record#*|}"
  if [ "$approval_rc" -ne 0 ] || [ "$approval_state" != "approved" ]; then
    printf '%s' "$approval_record"
    return "$approval_rc"
  fi

  local status_record status_rc=0
  status_record=$(am_resolve_status_gate_signal "$pr_json") || status_rc=$?
  local status_state status_source
  status_state="${status_record%%|*}"
  status_source="${status_record#*|}"
  if [ "$status_rc" -ne 0 ] || [ "$status_state" != "approved" ]; then
    printf '%s' "$status_record"
    return "$status_rc"
  fi

  printf 'approved|%s+%s' "$approval_source" "$status_source"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# am_should_enable_for_pr: 1 PR が auto-merge 有効化の対象かを判定する
#   入力: $1 = pr_json（候補配列の単一要素）
#   戻り値: 0 = enable 対象 / 1 = skip（対象外）/ 2 = 既に auto-merge 有効（冪等 skip）
#   副作用: なし（jq 評価のみ）
# ─────────────────────────────────────────────────────────────────────────────
am_should_enable_for_pr() {
  local pr_json="$1"
  local head_ref is_draft mergeable auto_merge

  head_ref=$(printf '%s' "$pr_json" | jq -r '.headRefName // ""')
  is_draft=$(printf '%s' "$pr_json" | jq -r '.isDraft // false')
  mergeable=$(printf '%s' "$pr_json" | jq -r '.mergeable // "UNKNOWN"')
  auto_merge=$(printf '%s' "$pr_json" | jq -r '.autoMergeRequest // "null"')

  # head pattern（実装 PR のみ）
  if ! printf '%s' "$head_ref" | grep -qE -- "$AUTO_MERGE_HEAD_PATTERN"; then
    return 1
  fi
  # draft は対象外
  if [ "$is_draft" = "true" ]; then
    return 1
  fi
  # ready-for-review 必須
  if ! am_pr_has_label "$pr_json" "$LABEL_READY"; then
    return 1
  fi
  # blocking label が付いていたら対象外（人間 / iteration / rebase gate）
  local blocking_label
  for blocking_label in \
      "$LABEL_FAILED" \
      "$LABEL_NEEDS_DECISIONS" \
      "${LABEL_NEEDS_ITERATION:-codex-needs-iteration}" \
      "${LABEL_NEEDS_REBASE:-codex-needs-rebase}"; do
    if am_pr_has_label "$pr_json" "$blocking_label"; then
      return 1
    fi
  done
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
  local pr_number="$1" head_ref="$2" head_sha="$3" pr_url="$4" gate_source="${5:-unknown}"

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
    am_log "PR #${pr_number}: auto-merge enabled (squash, delete-branch) review_gate=${gate_source} head=${head_ref} sha=${head_sha} url=${pr_url}"
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
      --json number,headRefName,headRefOid,baseRefName,mergeable,labels,url,isDraft,headRepositoryOwner,autoMergeRequest,reviewDecision,statusCheckRollup \
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
        local gate_record gate_rc=0 gate_state gate_source
        gate_record=$(am_resolve_review_gate_for_pr "$pr_json") || gate_rc=$?
        gate_state="${gate_record%%|*}"
        gate_source="${gate_record#*|}"
        if [ "$gate_rc" -ne 0 ] || [ "$gate_state" != "approved" ]; then
          skipped=$((skipped + 1))
          am_log "PR #${pr_number}: auto-merge skip: review gate missing reason=${gate_source} head=${head_ref} sha=${head_sha}"
          continue
        fi
        am_log "PR #${pr_number}: review gate accepted source=${gate_source} head=${head_ref} sha=${head_sha}"
        if am_enable_auto_merge_for_pr "$pr_number" "$head_ref" "$head_sha" "$pr_url" "$gate_source"; then
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
