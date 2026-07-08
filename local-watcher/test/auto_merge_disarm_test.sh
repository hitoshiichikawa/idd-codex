#!/usr/bin/env bash
#
# 用途: auto-merge-disarm.sh（#145 / idd-claude #434 Defect A 移植）の gate / 対象判定 /
#       disarm 呼び出し / dispatcher 統合を gh・timeout stub で検証する。
#
#       検証観点:
#         - gate: FULL_AUTO_ENABLED AND (AUTO_MERGE_ENABLED OR AUTO_MERGE_DESIGN_ENABLED)。
#           OFF（既定）では gh ゼロ呼び出しの no-op（後方互換）
#         - arm 済み + terminal ラベル（codex-failed / codex-needs-decisions）→ disarm 呼び出し
#         - terminal ラベル無し / 未 arm / open でない → no-op
#         - disarm API 失敗 → WARN + fail-continue（残り PR を中断しない）
#         - head pattern mismatch（人間手書き PR）→ 対象外
#
# 配置先: local-watcher/test/auto_merge_disarm_test.sh
# 依存:   bash 4+, awk, grep, jq, mktemp
# 実行:   bash local-watcher/test/auto_merge_disarm_test.sh
# 前提:   auto-merge-disarm.sh から amx_* 関数、watcher から full_auto_enabled を awk 抽出 → eval。

set -euo pipefail
# shellcheck disable=SC2034  # eval で抽出した関数が参照する環境変数をこのテスト内で定義する。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/auto-merge-disarm.sh"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
for f in "$MODULE_SH" "$WATCHER_SH"; do
  [ -f "$f" ] || { echo "ERROR: not found: $f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 2; }

extract_function() {
  local script="$1" fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

for fn in amx_resolve_gate_enabled amx_should_disarm_for_pr amx_disarm_pr \
  process_auto_merge_disarm; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$MODULE_SH" "$fn")"
done
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "full_auto_enabled")"

for fn in amx_resolve_gate_enabled amx_should_disarm_for_pr amx_disarm_pr \
  process_auto_merge_disarm full_auto_enabled; do
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done

# ─── 環境 / stub ───
export REPO="owner/repo"
export LABEL_FAILED="codex-failed"; export LABEL_NEEDS_DECISIONS="codex-needs-decisions"
export AUTO_MERGE_DISARM_MAX_PRS=10; export AUTO_MERGE_GIT_TIMEOUT=5
export AUTO_MERGE_HEAD_PATTERN='^codex/issue-.*-impl'
export AUTO_MERGE_DESIGN_HEAD_PATTERN='^codex/issue-.*-design'
GH_CALL_LOG=""; LOG_FILE=""; GH_PR_LIST_RESPONSE="[]"; GH_PR_LIST_RC=0
GH_PR_MERGE_RC=0; GH_PR_MERGE_STDERR=""; GH_PR_MERGE_FAIL_FOR=""

timeout() { shift; "$@"; }
gh() {
  printf 'gh %s\n' "$*" >>"$GH_CALL_LOG"
  case "$1 $2" in
    "pr list")
      [ "$GH_PR_LIST_RC" -ne 0 ] && return "$GH_PR_LIST_RC"
      printf '%s' "$GH_PR_LIST_RESPONSE"
      ;;
    "pr merge")
      # `gh pr merge --repo ... --disable-auto -- <PR>` の PR 番号を末尾引数から取る。
      local last_arg=""
      for last_arg in "$@"; do :; done
      if [ -n "$GH_PR_MERGE_FAIL_FOR" ] && [ "$last_arg" = "$GH_PR_MERGE_FAIL_FOR" ]; then
        [ -n "$GH_PR_MERGE_STDERR" ] && printf '%s\n' "$GH_PR_MERGE_STDERR" >&2
        return 1
      fi
      [ -n "$GH_PR_MERGE_STDERR" ] && printf '%s\n' "$GH_PR_MERGE_STDERR" >&2
      return "$GH_PR_MERGE_RC"
      ;;
  esac
  return 0
}
amx_log()  { printf 'LOG %s\n'  "$*" >>"$LOG_FILE"; }
amx_warn() { printf 'WARN %s\n' "$*" >>"$LOG_FILE"; }
amx_error(){ printf 'ERR %s\n'  "$*" >>"$LOG_FILE"; }
idd_secure_mktemp() { mktemp -t "idd-codex-test-${1:-x}.XXXXXX"; }

reset_state() {
  GH_CALL_LOG="$(mktemp)"; LOG_FILE="$(mktemp)"
  GH_PR_LIST_RESPONSE="[]"; GH_PR_LIST_RC=0
  GH_PR_MERGE_RC=0; GH_PR_MERGE_STDERR=""; GH_PR_MERGE_FAIL_FOR=""
}
calls() { grep -c "$1" "$GH_CALL_LOG" 2>/dev/null || true; }
logs()  { grep -c "$1" "$LOG_FILE" 2>/dev/null || true; }

# PR JSON ビルダー: $1=num $2=head $3=state(OPEN/MERGED/CLOSED) $4=labels_csv $5=automerge(null|{..}) $6=owner
build_pr_json() {
  local labels_json="[]"
  [ -n "$4" ] && labels_json=$(printf '%s' "$4" | jq -R 'split(",")|map({name:.})')
  jq -nc --argjson num "$1" --arg head "$2" --arg state "$3" \
    --argjson labels "$labels_json" --argjson am "${5:-null}" --arg owner "${6:-owner}" \
    '{number:$num,headRefName:$head,state:$state,isDraft:false,labels:$labels,autoMergeRequest:$am,url:("https://x/pr/" + ($num|tostring)),headRepositoryOwner:{login:$owner}}'
}

ARMED='{"enabledAt":"2026-07-01T00:00:00Z"}'

PASS=0; FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS: $1"
  else FAIL=$((FAIL+1)); echo "FAIL: $1 (expected=$2 actual=$3)"; fi
}
assert_rc() {
  local label="$1" expected="$2"; shift 2
  local rc=0; "$@" >/dev/null 2>&1 || rc=$?
  assert_eq "$label" "$expected" "$rc"
}

# ============================================================
echo "--- Section 1: amx_resolve_gate_enabled（gate OR 相乗り + kill switch AND） ---"
# ============================================================

unset FULL_AUTO_ENABLED
AUTO_MERGE_ENABLED="true"; AUTO_MERGE_DESIGN_ENABLED="true"
assert_rc "kill switch OFF → gate OFF" 1 amx_resolve_gate_enabled

FULL_AUTO_ENABLED="true"
unset AUTO_MERGE_ENABLED AUTO_MERGE_DESIGN_ENABLED
assert_rc "両 arm 源 OFF → gate OFF" 1 amx_resolve_gate_enabled

FULL_AUTO_ENABLED="true"; AUTO_MERGE_ENABLED="true"; unset AUTO_MERGE_DESIGN_ENABLED
assert_rc "AUTO_MERGE_ENABLED のみ ON → gate ON" 0 amx_resolve_gate_enabled

FULL_AUTO_ENABLED="true"; unset AUTO_MERGE_ENABLED; AUTO_MERGE_DESIGN_ENABLED="true"
assert_rc "AUTO_MERGE_DESIGN_ENABLED のみ ON → gate ON" 0 amx_resolve_gate_enabled

FULL_AUTO_ENABLED="true"
for v in "" "false" "0" "True" "TRUE" "1" "on" "yes"; do
  AUTO_MERGE_ENABLED="$v"; AUTO_MERGE_DESIGN_ENABLED="$v"
  assert_rc "arm 源='$v' は安全側 OFF" 1 amx_resolve_gate_enabled
done
FULL_AUTO_ENABLED="true"; AUTO_MERGE_ENABLED="true"; AUTO_MERGE_DESIGN_ENABLED="true"

# ============================================================
echo ""
echo "--- Section 2: amx_should_disarm_for_pr 純粋判定 ---"
# ============================================================

PR_FAILED=$(build_pr_json 100 "codex/issue-145-impl-foo" "OPEN" "codex-failed" "$ARMED")
assert_rc "arm 済み + codex-failed → disarm 対象" 0 amx_should_disarm_for_pr "$PR_FAILED"

PR_NEEDS=$(build_pr_json 101 "codex/issue-145-impl-foo" "OPEN" "codex-needs-decisions" "$ARMED")
assert_rc "arm 済み + codex-needs-decisions → disarm 対象" 0 amx_should_disarm_for_pr "$PR_NEEDS"

PR_BOTH=$(build_pr_json 102 "codex/issue-145-impl-foo" "OPEN" "codex-failed,codex-needs-decisions" "$ARMED")
assert_rc "arm 済み + 両 terminal ラベル → disarm 対象" 0 amx_should_disarm_for_pr "$PR_BOTH"

PR_NO_TERMINAL=$(build_pr_json 103 "codex/issue-145-impl-foo" "OPEN" "codex-ready-for-review" "$ARMED")
assert_rc "arm 済み + terminal ラベル無し → disarm しない" 1 amx_should_disarm_for_pr "$PR_NO_TERMINAL"

PR_NOT_ARMED=$(build_pr_json 104 "codex/issue-145-impl-foo" "OPEN" "codex-failed" "null")
assert_rc "未 arm + codex-failed → 対象外（no-op）" 1 amx_should_disarm_for_pr "$PR_NOT_ARMED"

PR_MERGED=$(build_pr_json 105 "codex/issue-145-impl-foo" "MERGED" "codex-failed" "$ARMED")
assert_rc "MERGED PR → 対象外" 1 amx_should_disarm_for_pr "$PR_MERGED"

PR_CLOSED=$(build_pr_json 106 "codex/issue-145-impl-foo" "CLOSED" "codex-needs-decisions" "$ARMED")
assert_rc "CLOSED PR → 対象外" 1 amx_should_disarm_for_pr "$PR_CLOSED"

PR_DESIGN=$(build_pr_json 107 "codex/issue-145-design-foo" "OPEN" "codex-failed" "$ARMED")
assert_rc "design PR でも arm + terminal なら disarm 対象" 0 amx_should_disarm_for_pr "$PR_DESIGN"

# ============================================================
echo ""
echo "--- Section 3: amx_disarm_pr 呼び出し検証 ---"
# ============================================================

reset_state
amx_disarm_pr 100 "codex/issue-145-impl-foo" "https://x/pr/100"
assert_eq "gh pr merge が 1 回発火" "1" "$(calls '^gh pr merge')"
assert_eq "--disable-auto フラグあり" "1" "$(calls 'gh pr merge.*--disable-auto')"
assert_eq "-- でオプション解釈打ち切り + PR 番号" "1" "$(calls 'gh pr merge.*-- 100')"
assert_eq "成功時 disarmed log line" "1" "$(logs 'PR #100.*disarmed')"

reset_state
GH_PR_MERGE_RC=1; GH_PR_MERGE_STDERR="HTTP 422: something failed"
assert_rc "disarm 失敗で rc=1（fail-continue 呼出側で吸収）" 1 amx_disarm_pr 200 "head" "url"
assert_eq "disarm 失敗時 WARN を残す（silent fail 禁止）" "1" "$(logs 'WARN PR #200.*disarm failed')"

reset_state
amx_disarm_pr "abc; rm -rf /" "head" "url" || true
assert_eq "数値以外の PR 番号で gh pr merge を呼ばない" "0" "$(calls '^gh pr merge')"
assert_eq "数値以外の PR 番号は WARN + skip" "1" "$(logs 'WARN PR number')"

# ============================================================
echo ""
echo "--- Section 4: process_auto_merge_disarm 統合 ---"
# ============================================================

# Case A: kill switch OFF → gh ゼロ呼び出し
reset_state
unset FULL_AUTO_ENABLED
AUTO_MERGE_ENABLED="true"; AUTO_MERGE_DESIGN_ENABLED="true"
process_auto_merge_disarm
assert_eq "kill switch OFF で gh ゼロ呼び出し" "0" "$(calls '^gh ')"

# Case B: 両 arm 源 OFF → gh ゼロ呼び出し
reset_state
FULL_AUTO_ENABLED="true"
unset AUTO_MERGE_ENABLED AUTO_MERGE_DESIGN_ENABLED
process_auto_merge_disarm
assert_eq "両 arm 源 OFF で gh ゼロ呼び出し" "0" "$(calls '^gh ')"

# 以降 gate ON
export FULL_AUTO_ENABLED="true"; export AUTO_MERGE_ENABLED="true"; export AUTO_MERGE_DESIGN_ENABLED="true"

# Case C: arm 済み + codex-failed の impl PR 1 件 → disarm 1 回
reset_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 300 "codex/issue-145-impl-foo" "OPEN" "codex-failed" "$ARMED")]"
process_auto_merge_disarm
assert_eq "GitHub 直接クエリ（gh pr list）で対象列挙" "1" "$(calls '^gh pr list')"
assert_eq "arm + codex-failed → disarm 1 回" "1" "$(calls '^gh pr merge.*--disable-auto')"
assert_eq "サマリ行に disarmed=1" "1" "$(logs 'サマリ: disarmed=1, failed=0')"

# Case D: 対象 0 件（terminal ラベル無し）→ disarm 呼び出しゼロ
reset_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 301 "codex/issue-145-impl-foo" "OPEN" "codex-ready-for-review" "$ARMED")]"
process_auto_merge_disarm
assert_eq "terminal ラベル無し → disarm 呼び出しゼロ" "0" "$(calls '^gh pr merge')"
assert_eq "対象 0 件はサマリ 1 行のみ" "1" "$(logs 'サマリ: disarmed=0, failed=0')"

# Case E: 未 arm + terminal → disarm 呼び出しゼロ
reset_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 302 "codex/issue-145-impl-foo" "OPEN" "codex-failed" "null")]"
process_auto_merge_disarm
assert_eq "未 arm PR → disarm 呼び出しゼロ" "0" "$(calls '^gh pr merge')"

# Case F: 人間手書き PR（head pattern mismatch）→ disarm 呼び出しゼロ
reset_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 303 "feature/manual-pr" "OPEN" "codex-failed" "$ARMED")]"
process_auto_merge_disarm
assert_eq "head pattern mismatch（手書き PR）→ disarm 呼び出しゼロ" "0" "$(calls '^gh pr merge')"

# Case G: fork PR（headRepositoryOwner mismatch）→ disarm 呼び出しゼロ
reset_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 304 "codex/issue-145-impl-foo" "OPEN" "codex-failed" "$ARMED" "attacker")]"
process_auto_merge_disarm
assert_eq "fork PR → disarm 呼び出しゼロ" "0" "$(calls '^gh pr merge')"

# Case H: design PR + arm + codex-needs-decisions → disarm 1 回（design head pattern OR）
reset_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 305 "codex/issue-145-design-foo" "OPEN" "codex-needs-decisions" "$ARMED")]"
process_auto_merge_disarm
assert_eq "design PR + arm + needs-decisions → disarm 1 回" "1" "$(calls '^gh pr merge.*--disable-auto')"

# Case I: 3 件中 1 件失敗 → 残りを中断しない（fail-continue）
reset_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 306 "codex/issue-145-impl-a" "OPEN" "codex-failed" "$ARMED"),$(build_pr_json 307 "codex/issue-145-impl-b" "OPEN" "codex-failed" "$ARMED"),$(build_pr_json 308 "codex/issue-145-impl-c" "OPEN" "codex-failed" "$ARMED")]"
GH_PR_MERGE_FAIL_FOR="307"; GH_PR_MERGE_STDERR="HTTP 500: boom"
process_auto_merge_disarm
assert_eq "1 件失敗でも 3 件すべて disarm を試行" "3" "$(calls '^gh pr merge.*--disable-auto')"
assert_eq "サマリに disarmed=2, failed=1" "1" "$(logs 'サマリ: disarmed=2, failed=1')"

# Case J: gh pr list 失敗 → WARN + fail-continue（rc=0）
reset_state
GH_PR_LIST_RC=1
assert_rc "gh pr list 失敗でも rc=0（fail-continue）" 0 process_auto_merge_disarm
reset_state
GH_PR_LIST_RC=1
process_auto_merge_disarm
assert_eq "gh pr list 失敗で WARN 1 行" "1" "$(logs 'WARN 対象 PR 一覧の取得に失敗')"

# Case K: MERGED PR + arm + terminal → disarm 呼び出しゼロ
reset_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 309 "codex/issue-145-impl-foo" "MERGED" "codex-failed" "$ARMED")]"
process_auto_merge_disarm
assert_eq "MERGED PR → disarm 呼び出しゼロ" "0" "$(calls '^gh pr merge')"

# Case L: AUTO_MERGE_DISARM_MAX_PRS 上限で持ち越し
reset_state
AUTO_MERGE_DISARM_MAX_PRS=1
GH_PR_LIST_RESPONSE="[$(build_pr_json 310 "codex/issue-145-impl-a" "OPEN" "codex-failed" "$ARMED"),$(build_pr_json 311 "codex/issue-145-impl-b" "OPEN" "codex-failed" "$ARMED")]"
process_auto_merge_disarm
assert_eq "MAX_PRS=1 で disarm 1 回のみ" "1" "$(calls '^gh pr merge.*--disable-auto')"
assert_eq "上限到達ログを出す" "1" "$(logs '上限 1 に到達')"
AUTO_MERGE_DISARM_MAX_PRS=10

# ============================================================
echo ""
echo "=================================================="
echo "RESULT: PASS=$PASS FAIL=$FAIL"
echo "=================================================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
