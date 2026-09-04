#!/usr/bin/env bash
#
# 用途: effort-guard.sh（Issue #174）を検証する。
#   - allowlist（minimal / low / medium / high / xhigh / max）の透過（既定挙動不変）
#   - allowlist 外（typo / 大文字 / 空文字）→ 当該 stage の組み込み既定へ正規化 + WARN
#   - `ultra` は CODEX_ALLOW_ULTRA_EFFORT=true 厳密一致のみ透過、それ以外は既定へ正規化 + WARN
#   - stage 既定: Triage=medium / その他=high
#   - codex_exec_prompt からの配線（eg_normalize_effort 呼び出しが存在し、-c model_reasoning_effort に
#     正規化後の値が渡る）
#
# 配置先: local-watcher/test/effort_guard_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/effort_guard_test.sh

# 環境変数は eval で読み込んだ関数（codex_reasoning_effort_for_stage / eg_*）が参照するため、
# 静的解析の未使用警告（SC2034）をファイル単位で抑止する。
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/effort-guard.sh"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
[ -f "$MODULE_SH" ] || { echo "ERROR: not found: $MODULE_SH" >&2; exit 2; }
[ -f "$WATCHER_SH" ] || { echo "ERROR: not found: $WATCHER_SH" >&2; exit 2; }

extract_function() {
  local script="$1" fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 本モジュールは関数定義 + allowlist 定数のみで副作用が無いため source で読む。
# shellcheck disable=SC1090
. "$MODULE_SH"
for fn in eg_default_effort_for_stage eg_is_allowlisted_effort eg_ultra_allowed eg_sanitize_effort_token eg_normalize_effort; do
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done
# codex_reasoning_effort_for_stage（本体）も抽出して env → 正規化の直列を検証する
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "codex_reasoning_effort_for_stage")"
declare -F codex_reasoning_effort_for_stage >/dev/null || { echo "ERROR: codex_reasoning_effort_for_stage not loaded" >&2; exit 2; }

# ─── stub logger（core_utils 由来）: WARN を捕捉 ───
WARN_CAP="$(mktemp)"; trap 'rm -f "$WARN_CAP"' EXIT
REPO="owner/repo"
eg_log()  { :; }
eg_warn() { printf '%s\n' "$*" >>"$WARN_CAP"; }
eg_error(){ printf 'ERROR %s\n' "$*" >>"$WARN_CAP"; }
reset_warn() { : >"$WARN_CAP"; }
warn_count() { grep -c . "$WARN_CAP" 2>/dev/null || true; }

PASS_COUNT=0; FAIL_COUNT=0
assert_eq() { local l="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l"; echo "  exp=$(printf '%q' "$e") act=$(printf '%q' "$a")"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }
assert_contains() { local l="$1" h="$2" n="$3"; case "$h" in *"$n"*) echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1));; *) echo "FAIL: $l ('$n' 不在: $(printf '%q' "$h"))"; FAIL_COUNT=$((FAIL_COUNT+1));; esac; }
rc_of() { local fn="$1"; shift; local r=0; "$fn" "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }

# ════════════════════════════════════════════════════════════════════════════
echo "--- 1. eg_default_effort_for_stage（組み込み既定）---"
assert_eq "Triage → medium" "medium" "$(eg_default_effort_for_stage Triage)"
assert_eq "triage(lower) → medium" "medium" "$(eg_default_effort_for_stage triage)"
assert_eq "StageA → high" "high" "$(eg_default_effort_for_stage StageA)"
assert_eq "Reviewer-r1-a1 → high" "high" "$(eg_default_effort_for_stage Reviewer-r1-a1)"
assert_eq "Debugger-blocked-1 → high" "high" "$(eg_default_effort_for_stage Debugger-blocked-1)"
assert_eq "AutoRebase-42 → high" "high" "$(eg_default_effort_for_stage AutoRebase-42)"
assert_eq "PR-iteration-impl-r2 → high" "high" "$(eg_default_effort_for_stage PR-iteration-impl-r2)"
assert_eq "空 stage → high（catch-all）" "high" "$(eg_default_effort_for_stage "")"

echo ""; echo "--- 2. eg_is_allowlisted_effort ---"
for v in minimal low medium high xhigh max; do
  assert_eq "allowlist: $v → 0" "0" "$(rc_of eg_is_allowlisted_effort "$v")"
done
assert_eq "ultra は allowlist 外(1)" "1" "$(rc_of eg_is_allowlisted_effort ultra)"
assert_eq "High（大文字）は allowlist 外(1)" "1" "$(rc_of eg_is_allowlisted_effort High)"
assert_eq "hihg（typo）は allowlist 外(1)" "1" "$(rc_of eg_is_allowlisted_effort hihg)"
assert_eq "空文字は allowlist 外(1)" "1" "$(rc_of eg_is_allowlisted_effort "")"
assert_eq "部分一致 'hig' は allowlist 外(1)" "1" "$(rc_of eg_is_allowlisted_effort hig)"
assert_eq "空白入り ' high' は allowlist 外(1)" "1" "$(rc_of eg_is_allowlisted_effort " high")"

echo ""; echo "--- 3. eg_ultra_allowed（opt-in gate 厳密一致）---"
CODEX_ALLOW_ULTRA_EFFORT=true;  assert_eq "true → 0" "0" "$(rc_of eg_ultra_allowed)"
CODEX_ALLOW_ULTRA_EFFORT=TRUE;  assert_eq "TRUE → 1" "1" "$(rc_of eg_ultra_allowed)"
CODEX_ALLOW_ULTRA_EFFORT=1;     assert_eq "1 → 1" "1" "$(rc_of eg_ultra_allowed)"
CODEX_ALLOW_ULTRA_EFFORT=yes;   assert_eq "yes → 1" "1" "$(rc_of eg_ultra_allowed)"
CODEX_ALLOW_ULTRA_EFFORT=false; assert_eq "false → 1" "1" "$(rc_of eg_ultra_allowed)"
CODEX_ALLOW_ULTRA_EFFORT="";    assert_eq "空文字 → 1" "1" "$(rc_of eg_ultra_allowed)"
unset CODEX_ALLOW_ULTRA_EFFORT; assert_eq "未設定 → 1" "1" "$(rc_of eg_ultra_allowed)"

echo ""; echo "--- 4. eg_normalize_effort: allowlist 内は透過（WARN なし / 既定挙動不変）---"
unset CODEX_ALLOW_ULTRA_EFFORT
for v in minimal low medium high xhigh max; do
  reset_warn
  assert_eq "透過: $v" "$v" "$(eg_normalize_effort StageA "$v")"
  assert_eq "透過: $v は WARN なし" "0" "$(warn_count)"
done
reset_warn
assert_eq "Triage medium 透過" "medium" "$(eg_normalize_effort Triage medium)"
assert_eq "Triage medium は WARN なし" "0" "$(warn_count)"

echo ""; echo "--- 5. eg_normalize_effort: allowlist 外 → stage 既定 + WARN ---"
reset_warn
assert_eq "typo 'hihg' (StageA) → high" "high" "$(eg_normalize_effort StageA hihg)"
assert_eq "typo は WARN 1 行" "1" "$(warn_count)"
assert_contains "WARN に allowlist 外の旨" "$(cat "$WARN_CAP")" "allowlist"
assert_contains "WARN に stage 名" "$(cat "$WARN_CAP")" "stage=StageA"
assert_contains "WARN に正規化先" "$(cat "$WARN_CAP")" "既定 'high'"
reset_warn
assert_eq "typo 'hihg' (Triage) → medium（stage 既定）" "medium" "$(eg_normalize_effort Triage hihg)"
assert_contains "Triage WARN の正規化先は medium" "$(cat "$WARN_CAP")" "既定 'medium'"
reset_warn
assert_eq "大文字 'High' → high（厳密一致で非許可 → 既定）" "high" "$(eg_normalize_effort StageA High)"
assert_eq "大文字は WARN 1 行" "1" "$(warn_count)"
reset_warn
assert_eq "空文字 → high" "high" "$(eg_normalize_effort StageA "")"
assert_eq "空文字は WARN 1 行" "1" "$(warn_count)"
reset_warn
NL_VALUE=$'high\ninjected line'
assert_eq "改行入り値 → high（正規化）" "high" "$(eg_normalize_effort StageA "$NL_VALUE")"
assert_eq "改行入り値でも WARN は 1 行（ログ破壊なし）" "1" "$(warn_count)"
assert_contains "改行は '?' に丸められる" "$(cat "$WARN_CAP")" "high?injected?line"

echo ""; echo "--- 6. eg_normalize_effort: ultra の opt-in gate ---"
unset CODEX_ALLOW_ULTRA_EFFORT; reset_warn
assert_eq "ultra / gate 未設定 (StageA) → high" "high" "$(eg_normalize_effort StageA ultra)"
assert_eq "ultra / gate 未設定は WARN 1 行" "1" "$(warn_count)"
assert_contains "WARN に opt-in 変数名" "$(cat "$WARN_CAP")" "CODEX_ALLOW_ULTRA_EFFORT=true"
reset_warn
assert_eq "ultra / gate 未設定 (Triage) → medium" "medium" "$(eg_normalize_effort Triage ultra)"
CODEX_ALLOW_ULTRA_EFFORT=false; reset_warn
assert_eq "ultra / gate=false → high" "high" "$(eg_normalize_effort StageA ultra)"
CODEX_ALLOW_ULTRA_EFFORT=TRUE; reset_warn
assert_eq "ultra / gate=TRUE（typo）→ high（安全側）" "high" "$(eg_normalize_effort StageA ultra)"
assert_eq "gate typo は WARN 1 行" "1" "$(warn_count)"
CODEX_ALLOW_ULTRA_EFFORT=true; reset_warn
assert_eq "ultra / gate=true → ultra 透過" "ultra" "$(eg_normalize_effort StageA ultra)"
assert_eq "ultra 許可時もコスト注意 WARN 1 行" "1" "$(warn_count)"
assert_contains "許可 WARN は '許可' を含む" "$(cat "$WARN_CAP")" "許可"
reset_warn
assert_eq "gate=true でも typo は既定へ（gate は ultra 専用）" "high" "$(eg_normalize_effort StageA hihg)"
unset CODEX_ALLOW_ULTRA_EFFORT

echo ""; echo "--- 7. env → codex_reasoning_effort_for_stage → eg_normalize_effort の直列 ---"
TRIAGE_REASONING_EFFORT=medium; DEV_REASONING_EFFORT=high; REVIEWER_REASONING_EFFORT=high
DEBUGGER_REASONING_EFFORT=high; AUTO_REBASE_REASONING_EFFORT=high; PR_ITERATION_REASONING_EFFORT=high
reset_warn
assert_eq "既定 env: Triage → medium" "medium" "$(eg_normalize_effort Triage "$(codex_reasoning_effort_for_stage Triage)")"
assert_eq "既定 env: PerTask-Impl-1 → high" "high" "$(eg_normalize_effort PerTask-Impl-1 "$(codex_reasoning_effort_for_stage PerTask-Impl-1)")"
assert_eq "既定 env では WARN ゼロ（後方互換）" "0" "$(warn_count)"
DEV_REASONING_EFFORT=xhigh; reset_warn
assert_eq "DEV=xhigh は透過" "xhigh" "$(eg_normalize_effort StageA "$(codex_reasoning_effort_for_stage StageA)")"
DEV_REASONING_EFFORT=ultra; unset CODEX_ALLOW_ULTRA_EFFORT; reset_warn
assert_eq "DEV=ultra / gate 無し → high" "high" "$(eg_normalize_effort StageA "$(codex_reasoning_effort_for_stage StageA)")"
REVIEWER_REASONING_EFFORT=Max; reset_warn
assert_eq "REVIEWER=Max（大文字 typo）→ high" "high" "$(eg_normalize_effort Reviewer-r1-a1 "$(codex_reasoning_effort_for_stage Reviewer-r1-a1)")"
TRIAGE_REASONING_EFFORT=ultra; reset_warn
assert_eq "TRIAGE=ultra / gate 無し → medium（Triage 既定）" "medium" "$(eg_normalize_effort Triage "$(codex_reasoning_effort_for_stage Triage)")"

echo ""; echo "--- 8. 本体配線（codex_exec_prompt が eg_normalize_effort を通してから -c に渡す）---"
EXEC_BODY="$(extract_function "$WATCHER_SH" "codex_exec_prompt")"
assert_contains "codex_exec_prompt に eg_normalize_effort 呼び出しがある" "$EXEC_BODY" 'effort="$(eg_normalize_effort "$stage_label" "$effort")"'
NORM_LINE=$(printf '%s\n' "$EXEC_BODY" | grep -n 'eg_normalize_effort' | head -1 | cut -d: -f1)
ARGS_LINE=$(printf '%s\n' "$EXEC_BODY" | grep -n 'model_reasoning_effort=' | head -1 | cut -d: -f1)
if [ -n "$NORM_LINE" ] && [ -n "$ARGS_LINE" ] && [ "$NORM_LINE" -lt "$ARGS_LINE" ]; then
  echo "PASS: 正規化は -c model_reasoning_effort 組み立てより前に行われる"; PASS_COUNT=$((PASS_COUNT+1))
else
  echo "FAIL: 正規化位置が -c 組み立てより後（norm=$NORM_LINE args=$ARGS_LINE）"; FAIL_COUNT=$((FAIL_COUNT+1))
fi
assert_contains "REQUIRED_MODULES に effort-guard.sh が登録されている" "$(grep -E '^REQUIRED_MODULES=' "$WATCHER_SH")" '"effort-guard.sh"'
assert_contains "本体 Config に CODEX_ALLOW_ULTRA_EFFORT 既定 false" "$(grep -E '^CODEX_ALLOW_ULTRA_EFFORT=' "$WATCHER_SH")" '${CODEX_ALLOW_ULTRA_EFFORT:-false}'

echo ""; echo "──────────────"
echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
echo "ALL GREEN"
