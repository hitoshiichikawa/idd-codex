#!/usr/bin/env bash
#
# 用途: slack-notify.sh の gate（SLACK_NOTIFY_ENABLED + FULL_AUTO + URL）/ GitHub URL 組立 /
#       payload JSON 安全 escape / sn_notify_intervention の通知・no-op・失敗継続、
#       進捗イベント per-event トグル（SLACK_NOTIFY_PROGRESS_EVENTS / #135）の
#       sn_progress_notify_enabled・sn_notify_pickup の通知・no-op・失敗継続、および
#       **秘匿情報（webhook URL）がログに出力されない**ことを stub で検証する。
#       Issue #105 / D-18、#135（進捗イベント）。
#
# 配置先: local-watcher/test/slack_notify_test.sh
# 依存:   bash 4+, awk, grep, jq, mktemp
# 実行:   bash local-watcher/test/slack_notify_test.sh
# 前提:   slack-notify.sh から sn_*、watcher から full_auto_enabled を awk 抽出 → eval。
#         curl を stub。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/slack-notify.sh"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
for f in "$MODULE_SH" "$WATCHER_SH"; do
  [ -f "$f" ] || { echo "ERROR: not found: $f" >&2; exit 2; }
done

extract_function() {
  local script="$1" fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

REAL_FNS=( sn_notify_enabled sn_github_url sn_build_payload sn_post sn_notify_intervention sn_progress_notify_enabled sn_notify_pickup )
for fn in "${REAL_FNS[@]}"; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$MODULE_SH" "$fn")"
done
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "full_auto_enabled")"
for fn in "${REAL_FNS[@]}" full_auto_enabled; do
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done

# ─── 共有グローバル ───
REPO="owner/repo"
SECRET_URL="https://hooks.slack.test/services/T000/B000/SECRET12345"
SLACK_NOTIFY_TIMEOUT=5

# ─── stub ───
CURL_LOG=""; CURL_RC=0
curl() { printf 'curl %s\n' "$*" >>"$CURL_LOG"; return "$CURL_RC"; }
sn_log()  { echo "LOG: $*"; }
sn_warn() { echo "WARN: $*" >&2; }
sn_error(){ echo "ERR: $*" >&2; }

reset_state() { CURL_LOG="$(mktemp)"; CURL_RC=0; }
curl_calls() { grep -c '^curl ' "$CURL_LOG" 2>/dev/null || true; }

PASS_COUNT=0; FAIL_COUNT=0
assert_eq() { local l="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l"; echo "  exp=$(printf '%q' "$e") act=$(printf '%q' "$a")"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }
assert_contains() { local l="$1" h="$2" n="$3"; case "$h" in *"$n"*) echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1));; *) echo "FAIL: $l ('$n' 不在)"; FAIL_COUNT=$((FAIL_COUNT+1));; esac; }
assert_not_contains() { local l="$1" h="$2" n="$3"; case "$h" in *"$n"*) echo "FAIL: $l ('$n' が出力された)"; FAIL_COUNT=$((FAIL_COUNT+1));; *) echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1));; esac; }
rc_of() { local fn="$1"; shift; local r=0; "$fn" "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }

# ════════════════════════════════════════════════════════════════════════════
echo "--- 1. sn_notify_enabled（三重 gate）---"
SLACK_NOTIFY_ENABLED=true;  FULL_AUTO_ENABLED=true;  SLACK_WEBHOOK_URL="$SECRET_URL"
assert_eq "全 ON → 有効(0)" "0" "$(rc_of sn_notify_enabled)"
SLACK_NOTIFY_ENABLED=false; FULL_AUTO_ENABLED=true;  SLACK_WEBHOOK_URL="$SECRET_URL"
assert_eq "SLACK_NOTIFY OFF → 無効(1)" "1" "$(rc_of sn_notify_enabled)"
SLACK_NOTIFY_ENABLED=true;  FULL_AUTO_ENABLED=false; SLACK_WEBHOOK_URL="$SECRET_URL"
assert_eq "full_auto OFF → 無効(1)" "1" "$(rc_of sn_notify_enabled)"
SLACK_NOTIFY_ENABLED=true;  FULL_AUTO_ENABLED=true;  SLACK_WEBHOOK_URL=""
assert_eq "URL 未設定 → 無効(1)" "1" "$(rc_of sn_notify_enabled)"

echo ""; echo "--- 2. sn_github_url ---"
assert_eq "issue URL" "https://github.com/owner/repo/issues/42" "$(sn_github_url issue 42)"
assert_eq "pr URL"    "https://github.com/owner/repo/pull/42"   "$(sn_github_url pr 42)"

echo ""; echo "--- 3. sn_build_payload（JSON 安全 escape）---"
PAYLOAD=$(sn_build_payload "failed-recovery-budget" "issue" "101" "上限到達" "https://github.com/owner/repo/issues/101")
assert_eq "有効な JSON" "0" "$(printf '%s' "$PAYLOAD" | jq -e . >/dev/null 2>&1; echo $?)"
assert_contains "text に event" "$(printf '%s' "$PAYLOAD" | jq -r '.text')" "failed-recovery-budget"
assert_contains "text に number" "$(printf '%s' "$PAYLOAD" | jq -r '.text')" "#101"
assert_contains "text に URL" "$(printf '%s' "$PAYLOAD" | jq -r '.text')" "issues/101"
# ダブルクォートを含む title でも壊れない（jq escape）
PAYLOAD2=$(sn_build_payload "needs-decisions" "issue" "5" 'タイトル"with"quotes' "https://x")
assert_eq "quote 含む title でも有効 JSON" "0" "$(printf '%s' "$PAYLOAD2" | jq -e . >/dev/null 2>&1; echo $?)"
# category 省略時（既存 5 引数呼び出し）は後方互換で "介入要求"（#135 追加前と同一文言）
assert_contains "category 省略時は「介入要求」" "$(printf '%s' "$PAYLOAD" | jq -r '.text')" "介入要求"
# category を明示指定（進捗イベント / #135）すると文言が切り替わる
PAYLOAD3=$(sn_build_payload "codex-pickup" "issue" "9" "impl 着手（mode=impl）" "https://github.com/owner/repo/issues/9" "進捗")
assert_eq "category=進捗 でも有効 JSON" "0" "$(printf '%s' "$PAYLOAD3" | jq -e . >/dev/null 2>&1; echo $?)"
assert_contains "category=進捗 が文言に反映される" "$(printf '%s' "$PAYLOAD3" | jq -r '.text')" "進捗"
assert_not_contains "category=進捗 のとき「介入要求」は出ない" "$(printf '%s' "$PAYLOAD3" | jq -r '.text')" "介入要求"

echo ""; echo "--- 4. sn_notify_intervention（通知 / no-op / 失敗継続）---"
# 4a. 有効 → curl 1 回・rc 0
reset_state; SLACK_NOTIFY_ENABLED=true; FULL_AUTO_ENABLED=true; SLACK_WEBHOOK_URL="$SECRET_URL"; CURL_RC=0
r=$(rc_of sn_notify_intervention "blocked-cycle" "issue" "7" "循環検出")
assert_eq "有効 → rc 0" "0" "$r"
assert_eq "有効 → curl 1 回" "1" "$(curl_calls)"
# 4b. gate OFF → no-op（curl 0 回）
reset_state; SLACK_NOTIFY_ENABLED=false; FULL_AUTO_ENABLED=true; SLACK_WEBHOOK_URL="$SECRET_URL"
r=$(rc_of sn_notify_intervention "blocked-cycle" "issue" "7" "循環検出")
assert_eq "gate OFF → rc 0" "0" "$r"
assert_eq "gate OFF → curl 0 回（no-op）" "0" "$(curl_calls)"
# 4c. webhook 失敗 → rc 0（本体継続）
reset_state; SLACK_NOTIFY_ENABLED=true; FULL_AUTO_ENABLED=true; SLACK_WEBHOOK_URL="$SECRET_URL"; CURL_RC=1
r=$(rc_of sn_notify_intervention "failed-recovery-budget" "pr" "42" "上限到達")
assert_eq "webhook 失敗 → rc 0（本体継続）" "0" "$r"

echo ""; echo "--- 5. 秘匿情報（webhook URL）がログに出ない ---"
# 失敗ケースの stdout+stderr に SECRET が含まれないこと
reset_state; SLACK_NOTIFY_ENABLED=true; FULL_AUTO_ENABLED=true; SLACK_WEBHOOK_URL="$SECRET_URL"; CURL_RC=1
OUT=$(sn_notify_intervention "failed-recovery-budget" "pr" "42" "上限到達" 2>&1)
assert_not_contains "失敗ログに SECRET URL を出さない" "$OUT" "SECRET12345"
assert_contains "失敗ログに ref は出す" "$OUT" "#42"
# 成功ケースの stdout+stderr にも SECRET が含まれないこと
reset_state; CURL_RC=0
OUT=$(sn_notify_intervention "blocked-cycle" "issue" "7" "循環検出" 2>&1)
assert_not_contains "成功ログにも SECRET URL を出さない" "$OUT" "SECRET12345"
# payload 自体にも webhook URL を含めない（GitHub URL のみ）
PAYLOAD=$(sn_build_payload "blocked-cycle" "issue" "7" "循環検出" "$(sn_github_url issue 7)")
assert_not_contains "payload に webhook URL を含めない" "$PAYLOAD" "SECRET12345"

echo ""; echo "--- 6. sn_progress_notify_enabled（介入要求 三重 gate + 進捗トグル / #135）---"
# 6a. 全 ON（三重 gate + トグル ON）→ 有効(0)
SLACK_NOTIFY_ENABLED=true; FULL_AUTO_ENABLED=true; SLACK_WEBHOOK_URL="$SECRET_URL"; SLACK_NOTIFY_PROGRESS_EVENTS=true
assert_eq "全 ON → 有効(0)" "0" "$(rc_of sn_progress_notify_enabled)"
# 6b. 三重 gate は満たすがトグル未設定（既定 false）→ 無効(1)（導入前と等価）
unset SLACK_NOTIFY_PROGRESS_EVENTS
assert_eq "トグル未設定 → 無効(1)" "1" "$(rc_of sn_progress_notify_enabled)"
# 6c. トグルが typo（大文字違い）→ 無効(1)（厳密一致のみ有効）
SLACK_NOTIFY_PROGRESS_EVENTS=True
assert_eq "トグル typo(True) → 無効(1)" "1" "$(rc_of sn_progress_notify_enabled)"
# 6d. トグル ON でも三重 gate 側が OFF（SLACK_NOTIFY_ENABLED=false）→ 無効(1)
SLACK_NOTIFY_ENABLED=false; SLACK_NOTIFY_PROGRESS_EVENTS=true
assert_eq "三重 gate 側 OFF → 無効(1)" "1" "$(rc_of sn_progress_notify_enabled)"
SLACK_NOTIFY_ENABLED=true

echo ""; echo "--- 7. sn_notify_pickup（通知 / no-op / 失敗継続 / #135）---"
# 7a. トグル ON → curl 1 回・rc 0・payload に mode を含む
reset_state; SLACK_NOTIFY_ENABLED=true; FULL_AUTO_ENABLED=true; SLACK_WEBHOOK_URL="$SECRET_URL"; SLACK_NOTIFY_PROGRESS_EVENTS=true; CURL_RC=0
r=$(rc_of sn_notify_pickup "issue" "9" "impl")
assert_eq "トグル ON → rc 0" "0" "$r"
assert_eq "トグル ON → curl 1 回" "1" "$(curl_calls)"
PICKUP_PAYLOAD=$(sn_build_payload "codex-pickup" "issue" "9" "impl 着手（mode=impl）" "$(sn_github_url issue 9)" "進捗")
assert_contains "payload に mode を含む" "$(printf '%s' "$PICKUP_PAYLOAD" | jq -r '.text')" "mode=impl"
assert_contains "payload に Issue 番号を含む" "$(printf '%s' "$PICKUP_PAYLOAD" | jq -r '.text')" "#9"
assert_contains "payload に URL を含む" "$(printf '%s' "$PICKUP_PAYLOAD" | jq -r '.text')" "issues/9"
# 7b. トグル未設定（既定 OFF）→ no-op（curl 0 回）＝導入前と等価
reset_state; SLACK_NOTIFY_ENABLED=true; FULL_AUTO_ENABLED=true; SLACK_WEBHOOK_URL="$SECRET_URL"; unset SLACK_NOTIFY_PROGRESS_EVENTS
r=$(rc_of sn_notify_pickup "issue" "9" "impl")
assert_eq "トグル OFF（既定） → rc 0" "0" "$r"
assert_eq "トグル OFF（既定） → curl 0 回（no-op）" "0" "$(curl_calls)"
# 7c. 介入要求側 gate OFF（SLACK_NOTIFY_ENABLED=false）→ トグル ON でも no-op
reset_state; SLACK_NOTIFY_ENABLED=false; FULL_AUTO_ENABLED=true; SLACK_WEBHOOK_URL="$SECRET_URL"; SLACK_NOTIFY_PROGRESS_EVENTS=true
r=$(rc_of sn_notify_pickup "issue" "9" "impl")
assert_eq "介入要求 gate OFF → rc 0" "0" "$r"
assert_eq "介入要求 gate OFF → curl 0 回（no-op）" "0" "$(curl_calls)"
# 7d. webhook 失敗 → rc 0（本体継続、silent fail にはしない）
reset_state; SLACK_NOTIFY_ENABLED=true; FULL_AUTO_ENABLED=true; SLACK_WEBHOOK_URL="$SECRET_URL"; SLACK_NOTIFY_PROGRESS_EVENTS=true; CURL_RC=1
r=$(rc_of sn_notify_pickup "issue" "9" "impl-resume")
assert_eq "webhook 失敗 → rc 0（本体継続）" "0" "$r"
# 7e. 秘匿情報（webhook URL）が成功・失敗いずれのログにも出ない
reset_state; SLACK_NOTIFY_ENABLED=true; FULL_AUTO_ENABLED=true; SLACK_WEBHOOK_URL="$SECRET_URL"; SLACK_NOTIFY_PROGRESS_EVENTS=true; CURL_RC=1
OUT=$(sn_notify_pickup "issue" "9" "impl" 2>&1)
assert_not_contains "失敗ログに SECRET URL を出さない" "$OUT" "SECRET12345"
assert_contains "失敗ログに ref は出す" "$OUT" "#9"
reset_state; CURL_RC=0
OUT=$(sn_notify_pickup "issue" "9" "impl" 2>&1)
assert_not_contains "成功ログにも SECRET URL を出さない" "$OUT" "SECRET12345"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
