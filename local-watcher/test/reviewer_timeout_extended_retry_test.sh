#!/usr/bin/env bash
#
# 用途: 独立 Reviewer（per-task 経路 run_per_task_reviewer / 単発経路 run_reviewer_stage）の
#       wall-clock timeout（rc=124）起因失敗を、拡張 timeout（REVIEWER_TIMEOUT_EXTENDED_SEC、
#       既定は基準の 2 倍）で同一 round 内 1 回だけ再試行し、なお失敗なら rc=6
#       （reviewer-timeout-exhausted 経路）で区別して返すことを検証する。
#       Issue #149（idd-claude #442 の「拡張 turn リトライ」→「拡張 timeout リトライ」読み替え移植）
#       回帰テスト。
#
# 観点:
#   - 単体: reviewer_normalize_extended_timeout_sec の正規化（既定 2 倍 / 不正値 fallback /
#     基準未満の引き上げ / timeout 無効時は空）
#   - 正常系: timeout → 拡張 timeout リトライで成功（rc=0、リトライ時に拡張予算が適用される）
#   - 異常系: リトライ後も timeout → rc=6 + reason=timeout-exhausted
#   - 境界: 非 timeout 失敗（rc=42）はリトライせず従来どおり rc=2 / timeout 無効設定では
#     rc=124 でも従来どおり rc=2（後方互換）
#   - 対称性: 単発経路 run_reviewer_stage でも同一挙動 + rs_record_reviewer degraded 記録
#
# 配置先: local-watcher/test/reviewer_timeout_extended_retry_test.sh
# 依存:   bash 4+, awk, grep
# 実行:   bash local-watcher/test/reviewer_timeout_extended_retry_test.sh

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

for fn in codex_effective_timeout_sec reviewer_base_timeout_sec \
  reviewer_normalize_extended_timeout_sec reviewer_is_timeout_rc \
  run_per_task_reviewer run_reviewer_stage; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$WATCHER_SH" "$fn")"
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

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
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

echo "--- reviewer_normalize_extended_timeout_sec 正規化（単体） ---"

norm() {
  REVIEWER_TIMEOUT_EXTENDED_SEC="$1" reviewer_normalize_extended_timeout_sec "$2"
}

assert_eq "未設定なら基準の 2 倍（1800→3600）" "3600" "$(norm "" 1800)"
assert_eq "非数値 (abc) は破棄して基準の 2 倍" "3600" "$(norm "abc" 1800)"
assert_eq "非数値 (12x) は破棄して基準の 2 倍" "3600" "$(norm "12x" 1800)"
assert_eq "負号付き (-1) は破棄して基準の 2 倍" "3600" "$(norm "-1" 1800)"
assert_eq "基準未満 (900 < 1800) は基準に引き上げ" "1800" "$(norm "900" 1800)"
assert_eq "基準以上 (7200) はそのまま採用" "7200" "$(norm "7200" 1800)"
assert_eq "基準が空なら空（timeout 無効 = 拡張リトライ非適用）" "" "$(norm "7200" "")"
assert_eq "基準が 0 なら空（timeout 無効 = 拡張リトライ非適用）" "" "$(norm "7200" 0)"
assert_eq "基準が非数値なら空" "" "$(norm "7200" "abc")"

echo ""
echo "--- reviewer_is_timeout_rc 判定（単体） ---"

rc=0; reviewer_is_timeout_rc 124 || rc=$?
assert_eq "rc=124 は timeout 起因と判定" "0" "$rc"
rc=0; reviewer_is_timeout_rc 0 || rc=$?
assert_eq "rc=0 は timeout ではない" "1" "$rc"
rc=0; reviewer_is_timeout_rc 99 || rc=$?
assert_eq "rc=99 (quota) は timeout ではない" "1" "$rc"
rc=0; reviewer_is_timeout_rc 42 || rc=$?
assert_eq "rc=42 (crash) は timeout ではない" "1" "$rc"

echo ""
echo "--- flow テスト用 stub 定義 ---"

# ── 共通 stub（per-task / 単発の両経路で使用） ──
CALL_COUNT_FILE="$TMPROOT/codex-calls"
CALL_TIMEOUT_CAPTURE="$TMPROOT/codex-timeouts"
# CODEX_RC_SEQUENCE: 空白区切りの rc 列。N 回目の呼び出しは N 番目の rc を返す（超過分は最後を再利用）。
CODEX_RC_SEQUENCE="0"

reset_codex_stub() {
  CODEX_RC_SEQUENCE="$1"
  : >"$CALL_COUNT_FILE"
  : >"$CALL_TIMEOUT_CAPTURE"
}

codex_call_count() {
  wc -l <"$CALL_COUNT_FILE" | tr -d '[:space:]'
}

codex_exec_prompt() {
  # 呼び出し回数を記録し、その回に対応する rc を CODEX_RC_SEQUENCE から返す。
  # 実効 timeout（CODEX_EXEC_TIMEOUT_SEC 優先）も呼び出しごとに記録する。
  echo "call" >>"$CALL_COUNT_FILE"
  local n rc_list rc_n
  n=$(codex_call_count)
  codex_effective_timeout_sec >>"$CALL_TIMEOUT_CAPTURE"
  read -r -a rc_list <<<"$CODEX_RC_SEQUENCE"
  if [ "$n" -le "${#rc_list[@]}" ]; then
    rc_n="${rc_list[$((n - 1))]}"
  else
    rc_n="${rc_list[$(( ${#rc_list[@]} - 1 ))]}"
  fi
  return "$rc_n"
}

qa_run_codex_stage() {
  local _stage="$1" _reset_file="$2"
  shift 2
  if [ "${1:-}" = "--" ]; then
    shift
  fi
  "$@"
}

idd_secure_mktemp() {
  mktemp "$TMPROOT/qa-reset.XXXXXX"
}

pt_log() { printf 'per-task: %s\n' "$*"; }
rv_log() { printf 'reviewer: %s\n' "$*"; }
dbg_log() { printf 'debugger: %s\n' "$*"; }
cm_write_context_map() { return 0; }
cm_warn() { printf 'context-map WARN: %s\n' "$*" >&2; }
qa_handle_quota_exceeded() { return 0; }
extract_review_result_token() { printf 'approve\n'; }
build_per_task_reviewer_prompt() { printf 'test prompt task=%s\n' "$1"; }
build_reviewer_prompt() { printf 'test prompt round=%s\n' "$1"; }
parse_review_result() { printf 'approve\t\t1.1\n'; }
pt_resolve_diff_range() { printf 'deadbeef\tcafebabe\n'; }
pt_guard_reviewer_range_fresh() { return 0; }

RS_RECORD_CAPTURE="$TMPROOT/rs-record"
rs_record_reviewer() { printf '%s\n' "$*" >>"$RS_RECORD_CAPTURE"; }

# ── 共通 env（extract した関数本体から動的に参照される / SC2034 false-positive 抑止） ──
LOG="$TMPROOT/test.log"
# shellcheck disable=SC2034
REPO_DIR="$TMPROOT"
# shellcheck disable=SC2034
SPEC_DIR_REL="docs/specs/149-test"
# shellcheck disable=SC2034
REVIEWER_MODEL="test-reviewer"
# shellcheck disable=SC2034
REVIEWER_MAX_TURNS="1"
# shellcheck disable=SC2034
REPO_SLUG="idd-codex-test"
# shellcheck disable=SC2034
NUMBER="149"
mkdir -p "$TMPROOT/docs/specs/149-test"

run_pt_case() {
  # $1 = rc sequence, $2.. = env assignments (VAR=VALUE)
  local seq="$1"; shift
  reset_codex_stub "$seq"
  : >"$LOG"
  : >"$RS_RECORD_CAPTURE"
  local rc=0
  ( for kv in "$@"; do export "${kv?}"; done
    run_per_task_reviewer "1.1" "1" ) >>"$LOG" 2>&1 || rc=$?
  printf '%s' "$rc"
}

run_rv_case() {
  local seq="$1"; shift
  reset_codex_stub "$seq"
  : >"$LOG"
  : >"$RS_RECORD_CAPTURE"
  local rc=0
  ( for kv in "$@"; do export "${kv?}"; done
    run_reviewer_stage "1" ) >>"$LOG" 2>&1 || rc=$?
  printf '%s' "$rc"
}

echo ""
echo "--- per-task 経路: timeout → 拡張 timeout リトライで成功（正常系） ---"

rc=$(run_pt_case "124 0" "CODEX_DEFAULT_TIMEOUT_SEC=1800")
assert_eq "timeout 後の拡張リトライ成功で rc=0 (approve)" "0" "$rc"
assert_eq "codex は 2 回呼ばれる（初回 + 拡張リトライ）" "2" "$(codex_call_count)"
assert_eq "初回は基準 timeout (1800s) で起動" "1800" "$(sed -n '1p' "$CALL_TIMEOUT_CAPTURE")"
assert_eq "リトライは拡張 timeout (3600s) で起動" "3600" "$(sed -n '2p' "$CALL_TIMEOUT_CAPTURE")"
assert_contains "リトライ起動をログに記録（reason=extended-timeout）" \
  "retry reason=extended-timeout base-timeout-sec=1800 extended-timeout-sec=3600" "$(cat "$LOG")"

echo ""
echo "--- per-task 経路: REVIEWER_TIMEOUT_EXTENDED_SEC の明示 override ---"

rc=$(run_pt_case "124 0" "CODEX_DEFAULT_TIMEOUT_SEC=1800" "REVIEWER_TIMEOUT_EXTENDED_SEC=5400")
assert_eq "override 時もリトライ成功で rc=0" "0" "$rc"
assert_eq "リトライは override 値 (5400s) で起動" "5400" "$(sed -n '2p' "$CALL_TIMEOUT_CAPTURE")"

echo ""
echo "--- per-task 経路: リトライ後も timeout → rc=6 (timeout-exhausted / 異常系) ---"

rc=$(run_pt_case "124 124" "CODEX_DEFAULT_TIMEOUT_SEC=1800")
assert_eq "拡張リトライ後も timeout なら rc=6" "6" "$rc"
assert_eq "リトライは同一 round 内 1 回限定（呼び出し 2 回で停止）" "2" "$(codex_call_count)"
assert_contains "timeout 枯渇を区別された reason でログに記録" \
  "reason=timeout-exhausted rc=124" "$(cat "$LOG")"

echo ""
echo "--- per-task 経路: 非 timeout 失敗はリトライしない（境界） ---"

rc=$(run_pt_case "42" "CODEX_DEFAULT_TIMEOUT_SEC=1800")
assert_eq "非 timeout 失敗 (rc=42) は従来どおり rc=2" "2" "$rc"
assert_eq "非 timeout 失敗ではリトライしない（呼び出し 1 回）" "1" "$(codex_call_count)"
assert_contains "非 timeout 失敗は従来 reason のまま" \
  "reason=codex-exit-nonzero rc=42" "$(cat "$LOG")"
assert_not_contains "非 timeout 失敗で extended-timeout リトライは発火しない" \
  "reason=extended-timeout" "$(cat "$LOG")"

echo ""
echo "--- per-task 経路: timeout 無効設定では従来挙動（後方互換 / 空入力） ---"

rc=$(run_pt_case "124" "CODEX_DEFAULT_TIMEOUT_SEC=0")
assert_eq "timeout 無効 (=0) のとき rc=124 は従来どおり rc=2" "2" "$rc"
assert_eq "timeout 無効ではリトライしない（呼び出し 1 回）" "1" "$(codex_call_count)"
assert_not_contains "timeout 無効では timeout-exhausted を発行しない" \
  "timeout-exhausted" "$(cat "$LOG")"

echo ""
echo "--- 単発経路 run_reviewer_stage: timeout → 拡張 timeout リトライで成功（対称性） ---"

rc=$(run_rv_case "124 0" "CODEX_DEFAULT_TIMEOUT_SEC=1800")
assert_eq "単発経路: timeout 後の拡張リトライ成功で rc=0 (approve)" "0" "$rc"
assert_eq "単発経路: codex は 2 回呼ばれる" "2" "$(codex_call_count)"
assert_eq "単発経路: リトライは拡張 timeout (3600s) で起動" "3600" "$(sed -n '2p' "$CALL_TIMEOUT_CAPTURE")"
assert_contains "単発経路: リトライ起動をログに記録" \
  "retry reason=extended-timeout base-timeout-sec=1800 extended-timeout-sec=3600" "$(cat "$LOG")"
assert_contains "単発経路: 成功時は approve として run-summary 記録" \
  "independent approve 1" "$(cat "$RS_RECORD_CAPTURE")"

echo ""
echo "--- 単発経路 run_reviewer_stage: リトライ後も timeout → rc=6 + degraded 記録 ---"

rc=$(run_rv_case "124 124" "CODEX_DEFAULT_TIMEOUT_SEC=1800")
assert_eq "単発経路: 拡張リトライ後も timeout なら rc=6" "6" "$rc"
assert_eq "単発経路: リトライは 1 回限定（呼び出し 2 回で停止）" "2" "$(codex_call_count)"
assert_contains "単発経路: timeout 枯渇を区別された reason でログに記録" \
  "reason=timeout-exhausted rc=124" "$(cat "$LOG")"
assert_contains "単発経路: timeout 枯渇は run-summary に degraded 記録" \
  "degraded  1" "$(cat "$RS_RECORD_CAPTURE")"

echo ""
echo "--- 単発経路 run_reviewer_stage: 非 timeout 失敗はリトライしない（対称性） ---"

rc=$(run_rv_case "42" "CODEX_DEFAULT_TIMEOUT_SEC=1800")
assert_eq "単発経路: 非 timeout 失敗 (rc=42) は従来どおり rc=2" "2" "$rc"
assert_eq "単発経路: 非 timeout 失敗ではリトライしない（呼び出し 1 回）" "1" "$(codex_call_count)"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
