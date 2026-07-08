#!/usr/bin/env bash
# failed-recovery.sh — watcher の codex-failed / CI 失敗 自動解析・復旧プロセッサ (#101 / D-19)
#
# 用途:
#   `codex-failed` Issue（**reviewer-reject 由来も含む** / D-19a）と、auto-merge 待ちで CI が
#   失敗している PR を拾い、失敗ログ（Issue コメント / CI ログ）を解析して fresh context の
#   codex で修正を再開する。対応内容は Issue / PR コメントに残す（D-07 追加要件）。
#
#   多重ループと quota 燃焼を防ぐ終端設計を必須とする（D-19）:
#     - **通算 attempt budget = 4 を唯一のカウンタ**（`FAILED_RECOVERY_MAX_ATTEMPTS`）。
#       work-unit（Issue / PR）単位で `$FAILED_RECOVERY_STATE_DIR` 配下に永続化する。
#       Reviewer 内部 2/2・pr-iteration 3R と**掛け算しない**（D-19b / 本モジュール単独カウンタ）。
#     - **no-progress ガード**: 直前と同じ失敗 signature かつ diff 無進捗なら即終端（D-19）。
#     - **確実な終端**: budget 超過 / no-progress 時は `codex-failed` 据え置きで停止し
#       run-summary に通知（無限ループ・沈黙死しない）。
#
#   **quota 統合（codex 固有 / #79）**: codex 実行は `qa_run_codex_stage` 経由で行い、quota
#   reached（rc=99）を検出した場合は **budget を消費せず待機**する。Issue は既存
#   `qa_handle_quota_exceeded`（codex-needs-quota-wait + process_quota_resume の resume rails）
#   に委譲し、PR は reset 時刻を永続化してコメントを残す。recovery が quota を燃やし切る
#   事故を防ぐ。StageA PM/Dev 分割(#82) の +1 exec/issue を踏まえ budget 既定は 4。
#
#   完全自動化 kill switch `FULL_AUTO_ENABLED`（#97）と `FAILED_RECOVERY_ENABLED` の
#   **AND 二重 opt-in** で動き、いずれか OFF（既定）では外部副作用ゼロで no-op
#   （`codex-failed` は人間対応のまま＝導入前と等価）。
#
#   ロガー（fr_log / fr_warn / fr_error）は core_utils.sh にあるため再定義しない。
#   関連: README オプション機能一覧 / Issue #101。
#
# 依存グローバル: REPO, REPO_SLUG, BASE_BRANCH, LOG, LABEL_FAILED, LABEL_TRIGGER,
#   LABEL_NEEDS_DECISIONS, LABEL_NEEDS_QUOTA_WAIT, LABEL_BLOCKED, LABEL_AWAITING_SLOT,
#   FAILED_RECOVERY_ENABLED, FAILED_RECOVERY_MAX_ATTEMPTS, FAILED_RECOVERY_MAX_PRS,
#   FAILED_RECOVERY_GIT_TIMEOUT, FAILED_RECOVERY_DEV_MODEL, FAILED_RECOVERY_STATE_DIR,
#   FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS(#137), FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK(#137),
#   full_auto_enabled()(#97), qa_run_codex_stage()/qa_handle_quota_exceeded()/
#   qa_persist_reset_time()(#79), codex_exec_prompt(), rs_set_result(), idd_secure_mktemp()
#
#   **#137 即時失敗の budget 除外**: codex が起動直後（elapsed < FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS,
#   既定 10 秒）に rc≠0 で即死する「即時失敗」（認証エラー等の決定論的失敗）は attempt budget を
#   消費せず巻き戻し、state JSON の `immediate_failure_streak` のみ加算する。streak が
#   FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK（既定 3）に達したら max-attempts と区別された
#   `immediate-failure-streak` 終端理由で停止する。`immediate_failure_streak` は state JSON の
#   新キーで、欠落時は 0 継承（#137 導入前の state ファイルと後方互換）。
#
#   **#140 terminate の cross-cycle べき等化**: terminate 時（max-attempts / no-progress /
#   immediate-failure-streak）に `last_status` を terminal 値で state JSON へ永続化し、以後の
#   サイクルでは fr_fetch_* が terminal 状態の work-unit を候補列挙から除外する。これにより
#   終端コメント・rs_set_result・sn_notify_intervention の cron tick ごとの再発火（コメント spam）
#   を防ぐ。state 破損・欠落時は fail-open（従来の再投稿に退行 / silent fail なし）。
#
# Issue / PR コメントに埋め込む hidden marker。signature 計算時に recovery 自身の
# コメントを除外し、no-progress ガードが自分のコメント増殖を「進捗」と誤認しないようにする。
FR_COMMENT_MARKER="idd-codex:failed-recovery"

# ─────────────────────────────────────────────────────────────────────────────
# fr_resolve_gate_enabled: FAILED_RECOVERY_ENABLED 個別 gate の判定（純粋関数）
#   戻り値: 0 = ON（=true 厳密一致）/ 1 = OFF（未設定 / 空 / False / 1 / on / typo）
#   副作用: なし
# ─────────────────────────────────────────────────────────────────────────────
fr_resolve_gate_enabled() {
  case "${FAILED_RECOVERY_ENABLED:-false}" in
    true) return 0 ;;
    *) return 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_should_recover: 通算 attempt budget 未到達かを判定する（純粋関数）
#   入力: $1 = total_attempts（整数）
#   戻り値: 0 = まだ試行可（total < MAX）/ 1 = budget 到達（終端すべき）
# ─────────────────────────────────────────────────────────────────────────────
fr_should_recover() {
  local total="$1"
  if ! [[ "$total" =~ ^[0-9]+$ ]]; then
    total=0
  fi
  [ "$total" -lt "$FAILED_RECOVERY_MAX_ATTEMPTS" ] || return 1
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_state_path: work-unit の state JSON 絶対パスを返す（純粋関数）
#   入力: $1=kind（issue|pr） $2=number
#   出力: stdout に "$FAILED_RECOVERY_STATE_DIR/<kind>-<number>.json"
#   Issue 番号と PR 番号は同一空間だが kind prefix で衝突を明示的に避ける。
# ─────────────────────────────────────────────────────────────────────────────
fr_state_path() {
  local kind="$1" number="$2"
  printf '%s/%s-%s.json\n' "$FAILED_RECOVERY_STATE_DIR" "$kind" "$number"
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_load_state: work-unit の state JSON を読み出す（fail-open）
#   入力: $1=kind $2=number
#   出力: stdout に state JSON。ファイル無し / jq parse 失敗時は "{}"（常に rc 0）。
# ─────────────────────────────────────────────────────────────────────────────
fr_load_state() {
  local kind="$1" number="$2"
  local path
  path="$(fr_state_path "$kind" "$number")"
  if [ ! -f "$path" ]; then
    printf '{}'
    return 0
  fi
  local parsed
  if parsed=$(jq -c '.' "$path" 2>/dev/null); then
    printf '%s' "$parsed"
  else
    # 破損ファイルは fail-open（budget=0 扱い → 最大 MAX 回まで再試行できる）。
    printf '{}'
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_save_state: work-unit の state JSON を atomic に書き出す
#   入力: $1=kind $2=number $3=total_attempts $4=last_status
#         $5=last_failure_signature $6=last_head_sha
#         $7=immediate_failure_streak（#137 / 省略時は既存 state から継承 = 後方互換）
#   戻り値: 0 = 永続化成功 / 1 = 失敗（WARN 済み・呼び出し側は継続）
#   history[] は直近 8 件に truncate する。
#   #137: last_status は "in-progress" | "succeeded" | "quota-wait" | "max-attempts" |
#         "no-progress" | "immediate-failure-streak" を取りうる。$7 を省略した既存呼出側は
#         prev_state の immediate_failure_streak を継承する（欠落時 0）。
# ─────────────────────────────────────────────────────────────────────────────
fr_save_state() {
  local kind="$1" number="$2" total="$3" status="$4" signature="${5:-}" head_sha="${6:-}"
  # #137: 7 番目の引数は immediate_failure_streak（省略時は既存 state から継承）。
  local immediate_streak="${7-}"

  if ! [[ "$total" =~ ^[0-9]+$ ]]; then
    total=0
  fi

  if ! mkdir -p "$FAILED_RECOVERY_STATE_DIR" 2>/dev/null; then
    fr_warn "${kind}=#${number}: state dir 作成に失敗 (${FAILED_RECOVERY_STATE_DIR})"
    return 1
  fi

  local path prev
  path="$(fr_state_path "$kind" "$number")"
  prev="$(fr_load_state "$kind" "$number")"

  # #137: immediate_failure_streak を省略時は既存 state から継承（NFR 後方互換）。
  # 既存 state が当該フィールドを持たない（#137 導入前に書かれた）なら 0 fallback。
  # 明示指定 / 継承後の値は数値検証し、非整数は 0 に正規化する。
  if [ -z "$immediate_streak" ]; then
    if ! immediate_streak=$(printf '%s' "$prev" | jq -r '.immediate_failure_streak // 0' 2>/dev/null); then
      immediate_streak=0
    fi
  fi
  if ! [[ "$immediate_streak" =~ ^[0-9]+$ ]]; then
    immediate_streak=0
  fi

  local new_json
  if ! new_json=$(printf '%s' "$prev" | jq -c \
      --arg kind "$kind" \
      --argjson number "$number" \
      --argjson total "$total" \
      --arg status "$status" \
      --arg sig "$signature" \
      --arg head "$head_sha" \
      --argjson streak "$immediate_streak" \
      '
      .kind = $kind
      | .number = $number
      | .total_attempts = $total
      | .last_status = $status
      | .last_failure_signature = $sig
      | .last_head_sha = $head
      | .immediate_failure_streak = $streak
      | .history = ((.history // []) + [{total: $total, status: $status, sig: $sig}] | .[-8:])
      ' 2>/dev/null); then
    fr_warn "${kind}=#${number}: state JSON 構築に失敗"
    return 1
  fi

  local tmp
  tmp="$(idd_secure_mktemp "fr-state-${kind}-${number}" 2>/dev/null || true)"
  if [ -z "$tmp" ]; then
    fr_warn "${kind}=#${number}: state 一時ファイル作成に失敗"
    return 1
  fi
  if ! printf '%s\n' "$new_json" > "$tmp" 2>/dev/null; then
    fr_warn "${kind}=#${number}: state 一時ファイル書き込みに失敗"
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$path" 2>/dev/null; then
    fr_warn "${kind}=#${number}: state ファイル mv に失敗"
    rm -f "$tmp"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_classify_immediate_failure: codex 実行結果から「即時失敗」を判定する（純粋関数 / #137）
#   入力: $1=codex_rc（int） $2=elapsed_seconds（int） $3=threshold_seconds（int）
#   戻り値: 0 = 即時失敗（attempt budget から除外すべき）/ 1 = 通常の試行（budget 加算）
#   判定ロジック（#137）:
#     - codex_rc == 0（success） → 1（通常扱い）
#     - elapsed >= threshold（一定時間継続して失敗） → 1（通常扱い）
#     - 上記いずれにも該当しない（rc≠0 かつ短時間で終了） → 0（即時失敗）
#   quota reached（rc=99）は本関数の呼び出し前に別経路で処理されるため引数に含めない。
#   非整数入力は安全側に正規化（elapsed→0 / threshold→10）する。
# ─────────────────────────────────────────────────────────────────────────────
fr_classify_immediate_failure() {
  local codex_rc="$1" elapsed_seconds="$2" threshold_seconds="$3"
  # 正常終了は即時失敗ではない。
  if [ "$codex_rc" = "0" ]; then
    return 1
  fi
  if ! [[ "$elapsed_seconds" =~ ^[0-9]+$ ]]; then
    elapsed_seconds=0
  fi
  if ! [[ "$threshold_seconds" =~ ^[0-9]+$ ]]; then
    threshold_seconds=10
  fi
  # 閾値以上の時間継続していたら実質作業に着手したとみなし通常の試行として扱う。
  if [ "$elapsed_seconds" -ge "$threshold_seconds" ]; then
    return 1
  fi
  # rc≠0 かつ短時間終了 = 即時失敗。
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_is_terminated: state JSON の last_status が terminal（cross-cycle 終端済み）かを
#   判定する純粋関数（#140）。
#   入力: $1=state_json（`{}` または schema 準拠 JSON。空可）
#   出力: stdout に terminal 理由（"max-attempts" / "no-progress" /
#         "immediate-failure-streak"）。未終端なら空文字。
#   戻り値: 0 = 終端済み / 1 = 未終端（state 不在 / 破損 / それ以外の status → fail-open）
#   state 不在・破損は呼出元 fr_load_state が `{}` に正規化するため、本関数は status を
#   読めなければ未終端（rc 1）として扱い、cross-cycle べき等ガードを fail-open にする。
# ─────────────────────────────────────────────────────────────────────────────
fr_is_terminated() {
  local state_json="${1-}"
  if [ -z "$state_json" ]; then
    return 1
  fi
  local status
  if ! status=$(printf '%s' "$state_json" | jq -r '.last_status // ""' 2>/dev/null); then
    return 1
  fi
  case "$status" in
    max-attempts|no-progress|immediate-failure-streak)
      printf '%s' "$status"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_filter_terminated_candidates: 候補列挙 JSON 配列から terminal 状態に永続化済みの
#   work-unit を client-side で除外する（#140）。
#   入力: $1=kind（issue|pr。ログ識別用） $2=candidates_json（JSON 配列文字列）
#   出力: stdout に terminal 除外済み JSON 配列
#   戻り値: 0 固定（fail-continue）
#   - 各要素の `.number` で fr_load_state → fr_is_terminated を確認し、terminal なら除外。
#   - state 不在 / 破損 → fr_is_terminated が rc 1（未終端）で fail-open（残す）。
#   - number 非数値は fail-open で残す（列挙側の sanitize に委ねる）。
#   - 抑止時は 1 行ログ（`<kind>=#<n> terminated reason=<status> suppressed=enumeration`）を
#     残し、運用者が grep でコメント spam の収束を確認できるようにする。
# ─────────────────────────────────────────────────────────────────────────────
fr_filter_terminated_candidates() {
  local kind="$1" candidates_json="${2-}"

  case "$kind" in
    issue|pr) : ;;
    *)
      fr_warn "fr_filter_terminated_candidates: 不正な kind=$(printf '%s' "$kind" | tr -cd '[:alnum:]_-' | head -c 16)"
      printf '%s' "[]"
      return 0
      ;;
  esac

  if [ -z "$candidates_json" ]; then
    printf '%s' "[]"
    return 0
  fi
  if ! printf '%s' "$candidates_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '%s' "[]"
    return 0
  fi

  local count
  count=$(printf '%s' "$candidates_json" | jq -r 'length' 2>/dev/null || echo "0")
  if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" = "0" ]; then
    printf '%s' "[]"
    return 0
  fi

  local result="[]" idx=0
  while [ "$idx" -lt "$count" ]; do
    local item number state_json terminal_reason
    item=$(printf '%s' "$candidates_json" | jq -c --argjson i "$idx" '.[$i]' 2>/dev/null || echo "")
    if [ -z "$item" ]; then
      idx=$((idx + 1))
      continue
    fi
    number=$(printf '%s' "$item" | jq -r '.number // ""' 2>/dev/null || echo "")
    if ! [[ "$number" =~ ^[0-9]+$ ]]; then
      # 数値検証失敗は fail-open で残す（候補列挙側で再度 sanitize される）。
      result=$(printf '%s' "$result" | jq -c --argjson it "$item" '. + [$it]' 2>/dev/null || printf '%s' "$result")
      idx=$((idx + 1))
      continue
    fi
    state_json=$(fr_load_state "$kind" "$number")
    terminal_reason=""
    if terminal_reason=$(fr_is_terminated "$state_json"); then
      # terminal 済み → 除外 + 抑止ログ。
      fr_log "${kind}=#${number} terminated reason=${terminal_reason} suppressed=enumeration"
    else
      result=$(printf '%s' "$result" | jq -c --argjson it "$item" '. + [$it]' 2>/dev/null || printf '%s' "$result")
    fi
    idx=$((idx + 1))
  done

  printf '%s' "$result"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_compute_failure_signature: 失敗ログ（stdin）から正規化 SHA-1 を計算する
#   出力: stdout に 40 桁 hex。timestamp / SHA / path:line / URL / Run # 等の volatile
#         要素を sed で除去してから hash し、同一原因の失敗を安定して同定する。
# ─────────────────────────────────────────────────────────────────────────────
fr_compute_failure_signature() {
  sed -E '
    s|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z?||g
    s|[0-9a-f]{40}|<sha>|g
    s|/[A-Za-z0-9._/-]+:[0-9]+|<path:line>|g
    s|https?://[^[:space:]]+|<url>|g
    s|[Rr]un #?[0-9]+|<run>|g
    s|[0-9]+|<n>|g
  ' | sha1sum | cut -d' ' -f1
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_detect_no_progress: 直前 attempt と比べて無進捗かを判定する（純粋関数）
#   入力: $1=current_signature $2=current_head_sha $3=prev_state_json
#   戻り値: 0 = no-progress（即終端すべき）/ 1 = progress（試行継続可）
#   - prev signature 無し（初回 / 破損）→ progress
#   - signature 異 → progress
#   - PR 経路（head_sha 非空）: head が進んでいたら progress / 同一なら no-progress
#   - Issue 経路（head_sha 空）: signature 一致のみで no-progress
# ─────────────────────────────────────────────────────────────────────────────
fr_detect_no_progress() {
  local current_signature="$1" current_head_sha="$2" prev_state_json="${3:-}"
  if [ -z "$prev_state_json" ]; then
    prev_state_json="{}"
  fi

  local prev_signature prev_head_sha
  if ! prev_signature=$(printf '%s' "$prev_state_json" | jq -r '.last_failure_signature // ""' 2>/dev/null); then
    prev_signature=""
  fi
  if ! prev_head_sha=$(printf '%s' "$prev_state_json" | jq -r '.last_head_sha // ""' 2>/dev/null); then
    prev_head_sha=""
  fi

  # prev signature 無し（初回 / 破損 fallback）→ progress
  if [ -z "$prev_signature" ]; then
    return 1
  fi
  # signature 異 → progress
  if [ "$prev_signature" != "$current_signature" ]; then
    return 1
  fi
  # PR 経路: head が進んでいたら progress
  if [ -n "$current_head_sha" ]; then
    if [ "$prev_head_sha" != "$current_head_sha" ]; then
      return 1
    fi
    return 0
  fi
  # Issue 経路: signature 一致のみで no-progress
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_fetch_failed_issues: 復旧対象の `codex-failed` Issue 一覧を取得する
#   出力: stdout に JSON 配列（number のみ）。取得失敗時は "[]"（常に rc 0）。
#   codex-auto-dev かつ codex-failed で、人間ゲート系ラベル（needs-decisions /
#   needs-quota-wait / blocked / awaiting-slot）が付いていない open Issue に限定する。
#   reviewer-reject 由来も label 同定で区別なく含まれる（D-19a）。
# ─────────────────────────────────────────────────────────────────────────────
fr_fetch_failed_issues() {
  local issues_json
  if ! issues_json=$(timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh issue list \
      --repo "$REPO" --state open \
      --search "label:\"$LABEL_FAILED\" label:\"$LABEL_TRIGGER\" -label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_NEEDS_QUOTA_WAIT\" -label:\"$LABEL_BLOCKED\" -label:\"$LABEL_AWAITING_SLOT\"" \
      --json number \
      --limit 50 2>/dev/null); then
    fr_warn "codex-failed Issue 一覧の取得に失敗しました（後続処理は継続）"
    printf '[]'
    return 0
  fi
  if [ -z "$issues_json" ]; then
    printf '[]'
    return 0
  fi
  # #140: terminal 状態（max-attempts / no-progress / immediate-failure-streak）に
  # 永続化済みの Issue を除外し、終端コメントの cron tick ごとの再投稿を防ぐ。
  # state 不在 / 破損は fr_is_terminated が未終端扱い（rc 1）で fail-open する。
  printf '%s' "$(fr_filter_terminated_candidates "issue" "$issues_json")"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_fetch_failed_prs: auto-merge 待ちで CI が失敗している PR 一覧を取得する
#   出力: stdout に JSON 配列（number,headRefName,headRefOid を含む）。失敗時は "[]"。
#   2 段: gh pr list（head pattern / non-draft / fork 除外）→ 各 PR を gh pr view し
#   autoMergeRequest!=null かつ statusCheckRollup に FAILURE/TIMED_OUT を含むものに絞る。
# ─────────────────────────────────────────────────────────────────────────────
fr_fetch_failed_prs() {
  local repo_owner="${REPO%%/*}"
  local prs_json
  if ! prs_json=$(timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" --state open \
      --json number,headRefName,headRefOid,isDraft,headRepositoryOwner \
      --limit 50 2>/dev/null); then
    fr_warn "open PR 一覧の取得に失敗しました（後続処理は継続）"
    printf '[]'
    return 0
  fi

  # client-side: draft 除外 + head `^codex/` + fork 除外
  local candidates
  candidates=$(printf '%s' "$prs_json" | jq -c --arg owner "$repo_owner" \
    '[ .[] | select((.isDraft // false) == false)
            | select((.headRefName // "") | test("^codex/"))
            | select((.headRepositoryOwner.login // "") == $owner) ]' 2>/dev/null || echo "[]")

  local result="[]"
  local pr_iter
  pr_iter=$(printf '%s' "$candidates" | jq -c '.[]' 2>/dev/null || echo "")
  while IFS= read -r pr_json; do
    [ -z "$pr_json" ] && continue
    local number
    number=$(printf '%s' "$pr_json" | jq -r '.number' 2>/dev/null || echo "")
    [[ "$number" =~ ^[0-9]+$ ]] || continue

    local view_json
    if ! view_json=$(timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh pr view "$number" \
        --repo "$REPO" \
        --json number,headRefName,headRefOid,autoMergeRequest,statusCheckRollup 2>/dev/null); then
      continue
    fi
    local keep
    keep=$(printf '%s' "$view_json" | jq -r '
      (.autoMergeRequest != null) as $auto
      | ((.statusCheckRollup // []) | map(select(
            (.state // "") == "FAILURE"
            or (.conclusion // "") == "FAILURE"
            or (.conclusion // "") == "TIMED_OUT"
        )) | length > 0) as $err
      | if ($auto and $err) then "yes" else "no" end
    ' 2>/dev/null || echo "no")
    if [ "$keep" = "yes" ]; then
      result=$(printf '%s' "$result" | jq -c --argjson v "$view_json" \
        '. + [{number: $v.number, headRefName: $v.headRefName, headRefOid: $v.headRefOid}]' 2>/dev/null || printf '%s' "$result")
    fi
  done <<< "$pr_iter"

  # #140: terminal 状態に永続化済みの PR を除外する（fail-open は
  # fr_filter_terminated_candidates 内で担保）。
  printf '%s' "$(fr_filter_terminated_candidates "pr" "$result")"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_collect_issue_context: codex-failed Issue の失敗コンテキストを収集する
#   入力: $1=issue_number
#   出力: stdout に title + labels + body + 直近コメント（recovery 自身のコメントは除外）。
#   recovery marker 付きコメントを除外することで、prompt と signature が recovery の
#   コメント増殖に汚染されない（no-progress ガードの安定性）。
#   gh 失敗時は空文字 + WARN（fail-continue）。
# ─────────────────────────────────────────────────────────────────────────────
fr_collect_issue_context() {
  local issue_number="$1"
  if ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
    fr_warn "fr_collect_issue_context: 不正な issue_number='${issue_number}'"
    return 0
  fi
  local view_json
  if ! view_json=$(timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh issue view "$issue_number" \
      --repo "$REPO" --json title,labels,body,comments 2>/dev/null); then
    fr_warn "Issue #${issue_number}: コンテキスト取得に失敗"
    return 0
  fi
  printf '%s' "$view_json" | jq -r --arg marker "$FR_COMMENT_MARKER" '
    "## Title\n" + (.title // "")
    + "\n\n## Labels\n" + ((.labels // []) | map(.name) | join(", "))
    + "\n\n## Body\n" + (.body // "")
    + "\n\n## Recent comments\n"
    + ((.comments // [])
        | map(select((.body // "") | contains($marker) | not))
        | .[-5:]
        | map(.body // "")
        | join("\n---\n"))
  ' 2>/dev/null || true
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_collect_pr_ci_context: auto-merge 待ち PR の CI 失敗コンテキストを収集する
#   入力: $1=pr_number
#   出力: stdout に失敗 check サマリ + 各 check の `gh run view --log-failed` tail。
#   gh 失敗時は空文字 + WARN（fail-continue）。
# ─────────────────────────────────────────────────────────────────────────────
fr_collect_pr_ci_context() {
  local pr_number="$1"
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    fr_warn "fr_collect_pr_ci_context: 不正な pr_number='${pr_number}'"
    return 0
  fi
  local checks_json
  if ! checks_json=$(timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh pr checks "$pr_number" \
      --repo "$REPO" --json name,state,bucket,link 2>/dev/null); then
    fr_warn "PR #${pr_number}: CI check 一覧取得に失敗"
    return 0
  fi

  printf '## Failing checks\n'
  printf '%s' "$checks_json" | jq -r '
    (. // []) | map(select((.state // "") == "FAILURE" or (.bucket // "") == "fail"))
    | map("- " + (.name // "?") + " (" + (.state // .bucket // "?") + ")") | join("\n")
  ' 2>/dev/null || true

  # 失敗 check ごとに run log の末尾を取り込む（run id を link から抽出）。
  local failing_links
  failing_links=$(printf '%s' "$checks_json" | jq -r '
    (. // [])[] | select((.state // "") == "FAILURE" or (.bucket // "") == "fail")
    | (.link // "")' 2>/dev/null || echo "")
  local link run_id
  while IFS= read -r link; do
    [ -z "$link" ] && continue
    run_id=""
    if [[ "$link" =~ actions/runs/([0-9]+) ]]; then
      run_id="${BASH_REMATCH[1]}"
    fi
    [[ "$run_id" =~ ^[0-9]+$ ]] || continue
    local log_tail
    if log_tail=$(timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh run view "$run_id" \
        --repo "$REPO" --log-failed 2>/dev/null | tail -n 200); then
      printf '\n\n### Failed log (run #%s)\n%s' "$run_id" "$log_tail"
    fi
  done <<< "$failing_links"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_build_recovery_prompt: codex に渡す復旧プロンプトを組み立てる
#   入力: $1=kind（issue|pr） $2=number $3=context $4=head_ref（PR のみ）
#   出力: stdout に prompt 文字列。
# ─────────────────────────────────────────────────────────────────────────────
fr_build_recovery_prompt() {
  local kind="$1" number="$2" context="$3" head_ref="${4:-}"
  if [ "$kind" = "pr" ]; then
    cat <<EOF
あなたは idd-codex の自動復旧 (Failed Recovery) Developer です。auto-merge 待ちの PR #${number}
は CI が失敗しています。head branch \`${head_ref}\` は既に checkout 済みです。

## CI 失敗コンテキスト
${context}

## 手順
1. 失敗した check（build / test / lint）のログから根本原因を特定する。
2. 最小差分で修正する（過剰な scope 拡大をしない）。CLAUDE.md / AGENTS.md のコード・テスト規約に従う。
3. 同一 branch \`${head_ref}\` に \`git commit\` して \`git push\` する。
4. requirements.md / design.md / tasks.md は書き換えない（矛盾は PR 本文「確認事項」に記す）。

## 制約
- ${BASE_BRANCH} への直接 push 禁止。1 回の実行で 1 つの根本原因に集中する。
EOF
  else
    cat <<EOF
あなたは idd-codex の自動復旧 (Failed Recovery) Developer です。以下の \`codex-failed\` Issue #${number}
は自動開発パイプラインで失敗しました（Reviewer reject = AC 未カバー / missing test / boundary 逸脱、
もしくは Stage 失敗 / CI error 等）。失敗原因を解析し、最小差分で修正してください。

## 失敗コンテキスト
${context}

## 手順
1. Issue に紐づく作業ブランチ（\`codex/issue-${number}-impl-<slug>\` 等）を \`git fetch\` して checkout する。
   存在しなければ \`origin/${BASE_BRANCH}\` 起点で作成する。
2. 失敗の根本原因を特定し修正する。reviewer reject の場合は指摘された AC / test / boundary を満たす。
3. CLAUDE.md / AGENTS.md のコード・テスト規約に従いテストを追加・更新する。
4. \`git commit\` して \`git push\` する。requirements.md / design.md / tasks.md は書き換えない。

## 制約
- ${BASE_BRANCH} への直接 push 禁止。1 回の実行で 1 つの根本原因に集中する。
EOF
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_invoke_codex: 復旧 prompt で codex を実行する（quota 検出統合 / #79）
#   入力: $1=stage_label $2=prompt $3=reset_file $4=head_ref（PR のみ。空なら checkout せず）
#   戻り値: 0 = 正常終了 / 99 = quota reached（reset_file に reset epoch）/
#           70 = git setup 失敗 / その他 = codex 失敗
#   PR 経路では head branch を fetch+checkout してから実行し、終了時に BASE_BRANCH へ戻す。
#   codex 実行は qa_run_codex_stage 経由のため quota reached が rc=99 で伝播する。
# ─────────────────────────────────────────────────────────────────────────────
fr_invoke_codex() {
  local stage_label="$1" prompt="$2" reset_file="$3" head_ref="${4:-}"
  : > "$reset_file"
  local rc=0
  (
    set +e
    # shellcheck disable=SC2064
    trap "timeout \"${FAILED_RECOVERY_GIT_TIMEOUT}\" git checkout \"${BASE_BRANCH}\" >/dev/null 2>&1" EXIT
    if [ -n "$head_ref" ]; then
      if ! timeout "$FAILED_RECOVERY_GIT_TIMEOUT" git fetch origin "$head_ref" >/dev/null 2>&1; then
        fr_warn "${stage_label}: git fetch origin ${head_ref} に失敗"
        exit 70
      fi
      if ! timeout "$FAILED_RECOVERY_GIT_TIMEOUT" git checkout -B "$head_ref" "origin/${head_ref}" >/dev/null 2>&1; then
        fr_warn "${stage_label}: head branch '${head_ref}' の checkout に失敗"
        exit 70
      fi
    fi
    local crc=0
    qa_run_codex_stage "$stage_label" "$reset_file" -- \
      codex_exec_prompt "$stage_label" "$FAILED_RECOVERY_DEV_MODEL" "$prompt" \
      >> "$LOG" 2>&1 || crc=$?
    exit "$crc"
  ) || rc=$?
  return "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_post_attempt_comment: Issue / PR に recovery のステータスコメントを 1 件投稿する
#   入力: $1=kind（issue|pr） $2=number $3=body
#   戻り値: 0 = 投稿成功 / 1 = 失敗（WARN 済み・fail-continue）
#   本文末尾に hidden marker を付与する（signature 除外 / 既処理判定用）。
# ─────────────────────────────────────────────────────────────────────────────
fr_post_attempt_comment() {
  local kind="$1" number="$2" body="$3"
  local full_body
  full_body="${body}

<!-- ${FR_COMMENT_MARKER} ${kind}=${number} -->"
  local sub="issue"
  [ "$kind" = "pr" ] && sub="pr"
  if ! timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh "$sub" comment "$number" \
      --repo "$REPO" --body "$full_body" >/dev/null 2>&1; then
    fr_warn "${kind}=#${number}: recovery コメント投稿に失敗（処理は継続）"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_finalize_success: 復旧成功時の後処理（codex-failed 除去 + state 更新）
#   入力: $1=kind $2=number $3=total_attempts $4=signature $5=head_sha
#   戻り値: 0 固定（fail-continue）
# ─────────────────────────────────────────────────────────────────────────────
fr_finalize_success() {
  local kind="$1" number="$2" total="$3" signature="${4:-}" head_sha="${5:-}"
  # Issue は codex-failed を除去して通常フローへ戻す。PR は CI 再実行で auto-merge が進む
  # ため label 操作不要（codex-failed は PR には付かない）。
  if [ "$kind" = "issue" ]; then
    if ! timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh issue edit "$number" \
        --repo "$REPO" --remove-label "$LABEL_FAILED" >/dev/null 2>&1; then
      fr_warn "Issue #${number}: codex-failed ラベル除去に失敗（次サイクルで再評価）"
    fi
  fi
  # #137: 成功時は immediate_failure_streak を 0 にリセットする。
  fr_save_state "$kind" "$number" "$total" "succeeded" "$signature" "$head_sha" "0" || true
  local body
  body="$(printf 'Failed Recovery Processor (#101): 復旧を実行しました（通算 %s 回 / 修正を push 済み）。CI 再実行の結果を待ちます。' "$total")"
  fr_post_attempt_comment "$kind" "$number" "$body" || true
  fr_log "${kind}=#${number} recovered total=${total}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_handle_quota: quota reached を budget 不消費で待機させる（#79 統合）
#   入力: $1=kind $2=number $3=stage_label $4=reset_file $5=prev_total
#         $6=prev_signature $7=prev_head_sha
#   戻り値: 99 固定（dispatcher では非終端 no-op 扱い）
#   - state を **prev_total（=増分前）** + 直前 attempt の signature/head_sha で再保存し、
#     budget も no-progress baseline も進めない（quota を消費しない）。
#   - Issue は qa_handle_quota_exceeded（codex-needs-quota-wait + resume rails）へ委譲。
#   - PR は process_quota_resume が PR を resume しないため、reset 時刻を永続化して
#     コメントを残すに留める（次サイクルで自然に再試行）。
# ─────────────────────────────────────────────────────────────────────────────
fr_handle_quota() {
  local kind="$1" number="$2" stage_label="$3" reset_file="$4" prev_total="$5" prev_signature="${6:-}" prev_head_sha="${7:-}"
  local epoch=""
  if [ -f "$reset_file" ]; then
    epoch="$(tr -d '[:space:]' < "$reset_file" 2>/dev/null || echo "")"
  fi

  # budget も baseline も巻き戻す（quota は消費しない / D-19 codex delta）。
  fr_save_state "$kind" "$number" "$prev_total" "quota-wait" "$prev_signature" "$prev_head_sha" || true

  if [ "$kind" = "issue" ] && [[ "$epoch" =~ ^[0-9]+$ ]]; then
    # Issue は既存 quota rails（codex-needs-quota-wait + process_quota_resume）へ委譲。
    qa_handle_quota_exceeded "$number" "$stage_label" "$epoch" || true
  else
    # PR / epoch 不明: reset 時刻を永続化（best-effort）し PR コメントを残す。
    if [[ "$epoch" =~ ^[0-9]+$ ]]; then
      qa_persist_reset_time "$number" "$epoch" || true
    fi
    fr_post_attempt_comment "$kind" "$number" \
      "Failed Recovery Processor (#101): quota 上限に到達したため復旧を待機します（budget は消費しません）。quota リセット後の次サイクルで自動再試行します。" || true
  fi
  fr_log "${kind}=#${number} quota-wait reset_epoch=${epoch:-unknown} budget-preserved total=${prev_total}"
  return 99
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_run_recovery_attempt: 1 work-unit に対する 1 復旧 attempt を駆動する
#   入力: $1=kind（issue|pr） $2=number $3=pr_json（PR のみ。Issue は空）
#   戻り値: 0 = 復旧実行（成功）/ 1 = codex 失敗（codex-failed 据え置き・次サイクル再試行）
#           / 2 = budget 到達（max-attempts 終端）/ 3 = no-progress 終端
#           / 4 = 即時失敗連続上限到達（immediate-failure-streak 終端 / #137）
#           / 99 = quota 待機（非終端・budget 不消費）
#   #137: codex が閾値（FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS）未満で rc≠0 即死した
#   「即時失敗」は attempt budget を消費せず state を巻き戻し、immediate_failure_streak
#   のみ加算する。streak 上限到達で rc=4 を返し max-attempts と区別された終端に流す。
# ─────────────────────────────────────────────────────────────────────────────
fr_run_recovery_attempt() {
  local kind="$1" number="$2" pr_json="${3:-}"

  local prev_state prev_total prev_sig prev_head
  prev_state="$(fr_load_state "$kind" "$number")"
  prev_total=$(printf '%s' "$prev_state" | jq -r '.total_attempts // 0' 2>/dev/null || echo 0)
  [[ "$prev_total" =~ ^[0-9]+$ ]] || prev_total=0
  prev_sig=$(printf '%s' "$prev_state" | jq -r '.last_failure_signature // ""' 2>/dev/null || echo "")
  prev_head=$(printf '%s' "$prev_state" | jq -r '.last_head_sha // ""' 2>/dev/null || echo "")

  # #137: 直前の immediate_failure_streak を読み出す（欠落時 0 継承 = 後方互換）。
  local prev_streak
  prev_streak=$(printf '%s' "$prev_state" | jq -r '.immediate_failure_streak // 0' 2>/dev/null || echo 0)
  [[ "$prev_streak" =~ ^[0-9]+$ ]] || prev_streak=0

  # #137: 連続即時失敗の上限事前チェック（attempt budget とは独立の終端経路）。
  # 既に上限到達していたら budget を消費せず即 terminate 経路（rc=4）へ。
  local streak_max="${FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK:-3}"
  if ! [[ "$streak_max" =~ ^[0-9]+$ ]] || [ "$streak_max" -le 0 ]; then
    streak_max=3
  fi
  if [ "$prev_streak" -ge "$streak_max" ]; then
    fr_log "${kind}=#${number} 即時失敗連続上限到達 streak=${prev_streak} max=${streak_max}"
    return 4
  fi

  # budget 到達は attempt 開始前に判定して終端（quota を燃やさない）。
  if ! fr_should_recover "$prev_total"; then
    return 2
  fi

  # コンテキスト収集 + head_sha 取得（PR のみ）
  local context head_ref="" head_sha=""
  if [ "$kind" = "pr" ]; then
    head_ref=$(printf '%s' "$pr_json" | jq -r '.headRefName // ""' 2>/dev/null || echo "")
    head_sha=$(printf '%s' "$pr_json" | jq -r '.headRefOid // ""' 2>/dev/null || echo "")
    context="$(fr_collect_pr_ci_context "$number")"
  else
    context="$(fr_collect_issue_context "$number")"
  fi

  local signature
  signature=$(printf '%s' "$context" | fr_compute_failure_signature)

  # no-progress ガード: 直前と同一 signature かつ diff 無進捗なら即終端。
  if fr_detect_no_progress "$signature" "$head_sha" "$prev_state"; then
    # 終端用に signature を保存（baseline は据え置き済みのため total/baseline は変えない）。
    fr_save_state "$kind" "$number" "$prev_total" "no-progress" "$prev_sig" "$prev_head" || true
    return 3
  fi

  # attempt 開始時に budget++ を確定（quota 燃焼の上界保証 + no-progress baseline を現在へ前進）。
  local new_total=$((prev_total + 1))
  fr_save_state "$kind" "$number" "$new_total" "in-progress" "$signature" "$head_sha" || true

  # 開始コメント（D-07: 対応内容を残す）
  fr_post_attempt_comment "$kind" "$number" \
    "$(printf 'Failed Recovery Processor (#101): 復旧 attempt %s/%s を開始します。失敗ログを解析し修正を試みます。' "$new_total" "$FAILED_RECOVERY_MAX_ATTEMPTS")" || true

  local prompt stage_label reset_file
  stage_label="FailedRecovery-${kind}-${number}"
  prompt="$(fr_build_recovery_prompt "$kind" "$number" "$context" "$head_ref")"
  reset_file="$(idd_secure_mktemp "fr-reset-${kind}-${number}" 2>/dev/null || true)"
  if [ -z "$reset_file" ]; then
    fr_warn "${kind}=#${number}: reset 一時ファイル作成に失敗（attempt 中止）"
    return 1
  fi

  # #137: 即時失敗判定用にセッション継続時間を計測する（epoch 秒 / date 失敗時は 0 扱い）。
  local invoke_start_epoch invoke_end_epoch elapsed_seconds
  invoke_start_epoch=$(date +%s 2>/dev/null || echo 0)
  local codex_rc=0
  fr_invoke_codex "$stage_label" "$prompt" "$reset_file" "$head_ref" || codex_rc=$?
  invoke_end_epoch=$(date +%s 2>/dev/null || echo "$invoke_start_epoch")
  elapsed_seconds=$((invoke_end_epoch - invoke_start_epoch))
  if [ "$elapsed_seconds" -lt 0 ]; then
    elapsed_seconds=0
  fi

  case "$codex_rc" in
    0)
      rm -f "$reset_file"
      fr_finalize_success "$kind" "$number" "$new_total" "$signature" "$head_sha"
      return 0
      ;;
    99)
      # quota: budget を消費せず待機（prev_total / 直前 baseline に巻き戻す）。
      fr_handle_quota "$kind" "$number" "$stage_label" "$reset_file" "$prev_total" "$prev_sig" "$prev_head"
      local q_rc=$?
      rm -f "$reset_file"
      return "$q_rc"
      ;;
    *)
      rm -f "$reset_file"
      # #137: 即時失敗判定。rc≠0（quota 以外）かつ elapsed < 閾値なら「codex が実質作業前に
      # 即死した」とみなし、attempt budget を消費せず state を巻き戻す（quota 経路と同型:
      # total / no-progress baseline を据え置き）。immediate_failure_streak のみ加算する。
      if fr_classify_immediate_failure "$codex_rc" "$elapsed_seconds" "${FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS:-10}"; then
        local new_streak=$((prev_streak + 1))
        fr_save_state "$kind" "$number" "$prev_total" "in-progress" "$prev_sig" "$prev_head" "$new_streak" || true
        fr_log "${kind}=#${number} immediate-failure rc=${codex_rc} elapsed=${elapsed_seconds}s threshold=${FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS:-10}s streak=${new_streak}/${streak_max} budget-preserved total=${prev_total}"
        if [ "$new_streak" -ge "$streak_max" ]; then
          # 連続上限到達: caller (_fr_dispatch_candidate) が terminate 経路（rc=4）に流す。
          return 4
        fi
        fr_post_attempt_comment "$kind" "$number" \
          "$(printf 'Failed Recovery Processor (#101): codex が起動直後に即時失敗しました（rc=%s / %s 秒 / 連続 %s 回目・上限 %s 回）。attempt budget は消費しません（通算 %s 回のまま）。`codex-failed` を据え置き、次サイクルで再試行します。' "$codex_rc" "$elapsed_seconds" "$new_streak" "$streak_max" "$prev_total")" || true
        return 1
      fi
      # codex 失敗（70=git setup 失敗 含む）: codex-failed 据え置き・次サイクルで再試行。
      # #137: 通常失敗（閾値以上継続した失敗）は immediate_failure_streak を 0 にリセットする。
      fr_save_state "$kind" "$number" "$new_total" "in-progress" "$signature" "$head_sha" "0" || true
      fr_post_attempt_comment "$kind" "$number" \
        "$(printf 'Failed Recovery Processor (#101): 復旧 attempt %s/%s は失敗しました（codex rc=%s）。`codex-failed` を据え置き、次サイクルで再試行します（budget 残 %s）。' "$new_total" "$FAILED_RECOVERY_MAX_ATTEMPTS" "$codex_rc" "$((FAILED_RECOVERY_MAX_ATTEMPTS - new_total))")" || true
      fr_log "${kind}=#${number} attempt failed total=${new_total} codex_rc=${codex_rc}"
      return 1
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_terminate_max_attempts: budget 超過時の確実な終端（codex-failed 据え置き）
#   入力: $1=kind $2=number $3=total_attempts
#   戻り値: 0 固定。run-summary 通知 1 回 + コメント 1 件。ラベルは据え置く（人間へ）。
#   #140: last_status="max-attempts" を state JSON へ永続化し、以後のサイクルでは
#   fr_fetch_* の terminal 除外 + 冒頭のべき等ガードで終端コメント・rs_set_result・
#   sn_notify_intervention を再発火しない（cross-cycle 冪等化）。state 破損・欠落時は
#   fail-open（従来の再投稿に退行 / silent fail なし）。
# ─────────────────────────────────────────────────────────────────────────────
fr_terminate_max_attempts() {
  local kind="$1" number="$2" total="$3"

  # #140: cross-cycle べき等ガード。既に terminal なら再発火せず即 return 0。
  # state 不在 / 破損は fr_load_state が {} を返し fr_is_terminated が未終端扱い（fail-open）。
  local prev_state prev_status
  prev_state="$(fr_load_state "$kind" "$number")"
  if prev_status=$(fr_is_terminated "$prev_state"); then
    fr_log "${kind}=#${number} terminated reason=${prev_status} suppressed=terminate-max-attempts"
    return 0
  fi

  local body
  body="$(printf 'Failed Recovery Processor (#101): 通算 attempt 上限に到達したため修正試行を停止します（通算 %s 回 / 上限 %s 回 / 終端理由: max-attempts）。\n\n`codex-failed` ラベルは据え置きます。手動レビューに移行してください。' "$total" "$FAILED_RECOVERY_MAX_ATTEMPTS")"
  fr_post_attempt_comment "$kind" "$number" "$body" || true
  rs_set_result "$LABEL_FAILED" || true
  # Slack 介入通知（#105）。gate OFF（既定）では no-op。
  sn_notify_intervention "failed-recovery-budget" "$kind" "$number" \
    "通算 attempt 上限到達で codex-failed 据え置き（手動レビュー必要）" || true

  # #140: terminal 状態を永続化する（以後のサイクルで fetch から除外され再発火しない）。
  # signature / head_sha は前回値を継承、immediate_failure_streak は省略で自動継承。
  # 永続化失敗は fr_warn で明示し fail-open（次サイクルは従来どおり再投稿に退行）。
  local prev_sig prev_head
  prev_sig=$(printf '%s' "$prev_state" | jq -r '.last_failure_signature // ""' 2>/dev/null || echo "")
  prev_head=$(printf '%s' "$prev_state" | jq -r '.last_head_sha // ""' 2>/dev/null || echo "")
  fr_save_state "$kind" "$number" "$total" "max-attempts" "$prev_sig" "$prev_head" \
    || fr_warn "fr_terminate_max_attempts: fr_save_state 失敗 ${kind}=#${number}（cross-cycle 冪等性が失われる可能性）"

  fr_log "${kind}=#${number} terminated reason=max-attempts total=${total} max=${FAILED_RECOVERY_MAX_ATTEMPTS}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_terminate_no_progress: no-progress 検出時の確実な終端（codex-failed 据え置き）
#   入力: $1=kind $2=number $3=total_attempts $4=signature（任意・ログ用）
#   戻り値: 0 固定。run-summary 通知 1 回 + コメント 1 件。ラベルは据え置く。
#   #140: last_status="no-progress" は fr_run_recovery_attempt（return 3 直前）で永続化
#   済みのため本関数では保存しない。cross-cycle 冪等化は fr_fetch_* の terminal 除外が
#   主機構（本関数に冒頭ガードを置くと初回の正当な終端コメントまで抑止されるため置かない）。
# ─────────────────────────────────────────────────────────────────────────────
fr_terminate_no_progress() {
  local kind="$1" number="$2" total="$3" signature="${4:-}"
  local body
  body="$(printf 'Failed Recovery Processor (#101): no-progress を検出したため修正試行を停止します（通算 %s 回 / 終端理由: no-progress / 直前と同一の失敗が再発・無進捗）。\n\n`codex-failed` ラベルは据え置きます。手動レビューに移行してください。' "$total")"
  fr_post_attempt_comment "$kind" "$number" "$body" || true
  rs_set_result "$LABEL_FAILED" || true
  # Slack 介入通知（#105）。gate OFF（既定）では no-op。
  sn_notify_intervention "failed-recovery-no-progress" "$kind" "$number" \
    "no-progress 検出で codex-failed 据え置き（手動レビュー必要）" || true
  local sig_prefix=""
  if [ -n "$signature" ]; then
    sig_prefix=" signature=$(printf '%s' "$signature" | cut -c1-8)"
  fi
  fr_log "${kind}=#${number} terminated reason=no-progress total=${total}${sig_prefix}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# fr_terminate_immediate_failure_streak: 即時失敗連続上限到達時の確実な終端（#137）
#   入力: $1=kind $2=number $3=streak_count
#   戻り値: 0 固定。run-summary 通知 1 回 + コメント 1 件。ラベルは据え置く（人間へ）。
#   max-attempts と区別された終端理由 `immediate-failure-streak` を用いる（運用者が
#   「codex が試行した結果ダメだった」と「codex が起動できなかった」を切り分け可能）。
#   #140: last_status="immediate-failure-streak" を state JSON へ永続化し cross-cycle
#   冪等化する。既に terminal なら再発火しない（state 破損・欠落時は fail-open）。
# ─────────────────────────────────────────────────────────────────────────────
fr_terminate_immediate_failure_streak() {
  local kind="$1" number="$2" streak="${3:-0}"
  if ! [[ "$streak" =~ ^[0-9]+$ ]]; then
    streak=0
  fi

  # #140: cross-cycle べき等ガード。既に terminal なら再発火せず即 return 0。
  local prev_state prev_status
  prev_state="$(fr_load_state "$kind" "$number")"
  if prev_status=$(fr_is_terminated "$prev_state"); then
    fr_log "${kind}=#${number} terminated reason=${prev_status} suppressed=terminate-immediate-failure-streak"
    return 0
  fi

  local body
  body="$(printf 'Failed Recovery Processor (#101): codex の即時失敗（起動直後の rc≠0 終了）が連続 %s 回に達したため修正試行を停止します（上限 %s 回 / 終端理由: immediate-failure-streak）。codex が起動不能の可能性があります（認証エラー / CLI 環境差など）。\n\n`codex-failed` ラベルは据え置きます。手動レビューに移行してください。' "$streak" "${FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK:-3}")"
  fr_post_attempt_comment "$kind" "$number" "$body" || true
  rs_set_result "$LABEL_FAILED" || true
  # Slack 介入通知（#105）。gate OFF（既定）では no-op。
  sn_notify_intervention "failed-recovery-immediate-failure-streak" "$kind" "$number" \
    "即時失敗連続上限到達で codex-failed 据え置き（codex 起動不能の可能性 / 手動レビュー必要）" || true

  # #140: terminal 状態を永続化する（以後のサイクルで fetch から除外され再発火しない）。
  local prev_total prev_sig prev_head
  prev_total=$(printf '%s' "$prev_state" | jq -r '.total_attempts // 0' 2>/dev/null || echo 0)
  [[ "$prev_total" =~ ^[0-9]+$ ]] || prev_total=0
  prev_sig=$(printf '%s' "$prev_state" | jq -r '.last_failure_signature // ""' 2>/dev/null || echo "")
  prev_head=$(printf '%s' "$prev_state" | jq -r '.last_head_sha // ""' 2>/dev/null || echo "")
  fr_save_state "$kind" "$number" "$prev_total" "immediate-failure-streak" "$prev_sig" "$prev_head" "$streak" \
    || fr_warn "fr_terminate_immediate_failure_streak: fr_save_state 失敗 ${kind}=#${number}（cross-cycle 冪等性が失われる可能性）"

  fr_log "${kind}=#${number} terminated reason=immediate-failure-streak streak=${streak} max=${FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK:-3}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# _fr_dispatch_candidate: 1 候補を処理し attempt の rc を終端関数へルーティングする
#   入力: $1=kind $2=number $3=pr_json（PR のみ）
#   戻り値: 0 固定（後続候補の処理を阻害しない）
# ─────────────────────────────────────────────────────────────────────────────
_fr_dispatch_candidate() {
  local kind="$1" number="$2" pr_json="${3:-}"

  local rc=0
  fr_run_recovery_attempt "$kind" "$number" "$pr_json" || rc=$?

  case "$rc" in
    0|1|99)
      # 0=復旧 / 1=失敗（次サイクル再試行）/ 99=quota 待機。いずれも非終端。
      ;;
    2)
      local total
      total=$(fr_load_state "$kind" "$number" | jq -r '.total_attempts // 0' 2>/dev/null || echo 0)
      fr_terminate_max_attempts "$kind" "$number" "$total"
      ;;
    3)
      local st total sig
      st="$(fr_load_state "$kind" "$number")"
      total=$(printf '%s' "$st" | jq -r '.total_attempts // 0' 2>/dev/null || echo 0)
      sig=$(printf '%s' "$st" | jq -r '.last_failure_signature // ""' 2>/dev/null || echo "")
      fr_terminate_no_progress "$kind" "$number" "$total" "$sig"
      ;;
    4)
      # #137: 即時失敗連続上限到達。streak は state JSON から再読み込みする。
      local ifs_state ifs_streak
      ifs_state="$(fr_load_state "$kind" "$number")"
      ifs_streak=$(printf '%s' "$ifs_state" | jq -r '.immediate_failure_streak // 0' 2>/dev/null || echo 0)
      [[ "$ifs_streak" =~ ^[0-9]+$ ]] || ifs_streak=0
      fr_terminate_immediate_failure_streak "$kind" "$number" "$ifs_streak"
      ;;
    *)
      fr_warn "${kind}=#${number}: fr_run_recovery_attempt が想定外の rc=${rc} を返しました（skip）"
      ;;
  esac
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# process_failed_recovery: dispatcher エントリ（毎サイクル呼ばれる）
#   戻り値: 0 固定（後続 processor を阻害しない / dispatcher fail-continue 契約）
#   gate: full_auto_enabled(#97) AND fr_resolve_gate_enabled の AND 二重 opt-in
# ─────────────────────────────────────────────────────────────────────────────
process_failed_recovery() {
  # AND 二重 opt-in。kill switch OFF は #97 ログに委ね本関数では無言で return。
  if ! full_auto_enabled; then
    return 0
  fi
  if ! fr_resolve_gate_enabled; then
    fr_log "suppressed by FAILED_RECOVERY_ENABLED gate (no-op)"
    return 0
  fi

  fr_log "サイクル開始 (max_attempts=${FAILED_RECOVERY_MAX_ATTEMPTS}, max_prs=${FAILED_RECOVERY_MAX_PRS}, model=${FAILED_RECOVERY_DEV_MODEL}, state_dir=${FAILED_RECOVERY_STATE_DIR})"

  # 1) codex-failed Issue
  local issues_json issue_iter issue_number
  issues_json="$(fr_fetch_failed_issues)"
  issue_iter=$(printf '%s' "$issues_json" | jq -r '.[].number' 2>/dev/null || echo "")
  while IFS= read -r issue_number; do
    [ -z "$issue_number" ] && continue
    [[ "$issue_number" =~ ^[0-9]+$ ]] || continue
    _fr_dispatch_candidate "issue" "$issue_number" ""
  done <<< "$issue_iter"

  # 2) auto-merge 待ち PR（CI error）。1 サイクルの処理上限を適用。
  local prs_json total pr_iter pr_json processed=0
  prs_json="$(fr_fetch_failed_prs)"
  total=$(printf '%s' "$prs_json" | jq -r 'length' 2>/dev/null || echo 0)
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  pr_iter=$(printf '%s' "$prs_json" | jq -c '.[]' 2>/dev/null || echo "")
  while IFS= read -r pr_json; do
    [ -z "$pr_json" ] && continue
    if [ "$processed" -ge "$FAILED_RECOVERY_MAX_PRS" ]; then
      fr_log "PR 処理上限 ${FAILED_RECOVERY_MAX_PRS} 件に到達（残り $((total - processed)) 件は次サイクルへ持ち越し）"
      break
    fi
    local pr_number
    pr_number=$(printf '%s' "$pr_json" | jq -r '.number' 2>/dev/null || echo "")
    [[ "$pr_number" =~ ^[0-9]+$ ]] || continue
    _fr_dispatch_candidate "pr" "$pr_number" "$pr_json"
    processed=$((processed + 1))
  done <<< "$pr_iter"

  fr_log "サイクル終了 (issues=$(printf '%s' "$issues_json" | jq -r 'length' 2>/dev/null || echo 0), prs_processed=${processed})"
  return 0
}
