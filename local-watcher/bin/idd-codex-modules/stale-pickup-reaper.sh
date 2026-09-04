#!/usr/bin/env bash
# stale-pickup-reaper.sh — watcher の Stale Pickup Reaper モジュール（idd-claude #379/F6 移植）
#
# 用途:
#   watcher セッションがクラッシュ / OOM / マシン再起動などで異常終了したとき、
#   `codex-picked-up` / `codex-claimed` ラベルが Issue に残り続け、dispatcher が
#   「処理中」とみなして候補から永久除外する停止状態を、3 観点（marker 経過時間 /
#   slot ロック保持 / セッション存在）の AND 判定で「非アクティブ」と確定した Issue
#   についてのみ `codex-auto-dev` 状態へ自動復帰させる Stale Pickup Reaper を集約する。
#   failed-recovery (#101) が `codex-failed` のみを扱う構造の gap を埋める位置付け。
#
#   - sr_is_enabled    : 単独 opt-in gate（STALE_PICKUP_REAPER_ENABLED=true 厳密一致）
#   - sr_marker_path   : marker JSON の絶対パスを返す純粋関数
#   - sr_load_marker   : marker JSON 読み出し（不在 / parse 失敗で `{}` を返す fail-open）
#   - sr_save_marker   : marker JSON の atomic write（mktemp → mv -f）
#   - sr_fetch_candidates  : 候補列挙（label filter / codex-picked-up + codex-claimed）
#   - sr_check_marker_age : marker.first_seen_at の経過時間を閾値判定（観点 1）
#   - sr_check_slot_lock  : slot lock file の保持状態を flock で観測（観点 2）
#   - sr_lockfile_is_held : 単一 lock file の flock 保持状態を試行観測（#180 / 観点 3 の前段）
#   - sr_check_session    : lock 保持 pid の生存を kill -0 で観測（観点 3。解放済み lock は非セッション扱い / #180）
#   - sr_is_active        : 3 観点 AND 結合（全観点 rc=0 のときのみ inactive 確定）
#   - sr_revert_to_auto_dev      : ラベル除去 + codex-auto-dev 残存確認（同サイクル冪等）
#   - process_stale_pickup_reaper : watcher 本体からの単一エントリ（fail-continue / 戻り値常に 0）
#
# 配置先:
#   $HOME/bin/idd-codex-modules/stale-pickup-reaper.sh（install.sh が local-watcher/bin/idd-codex-modules/ から配置）
#
# 依存:
#   - 本モジュールは idd-codex-issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー（sr_log / sr_warn / sr_error）は core_utils.sh にあるため再定義しない。
#   - グローバル（$STALE_PICKUP_REAPER_* / $LABEL_PICKED / $LABEL_CLAIMED / $LABEL_TRIGGER /
#     $SLOT_LOCK_DIR / $REPO_SLUG / $REPO / $LABEL_FAILED 等）は本体 Config ブロックで定義済み。
#   - 外部 CLI: jq / mktemp / gh / date / flock / fuser / lsof。
#   - 関数 prefix `sr_` を namespace として採用する。
#
# 移植元: idd-claude #379（PR #382）`modules/stale-pickup-reaper.sh`。idd-codex の
#   slot-lock 命名（$SLOT_LOCK_DIR/${REPO_SLUG}-slot-*.lock）・LABEL_* 定数は同型のため、
#   ラベル / state dir / 除外フィルタのみ codex 向けに差し替え、判定ロジックは温存。

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Gate Layer
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Stale Pickup Reaper の単独 opt-in gate（純粋関数 / 副作用なし）。
# `STALE_PICKUP_REAPER_ENABLED=true` 厳密一致のときのみ 0、それ以外は 1（OFF）。
# failed-recovery と異なり FULL_AUTO_ENABLED は要求しない単独 gate（セッション喪失の
# 復旧はリスクが低く、full-auto 非利用環境でも有用なため）。
#   0 = enabled / 1 = disabled
sr_is_enabled() {
  [ "${STALE_PICKUP_REAPER_ENABLED:-false}" = "true" ] || return 1
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Persistence Layer
#
# 各候補 Issue ごとに 1 ファイルの marker JSON を $STALE_PICKUP_REAPER_STATE_DIR/<issue>.json
# に保存する。failed-recovery (#101) の state schema と同じ atomic write + repo-slug 分離方針。
#   { issue, first_seen_at, last_seen_at, last_known_labels[], status(observing|reverted),
#     revert_at }
#   - first_seen_at: pickup ラベル滞留を最初に観測した時刻（タイムスタンプ marker の起算点）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Args: $1=issue number / Stdout: $STALE_PICKUP_REAPER_STATE_DIR/<issue>.json / Returns: 0
sr_marker_path() {
  local issue_number="$1"
  printf '%s/%s.json' "$STALE_PICKUP_REAPER_STATE_DIR" "$issue_number"
}

# marker JSON を stdout に出力する。不在 / parse 失敗時は `{}`（fail-open）。Returns: 0
sr_load_marker() {
  local issue_number="$1"
  local marker_file
  marker_file=$(sr_marker_path "$issue_number")
  if [ ! -f "$marker_file" ]; then
    printf '%s' "{}"
    return 0
  fi
  local content
  if ! content=$(jq -c '.' "$marker_file" 2>/dev/null); then
    printf '%s' "{}"
    return 0
  fi
  printf '%s' "$content"
  return 0
}

# marker JSON を atomic write で永続化する（mkdir -p → 同一 dir mktemp → mv -f）。
# Args: $1=issue $2=first_seen_at $3=last_seen_at $4=labels_json $5=status $6=revert_at
# Returns: 0=persisted / 1=failure（呼出側を落とさない / sr_warn）
sr_save_marker() {
  local issue_number="$1"
  local first_seen_at="$2"
  local last_seen_at="$3"
  local labels_json="$4"
  local status="$5"
  local revert_at="$6"

  if ! mkdir -p "$STALE_PICKUP_REAPER_STATE_DIR" 2>/dev/null; then
    sr_warn "sr_save_marker: mkdir -p \"$STALE_PICKUP_REAPER_STATE_DIR\" 失敗"
    return 1
  fi

  local marker_file
  marker_file=$(sr_marker_path "$issue_number")

  # labels_json が空 / 非 JSON 配列なら空配列で正規化（fail-safe）。
  local labels_normalized=""
  if [ -n "$labels_json" ]; then
    labels_normalized=$(printf '%s' "$labels_json" | jq -c 'if type == "array" then . else [] end' 2>/dev/null) || labels_normalized=""
  fi
  if [ -z "$labels_normalized" ]; then
    labels_normalized="[]"
  fi

  local new_marker
  if ! new_marker=$(jq -n \
      --argjson issue "$issue_number" \
      --arg first_seen_at "$first_seen_at" \
      --arg last_seen_at "$last_seen_at" \
      --argjson last_known_labels "$labels_normalized" \
      --arg status "$status" \
      --arg revert_at "$revert_at" \
      '{
        issue: $issue,
        first_seen_at: $first_seen_at,
        last_seen_at: $last_seen_at,
        last_known_labels: $last_known_labels,
        status: $status,
        revert_at: $revert_at
      }' 2>/dev/null); then
    sr_warn "sr_save_marker: JSON 組み立て失敗 issue=$issue_number"
    return 1
  fi

  # atomic write: 同一 dir に temp file → mv -f で rename（同一 FS / atomic rename 保証）。
  local tmp_file
  if ! tmp_file=$(mktemp "${marker_file}.XXXXXX" 2>/dev/null); then
    sr_warn "sr_save_marker: mktemp 失敗 issue=$issue_number"
    return 1
  fi
  if ! printf '%s\n' "$new_marker" > "$tmp_file" 2>/dev/null; then
    rm -f "$tmp_file"
    sr_warn "sr_save_marker: temp file 書き込み失敗 issue=$issue_number"
    return 1
  fi
  if ! mv -f "$tmp_file" "$marker_file" 2>/dev/null; then
    rm -f "$tmp_file"
    sr_warn "sr_save_marker: atomic rename 失敗 issue=$issue_number"
    return 1
  fi
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Candidate Selection Layer
#
# `codex-picked-up` / `codex-claimed` が残ったままの open Issue を server-side filter で
# 列挙する。人間判断待ち / 別 processor 領分のラベルは除外。取得失敗時は `[]` + sr_warn。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# sr_fetch_candidates: codex-picked-up / codex-claimed Issue 群を列挙する。
# Stdout: JSON 配列文字列（候補なし / 取得失敗時は `[]`）/ Returns: 0（常に。fail-continue）
sr_fetch_candidates() {
  # 除外条件（人間判断待ち / failed-recovery 領分 / 別 processor の正当な待機状態）。
  local exclude_filter
  exclude_filter="-label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_AWAITING_DESIGN\" -label:\"$LABEL_NEEDS_QUOTA_WAIT\" -label:\"$LABEL_BLOCKED\" -label:\"$LABEL_STAGED_FOR_RELEASE\" -label:\"$LABEL_AWAITING_SLOT\""

  # クエリ 1: codex-picked-up 候補
  local picked_json
  if ! picked_json=$(timeout "$STALE_PICKUP_REAPER_GH_TIMEOUT" gh issue list \
      --repo "$REPO" \
      --state open \
      --search "label:\"$LABEL_PICKED\" $exclude_filter" \
      --json number,labels,title,url,updatedAt \
      --limit "$STALE_PICKUP_REAPER_MAX_ISSUES" 2>/dev/null); then
    sr_warn "sr_fetch_candidates: gh issue list 失敗（label:$LABEL_PICKED / timeout または API エラー）"
    echo "[]"
    return 0
  fi
  if [ -z "$picked_json" ]; then
    picked_json="[]"
  fi
  if ! printf '%s' "$picked_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    sr_warn "sr_fetch_candidates: gh issue list が JSON 配列を返さなかった（label:$LABEL_PICKED）"
    picked_json="[]"
  fi

  # クエリ 2: codex-claimed 候補
  local claimed_json
  if ! claimed_json=$(timeout "$STALE_PICKUP_REAPER_GH_TIMEOUT" gh issue list \
      --repo "$REPO" \
      --state open \
      --search "label:\"$LABEL_CLAIMED\" $exclude_filter" \
      --json number,labels,title,url,updatedAt \
      --limit "$STALE_PICKUP_REAPER_MAX_ISSUES" 2>/dev/null); then
    sr_warn "sr_fetch_candidates: gh issue list 失敗（label:$LABEL_CLAIMED / timeout または API エラー）"
    echo "[]"
    return 0
  fi
  if [ -z "$claimed_json" ]; then
    claimed_json="[]"
  fi
  if ! printf '%s' "$claimed_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    sr_warn "sr_fetch_candidates: gh issue list が JSON 配列を返さなかった（label:$LABEL_CLAIMED）"
    claimed_json="[]"
  fi

  # 2 結果を結合 + dedup + truncate（jq で完結）。
  local merged_json
  if ! merged_json=$(jq -n -c \
      --argjson picked "$picked_json" \
      --argjson claimed "$claimed_json" \
      --argjson limit "$STALE_PICKUP_REAPER_MAX_ISSUES" \
      '($picked + $claimed) | unique_by(.number) | .[0:$limit]' 2>/dev/null); then
    sr_warn "sr_fetch_candidates: jq 結合 / dedup 失敗"
    echo "[]"
    return 0
  fi
  printf '%s' "$merged_json"
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Active Decision Layer
#
# 復旧候補が「現在もアクティブな処理セッションに握られているか」を 3 観点（marker 経過
# 時間 / slot ロック保持 / セッション存在）の AND で判定する。1 つでも「アクティブの
# 可能性あり」なら revert しない（誤検出回避優先）。判定中は read-only（gh を呼ばない）。
#   sr_check_marker_age: 0=aged(閾値超) / 1=fresh(閾値未満 / 不明)
#   sr_check_slot_lock:  0=no lock / 1=some lock held / 2=判定不能（safe-side で 1 扱い）
#   sr_check_session:    0=no session / 1=session may be alive（safe-side 含む）
#   sr_is_active:        0=active or unknown(keep) / 1=inactive(revert へ)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# marker.first_seen_at の経過分数を閾値判定する純粋関数。
#   0=aged（>= 閾値）/ 1=fresh（閾値未満 / 不在 / parse 失敗 = safe-side fresh）
sr_check_marker_age() {
  local marker_json="$1"
  local first_seen_at
  first_seen_at=$(printf '%s' "$marker_json" | jq -r '.first_seen_at // empty' 2>/dev/null)
  if [ -z "$first_seen_at" ]; then
    return 1
  fi

  # GNU date (Linux) 優先、失敗時 BSD date (macOS) fallback、両方失敗は safe-side fresh
  local first_epoch=""
  first_epoch=$(date -d "$first_seen_at" +%s 2>/dev/null) || first_epoch=""
  if [ -z "$first_epoch" ]; then
    first_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$first_seen_at" "+%s" 2>/dev/null) || first_epoch=""
  fi
  if [ -z "$first_epoch" ]; then
    return 1
  fi

  local now_epoch
  now_epoch=$(date +%s)
  local age_minutes=$(( (now_epoch - first_epoch) / 60 ))

  if [ "$age_minutes" -ge "$STALE_PICKUP_REAPER_THRESHOLD_MINUTES" ]; then
    return 0
  fi
  return 1
}

# Slot lock file の保持状態を `flock -n -x` で観測する（試行的・lock を奪わない）。
#   0=no lock held / 1=some lock held（アクティブの可能性）/ 2=判定不能（flock 不在 / safe-side）
sr_check_slot_lock() {
  local _marker_json="${1:-}"
  : "$_marker_json"

  if ! command -v flock >/dev/null 2>&1; then
    return 2
  fi

  local lockfile
  local some_held=0
  local any_exists=0
  # shellcheck disable=SC2231
  for lockfile in "$SLOT_LOCK_DIR/${REPO_SLUG}-slot-"*.lock; do
    [ -f "$lockfile" ] || continue
    any_exists=1
    if ! flock -n -x "$lockfile" true 2>/dev/null; then
      some_held=1
      break
    fi
  done

  if [ "$any_exists" = "0" ]; then
    return 0
  fi
  if [ "$some_held" = "1" ]; then
    return 1
  fi
  return 0
}

# 単一 slot lock file が現在 flock で保持されているかを試行的に観測する（lock を奪わない）。
#   0=解放済み（`flock -n -x` が即時取得できた）/ 1=保持中 / 2=判定不能（flock 不在）
sr_lockfile_is_held() {
  local lockfile="$1"
  if ! command -v flock >/dev/null 2>&1; then
    return 2
  fi
  if flock -n -x "$lockfile" true 2>/dev/null; then
    return 0
  fi
  return 1
}

# Lock file 保持 pid の生存確認で「watcher / codex セッション存在」を判定する。
#   0=no session（lock 不在 / 全 lock 解放済み / 全 pid 非生存）/ 1=session may be alive（safe-side 含む）
#
# Issue #180: slot lock file は `$SLOT_LOCK_DIR/<repo-slug>-slot-N.lock` に **永続配置** され、
# worker 終了後も削除されない。旧実装は「lock file が存在するのに pid を取得できない」を常に
# safe-side（rc=1）としていたため、解放済み lock でも `sess=1` となり reaper が永久に回収できな
# かった。本実装は lock file ごとに `flock -n -x` で **実際に保持されているか** を先に観測し、
#   - 解放済み（取得可）→ その slot にセッションは無い（pid 不在は当然）→ 次の lock file へ
#   - 保持中 → 実際に誰かが握っているためセッション存続とみなし rc=1（claim を解除しない）
# とする。flock が使えない環境（判定不能）では旧実装と同じ owner pid のみの判定へ fallback し、
# pid 取得手段が無い / pid を取れない場合は従来どおり safe-side で rc=1、生存 pid があれば rc=1。
sr_check_session() {
  local _marker_json="${1:-}"
  : "$_marker_json"

  local lockfile
  local any_lockfile=0
  for lockfile in "$SLOT_LOCK_DIR/${REPO_SLUG}-slot-"*.lock; do
    [ -f "$lockfile" ] || continue
    any_lockfile=1
    break
  done
  if [ "$any_lockfile" = "0" ]; then
    return 0
  fi

  # pid 取得手段: Linux fuser → macOS lsof の順。両方不在は pid 判定不能（後段で safe-side）。
  local pid_tool=""
  if command -v fuser >/dev/null 2>&1; then
    pid_tool="fuser"
  elif command -v lsof >/dev/null 2>&1; then
    pid_tool="lsof"
  fi

  local pids pid held_rc
  for lockfile in "$SLOT_LOCK_DIR/${REPO_SLUG}-slot-"*.lock; do
    [ -f "$lockfile" ] || continue

    held_rc=0
    sr_lockfile_is_held "$lockfile" || held_rc=$?
    case "$held_rc" in
      0)
        # Issue #180: lock は解放済み。永続 lock file の存在だけでは session とみなさない。
        continue
        ;;
      1)
        # lock が実際に保持されている → セッション存続とみなし claim を解除しない（AC 4）。
        return 1
        ;;
    esac

    # rc=2: flock 判定不能（flock 不在）→ 旧実装と同じ owner pid のみの判定へ fallback する。
    if [ -z "$pid_tool" ]; then
      # pid 取得手段なし → safe-side で「保持の可能性あり」
      return 1
    fi
    pids=""
    case "$pid_tool" in
      fuser) pids=$(fuser "$lockfile" 2>/dev/null || true) ;;
      lsof)  pids=$(lsof -t "$lockfile" 2>/dev/null || true) ;;
    esac

    if [ -z "$pids" ]; then
      # 保持中（または判定不能）なのに pid を取得できない → safe-side で「保持の可能性あり」
      return 1
    fi

    for pid in $pids; do
      case "$pid" in
        ''|*[!0-9]*) continue ;;
      esac
      if kill -0 "$pid" 2>/dev/null; then
        return 1
      fi
    done
  done

  return 0
}

# 3 観点 AND 結合で「非アクティブ」確定を判定する。判定根拠を 1 行ログ。
#   0=active or unknown(keep) / 1=inactive(revert へ)
sr_is_active() {
  local marker_json="$1"
  local age lock sess
  local issue_id

  issue_id=$(printf '%s' "$marker_json" | jq -r '.issue // "?"' 2>/dev/null) || issue_id="?"

  age=0
  sr_check_marker_age "$marker_json" || age=$?
  lock=0
  sr_check_slot_lock "$marker_json" || lock=$?
  sess=0
  sr_check_session "$marker_json" || sess=$?

  if [ "$age" = "0" ] && [ "$lock" = "0" ] && [ "$sess" = "0" ]; then
    sr_log "issue=#$issue_id inactive (age>threshold, no slot lock, no session) age=$age lock=$lock sess=$sess"
    return 1
  fi
  sr_log "issue=#$issue_id keep age=$age lock=$lock sess=$sess"
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Recovery Action Layer
#
# 「非アクティブ確定」Issue から codex-picked-up / codex-claimed を除去し、codex-auto-dev
# の残存を確認・必要なら付与する。branch は一切触らない（`git` を呼ばない）。同サイクル
# 内重複は SR_PROCESSED_THIS_CYCLE in-memory set で防ぐ。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# 同サイクル内に既に revert 済みの Issue 番号を保持する（orchestrator 起動毎に bash
# プロセスごと再初期化されるため明示 unset 不要）。
SR_PROCESSED_THIS_CYCLE="${SR_PROCESSED_THIS_CYCLE:-}"

# 非アクティブ確定 Issue から codex-picked-up / codex-claimed を除去し codex-auto-dev 残存確認。
# Args: $1=issue number（^[0-9]+$）, $2=marker_json（ログ用）
# Returns: 0=reverted（同サイクル 2 回目以降は idempotent no-op）/ 1=failed（observing 温存）
sr_revert_to_auto_dev() {
  local issue="$1"
  local marker_json="${2:-{\}}"

  # 未信頼入力 sanitize: issue 番号の数値検証（引数注入の予防）。
  case "$issue" in
    ''|*[!0-9]*)
      sr_warn "sr_revert_to_auto_dev: 不正な issue 番号 issue=$(printf '%q' "$issue")（数値以外 / reject）"
      return 1
      ;;
  esac

  # 同サイクル内 2 回目以降は idempotent no-op。
  case " $SR_PROCESSED_THIS_CYCLE " in
    *" $issue "*)
      sr_log "issue=#$issue skip (already processed in this cycle)"
      return 0
      ;;
  esac

  # marker から prev_labels CSV と経過分数を算出（ログ用 / 副作用なし）。
  local prev_labels_csv=""
  prev_labels_csv=$(printf '%s' "$marker_json" | jq -r '
    if (.last_known_labels // null) | type == "array"
    then (.last_known_labels | join(","))
    else ""
    end
  ' 2>/dev/null) || prev_labels_csv=""

  local age_minutes="?"
  local first_seen_at
  first_seen_at=$(printf '%s' "$marker_json" | jq -r '.first_seen_at // empty' 2>/dev/null) || first_seen_at=""
  if [ -n "$first_seen_at" ]; then
    local first_epoch=""
    first_epoch=$(date -d "$first_seen_at" +%s 2>/dev/null) || first_epoch=""
    if [ -z "$first_epoch" ]; then
      first_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$first_seen_at" "+%s" 2>/dev/null) || first_epoch=""
    fi
    if [ -n "$first_epoch" ]; then
      local now_epoch
      now_epoch=$(date +%s)
      age_minutes=$(( (now_epoch - first_epoch) / 60 ))
    fi
  fi

  # 1 回目 PATCH: codex-picked-up / codex-claimed を 1 リクエストで除去。
  if ! gh issue edit "$issue" --repo "$REPO" -- \
      --remove-label "$LABEL_PICKED" \
      --remove-label "$LABEL_CLAIMED" >/dev/null 2>&1; then
    sr_warn "sr_revert_to_auto_dev: issue=#$issue ラベル除去失敗（codex-picked-up / codex-claimed）"
    return 1
  fi

  # 2 回目: 現ラベルを取得し codex-auto-dev 欠落時のみ付与。取得失敗時は WARN + skip
  # （remove 成功済みのため半端な状態は残らず、次サイクルで再判定の機会がある）。
  local labels_json
  if ! labels_json=$(gh issue view "$issue" --repo "$REPO" --json labels 2>/dev/null); then
    sr_warn "sr_revert_to_auto_dev: issue=#$issue 現ラベル取得失敗（codex-auto-dev 付与判定 skip）"
  else
    local has_autodev
    has_autodev=$(printf '%s' "$labels_json" | jq -r --arg trigger "$LABEL_TRIGGER" '
      if (.labels // null) | type == "array"
      then (any(.labels[]; .name == $trigger))
      else false
      end
    ' 2>/dev/null) || has_autodev="false"
    if [ "$has_autodev" != "true" ]; then
      if ! gh issue edit "$issue" --repo "$REPO" -- \
          --add-label "$LABEL_TRIGGER" >/dev/null 2>&1; then
        sr_warn "sr_revert_to_auto_dev: issue=#$issue codex-auto-dev 付与失敗（次サイクル再評価へ）"
        return 1
      fi
    fi
  fi

  SR_PROCESSED_THIS_CYCLE="$SR_PROCESSED_THIS_CYCLE $issue"
  sr_log "issue=#$issue reverted reason=stale-pickup orphan age=${age_minutes}m prev_labels=$prev_labels_csv"
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Orchestrator Layer
#
# 1 watcher サイクルの SPR エントリ。Gate → Candidate → Marker update → Active 判定 →
# Revert を直列実行し、全例外を fail-continue で吸収する（戻り値は常に 0）。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

process_stale_pickup_reaper() {
  # 1 段目 gate: opt-in OFF なら gh API を一切呼ばずに return 0。
  if ! sr_is_enabled; then
    return 0
  fi

  sr_log "process_stale_pickup_reaper: 起動 (THRESHOLD_MINUTES=${STALE_PICKUP_REAPER_THRESHOLD_MINUTES} MAX_ISSUES=${STALE_PICKUP_REAPER_MAX_ISSUES})"

  local candidates_json
  candidates_json=$(sr_fetch_candidates 2>/dev/null || echo "[]")
  if [ -z "$candidates_json" ]; then
    candidates_json="[]"
  fi
  local candidates_count
  candidates_count=$(printf '%s' "$candidates_json" | jq -r 'length' 2>/dev/null || echo "0")
  if ! [[ "$candidates_count" =~ ^[0-9]+$ ]]; then
    candidates_count=0
  fi
  sr_log "process_stale_pickup_reaper: 候補 ${candidates_count} 件"

  local now_iso
  now_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%S')

  local i=0
  while [ "$i" -lt "$candidates_count" ]; do
    local issue_number labels_json_compact marker_json first_seen_at
    issue_number=$(printf '%s' "$candidates_json" | jq -r --argjson i "$i" '.[$i].number // empty' 2>/dev/null || echo "")

    if ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
      sr_warn "process_stale_pickup_reaper: 不正な issue 番号 index=${i}（skip）"
      i=$((i + 1))
      continue
    fi

    case " $SR_PROCESSED_THIS_CYCLE " in
      *" $issue_number "*)
        sr_log "issue=#$issue_number skip (already processed in this cycle)"
        i=$((i + 1))
        continue
        ;;
    esac

    labels_json_compact=$(printf '%s' "$candidates_json" | jq -c --argjson i "$i" '
      [(.[$i].labels // []) | .[].name]
    ' 2>/dev/null) || labels_json_compact="[]"
    if [ -z "$labels_json_compact" ]; then
      labels_json_compact="[]"
    fi

    marker_json=$(sr_load_marker "$issue_number" 2>/dev/null || echo "{}")
    if [ -z "$marker_json" ]; then
      marker_json="{}"
    fi
    first_seen_at=$(printf '%s' "$marker_json" | jq -r '.first_seen_at // empty' 2>/dev/null || echo "")
    if [ -z "$first_seen_at" ]; then
      first_seen_at="$now_iso"
    fi

    if ! sr_save_marker "$issue_number" "$first_seen_at" "$now_iso" "$labels_json_compact" "observing" ""; then
      sr_warn "process_stale_pickup_reaper: issue=#${issue_number} marker save 失敗（next-cycle で再試行）"
      i=$((i + 1))
      continue
    fi

    marker_json=$(sr_load_marker "$issue_number" 2>/dev/null || echo "{}")
    if [ -z "$marker_json" ]; then
      marker_json="{}"
    fi

    # 3 観点 AND 判定。アクティブの可能性ありなら何もせず次へ。
    if sr_is_active "$marker_json"; then
      i=$((i + 1))
      continue
    fi

    # 非アクティブ確定 → revert。失敗時は marker を observing のまま温存。
    if sr_revert_to_auto_dev "$issue_number" "$marker_json"; then
      if ! sr_save_marker "$issue_number" "$first_seen_at" "$now_iso" "$labels_json_compact" "reverted" "$now_iso"; then
        sr_warn "process_stale_pickup_reaper: issue=#${issue_number} reverted marker save 失敗（実害なし / 次サイクル再保存）"
      fi
    else
      sr_warn "process_stale_pickup_reaper: issue=#${issue_number} revert 失敗（observing のまま温存 / 次サイクル再評価）"
    fi
    i=$((i + 1))
  done

  sr_log "process_stale_pickup_reaper: サマリ candidates=${candidates_count}"
  return 0
}
