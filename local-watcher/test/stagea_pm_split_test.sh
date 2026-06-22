#!/usr/bin/env bash
#
# 用途: #82（impl mode の Stage A を PM exec / Developer exec に分離）の純粋部分を検証する。
#   - codex_agent_roles_for_stage の StageA / StageA-PM マッピング（split on/off・mode 別）
#   - build_dev_prompt_a の impl-pm / impl-dev モードの prompt 内容
# 実行: bash local-watcher/test/stagea_pm_split_test.sh

# MODE / STAGE_A_PM_SPLIT_ENABLED は eval 抽出した関数が global として読むため SC2034 を抑止する。
# shellcheck disable=SC2034
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
[ -f "$WATCHER_SH" ] || { echo "ERROR: watcher not found" >&2; exit 2; }

extract_function() {
  awk -v fn="${2}() {" '$0==fn{i=1} i{print} i&&$0=="}"{i=0}' "$1"
}
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "codex_agent_roles_for_stage")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "build_dev_prompt_a")"
for fn in codex_agent_roles_for_stage build_dev_prompt_a; do
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done

# build_dev_prompt_a が参照する env
NUMBER=7; TITLE="demo"; URL="http://x/7"; BODY="body"; BRANCH="codex/issue-7-x"
BASE_BRANCH="main"; SPEC_DIR_REL="docs/specs/7-x"
export NUMBER TITLE URL BODY BRANCH BASE_BRANCH SPEC_DIR_REL

# build_dev_prompt_a は #70 で追加された build_issue_context_block を template 内で呼ぶ。
# 本テストは prompt の mode 別 steps 内容のみを検証するため、当該依存は stub で十分。
build_issue_context_block() { printf '## 対象 Issue\n- Number: #%s\n- Title : %s\n' "${NUMBER:-}" "${TITLE:-}"; }

PASS=0; FAIL=0
eq()  { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (exp=$(printf %q "$2") act=$(printf %q "$3"))"; FAIL=$((FAIL+1)); fi; }
has() { if [[ "$2" == *"$3"* ]]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (missing '$3')"; FAIL=$((FAIL+1)); fi; }
hasnot() { if [[ "$2" != *"$3"* ]]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (unexpected '$3')"; FAIL=$((FAIL+1)); fi; }

# ─── role マッピング ───
eq "StageA-PM → product-manager" "product-manager" "$(codex_agent_roles_for_stage "StageA-PM")"

MODE="impl"; STAGE_A_PM_SPLIT_ENABLED="true"
eq "StageA (impl, split on) → developer のみ" "developer" "$(codex_agent_roles_for_stage "StageA")"
STAGE_A_PM_SPLIT_ENABLED="false"
eq "StageA (impl, split off) → PM+Developer 同居" "product-manager developer" "$(codex_agent_roles_for_stage "StageA")"
MODE="impl-resume"; STAGE_A_PM_SPLIT_ENABLED="true"
eq "StageA (impl-resume) → developer" "developer" "$(codex_agent_roles_for_stage "StageA")"
unset MODE STAGE_A_PM_SPLIT_ENABLED

# ─── prompt: impl-pm（PM のみ） ───
pm="$(build_dev_prompt_a "impl-pm")"
has "impl-pm: requirements.md を保存" "$pm" "requirements.md\` に保存"
has "impl-pm: 要件定義のみ明示" "$pm" "要件定義のみ"
has "impl-pm: 実装・commit しない明示" "$pm" "実装・テスト・commit は **行わないこと**"
hasnot "impl-pm: developer 実装ステップを含まない" "$pm" "developer として実装＋テスト＋コミット"

# ─── prompt: impl-dev（Developer のみ、requirements.md を fresh に読む） ───
dev="$(build_dev_prompt_a "impl-dev")"
has "impl-dev: developer 実装ステップ" "$dev" "developer として実装＋テスト＋コミット"
has "impl-dev: requirements.md を fresh に読む" "$dev" "fresh に読むこと"
hasnot "impl-dev: PM 要件定義ステップを含まない" "$dev" "product-manager として要件定義を"
has "impl-dev: PR 作成しない制約維持" "$dev" "PR 作成（project-manager サブエージェント）を行わないこと"

# 既存 impl / impl-resume が壊れていない
has "impl(bundled): PM ステップ存在" "$(build_dev_prompt_a "impl")" "product-manager サブエージェントで要件定義"
has "impl-resume: design.md/tasks.md 入力" "$(build_dev_prompt_a "impl-resume")" "design.md"

echo "──────────────"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1; echo "ALL GREEN"
