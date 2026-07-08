#!/usr/bin/env bash
#
# 用途: Issue #145 Defect B（terminal ラベル付き PR への claude-review=success の
#       fail-closed 化 / idd-claude #434 移植）で local-watcher/bin/idd-codex-modules/
#       pr-reviewer.sh の pr_publish_claude_status に追加した success 公開直前ガードを
#       fixture と gh stub で検証するスモークテスト。
#
#       対象関数:
#         - pr_publish_claude_status（2nd gate 経路 / catch 全 publish の唯一の publisher）
#         - adj_apply_status_decision（adjudicator 経路 → pr_publish_claude_status への
#           集約でガードが自動適用されることの統合確認）
#
#       検証観点:
#         - codex-failed 付き PR への success → publish しない（fail-closed + WARN）
#         - codex-needs-decisions 付き PR への success → publish しない
#         - terminal ラベル無し → 従来どおり approve=success / それ以外=failure を publish
#         - reject（failure）は terminal でも publish 継続（gate を閉じる方向は妨げない）
#         - ラベル再取得失敗時は従来どおり publish 継続（fail-open）+ WARN 1 行
#         - status-check gate OFF 時はガードの gh pr view も呼ばない（idd-claude #482 相当）
#         - adjudicator 経路（adj_apply_status_decision）でも terminal なら success 抑止
#
# 配置先: local-watcher/test/pr_reviewer_claude_status_fail_closed_test.sh
# 依存:   bash 4+, awk, grep, jq, mktemp
# 実行:   bash local-watcher/test/pr_reviewer_claude_status_fail_closed_test.sh

set -euo pipefail
# shellcheck disable=SC2034  # eval で抽出した関数が遅延束縛で参照する変数をこのテスト内で定義する。

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
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$ADJ_MOD" "adj_apply_status_decision")"

for fn in pr_publish_claude_status adj_apply_status_decision; do
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done

# ─── 環境 / stub ───
export REPO="owner/repo"
# shellcheck disable=SC2034  # eval 抽出関数が遅延束縛で参照する
LABEL_FAILED="codex-failed"
# shellcheck disable=SC2034  # eval 抽出関数が遅延束縛で参照する
LABEL_NEEDS_DECISIONS="codex-needs-decisions"
export PR_REVIEWER_GIT_TIMEOUT=5

WARN_OUT=""; PUBLISH_CALL_LOG=""; GH_CALL_LOG=""
GH_PR_VIEW_LABELS='{"labels":[]}'
GH_PR_VIEW_RC=0
STATUS_CHECK_GATE_RC=0   # 0 = gate ON / 1 = gate OFF（#482 相当の inert 検証用）

reset_state() {
  WARN_OUT="$(mktemp)"; PUBLISH_CALL_LOG="$(mktemp)"; GH_CALL_LOG="$(mktemp)"
  GH_PR_VIEW_LABELS='{"labels":[]}'
  GH_PR_VIEW_RC=0
  STATUS_CHECK_GATE_RC=0
}

# shellcheck disable=SC2317
pr_warn() { printf '%s\n' "$*" >>"$WARN_OUT"; }
# shellcheck disable=SC2317
pr_log()  { :; }
# shellcheck disable=SC2317
adj_warn() { printf '%s\n' "$*" >>"$WARN_OUT"; }
# shellcheck disable=SC2317
adj_log()  { :; }

# timeout を no-op に（第 1 引数の秒数を捨てて後続を実行）
# shellcheck disable=SC2317
timeout() { shift; "$@"; }

# status-check gate stub（STATUS_CHECK_GATE_RC で ON/OFF を制御）
# shellcheck disable=SC2317
pr_status_check_enabled() { return "$STATUS_CHECK_GATE_RC"; }

# gh stub: gh pr view --json labels の応答を制御 + 呼び出しを観測
# shellcheck disable=SC2317
gh() {
  printf 'gh %s\n' "$*" >>"$GH_CALL_LOG"
  if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
    [ "$GH_PR_VIEW_RC" -ne 0 ] && return "$GH_PR_VIEW_RC"
    printf '%s' "$GH_PR_VIEW_LABELS"
    return 0
  fi
  return 0
}

# pr_publish_commit_status stub: 呼び出しと引数を記録（実 publish が走ったかの観測）
# shellcheck disable=SC2317
pr_publish_commit_status() {
  # $1=pr_number $2=sha $3=context $4=state $5=description $6=target_url
  printf 'publish pr=%s context=%s state=%s\n' "$1" "$3" "$4" >>"$PUBLISH_CALL_LOG"
  return 0
}

# adjudicator 経路用: Reviewer verdict stub（既定は approve 相当の空）
ADJ_REVIEWER_VERDICT=""
# shellcheck disable=SC2317
adj_read_reviewer_verdict() { printf '%s\n' "$ADJ_REVIEWER_VERDICT"; }

count_publish() { grep -c -E -- "$1" "$PUBLISH_CALL_LOG" 2>/dev/null || true; }
count_warn()    { grep -c -E -- "$1" "$WARN_OUT" 2>/dev/null || true; }
count_gh()      { grep -c -E -- "$1" "$GH_CALL_LOG" 2>/dev/null || true; }

PASS=0; FAIL=0
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label (expected='$expected' actual='$actual')"; FAIL=$((FAIL + 1))
  fi
}

VALID_SHA="0123456789abcdef0123456789abcdef01234567"

# ============================================================
# Section 1: terminal ラベル付き PR への success → fail-closed
# ============================================================
echo "--- Section 1: terminal ラベル付き success の fail-closed ---"

reset_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"codex-failed"}]}'
pr_publish_claude_status 100 "$VALID_SHA" approve "https://example.com/pr/100"
assert_eq "codex-failed 付き → success publish ゼロ（fail-closed）" "0" "$(count_publish 'context=claude-review')"
assert_eq "skip 時に WARN 1 行を残す" "1" "$(count_warn 'terminal label.*skip claude-review=success')"

reset_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"codex-needs-decisions"}]}'
pr_publish_claude_status 101 "$VALID_SHA" approve ""
assert_eq "codex-needs-decisions 付き → success publish ゼロ" "0" "$(count_publish 'context=claude-review')"

reset_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"codex-failed"},{"name":"codex-needs-decisions"}]}'
pr_publish_claude_status 102 "$VALID_SHA" approve ""
assert_eq "両 terminal ラベル → success publish ゼロ" "0" "$(count_publish 'context=claude-review')"

# ============================================================
# Section 2: terminal ラベル無しの通常経路（後方互換）
# ============================================================
echo ""
echo "--- Section 2: terminal ラベル無しの通常 publish ---"

reset_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"codex-ready-for-review"}]}'
pr_publish_claude_status 103 "$VALID_SHA" approve ""
assert_eq "terminal ラベル無し → success を publish（従来どおり）" "1" "$(count_publish 'context=claude-review state=success')"

reset_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"codex-failed"}]}'
pr_publish_claude_status 104 "$VALID_SHA" iteration ""
assert_eq "reject(failure) は terminal でも publish（ガードは success 経路のみ）" "1" "$(count_publish 'context=claude-review state=failure')"
assert_eq "failure 経路では gh pr view ラベル再取得を行わない" "0" "$(count_gh '^gh pr view')"

# ============================================================
# Section 3: ラベル再取得失敗時の fail-open
# ============================================================
echo ""
echo "--- Section 3: ラベル再取得失敗時の fail-open ---"

reset_state
GH_PR_VIEW_RC=1
pr_publish_claude_status 105 "$VALID_SHA" approve ""
assert_eq "ラベル再取得失敗 → success を従来どおり publish（fail-open）" "1" "$(count_publish 'context=claude-review state=success')"
assert_eq "ラベル再取得失敗時に WARN 1 行を残す" "1" "$(count_warn 'terminal ラベル再取得に失敗')"

# ============================================================
# Section 4: status-check gate OFF 時の inert（idd-claude #482 相当）
# ============================================================
echo ""
echo "--- Section 4: gate OFF 時はガードの gh 呼び出しもゼロ ---"

reset_state
STATUS_CHECK_GATE_RC=1
GH_PR_VIEW_LABELS='{"labels":[{"name":"codex-failed"}]}'
pr_publish_claude_status 106 "$VALID_SHA" approve ""
assert_eq "gate OFF: ガードの gh pr view を呼ばない（外部呼び出しゼロ）" "0" "$(count_gh '^gh pr view')"
# gate OFF 時は後段 pr_publish_commit_status（実物）が publish 自体を抑止する。
# 本テストの stub は抑止しないため、ガードを素通りして後段へ到達することのみ確認する。
assert_eq "gate OFF: ガードは skip 判定せず後段へ委譲" "1" "$(count_publish 'context=claude-review state=success')"

# ============================================================
# Section 5: adjudicator 経路（adj_apply_status_decision）への自動波及
# ============================================================
echo ""
echo "--- Section 5: adjudicator 経路の fail-closed 波及 ---"

# legitimate=0（success 導出）+ terminal ラベル → success 抑止
reset_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"codex-failed"}]}'
ADJ_REVIEWER_VERDICT=""
adj_apply_status_decision 107 "$VALID_SHA" 0 "https://example.com/pr/107" "codex/issue-145-impl-foo" || true
assert_eq "adjudicator 経路: terminal + legitimate=0 → success publish ゼロ" "0" "$(count_publish 'context=claude-review')"
assert_eq "adjudicator 経路: skip WARN 1 行" "1" "$(count_warn 'terminal label.*skip claude-review=success')"

# legitimate=0 + terminal ラベル無し → success publish（従来どおり）
reset_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"codex-ready-for-review"}]}'
ADJ_REVIEWER_VERDICT=""
adj_apply_status_decision 108 "$VALID_SHA" 0 "https://example.com/pr/108" "codex/issue-145-impl-foo" || true
assert_eq "adjudicator 経路: terminal 無し → success publish（従来どおり）" "1" "$(count_publish 'context=claude-review state=success')"

# legitimate>0（failure 導出）+ terminal ラベル → failure はそのまま publish
reset_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"codex-failed"}]}'
ADJ_REVIEWER_VERDICT=""
adj_apply_status_decision 109 "$VALID_SHA" 2 "https://example.com/pr/109" "codex/issue-145-impl-foo" || true
assert_eq "adjudicator 経路: terminal でも failure は publish 継続" "1" "$(count_publish 'context=claude-review state=failure')"

echo ""
echo "=================================================="
echo "RESULT: PASS=$PASS FAIL=$FAIL"
echo "=================================================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
