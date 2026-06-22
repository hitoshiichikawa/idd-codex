#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-issue-watcher.sh の full-auto kill switch
#       (`full_auto_enabled` 述語 + `FULL_AUTO_ENABLED` 値正規化 + startup ログ配線) を
#       検証する。Issue #97 (full-auto kill switch / FULL_AUTO_ENABLED) で導入。
#
# 配置先: local-watcher/test/full_auto_kill_switch_test.sh
# 依存:   bash 4+, awk, grep
# 実行:   bash local-watcher/test/full_auto_kill_switch_test.sh
# 前提:   watcher から `full_auto_enabled` 1 関数だけを awk で切り出して eval で読み込み、
#         トップレベル副作用は回避する。
#
# 期待動作: 全ケース PASS なら exit 0、1 件でも失敗で exit 1。

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
eval "$(extract_function "$WATCHER_SH" "full_auto_enabled")"

if ! declare -F full_auto_enabled >/dev/null; then
  echo "ERROR: full_auto_enabled not loaded" >&2
  exit 2
fi

# ─── アサーションヘルパ ───
PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected: $(printf '%q' "$expected")"
    echo "  actual  : $(printf '%q' "$actual")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# full_auto_enabled の戻り値を on/off 文字列へ写す（FULL_AUTO_ENABLED を都度上書きして評価）
# SC2034: 抽出した full_auto_enabled がグローバル参照するため shellcheck は使用を追えない。
gate_for() {
  # shellcheck disable=SC2034
  FULL_AUTO_ENABLED="$1"
  if full_auto_enabled; then echo "on"; else echo "off"; fi
}

gate_for_unset() {
  unset FULL_AUTO_ENABLED
  if full_auto_enabled; then echo "on"; else echo "off"; fi
}

echo "--- full_auto_enabled 述語: 入力マトリクス (Issue #97 Req 1.2 / 1.3) ---"

# 正常系: `true` 厳密一致のみ ON
assert_eq "正常系: 'true' 厳密一致 → on" "on" "$(gate_for "true")"

# 異常系/境界: それ以外はすべて OFF（安全側）
assert_eq "境界: 'false' → off"            "off" "$(gate_for "false")"
assert_eq "境界: 空文字 → off"             "off" "$(gate_for "")"
assert_eq "境界: 未設定(unset) → off"      "off" "$(gate_for_unset)"
assert_eq "境界: 'True'(大文字混在) → off" "off" "$(gate_for "True")"
assert_eq "境界: 'TRUE' → off"             "off" "$(gate_for "TRUE")"
assert_eq "境界: '1' → off"                "off" "$(gate_for "1")"
assert_eq "境界: 'on' → off"               "off" "$(gate_for "on")"
assert_eq "境界: 'yes' → off"              "off" "$(gate_for "yes")"
assert_eq "境界: 前後空白 ' true ' → off"  "off" "$(gate_for " true ")"
assert_eq "境界: typo 'ture' → off"        "off" "$(gate_for "ture")"

echo ""
echo "--- 構造チェック: 値正規化 + startup ログ配線 (Req 1.1 / 1.4) ---"

# 既定 false（opt-in 制）
if grep -qE '^FULL_AUTO_ENABLED="\$\{FULL_AUTO_ENABLED:-false\}"' "$WATCHER_SH"; then
  assert_eq "Config: 既定 false の宣言が存在" "ok" "ok"
else
  assert_eq "Config: 既定 false の宣言が存在" "ok" "missing"
fi

# 厳密 true 正規化（非 true を false に固定）
if awk '/^case "\$FULL_AUTO_ENABLED" in/{f=1} f&&/FULL_AUTO_ENABLED="false"/{print "found"; exit}' "$WATCHER_SH" | grep -q found; then
  assert_eq "Config: 非 true を false へ正規化する case が存在" "ok" "ok"
else
  assert_eq "Config: 非 true を false へ正規化する case が存在" "ok" "missing"
fi

# startup ログに full-auto= が配線されている（可観測性）
if grep -qE 'full-auto=\$\{FULL_AUTO_ENABLED\}' "$WATCHER_SH"; then
  assert_eq "Log: startup config 行に full-auto= が配線されている" "ok" "ok"
else
  assert_eq "Log: startup config 行に full-auto= が配線されている" "ok" "missing"
fi

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
