#!/usr/bin/env bash
#
# 用途: PR Reviewer Adjudicator (#404) の codex 指摘 parse 関数 `adj_extract_findings` の
#       挙動を検証するスモークテスト。
#
#       検証する受入基準（docs/specs/404-feat-pr-reviewer-codex-advisory-claude-a/requirements.md）:
#         - Req 1.1 各指摘を legitimate/excessive に分類する前段としての parse
#         - Req 5.5 既存 exit code 契約（戻り値 4 = reconciliation mismatch）の確立
#
#       検証ケース:
#         (1) 空: review_text に `## 指摘事項` 見出し無し / 「指摘なし」のみ → `[]` rc=0
#         (2) 単一: 1 件指摘で 1 件パース rc=0
#         (3) 多重: high / medium / low 各 1 件 → 3 件パース rc=0
#         (4) 不正行混在: 書式不正 bullet + 正常 bullet 1 件 → reconciliation 不一致 rc=4
#                          + 正常分は返す（fail-safe は呼び出し元責任）
#         (5) 次の `## 結論` 直前で打ち切り: section 境界が正しく解決される
#
# 配置先: local-watcher/test/adj_extract_findings_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/adj_extract_findings_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADJ_SH="$SCRIPT_DIR/../bin/idd-codex-modules/adjudicator.sh"

if [ ! -f "$ADJ_SH" ]; then
  echo "ERROR: cannot find adjudicator.sh at $ADJ_SH" >&2
  exit 2
fi

# adj_warn は core_utils.sh 配置だが、本テストは関数を隔離抽出するため stub で潰す。
# extract_function が adj_extract_findings 本体のみを抜くと adj_warn 呼び出しが残るため、
# 事前に no-op 関数として定義しておく（reconciliation mismatch ケースで stderr に WARN を
# 落とすが、本テストでは assertion 対象外なので silent な空関数で十分）。
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
eval "$(extract_function "$ADJ_SH" "adj_extract_findings")"

if ! declare -F adj_extract_findings >/dev/null; then
  echo "ERROR: adj_extract_findings not loaded" >&2
  exit 2
fi

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

# ─── ケース (1): 空 ───

echo "--- adj_extract_findings case 1: empty (Req 1.1) ---"

# Case 1a: review_text が空文字
out=$(adj_extract_findings "" 2>/dev/null) || rc=$?
rc=${rc:-0}
assert_eq "Case 1a (空 review_text): JSON 出力は '[]'" "[]" "$out"
assert_eq "Case 1a (空 review_text): rc=0" "0" "$rc"
unset rc

# Case 1b: `## 指摘事項` 見出し無し
out=$(adj_extract_findings "## 概要
foo

## 結論
VERDICT: approve" 2>/dev/null) || rc=$?
rc=${rc:-0}
assert_eq "Case 1b (指摘事項見出し無し): JSON 出力は '[]'" "[]" "$out"
assert_eq "Case 1b (指摘事項見出し無し): rc=0" "0" "$rc"
unset rc

# Case 1c: `## 指摘事項` 見出しはあるが「指摘なし」のみ
out=$(adj_extract_findings "## 概要
foo

## 指摘事項
指摘なし

## 結論
VERDICT: approve" 2>/dev/null) || rc=$?
rc=${rc:-0}
assert_eq "Case 1c (指摘なし plain text のみ): JSON 出力は '[]'" "[]" "$out"
assert_eq "Case 1c (指摘なし plain text のみ): rc=0（reconcile 対象外）" "0" "$rc"
unset rc

# ─── ケース (2): 単一指摘 ───

echo "--- adj_extract_findings case 2: single finding (Req 1.1) ---"

out=$(adj_extract_findings "## 概要
foo

## 指摘事項
- [high] foo.sh:10 — 重大バグです

## 結論
VERDICT: codex-needs-iteration" 2>/dev/null) || rc=$?
rc=${rc:-0}

count=$(echo "$out" | jq -r 'length')
sev=$(echo "$out" | jq -r '.[0].severity')
fil=$(echo "$out" | jq -r '.[0].file')
lin=$(echo "$out" | jq -r '.[0].line')
msg=$(echo "$out" | jq -r '.[0].message')

assert_eq "Case 2 (単一指摘): 件数=1" "1" "$count"
assert_eq "Case 2 (単一指摘): severity='high'" "high" "$sev"
assert_eq "Case 2 (単一指摘): file='foo.sh'" "foo.sh" "$fil"
assert_eq "Case 2 (単一指摘): line=10 (integer)" "10" "$lin"
assert_eq "Case 2 (単一指摘): message='重大バグです'" "重大バグです" "$msg"
assert_eq "Case 2 (単一指摘): rc=0" "0" "$rc"
unset rc

# ─── ケース (3): 多重指摘 (high / medium / low) ───

echo "--- adj_extract_findings case 3: multiple findings (Req 1.1) ---"

out=$(adj_extract_findings "## 指摘事項
- [high] foo.sh:10 — バグ A
- [medium] bar.sh:25 — 警告 B
- [low] baz.sh:100 — 提案 C

## 結論
VERDICT: codex-needs-iteration" 2>/dev/null) || rc=$?
rc=${rc:-0}

count=$(echo "$out" | jq -r 'length')
sev_concat=$(echo "$out" | jq -r '[.[].severity] | join(",")')
fil_concat=$(echo "$out" | jq -r '[.[].file] | join(",")')

assert_eq "Case 3 (多重指摘): 件数=3" "3" "$count"
assert_eq "Case 3 (多重指摘): severity 順序保持='high,medium,low'" "high,medium,low" "$sev_concat"
assert_eq "Case 3 (多重指摘): file 順序保持='foo.sh,bar.sh,baz.sh'" "foo.sh,bar.sh,baz.sh" "$fil_concat"
assert_eq "Case 3 (多重指摘): rc=0" "0" "$rc"
unset rc

# ─── ケース (4): 不正行混在で reconciliation 不一致 ───

echo "--- adj_extract_findings case 4: malformed bullet + reconciliation mismatch (Req 5.5) ---"

# 書式不正な bullet（`- これは普通のリスト`）と正常な指摘 2 件を混在させる。
# bullet 総数 = 3 / parse 件数 = 2 のため reconcile 不一致で rc=4 を返し、parse 済み 2 件は返す。
out=$(adj_extract_findings "## 指摘事項
- [high] foo.sh:10 — 正常な指摘 1
- これは普通のリスト項目（書式不正）
- [medium] bar.sh:5 — 正常な指摘 2

## 結論
VERDICT: codex-needs-iteration" 2>/dev/null) && rc=0 || rc=$?

count=$(echo "$out" | jq -r 'length')
sev_concat=$(echo "$out" | jq -r '[.[].severity] | join(",")')

assert_eq "Case 4 (reconcile 不一致): rc=4" "4" "$rc"
assert_eq "Case 4 (reconcile 不一致): 正常 parse 分は返す（件数=2）" "2" "$count"
assert_eq "Case 4 (reconcile 不一致): severity 順序='high,medium'" "high,medium" "$sev_concat"
unset rc

# ─── ケース (5): 次の `## 結論` 直前で打ち切り ───

echo "--- adj_extract_findings case 5: section boundary at next '## ' heading (Req 1.1) ---"

# 後続セクション（## 結論）以降に bullet 行があっても、`## 指摘事項` 配下に
# 含めず正しくセクション境界を解決すること。
out=$(adj_extract_findings "## 概要
total

## 指摘事項
- [high] foo.sh:10 — first
- [low] bar.sh:5 — second

## 結論
VERDICT: codex-needs-iteration

- [high] outside.sh:99 — outside section should be ignored" 2>/dev/null) || rc=$?
rc=${rc:-0}

count=$(echo "$out" | jq -r 'length')
sev_concat=$(echo "$out" | jq -r '[.[].severity] | join(",")')
fil_concat=$(echo "$out" | jq -r '[.[].file] | join(",")')

assert_eq "Case 5 (section 境界): 件数=2（## 結論 後の bullet は無視）" "2" "$count"
assert_eq "Case 5 (section 境界): severity='high,low'" "high,low" "$sev_concat"
assert_eq "Case 5 (section 境界): file='foo.sh,bar.sh'（outside.sh は除外）" "foo.sh,bar.sh" "$fil_concat"
assert_eq "Case 5 (section 境界): rc=0（reconcile 不発生）" "0" "$rc"
unset rc

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
