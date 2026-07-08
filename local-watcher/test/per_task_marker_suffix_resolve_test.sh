#!/usr/bin/env bash
#
# 用途: per-task Reviewer の diff range 解決が、marker commit の trailing issue-ref suffix
#       （例: `docs(tasks): mark 6 as done (#118)`）を単記 / 連記いずれの経路でも許容し、
#       無関係 suffix は非許容のままであることを検証する。Issue #142（idd-claude #421 移植）
#       回帰テスト。
#
# 観点:
#   - 正常系: suffix 付き単記 marker の解決（via=single-id-marker-with-suffix）
#   - 正常系: suffix 付き連記 marker の解決（via=multi-id-marker-with-suffix）
#   - 異常系/境界: 無関係 suffix（空白なし / 括弧なし / 閉じ括弧後の追加文字列 / 非数字）は非許容
#   - 後方互換: canonical（suffix 無し）のみの履歴では従来と同一の SHA pair / ログ無し
#
# 配置先: local-watcher/test/per_task_marker_suffix_resolve_test.sh
# 依存:   bash 4+, awk, git, grep
# 実行:   bash local-watcher/test/per_task_marker_suffix_resolve_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
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

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_marker_matches_task_with_suffix")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_resolve_diff_range")"

if ! declare -F pt_marker_matches_task_with_suffix >/dev/null; then
  echo "ERROR: pt_marker_matches_task_with_suffix not loaded" >&2
  exit 2
fi
if ! declare -F pt_resolve_diff_range >/dev/null; then
  echo "ERROR: pt_resolve_diff_range not loaded" >&2
  exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
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
  local label="$1" needle="$2" haystack="$3"
  if grep -Fq -- "$needle" <<<"$haystack"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  needle: $(printf '%q' "$needle")"
    echo "  in    : $(printf '%q' "$haystack")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -Fq -- "$needle" <<<"$haystack"; then
    echo "FAIL: $label"
    echo "  unexpected needle: $(printf '%q' "$needle")"
    echo "  in               : $(printf '%q' "$haystack")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

# ─── fixture 構築: base commit + impl commit + 指定 subject の marker commit ───
setup_repo_with_marker_subject() {
  local repo="$1" marker_subject="$2"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "idd-codex-test@example.invalid"
  git -C "$repo" config user.name "idd-codex test"
  git -C "$repo" checkout -q -b main
  printf '%s\n' "base" >"$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "chore: base"
  git -C "$repo" checkout -q -b codex/issue-142-test
  printf '%s\n' "implementation" >"$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "fix(watcher): task implementation"
  git -C "$repo" commit -q --allow-empty -m "$marker_subject"
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

echo "--- pt_marker_matches_task_with_suffix 単体（許容 / 拒否境界） ---"

rc=0; pt_marker_matches_task_with_suffix "docs(tasks): mark 6 as done (#118)" "6" || rc=$?
assert_eq "canonical suffix（空白 1 + (#数字)）は許容" "0" "$rc"

rc=0; pt_marker_matches_task_with_suffix "docs(tasks): mark 1.1 as done (#9)" "1.1" || rc=$?
assert_eq "階層 task ID + suffix は許容" "0" "$rc"

rc=0; pt_marker_matches_task_with_suffix "docs(tasks): mark 6 as done(#118)" "6" || rc=$?
assert_eq "空白なし as done(#118) は拒否" "1" "$rc"

rc=0; pt_marker_matches_task_with_suffix "docs(tasks): mark 6 as done #118" "6" || rc=$?
assert_eq "括弧なし as done #118 は拒否" "1" "$rc"

rc=0; pt_marker_matches_task_with_suffix "docs(tasks): mark 6 as done (#118) extra" "6" || rc=$?
assert_eq "閉じ括弧後の追加文字列は拒否" "1" "$rc"

rc=0; pt_marker_matches_task_with_suffix "docs(tasks): mark 6 as done (#abc)" "6" || rc=$?
assert_eq "非数字 (#abc) は拒否" "1" "$rc"

rc=0; pt_marker_matches_task_with_suffix "docs(tasks): mark 6 as done (#)" "6" || rc=$?
assert_eq "数字ゼロ桁 (#) は拒否" "1" "$rc"

rc=0; pt_marker_matches_task_with_suffix "docs(tasks): mark 61 as done (#118)" "6" || rc=$?
assert_eq "task_id 不一致（61 vs 6）は拒否" "1" "$rc"

rc=0; pt_marker_matches_task_with_suffix "docs(tasks): mark 1x1 as done (#118)" "1.1" || rc=$?
assert_eq "task_id の . はリテラル照合（1x1 vs 1.1 は拒否）" "1" "$rc"

echo ""
echo "--- suffix 付き単記 marker の解決（Issue #142 正常系） ---"

repo1="$TMPROOT/single-suffix"
setup_repo_with_marker_subject "$repo1" "docs(tasks): mark 6 as done (#118)"
marker1_sha=$(git -C "$repo1" rev-parse HEAD)
base1_sha=$(git -C "$repo1" rev-parse main)

stderr1="$TMPROOT/single-suffix.err"
rc=0
range1=$(cd "$repo1" && BASE_BRANCH=main pt_resolve_diff_range "6" 2>"$stderr1") || rc=$?
assert_eq "suffix 付き単記 marker を解決できる（rc=0）" "0" "$rc"
assert_eq "range_start は base SHA" "$base1_sha" "$(printf '%s' "$range1" | cut -f1)"
assert_eq "range_end は suffix 付き marker SHA" "$marker1_sha" "$(printf '%s' "$range1" | cut -f2)"
assert_contains "観測ログに via=single-id-marker-with-suffix を残す" \
  "via=single-id-marker-with-suffix task_id=6" "$(cat "$stderr1")"

echo ""
echo "--- suffix 付き連記 marker の解決（Issue #142 正常系） ---"

repo2="$TMPROOT/multi-suffix"
setup_repo_with_marker_subject "$repo2" "docs(tasks): mark 1 / 1.1 as done (#118)"
marker2_sha=$(git -C "$repo2" rev-parse HEAD)
base2_sha=$(git -C "$repo2" rev-parse main)

stderr2="$TMPROOT/multi-suffix.err"
rc=0
range2=$(cd "$repo2" && BASE_BRANCH=main pt_resolve_diff_range "1.1" 2>"$stderr2") || rc=$?
assert_eq "suffix 付き連記 marker を解決できる（rc=0）" "0" "$rc"
assert_eq "連記 suffix: range_end は marker SHA" "$marker2_sha" "$(printf '%s' "$range2" | cut -f2)"
assert_eq "連記 suffix: range_start は base SHA" "$base2_sha" "$(printf '%s' "$range2" | cut -f1)"
assert_contains "観測ログに via=multi-id-marker-with-suffix を残す" \
  "via=multi-id-marker-with-suffix task_id=1.1" "$(cat "$stderr2")"

# token 完全一致の false-positive 防止（task_id=1 が 1.1 に誤マッチしない）を suffix 併用でも維持
rc=0
(cd "$repo2" && BASE_BRANCH=main pt_resolve_diff_range "11" >/dev/null 2>&1) || rc=$?
assert_eq "連記 suffix でも token 不一致 task_id=11 は解決しない（rc=1）" "1" "$rc"

echo ""
echo "--- 無関係 suffix は非許容のまま（Issue #142 異常系 / 境界） ---"

for bad_case in \
  "no-space|docs(tasks): mark 6 as done(#118)" \
  "no-paren|docs(tasks): mark 6 as done #118" \
  "trailing-extra|docs(tasks): mark 6 as done (#118) extra" \
  "non-numeric|docs(tasks): mark 6 as done (#abc)"; do
  label="${bad_case%%|*}"
  subject="${bad_case#*|}"
  repo_bad="$TMPROOT/bad-$label"
  setup_repo_with_marker_subject "$repo_bad" "$subject"
  rc=0
  (cd "$repo_bad" && BASE_BRANCH=main pt_resolve_diff_range "6" >/dev/null 2>&1) || rc=$?
  assert_eq "無関係 suffix ($label) は解決しない（rc=1）" "1" "$rc"
done

echo ""
echo "--- canonical（suffix 無し）marker の後方互換 ---"

repo3="$TMPROOT/canonical"
setup_repo_with_marker_subject "$repo3" "docs(tasks): mark 6 as done"
marker3_sha=$(git -C "$repo3" rev-parse HEAD)
base3_sha=$(git -C "$repo3" rev-parse main)

stderr3="$TMPROOT/canonical.err"
rc=0
range3=$(cd "$repo3" && BASE_BRANCH=main pt_resolve_diff_range "6" 2>"$stderr3") || rc=$?
assert_eq "canonical 単記 marker は従来どおり解決（rc=0）" "0" "$rc"
assert_eq "canonical: range_start は base SHA" "$base3_sha" "$(printf '%s' "$range3" | cut -f1)"
assert_eq "canonical: range_end は marker SHA" "$marker3_sha" "$(printf '%s' "$range3" | cut -f2)"
assert_not_contains "canonical 単記経由は観測ログを増やさない（via 行なし）" \
  "via=" "$(cat "$stderr3")"

# canonical と suffix 付きの双方が存在する場合、より新しい方（時系列最後）を採用する
repo4="$TMPROOT/canonical-then-suffix"
setup_repo_with_marker_subject "$repo4" "docs(tasks): mark 6 as done"
git -C "$repo4" commit -q --allow-empty -m "fix(watcher): corrective"
git -C "$repo4" commit -q --allow-empty -m "docs(tasks): mark 6 as done (#118)"
marker4_sha=$(git -C "$repo4" rev-parse HEAD)
rc=0
range4=$(cd "$repo4" && BASE_BRANCH=main pt_resolve_diff_range "6" 2>/dev/null) || rc=$?
assert_eq "canonical+suffix 併存時も解決できる（rc=0）" "0" "$rc"
assert_eq "canonical+suffix 併存時は最後（最新）の marker を採用" "$marker4_sha" "$(printf '%s' "$range4" | cut -f2)"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
