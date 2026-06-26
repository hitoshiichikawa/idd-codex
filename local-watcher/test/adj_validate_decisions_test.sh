#!/usr/bin/env bash
#
# 用途: PR Reviewer Adjudicator (#404) の classify / validate 関数
#       `adj_classify_findings` / `adj_validate_decisions` の挙動を、
#       PATH 経由の stub claude / stub jq でない実 jq を使って検証するスモークテスト。
#
#       検証する受入基準（docs/specs/404-feat-pr-reviewer-codex-advisory-claude-a/requirements.md）:
#         - Req 1.1 各指摘を legitimate/excessive に分類した結果を生成する
#         - Req 1.4 確信が持てない / parse 失敗時は legitimate に倒す（fail-safe は
#                  呼び出し元責務だが、本テストでは「adj_validate_decisions が invalid を
#                  rc=1 で報告し、呼び出し元 sentinel を起動できる」ことを担保）
#         - Req 1.5 全指摘に分類 + 根拠を 1:1 対応（件数一致 / schema 検証）
#
#       検証ケース:
#         adj_classify_findings:
#           (1) legitimate-only: findings 2 件 → decisions 2 件 verdict=legitimate, rc=0
#           (2) excessive-only:  findings 2 件 → decisions 2 件 verdict=excessive,  rc=0
#           (3) mixed:           findings 3 件 → decisions 3 件 verdict 混在,        rc=0
#           (4) JSON parse 失敗: stub claude が散文のみを返す → rc=2
#           (5) findings 空配列 `[]` 早期 return → rc=0, decisions=[]
#         adj_validate_decisions:
#           (A) 件数一致 + 全 verdict 妥当 → rc=0
#           (B) 件数不一致 → rc=1
#           (C) verdict 値が legitimate|excessive 以外 → rc=1
#           (D) summary 集計と decisions verdict 集計が不整合 → rc=1
#           (E) findings 空 + decisions 空 → rc=0
#           (F) findings 空 + decisions 1 件 → rc=1
#
# 配置先: local-watcher/test/adj_validate_decisions_test.sh
# 依存:   bash 4+, awk, jq, mktemp, git
# 実行:   bash local-watcher/test/adj_validate_decisions_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADJ_SH="$SCRIPT_DIR/../bin/idd-codex-modules/adjudicator.sh"

if [ ! -f "$ADJ_SH" ]; then
  echo "ERROR: cannot find adjudicator.sh at $ADJ_SH" >&2
  exit 2
fi

# adj_warn は core_utils.sh 配置だが、本テストは関数を隔離抽出するため stub で潰す。
# adj_classify_findings / adj_validate_decisions は WARN を stderr に出すが、test 結果
# 観測には影響しない。
adj_warn() {
  echo "STUB adj_warn: $*" >&2
}

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

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$ADJ_SH" "adj_classify_findings")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$ADJ_SH" "adj_validate_decisions")"

for fn in adj_classify_findings adj_validate_decisions; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# adj_warn が core_utils.sh 由来で $REPO を参照する可能性に備えて、stub 用 REPO を設定。
export REPO="test/test"

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

# ─── stub claude PATH 戦略 ───
# stub claude を PATH 先頭の tempdir に置き、`claude --output-format json ...` 呼び出しを
# stub に差し替える（方法 A / 本番コードへの env 注入を回避）。stub は $STUB_CLAUDE_OUTPUT
# に指定された JSON ファイルを cat する。
TMP_BIN=$(mktemp -d)
trap 'rm -rf "$TMP_BIN" 2>/dev/null || true' EXIT

cat > "$TMP_BIN/claude" <<'CLAUDE_STUB_EOF'
#!/usr/bin/env bash
# stub claude: --output-format json を期待する側へ canned JSON を cat する。
# STUB_CLAUDE_OUTPUT に「実物 claude --output-format json 出力相当の JSON が入った
# ファイル」のパスをセットしておく。STUB_CLAUDE_RC でリターンコードを制御可能。
if [ -n "${STUB_CLAUDE_OUTPUT:-}" ] && [ -f "${STUB_CLAUDE_OUTPUT}" ]; then
  cat "${STUB_CLAUDE_OUTPUT}"
fi
exit "${STUB_CLAUDE_RC:-0}"
CLAUDE_STUB_EOF
chmod +x "$TMP_BIN/claude"

# stub timeout: 第 1 引数（秒）を捨てて残りを exec
cat > "$TMP_BIN/timeout" <<'TIMEOUT_STUB_EOF'
#!/usr/bin/env bash
shift
exec "$@"
TIMEOUT_STUB_EOF
chmod +x "$TMP_BIN/timeout"

# stub git: status / checkout を no-op に潰す（adj_classify_findings の read-only invariant
# 検査で `git status --porcelain` を呼ぶが、テスト環境のワークツリー状態は無視したい）
cat > "$TMP_BIN/git" <<'GIT_STUB_EOF'
#!/usr/bin/env bash
case "${1:-}" in
  status)
    # 常に clean を装う（stdout 空）
    exit 0
    ;;
  checkout)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
GIT_STUB_EOF
chmod +x "$TMP_BIN/git"

export PATH="$TMP_BIN:$PATH"

# stub idd-codex-adjudicator-prompt.tmpl: classify 関数は
# $HOME/bin/idd-codex-adjudicator-prompt.tmpl を読むので HOME を tempdir に上書きして
# ダミー tmpl を配置する（PR_REVIEWER_ADJUDICATOR_PROMPT env でも上書き可能だが、tmpl path
# 解決経路の正常動作も同時に確認するため両方の経路を試す）。
mkdir -p "$TMP_BIN/bin"
cat > "$TMP_BIN/bin/idd-codex-adjudicator-prompt.tmpl" <<'TMPL_EOF'
You are a stub adjudicator.
PR={PR} SHA={SHA} BASE={BASE} HEAD={HEAD}
SPEC={SPEC_DIR}
{REVIEW_TEXT}
{REQUIREMENTS_MD}
TMPL_EOF
export HOME="$TMP_BIN"

# Issue env defaults（adj_classify_findings が参照）
export PR_REVIEWER_ADJUDICATOR_EXEC_TIMEOUT="300"
export PR_REVIEWER_ADJUDICATOR_MODEL="claude-sonnet-4-5"
unset PR_REVIEWER_ADJUDICATOR_PROMPT

# ─── helper: stub claude が返す JSON を構築 ─────────────────────────────
# 引数: $1 = embedded JSON 本文（result フィールド内に文字列として格納される）
# 出力: STUB_CLAUDE_OUTPUT に書き込んだファイルのパスを stdout に出す
build_claude_result_json() {
  local embedded="$1"
  local out
  out=$(mktemp)
  jq -n --arg result "$embedded" '{
    type: "result",
    subtype: "success",
    result: $result
  }' > "$out"
  printf '%s' "$out"
}

# ============================================================
# adj_classify_findings: Section A
# ============================================================

# 共通入力: 既に adj_extract_findings で得られた findings_json
FINDINGS_2=$(jq -nc '[
  {severity:"high",   file:"foo.sh", line:10, message:"重大バグ A"},
  {severity:"medium", file:"bar.sh", line:25, message:"警告 B"}
]')

FINDINGS_3=$(jq -nc '[
  {severity:"high",   file:"foo.sh", line:10, message:"バグ X"},
  {severity:"medium", file:"bar.sh", line:25, message:"提案 Y"},
  {severity:"low",    file:"baz.sh", line:100, message:"スタイル Z"}
]')

PR_NUMBER="404"
SHA="0123456789abcdef0123456789abcdef01234567"
SPEC_DIR_HINT=""    # tmpl 内の {SPEC_DIR} に `(none)` 埋め込み
BASE_REF="main"
HEAD_REF="codex/issue-404-impl-feat-pr-reviewer-codex-advisory-claude-a"

# ─── ケース (1): legitimate-only ───

echo "--- adj_classify_findings case 1: legitimate-only (Req 1.1, 1.5) ---"

# stub claude が「2 件とも legitimate」を返す
LEGITIMATE_ONLY_BODY=$(jq -nc '{
  decisions: [
    {id:1, severity:"high",   file:"foo.sh", line:10, verdict:"legitimate", reason:"AC 1.1 直結"},
    {id:2, severity:"medium", file:"bar.sh", line:25, verdict:"legitimate", reason:"後方互換破壊"}
  ],
  summary: {total:2, legitimate:2, excessive:0}
}')
STUB_CLAUDE_OUTPUT=$(build_claude_result_json "$LEGITIMATE_ONLY_BODY")
export STUB_CLAUDE_OUTPUT STUB_CLAUDE_RC=0

out=$(adj_classify_findings "$PR_NUMBER" "$SHA" "$FINDINGS_2" "$SPEC_DIR_HINT" "$BASE_REF" "$HEAD_REF" 2>/dev/null) && rc=0 || rc=$?

count=$(echo "$out" | jq -r '.decisions | length')
sev_concat=$(echo "$out" | jq -r '[.decisions[].verdict] | join(",")')
sum_legit=$(echo "$out" | jq -r '.summary.legitimate')
sum_excess=$(echo "$out" | jq -r '.summary.excessive')
sum_total=$(echo "$out" | jq -r '.summary.total')

assert_eq "Case 1 (legitimate-only): rc=0" "0" "$rc"
assert_eq "Case 1 (legitimate-only): decisions 件数=2" "2" "$count"
assert_eq "Case 1 (legitimate-only): verdict='legitimate,legitimate'" "legitimate,legitimate" "$sev_concat"
assert_eq "Case 1 (legitimate-only): summary.legitimate=2" "2" "$sum_legit"
assert_eq "Case 1 (legitimate-only): summary.excessive=0" "0" "$sum_excess"
assert_eq "Case 1 (legitimate-only): summary.total=2" "2" "$sum_total"

rm -f "$STUB_CLAUDE_OUTPUT"

# ─── ケース (2): excessive-only ───

echo "--- adj_classify_findings case 2: excessive-only (Req 1.1) ---"

EXCESSIVE_ONLY_BODY=$(jq -nc '{
  decisions: [
    {id:1, severity:"high",   file:"foo.sh", line:10, verdict:"excessive", reason:"重複指摘"},
    {id:2, severity:"medium", file:"bar.sh", line:25, verdict:"excessive", reason:"主観的スタイル"}
  ],
  summary: {total:2, legitimate:0, excessive:2}
}')
STUB_CLAUDE_OUTPUT=$(build_claude_result_json "$EXCESSIVE_ONLY_BODY")
export STUB_CLAUDE_OUTPUT

out=$(adj_classify_findings "$PR_NUMBER" "$SHA" "$FINDINGS_2" "$SPEC_DIR_HINT" "$BASE_REF" "$HEAD_REF" 2>/dev/null) && rc=0 || rc=$?

count=$(echo "$out" | jq -r '.decisions | length')
sev_concat=$(echo "$out" | jq -r '[.decisions[].verdict] | join(",")')
sum_legit=$(echo "$out" | jq -r '.summary.legitimate')
sum_excess=$(echo "$out" | jq -r '.summary.excessive')

assert_eq "Case 2 (excessive-only): rc=0" "0" "$rc"
assert_eq "Case 2 (excessive-only): decisions 件数=2" "2" "$count"
assert_eq "Case 2 (excessive-only): verdict='excessive,excessive'" "excessive,excessive" "$sev_concat"
assert_eq "Case 2 (excessive-only): summary.legitimate=0" "0" "$sum_legit"
assert_eq "Case 2 (excessive-only): summary.excessive=2" "2" "$sum_excess"

rm -f "$STUB_CLAUDE_OUTPUT"

# ─── ケース (3): mixed (1 legitimate + 2 excessive) ───

echo "--- adj_classify_findings case 3: mixed (Req 1.1, 1.5) ---"

MIXED_BODY=$(jq -nc '{
  decisions: [
    {id:1, severity:"high",   file:"foo.sh", line:10,  verdict:"legitimate", reason:"AC 直結"},
    {id:2, severity:"medium", file:"bar.sh", line:25,  verdict:"excessive",  reason:"AC 非紐付け"},
    {id:3, severity:"low",    file:"baz.sh", line:100, verdict:"excessive",  reason:"主観的"}
  ],
  summary: {total:3, legitimate:1, excessive:2}
}')
STUB_CLAUDE_OUTPUT=$(build_claude_result_json "$MIXED_BODY")
export STUB_CLAUDE_OUTPUT

out=$(adj_classify_findings "$PR_NUMBER" "$SHA" "$FINDINGS_3" "$SPEC_DIR_HINT" "$BASE_REF" "$HEAD_REF" 2>/dev/null) && rc=0 || rc=$?

count=$(echo "$out" | jq -r '.decisions | length')
sev_concat=$(echo "$out" | jq -r '[.decisions[].verdict] | join(",")')
sum_legit=$(echo "$out" | jq -r '.summary.legitimate')
sum_excess=$(echo "$out" | jq -r '.summary.excessive')

assert_eq "Case 3 (mixed): rc=0" "0" "$rc"
assert_eq "Case 3 (mixed): decisions 件数=3" "3" "$count"
assert_eq "Case 3 (mixed): verdict='legitimate,excessive,excessive'" "legitimate,excessive,excessive" "$sev_concat"
assert_eq "Case 3 (mixed): summary.legitimate=1" "1" "$sum_legit"
assert_eq "Case 3 (mixed): summary.excessive=2" "2" "$sum_excess"

rm -f "$STUB_CLAUDE_OUTPUT"

# ─── ケース (4): JSON parse 失敗 (散文のみ) ───

echo "--- adj_classify_findings case 4: JSON parse failure (Req 1.4 / fallback gate) ---"

# stub claude が「散文だけ」を result フィールドに入れて返す。
# adj_classify_findings は `{`-`}` 抽出 → jq valid 検証で fail し rc=2 を返すべき。
PROSE_BODY="これは散文だけの応答で JSON が含まれていません"
STUB_CLAUDE_OUTPUT=$(build_claude_result_json "$PROSE_BODY")
export STUB_CLAUDE_OUTPUT

rc=0
out=$(adj_classify_findings "$PR_NUMBER" "$SHA" "$FINDINGS_2" "$SPEC_DIR_HINT" "$BASE_REF" "$HEAD_REF" 2>/dev/null) || rc=$?

assert_eq "Case 4 (JSON parse 失敗): rc=2（fallback モード適用は呼び出し元責務）" "2" "$rc"

rm -f "$STUB_CLAUDE_OUTPUT"

# ─── ケース (5): findings 空配列で早期 return（claude 起動なし） ───

echo "--- adj_classify_findings case 5: empty findings early return (no claude) ---"

# stub claude が呼ばれたら不正な JSON を返すよう仕掛けておき、それでも rc=0 で
# decisions=[] が返ることを確認する（claude が起動されていない証明）。
STUB_CLAUDE_OUTPUT=$(mktemp)
echo "this would be invalid JSON if claude were invoked" > "$STUB_CLAUDE_OUTPUT"
export STUB_CLAUDE_OUTPUT

rc=0
out=$(adj_classify_findings "$PR_NUMBER" "$SHA" "[]" "$SPEC_DIR_HINT" "$BASE_REF" "$HEAD_REF" 2>/dev/null) || rc=$?
count=$(echo "$out" | jq -r '.decisions | length')
sum_total=$(echo "$out" | jq -r '.summary.total')

assert_eq "Case 5 (空配列早期 return): rc=0" "0" "$rc"
assert_eq "Case 5 (空配列早期 return): decisions=[]" "0" "$count"
assert_eq "Case 5 (空配列早期 return): summary.total=0" "0" "$sum_total"

rm -f "$STUB_CLAUDE_OUTPUT"
unset STUB_CLAUDE_OUTPUT

# ============================================================
# adj_validate_decisions: Section B
# ============================================================

# ─── ケース (A): 件数一致 + 全 verdict 妥当 ───

echo "--- adj_validate_decisions case A: well-formed (Req 1.5) ---"

VALID_DECISIONS=$(jq -nc '{
  decisions: [
    {id:1, severity:"high",   file:"foo.sh", line:10, verdict:"legitimate", reason:"AC 直結"},
    {id:2, severity:"medium", file:"bar.sh", line:25, verdict:"excessive",  reason:"主観的"}
  ],
  summary: {total:2, legitimate:1, excessive:1}
}')

rc=0
adj_validate_decisions "$FINDINGS_2" "$VALID_DECISIONS" 2>/dev/null || rc=$?
assert_eq "Case A (well-formed): rc=0" "0" "$rc"

# ─── ケース (B): 件数不一致 ───

echo "--- adj_validate_decisions case B: count mismatch (Req 1.5) ---"

COUNT_MISMATCH=$(jq -nc '{
  decisions: [
    {id:1, severity:"high", file:"foo.sh", line:10, verdict:"legitimate", reason:"x"}
  ],
  summary: {total:1, legitimate:1, excessive:0}
}')

rc=0
adj_validate_decisions "$FINDINGS_2" "$COUNT_MISMATCH" 2>/dev/null || rc=$?
assert_eq "Case B (count mismatch findings=2 vs decisions=1): rc=1" "1" "$rc"

# ─── ケース (C): verdict 値が legitimate|excessive 以外 ───

echo "--- adj_validate_decisions case C: invalid verdict value (Req 1.4) ---"

INVALID_VERDICT=$(jq -nc '{
  decisions: [
    {id:1, severity:"high",   file:"foo.sh", line:10, verdict:"legitimate", reason:"x"},
    {id:2, severity:"medium", file:"bar.sh", line:25, verdict:"maybe",      reason:"y"}
  ],
  summary: {total:2, legitimate:1, excessive:1}
}')

rc=0
adj_validate_decisions "$FINDINGS_2" "$INVALID_VERDICT" 2>/dev/null || rc=$?
assert_eq "Case C (invalid verdict='maybe'): rc=1" "1" "$rc"

# ─── ケース (D): summary 集計と decisions verdict 集計が不整合 ───

echo "--- adj_validate_decisions case D: summary mismatch ---"

# decisions 上は legitimate=2 / excessive=0 だが summary.total が 1 を主張するケース
SUMMARY_TOTAL_MISMATCH=$(jq -nc '{
  decisions: [
    {id:1, severity:"high",   file:"foo.sh", line:10, verdict:"legitimate", reason:"x"},
    {id:2, severity:"medium", file:"bar.sh", line:25, verdict:"legitimate", reason:"y"}
  ],
  summary: {total:1, legitimate:2, excessive:0}
}')

rc=0
adj_validate_decisions "$FINDINGS_2" "$SUMMARY_TOTAL_MISMATCH" 2>/dev/null || rc=$?
assert_eq "Case D (summary.total != decisions length): rc=1" "1" "$rc"

# decisions 上は legitimate=1 / excessive=1 だが summary は legitimate=2 / excessive=0
SUMMARY_LEGIT_MISMATCH=$(jq -nc '{
  decisions: [
    {id:1, severity:"high",   file:"foo.sh", line:10, verdict:"legitimate", reason:"x"},
    {id:2, severity:"medium", file:"bar.sh", line:25, verdict:"excessive",  reason:"y"}
  ],
  summary: {total:2, legitimate:2, excessive:0}
}')

rc=0
adj_validate_decisions "$FINDINGS_2" "$SUMMARY_LEGIT_MISMATCH" 2>/dev/null || rc=$?
assert_eq "Case D' (summary.legitimate != count(verdict=legitimate)): rc=1" "1" "$rc"

# ─── ケース (E): findings 空 + decisions 空 → rc=0 ───

echo "--- adj_validate_decisions case E: empty + empty ---"

EMPTY_DECISIONS=$(jq -nc '{
  decisions: [],
  summary: {total:0, legitimate:0, excessive:0}
}')

rc=0
adj_validate_decisions "[]" "$EMPTY_DECISIONS" 2>/dev/null || rc=$?
assert_eq "Case E (findings 空 + decisions 空): rc=0" "0" "$rc"

# ─── ケース (F): findings 空 + decisions 1 件 → rc=1 ───

echo "--- adj_validate_decisions case F: empty findings but non-empty decisions ---"

NON_EMPTY_FOR_EMPTY=$(jq -nc '{
  decisions: [
    {id:1, severity:"high", file:"foo.sh", line:10, verdict:"legitimate", reason:"x"}
  ],
  summary: {total:1, legitimate:1, excessive:0}
}')

rc=0
adj_validate_decisions "[]" "$NON_EMPTY_FOR_EMPTY" 2>/dev/null || rc=$?
assert_eq "Case F (findings 空 + decisions 1 件): rc=1" "1" "$rc"

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
