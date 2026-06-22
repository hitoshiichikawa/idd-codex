#!/usr/bin/env bash
#
# 用途: pr-reviewer.sh の commit status publish 機能
#       (`pr_status_check_enabled` / `pr_publish_commit_status` / `pr_publish_codex_status`)
#       を gh/timeout stub で検証する。Issue #98（review status checks / codex-review）。
#
# 配置先: local-watcher/test/pr_publish_commit_status_test.sh
# 依存:   bash 4+, awk, grep, mktemp
# 実行:   bash local-watcher/test/pr_publish_commit_status_test.sh
# 前提:   pr-reviewer.sh から 3 関数だけを awk で切り出して eval。トップレベル副作用は回避。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/pr-reviewer.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find pr-reviewer.sh at $MODULE_SH" >&2
  exit 2
fi

extract_function() {
  local script="$1" fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

for fn in pr_status_check_enabled pr_publish_commit_status pr_publish_codex_status; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$MODULE_SH" "$fn")"
done

for fn in pr_status_check_enabled pr_publish_commit_status pr_publish_codex_status; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2; exit 2
  fi
done

# ─── stub / 環境 ───
REPO="owner/repo"
PR_REVIEWER_GIT_TIMEOUT="5"
GH_CALL_LOG=""
LOG_FILE=""
GH_NEXT_RC=0
SHA40="$(printf '0%.0s' {1..40})" # 40 桁 hex（"0" x40）

# timeout: 第1引数（秒）を捨てて残りを実行
timeout() { shift; "$@"; }
# gh: 引数を1行で記録し GH_NEXT_RC を返す
gh() { printf 'gh %s\n' "$*" >>"$GH_CALL_LOG"; return "${GH_NEXT_RC:-0}"; }
# logger: pr_log/pr_warn を記録ファイルへ
pr_log()  { printf 'LOG %s\n'  "$*" >>"$LOG_FILE"; }
pr_warn() { printf 'WARN %s\n' "$*" >>"$LOG_FILE"; }
# idd_secure_mktemp: 実 tempfile を返す
idd_secure_mktemp() { mktemp -t "idd-codex-test-${1:-x}.XXXXXX"; }

reset_state() {
  GH_CALL_LOG="$(mktemp)"; LOG_FILE="$(mktemp)"
  GH_NEXT_RC=0
  PR_STATUS_GATE_SUPPRESS_LOGGED=0
}
# grep -c は 0 件でも "0" を stdout に出し exit 1 を返すため、|| true で exit のみ吸収する
# （|| echo 0 にすると "0" が二重出力される）。
gh_calls() { grep -c '^gh ' "$GH_CALL_LOG" 2>/dev/null || true; }
log_grep_count() { grep -c "$1" "$LOG_FILE" 2>/dev/null || true; }

# ─── アサーションヘルパ ───
PASS_COUNT=0; FAIL_COUNT=0
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then echo "PASS: $label"; PASS_COUNT=$((PASS_COUNT+1))
  else echo "FAIL: $label"; echo "  expected: $(printf '%q' "$expected")"; echo "  actual  : $(printf '%q' "$actual")"; FAIL_COUNT=$((FAIL_COUNT+1)); fi
}
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in *"$needle"*) echo "PASS: $label"; PASS_COUNT=$((PASS_COUNT+1));;
    *) echo "FAIL: $label"; echo "  '$needle' not in: $haystack"; FAIL_COUNT=$((FAIL_COUNT+1));; esac
}

# ─── 1. gate ───
echo "--- gate: pr_status_check_enabled (AND 二重 opt-in) ---"
PR_REVIEWER_STATUS_CHECK_ENABLED=true;  FULL_AUTO_ENABLED=true
if pr_status_check_enabled; then assert_eq "両 gate true → ON" "on" "on"; else assert_eq "両 gate true → ON" "on" "off"; fi
PR_REVIEWER_STATUS_CHECK_ENABLED=true;  FULL_AUTO_ENABLED=false
if pr_status_check_enabled; then assert_eq "FULL_AUTO=false → OFF" "off" "on"; else assert_eq "FULL_AUTO=false → OFF" "off" "off"; fi
PR_REVIEWER_STATUS_CHECK_ENABLED=false; FULL_AUTO_ENABLED=true
if pr_status_check_enabled; then assert_eq "status=false → OFF" "off" "on"; else assert_eq "status=false → OFF" "off" "off"; fi

# ─── 2. gate OFF: no-op + suppression ログ 1 回 ───
echo ""; echo "--- gate OFF: 外部副作用ゼロ + suppression ログ cycle 1 回 ---"
reset_state
PR_REVIEWER_STATUS_CHECK_ENABLED=false; FULL_AUTO_ENABLED=true
rc=0; pr_publish_commit_status 12 "$SHA40" "codex-review" "success" "ok" "" || rc=$?
pr_publish_commit_status 13 "$SHA40" "codex-review" "success" "ok" "" || true
assert_eq "gate OFF → return 1"             "1"  "$rc"
assert_eq "gate OFF → gh 呼び出し 0 件"     "0"  "$(gh_calls)"
assert_eq "gate OFF → suppression ログ 1 回" "1" "$(log_grep_count 'suppressed by PR_REVIEWER_STATUS_CHECK_ENABLED')"

# ─── 3. 両 gate ON: POST 1 回 + payload ───
echo ""; echo "--- 両 gate ON: POST 1 回 + payload 検証 ---"
reset_state
PR_REVIEWER_STATUS_CHECK_ENABLED=true; FULL_AUTO_ENABLED=true
rc=0; pr_publish_commit_status 42 "$SHA40" "codex-review" "success" "codex: approve" "https://x/pr/42" || rc=$?
gh_line="$(cat "$GH_CALL_LOG")"
assert_eq "両 gate ON → return 0"      "0" "$rc"
assert_eq "両 gate ON → gh 呼び出し 1 件" "1" "$(gh_calls)"
assert_contains "POST path = statuses/{sha}" "$gh_line" "repos/owner/repo/statuses/${SHA40}"
assert_contains "payload state=success"      "$gh_line" "state=success"
assert_contains "payload context=codex-review" "$gh_line" "context=codex-review"
assert_contains "payload target_url 含む"    "$gh_line" "target_url=https://x/pr/42"

# target_url 空 → -f target_url= を渡さない
reset_state
PR_REVIEWER_STATUS_CHECK_ENABLED=true; FULL_AUTO_ENABLED=true
pr_publish_commit_status 42 "$SHA40" "codex-review" "failure" "codex: iteration" "" || true
case "$(cat "$GH_CALL_LOG")" in *target_url=*) assert_eq "target_url 空 → 渡さない" "absent" "present";; *) assert_eq "target_url 空 → 渡さない" "absent" "absent";; esac

# ─── 4. 入力検証（return 2, gh 0 件）───
echo ""; echo "--- 未信頼入力検証 ---"
reset_state; PR_REVIEWER_STATUS_CHECK_ENABLED=true; FULL_AUTO_ENABLED=true
rc=0; pr_publish_commit_status 42 "deadbeef" "codex-review" "success" "x" "" || rc=$?
assert_eq "不正 sha → return 2" "2" "$rc"
assert_eq "不正 sha → gh 0 件"  "0" "$(gh_calls)"
rc=0; pr_publish_commit_status "abc" "$SHA40" "codex-review" "success" "x" "" || rc=$?
assert_eq "不正 pr_number → return 2" "2" "$rc"
rc=0; pr_publish_commit_status 42 "$SHA40" "codex-review" "bogus" "x" "" || rc=$?
assert_eq "不正 state → return 2" "2" "$rc"

# ─── 5. API 失敗 → return 3 + WARN ───
echo ""; echo "--- API 失敗時の degrade ---"
reset_state; PR_REVIEWER_STATUS_CHECK_ENABLED=true; FULL_AUTO_ENABLED=true; GH_NEXT_RC=1
rc=0; pr_publish_commit_status 42 "$SHA40" "codex-review" "success" "x" "" || rc=$?
assert_eq "gh 失敗 → return 3" "3" "$rc"
assert_eq "gh 失敗 → WARN(FAILED) 1 件" "1" "$(log_grep_count 'commit status publish FAILED')"

# ─── 6. description 72 字切り詰め ───
echo ""; echo "--- description 72 字切り詰め ---"
reset_state; PR_REVIEWER_STATUS_CHECK_ENABLED=true; FULL_AUTO_ENABLED=true
long="$(printf 'd%.0s' {1..100})"
pr_publish_commit_status 42 "$SHA40" "codex-review" "success" "$long" "" || true
# 72 字 'd' を含み、73 字は含まない
d72="$(printf 'd%.0s' {1..72})"; d73="$(printf 'd%.0s' {1..73})"
case "$(cat "$GH_CALL_LOG")" in *"description=$d72"*) hit72=1;; *) hit72=0;; esac
case "$(cat "$GH_CALL_LOG")" in *"description=$d73"*) hit73=1;; *) hit73=0;; esac
assert_eq "description は 72 字に切り詰め（72 字一致）" "1" "$hit72"
assert_eq "description は 73 字を含まない"            "0" "$hit73"

# ─── 7. pr_publish_codex_status: verdict → state ───
echo ""; echo "--- pr_publish_codex_status: verdict → state マッピング ---"
reset_state; PR_REVIEWER_STATUS_CHECK_ENABLED=true; FULL_AUTO_ENABLED=true
pr_publish_codex_status 42 "$SHA40" "approve" "https://x/42" || true
assert_contains "approve → success"          "$(cat "$GH_CALL_LOG")" "state=success"
assert_contains "approve → context codex-review" "$(cat "$GH_CALL_LOG")" "context=codex-review"
reset_state; PR_REVIEWER_STATUS_CHECK_ENABLED=true; FULL_AUTO_ENABLED=true
pr_publish_codex_status 42 "$SHA40" "iteration" "https://x/42" || true
assert_contains "iteration → failure"        "$(cat "$GH_CALL_LOG")" "state=failure"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
