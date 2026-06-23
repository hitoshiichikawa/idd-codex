#!/usr/bin/env bash
#
# 用途: pr_default_prompt（idd-claude #399 移植）に「網羅性要求」と「spec 文書間整合
#       チェック」の 2 ブロックが含まれ、既存の出力契約（VERDICT 行 / 5 観点 / 概要・
#       指摘事項・結論）が維持されていることを検証する。反復ラウンド/コスト削減が目的。
#
# 配置先: local-watcher/test/pr_default_prompt_blocks_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/pr_default_prompt_blocks_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_REVIEWER_SH="$SCRIPT_DIR/../bin/idd-codex-modules/pr-reviewer.sh"
[ -f "$PR_REVIEWER_SH" ] || { echo "ERROR: not found: $PR_REVIEWER_SH" >&2; exit 2; }

extract_function() {
  local script="$1" fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_REVIEWER_SH" "pr_default_prompt")"
declare -F pr_default_prompt >/dev/null || { echo "ERROR: pr_default_prompt not loaded" >&2; exit 2; }

OUT="$(pr_default_prompt)"

PASS_COUNT=0; FAIL_COUNT=0
assert_contains() { local l="$1" n="$2"; case "$OUT" in *"$n"*) echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1));; *) echo "FAIL: $l ('$n' 不在)"; FAIL_COUNT=$((FAIL_COUNT+1));; esac; }
assert_count() { local l="$1" n="$2" e="$3"; local a; a=$(printf '%s' "$OUT" | grep -cF "$n" || true); if [ "$a" = "$e" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l (exp=$e act=$a)"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }

echo "--- 1. 網羅性要求ブロック（#399）---"
assert_contains "網羅性要求 見出し" "# 網羅性要求（最優先）"
assert_contains "drip-feed 禁止の明記" "drip-feed（小出し）せず"
assert_contains "往復回数最小化の明記" "レビュー往復回数を最小化"

echo ""; echo "--- 2. spec 文書間整合チェックブロック（#399・条件付き）---"
assert_contains "spec 整合 見出し" "# spec 文書間整合チェック（条件付き適用）"
assert_contains "条件付き（docs/specs 変更時のみ）" "docs/specs/"
assert_contains "requirements ⇄ design" "requirements ⇄ design"
assert_contains "design ⇄ tasks" "design ⇄ tasks"
assert_contains "tasks ⇄ requirements (_Requirements:_)" "_Requirements:_"

echo ""; echo "--- 3. 既存契約の維持（回帰なし）---"
assert_contains "レビュー観点 見出し維持" "# レビュー観点（優先度順）"
assert_contains "制約 見出し維持" "# 制約"
assert_contains "概要 セクション維持" "## 概要"
assert_contains "指摘事項 セクション維持" "## 指摘事項"
assert_contains "結論 セクション維持" "## 結論"
assert_contains "VERDICT codex-needs-iteration 維持" "VERDICT: codex-needs-iteration"
assert_contains "VERDICT approve 維持" "VERDICT: approve"
# 網羅性ブロックは「レビュー観点」より前（intro 直後）に置く
case "$OUT" in
  *"網羅性要求"*"レビュー観点（優先度順）"*) echo "PASS: 網羅性ブロックがレビュー観点より前"; PASS_COUNT=$((PASS_COUNT+1));;
  *) echo "FAIL: 網羅性ブロックの位置"; FAIL_COUNT=$((FAIL_COUNT+1));;
esac
# VERDICT 行は各 1 回（出力契約の単独行を壊さない）
assert_count "VERDICT 行は 2 種各 1 回" "VERDICT:" "2"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
