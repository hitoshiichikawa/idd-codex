#!/usr/bin/env bash
# needs-decisions-auto.sh — `codex-needs-decisions` の自動続行プロセッサ (#102 / D-08・D-09)
#
# 用途:
#   Triage（PM）が `codex-needs-decisions` と判定した Issue について、**安全な曖昧さ**
#   （Triage JSON の `decisions[].classification == "safe"`）に限り PM の第一推奨で自動続行する。
#   先行資産 #90（per-task NEEDS_DECISION ルート）が分類した `codex-needs-decisions` の上に、
#   自動続行レイヤを薄く重ねる。本体 Triage ルート（codex-needs-decisions 起票直前）に
#   `nda_evaluate_auto_continue` を thin guard として差し込む形で統合する。
#
#   **モード切替**（`NEEDS_DECISIONS_MODE`）:
#     - `all-human`（既定）: 全件 人間据え置き（本機能導入前と完全等価）
#     - `classified`: `safe` → PM 第一推奨で自動続行 / `human-only` → 人間据え置き
#     - `all-auto`: `safe` のみ自動続行（**`human-only` は all-auto でも自動続行しない**）
#     - 不正値 / 未設定 → `all-human`（安全側 / 本体 Config で正規化）
#
#   **安全境界（最重要 / D-09）**: 機密・コンプラ・不可逆・外部影響は `human-only` 分類とし、
#   **どのモードでも自動続行しない**。分類が `safe` 以外 / 欠落 / 混在 / 破損 / 取得失敗は
#   すべて `human-only` に畳む（fail-safe）。Triage prompt 側でも「確信が持てなければ
#   human-only」を強制する。
#
#   **無限続行ガード（codex 固有 / Issue 05 budget と整合）**: 同一 Issue を自動続行した
#   回数を audit コメントの hidden marker 数で数え、`NEEDS_DECISIONS_AUTO_MAX`（既定 4）に
#   達したら自動続行せず人間据え置きへフォールバック（failed-recovery の通算 budget と同じ
#   単一カウンタ思想。Reviewer 2/2・pr-iteration 3R と掛け算しない）。
#
#   完全自動化 kill switch `FULL_AUTO_ENABLED`（#97）と `NEEDS_DECISIONS_MODE`（classified
#   または all-auto）の **AND 二重 opt-in** で動き、いずれか不成立では guard が halt(rc 1)
#   を返し、本体は従来どおり `codex-needs-decisions` 付与 + コメント投稿に流れる（導入前と等価）。
#
#   ロガー（nda_log / nda_warn / nda_error）は core_utils.sh にあるため再定義しない。
#   関連: README オプション機能一覧 / Issue #102。
#
# 依存グローバル: REPO, NUMBER, LABEL_CLAIMED, NEEDS_DECISIONS_MODE,
#   NEEDS_DECISIONS_AUTO_MAX, NEEDS_DECISIONS_GIT_TIMEOUT, full_auto_enabled()(#97)
#
# audit コメントに埋め込む hidden marker。同一 Issue の自動続行回数カウント（budget）と
# 既処理判定に用いる。
NDA_COMMENT_MARKER="idd-codex:needs-decisions-auto"

# ─────────────────────────────────────────────────────────────────────────────
# nda_resolve_mode_enabled: NEEDS_DECISIONS_MODE が自動続行を評価しうるモードかを判定
#   戻り値: 0 = classified / all-auto（評価する）/ 1 = それ以外（all-human 相当・据え置き）
#   副作用: なし（純粋関数）
# ─────────────────────────────────────────────────────────────────────────────
nda_resolve_mode_enabled() {
  case "${NEEDS_DECISIONS_MODE:-all-human}" in
    classified|all-auto) return 0 ;;
    *) return 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# nda_extract_classification: Triage JSON の分類タグを fail-safe に畳んで返す
#   入力: $1 = triage_json_path
#   出力: stdout に "safe" または "human-only"
#   全 decision が **厳密に "safe"** のときのみ "safe"。それ以外（human-only を含む /
#   欠落 / null / 不明値 / 混在 / 空配列 / 非配列 / jq 失敗 / ファイル無し）は "human-only"。
# ─────────────────────────────────────────────────────────────────────────────
nda_extract_classification() {
  local path="$1"
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    printf 'human-only'
    return 0
  fi
  local result
  result=$(jq -r '
    .decisions
    | if (. == null or (type != "array") or length == 0) then
        "human-only"
      else
        (map(.classification // "")) as $tags
        | if ($tags | any(. == "human-only")) then "human-only"
          elif ($tags | all(. == "safe")) then "safe"
          else "human-only" end
      end
  ' "$path" 2>/dev/null)
  case "$result" in
    safe) printf 'safe' ;;
    *) printf 'human-only' ;;
  esac
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# nda_extract_first_recommendation: Triage JSON の第一推奨を取り出す
#   入力: $1 = triage_json_path
#   出力: stdout に decisions[0].recommendation（成功時）
#   戻り値: 0 = 取得成功 / 1 = null / 空 / "null" / 欠落 / ファイル無し（halt させる）
# ─────────────────────────────────────────────────────────────────────────────
nda_extract_first_recommendation() {
  local path="$1"
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    return 1
  fi
  local rec
  rec=$(jq -r '.decisions[0].recommendation // ""' "$path" 2>/dev/null)
  if [ -z "$rec" ] || [ "$rec" = "null" ]; then
    return 1
  fi
  printf '%s' "$rec"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# nda_count_prior_auto_continues: 同一 Issue の過去自動続行回数を marker から数える
#   入力: $1 = issue_number
#   出力: stdout に整数（取得失敗時は NEEDS_DECISIONS_AUTO_MAX を返し budget 枯渇へ倒す）
#   gh 失敗 → 「数えられない」ため安全側（自動続行しない）に倒す。
# ─────────────────────────────────────────────────────────────────────────────
nda_count_prior_auto_continues() {
  local issue_number="$1"
  local comments_json
  if ! comments_json=$(timeout "$NEEDS_DECISIONS_GIT_TIMEOUT" gh issue view "$issue_number" \
      --repo "$REPO" --json comments 2>/dev/null); then
    nda_warn "issue=#${issue_number}: 過去コメント取得に失敗（budget 枯渇扱い＝自動続行しない）"
    printf '%s' "$NEEDS_DECISIONS_AUTO_MAX"
    return 0
  fi
  local count
  count=$(printf '%s' "$comments_json" | jq -r --arg m "$NDA_COMMENT_MARKER" --arg n "$issue_number" '
    [ (.comments // [])[] | select((.body // "") | contains($m + " issue=" + $n)) ] | length
  ' 2>/dev/null || echo "")
  if ! [[ "$count" =~ ^[0-9]+$ ]]; then
    count=0
  fi
  printf '%s' "$count"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# nda_budget_available: 無限続行ガード（同一 Issue の自動続行回数が budget 内か）
#   入力: $1 = issue_number
#   戻り値: 0 = まだ自動続行可（prior < MAX）/ 1 = budget 枯渇（halt → 人間据え置き）
# ─────────────────────────────────────────────────────────────────────────────
nda_budget_available() {
  local issue_number="$1"
  local prior
  prior=$(nda_count_prior_auto_continues "$issue_number")
  [[ "$prior" =~ ^[0-9]+$ ]] || prior="$NEEDS_DECISIONS_AUTO_MAX"
  [ "$prior" -lt "$NEEDS_DECISIONS_AUTO_MAX" ] || return 1
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# nda_auto_continue: 自動続行の実行（audit コメント投稿 → claim ラベル除去）
#   入力: $1=triage_json_path $2=recommendation
#   戻り値: 0 = 自動続行成功（再 pickup 待機）/ 1 = 失敗（halt → 既存据え置き経路へ）
#   - audit コメントを **先に** 投稿し（marker + 採用推奨 + 解除条件を記録）、
#     **成功した場合のみ** `LABEL_CLAIMED` を除去する（audit 無き再 pickup を防ぐ）。
#   - `codex-needs-decisions` は付与しない（付与すると dispatcher が再 pickup しない）。
# ─────────────────────────────────────────────────────────────────────────────
nda_auto_continue() {
  local path="$1" recommendation="$2"
  local classification
  classification=$(nda_extract_classification "$path")

  local body
  body="## 🤖 needs-decisions 自動続行（#102）

Triage が \`safe\` 分類した論点について、PM の第一推奨を採用し自動で開発を続行します
（\`NEEDS_DECISIONS_MODE=${NEEDS_DECISIONS_MODE}\`）。

**採用した第一推奨**:

> ${recommendation}

この判断を止めたい場合は \`FULL_AUTO_ENABLED=false\` または \`NEEDS_DECISIONS_MODE=all-human\`
に切り替えてください（次サイクル以降は人間据え置きに戻ります）。機密・コンプラ・不可逆・
外部影響を含む論点は \`human-only\` 分類となり、本機能では自動続行しません。

<!-- ${NDA_COMMENT_MARKER} issue=${NUMBER} mode=${NEEDS_DECISIONS_MODE} classification=${classification} -->"

  if ! timeout "$NEEDS_DECISIONS_GIT_TIMEOUT" gh issue comment "$NUMBER" \
      --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    nda_warn "issue=#${NUMBER}: audit コメント投稿に失敗（自動続行 halt → 既存据え置き経路へ）"
    return 1
  fi

  # claim 解除（codex-needs-decisions は付与しない）→ 次サイクルで dispatcher 再 pickup。
  if ! timeout "$NEEDS_DECISIONS_GIT_TIMEOUT" gh issue edit "$NUMBER" \
      --repo "$REPO" --remove-label "$LABEL_CLAIMED" >/dev/null 2>&1; then
    nda_warn "issue=#${NUMBER}: claim ラベル除去に失敗（次サイクルで再評価）"
  fi
  nda_log "issue=#${NUMBER} action=auto-continue mode=${NEEDS_DECISIONS_MODE} classification=${classification}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# nda_evaluate_auto_continue: 自動続行可否のゲート（本体 Triage ルートから呼ぶ thin guard）
#   入力: $1 = triage_json_path
#   戻り値: 0 = 自動続行を実行した（本体は据え置き経路を skip し return すべき）
#           1 = halt（本体は従来どおり codex-needs-decisions 付与 + コメントへ流す）
#   評価順（安全境界）: full_auto → mode → classification(human-only HARD halt) →
#                       recommendation → budget → auto_continue
#   `all-auto` は mode 評価を通すだけで classification 評価を **短絡しない**。human-only は
#   全モードで halt する（NFR hard safety boundary）。
# ─────────────────────────────────────────────────────────────────────────────
nda_evaluate_auto_continue() {
  local path="$1"
  local mode="${NEEDS_DECISIONS_MODE:-all-human}"

  # 1. kill switch
  if ! full_auto_enabled; then
    nda_log "issue=#${NUMBER} action=halt cause=suppressed-by-FULL_AUTO_ENABLED"
    return 1
  fi
  # 2. mode（all-human / 不正値 → halt）
  if ! nda_resolve_mode_enabled; then
    nda_log "issue=#${NUMBER} mode=${mode} action=halt cause=mode-all-human"
    return 1
  fi
  # 3. classification（human-only は全モードで HARD halt / 安全境界）
  local classification
  classification=$(nda_extract_classification "$path")
  if [ "$classification" = "human-only" ]; then
    nda_log "issue=#${NUMBER} mode=${mode} classification=human-only action=halt cause=classification-human-only"
    return 1
  fi
  # 4. recommendation（第一推奨が無ければ halt）
  local recommendation
  if ! recommendation=$(nda_extract_first_recommendation "$path"); then
    nda_log "issue=#${NUMBER} mode=${mode} classification=${classification} action=halt cause=recommendation-missing"
    return 1
  fi
  # 5. budget（無限続行ガード）
  if ! nda_budget_available "$NUMBER"; then
    nda_log "issue=#${NUMBER} mode=${mode} action=halt cause=budget-exhausted max=${NEEDS_DECISIONS_AUTO_MAX}"
    return 1
  fi
  # 6. 全 pass → 自動続行
  if nda_auto_continue "$path" "$recommendation"; then
    return 0
  fi
  return 1
}
