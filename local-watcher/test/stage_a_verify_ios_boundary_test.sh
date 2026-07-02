#!/usr/bin/env bash
#
# 用途: Stage A Verify の iOS Simulator / CoreSimulator 境界調整と診断を検証する。
#
# 検証観点:
#   - 未設定時は repository 由来 verify が従来どおり codex sandbox 境界で実行される
#   - `STAGE_A_VERIFY_EXECUTION_BOUNDARY=host` 完全一致時のみ host 実行へ切り替わる
#   - typo / 大文字違いは sandbox に倒れる
#   - CoreSimulatorService / Operation not permitted / destination 検出失敗を診断ログへ出す
#
# 実行: bash local-watcher/test/stage_a_verify_ios_boundary_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/stage-a-verify.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find stage-a-verify.sh at $MODULE_SH" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$MODULE_SH"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  ok: $label"
    PASS=$((PASS + 1))
  else
    echo "  NG: ${label}（期待=$expected / 実際=${actual}）" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  ok: $label"
    PASS=$((PASS + 1))
  else
    echo "  NG: ${label}（期待文字列 '$needle' が見つからない）" >&2
    echo "      実際: $haystack" >&2
    FAIL=$((FAIL + 1))
  fi
}

setup_case() {
  local name="$1"
  REPO_DIR="$TMP_ROOT/$name/repo"
  SPEC_DIR_REL="docs/specs/130-case"
  LOG="$TMP_ROOT/$name/stage-a-verify.log"
  CODEX_ARGS_FILE="$TMP_ROOT/$name/codex-args.log"
  FAKE_CODEX_OUTPUT_FILE="$TMP_ROOT/$name/fake-codex-output.txt"
  mkdir -p "$REPO_DIR/$SPEC_DIR_REL" "$(dirname "$LOG")"
  : > "$LOG"
  : > "$CODEX_ARGS_FILE"
  : > "$FAKE_CODEX_OUTPUT_FILE"

  export REPO="owner/repo"
  export REPO_DIR SPEC_DIR_REL LOG CODEX_ARGS_FILE FAKE_CODEX_OUTPUT_FILE
  export NUMBER=130
  export BRANCH="codex/issue-130-stage-a-verify"
  export REPO_SLUG="owner-repo"
  export STAGE_A_VERIFY_ENABLED="true"
  export STAGE_A_VERIFY_TIMEOUT="5"
  export STAGE_A_VERIFY_COMMAND=""
  export STAGE_A_VERIFY_SANDBOX_PROFILE=":workspace"
  export STAGE_A_VERIFY_EXECUTION_BOUNDARY="codex-sandbox"
  export STAGE_A_VERIFY_STATE_DIR="$TMP_ROOT/$name/state"
  export FAKE_CODEX_RC="0"

  CODEX_BIN="$TMP_ROOT/$name/fake-codex"
  export CODEX_BIN
  cat > "$CODEX_BIN" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'argc=%s\n' "$#"
  for arg in "$@"; do
    printf '<%s>\n' "$arg"
  done
} >> "$CODEX_ARGS_FILE"
cat "$FAKE_CODEX_OUTPUT_FILE"
exit "${FAKE_CODEX_RC:-0}"
FAKE_CODEX
  chmod +x "$CODEX_BIN"
}

write_ios_tasks() {
  printf '%s\n' \
    "# Tasks" \
    "" \
    "<!-- stage-a-verify -->" \
    '```bash' \
    "xcodebuild -project KukuMaster.xcodeproj -scheme KukuMaster -destination 'platform=iOS Simulator,name=iPhone 17' test" \
    '```' > "$REPO_DIR/$SPEC_DIR_REL/tasks.md"
}

run_stage_a_verify() {
  local rc=0
  stage_a_verify_run >/dev/null 2>>"$LOG" || rc=$?
  printf '%s\n' "$rc"
}

echo "[case1] 未設定時は codex sandbox 境界で実行される"
setup_case "default-sandbox"
write_ios_tasks
unset STAGE_A_VERIFY_EXECUTION_BOUNDARY
rc="$(run_stage_a_verify)"
args="$(cat "$CODEX_ARGS_FILE")"
log_body="$(cat "$LOG")"
assert_eq "$rc" "0" "未設定時の fake sandbox 成功を反映する"
assert_contains "$args" "<sandbox>" "未設定時は codex sandbox を呼ぶ"
assert_contains "$log_body" "sandbox EXEC profile=:workspace boundary=codex-sandbox" "既定境界をログに残す"

echo "[case2] host opt-in 時は repository 由来 verify を host 実行する"
setup_case "host-opt-in"
write_ios_tasks
HOST_MARKER="$TMP_ROOT/host-opt-in-marker"
printf '%s\n' \
  "# Tasks" \
  "" \
  "<!-- stage-a-verify -->" \
  '```bash' \
  "printf host > '$HOST_MARKER'" \
  '```' > "$REPO_DIR/$SPEC_DIR_REL/tasks.md"
STAGE_A_VERIFY_EXECUTION_BOUNDARY="host"
export STAGE_A_VERIFY_EXECUTION_BOUNDARY
rc="$(run_stage_a_verify)"
args="$(cat "$CODEX_ARGS_FILE")"
log_body="$(cat "$LOG")"
host_body="$(cat "$HOST_MARKER")"
assert_eq "$rc" "0" "host opt-in の直接実行成功を反映する"
assert_eq "$args" "" "host opt-in では codex sandbox を呼ばない"
assert_eq "$host_body" "host" "host opt-in は verify コマンドを REPO_DIR から直接実行する"
assert_contains "$log_body" "host EXEC boundary=host reason=operator-opt-in" "非 default 境界をログに残す"

echo "[case3] typo / 大文字違いは sandbox に倒れる"
setup_case "typo-boundary"
write_ios_tasks
STAGE_A_VERIFY_EXECUTION_BOUNDARY="Host"
export STAGE_A_VERIFY_EXECUTION_BOUNDARY
rc="$(run_stage_a_verify)"
args="$(cat "$CODEX_ARGS_FILE")"
log_body="$(cat "$LOG")"
assert_eq "$rc" "0" "typo 時も fake sandbox 成功を反映する"
assert_contains "$args" "<sandbox>" "typo 時は codex sandbox を呼ぶ"
assert_contains "$log_body" "fallback=codex-sandbox" "typo の fallback を警告する"

echo "[case4] CoreSimulator 境界失敗を exit code と別の診断として記録する"
setup_case "coresim-diagnostics"
write_ios_tasks
FAKE_CODEX_RC="70"
export FAKE_CODEX_RC
cat > "$FAKE_CODEX_OUTPUT_FILE" <<'FAKE_OUTPUT'
CoreSimulatorService connection became invalid. Simulator services will no longer be available.
Error opening log file (/Users/hitoshi/Library/Logs/CoreSimulator/CoreSimulator.com.apple.dt.xcodebuild.log): Operation not permitted
Unable to discover any Simulator runtimes.
xcodebuild: error: Unable to find a device matching the provided destination specifier:
  { platform:iOS Simulator, OS:latest, name:iPhone 17 }
FAKE_OUTPUT
rc="$(run_stage_a_verify)"
log_body="$(cat "$LOG")"
assert_eq "$rc" "1" "xcodebuild exit 70 は round=1 failure として扱う"
assert_contains "$log_body" "FAILED exit=70" "verify exit code をログに残す"
assert_contains "$log_body" "DIAGNOSTIC kind=coresimulator-connection" "CoreSimulatorService 接続失敗を診断する"
assert_contains "$log_body" "DIAGNOSTIC kind=coresimulator-permission" "CoreSimulator log の Operation not permitted を診断する"
assert_contains "$log_body" "DIAGNOSTIC kind=ios-simulator-destination" "destination 検出失敗に recovery hint を出す"
assert_contains "$log_body" "boundary_opt_in=STAGE_A_VERIFY_EXECUTION_BOUNDARY=host" "gate opt-out と境界調整の違いを示す"

echo "[case5] heuristic の xcodebuild verify 行も抽出対象になる"
setup_case "heuristic-xcodebuild"
printf '%s\n' \
  "# Tasks" \
  "" \
  "- [ ] xcodebuild -project KukuMaster.xcodeproj -scheme KukuMaster -destination 'platform=iOS Simulator,name=iPhone 17' test" \
  > "$REPO_DIR/$SPEC_DIR_REL/tasks.md"
rc="$(run_stage_a_verify)"
args="$(cat "$CODEX_ARGS_FILE")"
assert_eq "$rc" "0" "heuristic xcodebuild の fake sandbox 成功を反映する"
assert_contains "$args" "<sandbox>" "heuristic xcodebuild は sandbox 経由"
assert_contains "$args" "<xcodebuild -project KukuMaster.xcodeproj -scheme KukuMaster -destination 'platform=iOS Simulator,name=iPhone 17' test>" "xcodebuild 行を verify コマンドとして抽出する"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo "RESULT: FAIL" >&2
  exit 1
fi
echo "RESULT: PASS"
