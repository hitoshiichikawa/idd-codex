#!/usr/bin/env bash
#
# 用途: stale-pickup-reaper.sh（idd-claude #379/F6 移植）を検証する。gate / marker 永続化
#       (roundtrip / fail-open) / marker age 判定 / **3 観点 AND（誤検出回避の安全境界）** /
#       revert 副作用（picked+claimed 除去・auto-dev 付与・git 非呼出・同サイクル冪等） /
#       process_stale_pickup_reaper の routing（gate off=no-op / inactive→revert / active→keep）
#       を stub で確認する。
#
# 配置先: local-watcher/test/stale_pickup_reaper_test.sh
# 依存:   bash 4+, awk, jq, mktemp, date(GNU)
# 実行:   bash local-watcher/test/stale_pickup_reaper_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/stale-pickup-reaper.sh"
[ -f "$MODULE_SH" ] || { echo "ERROR: not found: $MODULE_SH" >&2; exit 2; }

extract_function() {
  local script="$1" fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

REAL_FNS=(
  sr_is_enabled sr_marker_path sr_load_marker sr_save_marker sr_check_marker_age
  sr_is_active sr_revert_to_auto_dev sr_fetch_candidates process_stale_pickup_reaper
)
for fn in "${REAL_FNS[@]}"; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$MODULE_SH" "$fn")"
done
for fn in "${REAL_FNS[@]}"; do
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done

# ─── 共有グローバル ───
REPO="owner/repo"; REPO_SLUG="owner-repo"
LABEL_PICKED="codex-picked-up"; LABEL_CLAIMED="codex-claimed"; LABEL_TRIGGER="codex-auto-dev"
LABEL_FAILED="codex-failed"; LABEL_NEEDS_DECISIONS="codex-needs-decisions"
LABEL_AWAITING_DESIGN="codex-awaiting-design-review"; LABEL_NEEDS_QUOTA_WAIT="codex-needs-quota-wait"
LABEL_BLOCKED="codex-blocked"; LABEL_STAGED_FOR_RELEASE="codex-staged-for-release"
LABEL_AWAITING_SLOT="codex-awaiting-slot"
STALE_PICKUP_REAPER_THRESHOLD_MINUTES=45; STALE_PICKUP_REAPER_MAX_ISSUES=20
STALE_PICKUP_REAPER_GH_TIMEOUT=5
STATE_DIR=""

# ─── stub ───
GH_CALL_LOG=""; GH_LABELS_RESPONSE='{"labels":[]}'; GH_EDIT_RC=0
timeout() { shift; "$@"; }
git() { printf 'git %s\n' "$*" >>"$GH_CALL_LOG"; return 0; }
gh() {
  printf 'gh %s\n' "$*" >>"$GH_CALL_LOG"
  case "$1 $2" in
    "issue view") printf '%s' "$GH_LABELS_RESPONSE" ;;
    "issue edit") return "$GH_EDIT_RC" ;;
  esac
  return 0
}
sr_log()  { :; }
sr_warn() { :; }
sr_error(){ :; }

reset_state() {
  GH_CALL_LOG="$(mktemp)"; GH_LABELS_RESPONSE='{"labels":[]}'; GH_EDIT_RC=0
  STATE_DIR="$(mktemp -d)"; STALE_PICKUP_REAPER_STATE_DIR="$STATE_DIR"
  SR_PROCESSED_THIS_CYCLE=""
}
calls() { grep -c "$1" "$GH_CALL_LOG" 2>/dev/null || true; }

PASS_COUNT=0; FAIL_COUNT=0
assert_eq() { local l="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l"; echo "  exp=$(printf '%q' "$e") act=$(printf '%q' "$a")"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }
assert_contains() { local l="$1" h="$2" n="$3"; case "$h" in *"$n"*) echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1));; *) echo "FAIL: $l ('$n' 不在)"; FAIL_COUNT=$((FAIL_COUNT+1));; esac; }
rc_of() { local fn="$1"; shift; local r=0; "$fn" "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }

# ════════════════════════════════════════════════════════════════════════════
echo "--- 1. sr_is_enabled（単独 opt-in gate）---"
STALE_PICKUP_REAPER_ENABLED=true;  assert_eq "true → ON(0)" "0" "$(rc_of sr_is_enabled)"
STALE_PICKUP_REAPER_ENABLED=false; assert_eq "false → OFF(1)" "1" "$(rc_of sr_is_enabled)"
STALE_PICKUP_REAPER_ENABLED=1;     assert_eq "1 → OFF(1)" "1" "$(rc_of sr_is_enabled)"
unset STALE_PICKUP_REAPER_ENABLED; assert_eq "未設定 → OFF(1)" "1" "$(rc_of sr_is_enabled)"

echo ""; echo "--- 2. marker 永続化（roundtrip / fail-open）---"
reset_state
assert_eq "未保存 → {} (fail-open)" "{}" "$(sr_load_marker 5)"
sr_save_marker 5 "2026-06-23T00:00:00Z" "2026-06-23T00:10:00Z" '["codex-picked-up"]' "observing" ""
assert_eq "issue 永続化" "5" "$(sr_load_marker 5 | jq -r '.issue')"
assert_eq "first_seen_at 永続化" "2026-06-23T00:00:00Z" "$(sr_load_marker 5 | jq -r '.first_seen_at')"
assert_eq "status 永続化" "observing" "$(sr_load_marker 5 | jq -r '.status')"
assert_eq "labels 永続化" "codex-picked-up" "$(sr_load_marker 5 | jq -r '.last_known_labels[0]')"
printf 'broken{{' > "$STATE_DIR/6.json"
assert_eq "破損 JSON → {} (fail-open)" "{}" "$(sr_load_marker 6)"

echo ""; echo "--- 3. sr_check_marker_age（経過時間閾値）---"
AGED_TS=$(date -u -d '60 minutes ago' '+%Y-%m-%dT%H:%M:%SZ')
FRESH_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
assert_eq "60分前(>45) → aged(0)" "0" "$(rc_of sr_check_marker_age "$(jq -nc --arg t "$AGED_TS" '{first_seen_at:$t}')")"
assert_eq "現在(<45) → fresh(1)" "1" "$(rc_of sr_check_marker_age "$(jq -nc --arg t "$FRESH_TS" '{first_seen_at:$t}')")"
assert_eq "first_seen_at 不在 → fresh(1)" "1" "$(rc_of sr_check_marker_age '{}')"
assert_eq "parse 不能 → fresh(1)" "1" "$(rc_of sr_check_marker_age "$(jq -nc '{first_seen_at:"not-a-date"}')")"

echo ""; echo "--- 4. sr_is_active 3観点 AND（誤検出回避の安全境界）---"
# 3 checks を eval 上書き（SC2218 回避）。AGE_RC/LOCK_RC/SESS_RC で制御。
eval 'sr_check_marker_age() { return "${AGE_RC:-0}"; }'
eval 'sr_check_slot_lock() { return "${LOCK_RC:-0}"; }'
eval 'sr_check_session() { return "${SESS_RC:-0}"; }'
MK='{"issue":7}'
AGE_RC=0; LOCK_RC=0; SESS_RC=0; assert_eq "全観点 inactive(0,0,0) → inactive(revert/1)" "1" "$(rc_of sr_is_active "$MK")"
AGE_RC=1; LOCK_RC=0; SESS_RC=0; assert_eq "age fresh → keep(0)" "0" "$(rc_of sr_is_active "$MK")"
AGE_RC=0; LOCK_RC=1; SESS_RC=0; assert_eq "lock held → keep(0)【安全】" "0" "$(rc_of sr_is_active "$MK")"
AGE_RC=0; LOCK_RC=0; SESS_RC=1; assert_eq "session alive → keep(0)【安全】" "0" "$(rc_of sr_is_active "$MK")"
AGE_RC=0; LOCK_RC=2; SESS_RC=0; assert_eq "lock 判定不能(2) → keep(0)【safe-side】" "0" "$(rc_of sr_is_active "$MK")"

echo ""; echo "--- 5. sr_revert_to_auto_dev（副作用 / git 非呼出 / 冪等）---"
reset_state; GH_LABELS_RESPONSE='{"labels":[]}'
r=$(rc_of sr_revert_to_auto_dev 8 '{"issue":8}')
assert_eq "成功 → rc 0" "0" "$r"
assert_eq "codex-picked-up 除去" "1" "$(calls 'remove-label codex-picked-up')"
assert_eq "codex-claimed 除去" "1" "$(calls 'remove-label codex-claimed')"
assert_eq "auto-dev 欠落 → 付与" "1" "$(calls 'add-label codex-auto-dev')"
assert_eq "git を呼ばない（branch 温存）" "0" "$(calls '^git ')"
# auto-dev が既に有る → add しない
reset_state; GH_LABELS_RESPONSE='{"labels":[{"name":"codex-auto-dev"}]}'
sr_revert_to_auto_dev 9 '{"issue":9}' >/dev/null 2>&1 || true
assert_eq "auto-dev 既存 → 付与しない" "0" "$(calls 'add-label codex-auto-dev')"
# 不正 issue → reject（gh 呼ばない）
reset_state
assert_eq "不正 issue → rc 1" "1" "$(rc_of sr_revert_to_auto_dev 'abc' '{}')"
assert_eq "不正 issue → gh 0 回" "0" "$(calls '^gh ')"
# 同サイクル冪等
reset_state; SR_PROCESSED_THIS_CYCLE=" 10 "
sr_revert_to_auto_dev 10 '{"issue":10}' >/dev/null 2>&1 || true
assert_eq "同サイクル 2 回目 → gh 0 回（idempotent）" "0" "$(calls '^gh ')"

echo ""; echo "--- 6. process_stale_pickup_reaper routing ---"
# leaf を eval 上書きして revert 有無を記録。
REVERT_LOG=""
eval 'sr_fetch_candidates() { printf "%s" "$CANDIDATES"; }'
eval 'sr_save_marker() { return 0; }'
eval 'sr_load_marker() { printf "%s" "$MARKER"; }'
eval 'sr_is_active() { return "${ACTIVE_RC:-1}"; }'
eval 'sr_revert_to_auto_dev() { REVERT_LOG="${REVERT_LOG} $1"; return 0; }'
CANDIDATES='[{"number":11,"labels":[{"name":"codex-picked-up"}]}]'
MARKER='{"issue":11,"first_seen_at":"2026-06-23T00:00:00Z"}'
run_proc() { REVERT_LOG=""; process_stale_pickup_reaper >/dev/null 2>&1 || true; }

# 6a. gate off → 候補取得も revert もしない
reset_state; STALE_PICKUP_REAPER_ENABLED=false; run_proc
assert_eq "gate off → revert なし" "" "$REVERT_LOG"
# 6b. gate on + inactive → revert
reset_state; STALE_PICKUP_REAPER_ENABLED=true; ACTIVE_RC=1; run_proc
assert_eq "gate on + inactive → revert #11" " 11" "$REVERT_LOG"
# 6c. gate on + active → keep（revert しない）
reset_state; STALE_PICKUP_REAPER_ENABLED=true; ACTIVE_RC=0; run_proc
assert_eq "gate on + active → revert しない" "" "$REVERT_LOG"

echo ""; echo "--- 7. sr_fetch_candidates（検索クエリ / 除外フィルタ）---"
# section 6 で stub 上書きした sr_fetch_candidates を実体へ戻す。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sr_fetch_candidates")"
reset_state; STALE_PICKUP_REAPER_ENABLED=true
GH_PICKED_CLAIMED='[]'
eval 'gh() { printf "gh %s\n" "$*" >>"$GH_CALL_LOG"; case "$1 $2" in "issue list") printf "%s" "$GH_PICKED_CLAIMED" ;; esac; return 0; }'
out=$(sr_fetch_candidates)
assert_eq "空候補 → []" "[]" "$(printf '%s' "$out" | jq -c '.')"
assert_contains "codex-picked-up を検索" "$(cat "$GH_CALL_LOG")" 'label:"codex-picked-up"'
assert_contains "codex-claimed を検索" "$(cat "$GH_CALL_LOG")" 'label:"codex-claimed"'
assert_contains "codex-failed を除外" "$(cat "$GH_CALL_LOG")" '-label:"codex-failed"'
assert_contains "codex-needs-decisions を除外" "$(cat "$GH_CALL_LOG")" '-label:"codex-needs-decisions"'

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
