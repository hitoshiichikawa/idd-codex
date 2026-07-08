#!/usr/bin/env bash
#
# 用途: Issue #138 で追加した Merge Gate Visibility Processor（idd-claude #412 / PR #423 の
#       移植）の各判定ヘルパー（mgv_claude_review_required / mgv_pr_has_claude_review_status /
#       mgv_pr_has_adjudicator_marker）と process_claude_review_merge_gate_visibility の
#       停滞 / 解消判定を gh stub で検証するスモークテスト。
#
#       検証観点:
#         - 正常系: claude-review required + status 未 publish + marker 不在 → 停滞検知
#           （codex-needs-merge-gate-attention 付与 + WARN ログ）
#         - 解消系: status publish 済 / adjudicator marker あり → ラベル冪等除去
#         - 異常系: branch protection 未設定（404）/ API 失敗 → fail-safe skip
#         - 境界: 不正 branch 名（option injection）/ 不正 sha / 不正 PR 番号 /
#           sha 不一致 marker / contexts 空配列 / 候補 PR ゼロ件
#
# 配置先: local-watcher/test/mgv_merge_gate_visibility_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/mgv_merge_gate_visibility_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_SH="$SCRIPT_DIR/../bin/idd-codex-modules/pr-reviewer.sh"

if [ ! -f "$PR_SH" ]; then
  echo "ERROR: cannot find pr-reviewer.sh at $PR_SH" >&2
  exit 2
fi

# 既存テストと同じイディオム: 対象スクリプトから 1 関数だけを awk で切り出して eval。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 対象関数群を読み込む（gh / timeout / pr_log / pr_warn はテスト内で stub）。
# shellcheck disable=SC1090
eval "$(extract_function "$PR_SH" "mgv_claude_review_required")"
# shellcheck disable=SC1090
eval "$(extract_function "$PR_SH" "mgv_pr_has_claude_review_status")"
# shellcheck disable=SC1090
eval "$(extract_function "$PR_SH" "mgv_pr_has_adjudicator_marker")"
# shellcheck disable=SC1090
eval "$(extract_function "$PR_SH" "mgv_add_attention_label")"
# shellcheck disable=SC1090
eval "$(extract_function "$PR_SH" "mgv_remove_attention_label")"
# shellcheck disable=SC1090
eval "$(extract_function "$PR_SH" "process_claude_review_merge_gate_visibility")"

# モジュール定数（pr-reviewer.sh のトップレベル定義を等価に再現し、値の drift を検出）。
# eval で抽出した関数内から遅延束縛で参照されるため SC2034 を局所抑止する。
# shellcheck disable=SC2034
MGV_LABEL_NEEDS_MERGE_GATE_ATTENTION="codex-needs-merge-gate-attention"
if ! grep -q 'MGV_LABEL_NEEDS_MERGE_GATE_ATTENTION="codex-needs-merge-gate-attention"' "$PR_SH"; then
  echo "FAIL: pr-reviewer.sh のラベル定数が codex-needs-merge-gate-attention ではありません" >&2
  exit 1
fi

# 抽出関数が遅延束縛で参照するグローバル env（SC2034 局所抑止）。
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
BASE_BRANCH="main"
# shellcheck disable=SC2034
PR_REVIEWER_GIT_TIMEOUT=10
# shellcheck disable=SC2034
PR_REVIEWER_MAX_PRS=5

PASS_COUNT=0
FAIL_COUNT=0

assert_rc() {
  local label="$1"
  local expected_rc="$2"
  local actual_rc="$3"
  if [ "$expected_rc" = "$actual_rc" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected rc: $expected_rc"
    echo "  actual rc  : $actual_rc"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if printf '%s' "$haystack" | grep -F -q -- "$needle"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  needle  : $needle"
    echo "  haystack: $haystack"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if printf '%s' "$haystack" | grep -F -q -- "$needle"; then
    echo "FAIL: $label"
    echo "  unexpected needle: $needle"
    echo "  haystack         : $haystack"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

# ─── stubs ────────────────────────────────────────────────────────────────────
# - timeout: 引数の `timeout SECS gh ...` を `gh ...` だけに転送（実 timeout は使わない）
# - gh: $MGV_GH_SCRIPT で振る舞いを切り替える stub。各テストケース冒頭で設定。
# - jq: 本物を呼ぶ

# shellcheck disable=SC2317
timeout() {
  shift  # 秒数を捨てる
  "$@"
}

MGV_GH_SCRIPT=""
GH_EDIT_LOG=""

# shellcheck disable=SC2317
gh() {
  # gh pr edit（ラベル操作）は共通で記録して成功させる
  if [ "${1:-}" = "pr" ] && [ "${2:-}" = "edit" ]; then
    GH_EDIT_LOG="${GH_EDIT_LOG}gh $*"$'\n'
    return 0
  fi
  case "$MGV_GH_SCRIPT" in
    protection_with_claude_review)
      case "$*" in
        *"/protection"*)
          printf '%s\n' '["ci","claude-review","codex-review"]'
          return 0
          ;;
      esac
      ;;
    protection_without_claude_review)
      case "$*" in
        *"/protection"*)
          printf '%s\n' '["ci"]'
          return 0
          ;;
      esac
      ;;
    protection_empty)
      case "$*" in
        *"/protection"*)
          printf '%s\n' '[]'
          return 0
          ;;
      esac
      ;;
    protection_not_found)
      case "$*" in
        *"/protection"*)
          return 1
          ;;
      esac
      ;;
    statuses_with_claude_review)
      printf '%s\n' '["ci","claude-review"]'
      return 0
      ;;
    statuses_without_claude_review)
      printf '%s\n' '["ci"]'
      return 0
      ;;
    statuses_api_fail)
      return 1
      ;;
    comments_with_marker)
      cat <<'EOF'
First comment unrelated
<!-- idd-codex:pr-adjudicator sha=abc1234 kind=decision -->
Adjudicator decision summary
EOF
      return 0
      ;;
    comments_without_marker)
      cat <<'EOF'
Random comment
<!-- idd-codex:pr-adjudicator-excessive id=1 sha=abc1234 -->
EOF
      return 0
      ;;
    comments_with_marker_wrong_sha)
      cat <<'EOF'
<!-- idd-codex:pr-adjudicator sha=deadbee kind=decision -->
EOF
      return 0
      ;;
    comments_api_fail)
      return 1
      ;;
    e2e_stalled)
      # processor E2E: protection=required / statuses=未publish / comments=markerなし
      case "$*" in
        *"/protection"*)  printf '%s\n' '["claude-review"]'; return 0 ;;
        *"/statuses"*)    printf '%s\n' '["ci"]'; return 0 ;;
        "pr view"*)       printf '%s\n' 'no marker here'; return 0 ;;
      esac
      ;;
    e2e_cleared_by_status)
      case "$*" in
        *"/protection"*)  printf '%s\n' '["claude-review"]'; return 0 ;;
        *"/statuses"*)    printf '%s\n' '["ci","claude-review"]'; return 0 ;;
        "pr view"*)       printf '%s\n' 'no marker here'; return 0 ;;
      esac
      ;;
    e2e_not_required)
      case "$*" in
        *"/protection"*)  printf '%s\n' '["ci"]'; return 0 ;;
        *)                echo "ERROR: not_required なのに追加 gh 呼び出し: $*" >&2; return 99 ;;
      esac
      ;;
  esac
  echo "ERROR: unexpected gh call (MGV_GH_SCRIPT=${MGV_GH_SCRIPT}): $*" >&2
  return 99
}

PR_LOG_BUF=""
PR_WARN_BUF=""
# shellcheck disable=SC2317
pr_log() { PR_LOG_BUF="${PR_LOG_BUF}$*"$'\n'; }
# shellcheck disable=SC2317
pr_warn() { PR_WARN_BUF="${PR_WARN_BUF}$*"$'\n'; }

# process_claude_review_merge_gate_visibility が呼ぶ候補 PR 取得を stub 化。
MGV_CANDIDATES_JSON="[]"
# shellcheck disable=SC2317
pr_fetch_candidate_prs() { printf '%s\n' "$MGV_CANDIDATES_JSON"; }

# ─── mgv_claude_review_required ───

echo "--- mgv_claude_review_required（正常系 / 異常系 / 境界） ---"

MGV_GH_SCRIPT="protection_with_claude_review"
rc=0
mgv_claude_review_required "main" || rc=$?
assert_rc "正常系: branch protection に claude-review 含 → rc=0 (required)" "0" "$rc"

MGV_GH_SCRIPT="protection_without_claude_review"
rc=0
mgv_claude_review_required "main" || rc=$?
assert_rc "正常系: branch protection に claude-review 不含 → rc=1 (not required)" "1" "$rc"

MGV_GH_SCRIPT="protection_empty"
rc=0
mgv_claude_review_required "main" || rc=$?
assert_rc "境界: contexts 空配列 → rc=1 (not required)" "1" "$rc"

MGV_GH_SCRIPT="protection_not_found"
rc=0
mgv_claude_review_required "main" || rc=$?
assert_rc "異常系: branch protection 未設定 (gh api 404) → rc=2 (fail-safe)" "2" "$rc"

MGV_GH_SCRIPT="protection_with_claude_review"  # 呼ばれない想定
rc=0
mgv_claude_review_required "--option-injection" || rc=$?
assert_rc "境界: 不正な branch 名（option injection）→ rc=1 (gh 呼び出し前 reject)" "1" "$rc"

rc=0
mgv_claude_review_required "" || rc=$?
assert_rc "境界: 空 branch 名 → rc=1" "1" "$rc"

echo ""
echo "--- mgv_pr_has_claude_review_status ---"

MGV_GH_SCRIPT="statuses_with_claude_review"
rc=0
mgv_pr_has_claude_review_status "abc1234" || rc=$?
assert_rc "解消系: claude-review status 既 publish → rc=0 (clear 対象)" "0" "$rc"

MGV_GH_SCRIPT="statuses_without_claude_review"
rc=0
mgv_pr_has_claude_review_status "abc1234" || rc=$?
assert_rc "正常系: claude-review status 未 publish → rc=1 (stalled 候補)" "1" "$rc"

MGV_GH_SCRIPT="statuses_api_fail"
rc=0
mgv_pr_has_claude_review_status "abc1234" || rc=$?
assert_rc "異常系: API 失敗 → rc=2 (fail-safe)" "2" "$rc"

rc=0
mgv_pr_has_claude_review_status "not-a-sha" || rc=$?
assert_rc "境界: 不正な sha → rc=1 (gh 呼び出し前 reject)" "1" "$rc"

echo ""
echo "--- mgv_pr_has_adjudicator_marker ---"

MGV_GH_SCRIPT="comments_with_marker"
rc=0
mgv_pr_has_adjudicator_marker "123" "abc1234" || rc=$?
assert_rc "解消系: adjudicator decision marker (sha 一致) あり → rc=0 (clear 対象)" "0" "$rc"

MGV_GH_SCRIPT="comments_without_marker"
rc=0
mgv_pr_has_adjudicator_marker "123" "abc1234" || rc=$?
assert_rc "正常系: decision marker 不在（excessive marker のみ）→ rc=1 (stalled 候補)" "1" "$rc"

MGV_GH_SCRIPT="comments_with_marker_wrong_sha"
rc=0
mgv_pr_has_adjudicator_marker "123" "abc1234" || rc=$?
assert_rc "境界: marker あるが sha 不一致 → rc=1 (別 sha の marker は対象外)" "1" "$rc"

MGV_GH_SCRIPT="comments_api_fail"
rc=0
mgv_pr_has_adjudicator_marker "123" "abc1234" || rc=$?
assert_rc "異常系: gh comments fetch 失敗 → rc=2 (fail-safe)" "2" "$rc"

rc=0
mgv_pr_has_adjudicator_marker "not-a-number" "abc1234" || rc=$?
assert_rc "境界: 不正な PR 番号 → rc=1" "1" "$rc"

# ─── process_claude_review_merge_gate_visibility（E2E: 停滞 / 解消 / skip） ───

echo ""
echo "--- process_claude_review_merge_gate_visibility（processor E2E） ---"

# 停滞検知: required + status 未 publish + marker 不在 → ラベル付与 + WARN
MGV_GH_SCRIPT="e2e_stalled"
MGV_CANDIDATES_JSON='[{"number":42,"headRefOid":"abc1234def5678"}]'
PR_LOG_BUF=""; PR_WARN_BUF=""; GH_EDIT_LOG=""
rc=0
process_claude_review_merge_gate_visibility || rc=$?
assert_rc "正常系: 停滞 PR → rc=0（processor は常に 0）" "0" "$rc"
assert_contains "正常系: 停滞検知 WARN ログ" "停滞検知" "$PR_WARN_BUF"
assert_contains "正常系: WARN に PR 番号と sha を含む" "PR #42 sha=abc1234def5678" "$PR_WARN_BUF"
assert_contains "正常系: codex-needs-merge-gate-attention 付与" "--add-label codex-needs-merge-gate-attention" "$GH_EDIT_LOG"
assert_contains "正常系: サマリ stalled=1" "stalled=1 cleared=0" "$PR_LOG_BUF"

# 解消: status publish 済 → ラベル冪等除去 + WARN なし
MGV_GH_SCRIPT="e2e_cleared_by_status"
MGV_CANDIDATES_JSON='[{"number":42,"headRefOid":"abc1234def5678"}]'
PR_LOG_BUF=""; PR_WARN_BUF=""; GH_EDIT_LOG=""
rc=0
process_claude_review_merge_gate_visibility || rc=$?
assert_rc "解消系: publish 済 PR → rc=0" "0" "$rc"
assert_not_contains "解消系: 停滞 WARN を出さない" "停滞検知" "$PR_WARN_BUF"
assert_contains "解消系: ラベル冪等除去" "--remove-label codex-needs-merge-gate-attention" "$GH_EDIT_LOG"
assert_contains "解消系: サマリ cleared=1" "stalled=0 cleared=1" "$PR_LOG_BUF"

# required でない repo: protection 確認 1 回のみで即 skip（副作用ゼロ）
MGV_GH_SCRIPT="e2e_not_required"
MGV_CANDIDATES_JSON='[{"number":42,"headRefOid":"abc1234def5678"}]'
PR_LOG_BUF=""; PR_WARN_BUF=""; GH_EDIT_LOG=""
rc=0
process_claude_review_merge_gate_visibility || rc=$?
assert_rc "skip 系: claude-review が required でない → rc=0" "0" "$rc"
assert_rc "skip 系: ラベル操作ゼロ（GH_EDIT_LOG 空）" "0" "$([ -z "$GH_EDIT_LOG" ]; echo $?)"
assert_not_contains "skip 系: WARN なし" "merge-gate-visibility" "$PR_WARN_BUF"

# 候補 PR ゼロ件: gh を一切呼ばず即 return 0
MGV_GH_SCRIPT="e2e_not_required"  # 呼ばれたら gh stub が 99 を返して検出される
MGV_CANDIDATES_JSON='[]'
PR_LOG_BUF=""; PR_WARN_BUF=""; GH_EDIT_LOG=""
rc=0
process_claude_review_merge_gate_visibility || rc=$?
assert_rc "境界: 候補 PR ゼロ件 → rc=0（即 return）" "0" "$rc"

# ─── サマリ ───

echo ""
echo "================================"
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
