#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-issue-watcher.sh の Quota-Aware Stage Wrapper
#       (qa_run_codex_stage) を fixture で end-to-end 検証する。
#       Issue #104 で導入。
#
#       検証観点（Req と対応付け）:
#         - 現行スキーマ rate_limit_event_v2 検出 → exit 99 + reset_file = epoch
#           (Req 1.1, 1.2, 5.4)
#         - 旧スキーマ rate_limit_event_v1 検出 → exit 99 + reset_file = epoch
#           (Req 2.1, 5.4)
#         - synthetic 429 result（rate_limit_info 同居） → exit 99 + reset_file = epoch
#           (Req 3.1, 3.3, 5.4)
#         - 通常成功（detection なし） → exit 0
#           (Req 3.4)
#         - synthetic 429 のみで reset 不在 → codex_rc 透過 + warn
#           (Req 3.2)
#         - usage-limit fatal + reset あり → exit 99 + reset_file = epoch
#           (Issue #12 Req 1, 2, 3, 6)
#         - usage-limit fatal + reset なし → codex_rc 透過
#           (Issue #12 Option B / Req 4)
#         - opt-out (QUOTA_AWARE_ENABLED!=true) → 素通し
#           (NFR 1.1)
#
# 配置先: local-watcher/test/qa_run_codex_stage_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/qa_run_codex_stage_test.sh
# 前提:   idd-codex-issue-watcher.sh から関数 2 つ（qa_log/qa_warn/qa_error と
#         qa_detect_rate_limit / qa_run_codex_stage）を切り出して読み込む。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
# #177 Part 1 で低レベル共通ユーティリティ（qa_log 等のロガーを含む）は
# modules/core_utils.sh へ分離された。関数抽出の探索元に core_utils.sh も含める。
CORE_UTILS_SH="$SCRIPT_DIR/../bin/modules/core_utils.sh"
# #180 Part 2 で quota 待機制御プロセッサ（qa_detect_rate_limit / qa_run_codex_stage 等）は
# modules/quota-aware.sh へ分離された。関数抽出の探索元に quota-aware.sh も含める。
QUOTA_AWARE_SH="$SCRIPT_DIR/../bin/modules/quota-aware.sh"
RUN_SUMMARY_SH="$SCRIPT_DIR/../bin/modules/run-summary.sh"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/qa_detect_rate_limit"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi
if [ ! -f "$CORE_UTILS_SH" ]; then
  echo "ERROR: cannot find core_utils.sh at $CORE_UTILS_SH" >&2
  exit 2
fi
if [ ! -f "$QUOTA_AWARE_SH" ]; then
  echo "ERROR: cannot find quota-aware.sh at $QUOTA_AWARE_SH" >&2
  exit 2
fi
if [ ! -f "$RUN_SUMMARY_SH" ]; then
  echo "ERROR: cannot find run-summary.sh at $RUN_SUMMARY_SH" >&2
  exit 2
fi

# 一時 LOG ファイル（qa_run_codex_stage は $LOG に tee する）
TMPDIR_TEST=$(mktemp -d)
LOG="$TMPDIR_TEST/test.log"
export LOG
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# 必要な関数だけを抽出して eval で読み込む。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script" "$CORE_UTILS_SH" "$QUOTA_AWARE_SH" "$RUN_SUMMARY_SH"
}

# qa_log / qa_warn / qa_error は qa_run_codex_stage が呼ぶので必ず loaded する
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_log")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_warn")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_error")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_detect_rate_limit")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_extract_usage_limit_reset_epoch")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_sanitize_summary_token")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_infer_collab_agent_role")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_collab_mark_seen")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_collab_set_repeated_flag")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_detect_collab_spawn_failures")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_run_codex_stage")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_format_iso8601")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_persist_reset_time")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_build_escalation_comment")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_handle_quota_exceeded")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "codex_log_detect_529")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "rs_init")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "rs_sanitize_token")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "rs_record_degraded_event")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "rs_emit")"

for fn in qa_log qa_warn qa_error qa_detect_rate_limit qa_extract_usage_limit_reset_epoch qa_sanitize_summary_token qa_infer_collab_agent_role qa_collab_mark_seen qa_collab_set_repeated_flag qa_detect_collab_spawn_failures qa_run_codex_stage qa_format_iso8601 qa_persist_reset_time qa_build_escalation_comment qa_handle_quota_exceeded codex_log_detect_529 rs_init rs_sanitize_token rs_record_degraded_event rs_emit; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

REPO="owner/test"
REPO_SLUG="owner-test"
LOG_DIR="$TMPDIR_TEST/logs"
QUOTA_RESET_STATE_FILE="$TMPDIR_TEST/quota-reset-times.json"
QUOTA_RESUME_GRACE_SEC="60"
LABEL_CLAIMED="codex-claimed"
LABEL_PICKED="codex-picked-up"
LABEL_NEEDS_QUOTA_WAIT="codex-needs-quota-wait"
LABEL_FAILED="codex-failed"
GH_CALL_LOG="$TMPDIR_TEST/gh-calls.log"
MARK_FAILED_LOG="$TMPDIR_TEST/mark-failed.log"
export REPO REPO_SLUG LOG_DIR QUOTA_RESET_STATE_FILE QUOTA_RESUME_GRACE_SEC
export LABEL_CLAIMED LABEL_PICKED LABEL_NEEDS_QUOTA_WAIT LABEL_FAILED

gh() {
  printf '%s\n' "$*" >> "$GH_CALL_LOG"
  return 0
}

mark_issue_failed() {
  printf '%s\n' "$*" >> "$MARK_FAILED_LOG"
  return 0
}

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

assert_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  missing: $(printf '%q' "$needle")"
    echo "  in     : $(printf '%q' "$haystack")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  unexpected: $(printf '%q' "$needle")"
    echo "  in        : $(printf '%q' "$haystack")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# fake-codex: fixture を stdout にダンプし、指定された exit code を返す。
# qa_run_codex_stage は "$@" を実行するため、引数として fixture と rc を受け取る。
fake_codex() {
  local fx_path="$1"
  local rc="${2:-0}"
  cat "$fx_path"
  return "$rc"
}

fake_codex_sequence() {
  local state_file="$1"
  local first_fx="$2"
  local second_fx="$3"
  if [ ! -f "$state_file" ]; then
    : > "$state_file"
    cat "$FIXTURE_DIR/$first_fx"
    return 1
  fi
  cat "$FIXTURE_DIR/$second_fx"
  return 0
}

fake_codex_repeat_failure() {
  local state_file="$1"
  local fx="$2"
  local rc="${3:-1}"
  printf 'attempt\n' >> "$state_file"
  cat "$FIXTURE_DIR/$fx"
  return "$rc"
}

reset_run_summary_for_test() {
  rs_init
  # shellcheck disable=SC2034  # eval で読み込んだ qa_* 関数が dynamic scope で参照する
  QA_COLLAB_SPAWN_SEEN_KEYS=""
  # shellcheck disable=SC2034
  QA_COLLAB_SPAWN_TOTAL_COUNT=0
  # shellcheck disable=SC2034
  QA_COLLAB_LAST_COUNT=0
  # shellcheck disable=SC2034
  QA_COLLAB_LAST_ROLES=""
  # shellcheck disable=SC2034
  QA_COLLAB_REPEATED_FLAG="no"
}

# テスト 1 件を実行する補助関数。
# Args: <test_label> <expected_rc> <expected_reset_file_content> <fixture> [fake_codex_rc] [stage_label]
# QUOTA_AWARE_ENABLED は呼び出し側で export する想定。
run_case() {
  local label="$1"
  local expected_rc="$2"
  local expected_reset="$3"
  local fx="$4"
  local fake_rc="${5:-0}"
  local stage_label="${6:-TestStage}"

  local reset_file
  reset_file=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
  local rc=0
  qa_run_codex_stage "$stage_label" "$reset_file" -- \
    fake_codex "$FIXTURE_DIR/$fx" "$fake_rc" >/dev/null 2>&1 || rc=$?

  local actual_reset
  actual_reset=$(cat "$reset_file" 2>/dev/null || true)
  rm -f "$reset_file" "${reset_file}.detect"

  assert_eq "$label rc" "$expected_rc" "$rc"
  assert_eq "$label reset_file" "$expected_reset" "$actual_reset"
}

run_quota_wait_label_case() {
  local label="$1"
  local stage_label="$2"
  local reset_file
  reset_file=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
  : > "$GH_CALL_LOG"
  : > "$MARK_FAILED_LOG"
  rm -f "$QUOTA_RESET_STATE_FILE"

  local rc=0
  qa_run_codex_stage "$stage_label" "$reset_file" -- \
    fake_codex "$FIXTURE_DIR/usage-limit-with-reset.jsonl" 1 >/dev/null 2>&1 || rc=$?
  case "$rc" in
    99)
      qa_handle_quota_exceeded "12" "$stage_label" "$(cat "$reset_file")"
      rc=0
      ;;
    *)
      mark_issue_failed "$stage_label" "unexpected rc=${rc}"
      ;;
  esac

  local gh_calls mark_failed persisted_epoch
  gh_calls=$(cat "$GH_CALL_LOG" 2>/dev/null || true)
  mark_failed=$(cat "$MARK_FAILED_LOG" 2>/dev/null || true)
  persisted_epoch=$(jq -r '."12" // ""' "$QUOTA_RESET_STATE_FILE" 2>/dev/null || true)
  rm -f "$reset_file" "${reset_file}.detect"

  assert_eq "$label callsite rc" "0" "$rc"
  assert_contains "$label adds quota wait label" "$gh_calls" "--add-label $LABEL_NEEDS_QUOTA_WAIT"
  assert_not_contains "$label does not add failed label" "$gh_calls" "--add-label $LABEL_FAILED"
  assert_eq "$label mark_issue_failed not called" "" "$mark_failed"
  assert_eq "$label reset persisted" "$usage_reset_epoch" "$persisted_epoch"
}

run_collab_success_case() {
  local reset_file
  reset_file=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
  : > "$LOG"
  reset_run_summary_for_test

  local rc=0
  qa_run_codex_stage "StageA" "$reset_file" -- \
    fake_codex "$FIXTURE_DIR/collab-no-thread-developer.jsonl" 0 >> "$LOG" 2>&1 || rc=$?

  local summary log_body
  summary=$(rs_emit)
  log_body=$(cat "$LOG" 2>/dev/null || true)
  rm -f "$reset_file" "${reset_file}.detect" "${reset_file}.stream"

  assert_eq "collab degraded-success rc preserved" "0" "$rc"
  assert_contains "collab summary has structured event" "$summary" "degraded-events=collab_spawn_failed(stage=StageA,role=Developer,reason=no_thread_with_id,fallback=yes,degraded=yes,repeated=no)"
  assert_contains "collab summary marks errors" "$summary" "errors=yes"
  assert_contains "collab log records degraded-success fallback" "$log_body" "collab-spawn fallback result=degraded-success stage=StageA roles=Developer reason=no_thread_with_id"
}

run_collab_repeated_case() {
  local reset_file
  reset_file=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
  : > "$LOG"
  reset_run_summary_for_test

  local rc=0
  qa_run_codex_stage "StageA" "$reset_file" -- \
    fake_codex "$FIXTURE_DIR/collab-no-thread-repeated-pm.jsonl" 0 >> "$LOG" 2>&1 || rc=$?

  local summary log_body
  summary=$(rs_emit)
  log_body=$(cat "$LOG" 2>/dev/null || true)
  rm -f "$reset_file" "${reset_file}.detect" "${reset_file}.stream"

  assert_eq "collab repeated rc preserved" "0" "$rc"
  assert_contains "collab repeated summary warning" "$summary" "warnings=collab_spawn_repeated"
  assert_contains "collab repeated event is individual" "$summary" "role=ProductManager,reason=no_thread_with_id,fallback=yes,degraded=yes,repeated=yes"
  assert_contains "collab repeated log warning" "$log_body" "collab-spawn repeated warning stage=StageA role=ProductManager reason=no_thread_with_id"
}

run_collab_cross_role_repeated_case() {
  local reset_file_a reset_file_b
  reset_file_a=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
  reset_file_b=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
  : > "$LOG"
  reset_run_summary_for_test

  local rc_a=0 rc_b=0
  qa_run_codex_stage "StageA" "$reset_file_a" -- \
    fake_codex "$FIXTURE_DIR/collab-no-thread-developer.jsonl" 0 >> "$LOG" 2>&1 || rc_a=$?
  qa_run_codex_stage "Reviewer-r1-a1" "$reset_file_b" -- \
    fake_codex "$FIXTURE_DIR/collab-no-thread-reviewer.jsonl" 0 >> "$LOG" 2>&1 || rc_b=$?

  local summary log_body
  summary=$(rs_emit)
  log_body=$(cat "$LOG" 2>/dev/null || true)
  rm -f "$reset_file_a" "${reset_file_a}.detect" "${reset_file_a}.stream" \
        "$reset_file_b" "${reset_file_b}.detect" "${reset_file_b}.stream"

  assert_eq "collab cross-role first rc preserved" "0" "$rc_a"
  assert_eq "collab cross-role second rc preserved" "0" "$rc_b"
  assert_contains "collab cross-role summary warning" "$summary" "warnings=collab_spawn_repeated"
  assert_contains "collab cross-role second event repeated" "$summary" "collab_spawn_failed(stage=Reviewer-r1-a1,role=Reviewer,reason=no_thread_with_id,fallback=yes,degraded=yes,repeated=yes)"
  assert_contains "collab cross-role repeated log warning" "$log_body" "collab-spawn repeated warning stage=Reviewer-r1-a1 role=Reviewer reason=no_thread_with_id"
}

run_collab_bounded_retry_case() {
  local reset_file state_file
  reset_file=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
  state_file=$(mktemp -p "$TMPDIR_TEST" "collab-seq.XXXXXX")
  rm -f "$state_file"
  : > "$LOG"
  reset_run_summary_for_test

  local rc=0
  qa_run_codex_stage "Reviewer-r1-a1" "$reset_file" -- \
    fake_codex_sequence "$state_file" "collab-no-thread-reviewer.jsonl" "normal-success.jsonl" >> "$LOG" 2>&1 || rc=$?

  local summary log_body
  summary=$(rs_emit)
  log_body=$(cat "$LOG" 2>/dev/null || true)
  rm -f "$reset_file" "${reset_file}.detect" "${reset_file}.stream" "$state_file"

  assert_eq "collab bounded retry final rc success" "0" "$rc"
  assert_contains "collab retry summary records retry fallback" "$summary" "collab_spawn_failed(stage=Reviewer-r1-a1,role=Reviewer,reason=no_thread_with_id,fallback=retry,degraded=yes,repeated=no)"
  assert_contains "collab retry start logged" "$log_body" "collab-spawn fallback start stage=Reviewer-r1-a1 roles=Reviewer reason=no_thread_with_id action=bounded-retry next_attempt=2/2"
  assert_contains "collab retry success logged" "$log_body" "collab-spawn fallback result=success stage=Reviewer-r1-a1 reason=bounded-retry degraded=yes"
}

run_collab_bounded_retry_failed_case() {
  local reset_file state_file
  reset_file=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
  state_file=$(mktemp -p "$TMPDIR_TEST" "collab-fail-seq.XXXXXX")
  : > "$state_file"
  : > "$LOG"
  reset_run_summary_for_test

  local rc=0
  qa_run_codex_stage "Reviewer-r1-a1" "$reset_file" -- \
    fake_codex_repeat_failure "$state_file" "collab-no-thread-reviewer.jsonl" 4 >> "$LOG" 2>&1 || rc=$?

  local summary log_body attempts
  summary=$(rs_emit)
  log_body=$(cat "$LOG" 2>/dev/null || true)
  attempts=$(wc -l < "$state_file" | tr -d '[:space:]')
  rm -f "$reset_file" "${reset_file}.detect" "${reset_file}.stream" "$state_file"

  assert_eq "collab bounded retry failed rc transparent" "4" "$rc"
  assert_contains "collab failed retry summary records failed fallback" "$summary" "collab_spawn_failed(stage=Reviewer-r1-a1,role=Reviewer,reason=no_thread_with_id,fallback=failed,degraded=yes,repeated=yes)"
  assert_contains "collab failed retry result logged" "$log_body" "collab-spawn fallback result=failed stage=Reviewer-r1-a1 reason=bounded-retry degraded=yes codex_rc=4"
  assert_eq "collab failed retry does not attempt third spawn" "2" "$attempts"
  assert_not_contains "collab failed retry has no third retry log" "$log_body" "next_attempt=3/"
}

run_collab_stagec_project_manager_case() {
  local reset_file state_file
  reset_file=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
  state_file=$(mktemp -p "$TMPDIR_TEST" "collab-stagec-seq.XXXXXX")
  rm -f "$state_file"
  : > "$LOG"
  reset_run_summary_for_test

  local rc=0
  qa_run_codex_stage "StageC" "$reset_file" -- \
    fake_codex_sequence "$state_file" "collab-no-thread-project-manager.jsonl" "normal-success.jsonl" >> "$LOG" 2>&1 || rc=$?

  local summary log_body
  summary=$(rs_emit)
  log_body=$(cat "$LOG" 2>/dev/null || true)
  rm -f "$reset_file" "${reset_file}.detect" "${reset_file}.stream" "$state_file"

  assert_eq "collab StageC ProjectManager retry final rc success" "0" "$rc"
  assert_contains "collab StageC summary stage and role" "$summary" "collab_spawn_failed(stage=StageC,role=ProjectManager,reason=no_thread_with_id,fallback=retry,degraded=yes,repeated=no)"
  assert_contains "collab StageC retry start logged" "$log_body" "collab-spawn fallback start stage=StageC roles=ProjectManager reason=no_thread_with_id action=bounded-retry next_attempt=2/2"
  assert_contains "collab StageC retry success logged" "$log_body" "collab-spawn fallback result=success stage=StageC reason=bounded-retry degraded=yes"
}

# ─── テストケース ───

echo "--- qa_run_codex_stage cases (opt-in) ---"
export QUOTA_AWARE_ENABLED="true"

# Req 1.1, 1.2, 5.4: 現行スキーマ単独 → exit 99 + epoch 永続化
# 注: v2-rate-limit-event-rejected は末尾に reset 無し synthetic 429 を含むが、
# epoch 付き検出を優先採用するため exit 99 + 1778821200 が期待値。
run_case "v2-rate-limit-event-rejected (Req 1.1, 1.2, 5.4)" \
  99 "1778821200" "v2-rate-limit-event-rejected.jsonl" 0

# Req 1.1, 1.3 numeric epoch
run_case "v2-numeric-epoch (Req 1.1, 1.3)" \
  99 "1747375200" "v2-numeric-epoch.jsonl" 0

# Req 1.4: 現行スキーマで reset 欠落 → codex_rc 透過 (fake rc=0) + warn
run_case "v2-no-reset (Req 1.4)" \
  0 "" "v2-no-reset.jsonl" 0

# Req 2.1, 5.4: 旧スキーマ → exit 99 + epoch
run_case "v1-rate-limit-event-exceeded (Req 2.1, 5.4)" \
  99 "1778821200" "v1-rate-limit-event-exceeded.jsonl" 0

# Req 2.2: 旧スキーマ snake-case reset_at
run_case "v1-reset-at-snake (Req 2.2)" \
  99 "1778821200" "v1-reset-at-snake.jsonl" 0

# Req 3.1, 5.4: synthetic 429 (rate_limit_info 同居) → exit 99 + epoch
run_case "synthetic-429-result (Req 3.1, 5.4)" \
  99 "1778821200" "synthetic-429-result.jsonl" 0

# Req 3.2: synthetic 429 単独 + reset 不在 → codex_rc 透過 + warn
run_case "synthetic-429-no-reset (Req 3.2)" \
  0 "" "synthetic-429-no-reset.jsonl" 0

# Req 3.4: 通常成功 → codex_rc=0 透過、reset_file 空
run_case "normal-success (Req 3.4)" \
  0 "" "normal-success.jsonl" 0

# 補助: codex が非 0 で終了する場合は素通し（quota 検出なし時）
run_case "normal-success with codex rc=2 (NFR 1.2 既存 rc 透過)" \
  2 "" "normal-success.jsonl" 2

# Req 5.4: malformed line 混入でも検出を継続
run_case "v2-rate-limit-malformed-line (Req 5.4)" \
  99 "1778821200" "v2-rate-limit-malformed-line.jsonl" 0

usage_reset_epoch=$(qa_extract_usage_limit_reset_epoch "You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Jun 9th, 2026 1:16 AM.")
if [[ "$usage_reset_epoch" =~ ^[0-9]+$ ]]; then
  assert_eq "usage-limit reset parser returns numeric epoch (Issue #12 Req 3, 6)" "true" "true"
else
  assert_eq "usage-limit reset parser returns numeric epoch (Issue #12 Req 3, 6)" "true" "false"
fi

run_case "StageA usage-limit-with-reset → quota wait (Issue #12 Req 1, 6)" \
  99 "$usage_reset_epoch" "usage-limit-with-reset.jsonl" 1 "StageA"

run_case "Reviewer usage-limit-with-reset → quota wait (Issue #12 Req 1, 6)" \
  99 "$usage_reset_epoch" "usage-limit-with-reset.jsonl" 1 "Reviewer-r1-a1"

run_case "Debugger後 Reviewer usage-limit-with-reset → quota wait (Issue #12 Req 1, 6)" \
  99 "$usage_reset_epoch" "usage-limit-with-reset.jsonl" 1 "Reviewer-r3-a1"

run_case "Triage usage-limit-with-reset → quota wait (Issue #12 Req 2, 6)" \
  99 "$usage_reset_epoch" "usage-limit-with-reset.jsonl" 1 "Triage"

run_case "StageC usage-limit-with-reset → quota wait (Issue #12 Req 1, 6)" \
  99 "$usage_reset_epoch" "usage-limit-with-reset.jsonl" 1 "StageC"

run_quota_wait_label_case "StageA usage-limit callsite → quota label, no failed (Issue #12 Req 6.3)" \
  "StageA"

run_quota_wait_label_case "Reviewer usage-limit callsite → quota label, no failed (Issue #12 Req 6.4)" \
  "Reviewer-r1-a1"

run_quota_wait_label_case "Debugger後 Reviewer usage-limit callsite → quota label, no failed (Issue #12 Req 6.4)" \
  "Reviewer-r3-a1"

run_quota_wait_label_case "Triage usage-limit callsite → quota label, no failed (Issue #12 Req 6.5)" \
  "Triage"

run_case "usage-limit-no-reset → codex rc透過 (Issue #12 Option B)" \
  1 "" "usage-limit-no-reset.jsonl" 1 "StageA"

run_case "normal-error with codex rc=1 remains normal failure (Issue #12 Req 5)" \
  1 "" "normal-error.jsonl" 1 "StageA"

run_collab_success_case
run_collab_repeated_case
run_collab_cross_role_repeated_case
run_collab_bounded_retry_case
run_collab_bounded_retry_failed_case
run_collab_stagec_project_manager_case

# Issue #12 regression guard: 529 Overloaded の既存 detector は維持する。
LOG="$TMPDIR_TEST/overloaded-529.log"
export LOG
run_case "529-overloaded is not reclassified by usage-limit path (Issue #12 regression)" \
  2 "" "529-overloaded.jsonl" 2 "StageA"
_rc_529=0
codex_log_detect_529 "$LOG" || _rc_529=$?
assert_eq "codex_log_detect_529 still detects 529 Overloaded (Issue #12 regression)" "0" "$_rc_529"

echo ""
echo "--- qa_run_codex_stage cases (opt-out) ---"
export QUOTA_AWARE_ENABLED="false"

# NFR 1.1: opt-out 時は tee も解析も走らず素通し
# Req 1.1 / NFR 1.1 で codex_rc を完全透過、reset_file は touch されない
reset_file=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
rm -f "$reset_file"  # opt-out 時は touch されないことを確認するため事前削除
rc=0
qa_run_codex_stage "TestStage" "$reset_file" -- \
  fake_codex "$FIXTURE_DIR/v2-rate-limit-event-rejected.jsonl" 0 >/dev/null 2>&1 || rc=$?
assert_eq "opt-out v2 input rc=0 (NFR 1.1)" "0" "$rc"
if [ ! -e "$reset_file" ]; then
  echo "PASS: opt-out reset_file untouched (NFR 1.1)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: opt-out reset_file unexpectedly created"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# opt-out で codex rc を透過
reset_file=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
rm -f "$reset_file"
rc=0
qa_run_codex_stage "TestStage" "$reset_file" -- \
  fake_codex "$FIXTURE_DIR/normal-success.jsonl" 7 >/dev/null 2>&1 || rc=$?
assert_eq "opt-out preserves codex rc=7 (NFR 1.1, 1.2)" "7" "$rc"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
