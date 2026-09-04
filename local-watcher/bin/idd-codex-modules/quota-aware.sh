#!/usr/bin/env bash
# quota-aware.sh — watcher の Quota-Aware 待機制御プロセッサモジュール
#
# 用途:
#   idd-codex-issue-watcher.sh から切り出した quota 枯渇検出・待機制御プロセッサを集約する。
#   Codex Max の 5 時間ローリング quota 超過を Stage 実行中の codex CLI が出す
#   `rate_limit_event` / synthetic 429 で検知し、当該 Issue を `codex-needs-quota-wait`
#   状態にして reset 予定時刻を repo slug 単位の $LOG_DIR 配下に永続化する。次サイクル
#   以降の Quota Resume Processor が reset+grace 経過した Issue からラベルを除去して
#   通常 pickup ループに戻す。
#   - qa_detect_rate_limit  : stream-json を fold して quota 枯渇イベントを検出
#   - qa_detect_rate_limit_rollout : session rollout の rate_limits から quota reached を検出（#79 / codex 本筋）
#   - qa_log_token_usage    : turn.completed.usage を集計して per-stage token サマリをログ（#83 観測性。
#                             #176: cost-estimate.sh ロード時は model / cost_usd を同一行末尾に併記）
#   - qa_detect_collab_spawn_failures : collab subagent spawn failure を検出
#   - qa_run_codex_stage   : Stage 実行 wrapper（tee + 検出 + exit 99 sentinel）
#   - qa_persist_reset_time : reset 時刻の永続化（Issue 番号 keyed JSON）
#   - qa_load_reset_time    : reset 時刻の読み出し（移行期は本文 marker フォールバック）
#   - qa_build_escalation_comment / build_partial_escalation_comment : 状況コメント生成
#   - qa_handle_quota_exceeded : quota 検出時のラベル付与・コメント投稿・永続化
#   - process_quota_resume  : Resume Processor（全 Processor 先頭で起動）
#
# 配置先:
#   $HOME/bin/idd-codex-modules/quota-aware.sh（install.sh が local-watcher/bin/idd-codex-modules/ から配置する）
#
# 依存:
#   - 本モジュールは idd-codex-issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー（qa_log / qa_warn / qa_error / qa_format_iso8601）は core_utils.sh にあるため
#     本モジュールでは再定義しない。
#   - グローバル変数（$REPO / $QUOTA_AWARE_ENABLED / $LABEL_NEEDS_QUOTA_WAIT / reset 永続化先
#     パス等）は本体冒頭の Config ブロックで定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - 外部 CLI: gh / jq / date / codex。
#
# セットアップ参照先:
#   README.md（ディレクトリ構成・modules 化 migration note） / install.sh（配置ロジック）
#   設計参照: docs/specs/66-feat-watcher-codex-max-quota-rate-limit/design.md

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Quota-Aware Watcher Helpers (#66)
#   Codex Max の 5 時間ローリング quota 超過を、Stage 実行中の codex CLI が出す
#   `rate_limit_event` (status=exceeded) JSON で検知する。検知時は当該 Issue を
#   `codex-needs-quota-wait` 状態にし、reset 予定時刻を repo slug 単位で分離済みの $LOG_DIR
#   配下のローカルファイル（Issue 番号 keyed JSON）に永続化する（#169。Issue body の
#   read-modify-write を廃止し lost update を解消。移行期は本文 marker をフォールバック
#   読取）。次サイクル以降の Quota Resume Processor が reset+grace 経過した Issue
#   からラベルを除去して通常 pickup ループに戻す。
#
#   QUOTA_AWARE_ENABLED=false（明示 opt-out）では本セクションの全関数は呼ばれるが、
#   gate 早期 return で副作用を一切起こさない。Stage Wrapper も `"$@"` 素通しで
#   本機能導入前と 100% 互換（Req 1.1, NFR 2.1）。#112 でデフォルトは true に反転。
#
#   設計参照: docs/specs/66-feat-watcher-codex-max-quota-rate-limit/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# stdin の stream-json（1 行 1 JSON）を fold し、quota 枯渇イベントを検出して
# `<detection_path>\t<reset_epoch>[ \t<message>]` 形式の TSV を 1 検出 1 行で stdout に出力する
# （Req 1.1〜1.4, 2.1〜2.2, 3.1〜3.4, 5.1〜5.4 / Issue #66 Req 2.x との後方互換）。
#
# 検出経路（detection_path フィールド値）:
#   - `rate_limit_event_v2`  : 現行 Codex CLI スキーマ
#                              `type==rate_limit_event` かつ
#                              `rate_limit_info.status == "rejected"`
#                              （Issue #104 Bug 1 / Req 1.1）
#   - `rate_limit_event_v1`  : 旧スキーマ
#                              `type==rate_limit_event` かつ `status == "exceeded"`
#                              （Req 2.1 / Issue #66 互換維持）
#   - `synthetic_429_result` : quota 枯渇直撃時の synthetic result 行
#                              `type==result` かつ `is_error == true` かつ
#                              `api_error_status == 429`
#                              （Issue #104 Bug 2 / Req 3.1）
#   - `usage_limit_fatal`   : Codex CLI の fatal message
#                             `You've hit your usage limit ... try again at ...`
#                             （Issue #12。reset 時刻の自然言語 parse は
#                             qa_run_codex_stage 側で行う）
#                             codex-cli 0.144 系で追加された workspace 系文言
#                             `Your workspace is out of credits. ...` /
#                             `You hit your spend cap ...` も本経路で検出する
#                             （#170。reset hint を持たないため既存どおり
#                             codex_rc 透過 + warn ログとなる）
#
# Reset 時刻フィールド探索順（現行 / 旧スキーマ揺れと synthetic 429 同居を許容）:
#   1) .rate_limit_info.resetsAt / .resets_at / .reset_at  （現行スキーマ ネスト位置 / Req 1.3）
#   2) .resetsAt / .reset_at / .resets_at                  （旧スキーマ top-level / Req 2.2）
#   値の型が数値ならそのまま epoch、ISO 8601 文字列なら `fromdateiso8601` で epoch 化。
#   いずれも取得できなければ空（呼び出し側で reset 欠落 fallback / Req 1.4, 3.2）。
#
# 出力契約:
#   - 1 検出 1 行: `<detection_path>\t<epoch_or_empty>[ \t<message>]`
#   - `usage_limit_fatal` は message を第 3 フィールドへ出力する。第 2 フィールドに
#     数値 epoch が無い場合、qa_run_codex_stage が message から reset 時刻を抽出する
#   - 解析失敗（非 JSON / schema 違い）の行は無視して継続（Req 2.5 / Issue #66）
#   - allowed のみ / 通常 result（is_error:false）は無視（Req 3.4）
#   - 同一 stream に複数検出があっても全件出力（呼び出し側で `tail -1` 等を選択）
#
# 実装メモ: jq は default だと stdin を "concatenated JSON" として一括 parse する
# ため、無効な 1 行があると stream 全体が fatal で止まる。stream を停止させない
# 要件（Req 2.5）を満たすため、`-R`（raw input）で 1 行ずつ受け取り、各行を
# `try fromjson catch null` で個別 parse する。
qa_detect_rate_limit() {
  jq -R -r '
    # 入力 1 行を JSON object に折りたたむ。fromjson 失敗 / 非 object は捨てる。
    . as $line
    | (try ($line | fromjson) catch null)
    | select(type == "object") as $j

    # detection_path を 4 経路で識別（先頭で優先度を決定し、最初に match した
    # 経路を採用）。マッチしなければ empty で当該行を捨てる。
    | (
        if ($j.type? == "rate_limit_event")
           and (($j.rate_limit_info? // {}).status? == "rejected") then
          { path: "rate_limit_event_v2", message: null }
        elif ($j.type? == "rate_limit_event")
             and ($j.status? == "exceeded") then
          { path: "rate_limit_event_v1", message: null }
        elif ($j.type? == "result")
             and ($j.is_error? == true)
             and ($j.api_error_status? == 429) then
          { path: "synthetic_429_result", message: null }
        else
          (
            [
              ($j.message? // empty),
              ($j.error? // {} | .message? // empty),
              ($j.item? // {} | .message? // empty)
            ]
            | map(select(type == "string"))
            | map(select(test("usage limit|purchase more credits|try again at|out of credits|spend cap"; "i")))
            | .[-1] // null
          ) as $msg
          | if $msg != null then
              { path: "usage_limit_fatal", message: $msg }
            else
              empty
            end
        end
      ) as $det

    # reset epoch 候補値: 現行スキーマ ネスト → 旧スキーマ top-level の順で探索。
    # 値が無ければ null を bind（empty を bind すると jq 仕様により当該行が消える）。
    | (
        ($j.rate_limit_info? // {})
        | (.resetsAt // .resets_at // .reset_at // null)
      ) as $nested
    | (
        $j
        | (.resetsAt // .reset_at // .resets_at // null)
      ) as $top
    | (if $nested != null then $nested else $top end) as $raw

    # epoch 化: number はそのまま floor、string は ISO 8601 → epoch、それ以外は空。
    | (
        if $raw == null then ""
        elif ($raw | type) == "number" then ($raw | floor | tostring)
        elif ($raw | type) == "string" then
          (try ($raw | fromdateiso8601 | tostring)
            catch (try ($raw | tonumber | floor | tostring) catch ""))
        else "" end
      ) as $epoch_str

    # 出力: <detection_path>\t<epoch_or_empty>[ \t<message>]
    | if $det.path == "usage_limit_fatal" then
        "\($det.path)\t\($epoch_str)\t\($det.message | gsub("[\t\r\n]"; " "))"
      else
        "\($det.path)\t\($epoch_str)"
      end
  ' 2>/dev/null
}

# usage-limit 風 fatal message から reset epoch を抽出する。
# Codex CLI の観測文言は timezone を含まないため、PR Iteration 側の既存実装と同じく
# watcher 実行環境の local timezone で解釈する。絶対日付付き
# `try again at Jun 9th, 2026 1:16 AM.` と、同日内の時刻だけを返す
# `try again at 11:26 AM.` の両方を受理する。時刻だけの値が現在時刻以前なら翌日の
# reset とみなす。抽出不能時は空文字を返す。`try again at` の reset hint があるのに
# epoch 化できない場合は qa_run_codex_stage 側で保守的 fallback reset を使う。
# codex-cli 0.144 系は plan によって文頭大文字の ` Try again at ...` を出す
# （retry_suffix / #170）ため、sed は `[Tt]ry again at` で両方を受理する。
qa_extract_usage_limit_reset_epoch() {
  local message="${1:-}"
  if [ -z "$message" ]; then
    echo ""
    return 0
  fi

  local raw raw_kind
  raw=$(printf '%s\n' "$message" \
    | sed -nE 's/.*[Tt]ry again at ([A-Z][a-z]{2,8} [0-9]{1,2}(st|nd|rd|th)?, [0-9]{4} [0-9]{1,2}:[0-9]{2} (AM|PM)).*/\1/p' \
    | tail -1)
  raw_kind="absolute"
  if [ -z "$raw" ]; then
    raw=$(printf '%s\n' "$message" \
      | sed -nE 's/.*[Tt]ry again at ([0-9]{1,2}:[0-9]{2} (AM|PM)).*/\1/p' \
      | tail -1)
    raw_kind="time-only"
  fi
  if [ -z "$raw" ]; then
    echo ""
    return 0
  fi

  local normalized epoch=""
  if [ "$raw_kind" = "time-only" ]; then
    normalized="$raw"
    local today now_epoch
    today=$(date '+%Y-%m-%d')
    now_epoch=$(date '+%s')
    if epoch=$(date -d "${today} ${normalized}" '+%s' 2>/dev/null); then
      if [ "$epoch" -le "$now_epoch" ]; then
        epoch=$((epoch + 86400))
      fi
      echo "$epoch"
      return 0
    fi
    if epoch=$(date -j -f '%Y-%m-%d %I:%M %p' "${today} ${normalized}" '+%s' 2>/dev/null); then
      if [ "$epoch" -le "$now_epoch" ]; then
        epoch=$((epoch + 86400))
      fi
      echo "$epoch"
      return 0
    fi
    echo ""
    return 0
  fi

  normalized=$(printf '%s\n' "$raw" | sed -E 's/([0-9]+)(st|nd|rd|th)/\1/g')
  if epoch=$(date -d "$normalized" '+%s' 2>/dev/null); then
    echo "$epoch"
    return 0
  fi
  if epoch=$(date -j -f '%b %e, %Y %I:%M %p' "$normalized" '+%s' 2>/dev/null); then
    echo "$epoch"
    return 0
  fi
  if epoch=$(date -j -f '%B %e, %Y %I:%M %p' "$normalized" '+%s' 2>/dev/null); then
    echo "$epoch"
    return 0
  fi
  echo ""
  return 0
}

qa_usage_limit_has_reset_hint() {
  local message="${1:-}"
  printf '%s\n' "$message" | grep -Eiq 'try again at[[:space:]]+'
}

qa_usage_limit_fallback_reset_epoch() {
  local message="${1:-}"
  if ! qa_usage_limit_has_reset_hint "$message"; then
    echo ""
    return 0
  fi

  local wait_sec="${QUOTA_USAGE_LIMIT_FALLBACK_WAIT_SEC:-18000}"
  if ! [[ "$wait_sec" =~ ^[0-9]+$ ]] || [ "$wait_sec" -le 0 ]; then
    wait_sec="18000"
  fi

  echo "$(($(date '+%s') + wait_sec))"
}

qa_sanitize_summary_token() {
  printf '%s' "${1:-unknown}" | tr -c 'A-Za-z0-9_.=+/-' '_'
}

qa_infer_collab_agent_role() {
  local stage_label="${1:-}"
  local line="${2:-}"
  local lower
  lower=$(printf '%s %s' "$stage_label" "$line" | tr '[:upper:]' '[:lower:]')

  case "$lower" in
    *product-manager*|*"product manager"*|*" role pm "*|*" agent pm "*)
      printf '%s\n' "ProductManager"
      ;;
    *project-manager*|*"project manager"*|*pjm*|*stagec*)
      printf '%s\n' "ProjectManager"
      ;;
    *reviewer*|*pertask-rev*|*per-task-rev*)
      printf '%s\n' "Reviewer"
      ;;
    *developer*|*implementer*|*pertask-impl*|*per-task-impl*|*stagea-prime*|*stagea-redo*)
      printf '%s\n' "Developer"
      ;;
    *architect*)
      printf '%s\n' "Architect"
      ;;
    *debugger*)
      printf '%s\n' "Debugger"
      ;;
    *triage*)
      printf '%s\n' "Triage"
      ;;
    *stagea*)
      printf '%s\n' "StageA-PM-Developer"
      ;;
    *)
      printf '%s\n' "unknown"
      ;;
  esac
}

qa_collab_mark_seen() {
  local key="$1"
  QA_COLLAB_SPAWN_SEEN_KEYS="${QA_COLLAB_SPAWN_SEEN_KEYS:-}"
  case "|${QA_COLLAB_SPAWN_SEEN_KEYS}|" in
    *"|${key}|"*) return 1 ;;
    *)
      if [ -z "$QA_COLLAB_SPAWN_SEEN_KEYS" ]; then
        QA_COLLAB_SPAWN_SEEN_KEYS="$key"
      else
        QA_COLLAB_SPAWN_SEEN_KEYS="${QA_COLLAB_SPAWN_SEEN_KEYS}|${key}"
      fi
      return 0
      ;;
  esac
}

qa_collab_set_repeated_flag() {
  QA_COLLAB_SPAWN_TOTAL_COUNT="${QA_COLLAB_SPAWN_TOTAL_COUNT:-0}"
  if [ "$QA_COLLAB_SPAWN_TOTAL_COUNT" -gt 0 ]; then
    QA_COLLAB_REPEATED_FLAG="yes"
  else
    QA_COLLAB_REPEATED_FLAG="no"
  fi
  QA_COLLAB_SPAWN_TOTAL_COUNT=$((QA_COLLAB_SPAWN_TOTAL_COUNT + 1))
}

# Codex CLI / collab router 由来の `collab spawn failed: no thread with id` を検出し、
# Issue log と run-summary の双方へ operator-observable な degraded event を残す。
#
# Args:
#   $1 = stage label
#   $2 = stream log file（当該 codex attempt の stdout/stderr tee 先）
#   $3 = codex rc
#   $4 = attempt number
#   $5 = max attempts
#   $6 = fallback status（retry-scheduled / degraded-success / failed）
# Side effects:
#   QA_COLLAB_LAST_COUNT / QA_COLLAB_LAST_ROLES を更新
qa_detect_collab_spawn_failures() {
  local stage_label="$1"
  local stream_file="$2"
  local codex_rc="$3"
  local attempt="$4"
  local max_attempts="$5"
  local fallback_status="$6"

  QA_COLLAB_LAST_COUNT=0
  QA_COLLAB_LAST_ROLES=""

  [ -r "$stream_file" ] || return 0

  local match line_no line role role_token stage_token repeated key fallback degraded
  while IFS= read -r match; do
    [ -n "$match" ] || continue
    line_no="${match%%:*}"
    line="${match#*:}"
    role=$(qa_infer_collab_agent_role "$stage_label" "$line")
    role_token=$(qa_sanitize_summary_token "$role")
    stage_token=$(qa_sanitize_summary_token "$stage_label")
    key="${stage_token}:${role_token}"
    qa_collab_set_repeated_flag
    repeated="${QA_COLLAB_REPEATED_FLAG:-no}"
    qa_collab_mark_seen "$key" || true

    fallback="no"
    case "$fallback_status" in
      retry-scheduled) fallback="retry" ;;
      degraded-success) fallback="yes" ;;
      failed) fallback="failed" ;;
    esac
    degraded="yes"

    QA_COLLAB_LAST_COUNT=$((QA_COLLAB_LAST_COUNT + 1))
    case ",${QA_COLLAB_LAST_ROLES}," in
      *",${role_token},"*) : ;;
      *)
        if [ -z "$QA_COLLAB_LAST_ROLES" ]; then
          QA_COLLAB_LAST_ROLES="$role_token"
        else
          QA_COLLAB_LAST_ROLES="${QA_COLLAB_LAST_ROLES},${role_token}"
        fi
        ;;
    esac

    qa_warn "collab-spawn degraded event stage=${stage_token} role=${role_token} reason=no_thread_with_id fallback=${fallback} degraded=${degraded} repeated=${repeated} attempt=${attempt}/${max_attempts} line=${line_no} upstream=codex-cli-or-collab-router"
    if [ "$repeated" = "yes" ]; then
      qa_warn "collab-spawn repeated warning stage=${stage_token} role=${role_token} reason=no_thread_with_id action=fallback-or-fail"
    fi
    if declare -F rs_record_degraded_event >/dev/null 2>&1; then
      rs_record_degraded_event "collab_spawn_failed" "$stage_token" "$role_token" "no_thread_with_id" "$fallback" "$degraded" "$repeated" || true
    elif declare -F rs_record_error >/dev/null 2>&1; then
      rs_record_error "collab_spawn_failed" || true
    fi
  done < <(grep -Ein 'collab spawn failed:[[:space:]]*no thread with id' "$stream_file" 2>/dev/null || true)

  if [ "$QA_COLLAB_LAST_COUNT" -gt 0 ] && [ "$codex_rc" -eq 0 ]; then
    qa_warn "collab-spawn fallback result=degraded-success stage=$(qa_sanitize_summary_token "$stage_label") roles=${QA_COLLAB_LAST_ROLES:-unknown} reason=no_thread_with_id fallback=codex-cli-continuation degraded=yes"
  elif [ "$QA_COLLAB_LAST_COUNT" -gt 0 ] && [ "$fallback_status" = "failed" ]; then
    qa_warn "collab-spawn fallback result=failed stage=$(qa_sanitize_summary_token "$stage_label") roles=${QA_COLLAB_LAST_ROLES:-unknown} reason=no_thread_with_id fallback=failed degraded=yes codex_rc=${codex_rc}"
  fi
  return 0
}

# session rollout (rollout-*.jsonl) の `token_count.rate_limits` を解析し、quota reached の
# ときだけ binding window の reset epoch を stdout に返す（reached でなければ空 / #79）。
#
# 背景: `codex exec --json` の stdout には rate_limit 情報が一切出ない（thread.started /
# turn.started / item.completed / turn.completed のみ。turn.completed は usage token のみ）。
# rate_limits snapshot は CODEX_HOME/sessions 配下の session rollout に
# `{"type":"event_msg","payload":{"type":"token_count","rate_limits":{...}}}` として出る。
# そのため stdout 解析（qa_detect_rate_limit の rate_limit_event 経路）は実 codex では発火せず、
# rollout 解析が codex における構造化検出の本筋となる（usage_limit_fatal のテキスト検出は別経路で併存）。
#
# rate_limits の実スキーマ（codex-cli 0.139.0 実機 / 0.144.1 実機で互換確認済み #170）:
#   {"primary":{"used_percent":N,"window_minutes":300,"resets_at":<epoch>},
#    "secondary":{"used_percent":N,"window_minutes":10080,"resets_at":<epoch>},
#    "rate_limit_reached_type":null|<str>, "plan_type":..., "credits":...}
#   primary=5h ローリング窓 / secondary=weekly 窓。未到達時 reached_type=null。
#   0.144.1 で `limit_id` / `limit_name` / `individual_limit` が追加されたが、本関数の
#   jq パスは optional accessor のみ参照するため影響なし（追加フィールドは無視される）。
#
# 検出条件: `rate_limit_reached_type != null` もしくは いずれかの window の used_percent>=100。
# reset epoch: used_percent が高い側（binding window）の resets_at を採用する。
#
# Args: $1 = この exec の stdout を保存したファイル（thread.started から thread_id を取得）
# Stdout: reset epoch (integer) if reached, else empty
# Return: 0 always（検出なし / 解析失敗は空出力でフォールバック）
qa_detect_rate_limit_rollout() {
  local exec_out="$1"
  [ -n "${exec_out:-}" ] && [ -f "$exec_out" ] || return 0
  local codex_home="${CODEX_HOME:-$HOME/.codex}"
  [ -d "$codex_home/sessions" ] || return 0

  # この exec の thread_id を stdout の thread.started から取得（rollout 特定キー）。
  local thread_id
  thread_id=$(jq -r 'select(.type? == "thread.started") | .thread_id? // empty' "$exec_out" 2>/dev/null | head -1)
  [ -n "$thread_id" ] || return 0

  # thread_id を含む rollout ファイルを特定（同一 CODEX_HOME に全 repo の rollout が集約される
  # ため thread_id で曖昧性を排除する）。
  local rollout
  rollout=$(find "$codex_home/sessions" -type f -name "rollout-*-${thread_id}.jsonl" 2>/dev/null | head -1)
  [ -n "$rollout" ] && [ -f "$rollout" ] || return 0

  # 最新の rate_limits snapshot を取り、reached のときだけ binding window の resets_at を返す。
  # 1 段目は -c（compact）で各 rate_limits を 1 行に畳む（-r だと object が複数行 pretty 出力に
  # なり tail -1 が壊れる）。tail -1 で最新 snapshot を採用し、2 段目で reached 判定する。
  jq -c '
    select(.type? == "event_msg"
           and (.payload?.type? == "token_count")
           and (.payload?.rate_limits? != null))
    | .payload.rate_limits
  ' "$rollout" 2>/dev/null | tail -1 | jq -r '
    (.primary?.used_percent? // 0) as $pp
    | (.secondary?.used_percent? // 0) as $sp
    | if (.rate_limit_reached_type? != null) or ($pp >= 100) or ($sp >= 100) then
        (if $sp >= $pp then (.secondary?.resets_at? // .primary?.resets_at?)
         else (.primary?.resets_at? // .secondary?.resets_at?) end)
      else empty end
    | numbers | floor | tostring
  ' 2>/dev/null
}

# codex の `--json` stream（turn.completed.usage）を集計し、per-stage token サマリを
# qa_log でログする（#83 観測性 / behavior 影響なし）。idd-claude の token-usage.sh 相当を
# codex の usage スキーマ（input_tokens / cached_input_tokens / output_tokens /
# reasoning_output_tokens）向けに再導入する。複数 turn / retry 分は合算する。
# stream には 2>&1 で stderr も混ざるため、各行を try fromjson で堅牢に parse する。
qa_log_token_usage() {
  local stage_label="$1"
  local stream_file="$2"
  # Issue #176: 第 3 引数はモデル ID（任意）。cost-estimate.sh が読み込まれていれば
  # 推定 USD を `model=... cost_usd=...` として同一行末尾に併記する（未指定 / 未知は unknown）。
  local model="${3:-}"
  [ -n "${stream_file:-}" ] && [ -f "$stream_file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local summary
  summary=$(jq -R -r '
      . as $l
      | (try ($l | fromjson) catch null)
      | select(type == "object")
      | select(.type? == "turn.completed")
      | .usage? // empty
      | [ (.input_tokens? // 0), (.cached_input_tokens? // 0),
          (.output_tokens? // 0), (.reasoning_output_tokens? // 0) ]
      | @tsv
    ' "$stream_file" 2>/dev/null \
    | awk -F '\t' '
        { i += $1; c += $2; o += $3; r += $4; n += 1 }
        END {
          if (n > 0)
            printf "input=%d cached_input=%d output=%d reasoning=%d total=%d turns=%d", i, c, o, r, i + o, n
        }')

  [ -n "$summary" ] || return 0

  # Issue #176: 推定コストの併記（cost-estimate.sh 未ロード時は従来の行そのまま / 後方互換）。
  local cost_suffix=""
  if declare -F ce_stage_cost_suffix >/dev/null 2>&1; then
    local _in=0 _cached=0 _out=0
    if [[ "$summary" =~ input=([0-9]+)\ cached_input=([0-9]+)\ output=([0-9]+) ]]; then
      _in="${BASH_REMATCH[1]}"; _cached="${BASH_REMATCH[2]}"; _out="${BASH_REMATCH[3]}"
    fi
    cost_suffix="$(ce_stage_cost_suffix "$model" "$_in" "$_cached" "$_out")"
  fi
  qa_log "stage tokens label=$stage_label ${summary}${cost_suffix}"
  return 0
}

# 既存 6 stage の codex 呼び出しを横断ラップする Stage Wrapper（Req 1.1, 1.2,
# 2.1, NFR 2.1）。
#
# 引数: <stage_label> <reset_file> -- codex <codex args...>
# Returns:
#   0     : codex 正常終了 + quota 検出なし（既存挙動互換）
#   99    : quota 検出（reset epoch が $reset_file に書かれている）
#   N≠0,99: codex 自体の非ゼロ exit（quota 以外の失敗、既存フロー委譲）
#
# 副作用:
#   - ${LOG}（呼び出し側で設定済み）に stream 出力を追記
#   - $reset_file は空（quota 検出なし）または epoch 1 行
qa_run_codex_stage() {
  local stage_label="$1"
  local reset_file="$2"
  shift 2
  # 引数 separator '--' を skip
  if [ "${1:-}" = "--" ]; then
    shift
  fi
  local model_id=""
  if [ "${1:-}" = "codex_exec_prompt" ]; then
    model_id="${3:-}"
  fi
  mp_clear_last_config_error

  # opt-out: 既存挙動の素通し実行。tee も解析も走らない（Req 1.1, NFR 2.1）。
  if [ "$QUOTA_AWARE_ENABLED" != "true" ]; then
    "$@"
    return $?
  fi

  # opt-in: stream-json を tee で 2 系統に分岐
  #   系統 1: 既存 $LOG への append（観測ログを破壊しない）
  #   系統 2: qa_detect_rate_limit への pipe → 検出 TSV を中間ファイルに書き出し
  : > "$reset_file"
  local detect_file="${reset_file}.detect"
  : > "$detect_file"
  qa_log "stage start label=$stage_label"

  local codex_rc=0 attempt=1 max_attempts=2 retry_after_collab="false"
  local stream_file="${reset_file}.stream"
  : > "$stream_file"
  # Issue #176: wrapped command（codex_exec_prompt <label> <model> <prompt> / 素の codex -m <model>）から
  # モデル ID を抽出し、token サマリの推定コスト算出に渡す（抽出不能なら空 → cost_usd=unknown）。
  local _qa_model=""
  if declare -F ce_model_from_args >/dev/null 2>&1; then
    _qa_model="$(ce_model_from_args "$@")"
  fi

  while [ "$attempt" -le "$max_attempts" ]; do
    : > "$detect_file"
    : > "$stream_file"

    # set -e / pipefail 配下で個別の非 0 exit を握り潰すため、PIPESTATUS を即座に
    # 配列コピーしてから判断する。`|| true` は PIPESTATUS を 0 で上書きしてしまう
    # ため使えない（Issue #104 で発覚 / 既存 Issue #66 実装の latent bug 修正）。
    # set +e/-e で囲って pipefail 起因の即時 exit を一時的に抑止し、
    # PIPESTATUS[0] = codex 本体 exit code を確実に取り出す。
    set +e
    "$@" 2>&1 | tee -a "$LOG" "$stream_file" | qa_detect_rate_limit > "$detect_file"
    local _qa_pipestatus=("${PIPESTATUS[@]}")
    set -e
    codex_rc="${_qa_pipestatus[0]:-0}"

    local _fallback_status="failed"
    if [ "$codex_rc" -eq 0 ]; then
      _fallback_status="degraded-success"
    elif [ "$attempt" -lt "$max_attempts" ]; then
      _fallback_status="retry-scheduled"
    fi
    qa_detect_collab_spawn_failures "$stage_label" "$stream_file" "$codex_rc" "$attempt" "$max_attempts" "$_fallback_status"

    if [ -s "$detect_file" ]; then
      break
    fi

    if [ "${QA_COLLAB_LAST_COUNT:-0}" -gt 0 ] && [ "$codex_rc" -ne 0 ] && [ "$attempt" -lt "$max_attempts" ]; then
      retry_after_collab="true"
      qa_warn "collab-spawn fallback start stage=$(qa_sanitize_summary_token "$stage_label") roles=${QA_COLLAB_LAST_ROLES:-unknown} reason=no_thread_with_id action=bounded-retry next_attempt=$((attempt + 1))/${max_attempts}"
      attempt=$((attempt + 1))
      continue
    fi
    break
  done

  if [ "$retry_after_collab" = "true" ]; then
    if [ "$codex_rc" -eq 0 ]; then
      qa_warn "collab-spawn fallback result=success stage=$(qa_sanitize_summary_token "$stage_label") reason=bounded-retry degraded=yes"
    else
      qa_warn "collab-spawn fallback result=failed stage=$(qa_sanitize_summary_token "$stage_label") reason=bounded-retry degraded=yes codex_rc=${codex_rc}"
    fi
  fi

  # per-stage token テレメトリ（#83 観測性）。codex の turn.completed.usage を集計してログする。
  qa_log_token_usage "$stage_label" "$stream_file" "$_qa_model"

  # 検出 TSV を解釈する。
  # 優先順位:
  #   1) epoch を持つ検出のうち最新行を採用 → exit 99 経路（reset 永続化に必要）
  #   2) 1 が無く epoch なし検出のみある場合 → 既存フロー fallback + warn
  #      （quota 枯渇は事実だが reset 不明では Resume Processor が機能しないため、
  #      codex_rc を透過。Stage C は別途 PR 実在 verify で虚偽成功を防ぐ /
  #      Req 1.4 / Req 3.2 / Issue #66 後方互換）
  #   3) 検出ゼロ → codex_rc 透過
  if [ -s "$detect_file" ]; then
    local _epoch_line _path _epoch
    _epoch_line=$(awk -F '\t' 'NF >= 2 && $2 ~ /^[0-9]+$/ { last = $0 } END { print last }' "$detect_file")
    if [ -n "$_epoch_line" ]; then
      _path="${_epoch_line%%$'\t'*}"
      _epoch="${_epoch_line#*$'\t'}"
      _epoch="${_epoch%%$'\t'*}"
      _epoch=$(printf '%s' "$_epoch" | tr -d '[:space:]')
      printf '%s\n' "$_epoch" > "$reset_file"
      qa_log "stage detected exceeded label=$stage_label path=${_path} reset_epoch=$_epoch"
      mp_clear_last_config_error
      rm -f "$detect_file" "$stream_file"
      return 99
    fi

    # Codex CLI の usage-limit fatal は stream-json の通常 error message として出ることがある。
    # reset 時刻を抽出できる場合は quota wait に分類する。`try again at` の reset hint が
    # あるのに parser が取りこぼした場合は、Codex 側の表現揺れとして保守的 fallback reset を
    # 使う。reset hint 自体が無い場合は codex_rc を透過し、Issue #12 Option B を維持する。
    local _usage_line _usage_rest _usage_epoch _usage_message
    _usage_line=$(awk -F '\t' '$1 == "usage_limit_fatal" { last = $0 } END { print last }' "$detect_file")
    if [ -n "$_usage_line" ]; then
      _usage_rest="${_usage_line#*$'\t'}"
      _usage_epoch="${_usage_rest%%$'\t'*}"
      _usage_message="${_usage_rest#*$'\t'}"
      if ! [[ "$_usage_epoch" =~ ^[0-9]+$ ]]; then
        _usage_epoch=$(qa_extract_usage_limit_reset_epoch "$_usage_message")
      fi
      if ! [[ "$_usage_epoch" =~ ^[0-9]+$ ]]; then
        _usage_epoch=$(qa_usage_limit_fallback_reset_epoch "$_usage_message")
        if [[ "$_usage_epoch" =~ ^[0-9]+$ ]]; then
          qa_warn "stage detected usage-limit reset hint but parser failed label=$stage_label fallback_wait_sec=${QUOTA_USAGE_LIMIT_FALLBACK_WAIT_SEC:-18000} reset_epoch=$_usage_epoch"
        fi
      fi
      if [[ "$_usage_epoch" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$_usage_epoch" > "$reset_file"
        qa_log "stage detected exceeded label=$stage_label path=usage_limit_fatal reset_epoch=$_usage_epoch"
        mp_clear_last_config_error
        rm -f "$detect_file" "$stream_file"
        return 99
      fi
    fi

    # epoch 付き検出ゼロだが、検出経路だけは観測できたケース
    local _last_line
    _last_line=$(tail -1 "$detect_file")
    _path="${_last_line%%$'\t'*}"
    qa_warn "stage detected without reset label=$stage_label path=${_path} (既存フローに委譲 / codex_rc=$codex_rc)"
    : > "$reset_file"
  fi

  # stdout / usage-limit いずれの経路でも reset epoch が得られなかった場合、session rollout の
  # rate_limits snapshot を参照して quota reached を構造的に検出する（#79）。codex の rate_limit は
  # stdout に出ず rollout にのみ出るため、これが codex における第一の rate_limit 検出経路になる。
  # reached でない（=空）ときは副作用なしで codex_rc を透過する（純粋に追加的・後方互換）。
  local _rollout_epoch
  _rollout_epoch=$(qa_detect_rate_limit_rollout "$stream_file")
  if [[ "${_rollout_epoch:-}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$_rollout_epoch" > "$reset_file"
    qa_log "stage detected exceeded label=$stage_label path=rate_limits_rollout reset_epoch=$_rollout_epoch"
    mp_clear_last_config_error
    rm -f "$detect_file" "$stream_file"
    return 99
  fi

  if [ "$codex_rc" -eq "${MP_MODEL_CONFIG_ERROR_RC:-78}" ]; then
    mp_record_config_error "preflight" "$stage_label" "${model_id:-unknown}" "model-preflight-failed" "${LOG:-$stream_file}"
    mp_error "model-config-error stage=$(mp_sanitize_token "$stage_label") model=$(mp_sanitize_token "${model_id:-unknown}") reason=model-preflight-failed artifact=${LOG:-$stream_file}"
  elif [ "$codex_rc" -ne 0 ] && [ -n "$model_id" ]; then
    local _mp_classify_rc=0
    mp_classify_stage_model_error "$stage_label" "$model_id" "$stream_file" || _mp_classify_rc=$?
    if [ "$_mp_classify_rc" -eq 0 ]; then
      # shellcheck disable=SC2034  # mark_issue_failed が model-preflight module の global state として参照する
      MP_LAST_CONFIG_ERROR_ARTIFACT="${LOG:-$stream_file}"
    else
      mp_clear_last_config_error
    fi
  else
    mp_clear_last_config_error
  fi

  rm -f "$detect_file" "$stream_file"
  return "$codex_rc"
}

# reset 予定時刻のローカル永続化ファイル（#169）。
# Issue body の read-modify-write（lost update リスクあり）を廃止し、repo slug 単位で
# 分離済みの $LOG_DIR 配下に Issue 番号 keyed の JSON で永続化する（Req 1.1〜1.4, 2.x）。
# JSON 形状: { "<issue_number>": <reset_epoch_int>, ... }（1 Issue 最新値 1 件 / NFR 4.1）。
# $LOG_DIR は repo ごとに分離されているため、本ファイルに他 repo の値は混在しない（Req 1.4）。
QUOTA_RESET_STATE_FILE="${QUOTA_RESET_STATE_FILE:-$LOG_DIR/quota-reset-times.json}"

# reset 予定時刻をローカルファイルへ Issue 番号 keyed で永続化する（Req 1.1〜1.4, 2.1, 2.3,
# 4.1, 4.2, NFR 4.1）。Issue body への書き込み（gh issue edit --body 相当）は一切行わない
# （Req 1.2, 1.3）。書込はアトミック（temp file → mv）で破損リスクを抑える。
#
# Args: $1 = issue number, $2 = reset epoch (integer)
# Return: 0 = persisted, 1 = failure (warn only, do not fail caller / Req 4.2)
qa_persist_reset_time() {
  local issue_number="$1"
  local epoch="$2"

  # 不正な epoch（数値以外）は永続化しない（malformed 値を書き込まない / NFR 4.1 整合）
  if ! [[ "$epoch" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  # 永続化先ディレクトリを確保（$LOG_DIR は通常起動時に mkdir 済みだが防御的に）
  local state_dir
  state_dir=$(dirname "$QUOTA_RESET_STATE_FILE")
  if ! mkdir -p "$state_dir" 2>/dev/null; then
    return 1
  fi

  # 既存ファイルを基に Issue 番号 key を upsert する。ファイル不在 / 破損時は空 object から
  # 初期化（Req 4.5 の破損耐性は読取側で担保するが、書込時も破損を引きずらない）。
  local base_json="{}"
  if [ -f "$QUOTA_RESET_STATE_FILE" ]; then
    local existing
    if existing=$(jq -e '.' "$QUOTA_RESET_STATE_FILE" 2>/dev/null); then
      base_json="$existing"
    fi
  fi

  # アトミック書込: temp file に出力 → mv で置換（同一 Issue・同一 epoch を複数回実行しても
  # 1 件の最新値に収束 / NFR 4.1）。temp file は secure tempfile helper で owner-only に作る。
  local tmp_file
  if ! tmp_file=$(idd_secure_mktemp "quota-reset-state-${issue_number}"); then
    qa_warn "Issue #${issue_number}: quota reset state secure tempfile の作成に失敗"
    return 1
  fi
  if ! printf '%s' "$base_json" | jq \
      --arg num "$issue_number" \
      --argjson epoch "$epoch" \
      '. + {($num): $epoch}' > "$tmp_file" 2>/dev/null; then
    rm -f "$tmp_file"
    return 1
  fi
  if ! mv -f "$tmp_file" "$QUOTA_RESET_STATE_FILE" 2>/dev/null; then
    rm -f "$tmp_file"
    return 1
  fi
  return 0
}

# Issue 番号に対応する reset epoch を返す（Req 3.1〜3.4, 4.3, 4.4, 4.5）。
# 読取順: 1) ローカルファイル（優先 / Req 3.1, 3.3） 2) Issue body の hidden marker
# `<!-- idd-codex:quota-reset:<epoch>:v1 -->`（移行期フォールバック / Req 3.2, 3.4）。
# 破損ファイル / 不正値 / 双方不在いずれの場合も数値以外を返さず return 1（Req 4.4, 4.5）。
#
# Args: $1 = issue number
# Stdout: epoch (integer) on success, empty on failure
# Return: 0 = found, 1 = absent or malformed (caller must skip removal / Req 4.4)
qa_load_reset_time() {
  local issue_number="$1"

  # 1) ローカルファイル優先（Req 3.1, 3.3）。破損ファイルは jq -e が非 0 で抜け、
  #    フォールバックに進む（Req 4.5: malformed を数値として返さない）。
  if [ -f "$QUOTA_RESET_STATE_FILE" ]; then
    local local_epoch
    local_epoch=$(jq -er --arg num "$issue_number" \
      '.[$num] | select(type == "number") | floor | tostring' \
      "$QUOTA_RESET_STATE_FILE" 2>/dev/null)
    if [[ "$local_epoch" =~ ^[0-9]+$ ]]; then
      printf '%s' "$local_epoch"
      return 0
    fi
  fi

  # 2) フォールバック: Issue body の hidden marker（移行期 / 本変更デプロイ前に
  #    永続化済みの Issue 向け / Req 3.2, 3.4）。
  local body
  if ! body=$(gh issue view "$issue_number" --repo "$REPO" --json body --jq '.body' 2>/dev/null); then
    return 1
  fi
  local epoch
  epoch=$(printf '%s' "$body" \
    | sed -nE 's/.*<!-- idd-codex:quota-reset:([0-9]+):v1 -->.*/\1/p' \
    | tail -1)
  if [[ "$epoch" =~ ^[0-9]+$ ]]; then
    printf '%s' "$epoch"
    return 0
  fi
  return 1
}

# escalation コメント本文を組み立てる（design.md 「Escalation Comment Template」を逐語使用）。
# Args: $1 = stage label, $2 = epoch, $3 = ISO 8601 string
# Stdout: コメント本文（markdown）
qa_build_escalation_comment() {
  local stage_label="$1" epoch="$2" iso8601="$3"
  cat <<EOF
## ⏸️ Codex Max quota exceeded（quota wait）

watcher が \`${stage_label}\` 実行中に Codex CLI から \`rate_limit_event (status=exceeded)\` を検知しました。
当該 Issue を一時的に **\`codex-needs-quota-wait\`** 状態にしています。Codex Max の 5 時間ローリング quota
が reset された後、watcher が自動的に通常 pickup ループへ戻します。

### 検知情報

- 検知 Stage: \`${stage_label}\`
- reset 予定時刻 (UNIX epoch): \`${epoch}\`
- reset 予定時刻 (ISO 8601): \`${iso8601}\`
- 適用 grace 秒数: \`${QUOTA_RESUME_GRACE_SEC}\` 秒（reset 後この秒数を経過するまで pickup を抑止）

### 自動復帰の条件

- 次サイクルの Quota Resume Processor が、現在時刻が \`reset 予定時刻 + grace\` を超えていることを
  検知すると、\`codex-needs-quota-wait\` ラベルを自動除去します
- ラベル除去後の cron tick で Dispatcher が通常 pickup 候補として再選定します
- \`codex-failed\` ラベルは付与していません（quota 起因と他失敗の混同を避けるため、Req 3.2）

### 手動介入したい場合

- 即時再開: \`codex-needs-quota-wait\` ラベルを手動で外すと次サイクルで pickup されます
- quota 起因でないと判断する場合: \`codex-needs-quota-wait\` を \`codex-failed\` に手動付け替えしてください
  （reset 予定時刻は watcher 環境内のローカルファイルに保持されており、Issue body の編集は不要です）

---

_本コメントは Quota-Aware Watcher（Issue #66）が自動投稿しました。_
EOF
}

# ─── build_partial_escalation_comment <status_code> <impl_notes_path> <tasks_md_path> <branch> ───
#
# Partial Status Gate (#148) のエスカレーションコメント本文を組み立てる純粋関数。
# 副作用なし。本関数は stdout に markdown 本文を出力するのみで、`gh issue comment` 呼出は
# 呼出側（handle_partial_status / mark_issue_needs_decisions）の責務。
#
# 入力:
#   $1 = status_code         ("partial_blocked" または "partial_overrun")
#   $2 = impl_notes_path     (Halt 理由抽出元 / impl-notes.md)
#   $3 = tasks_md_path       (残タスク fallback / tasks.md)
#   $4 = branch              (push 済み branch 名)
#
# 出力構造（Req 4.1〜4.5 / NFR 2.2 をすべてカバー）:
#   1. 識別 HTML コメント `<!-- idd-codex:partial-status:STATUS -->`（本文先頭 / NFR 2.2）
#   2. h2 タイトル（status code 別の固定文言）
#   3. ## 検知情報（status / branch / Issue 番号）
#   4. ## Halt 理由 — impl-notes.md `## Partial Halt Reason` セクションを引用
#   5. ## Push 済み commit 一覧 — git log --oneline ${BASE_BRANCH}..HEAD
#   6. ## 残タスク一覧 — impl-notes.md `## Pending Tasks` セクション優先、なければ tasks.md
#      の `- [ ]` 行を fallback 抽出
#   7. ## 推奨アクション — 固定リスト（依存 Issue 先行 / Issue 分割 / 手動続行）
#   8. ## 次の手順 — `codex-needs-decisions` 除去で次サイクル自動 pickup される旨
#   9. footer — 本コメントが #148 由来である旨
#
# Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, NFR 2.2
build_partial_escalation_comment() {
  local status_code="$1"
  local impl_notes_path="$2"
  local tasks_md_path="$3"
  local branch="$4"

  # ── status 別のタイトル ──
  local title
  case "$status_code" in
    partial_blocked)
      title="⏸️ Developer が partial_blocked を報告しました（外部依存で進行不能）"
      ;;
    partial_overrun)
      title="⏸️ Developer が partial_overrun を報告しました（turn budget 残量不足）"
      ;;
    *)
      title="⏸️ Developer が partial 状態を報告しました（${status_code}）"
      ;;
  esac

  # ── Halt 理由抽出（impl-notes.md の `## Partial Halt Reason` セクション本文） ──
  # awk で「## Partial Halt Reason」見出しから次の `## ` 見出しまでを抽出
  # （見出し行自体は含めない / 末尾の空行も保持）。ファイル不在時は空文字。
  local halt_reason=""
  if [ -f "$impl_notes_path" ]; then
    halt_reason=$(awk '
      /^## Partial Halt Reason[[:space:]]*$/ { in_section=1; next }
      in_section && /^## / { exit }
      in_section { print }
    ' "$impl_notes_path" 2>/dev/null || true)
  fi
  if [ -z "$halt_reason" ]; then
    halt_reason="(impl-notes.md に \`## Partial Halt Reason\` セクションが見つかりませんでした)"
  fi

  # ── push 済み commit 一覧（${BASE_BRANCH}..HEAD） ──
  # git log は REPO_DIR で実行する前提（呼出側の `cd` 不要設計のため明示）。失敗時は空文字。
  local commit_list=""
  if [ -n "${REPO_DIR:-}" ] && [ -d "$REPO_DIR/.git" ]; then
    commit_list=$(git -C "$REPO_DIR" log --oneline "${BASE_BRANCH}..HEAD" 2>/dev/null || true)
  fi
  if [ -z "$commit_list" ]; then
    commit_list="(${BASE_BRANCH}..HEAD に commit がありません / または git log 取得に失敗しました)"
  fi

  # ── 残タスク一覧（impl-notes.md `## Pending Tasks` 優先、なければ tasks.md fallback） ──
  local pending=""
  if [ -f "$impl_notes_path" ]; then
    pending=$(awk '
      /^## Pending Tasks[[:space:]]*$/ { in_section=1; next }
      in_section && /^## / { exit }
      in_section { print }
    ' "$impl_notes_path" 2>/dev/null || true)
  fi
  if [ -z "$pending" ] && [ -f "$tasks_md_path" ]; then
    # fallback: tasks.md の `- [ ]` 未完了行を抽出（`- [ ]*` deferrable も含む）
    pending=$(grep -E '^- \[ \]\*? ' "$tasks_md_path" 2>/dev/null || true)
  fi
  if [ -z "$pending" ]; then
    pending="(残タスクが特定できませんでした。\`${SPEC_DIR_REL:-docs/specs/<N>-<slug>}/tasks.md\` を直接確認してください)"
  fi

  # ── 本文組立（heredoc） ──
  cat <<EOF
<!-- idd-codex:partial-status:${status_code} -->

## ${title}

watcher が Stage A 完了直後の Partial Status Gate (#148) で Developer の自己宣言を検出しました。
当該 Issue は \`codex-needs-decisions\` 状態に切り替わり、人間判断（依存解消 / Issue 分割 / 手動続行）を
仰ぐフローに入ります。Reviewer は **起動されません**。

### 検知情報

- 報告された status code: \`${status_code}\`
- 対象 branch: \`${branch}\`
- 対象 Issue: #${NUMBER:-(unknown)}

## Halt 理由

${halt_reason}

## Push 済み commit 一覧

\`\`\`
${commit_list}
\`\`\`

## 残タスク一覧

\`\`\`
${pending}
\`\`\`

## 推奨アクション

partial の種別に応じて以下のいずれかを選択してください:

- **依存 Issue を先に進める**: \`partial_blocked\` で halt 理由が「未 merge の依存 Issue」の
  場合は、当該 Issue を先に解決後、本 Issue の \`codex-needs-decisions\` を除去して再 pickup させる
- **Issue を分割する**: 残タスクが本 Issue の本来 scope を超えていると判断した場合、サブ Issue
  を起票して残タスクを移送し、本 Issue は close または scope を縮小して continue
- **手動で続行する**: \`partial_overrun\` で turn budget 不足だった場合、当該 branch を手動
  checkout して残タスクを実装し、commit + push 後に \`codex-needs-decisions\` を除去する

## 次の手順

人間判断で対処方針を決めた後、Issue から \`codex-needs-decisions\` ラベルを除去してください。
次の watcher サイクルで本 Issue は通常 pickup 候補として再評価され、自動進行が再開されます。

---

_本コメントは Partial Status Gate (#148) が自動投稿しました。_
EOF
}

# quota 検知時の副作用（永続化 → ラベル付け替え → escalation コメント → ログ）を
# 1 関数で原子的に実行する（Req 3.1, 3.2, 3.3, 3.4, 3.7, 4.1, NFR 1.1, 1.2）。
# `codex-failed` は **付与しない**（Req 3.2）。
#
# Args: $1 = issue number, $2 = stage label, $3 = reset epoch
# Return: 0 always（副作用失敗は warn でログ、呼び出し側はラベル付与済み前提で続行）
qa_handle_quota_exceeded() {
  local issue_number="$1" stage_label="$2" epoch="$3"
  local iso8601
  iso8601=$(qa_format_iso8601 "$epoch")

  # 1. 永続化（失敗してもラベル付与に進む。次 tick で再判定可能）
  #    NFR 2.1, 2.2: 成功 / 失敗を Issue 番号 + reset epoch 付きで $LOG_DIR ログに残し、
  #    grep による事後検索を可能にする。
  if qa_persist_reset_time "$issue_number" "$epoch"; then
    qa_log "reset persisted issue=#$issue_number stage=$stage_label reset_epoch=$epoch file=$QUOTA_RESET_STATE_FILE"
  else
    qa_warn "issue=$issue_number stage=$stage_label reset_epoch=$epoch reset 永続化に失敗（ラベル付与は継続）"
  fi

  # 2. ラベル付け替え（codex-claimed / codex-picked-up を除去 → codex-needs-quota-wait 付与。
  #    codex-failed は付与しない / Req 3.2）
  if ! gh issue edit "$issue_number" --repo "$REPO" \
      --remove-label "$LABEL_CLAIMED" \
      --remove-label "$LABEL_PICKED" \
      --add-label "$LABEL_NEEDS_QUOTA_WAIT" >/dev/null 2>&1; then
    qa_warn "issue=$issue_number stage=$stage_label ラベル付け替えに失敗"
  fi

  # 3. escalation コメント
  local comment_body
  comment_body=$(qa_build_escalation_comment "$stage_label" "$epoch" "$iso8601")
  if ! gh issue comment "$issue_number" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1; then
    qa_warn "issue=$issue_number stage=$stage_label escalation コメント投稿に失敗"
  fi

  # 4. ログ（NFR 1.1, 1.2 / grep 可能形式）
  qa_log "exceeded issue=#$issue_number stage=$stage_label reset_epoch=$epoch reset_iso=$iso8601 grace_sec=$QUOTA_RESUME_GRACE_SEC"
  return 0
}

# Quota Resume Processor: cron tick 冒頭で `codex-needs-quota-wait` 付き Issue を走査し、
# reset+grace 経過分のラベルを自動除去する（Req 5.1〜5.6, NFR 3.1〜3.3）。
#
# - opt-out 時は即時 return 0（NFR 2.1）
# - 0 件時は API 1 回で return 0（NFR 3.1）
# - 各 Issue で reset 取得失敗 / 不正値はラベル維持（Req 4.4）
# - API 失敗は warn 吸収して return 0 を保証（Req 5.6）
process_quota_resume() {
  if [ "$QUOTA_AWARE_ENABLED" != "true" ]; then
    return 0
  fi
  qa_log "Resume Processor 開始 (grace=${QUOTA_RESUME_GRACE_SEC}s)"

  local issues_json
  if ! issues_json=$(gh issue list --repo "$REPO" \
        --label "$LABEL_NEEDS_QUOTA_WAIT" --state open \
        --json number --limit 50 2>/dev/null); then
    qa_warn "codex-needs-quota-wait Issue 取得に失敗（後続 Processor 継続）"
    return 0
  fi

  local count
  count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null || echo 0)
  if [ "$count" -eq 0 ]; then
    qa_log "対象 Issue なし"
    return 0
  fi

  local now_epoch
  now_epoch=$(date -u +%s)

  local issue_number reset_epoch threshold
  while IFS= read -r issue_number; do
    [ -z "$issue_number" ] && continue
    if ! reset_epoch=$(qa_load_reset_time "$issue_number"); then
      qa_warn "issue=$issue_number reset 時刻読み出し失敗 → ラベル維持（Req 4.4）"
      continue
    fi
    threshold=$((reset_epoch + QUOTA_RESUME_GRACE_SEC))
    if [ "$now_epoch" -lt "$threshold" ]; then
      qa_log "issue=#$issue_number waiting reset_epoch=$reset_epoch now=$now_epoch wait_sec=$((threshold - now_epoch))"
      continue
    fi
    if gh issue edit "$issue_number" --repo "$REPO" \
        --remove-label "$LABEL_NEEDS_QUOTA_WAIT" >/dev/null 2>&1; then
      qa_log "resumed issue=#$issue_number reset_epoch=$reset_epoch reset_iso=$(qa_format_iso8601 "$reset_epoch") elapsed_sec=$((now_epoch - reset_epoch))"
    else
      qa_warn "issue=$issue_number ラベル除去に失敗（次サイクルで再評価）"
    fi
  done < <(printf '%s' "$issues_json" | jq -r '.[].number')

  return 0
}
