#!/usr/bin/env bash
#
# 用途: stage prompt の安定 prefix 規約（Issue #177）を構造的に固定する。
#   - codex_exec_prompt は role preamble を prompt の最前段に置く（既存 #74 の契約を prefix 規約として明示）
#   - Reviewer / Debugger prompt では、実行ごとに変わる値（HEAD SHA / ROUND / PREV_RESULT / TRIGGER /
#     TASK_ID / review-notes 本文）が静的な指示節（必読ファイル / 差分の取得 / 進め方 / 制約）より
#     **後方** に配置される（意味内容は不変 = 各節の見出し・文言が保持される）
#   - 静的 template（triage / iteration / auto-rebase）は先頭の静的ヘッダ（`# ===` ブロック）の後に
#     プレースホルダが来る。triage の実行ごとに変わる {{FILE}}（timestamp 付き）は判定基準節より後方
#
# 配置先: local-watcher/test/prompt_stable_prefix_test.sh
# 依存:   bash 4+, awk, grep
# 実行:   bash local-watcher/test/prompt_stable_prefix_test.sh

# 環境変数は eval で読み込んだ builder 関数が参照するため、静的解析の未使用警告（SC2034）を抑止する。
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
BIN_DIR="$SCRIPT_DIR/../bin"
[ -f "$WATCHER_SH" ] || { echo "ERROR: not found: $WATCHER_SH" >&2; exit 2; }

extract_function() {
  local script="$1" fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}
for fn in build_issue_context_block build_reviewer_prompt build_debugger_prompt codex_exec_prompt; do
  # shellcheck disable=SC1090
  eval "$(extract_function "$WATCHER_SH" "$fn")"
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done

PASS_COUNT=0; FAIL_COUNT=0
assert_contains() { local l="$1" h="$2" n="$3"; case "$h" in *"$n"*) echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1));; *) echo "FAIL: $l ('$n' 不在)"; FAIL_COUNT=$((FAIL_COUNT+1));; esac; }
# needle_a が needle_b より前に出現することを検証（両方存在が前提）
assert_before() {
  local l="$1" h="$2" a="$3" b="$4"
  local pa pb
  pa=$(printf '%s' "$h" | awk -v n="$a" 'index($0,n){print NR; exit}')
  pb=$(printf '%s' "$h" | awk -v n="$b" 'index($0,n){print NR; exit}')
  if [ -n "$pa" ] && [ -n "$pb" ] && [ "$pa" -lt "$pb" ]; then
    echo "PASS: $l (L$pa < L$pb)"; PASS_COUNT=$((PASS_COUNT+1))
  else
    echo "FAIL: $l (a=L${pa:-?} b=L${pb:-?})"; FAIL_COUNT=$((FAIL_COUNT+1))
  fi
}
count_of() { printf '%s' "$1" | grep -c -F -- "$2" || true; }

# ─── 共有グローバル（builder が参照）───
NUMBER=42; TITLE="Fix things"; URL="https://example.invalid/issues/42"; BODY="body"
REPO="owner/repo"; BRANCH="codex/issue-42-impl-fix-things"; BASE_BRANCH="main"
SPEC_DIR_REL="docs/specs/42-fix-things"; LOG="/tmp/x.log"
git() { printf 'deadbeef\n'; }   # head_sha stub

# ════════════════════════════════════════════════════════════════════════════
echo "--- 1. build_reviewer_prompt: 実行時値は静的節の後方 ---"
P="$(build_reviewer_prompt 2 "reject")"
assert_before "Issue context は 必読ファイル より前（Issue 単位で一定）" "$P" "## 対象 Issue" "## 必読ファイル"
assert_before "必読ファイル → 差分の取得 → 進め方 → 制約 の静的順序 (1)" "$P" "## 必読ファイル" "## 差分の取得"
assert_before "必読ファイル → 差分の取得 → 進め方 → 制約 の静的順序 (2)" "$P" "## 差分の取得" "## 進め方"
assert_before "必読ファイル → 差分の取得 → 進め方 → 制約 の静的順序 (3)" "$P" "## 進め方" "## 制約"
assert_before "HEAD commit（実行時値）は 制約 より後" "$P" "## 制約" "HEAD commit  : deadbeef"
assert_before "ROUND（実行時値）は 制約 より後" "$P" "## 制約" "ROUND        : 2"
assert_before "PREV_RESULT（実行時値）は 制約 より後" "$P" "## 制約" "PREV_RESULT  : reject"
assert_contains "意味内容: 3 カテゴリ判定の文言を保持" "$P" "判定カテゴリ: AC 未カバー / missing test / boundary 逸脱 の 3 つに限定"
assert_contains "意味内容: RESULT 行契約を保持" "$P" "RESULT: approve"
assert_contains "意味内容: BRANCH 値を保持" "$P" "BRANCH       : codex/issue-42-impl-fix-things"
assert_contains "意味内容: SPEC_DIR_REL 値を保持" "$P" "SPEC_DIR_REL : docs/specs/42-fix-things"
[ "$(count_of "$P" '## 作業ブランチ / spec ディレクトリ')" = "1" ] && { echo "PASS: 作業ブランチ節は 1 回だけ出現"; PASS_COUNT=$((PASS_COUNT+1)); } || { echo "FAIL: 作業ブランチ節の出現回数"; FAIL_COUNT=$((FAIL_COUNT+1)); }

echo ""; echo "--- 2. build_debugger_prompt: 実行時値 / notes 本文は静的節の後方 ---"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '## Findings\n- Finding X\nRESULT: reject\n' >"$TMP/review-notes.md"
P="$(build_debugger_prompt round2-reject "1.2" "$TMP/review-notes.md")"
assert_before "Issue context は 必読ファイル より前" "$P" "## 対象 Issue" "## 必読ファイル"
assert_before "静的順序: 必読ファイル → 差分の取得" "$P" "## 必読ファイル" "## 差分の取得（Bash で実行）"
assert_before "静的順序: 差分の取得 → web search" "$P" "## 差分の取得（Bash で実行）" "## web search の活用"
assert_before "静的順序: web search → 出力先" "$P" "## web search の活用" "## 出力先と必須セクション"
assert_before "静的順序: 出力先 → 禁止事項 → 進め方" "$P" "## 禁止事項（やってはいけないこと）" "## 進め方"
assert_before "TRIGGER（実行時値）は 進め方 より後" "$P" "## 進め方" "TRIGGER      : round2-reject"
assert_before "TASK_ID（実行時値）は 進め方 より後" "$P" "## 進め方" "TASK_ID      : 1.2"
assert_before "対象 task 節（実行時値）は 進め方 より後" "$P" "## 進め方" "## 対象 task（Phase 2 per-task loop 有効時）"
assert_before "review-notes 本文（実行時値・可変長）は 進め方 より後" "$P" "## 進め方" "## Reviewer の reject 理由（review-notes.md より）"
assert_contains "意味内容: notes 本文は保持" "$P" "- Finding X"
assert_contains "意味内容: 必須セクション（task 単位）を保持" "$P" "## Task 1.2"
assert_contains "意味内容: 禁止事項を保持" "$P" "コードファイル（実装 / テスト）を Edit / Write しない"
P2="$(build_debugger_prompt blocked "" "")"
assert_before "blocked 経路: BLOCKED 宣言節は 進め方 より後" "$P2" "## 進め方" "## Developer の BLOCKED 宣言"
assert_before "Issue 単位経路: 対象 scope 節は 進め方 より後" "$P2" "## 進め方" "## 対象 scope"
assert_contains "Issue 単位経路: 必須セクション（Issue 単位）を保持" "$P2" "- \`## 根本原因\`"

echo ""; echo "--- 3. codex_exec_prompt: role preamble が最前段 ---"
BODY_TXT="$(extract_function "$WATCHER_SH" "codex_exec_prompt")"
assert_before "preamble 組み立ては prompt 結合より前" "$BODY_TXT" 'role_preamble="$(codex_build_role_preamble "$stage_label")"' 'prompt="${role_preamble}'
assert_contains "preamble → 区切り → stage prompt の結合順" "$BODY_TXT" '（以下、本 stage の具体タスク指示）'
assert_contains "安定 prefix 規約の参照コメント" "$BODY_TXT" "Issue #177（安定 prefix 規約）"

echo ""; echo "--- 4. template: 静的ヘッダ → プレースホルダ の順 / triage {{FILE}} は判定基準より後 ---"
for tmpl in idd-codex-triage-prompt.tmpl idd-codex-iteration-prompt.tmpl idd-codex-iteration-prompt-design.tmpl idd-codex-auto-rebase-prompt.tmpl; do
  T="$(cat "$BIN_DIR/$tmpl")"
  first_ph=$(printf '%s' "$T" | grep -n -m1 -E '\{\{[A-Z_]+\}\}' | cut -d: -f1)
  [ -n "$first_ph" ] && [ "$first_ph" -gt 1 ] && { echo "PASS: $tmpl: 先頭行は静的（最初のプレースホルダは L$first_ph）"; PASS_COUNT=$((PASS_COUNT+1)); } || { echo "FAIL: $tmpl: 先頭にプレースホルダ"; FAIL_COUNT=$((FAIL_COUNT+1)); }
done
T="$(cat "$BIN_DIR/idd-codex-triage-prompt.tmpl")"
assert_before "triage: 実行ごとに変わる {{FILE}} は needs_architect 判定基準より後" "$T" "## 「Architect を挟むべき」と判定する基準" "{{FILE}}"
assert_before "triage: {{FILE}} は classification 基準より後" "$T" "## 分類タグ（classification）の判定基準" "{{FILE}}"

echo ""; echo "──────────────"
echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
echo "ALL GREEN"
