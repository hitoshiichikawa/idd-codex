#!/usr/bin/env bash
#
# 用途: Issue #145 Defect A（arm 後の terminal 遷移を disarm する processor / idd-claude #434
#       移植）で新規追加した local-watcher/bin/idd-codex-modules/auto-merge-disarm.sh の
#       関数群を fixture と gh stub で検証するスモークテスト。
#
#       対象関数:
#         - amx_resolve_gate_enabled    (gate OR 相乗り + kill switch AND / gate OFF 完全 no-op)
#         - amx_should_disarm_for_pr    (arm 済み + terminal ラベル + open の純粋判定)
#         - amx_disarm_pr               (gh pr merge --disable-auto / 失敗 WARN fail-continue)
#         - process_auto_merge_disarm   (GitHub 直接クエリ統合 / 1 件失敗で中断しない / 冪等)
#
#       検証観点:
#         - arm 済み + codex-failed → disarm 対象
#         - arm 済み + codex-needs-decisions → disarm 対象
#         - arm 済み + 両 terminal ラベル → disarm 対象
#         - arm 済みだが terminal ラベル無し → disarm しない（no-op）
#         - 未 arm（autoMergeRequest == null）→ 対象外（冪等 no-op）
#         - open でない（MERGED / CLOSED）→ 対象外
#         - disarm API 失敗 → WARN 1 行 + fail-continue（残り対象を中断しない）
#         - gate OFF（kill switch OFF / 両 arm 源 OFF / typo）→ gh ゼロ呼び出しの完全 no-op
#
# 配置先: local-watcher/test/auto_merge_disarm_test.sh
# 依存:   bash 4+, awk, grep, jq, mktemp
# 実行:   bash local-watcher/test/auto_merge_disarm_test.sh

set -euo pipefail
# shellcheck disable=SC2034  # eval で抽出した関数が遅延束縛で参照する変数をこのテスト内で定義する。

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
# shellcheck disable=SC2034  # eval 抽出関数が遅延束縛で参照する
LABEL_FAILED="codex-failed"
# shellcheck disable=SC2034  # eval 抽出関数が遅延束縛で参照する
LABEL_NEEDS_DECISIONS="codex-needs-decisions"
export AUTO_MERGE_GIT_TIMEOUT=5
export AUTO_MERGE_DISARM_MAX_PRS=10
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
      # `gh pr merge --repo ... --disable-auto -- <PR>` の PR 番号（末尾引数）を取る。
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
amx_log()   { printf 'LOG %s\n'  "$*" >>"$LOG_FILE"; }
amx_warn()  { printf 'WARN %s\n' "$*" >>"$LOG_FILE"; }
amx_error() { printf 'ERR %s\n'  "$*" >>"$LOG_FILE"; }
idd_secure_mktemp() { mktemp -t "idd-codex-test-${1:-x}.XXXXXX"; }

reset_state() {
  GH_CALL_LOG="$(mktemp)"; LOG_FILE="$(mktemp)"
  GH_PR_LIST_RESPONSE="[]"; GH_PR_LIST_RC=0
  GH_PR_MERGE_RC=0; GH_PR_MERGE_STDERR=""; GH_PR_MERGE_FAIL_FOR=""
}
calls() { grep -c "$1" "$GH_CALL_LOG" 2>/dev/null || true; }
logs()  { grep -c "$1" "$LOG_FILE" 2>/dev/null || true; }

PASS=0; FAIL=0
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label (expected='$expected' actual='$actual')"; FAIL=$((FAIL + 1))
  fi
}
assert_rc() {
  local label="$1" expected_rc="$2"; shift 2
  local actual_rc=0
  "$@" >/dev/null 2>&1 || actual_rc=$?
  if [ "$expected_rc" = "$actual_rc" ]; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label (expected rc=$expected_rc actual rc=$actual_rc)"; FAIL=$((FAIL + 1))
  fi
}

# PR JSON ビルダー: $1=num $2=head $3=state(OPEN/MERGED/CLOSED) $4=labels_csv $5=automerge(null|{..}) $6=owner
build_pr_json() {
  local labels_json="[]"
  [ -n "$4" ] && labels_json=$(printf '%s' "$4" | jq -R 'split(",")|map({name:.})')
  jq -nc --argjson num "$1" --arg head "$2" --arg state "$3" \
    --argjson labels "$labels_json" --argjson am "${5:-null}" --arg owner "${6:-owner}" \
    '{number:$num, headRefName:$head, state:$state, labels:$labels, autoMergeRequest:$am,
      url:("https://github.com/owner/repo/pull/" + ($num|tostring)),
      isDraft:false, headRepositoryOwner:{login:$owner}}'
}

ARMED='{"enabledAt":"2026-07-09T00:00:00Z"}'

# ============================================================
# Section 1: amx_resolve_gate_enabled（gate OR 相乗り + kill switch AND）
# ============================================================
echo "--- Section 1: amx_resolve_gate_enabled gate 判定 ---"

unset FULL_AUTO_ENABLED || true
AUTO_MERGE_ENABLED="true"; AUTO_MERGE_DESIGN_ENABLED="true"
assert_rc "kill switch OFF → gate OFF (rc=1)" 1 amx_resolve_gate_enabled

FULL_AUTO_ENABLED="true"
unset AUTO_MERGE_ENABLED AUTO_MERGE_DESIGN_ENABLED || true
assert_rc "両 arm 源 OFF（未設定）→ gate OFF (rc=1)" 1 amx_resolve_gate_enabled

FULL_AUTO_ENABLED="true"; AUTO_MERGE_ENABLED="true"
unset AUTO_MERGE_DESIGN_ENABLED || true
assert_rc "AUTO_MERGE_ENABLED のみ ON → gate ON (rc=0)" 0 amx_resolve_gate_enabled

FULL_AUTO_ENABLED="true"; AUTO_MERGE_DESIGN_ENABLED="true"
unset AUTO_MERGE_ENABLED || true
assert_rc "AUTO_MERGE_DESIGN_ENABLED のみ ON → gate ON (rc=0)" 0 amx_resolve_gate_enabled

FULL_AUTO_ENABLED="true"
for v in "" "false" "0" "True" "TRUE" "1" "on" "yes"; do
  AUTO_MERGE_ENABLED="$v"; AUTO_MERGE_DESIGN_ENABLED="$v"
  assert_rc "arm 源='$v'（typo / 不正値）は安全側 OFF" 1 amx_resolve_gate_enabled
done

# 以降のテスト用に gate を ON に戻す
FULL_AUTO_ENABLED="true"; AUTO_MERGE_ENABLED="true"; AUTO_MERGE_DESIGN_ENABLED="true"

# ============================================================
# Section 2: amx_should_disarm_for_pr 純粋判定
# ============================================================
echo ""
echo "--- Section 2: amx_should_disarm_for_pr 判定 ---"

PR_FAILED=$(build_pr_json 100 "codex/issue-145-impl-foo" "OPEN" "codex-failed" "$ARMED")
assert_rc "arm 済み + codex-failed → disarm 対象" 0 amx_should_disarm_for_pr "$PR_FAILED"

PR_NEEDS=$(build_pr_json 101 "codex/issue-145-impl-foo" "OPEN" "codex-needs-decisions" "$ARMED")
assert_rc "arm 済み + codex-needs-decisions → disarm 対象" 0 amx_should_disarm_for_pr "$PR_NEEDS"

PR_BOTH=$(build_pr_json 102 "codex/issue-145-impl-foo" "OPEN" "codex-failed,codex-needs-decisions" "$ARMED")
assert_rc "arm 済み + 両 terminal ラベル → disarm 対象" 0 amx_should_disarm_for_pr "$PR_BOTH"

PR_NO_TERMINAL=$(build_pr_json 103 "codex/issue-145-impl-foo" "OPEN" "codex-ready-for-review" "$ARMED")
assert_rc "arm 済み + terminal ラベル無し → disarm しない" 1 amx_should_disarm_for_pr "$PR_NO_TERMINAL"

PR_NOT_ARMED=$(build_pr_json 104 "codex/issue-145-impl-foo" "OPEN" "codex-failed" "null")
assert_rc "未 arm + codex-failed → 対象外（冪等 no-op）" 1 amx_should_disarm_for_pr "$PR_NOT_ARMED"

PR_MERGED=$(build_pr_json 105 "codex/issue-145-impl-foo" "MERGED" "codex-failed" "$ARMED")
assert_rc "MERGED PR → disarm 対象外" 1 amx_should_disarm_for_pr "$PR_MERGED"

PR_CLOSED=$(build_pr_json 106 "codex/issue-145-impl-foo" "CLOSED" "codex-needs-decisions" "$ARMED")
assert_rc "CLOSED PR → disarm 対象外" 1 amx_should_disarm_for_pr "$PR_CLOSED"

PR_DESIGN=$(build_pr_json 107 "codex/issue-145-design-foo" "OPEN" "codex-failed" "$ARMED")
assert_rc "design PR でも arm + terminal なら disarm 対象" 0 amx_should_disarm_for_pr "$PR_DESIGN"

# 空入力（labels 空 + 未 arm）
PR_EMPTY=$(build_pr_json 108 "codex/issue-145-impl-foo" "OPEN" "" "null")
assert_rc "空ラベル + 未 arm → 対象外（空入力）" 1 amx_should_disarm_for_pr "$PR_EMPTY"

# ============================================================
# Section 3: amx_disarm_pr 呼び出し検証
# ============================================================
echo ""
echo "--- Section 3: amx_disarm_pr 呼び出し検証 ---"

reset_state
GH_PR_MERGE_RC=0
amx_disarm_pr 100 "codex/issue-145-impl-foo" "https://github.com/owner/repo/pull/100"
assert_eq "amx_disarm_pr → gh pr merge 1 回発火" "1" "$(calls '^gh pr merge')"
assert_eq "--disable-auto フラグあり" "1" "$(calls 'gh pr merge.*--disable-auto')"
assert_eq "-- でオプション解釈打ち切り + PR 番号" "1" "$(calls 'gh pr merge.*-- 100')"
assert_eq "成功時 disarmed log line に PR 番号" "1" "$(logs 'PR #100.*disarmed')"

reset_state
GH_PR_MERGE_RC=1
GH_PR_MERGE_STDERR="HTTP 422: something failed"
amx_disarm_pr 200 "codex/issue-145-impl-bar" "https://github.com/owner/repo/pull/200" || true
assert_eq "disarm 失敗時 WARN を 1 行残す（silent fail 禁止）" "1" "$(logs 'WARN PR #200.*disarm failed')"
assert_rc "disarm 失敗で rc=1（呼出側 fail-continue で吸収）" 1 amx_disarm_pr 200 "head" "url"

reset_state
GH_PR_MERGE_RC=0
amx_disarm_pr "abc" "codex/issue-145-impl" "url" || true
assert_eq "数値以外の PR 番号で gh pr merge を呼ばない" "0" "$(calls '^gh pr merge')"
assert_eq "数値以外の PR 番号で WARN を残す" "1" "$(logs 'WARN PR number')"

# ============================================================
# Section 4: process_auto_merge_disarm 統合
# ============================================================
echo ""
echo "--- Section 4: process_auto_merge_disarm 統合 ---"

# Case A: gate OFF（kill switch OFF）→ gh ゼロ呼び出し
reset_state
unset FULL_AUTO_ENABLED || true
AUTO_MERGE_ENABLED="true"; AUTO_MERGE_DESIGN_ENABLED="true"
process_auto_merge_disarm
assert_eq "kill switch OFF で gh ゼロ呼び出し（完全 no-op）" "0" "$(calls '^gh ')"

# Case B: gate OFF（両 arm 源 OFF）→ gh ゼロ呼び出し
reset_state
FULL_AUTO_ENABLED="true"
unset AUTO_MERGE_ENABLED AUTO_MERGE_DESIGN_ENABLED || true
process_auto_merge_disarm
assert_eq "両 arm 源 OFF で gh ゼロ呼び出し（完全 no-op）" "0" "$(calls '^gh ')"

# 以降 gate ON
# shellcheck disable=SC2034  # eval 抽出関数が遅延束縛で参照する
FULL_AUTO_ENABLED="true"
# shellcheck disable=SC2034  # eval 抽出関数が遅延束縛で参照する
AUTO_MERGE_ENABLED="true"
# shellcheck disable=SC2034  # eval 抽出関数が遅延束縛で参照する
AUTO_MERGE_DESIGN_ENABLED="true"

# Case C: arm 済み + codex-failed の impl PR 1 件 → GitHub 直接クエリ + disarm 1 回
reset_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 300 "codex/issue-145-impl-foo" "OPEN" "codex-failed" "$ARMED")]"
process_auto_merge_disarm
assert_eq "GitHub 直接クエリ（gh pr list）で対象列挙" "1" "$(calls '^gh pr list')"
assert_eq "arm + codex-failed → disarm 1 回" "1" "$(calls '^gh pr merge.*--disable-auto')"
assert_eq "サマリ行に disarmed=1" "1" "$(logs 'summary: disarmed=1')"

# Case D: 対象 0 件（arm 済みだが terminal ラベル無し）→ disarm 呼び出しゼロ + サマリのみ
reset_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 301 "codex/issue-145-impl-foo" "OPEN" "codex-ready-for-review" "$ARMED")]"
process_auto_merge_disarm
assert_eq "terminal ラベル無し → disarm 呼び出しゼロ" "0" "$(calls '^gh pr merge')"
assert_eq "対象 0 件はサマリ 1 行のみ" "1" "$(logs 'summary: disarmed=0 failed=0')"

# Case E: 未 arm + terminal → disarm 呼び出しゼロ（冪等: 既 disarm 済みは no-op）
reset_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 302 "codex/issue-145-impl-foo" "OPEN" "codex-failed" "null")]"
process_auto_merge_disarm
assert_eq "未 arm（disarm 済み）PR → disarm 呼び出しゼロ（冪等）" "0" "$(calls '^gh pr merge')"

# Case F: 人間手書き PR（head pattern mismatch）→ disarm 呼び出しゼロ
reset_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 303 "feature/manual-pr" "OPEN" "codex-failed" "$ARMED")]"
process_auto_merge_disarm
assert_eq "head pattern mismatch（手書き PR）→ disarm 呼び出しゼロ" "0" "$(calls '^gh pr merge')"

# Case G: design PR + arm + codex-needs-decisions → disarm 1 回（design head pattern の OR）
reset_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 304 "codex/issue-145-design-foo" "OPEN" "codex-needs-decisions" "$ARMED")]"
process_auto_merge_disarm
assert_eq "design PR + arm + needs-decisions → disarm 1 回" "1" "$(calls '^gh pr merge.*--disable-auto')"

# Case H: 3 件中 1 件失敗 → 残りを中断しない（fail-continue）
reset_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 305 "codex/issue-145-impl-a" "OPEN" "codex-failed" "$ARMED"),$(build_pr_json 306 "codex/issue-145-impl-b" "OPEN" "codex-failed" "$ARMED"),$(build_pr_json 307 "codex/issue-145-impl-c" "OPEN" "codex-failed" "$ARMED")]"
GH_PR_MERGE_FAIL_FOR="306"
GH_PR_MERGE_STDERR="HTTP 500: boom"
process_auto_merge_disarm
assert_eq "1 件失敗でも 3 件すべて disarm を試行する" "3" "$(calls '^gh pr merge.*--disable-auto')"
assert_eq "サマリに disarmed=2 failed=1" "1" "$(logs 'summary: disarmed=2 failed=1')"

# Case I: MERGED PR + arm + terminal → disarm 呼び出しゼロ
reset_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 308 "codex/issue-145-impl-foo" "MERGED" "codex-failed" "$ARMED")]"
process_auto_merge_disarm
assert_eq "MERGED PR → disarm 呼び出しゼロ" "0" "$(calls '^gh pr merge')"

# Case J: gh pr list 失敗 → WARN 1 行 + rc=0（パイプライン継続）
reset_state
GH_PR_LIST_RC=1
assert_rc "gh pr list 失敗でも rc=0（fail-continue 契約）" 0 process_auto_merge_disarm
reset_state
GH_PR_LIST_RC=1
process_auto_merge_disarm
assert_eq "gh pr list 失敗で WARN を残す" "1" "$(logs 'WARN 対象 PR 一覧の取得に失敗')"

# Case K: 上限（AUTO_MERGE_DISARM_MAX_PRS=1）→ 1 件処理 + 持ち越しログ
reset_state
AUTO_MERGE_DISARM_MAX_PRS=1
GH_PR_LIST_RESPONSE="[$(build_pr_json 309 "codex/issue-145-impl-a" "OPEN" "codex-failed" "$ARMED"),$(build_pr_json 310 "codex/issue-145-impl-b" "OPEN" "codex-failed" "$ARMED")]"
process_auto_merge_disarm
assert_eq "上限 1 で disarm は 1 回のみ" "1" "$(calls '^gh pr merge.*--disable-auto')"
assert_eq "上限到達の持ち越しログ" "1" "$(logs '上限 1 に到達')"
AUTO_MERGE_DISARM_MAX_PRS=10

# Case L: 不正な上限値（typo）は既定 10 に正規化されて全件処理
reset_state
AUTO_MERGE_DISARM_MAX_PRS="abc"
GH_PR_LIST_RESPONSE="[$(build_pr_json 311 "codex/issue-145-impl-a" "OPEN" "codex-failed" "$ARMED"),$(build_pr_json 312 "codex/issue-145-impl-b" "OPEN" "codex-failed" "$ARMED")]"
process_auto_merge_disarm
assert_eq "不正上限値は既定 10 へ正規化（2 件とも処理）" "2" "$(calls '^gh pr merge.*--disable-auto')"
AUTO_MERGE_DISARM_MAX_PRS=10

# Case M: fork PR（headRepositoryOwner 不一致）→ disarm 呼び出しゼロ
reset_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 313 "codex/issue-145-impl-foo" "OPEN" "codex-failed" "$ARMED" "attacker")]"
process_auto_merge_disarm
assert_eq "fork PR（owner 不一致）→ disarm 呼び出しゼロ" "0" "$(calls '^gh pr merge')"

# Case N: 空リスト（open PR なし）→ gh pr merge ゼロ + サマリのみ
reset_state
GH_PR_LIST_RESPONSE="[]"
process_auto_merge_disarm
assert_eq "open PR なし → disarm 呼び出しゼロ（空入力）" "0" "$(calls '^gh pr merge')"
assert_eq "空リストでもサマリ 1 行" "1" "$(logs 'summary: disarmed=0 failed=0')"

echo ""
echo "=================================================="
echo "RESULT: PASS=$PASS FAIL=$FAIL"
echo "=================================================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
