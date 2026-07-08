#!/usr/bin/env bash
#
# 用途: PR Iteration out-of-scope 第 3 判定 (#146 / idd-claude #437 移植) の adjudicator 側
#       関数群を、shell 関数 stub（claude / gh / git / timeout / pi_route_out_of_scope_escalate）
#       で隔離検証するスモークテスト。
#
#       検証ケース:
#         Section A: adj_validate_decisions の 3 値 schema（gate ON）
#           (A.1) out-of-scope を含む 3 値 decisions + 3 値 summary → rc=0
#           (A.2) 未知 verdict（"maybe"）→ rc=1
#           (A.3) out-of-scope を含むのに summary が 2 値（out_of_scope 不在で total 不一致）→ rc=1
#           (A.4) summary.out_of_scope が verdict 件数と不一致 → rc=1
#           (A.5) 全件 legitimate/excessive + out_of_scope=0 → rc=0（3 値 gate でも 2 値応答を許容）
#         Section B: adj_validate_decisions の後方互換（gate OFF）
#           (B.1) 既存 2 値 decisions → rc=0（既存挙動バイト等価）
#           (B.2) out-of-scope を含む decisions → rc=1（schema 違反として拒否 = fail-safe）
#         Section C: round 不消費（legitimate 件数から out-of-scope を分離）
#           (C.1) adj_extract_legitimate_count が summary.legitimate のみを返す
#           (C.2) adj_extract_out_of_scope_count が summary.out_of_scope を返す
#           (C.3) 不正 JSON / フィールド不在は 0
#         Section D: adj_route_out_of_scope の委譲判定
#           (D.1) gate OFF → 委譲なし rc=0
#           (D.2) gate ON + out_of_scope=0 → 委譲なし rc=0
#           (D.3) gate ON + legitimate>=1 → 委譲なし rc=0（iteration 継続）
#           (D.4) gate ON + legitimate=0 + out_of_scope>=1 → pi_route_out_of_scope_escalate へ委譲
#           (D.5) 無効 PR 番号 / SHA → rc=2
#         Section E: prompt 注入（{OOS_INSTRUCTIONS} placeholder）
#           (E.1) gate ON → rendered prompt に分類規約ブロックが注入され placeholder 残骸なし
#           (E.2) gate OFF → placeholder 行が行ごと除去され、ブロックも注入されない
#
# 配置先: local-watcher/test/adj_out_of_scope_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/adj_out_of_scope_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADJ_SH="$SCRIPT_DIR/../bin/idd-codex-modules/adjudicator.sh"

if [ ! -f "$ADJ_SH" ]; then
  echo "ERROR: cannot find adjudicator.sh at $ADJ_SH" >&2
  exit 2
fi

# adjudicator.sh は関数定義のみのモジュール（副作用なし）のため、そのまま source する。
# adj_oos_prompt_block はヒアドキュメント内に列 0 の `}` を含み、既存テストの
# extract_function（awk 切り出し）では途中で打ち切られるため、本テストは module 全体を読む。
# shellcheck disable=SC1090
source "$ADJ_SH"

for fn in adj_oos_enabled adj_oos_prompt_block adj_validate_decisions \
          adj_extract_legitimate_count adj_extract_out_of_scope_count \
          adj_route_out_of_scope adj_classify_findings; do
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
ROUTE_CALL_LOG="$STATE_DIR/route.log"
PROMPT_CAPTURE="$STATE_DIR/prompt.txt"

reset_stub_state() {
  : > "$WARN_LOG"
  : > "$LOG_LOG"
  : > "$ROUTE_CALL_LOG"
  : > "$PROMPT_CAPTURE"
}

# shellcheck disable=SC2317
adj_warn() { echo "$*" >>"$WARN_LOG"; }
# shellcheck disable=SC2317
adj_log()  { echo "$*" >>"$LOG_LOG"; }

# pi_route_out_of_scope_escalate stub: 呼び出し痕跡のみ記録
# shellcheck disable=SC2317
pi_route_out_of_scope_escalate() {
  echo "route $1 $2 $4 $5" >>"$ROUTE_CALL_LOG"
  return 0
}

# timeout stub: 最初の引数（秒数）を捨てて残りを実行
# shellcheck disable=SC2317
timeout() {
  shift
  "$@"
}

# claude stub: -p の次の引数（rendered prompt）を capture し、canned 3 値 JSON を返す
# shellcheck disable=SC2317
claude() {
  local prev=""
  local arg
  for arg in "$@"; do
    if [ "$prev" = "-p" ]; then
      printf '%s' "$arg" >"$PROMPT_CAPTURE"
    fi
    prev="$arg"
  done
  printf '%s' '{"type":"result","subtype":"success","result":"{\"decisions\":[{\"id\":1,\"severity\":\"low\",\"file\":\"a.sh\",\"line\":1,\"verdict\":\"legitimate\",\"reason\":\"x\"}],\"summary\":{\"total\":1,\"legitimate\":1,\"excessive\":0}}"}'
  return 0
}

# git stub: read-only invariant 検査（status --porcelain）を常にクリーンで返す
# shellcheck disable=SC2317
git() {
  case "${1:-}" in
    status) return 0 ;;
    *) return 0 ;;
  esac
}

export REPO="owner/test-repo"

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

assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  case "$haystack" in
    *"$needle"*)
      echo "PASS: $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
    *)
      echo "FAIL: $label"
      echo "  needle  : $(printf '%q' "$needle")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
  esac
}

assert_not_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  case "$haystack" in
    *"$needle"*)
      echo "FAIL: $label"
      echo "  should not contain: $(printf '%q' "$needle")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
    *)
      echo "PASS: $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
  esac
}

VALID_SHA="abcdef0123456789abcdef0123456789abcdef01"

# 共通 fixture
FINDINGS_3='[
  {"severity":"high","file":"a.sh","line":10,"message":"m1"},
  {"severity":"low","file":"b.sh","line":20,"message":"m2"},
  {"severity":"medium","file":"c.sh","line":30,"message":"m3"}
]'
DECISIONS_3VAL='{
  "decisions": [
    {"id":1,"severity":"high","file":"a.sh","line":10,"verdict":"legitimate","reason":"r1"},
    {"id":2,"severity":"low","file":"b.sh","line":20,"verdict":"excessive","reason":"r2"},
    {"id":3,"severity":"medium","file":"c.sh","line":30,"verdict":"out-of-scope","reason":"r3"}
  ],
  "summary": {"total":3,"legitimate":1,"excessive":1,"out_of_scope":1}
}'

echo "--- Section A: adj_validate_decisions 3 値 schema（gate ON） ---"

export PR_ITERATION_OOS_ENABLED="true"

# A.1: 正常 3 値
reset_stub_state
rc=0
adj_validate_decisions "$FINDINGS_3" "$DECISIONS_3VAL" || rc=$?
assert_eq "A.1: gate ON で out-of-scope を含む 3 値 decisions は valid (rc=0)" "0" "$rc"

# A.2: 未知 verdict は拒否
reset_stub_state
rc=0
adj_validate_decisions "$FINDINGS_3" "$(printf '%s' "$DECISIONS_3VAL" | jq -c '.decisions[2].verdict = "maybe"')" || rc=$?
assert_eq "A.2: gate ON でも未知 verdict 'maybe' は invalid (rc=1)" "1" "$rc"

# A.3: out-of-scope を含むのに summary が 2 値（out_of_scope キー不在）→ 集計不整合
reset_stub_state
rc=0
adj_validate_decisions "$FINDINGS_3" "$(printf '%s' "$DECISIONS_3VAL" | jq -c 'del(.summary.out_of_scope)')" || rc=$?
assert_eq "A.3: out-of-scope 混在 + summary 2 値（legitimate+excessive != total）は invalid (rc=1)" "1" "$rc"

# A.4: summary.out_of_scope が verdict 件数と不一致
reset_stub_state
rc=0
adj_validate_decisions "$FINDINGS_3" "$(printf '%s' "$DECISIONS_3VAL" | jq -c '.summary.out_of_scope = 2 | .summary.legitimate = 0')" || rc=$?
assert_eq "A.4: summary.out_of_scope の集計不一致は invalid (rc=1)" "1" "$rc"

# A.5: 3 値 gate でも従来 2 値応答（out_of_scope キー不在 / OOS verdict なし）を許容
reset_stub_state
rc=0
adj_validate_decisions "$FINDINGS_3" '{
  "decisions": [
    {"id":1,"verdict":"legitimate","reason":"r1"},
    {"id":2,"verdict":"excessive","reason":"r2"},
    {"id":3,"verdict":"legitimate","reason":"r3"}
  ],
  "summary": {"total":3,"legitimate":2,"excessive":1}
}' || rc=$?
assert_eq "A.5: gate ON でも従来 2 値応答は valid (rc=0)" "0" "$rc"

echo "--- Section B: adj_validate_decisions 後方互換（gate OFF） ---"

export PR_ITERATION_OOS_ENABLED="false"

# B.1: 既存 2 値
reset_stub_state
rc=0
adj_validate_decisions "$FINDINGS_3" '{
  "decisions": [
    {"id":1,"verdict":"legitimate","reason":"r1"},
    {"id":2,"verdict":"excessive","reason":"r2"},
    {"id":3,"verdict":"legitimate","reason":"r3"}
  ],
  "summary": {"total":3,"legitimate":2,"excessive":1}
}' || rc=$?
assert_eq "B.1: gate OFF で既存 2 値 decisions は valid (rc=0)" "0" "$rc"

# B.2: gate OFF では out-of-scope は schema 違反
reset_stub_state
rc=0
adj_validate_decisions "$FINDINGS_3" "$DECISIONS_3VAL" || rc=$?
assert_eq "B.2: gate OFF で out-of-scope を含む decisions は invalid (rc=1 = fail-safe)" "1" "$rc"

echo "--- Section C: round 不消費（legitimate / out_of_scope 分離） ---"

export PR_ITERATION_OOS_ENABLED="true"

assert_eq "C.1: adj_extract_legitimate_count は out-of-scope を除外した summary.legitimate を返す" \
  "1" "$(adj_extract_legitimate_count "$DECISIONS_3VAL")"
assert_eq "C.2: adj_extract_out_of_scope_count は summary.out_of_scope を返す" \
  "1" "$(adj_extract_out_of_scope_count "$DECISIONS_3VAL")"
assert_eq "C.3a: 不正 JSON は 0 (legitimate)" "0" "$(adj_extract_legitimate_count 'not-json')"
assert_eq "C.3b: フィールド不在は 0 (out_of_scope)" \
  "0" "$(adj_extract_out_of_scope_count '{"summary":{"total":1,"legitimate":1,"excessive":0}}')"

echo "--- Section D: adj_route_out_of_scope の委譲判定 ---"

# D.1: gate OFF → 委譲なし
export PR_ITERATION_OOS_ENABLED="false"
reset_stub_state
rc=0
adj_route_out_of_scope "404" "$VALID_SHA" "0" "1" "$DECISIONS_3VAL" || rc=$?
assert_eq "D.1: gate OFF は no-op (rc=0)" "0" "$rc"
assert_eq "D.1: gate OFF は委譲しない" "0" "$(wc -l <"$ROUTE_CALL_LOG")"

export PR_ITERATION_OOS_ENABLED="true"

# D.2: out_of_scope=0 → 委譲なし
reset_stub_state
rc=0
adj_route_out_of_scope "404" "$VALID_SHA" "0" "0" "$DECISIONS_3VAL" || rc=$?
assert_eq "D.2: out_of_scope=0 は no-op (rc=0)" "0" "$rc"
assert_eq "D.2: out_of_scope=0 は委譲しない" "0" "$(wc -l <"$ROUTE_CALL_LOG")"

# D.3: legitimate>=1 → 委譲なし（iteration 継続）
reset_stub_state
rc=0
adj_route_out_of_scope "404" "$VALID_SHA" "2" "1" "$DECISIONS_3VAL" || rc=$?
assert_eq "D.3: legitimate>=1 は還流せず iteration 継続 (rc=0)" "0" "$rc"
assert_eq "D.3: legitimate>=1 は委譲しない" "0" "$(wc -l <"$ROUTE_CALL_LOG")"
assert_contains "D.3: route=continue を観測ログに残す" "route=continue" "$(cat "$LOG_LOG")"

# D.4: legitimate=0 + out_of_scope>=1 → 委譲
reset_stub_state
rc=0
adj_route_out_of_scope "404" "$VALID_SHA" "0" "1" "$DECISIONS_3VAL" || rc=$?
assert_eq "D.4: legitimate=0 + oos>=1 は委譲する (rc=0)" "0" "$rc"
assert_eq "D.4: pi_route_out_of_scope_escalate へ 1 回委譲" "1" "$(wc -l <"$ROUTE_CALL_LOG")"
assert_contains "D.4: 委譲引数（pr / sha / source=adjudicator / count）" \
  "route 404 ${VALID_SHA} adjudicator 1" "$(cat "$ROUTE_CALL_LOG")"

# D.5: 無効入力
reset_stub_state
rc=0
adj_route_out_of_scope "not-a-pr" "$VALID_SHA" "0" "1" "$DECISIONS_3VAL" || rc=$?
assert_eq "D.5a: 無効 PR 番号は rc=2" "2" "$rc"
reset_stub_state
rc=0
adj_route_out_of_scope "404" "NOT_A_SHA" "0" "1" "$DECISIONS_3VAL" || rc=$?
assert_eq "D.5b: 無効 SHA は rc=2" "2" "$rc"

echo "--- Section E: prompt 注入（{OOS_INSTRUCTIONS} placeholder） ---"

# 最小 template（placeholder 行を含む）を env override で注入
TEST_TMPL='HEADER 保守的に判定してください。
{OOS_INSTRUCTIONS}
## 全指摘に 1:1 対応する義務'
export PR_REVIEWER_ADJUDICATOR_PROMPT="$TEST_TMPL"
FINDINGS_1='[{"severity":"high","file":"a.sh","line":10,"message":"m1"}]'

# E.1: gate ON → 分類規約ブロックが注入される
export PR_ITERATION_OOS_ENABLED="true"
reset_stub_state
rc=0
adj_classify_findings "404" "$VALID_SHA" "$FINDINGS_1" "" "main" "codex/issue-404-impl-x" >/dev/null || rc=$?
assert_eq "E.1: gate ON で adj_classify_findings が成功する (rc=0)" "0" "$rc"
captured=$(cat "$PROMPT_CAPTURE")
assert_contains "E.1: rendered prompt に out-of-scope 分類規約が注入される" \
  "## out-of-scope（第 3 判定）の分類規約（本機能が有効です）" "$captured"
assert_contains "E.1: rendered prompt に summary.out_of_scope 出力契約が含まれる" \
  '"out_of_scope"' "$captured"
assert_not_contains "E.1: placeholder 残骸が無い" "{OOS_INSTRUCTIONS}" "$captured"

# E.2: gate OFF → placeholder 行ごと除去され、ブロックも注入されない
export PR_ITERATION_OOS_ENABLED="false"
reset_stub_state
rc=0
adj_classify_findings "404" "$VALID_SHA" "$FINDINGS_1" "" "main" "codex/issue-404-impl-x" >/dev/null || rc=$?
assert_eq "E.2: gate OFF で adj_classify_findings が成功する (rc=0)" "0" "$rc"
captured=$(cat "$PROMPT_CAPTURE")
assert_not_contains "E.2: placeholder 残骸が無い" "{OOS_INSTRUCTIONS}" "$captured"
assert_not_contains "E.2: out-of-scope 分類規約が注入されない" \
  "out-of-scope（第 3 判定）の分類規約" "$captured"
expected_off='HEADER 保守的に判定してください。
## 全指摘に 1:1 対応する義務'
assert_eq "E.2: gate OFF の rendered prompt は placeholder 行を除去した本文と一致" \
  "$expected_off" "$captured"

echo ""
echo "RESULT: PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
