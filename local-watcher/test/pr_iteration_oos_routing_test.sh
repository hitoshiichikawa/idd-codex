#!/usr/bin/env bash
#
# 用途: PR Iteration out-of-scope 第 3 判定 (#146 / idd-claude #437 移植) の還流ルーティング側
#       関数群（pi_general_filter_oos / pi_route_out_of_scope_escalate）を shell 関数 stub
#       （gh / timeout）で隔離検証するスモークテスト。
#
#       検証ケース:
#         Section A: pi_general_filter_oos（iteration 入力からの除外）
#           (A.1) gate OFF → pass-through（既存件数挙動を維持）
#           (A.2) gate ON → out-of-scope marker 付きコメントのみ除外
#           (A.3) gate ON でも adjudicator summary marker / excessive marker は素通し
#                 （部分一致・prefix 衝突なし）
#           (A.4) gate ON + 空配列 → 空配列（空入力）
#           (A.5) typo gate 値（"True"）→ pass-through（安全側 OFF）
#         Section B: pi_route_out_of_scope_escalate（還流本体）
#           (B.1) gate OFF → no-op rc=0（gh 呼び出しゼロ）
#           (B.2) 無効 PR 番号 / SHA → rc=2（gh 呼び出しゼロ）
#           (B.3) 正常経路 → needs-iteration 除去 + needs-decisions 付与 + 冪等 marker 付き
#                 追跡コメント投稿 + 観測ログ 1 行
#           (B.4) 冪等: 既存コメントに同一 sha の routed marker → skip（ラベル操作なし）
#           (B.5) PR_ITERATION_OOS_ROUTE 未知値（spawn-issue 等）→ needs-decisions に正規化
#           (B.6) ラベル操作失敗 → WARN を残しつつ rc=0（silent fail しない / 安全側）
#
# 配置先: local-watcher/test/pr_iteration_oos_routing_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/pr_iteration_oos_routing_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_ITERATION_SH="$SCRIPT_DIR/../bin/idd-codex-modules/pr-iteration.sh"

if [ ! -f "$PR_ITERATION_SH" ]; then
  echo "ERROR: cannot find pr-iteration.sh at $PR_ITERATION_SH" >&2
  exit 2
fi

extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

for fn in pi_general_filter_oos pi_route_out_of_scope_escalate; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$PR_ITERATION_SH" "$fn")"
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# ── stub state ──
STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT
WARN_LOG="$STATE_DIR/warn.log"
LOG_LOG="$STATE_DIR/log.log"
GH_CALL_LOG="$STATE_DIR/gh.log"
GH_VIEW_BODY_FILE="$STATE_DIR/view_body.txt"
GH_COMMENTS_FILE="$STATE_DIR/comments.txt"

reset_stub_state() {
  : > "$WARN_LOG"
  : > "$LOG_LOG"
  : > "$GH_CALL_LOG"
  : > "$GH_VIEW_BODY_FILE"
  : > "$GH_COMMENTS_FILE"
  GH_EDIT_RC=0
}

# shellcheck disable=SC2317
pi_warn() { echo "$*" >>"$WARN_LOG"; }
# shellcheck disable=SC2317
pi_log()  { echo "$*" >>"$LOG_LOG"; }

# timeout stub: 最初の引数（秒数）を捨てて残りを実行
# shellcheck disable=SC2317
timeout() {
  shift
  "$@"
}

# gh stub: 呼び出し痕跡を記録し、view body / comments を fixture から返す
# shellcheck disable=SC2317
gh() {
  echo "gh $*" >>"$GH_CALL_LOG"
  case "${1:-} ${2:-}" in
    "pr view")
      cat "$GH_VIEW_BODY_FILE"
      return 0
      ;;
    "pr edit")
      return "${GH_EDIT_RC:-0}"
      ;;
    "pr comment")
      return 0
      ;;
    "api /repos/"*)
      # --jq '.[].body' 経路: comments fixture（1 行 1 body）をそのまま流す
      cat "$GH_COMMENTS_FILE"
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

export REPO="owner/test-repo"
export LABEL_NEEDS_DECISIONS="codex-needs-decisions"
export LABEL_NEEDS_ITERATION="codex-needs-iteration"
export PR_ITERATION_GIT_TIMEOUT=5

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected: $(printf '%q' "$expected")"
    echo "  actual  : $(printf '%q' "$actual")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

count_calls() {
  local pattern="$1"
  local n
  n=$( { grep -F -- "$pattern" "$GH_CALL_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

VALID_SHA="abcdef0123456789abcdef0123456789abcdef01"

COMMENTS_JSON='[
  {"id":1,"body":"通常のレビューコメント"},
  {"id":2,"body":"## 自動裁定: out-of-scope\n\n<!-- idd-codex:pr-adjudicator-out-of-scope id=1 sha=abc123 -->"},
  {"id":3,"body":"## 自動裁定サマリ\n\n<!-- idd-codex:pr-adjudicator sha=abc123 kind=decision -->"},
  {"id":4,"body":"## 自動裁定: excessive\n\n<!-- idd-codex:pr-adjudicator-excessive id=2 sha=abc123 -->"}
]'

echo "--- Section A: pi_general_filter_oos ---"

# A.1: gate OFF → pass-through
export PR_ITERATION_OOS_ENABLED="false"
out=$(printf '%s' "$COMMENTS_JSON" | pi_general_filter_oos | jq 'length')
assert_eq "A.1: gate OFF は pass-through（4 件のまま）" "4" "$out"

# A.2: gate ON → oos marker 付きのみ除外
export PR_ITERATION_OOS_ENABLED="true"
out=$(printf '%s' "$COMMENTS_JSON" | pi_general_filter_oos | jq 'length')
assert_eq "A.2: gate ON は out-of-scope marker 付きコメントのみ除外（4→3 件）" "3" "$out"
out=$(printf '%s' "$COMMENTS_JSON" | pi_general_filter_oos | jq -r '[.[].id] | join(",")')
assert_eq "A.2: 除外されるのは id=2 のみ" "1,3,4" "$out"

# A.3: prefix 衝突なし（summary / excessive marker は素通し）→ A.2 の id=3,4 残存で担保済みだが
#      「pr-adjudicator-out-of-scope を含まない部分一致文字列」も明示検証する
out=$(printf '%s' '[{"id":9,"body":"idd-codex:pr-adjudicator-out-of-scop（末尾欠け偽装）"}]' \
  | pi_general_filter_oos | jq 'length')
assert_eq "A.3: marker 文字列の部分一致（末尾欠け）は除外しない" "1" "$out"

# A.4: 空配列
out=$(printf '%s' '[]' | pi_general_filter_oos | jq 'length')
assert_eq "A.4: 空配列入力は空配列のまま" "0" "$out"

# A.5: typo gate 値は安全側 pass-through
export PR_ITERATION_OOS_ENABLED="True"
out=$(printf '%s' "$COMMENTS_JSON" | pi_general_filter_oos | jq 'length')
assert_eq "A.5: gate 値 'True'（typo）は pass-through（安全側 OFF）" "4" "$out"

echo "--- Section B: pi_route_out_of_scope_escalate ---"

DECISIONS_OOS='{
  "decisions": [
    {"id":3,"severity":"medium","file":"c.sh","line":30,"verdict":"out-of-scope","reason":"design.md の確定契約と矛盾"}
  ],
  "summary": {"total":1,"legitimate":0,"excessive":0,"out_of_scope":1}
}'

# B.1: gate OFF → no-op
export PR_ITERATION_OOS_ENABLED="false"
reset_stub_state
rc=0
pi_route_out_of_scope_escalate "404" "$VALID_SHA" "$DECISIONS_OOS" "adjudicator" "1" || rc=$?
assert_eq "B.1: gate OFF は no-op (rc=0)" "0" "$rc"
assert_eq "B.1: gate OFF は gh を一切呼ばない" "0" "$(wc -l <"$GH_CALL_LOG")"

export PR_ITERATION_OOS_ENABLED="true"

# B.2: 無効入力
reset_stub_state
rc=0
pi_route_out_of_scope_escalate "404; rm -rf /" "$VALID_SHA" "$DECISIONS_OOS" "adjudicator" "1" || rc=$?
assert_eq "B.2a: 無効 PR 番号は rc=2" "2" "$rc"
assert_eq "B.2a: 無効 PR 番号では gh を呼ばない" "0" "$(wc -l <"$GH_CALL_LOG")"
reset_stub_state
rc=0
pi_route_out_of_scope_escalate "404" "--flag-injection" "$DECISIONS_OOS" "adjudicator" "1" || rc=$?
assert_eq "B.2b: 無効 SHA は rc=2" "2" "$rc"
assert_eq "B.2b: 無効 SHA では gh を呼ばない" "0" "$(wc -l <"$GH_CALL_LOG")"

# B.3: 正常経路
export PR_ITERATION_OOS_ROUTE="needs-decisions"
reset_stub_state
rc=0
pi_route_out_of_scope_escalate "404" "$VALID_SHA" "$DECISIONS_OOS" "adjudicator" "1" || rc=$?
assert_eq "B.3: 正常経路は rc=0" "0" "$rc"
assert_eq "B.3: needs-iteration 除去を 1 回呼ぶ" "1" "$(count_calls "--remove-label codex-needs-iteration")"
assert_eq "B.3: needs-decisions 付与を 1 回呼ぶ" "1" "$(count_calls "--add-label codex-needs-decisions")"
assert_eq "B.3: 追跡コメント（冪等 marker 付き）を 1 回投稿する" \
  "1" "$(count_calls "idd-codex:pr-iteration-oos-routed sha=${VALID_SHA}")"
assert_eq "B.3: 追跡コメントに判定根拠（reason）を並べる" \
  "1" "$(count_calls "design.md の確定契約と矛盾")"
assert_eq "B.3: 観測ログに reason=out-of-scope route=needs-decisions を 1 行残す" \
  "1" "$( { grep -c -- "reason=out-of-scope route=needs-decisions" "$LOG_LOG" || true; } )"

# B.4: 冪等 skip（既存コメントに routed marker）
reset_stub_state
printf '%s\n' "<!-- idd-codex:pr-iteration-oos-routed sha=${VALID_SHA} -->" >"$GH_COMMENTS_FILE"
rc=0
pi_route_out_of_scope_escalate "404" "$VALID_SHA" "$DECISIONS_OOS" "adjudicator" "1" || rc=$?
assert_eq "B.4: 既 routed sha は skip (rc=0)" "0" "$rc"
assert_eq "B.4: skip 時はラベル操作しない" "0" "$(count_calls "pr edit")"
assert_eq "B.4: skip 時はコメント投稿しない" "0" "$(count_calls "pr comment")"
assert_eq "B.4: skip の観測ログを残す" \
  "1" "$( { grep -c -- "action=skip-already-routed" "$LOG_LOG" || true; } )"

# B.5: PR_ITERATION_OOS_ROUTE 未知値 / 予約値は needs-decisions に正規化
export PR_ITERATION_OOS_ROUTE="spawn-issue"
reset_stub_state
rc=0
pi_route_out_of_scope_escalate "404" "$VALID_SHA" "$DECISIONS_OOS" "content-no-progress" "?" || rc=$?
assert_eq "B.5: route=spawn-issue（予約値）でも rc=0" "0" "$rc"
assert_eq "B.5: needs-decisions ラベルに正規化される" "1" "$(count_calls "--add-label codex-needs-decisions")"
assert_eq "B.5: 観測ログの route も needs-decisions" \
  "1" "$( { grep -c -- "route=needs-decisions" "$LOG_LOG" || true; } )"
export PR_ITERATION_OOS_ROUTE="needs-decisions"

# B.6: ラベル操作失敗でも WARN + rc=0（silent fail しない）
reset_stub_state
GH_EDIT_RC=1
rc=0
pi_route_out_of_scope_escalate "404" "$VALID_SHA" "$DECISIONS_OOS" "adjudicator" "1" || rc=$?
assert_eq "B.6: ラベル操作失敗でも rc=0（既存挙動据え置きの安全側）" "0" "$rc"
warn_count=$( { grep -c -- "付与失敗" "$WARN_LOG" || true; } )
assert_eq "B.6: ラベル付与失敗の WARN を残す" "1" "$warn_count"

echo ""
echo "RESULT: PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
