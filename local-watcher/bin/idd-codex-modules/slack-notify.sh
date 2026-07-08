#!/usr/bin/env bash
# slack-notify.sh — 介入要求 + （opt-in の）主要進捗イベントの Slack 外部通知モジュール
#   (#105 / D-18、進捗イベント: #135)
#
# 用途:
#   完全自動化（full-auto）下で「人間の介入が必要になった瞬間」を Slack incoming webhook
#   へ能動的に push する。run-summary（per-run の機械可読ログ）を補完し、**介入要求イベント
#   を既定で**通知してノイズを抑える。通知対象（最小 / 常時 ON 系）:
#     - failed-recovery の budget 超過 / no-progress 終端（`codex-failed` 据え置き / #101）
#     - needs-decisions 据え置き（human-only 等の人間判断待ち / #102 / Triage 経路）
#     - blocked 依存の cycle 検出（デッドロック / #104）
#
#   加えて、`SLACK_NOTIFY_PROGRESS_EVENTS` を明示 `=true` にした場合のみ、**主要進捗
#   イベント**（例: impl 着手 = `codex-picked-up` 遷移 / #135）も通知対象に含める
#   per-event トグル方式（既定 `false` = 進捗イベントは通知しない＝導入前と等価）。
#   進捗イベントは介入要求イベントより発生頻度が高くノイズになりやすいため、独立した
#   opt-in ゲートとして分離している（介入要求イベントの憲章・既定挙動には影響しない）。
#
#   完全自動化 kill switch `FULL_AUTO_ENABLED`（#97）と `SLACK_NOTIFY_ENABLED` の **AND 二重
#   opt-in**、かつ `SLACK_WEBHOOK_URL` が設定されている場合のみ通知する（介入要求 / 進捗
#   両系統に共通の gate）。いずれか欠ける場合（既定）は外部副作用ゼロの no-op（run-summary
#   + ログのみ＝導入前と等価）。進捗イベントはこれに加えて `SLACK_NOTIFY_PROGRESS_EVENTS=true`
#   が必須（三重 AND）。
#
#   **秘匿情報の扱い（必須 / #80・#91 系 redaction 方針）**: `SLACK_WEBHOOK_URL` は秘匿情報
#   として扱い、ログ・Issue/PR コメント・エラーメッセージに**一切出力しない**。curl への
#   引数としてのみ使用する。payload に含めるのは GitHub の公開 URL のみ。
#
#   通知失敗（webhook 4xx/5xx / network / timeout）でもパイプライン本体は継続する
#   （silent fail にせず WARN ログを残す。ただし URL は出さない）。
#
#   ロガー（sn_log / sn_warn / sn_error）は core_utils.sh にあるため再定義しない。
#   関連: README オプション機能一覧 / Issue #105 / Issue #135。
#
# 依存グローバル: REPO, SLACK_NOTIFY_ENABLED, SLACK_WEBHOOK_URL, SLACK_NOTIFY_TIMEOUT,
#   SLACK_NOTIFY_PROGRESS_EVENTS, full_auto_enabled()(#97)。外部 CLI: curl / jq。

# ─────────────────────────────────────────────────────────────────────────────
# sn_notify_enabled: Slack 通知が有効かを判定する（副作用なし）
#   戻り値: 0 = SLACK_NOTIFY_ENABLED=true かつ full_auto_enabled かつ URL 設定あり
#           1 = それ以外（no-op）
#   URL 未設定は「無効」として安全に扱う（誤って空 URL に POST しない）。
# ─────────────────────────────────────────────────────────────────────────────
sn_notify_enabled() {
  [ "${SLACK_NOTIFY_ENABLED:-false}" = "true" ] || return 1
  full_auto_enabled || return 1
  [ -n "${SLACK_WEBHOOK_URL:-}" ] || return 1
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# sn_github_url: kind/number から GitHub の Issue/PR URL を組み立てる（純粋関数）
#   入力: $1=kind（issue|pr） $2=number
#   出力: stdout に https://github.com/<REPO>/(issues|pull)/<number>
# ─────────────────────────────────────────────────────────────────────────────
sn_github_url() {
  local kind="$1" number="$2"
  local seg="issues"
  [ "$kind" = "pr" ] && seg="pull"
  printf 'https://github.com/%s/%s/%s' "${REPO:-unknown/unknown}" "$seg" "$number"
}

# ─────────────────────────────────────────────────────────────────────────────
# sn_build_payload: Slack incoming-webhook の JSON payload を組み立てる（純粋関数）
#   入力: $1=event $2=kind $3=number $4=title $5=url $6=category（省略時 "介入要求"）
#   出力: stdout に `{"text": "..."}` の 1 行 JSON（jq で安全に escape）
#   戻り値: 0=成功 / 1=jq 失敗（呼び出し側で no-op 継続）
#   秘匿情報（webhook URL）は payload に含めない（GitHub 公開 URL のみ）。
#   $6 は既存の介入要求系呼び出し（5 引数）との後方互換のため既定 "介入要求"。
#   進捗イベント（#135）は "進捗" を明示的に渡す。
# ─────────────────────────────────────────────────────────────────────────────
sn_build_payload() {
  local event="$1" kind="$2" number="$3" title="$4" url="$5" category="${6:-介入要求}"
  jq -nc \
    --arg e "$event" --arg k "$kind" --arg n "$number" \
    --arg t "$title" --arg u "$url" --arg r "${REPO:-unknown/unknown}" --arg c "$category" \
    '{text: (":rotating_light: *idd-codex " + $c + "* `" + $e + "` — <" + $u + "|" + $k + " #" + $n + ">: " + $t + " (" + $r + ")")}' \
    2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# sn_post: payload を webhook へ POST する（URL はログに出さない）
#   入力: $1=payload（JSON 文字列）
#   戻り値: curl の終了コード（0=成功）
#   curl の stdout/stderr は捨てる（応答にトークン断片が含まれ得るため）。
# ─────────────────────────────────────────────────────────────────────────────
sn_post() {
  local payload="$1"
  curl -sS -m "${SLACK_NOTIFY_TIMEOUT:-10}" -X POST \
    -H 'Content-Type: application/json' \
    --data-binary "$payload" \
    "$SLACK_WEBHOOK_URL" >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# sn_notify_intervention: 介入要求イベントを Slack へ 1 通通知する（hook 入口）
#   入力: $1=event（分類タグ） $2=kind（issue|pr） $3=number $4=title（要点・1 行）
#   戻り値: 0 固定（gate OFF / 失敗でも本体パイプラインを阻害しない）
#   各介入終端（fr_terminate / dr_escalate_cycle / Triage needs-decisions）から呼ばれる。
#   gate OFF（既定）では即 return 0 の no-op。
# ─────────────────────────────────────────────────────────────────────────────
sn_notify_intervention() {
  local event="$1" kind="$2" number="$3" title="$4"

  sn_notify_enabled || return 0

  local payload
  if ! payload=$(sn_build_payload "$event" "$kind" "$number" "$title" "$(sn_github_url "$kind" "$number")"); then
    sn_warn "Slack payload 構築に失敗 event=${event} ref=#${number}（本体は継続）"
    return 0
  fi

  if sn_post "$payload"; then
    sn_log "notified event=${event} ref=#${number}"
  else
    # webhook URL は WARN に出さない（秘匿情報 / #80・#91 系 redaction）。
    sn_warn "Slack 通知に失敗 event=${event} ref=#${number}（本体は継続 / webhook URL は非出力）"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# sn_progress_notify_enabled: 主要進捗イベント通知が有効かを判定する（副作用なし / #135）
#   戻り値: 0 = sn_notify_enabled（三重 gate）に加え SLACK_NOTIFY_PROGRESS_EVENTS=true
#           1 = それ以外（no-op）
#   per-event トグル方式（設計判断 (b)）: 介入要求 gate を満たさない限り評価しない
#   （SLACK_NOTIFY_ENABLED / FULL_AUTO_ENABLED / SLACK_WEBHOOK_URL を継承した上での
#   追加 opt-in）。未設定 / typo / `false` はすべて無効（進捗イベント通知しない＝導入前
#   と等価）。
# ─────────────────────────────────────────────────────────────────────────────
sn_progress_notify_enabled() {
  sn_notify_enabled || return 1
  [ "${SLACK_NOTIFY_PROGRESS_EVENTS:-false}" = "true" ] || return 1
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# sn_notify_pickup: impl 着手（`codex-picked-up` 遷移）を Slack へ 1 通通知する（hook 入口 / #135）
#   入力: $1=kind（issue|pr） $2=number $3=mode（impl|impl-resume 等）
#   戻り値: 0 固定（gate OFF / 失敗でも本体パイプラインを阻害しない）
#   watcher が `LABEL_PICKED`（codex-picked-up）付与に成功した直後（1 遷移 = 1 通）から
#   呼ばれる。gate OFF（既定。`SLACK_NOTIFY_PROGRESS_EVENTS` 未設定含む）では即 return 0
#   の no-op。
# ─────────────────────────────────────────────────────────────────────────────
sn_notify_pickup() {
  local kind="$1" number="$2" mode="$3"
  local event="codex-pickup"

  sn_progress_notify_enabled || return 0

  local title="impl 着手（mode=${mode}）"
  local payload
  if ! payload=$(sn_build_payload "$event" "$kind" "$number" "$title" "$(sn_github_url "$kind" "$number")" "進捗"); then
    sn_warn "Slack payload 構築に失敗 event=${event} ref=#${number}（本体は継続）"
    return 0
  fi

  if sn_post "$payload"; then
    sn_log "notified event=${event} ref=#${number}"
  else
    # webhook URL は WARN に出さない（秘匿情報 / #80・#91 系 redaction）。
    sn_warn "Slack 通知に失敗 event=${event} ref=#${number}（本体は継続 / webhook URL は非出力）"
  fi
  return 0
}
