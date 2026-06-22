#!/usr/bin/env bash
#
# 用途: #95 Stage A fallback の mode ログが set -u と全角区切り文字で落ちないことを検証する。
# 実行: bash local-watcher/test/stagea_mode_log_nounset_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
[ -f "$WATCHER_SH" ] || { echo "ERROR: watcher not found" >&2; exit 2; }

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$name"
  else
    fail "$name (expected=$(printf %q "$expected") actual=$(printf %q "$actual"))"
  fi
}

assert_nonzero() {
  local name="$1" rc="$2"
  if [ "$rc" -ne 0 ]; then
    pass "$name"
  else
    fail "$name (expected nonzero rc)"
  fi
}

assert_zero() {
  local name="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then
    pass "$name"
  else
    fail "$name (rc=$rc)"
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/unsafe-stage-a-log.sh" <<'EOF'
echo "--- Stage A 実行（$MODE）---"
EOF

if grep -n 'Stage A 実行（\$[A-Za-z_][A-Za-z0-9_]*）' "$TMP_DIR/unsafe-stage-a-log.sh" >/dev/null; then
  pass "historical \$MODE） expression is detected as unsafe"
else
  fail "historical \$MODE） expression was not detected"
fi

safe_rc=0
safe_out="$(
  bash -c 'set -u; MODE=impl; echo "--- Stage A 実行（${MODE}）---"' 2>/dev/null
)" || safe_rc=$?
assert_zero "braced \${MODE}） expression succeeds under nounset" "$safe_rc"
assert_eq 'braced expression preserves impl mode' "--- Stage A 実行（impl）---" "$safe_out"

safe_resume_rc=0
safe_resume_out="$(
  bash -c 'set -u; MODE=impl-resume; echo "--- Stage A 実行（${MODE}）---"' 2>/dev/null
)" || safe_resume_rc=$?
assert_zero "braced \${MODE}） expression succeeds for impl-resume" "$safe_resume_rc"
assert_eq 'braced expression preserves impl-resume mode' "--- Stage A 実行（impl-resume）---" "$safe_resume_out"

if grep -n 'Stage A 実行（\$[A-Za-z_][A-Za-z0-9_]*）' "$WATCHER_SH" >/dev/null; then
  fail 'watcher source has unsafe Stage A mode expansion followed by multibyte delimiter'
else
  pass 'watcher source braces Stage A mode expansion before multibyte delimiter'
fi

if grep -n 'Stage A-PM 実行（impl / PM 要件定義のみ）' "$WATCHER_SH" >/dev/null; then
  pass 'Stage A-PM requirements-definition path remains reachable after mode log'
else
  fail 'Stage A-PM requirements-definition path is missing'
fi

echo "──────────────"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL GREEN"
