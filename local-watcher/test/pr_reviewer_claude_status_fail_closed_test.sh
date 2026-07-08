#!/usr/bin/env bash
#
# 用途: Issue #145（idd-claude #434 Defect B 移植）で pr-reviewer.sh の
#       pr_publish_claude_status に追加した「terminal ラベル付き PR への
#       claude-review=success の fail-closed ガード」を gh stub で検証する。
#
#       検証観点:
#         - codex-failed / codex-needs-decisions 付き PR への success → publish しない
#           （fail-closed / WARN + skip）
#         - failure（iteration / conflict 等）は terminal でもそのまま publish
#         - terminal ラベル無し → 従来どおり publish
#         - ラベル再取得失敗 → 従来どおり publish 継続（fail-open）+ WARN 1 行
#         - status-check gate OFF → ガードの gh pr view を呼ばない（外部呼び出しゼロ）
#         - adjudicator 経路（adj_apply_status_decision → pr_publish_claude_status）でも
#           terminal ラベルで success が抑止される（publisher 1 箇所への集約で自動カバー）
#
# 配置先: local-watcher/test/pr_reviewer_claude_status_fail_closed_test.sh
# 依存:   bash 4+, awk, grep, jq, mktemp
# 実行:   bash local-watcher/test/pr_reviewer_claude_status_fail_closed_test.sh

set -euo pipefail
# shellcheck disable=SC2034  # eval で抽出した関数が参照する環境変数をこのテスト内で定義する。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_MOD="$SCRIPT_DIR/../bin/idd-codex-modules/pr-reviewer.sh"
ADJ_MOD="$SCRIPT_DIR/../bin/idd-codex-modules/adjudicator.sh"
for f in "$PR_MOD" "$ADJ_MOD"; do
  [ -f "$f" ] || { echo "ERROR: not found: $f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 2; }

extract_function() {
  local script="$1" fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_MOD" "pr_publish_claude_status")"
# adjudicator 経路の統合検証用
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$ADJ_MOD" "adj_apply_status_decision")"

for fn in pr_publish_claude_status adj_apply_status_decision; do
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done

# ─── 環境 / stub ───
export REPO="owner/repo"
export LABEL_FAILED="codex-failed"; export LABEL_NEEDS_DECISIONS="codex-needs-decisions"
export PR_REVIEWER_GIT_TIMEOUT=5
GH_CALL_LOG=""; WARN_OUT=""; PUBLISH_CALL_LOG=""
GH_PR_VIEW_LABELS='{"labels":[]}'; GH_PR_VIEW_RC=0
VALID_SHA="0123456789abcdef0123456789abcdef01234567"

timeout() { shift; "$@"; }
gh() {
  printf 'gh %s\n' "$*" >>"$GH_CALL_LOG"
  if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
    [ "$GH_PR_VIEW_RC" -ne 0 ] && return "$GH_PR_VIEW_RC"
    printf '%s' "$GH_PR_VIEW_LABELS"
    return 0
  fi
  return 0
}
# shellcheck disable=SC2317
pr_warn() { echo "$*" >>"$WARN_OUT"; }
# shellcheck disable=SC2317
pr_log()  { :; }
# shellcheck disable=SC2317
adj_warn() { echo "$*" >>"$WARN_OUT"; }
# shellcheck disable=SC2317
adj_log()  { :; }

# #145 ガードは publish 有効時（status-check gate ON）のみ発火する。本テストは gate ON
# 前提でガード挙動を検証するため、gate 判定を enabled 固定に stub する（gate OFF 時の
# 挙動は Section 4 で別 stub に差し替えて検証）。
# shellcheck disable=SC2317
pr_status_check_enabled() { return 0; }

# pr_publish_commit_status stub: 呼び出しと引数を記録（実 publish が走ったかの観測）
# shellcheck disable=SC2317
pr_publish_commit_status() {
  # $1=pr_number $2=sha $3=context $4=state $5=description $6=target_url
  echo "publish pr=$1 context=$3 state=$4" >>"$PUBLISH_CALL_LOG"
  return 0
}

# adjudicator 経路が参照する Reviewer verdict の stub（既定: approve 相当の空）
ADJ_REVIEWER_VERDICT=""
# shellcheck disable=SC2317
adj_read_reviewer_verdict() { printf '%s' "$ADJ_REVIEWER_VERDICT"; }

reset_state() {
  GH_CALL_LOG="$(mktemp)"; WARN_OUT="$(mktemp)"; PUBLISH_CALL_LOG="$(mktemp)"
  GH_PR_VIEW_LABELS='{"labels":[]}'; GH_PR_VIEW_RC=0; ADJ_REVIEWER_VERDICT=""
}
publishes() { grep -c "$1" "$PUBLISH_CALL_LOG" 2>/dev/null || true; }
warns()     { grep -c "$1" "$WARN_OUT" 2>/dev/null || true; }
gh_calls()  { grep -c "$1" "$GH_CALL_LOG" 2>/dev/null || true; }

PASS=0; FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS: $1"
  else FAIL=$((FAIL+1)); echo "FAIL: $1 (expected=$2 actual=$3)"; fi
}

# ============================================================
echo "--- Section 1: terminal ラベル付き success の fail-closed ---"
# ============================================================

# codex-failed 付き → success を publish しない
reset_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"codex-failed"}]}'
pr_publish_claude_status 100 "$VALID_SHA" approve "https://x/pr/100"
assert_eq "codex-failed 付き → success publish ゼロ（fail-closed）" "0" "$(publishes 'context=claude-review')"
assert_eq "skip 時に WARN 1 行を残す" "1" "$(warns "terminal label 'codex-failed'.*skip claude-review=success")"

# codex-needs-decisions 付き → success を publish しない
reset_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"codex-needs-decisions"}]}'
pr_publish_claude_status 101 "$VALID_SHA" approve ""
assert_eq "codex-needs-decisions 付き → success publish ゼロ" "0" "$(publishes 'context=claude-review')"

# 両 terminal ラベル付き → success を publish しない
reset_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"codex-failed"},{"name":"codex-needs-decisions"}]}'
pr_publish_claude_status 102 "$VALID_SHA" approve ""
assert_eq "両 terminal ラベル → success publish ゼロ" "0" "$(publishes 'context=claude-review')"

# ============================================================
echo ""
echo "--- Section 2: terminal ラベル無し / failure の通常経路 ---"
# ============================================================

# terminal ラベル無し → approve を success で publish（従来どおり）
reset_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"codex-ready-for-review"}]}'
pr_publish_claude_status 103 "$VALID_SHA" approve ""
assert_eq "terminal ラベル無し → success を publish" "1" "$(publishes 'context=claude-review state=success')"

# iteration（failure）は terminal でもそのまま publish（ガードは success 経路のみ）
reset_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"codex-failed"}]}'
pr_publish_claude_status 104 "$VALID_SHA" iteration ""
assert_eq "failure は terminal でも publish（gate を閉じる方向）" "1" "$(publishes 'context=claude-review state=failure')"
assert_eq "failure 経路では gh pr view を呼ばない" "0" "$(gh_calls '^gh pr view')"

# conflict（failure）も同様
reset_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"codex-needs-decisions"}]}'
pr_publish_claude_status 105 "$VALID_SHA" conflict ""
assert_eq "conflict（failure）も terminal で publish" "1" "$(publishes 'context=claude-review state=failure')"

# ============================================================
echo ""
echo "--- Section 3: ラベル再取得失敗時の fail-open ---"
# ============================================================

reset_state
GH_PR_VIEW_RC=1
pr_publish_claude_status 106 "$VALID_SHA" approve ""
assert_eq "ラベル再取得失敗 → success を従来どおり publish（fail-open）" "1" "$(publishes 'context=claude-review state=success')"
assert_eq "ラベル再取得失敗時に WARN 1 行を残す" "1" "$(warns 'terminal ラベル再取得に失敗')"

# 空応答も fail-open
reset_state
GH_PR_VIEW_LABELS=''
pr_publish_claude_status 107 "$VALID_SHA" approve ""
assert_eq "ラベル空応答 → fail-open で publish 継続" "1" "$(publishes 'context=claude-review state=success')"

# ============================================================
echo ""
echo "--- Section 4: status-check gate OFF ではガードの gh を呼ばない ---"
# ============================================================

# gate OFF: ガード自体を skip（idd-claude #482 の教訓 / 外部呼び出しゼロ維持）。
# 後段 pr_publish_commit_status（実物は gate OFF で return 1）は stub のため、ここでは
# 「gh pr view が呼ばれない」ことのみを観測する。
reset_state
pr_status_check_enabled() { return 1; }
GH_PR_VIEW_LABELS='{"labels":[{"name":"codex-failed"}]}'
pr_publish_claude_status 108 "$VALID_SHA" approve ""
assert_eq "gate OFF → ガードの gh pr view を呼ばない" "0" "$(gh_calls '^gh pr view')"
pr_status_check_enabled() { return 0; }

# 数値でない pr_number → ガードの gh pr view を呼ばない（未信頼入力を gh へ渡さない）
reset_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"codex-failed"}]}'
pr_publish_claude_status "abc" "$VALID_SHA" approve "" || true
assert_eq "非数値 pr_number → ガードの gh pr view を呼ばない" "0" "$(gh_calls '^gh pr view')"

# ============================================================
echo ""
echo "--- Section 5: adjudicator 経路（adj_apply_status_decision）の統合 ---"
# ============================================================

# legitimate=0（success 相当）+ terminal ラベル → success が抑止される
reset_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"codex-failed"}]}'
adj_apply_status_decision 200 "$VALID_SHA" 0 "https://x/pr/200" "codex/issue-145-impl-foo" || true
assert_eq "adjudicator 経路: legitimate=0 + terminal → success publish ゼロ" "0" "$(publishes 'context=claude-review')"
assert_eq "adjudicator 経路: skip WARN 1 行" "1" "$(warns 'skip claude-review=success')"

# legitimate=0 + terminal ラベル無し → success publish（従来どおり）
reset_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"codex-ready-for-review"}]}'
adj_apply_status_decision 201 "$VALID_SHA" 0 "https://x/pr/201" "codex/issue-145-impl-foo" || true
assert_eq "adjudicator 経路: terminal 無し → success を publish" "1" "$(publishes 'context=claude-review state=success')"

# legitimate>=1（failure）は terminal でも publish（gate を閉じる方向）
reset_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"codex-failed"}]}'
adj_apply_status_decision 202 "$VALID_SHA" 2 "https://x/pr/202" "codex/issue-145-impl-foo" || true
assert_eq "adjudicator 経路: legitimate>=1 は terminal でも failure を publish" "1" "$(publishes 'context=claude-review state=failure')"

# ============================================================
echo ""
echo "=================================================="
echo "RESULT: PASS=$PASS FAIL=$FAIL"
echo "=================================================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
