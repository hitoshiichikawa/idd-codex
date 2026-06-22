#!/usr/bin/env bash
#
# 用途: codex_effective_timeout_sec（#16 runaway bound）の優先順位を検証する。
#   - 明示 CODEX_EXEC_TIMEOUT_SEC が最優先
#   - 未指定時は CODEX_DEFAULT_TIMEOUT_SEC が適用
#   - 両者 0 / 空なら timeout なし（空文字 = 従来挙動）
#
# 実行: bash local-watcher/test/codex_effective_timeout_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
[ -f "$WATCHER_SH" ] || { echo "ERROR: watcher not found: $WATCHER_SH" >&2; exit 2; }

extract_function() {
  awk -v fn="${2}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$1"
}
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "codex_effective_timeout_sec")"
declare -F codex_effective_timeout_sec >/dev/null || { echo "ERROR: fn not loaded" >&2; exit 2; }

PASS=0; FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1));
  else echo "FAIL: $1 (expected=$(printf %q "$2") actual=$(printf %q "$3"))"; FAIL=$((FAIL+1)); fi
}

# 明示 per-call が最優先
CODEX_EXEC_TIMEOUT_SEC=600 CODEX_DEFAULT_TIMEOUT_SEC=1800 \
  assert_eq "explicit per-call が最優先" "600" "$(CODEX_EXEC_TIMEOUT_SEC=600 CODEX_DEFAULT_TIMEOUT_SEC=1800 codex_effective_timeout_sec)"
# 未指定 → 既定
assert_eq "未指定なら既定が適用" "1800" "$(unset CODEX_EXEC_TIMEOUT_SEC; CODEX_DEFAULT_TIMEOUT_SEC=1800 codex_effective_timeout_sec)"
# 明示 0 → 既定にフォールバック（明示無効化扱い）
assert_eq "explicit=0 は既定へフォールバック" "1800" "$(CODEX_EXEC_TIMEOUT_SEC=0 CODEX_DEFAULT_TIMEOUT_SEC=1800 codex_effective_timeout_sec)"
# 既定 0 かつ explicit 無し → timeout なし（空）
assert_eq "既定 0 + explicit 無し → timeout なし" "" "$(unset CODEX_EXEC_TIMEOUT_SEC; CODEX_DEFAULT_TIMEOUT_SEC=0 codex_effective_timeout_sec)"
# 両方未設定（set -u 下でも安全に空）
assert_eq "両方未設定 → 空" "" "$(unset CODEX_EXEC_TIMEOUT_SEC CODEX_DEFAULT_TIMEOUT_SEC; codex_effective_timeout_sec)"

echo "──────────────"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL GREEN"
