#!/usr/bin/env bash
# auto-merge-disarm.sh — arm 済み auto-merge を terminal ラベル遷移時に取り消す processor (#145)
#
# 用途:
#   `auto-merge`（#99）/ `auto-merge-design`（#100）processor が `gh pr merge --auto` で
#   arm した PR（`autoMergeRequest != null`）が、その後 `codex-failed` /
#   `codex-needs-decisions` といった terminal ラベルへ遷移しても disarm されず、必須
#   status checks が全 green に到達した瞬間に「失敗確定済み PR」が誤って merge されて
#   しまう不具合（idd-claude #434 Defect A の移植 / #145）を解消する。
#   本 processor は毎サイクル GitHub を直接クエリして「arm 済み かつ terminal ラベル付き
#   かつ open」な PR を列挙し、`gh pr merge --disable-auto` で native auto-merge を
#   取り消す。実 merge を行わず、arm の取り消し（autoMergeRequest を null へ戻す）のみを行う。
#
#   関数 prefix は本 module 専用の `amx_`（auto-merge disarm / 既存 am_ / amd_ と非衝突）。
#
#   - amx_resolve_gate_enabled  : opt-in gate 判定（AUTO_MERGE_ENABLED OR
#                                 AUTO_MERGE_DESIGN_ENABLED の相乗り。詳細は関数コメント）
#   - amx_should_disarm_for_pr  : 1 PR が disarm 対象か判定（純粋関数）
#   - amx_disarm_pr             : 1 PR に対し `gh pr merge --disable-auto` を実行
#   - process_auto_merge_disarm : サイクルあたりの entry point
#
# 配置先:
#   $HOME/bin/idd-codex-modules/auto-merge-disarm.sh
#   （install.sh が local-watcher/bin/idd-codex-modules/ から配置する）
#
# 依存:
#   - 本モジュールは idd-codex-issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$AUTO_MERGE_ENABLED / $AUTO_MERGE_DESIGN_ENABLED /
#     $AUTO_MERGE_DISARM_MAX_PRS / $AUTO_MERGE_GIT_TIMEOUT / $AUTO_MERGE_HEAD_PATTERN /
#     $AUTO_MERGE_DESIGN_HEAD_PATTERN / $LABEL_FAILED / $LABEL_NEEDS_DECISIONS / $REPO）は
#     本体冒頭の Config ブロックで定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - ロガー（amx_log / amx_warn / amx_error）は core_utils.sh（am_ / amd_ と同居）。
#   - `full_auto_enabled` 関数（#97）は本体に定義済み（AND 二重 opt-in の片側）。
#   - 外部 CLI: gh / jq。
#
# 後方互換性（AGENTS.md 機能追加ガイドライン 3 / 4）:
#   - opt-in gate（FULL_AUTO_ENABLED AND (AUTO_MERGE_ENABLED OR AUTO_MERGE_DESIGN_ENABLED)）が
#     成立しない場合、`process_auto_merge_disarm` は gh API ゼロ呼び出しで早期 return し、
#     本不具合修正導入前と完全に同一の挙動（no-op）を保つ。
#   - gate を arm 側（auto-merge / auto-merge-design）に相乗りさせることで、arm が起きない
#     環境では disarm も no-op になり、新規 env gate を増やさずに後方互換を満たす
#     （idd-claude #434 と同じ gate セマンティクス）。
#
# セットアップ参照先:
#   README.md（「Auto-Merge Disarm (#145)」節） / install.sh（配置ロジック）

# ─────────────────────────────────────────────────────────────────────────────
# amx_resolve_gate_enabled: 本 processor の opt-in gate を判定する。
#
#   gate = FULL_AUTO_ENABLED AND (AUTO_MERGE_ENABLED OR AUTO_MERGE_DESIGN_ENABLED)
#
#   設計判断（gate の OR 相乗り / idd-claude #434 と同一）:
#     arm は #99 Auto-Merge（impl PR / AUTO_MERGE_ENABLED）と #100 Design Auto-Merge
#     （design PR / AUTO_MERGE_DESIGN_ENABLED）の双方で起きうる。どちらの arm 源で arm
#     された PR も disarm 対象に含めるため、gate は両 arm 源の OR を取る。どちらの arm 源も
#     無効なら arm 自体が起きないため、disarm も完全 no-op で後方互換。
#     さらに #97 kill switch（FULL_AUTO_ENABLED）との AND を取り、kill switch OFF では一切
#     発火しない（arm 側と同じ二重 opt-in セマンティクス）。
#
#   値正規化: `AUTO_MERGE_ENABLED` / `AUTO_MERGE_DESIGN_ENABLED` は `=true` 厳密一致のみ ON。
#     未設定 / 空 / `false` / `0` / `True` / `TRUE` / `1` / `on` / `yes` / typo はすべて
#     OFF として扱う（安全側）。FULL_AUTO_ENABLED は full_auto_enabled に委譲。
#
#   戻り値: 0 = gate ON / 1 = OFF
#   副作用: なし（純粋関数）
# ─────────────────────────────────────────────────────────────────────────────
amx_resolve_gate_enabled() {
  # #97 kill switch（AND の片側）
  if ! full_auto_enabled; then
    return 1
  fi
  # arm 源の OR（どちらかの arm が有効なら disarm 対象になりうる）
  case "${AUTO_MERGE_ENABLED:-false}" in
    true) return 0 ;;
  esac
  case "${AUTO_MERGE_DESIGN_ENABLED:-false}" in
    true) return 0 ;;
  esac
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# amx_should_disarm_for_pr: 1 PR が disarm 対象か判定する（純粋関数）。
#
#   入力: $1 = pr_json（gh pr list が返す 1 要素 JSON）
#   戻り値:
#     0 : disarm 対象（arm 済み かつ terminal ラベル付き かつ open）
#     1 : 対象外（未 arm / terminal ラベル無し / open でない）
#   副作用: なし
#
#   判定条件（すべて満たすとき true）:
#     - state == OPEN（既に merge / close 済みは対象外）
#     - autoMergeRequest != null（arm 済み。未 arm は対象外 = 冪等 no-op の前提）
#     - codex-failed または codex-needs-decisions ラベルを持つ（terminal）
#       → terminal ラベルが無い arm 済み PR は disarm しない
# ─────────────────────────────────────────────────────────────────────────────
amx_should_disarm_for_pr() {
  local pr_json="$1"

  # open でない（merged / closed）PR は対象外
  local pr_state
  pr_state=$(printf '%s' "$pr_json" | jq -r '.state // ""')
  if [ "$pr_state" != "OPEN" ]; then
    return 1
  fi

  # 未 arm（autoMergeRequest == null）は対象外（no-op の前提条件）
  local auto_merge_req
  auto_merge_req=$(printf '%s' "$pr_json" | jq -r '.autoMergeRequest // empty')
  if [ -z "$auto_merge_req" ] || [ "$auto_merge_req" = "null" ]; then
    return 1
  fi

  # terminal ラベル（codex-failed / codex-needs-decisions）のいずれかを持つ
  if printf '%s' "$pr_json" | jq -e --arg l "$LABEL_FAILED" \
      '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1; then
    return 0
  fi
  if printf '%s' "$pr_json" | jq -e --arg l "$LABEL_NEEDS_DECISIONS" \
      '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1; then
    return 0
  fi

  # arm 済みだが terminal ラベル無し → disarm しない
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# amx_disarm_pr: 1 PR に対し `gh pr merge --disable-auto` を実行して native auto-merge を
#   取り消す（失敗時 fail-continue）。
#
#   入力: $1 = pr_number（数値検証する）
#         $2 = head_ref（観測ログ用 / 任意）
#         $3 = pr_url（観測ログ用 / 任意）
#   戻り値:
#     0 : disarm 呼び出し成功（log に disarmed 行を出力）
#     1 : disarm 呼び出し失敗 or PR 番号不正（WARN 1 行を残してパイプライン継続）
#   副作用: gh pr merge --disable-auto API 呼び出し
#
#   冪等性: 既に未 arm の PR は amx_should_disarm_for_pr が false で除外され本関数は呼ばれ
#     ない。万一 disable-auto を二重に打っても GitHub 側で no-op 相当（副作用最小）。
# ─────────────────────────────────────────────────────────────────────────────
amx_disarm_pr() {
  local pr_number="$1"
  local head_ref="${2:-}"
  local pr_url="${3:-}"

  # PR 番号は数値のみ（gh 引数として使う直前に検証 / 未信頼入力規約）
  if ! printf '%s' "$pr_number" | grep -qE '^[0-9]+$'; then
    amx_warn "PR number '${pr_number}' は数値ではないため disarm を skip"
    return 1
  fi

  # `gh pr merge --disable-auto -- <PR>` で arm を取り消す
  # `--` でオプション解釈打ち切り（PR 番号は数値検証済みだが安全側で統一）
  local stderr_file rc=0
  stderr_file=$(idd_secure_mktemp "auto-merge-disarm-${pr_number}" 2>/dev/null || true)
  if [ -n "$stderr_file" ]; then
    timeout "$AUTO_MERGE_GIT_TIMEOUT" \
      gh pr merge --repo "$REPO" --disable-auto -- "$pr_number" \
      >/dev/null 2>"$stderr_file" || rc=$?
  else
    timeout "$AUTO_MERGE_GIT_TIMEOUT" \
      gh pr merge --repo "$REPO" --disable-auto -- "$pr_number" \
      >/dev/null 2>&1 || rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    # 成功時の log line（PR 番号 / 動作 disarmed / head branch）
    amx_log "PR #${pr_number}: auto-merge disarmed (terminal label present) head=${head_ref} url=${pr_url}"
    [ -n "$stderr_file" ] && rm -f "$stderr_file" 2>/dev/null
    return 0
  fi

  # disarm 失敗は WARN 1 行を残して fail-continue（silent fail させない）。
  local stderr_tail=""
  if [ -n "$stderr_file" ] && [ -f "$stderr_file" ]; then
    stderr_tail="$(tail -c 500 "$stderr_file" 2>/dev/null | tr '\n' ' ')"
    rm -f "$stderr_file" 2>/dev/null
  fi
  amx_warn "PR #${pr_number}: auto-merge disarm failed (rc=${rc}) head=${head_ref} url=${pr_url} stderr=${stderr_tail}"
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# process_auto_merge_disarm: dispatcher エントリ（毎サイクル呼ばれる）。
#   1. gate を判定（FULL_AUTO AND (AUTO_MERGE OR AUTO_MERGE_DESIGN)）。OFF なら早期 return
#      （gh API ゼロ呼び出し）
#   2. open PR を gh pr list で取得（GitHub 直接クエリ。arm 側 state に依存しない）。
#      head pattern は impl / design 双方を含めてクライアント側 jq でフィルタ
#      （人間が手書きした PR を除外）+ fork 除外
#   3. 各 PR について amx_should_disarm_for_pr → amx_disarm_pr。
#      1 件失敗で全体を止めない（fail-continue）
#   4. サマリ 1 行を出力。gate OFF 時の追加ログは arm 側 suppression ログに委ねる
#
#   戻り値: 0 固定（後続 processor を阻害しない / dispatcher fail-continue 契約）
# ─────────────────────────────────────────────────────────────────────────────
process_auto_merge_disarm() {
  # gate OFF（kill switch / 両 arm 源 OFF）→ 早期 return（gh API ゼロ呼び出し）。
  # arm 側（process_auto_merge / process_auto_merge_design）が suppression ログを出すため、
  # 本 processor からは gate OFF 時の追加ログを出さない（過剰ログ抑止）。
  if ! amx_resolve_gate_enabled; then
    return 0
  fi

  # 走査件数上限（残りは次回サイクルに持ち越し）。数値以外 / 0 以下は既定 10 に丸める。
  local max_prs="${AUTO_MERGE_DISARM_MAX_PRS:-10}"
  if ! [[ "$max_prs" =~ ^[0-9]+$ ]] || [ "$max_prs" -le 0 ]; then
    max_prs=10
  fi

  # GitHub を直接クエリして open PR を取得。terminal ラベル / arm 有無は client 側 jq で
  # 判定する（server-side の label フィルタでは「arm 済み かつ terminal」の AND が表現
  # しづらく、autoMergeRequest は server-side filter 不可のため）。
  local repo_owner="${REPO%%/*}"
  local prs_json
  if ! prs_json=$(timeout "$AUTO_MERGE_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --json number,headRefName,labels,autoMergeRequest,url,state,isDraft,headRepositoryOwner \
      --limit 100 2>/dev/null); then
    amx_warn "対象 PR 一覧の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    return 0
  fi

  # head pattern によるクライアント側フィルタ（人間が手書きした PR を除外）+ fork 除外。
  # impl / design 双方の arm 源を disarm 対象に含めるため、両 head pattern の OR でフィルタ。
  # 未信頼値（pattern / owner）は jq --arg で渡す（sed / eval 非使用）。
  prs_json=$(printf '%s' "$prs_json" | jq -c \
    --arg impl_pattern "$AUTO_MERGE_HEAD_PATTERN" \
    --arg design_pattern "$AUTO_MERGE_DESIGN_HEAD_PATTERN" \
    --arg owner "$repo_owner" \
    '[.[]
      | select(((.headRefName // "") | test($impl_pattern)) or ((.headRefName // "") | test($design_pattern)))
      | select((.headRepositoryOwner.login // "") == $owner)
    ]' 2>/dev/null || echo '[]')

  local total
  total=$(printf '%s' "$prs_json" | jq 'length' 2>/dev/null || echo 0)

  local target_iter
  target_iter=$(printf '%s' "$prs_json" | jq -c '.[]' 2>/dev/null || echo "")

  local disarmed_count=0
  local failed_count=0
  local checked=0

  if [ -n "$target_iter" ]; then
    local pr_json pr_number head_ref pr_url
    while IFS= read -r pr_json; do
      [ -n "$pr_json" ] || continue
      if [ "$checked" -ge "$max_prs" ]; then
        amx_log "上限 ${max_prs} に到達したため残りを次サイクルへ持ち越し"
        break
      fi

      # disarm 対象でなければ skip（gh 呼び出しなし）
      if ! amx_should_disarm_for_pr "$pr_json"; then
        continue
      fi
      checked=$((checked + 1))

      pr_number=$(printf '%s' "$pr_json" | jq -r '.number')
      head_ref=$(printf '%s' "$pr_json" | jq -r '.headRefName')
      pr_url=$(printf '%s' "$pr_json" | jq -r '.url')

      # 1 件失敗で残りを中断しない（fail-continue）
      if amx_disarm_pr "$pr_number" "$head_ref" "$pr_url"; then
        disarmed_count=$((disarmed_count + 1))
      else
        failed_count=$((failed_count + 1))
      fi
    done <<< "$target_iter"
  fi

  # 対象 0 件のときも観測可能性のためサマリ 1 行のみ出力（過剰ログ抑止）。
  amx_log "サマリ: disarmed=${disarmed_count}, failed=${failed_count} (open候補=${total})"
  return 0
}
