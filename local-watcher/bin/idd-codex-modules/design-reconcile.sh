#!/usr/bin/env bash
# design-reconcile.sh — design モード終了後のラベル整合と merge 直後 race の緩和（Issue #180）
#
# 用途:
#   design PR の merge 直後に watcher tick が走ると、サイクル冒頭の `git fetch` が merge commit を
#   まだ含まず、slot worktree が古い `origin/$BASE_BRANCH` へ reset される。spec 未検出のため
#   design モードが再起動され、design agent が実行中に最新 origin を fetch して「設計は既に
#   merge 済み」と判断し **新規 PR を作らず正常終了**（rc=0）すると、design ルートは
#   `codex-claimed → codex-awaiting-design-review` の付け替えを PjM（agent 側）に委ねているため
#   `codex-claimed` が残留し、dispatcher が「処理中」とみなして当該 Issue を永久除外する。
#
#   本モジュールは 2 箇所で介入する（いずれも fail-open）:
#   - dnr_refresh_base_ref        : Design Review Release Processor が merged 設計 PR を検出して
#                                   ラベルを外した直後（dispatch 前・親プロセス）に
#                                   `git fetch origin $BASE_BRANCH` を 1 回行い、同サイクルの slot が
#                                   merge 済み spec を見られるようにする（race の一次緩和）
#   - dnr_reconcile_after_design  : design モード rc=0 の直後にラベル状態を検証し、
#                                   `codex-awaiting-design-review` へ遷移していない場合は
#                                   merged 設計 PR あり → claim 系ラベル除去（次 tick で impl-resume）
#                                   open 設計 PR あり   → awaiting-design-review へ補完遷移
#                                   どちらも無し        → design-no-pr として codex-failed（人間判断）
#
#   - dnr_is_enabled             : `DESIGN_NOOP_RECONCILE_ENABLED=false` 厳密一致のみ無効（既定 有効）
#   - dnr_issue_label_names      : Issue のラベル名一覧（1 行 1 ラベル）
#   - dnr_has_label              : ラベル名一覧に指定ラベルが含まれるか（純粋関数）
#   - dnr_find_open_design_pr    : head が `codex/issue-<N>-design-` の open PR 番号（最大番号）
#   - dnr_find_design_pr_with_retry : merged → open の順に設計 PR を探し、eventual consistency の
#                                   取りこぼしを bounded retry で吸収する
#
# 配置先:
#   $HOME/bin/idd-codex-modules/design-reconcile.sh（install.sh が local-watcher/bin/idd-codex-modules/ から配置）
#
# 依存:
#   - 本モジュールは idd-codex-issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー（dnr_log / dnr_warn / dnr_error）は core_utils.sh にあるため再定義しない。
#   - 本体の関数へ前方参照: drr_find_merged_design_pr（merged 設計 PR 検出）/ _slot_mark_failed。
#   - グローバル: $REPO / $REPO_DIR / $BASE_BRANCH / $LABEL_CLAIMED / $LABEL_PICKED /
#     $LABEL_AWAITING_DESIGN / $DRR_GH_TIMEOUT / $DESIGN_NOOP_RECONCILE_ENABLED / $DNR_PR_LOOKUP_RETRY_SLEEP
#   - 外部 CLI: gh / jq / git / timeout / sleep。
#   - 関数 prefix `dnr_` を namespace として採用する。

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Gate Layer
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# 不具合修正のため既定 有効。`DESIGN_NOOP_RECONCILE_ENABLED=false`（lowercase 厳密一致）のみ無効。
#   0 = enabled / 1 = disabled
dnr_is_enabled() {
  [ "${DESIGN_NOOP_RECONCILE_ENABLED:-true}" != "false" ] || return 1
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Observation Layer（read-only）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Issue の現在ラベル名を 1 行 1 件で stdout に出力する。
#   Args: $1 = issue number / Returns: 0 = 取得成功 / 1 = API 失敗（stdout 空）
dnr_issue_label_names() {
  local issue_number="$1"
  local json
  if ! json=$(timeout "${DRR_GH_TIMEOUT:-60}" gh issue view "$issue_number" --repo "$REPO" --json labels 2>/dev/null); then
    return 1
  fi
  printf '%s' "$json" | jq -r '(.labels // [])[] | .name // empty' 2>/dev/null || return 1
  return 0
}

# ラベル名一覧（改行区切り文字列）に指定ラベルが含まれるか（純粋関数）。
#   Args: $1 = names（改行区切り）/ $2 = label / Returns: 0 = 含む / 1 = 含まない
dnr_has_label() {
  printf '%s\n' "${1:-}" | grep -qx -- "${2:-}"
}

# head branch が `codex/issue-<N>-design-` prefix で始まる **open** PR の番号を stdout に返す。
# 複数件は最大番号を採用。drr_find_merged_design_pr（merged 版）と同じ strict prefix 判定。
#   Args: $1 = issue number / Stdout: PR 番号 or 空 / Returns: 0 = 正常 / 1 = API 失敗
dnr_find_open_design_pr() {
  local issue_number="$1"
  local prs_json
  if ! prs_json=$(timeout "${DRR_GH_TIMEOUT:-60}" gh pr list \
      --repo "$REPO" --state open --json number,headRefName --limit 100 2>/dev/null); then
    return 1
  fi
  local prefix="codex/issue-${issue_number}-design-"
  printf '%s' "$prs_json" | jq -r --arg prefix "$prefix" \
    '[(. // [])[] | select((.headRefName // "") | startswith($prefix)) | .number] | max // empty' 2>/dev/null || true
  return 0
}

# merged → open の順に設計 PR を探す。GitHub の eventual consistency（PjM が直前に作成した PR が
# list に載るまでの遅延）を bounded retry（最大 2 回・間隔 DNR_PR_LOOKUP_RETRY_SLEEP 秒）で吸収する。
#   Args: $1 = issue number
#   Stdout: "merged <pr>" / "open <pr>" / "none" / "error"（両 API とも失敗）
#   Returns: 常に 0
dnr_find_design_pr_with_retry() {
  local issue_number="$1"
  local attempt=1 max_attempts=2 merged_pr open_pr merged_rc open_rc
  local sleep_sec="${DNR_PR_LOOKUP_RETRY_SLEEP:-5}"
  while [ "$attempt" -le "$max_attempts" ]; do
    merged_rc=0; open_rc=0; merged_pr=""; open_pr=""
    merged_pr=$(drr_find_merged_design_pr "$issue_number") || merged_rc=$?
    if [ "$merged_rc" -eq 0 ] && [ -n "$merged_pr" ]; then
      printf 'merged %s\n' "$merged_pr"
      return 0
    fi
    open_pr=$(dnr_find_open_design_pr "$issue_number") || open_rc=$?
    if [ "$open_rc" -eq 0 ] && [ -n "$open_pr" ]; then
      printf 'open %s\n' "$open_pr"
      return 0
    fi
    if [ "$merged_rc" -ne 0 ] && [ "$open_rc" -ne 0 ]; then
      printf 'error\n'
      return 0
    fi
    if [ "$attempt" -lt "$max_attempts" ]; then
      sleep "$sleep_sec" 2>/dev/null || true
    fi
    attempt=$((attempt + 1))
  done
  printf 'none\n'
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Action Layer
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Design Review Release Processor が merged 設計 PR を検出しラベルを外した直後に呼ぶ。
# 親プロセス（dispatch 前・slot fork 前）で `origin/$BASE_BRANCH` を 1 回だけ最新化し、
# 同サイクルで claim される slot worktree が merge 済み spec を検出できるようにする。
# Issue #167 の per-slot fetch 競合は「複数 slot の同時 fetch」が原因で、本呼び出しは fork 前の
# 単一プロセスから 1 ref のみを fetch するため競合しない。fetch 失敗は WARN のみ（fail-open）。
#   Args: $1 = issue number / $2 = merged PR number / Returns: 常に 0
dnr_refresh_base_ref() {
  local issue_number="${1:-?}" merged_pr="${2:-?}"
  dnr_is_enabled || return 0
  if [ -z "${REPO_DIR:-}" ] || [ -z "${BASE_BRANCH:-}" ]; then
    dnr_warn "issue=#${issue_number} base ref refresh skip（REPO_DIR / BASE_BRANCH 未解決）"
    return 0
  fi
  if timeout "${DRR_GH_TIMEOUT:-60}" git -C "$REPO_DIR" fetch origin "$BASE_BRANCH" >/dev/null 2>&1; then
    dnr_log "issue=#${issue_number} merged-design-pr=#${merged_pr} → origin/${BASE_BRANCH} を再 fetch（merge 直後 race 緩和 / #180）"
  else
    dnr_warn "issue=#${issue_number} origin/${BASE_BRANCH} の再 fetch に失敗（次サイクルの通常 fetch に委ねる / fail-open）"
  fi
  return 0
}

# design モードの codex 実行が rc=0 で終わった直後に呼ぶ。ラベル状態を検証し、
# `codex-awaiting-design-review` へ遷移していない残留 claim を是正する。
#   Args: $1 = issue number
#   Returns: 0 = 正常（no-op / 補正済み）/ 1 = design-no-pr として codex-failed へ遷移させた
#   副作用: gh issue edit / gh issue comment / _slot_mark_failed（分岐に応じて）
dnr_reconcile_after_design() {
  local issue_number="$1"
  dnr_is_enabled || return 0

  local names
  if ! names=$(dnr_issue_label_names "$issue_number"); then
    dnr_warn "issue=#${issue_number} ラベル取得に失敗（reconcile skip / fail-open）"
    return 0
  fi

  if dnr_has_label "$names" "$LABEL_AWAITING_DESIGN"; then
    dnr_log "issue=#${issue_number} state=awaiting-design-review action=none（正常遷移済み）"
    return 0
  fi
  if ! dnr_has_label "$names" "$LABEL_CLAIMED" && ! dnr_has_label "$names" "$LABEL_PICKED"; then
    dnr_log "issue=#${issue_number} state=no-claim-labels action=none（claim 系ラベル残留なし）"
    return 0
  fi

  local found kind pr_number
  found=$(dnr_find_design_pr_with_retry "$issue_number")
  kind="${found%% *}"
  pr_number="${found#* }"

  case "$kind" in
    merged)
      if ! timeout "${DRR_GH_TIMEOUT:-60}" gh issue edit "$issue_number" --repo "$REPO" \
          --remove-label "$LABEL_CLAIMED" --remove-label "$LABEL_PICKED" >/dev/null 2>&1; then
        dnr_warn "issue=#${issue_number} merged-design-pr=#${pr_number} claim 系ラベル除去 API 失敗（次サイクル reaper / 手動復旧に委ねる）"
        return 0
      fi
      dnr_log "issue=#${issue_number} state=design-noop merged-design-pr=#${pr_number} action=claim labels removed → next tick impl-resume"
      local body_merged
      read -r -d '' body_merged <<EOF || true
## 自動: design no-op を検出（設計 PR は merge 済み）

設計 PR #${pr_number} は既に merge 済みのため、本サイクルの design worker は新規 PR を作成せず終了しました
（merge 直後の watcher tick が古い \`origin/${BASE_BRANCH}\` を参照した race）。
残留していた \`codex-claimed\` / \`codex-picked-up\` を watcher が除去しました。

次回 cron tick で Developer が **impl-resume モード**で自動起動します。

<!-- idd-codex:design-reconcile issue=${issue_number} kind=merged pr=${pr_number} -->
EOF
      timeout "${DRR_GH_TIMEOUT:-60}" gh issue comment "$issue_number" --repo "$REPO" --body "$body_merged" >/dev/null 2>&1 \
        || dnr_warn "issue=#${issue_number} コメント投稿 API 失敗（ラベルは補正済み）"
      return 0
      ;;
    open)
      if ! timeout "${DRR_GH_TIMEOUT:-60}" gh issue edit "$issue_number" --repo "$REPO" \
          --remove-label "$LABEL_CLAIMED" --remove-label "$LABEL_PICKED" \
          --add-label "$LABEL_AWAITING_DESIGN" >/dev/null 2>&1; then
        dnr_warn "issue=#${issue_number} open-design-pr=#${pr_number} awaiting-design-review への補完遷移 API 失敗"
        return 0
      fi
      dnr_log "issue=#${issue_number} state=label-handover-missing open-design-pr=#${pr_number} action=codex-awaiting-design-review を補完付与"
      local body_open
      read -r -d '' body_open <<EOF || true
## 自動: 設計 PR 作成後のラベル遷移を補完

設計 PR #${pr_number} は open ですが \`codex-claimed → codex-awaiting-design-review\` の付け替えが行われていなかったため、
watcher が補完しました。設計 PR を merge すると Design Review Release Processor が impl-resume へ進めます。

<!-- idd-codex:design-reconcile issue=${issue_number} kind=open pr=${pr_number} -->
EOF
      timeout "${DRR_GH_TIMEOUT:-60}" gh issue comment "$issue_number" --repo "$REPO" --body "$body_open" >/dev/null 2>&1 \
        || dnr_warn "issue=#${issue_number} コメント投稿 API 失敗（ラベルは補正済み）"
      return 0
      ;;
    error)
      dnr_warn "issue=#${issue_number} 設計 PR 検出 API が連続失敗（reconcile skip / 次サイクル reaper に委ねる）"
      return 0
      ;;
    *)
      dnr_warn "issue=#${issue_number} state=design-no-pr action=codex-failed（rc=0 だが設計 PR が open / merged いずれも見つからず awaiting-design-review 未遷移）"
      _slot_mark_failed "design-no-pr" "design モードの Codex 実行は正常終了（rc=0）しましたが、設計 PR（open / merged）が見つからず \`codex-awaiting-design-review\` へも遷移していません。design agent が PR を作成せずに終了した可能性があります。ログを確認し、必要なら \`codex-failed\` を外して再実行してください（Issue #180）。"
      return 1
      ;;
  esac
}
