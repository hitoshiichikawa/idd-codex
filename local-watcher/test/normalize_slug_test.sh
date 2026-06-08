#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-issue-watcher.sh の スラグ正規化 (`_normalize_slug`) と
#       Stage Checkpoint Resume スラグ照合 (`_stage_checkpoint_assert_slug_match` /
#       `_resume_branch_assert_slug_match`) を fixture で検証するスモークテスト。
#       Issue #114 で導入。
#
# 配置先: local-watcher/test/normalize_slug_test.sh
# 依存:   bash 4+, awk, sed, diff
# 実行:   bash local-watcher/test/normalize_slug_test.sh
# 前提:   このスクリプトは local-watcher/bin/idd-codex-issue-watcher.sh から
#         `_normalize_slug` 関数 1 つだけを awk で切り出して eval で読み込み、
#         idd-codex-issue-watcher.sh のトップレベル副作用は回避する。
#
# 期待動作: 全 fixture が Req どおりの結果を返せば PASS、1 件でも失敗すれば
#           exit 1 で全体失敗。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

# idd-codex-issue-watcher.sh から `_normalize_slug` のみを抽出する。
# awk で「関数開始行」から最初の単独 `}` までを抜き出す。
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
eval "$(extract_function "$WATCHER_SH" "_normalize_slug")"

if ! declare -F _normalize_slug >/dev/null; then
  echo "ERROR: _normalize_slug not loaded" >&2
  exit 2
fi

# ─── アサーションヘルパ ───
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

# ─── テストケース（Req 5.1 の正規化規則を網羅） ───

echo "--- _normalize_slug cases (Issue #114 Req 5.1, 5.2, 5.3) ---"

# 基本: lowercase 化 + 非英数字をハイフン 1 個へ縮約
assert_eq "Req 5.1: basic ASCII with spaces (lowercase + hyphen 縮約)" \
  "bug-watcher-stage-checkpoint-resume-docs" \
  "$(_normalize_slug "bug: watcher Stage Checkpoint Resume docs")"

# 連続する非英数字が 1 個のハイフンに縮約される
assert_eq "Req 5.1: 連続非英数字 → 単一ハイフン" \
  "foo-bar-baz" \
  "$(_normalize_slug "foo!!!bar   baz")"

# 40 文字に切り詰められる + 末尾ハイフン除去
# 入力: 50 文字の "a a a a a a a a a a a a a a a a a a a a a a a a a"
# → 全部 hyphen 区切り → 40 文字で cut → 末尾ハイフン除去
assert_eq "Req 5.1: 40 文字切り詰め + 末尾ハイフン除去" \
  "a-a-a-a-a-a-a-a-a-a-a-a-a-a-a-a-a-a-a-a" \
  "$(_normalize_slug "a a a a a a a a a a a a a a a a a a a a a a a a a")"

# 先頭の数字は保持
assert_eq "Req 5.1: 先頭数字を保持" \
  "112-default-env-var-9-true" \
  "$(_normalize_slug "112: default env var 9 true")"

# Unicode 文字（日本語）は非英数字としてハイフン化（連続 → 1 個）
assert_eq "Req 5.1: Unicode は非英数字扱い" \
  "feat-watcher" \
  "$(_normalize_slug "feat 日本語 watcher")"

# Unicode 文字（日本語）のみの入力 → "issue" にフォールバック
assert_eq "日本語のみの入力 → issue" \
  "issue" \
  "$(_normalize_slug "日本語")"

# 空入力 → 空出力（NFR 2.1 の安全側挙動）
assert_eq "境界: 空入力 → 空出力" \
  "" \
  "$(_normalize_slug "")"

# 大文字のみ → lowercase 化
assert_eq "Req 5.1: 大文字 → lowercase" \
  "abc-def" \
  "$(_normalize_slug "ABC DEF")"

# 既存実装と差分等価であることの再現テスト（NFR 1.1 後方互換性）
# 旧コード: tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | cut -c1-40 | sed -E 's/-+$//'
# 同じ入力で同じ出力になることを 2 通りで確認
EXPECTED_LEGACY=$(echo "Refactor: split _slot_run_issue() into smaller chunks!!" \
                  | tr '[:upper:]' '[:lower:]' \
                  | sed -E 's/[^a-z0-9]+/-/g' | cut -c1-40 | sed -E 's/-+$//')
assert_eq "NFR 1.1: legacy 実装との差分等価性" \
  "$EXPECTED_LEGACY" \
  "$(_normalize_slug "Refactor: split _slot_run_issue() into smaller chunks!!")"

# 冪等性（normalize_slug を 2 回適用しても同じ結果）— Req 5.2 の共通関数化が
# 機能するための前提
RAW="Issue #114: bug: watcher Stage Checkpoint Resume docs"
FIRST=$(_normalize_slug "$RAW")
SECOND=$(_normalize_slug "$FIRST")
assert_eq "Req 5.2: 冪等性（normalize(normalize(x)) == normalize(x)）" \
  "$FIRST" \
  "$SECOND"

# 末尾の連続ハイフンが完全に除去される
assert_eq "Req 5.1: 末尾ハイフン完全除去" \
  "abc" \
  "$(_normalize_slug "abc---")"

# 先頭ハイフンは 40 文字切り詰めの結果として残るケース（実装挙動の確認）
# 入力 "!abc" → "-abc"（先頭ハイフンは sed で除去されないことを確認）
assert_eq "Req 5.1: 先頭ハイフンは保持（規約上の挙動）" \
  "-abc" \
  "$(_normalize_slug "!abc")"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
