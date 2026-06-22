#!/usr/bin/env bash
#
# 用途: Issue #52 task 4 の secure tempfile helper と watcher core call-site を検証する。
# 依存: bash 4+, awk, grep, mktemp, stat
# 実行: bash local-watcher/test/security_medium_tempfiles_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CORE_UTILS_SH="$REPO_ROOT/local-watcher/bin/idd-codex-modules/core_utils.sh"
WATCHER_SH="$REPO_ROOT/local-watcher/bin/idd-codex-issue-watcher.sh"

[ -f "$CORE_UTILS_SH" ] || { echo "ERROR: core_utils.sh not found" >&2; exit 2; }
[ -f "$WATCHER_SH" ] || { echo "ERROR: watcher not found" >&2; exit 2; }

# shellcheck source=../bin/idd-codex-modules/core_utils.sh disable=SC1091
source "$CORE_UTILS_SH"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPROOT" 2>/dev/null || true; rm -rf "$TMPROOT"' EXIT

pass() {
  echo "  ok: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  NG: $1" >&2
  FAIL=$((FAIL + 1))
}

assert_success() {
  local label="$1"
  shift
  if "$@"; then
    pass "$label"
  else
    fail "$label"
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    fail "$label (expected=$(printf '%q' "$expected") actual=$(printf '%q' "$actual"))"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    pass "$label"
  else
    fail "$label (missing $(printf '%q' "$needle"))"
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    fail "$label (unexpected $(printf '%q' "$needle"))"
  else
    pass "$label"
  fi
}

mode_octal() {
  local path="$1"
  local mode
  if mode=$(stat -c '%a' "$path" 2>/dev/null); then
    printf '%s' "$mode"
    return 0
  fi
  mode=$(stat -f '%Lp' "$path")
  printf '%s' "$mode"
}

echo "[case1] secure tempfile helper creates non-predictable owner-only files"
export LOG_DIR="$TMPROOT/logs"
unset IDD_CODEX_TMP_DIR
mkdir -p "$LOG_DIR"
tmp_a="$(idd_secure_mktemp "triage")"
tmp_b="$(idd_secure_mktemp "triage")"
assert_success "helper creates first file" test -f "$tmp_a"
assert_success "helper creates second file" test -f "$tmp_b"
case "$tmp_a" in
  "$LOG_DIR/tmp"/*) pass "helper uses LOG_DIR private tmp root by default" ;;
  *) fail "helper uses LOG_DIR private tmp root by default" ;;
esac
assert_success "helper returns different paths" test "$tmp_a" != "$tmp_b"
assert_eq "private tmp directory is owner-only" "700" "$(mode_octal "$LOG_DIR/tmp")"
case "$(mode_octal "$tmp_a")" in
  600|700) pass "temporary file is owner-readable only" ;;
  *) fail "temporary file is owner-readable only" ;;
esac

echo "[case2] helper fails closed instead of predictable fallback"
readonly_parent="$TMPROOT/readonly-parent"
mkdir -p "$readonly_parent"
chmod 500 "$readonly_parent"
export IDD_CODEX_TMP_DIR="$readonly_parent/no-create"
helper_err="$TMPROOT/helper.err"
rc=0
idd_secure_mktemp "failcase" >"$TMPROOT/helper.out" 2>"$helper_err" || rc=$?
assert_eq "uncreatable tmp root returns non-zero" "1" "$rc"
assert_contains "failure is operator-visible" "$(cat "$helper_err")" "secure-tempfile: ERROR:"
assert_success "failure does not create predictable fallback path" test ! -e "/tmp/failcase-$$"

echo "[case3] helper handles boundary characters in labels safely"
export IDD_CODEX_TMP_DIR="$TMPROOT/custom tmp"
tmp_boundary="$(idd_secure_mktemp "Stage A/redo:01")"
assert_success "boundary label tempfile is created" test -f "$tmp_boundary"
case "$(basename "$tmp_boundary")" in
  idd-Stage-A-redo-01-*) pass "boundary label is sanitized into basename" ;;
  *) fail "boundary label is sanitized into basename" ;;
esac

echo "[case4] watcher core has no predictable temp path fallback for task-4 targets"
watcher_body="$(cat "$WATCHER_SH")"
core_body="$(cat "$CORE_UTILS_SH")"
assert_not_contains "triage JSON no longer uses /tmp path" "$watcher_body" 'TRIAGE_FILE="/tmp/triage-'
assert_not_contains "quota reset handoff no longer uses /tmp path" "$watcher_body" '="/tmp/qa-reset-'
assert_not_contains "mktemp fallback no longer suppresses secure temp failure" "$watcher_body" 'mktemp -t verify-push-XXXXXX.err 2>/dev/null || echo ""'
assert_not_contains "resume push stderr no longer falls back to missing tempfile" "$watcher_body" 'mktemp -t resume-push-XXXXXX.err 2>/dev/null || echo ""'
assert_not_contains "core utilities no longer use predictable mktemp fallback" "$core_body" 'mktemp -t worktree-reset-clean-XXXXXX.err 2>/dev/null || echo ""'
assert_not_contains "slot hook stderr no longer uses predictable mktemp fallback" "$core_body" 'mktemp -t slot-init-hook-XXXXXX.err 2>/dev/null || echo ""'

echo "──────────────"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL GREEN"
