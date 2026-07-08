#!/usr/bin/env bash
# =============================================================================
# idd-codex: GitHub ラベル一括作成スクリプト
#
# 使い方:
#   cd /path/to/your-project
#   bash .github/scripts/idd-codex-labels.sh
#
#   # 明示的に repo を指定（repo 外から呼ぶ場合）
#   bash .github/scripts/idd-codex-labels.sh --repo owner/repo
#
#   # 既存ラベルの color / description を上書き更新
#   bash .github/scripts/idd-codex-labels.sh --force
#
# 依存: gh CLI（`gh auth login` 済み）, jq
# =============================================================================

set -euo pipefail

REPO=""
FORCE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --repo)
      REPO="$2"
      shift 2
      ;;
    --force|-f)
      FORCE="--force"
      shift
      ;;
    -h|--help)
      sed -n '3,16p' "$0"
      exit 0
      ;;
    *)
      echo "未知のオプション: $1" >&2
      exit 1
      ;;
  esac
done

command -v gh >/dev/null 2>&1 || {
  echo "Error: 'gh' CLI が必要です。https://cli.github.com" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || {
  echo "Error: 'jq' が必要です。" >&2
  exit 1
}

REPO_ARG=()
if [ -n "$REPO" ]; then
  REPO_ARG=(--repo "$REPO")
fi

# Label definitions: name|color|description
# Issue #54 Req 2.1 / 2.2 / 2.3: 誤付与防止のため description に「【PR 用】」「【Issue 用】」
# prefix を入れて適用先を明示する。GitHub のラベル description 上限（100 文字）を超えないよう
# 末尾の説明文は維持できる範囲で短縮しない（最長: codex-needs-rebase = 80 文字）。
# ラベルの name / color 自体は本要件で変更しない（既存運用との互換性維持・Req 2.5）。
LABELS=(
  "codex-auto-dev|1f77b4|【Issue 用】 自動開発対象"
  "codex-needs-decisions|f1c40f|【Issue 用】 人間の判断が必要"
  "codex-awaiting-design-review|e67e22|【Issue 用】 設計 PR レビュー待ち（Architect 発動時）"
  "codex-claimed|c39bd3|【Issue 用】 Codex CLI が claim 済（Triage 実行中）"
  "codex-picked-up|9b59b6|【Issue 用】 Codex CLI 実行中"
  "codex-ready-for-review|2ecc71|【Issue 用】 PR 作成完了"
  "codex-failed|e74c3c|【Issue 用】 自動実行が失敗（復旧時は codex-ready-for-review を先に付与してから外す）"
  "codex-skip-triage|95a5a6|【Issue 用】 Triage をスキップ"
  "codex-needs-rebase|fbca04|【PR 用】 approved PR で base が古い／conflict が発生済み（Phase A: Merge Queue Processor が付与）"
  "codex-needs-iteration|d4c5f9|【PR 用】 PR レビューコメントの反復対応待ち（#26 PR Iteration Processor が処理）"
  "codex-needs-quota-wait|c5def5|【Issue 用】 Codex Max quota 超過で reset 待ち（Quota Resume Processor が自動除去）"
  "codex-staged-for-release|b8e0d2|【Issue 用】 develop に merge 済み、main 到達待ち（multi-branch 運用専用）"
  "codex-st-failed|d73a4a|【Issue 用】 ST failure 検知後 revert 済み（Phase B Promote Pipeline が付与）"
  "codex-awaiting-slot|c5def5|【Issue 用】 hot file 競合予防で同サイクル dispatch を見送り中（Phase E Path Overlap Checker が付与・除去）"
  "codex-blocked|b60205|【Issue 用】 依存 Issue 未 merge により codex-auto-dev 進行不能"
  "codex-hotfix|d93f0b|【Issue 用】 codex-hotfix 優先処理対象（Dispatcher が非 codex-hotfix より先に投入）"
  "codex-needs-merge-gate-attention|f9d0c4|【PR 用】 claude-review が required だが adjudicator も 2nd gate も発火せず merge gate を満たせない停滞状態（#138）"
)

echo "📌 idd-codex ラベルを作成します"
if [ -n "$REPO" ]; then
  echo "   対象: $REPO"
else
  echo "   対象: カレントディレクトリの git repo（gh auto-detect）"
fi
echo ""

CREATED=0
EXISTS=0
UPDATED=0
FAILED=0

# 既存ラベルを 1 回の API コールで全件取得しキャッシュする。
# `gh label list` のデフォルト件数上限（30）はページネーション境界の取りこぼし
# を起こすため、`--limit 1000` で十分なマージンを取る（NFR 2.3）。
# 取得自体に失敗した場合（API 不達 / 認証失敗 / 権限不足等）は、ラベル状態を
# 確定できないので即座にエラー終了する（Req 2.4）。
EXISTING_LABELS_JSON=""
if ! EXISTING_LABELS_JSON=$(gh label list "${REPO_ARG[@]}" --limit 1000 --json name 2>&1); then
  echo "Error: 既存ラベル一覧の取得に失敗しました: $EXISTING_LABELS_JSON" >&2
  exit 1
fi

EXISTING_LABEL_NAMES=$(printf '%s' "$EXISTING_LABELS_JSON" | jq -r '.[].name')

for spec in "${LABELS[@]}"; do
  IFS="|" read -r NAME COLOR DESC <<< "$spec"
  printf "  %-25s ... " "$NAME"
  if printf '%s\n' "$EXISTING_LABEL_NAMES" | grep -qxF "$NAME"; then
    # 既存ラベル
    if [ -n "$FORCE" ]; then
      if gh label create "$NAME" --color "$COLOR" --description "$DESC" --force "${REPO_ARG[@]}" >/dev/null 2>&1; then
        echo "created/updated"
        UPDATED=$((UPDATED+1))
      else
        echo "FAILED"
        FAILED=$((FAILED+1))
      fi
    else
      echo "already exists (skipped; use --force to update)"
      EXISTS=$((EXISTS+1))
    fi
  else
    # 未存在ラベル: 新規作成を試みる
    if gh label create "$NAME" --color "$COLOR" --description "$DESC" "${REPO_ARG[@]}" >/dev/null 2>&1; then
      if [ -n "$FORCE" ]; then
        echo "created/updated"
        UPDATED=$((UPDATED+1))
      else
        echo "created"
        CREATED=$((CREATED+1))
      fi
    else
      echo "FAILED"
      FAILED=$((FAILED+1))
    fi
  fi
done

echo ""
echo "== 結果 =="
echo "  新規作成: $CREATED"
echo "  既存スキップ: $EXISTS"
echo "  上書き更新: $UPDATED"
echo "  失敗: $FAILED"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
