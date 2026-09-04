#!/usr/bin/env bash
#
# 用途: codex_exec_prompt の production entrypoint で model preflight が codex exec
#       起動前に実行されることを検証する。
# 配置先: local-watcher/test/model_preflight_exec_prompt_test.sh
# 依存: bash 4+
# 実行: bash local-watcher/test/model_preflight_exec_prompt_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
CORE_UTILS_SH="$SCRIPT_DIR/../bin/idd-codex-modules/core_utils.sh"
MODEL_PREFLIGHT_SH="$SCRIPT_DIR/../bin/idd-codex-modules/model-preflight.sh"

for path in "$WATCHER_SH" "$CORE_UTILS_SH" "$MODEL_PREFLIGHT_SH"; do
  if [ ! -f "$path" ]; then
    echo "ERROR: missing test dependency: $path" >&2
    exit 2
  fi
done

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/idd-codex-exec-preflight-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# shellcheck source=../bin/idd-codex-modules/core_utils.sh
. "$CORE_UTILS_SH"
# shellcheck source=../bin/idd-codex-modules/model-preflight.sh
. "$MODEL_PREFLIGHT_SH"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "codex_exec_prompt")"

codex_reasoning_effort_for_stage() { printf '%s\n' "medium"; }
codex_build_role_preamble() { :; }
codex_agent_roles_for_stage() { printf '%s\n' "Developer"; }
codex_wants_web_search() { return 1; }
codex_effective_timeout_sec() { :; }
guard_build_args() {
  # shellcheck disable=SC2034  # codex_exec_prompt が dynamic scope で配列を参照する
  CODEX_HOOK_ARGS=()
}

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
  local label="$1" haystack="$2" needle="$3"
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
  local label="$1" haystack="$2" needle="$3"
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

export REPO="owner/repo"
export REPO_DIR="$TMP_DIR/repo"
export NUMBER="175"
export CODEX_LAST_MESSAGE_DIR="$TMP_DIR/last-message"
export CODEX_BIN="$TMP_DIR/codex"
export CODEX_EPHEMERAL="false"
export CODEX_UNSAFE_BYPASS="false"
export CODEX_SANDBOX="workspace-write"
export CODEX_APPROVAL_POLICY="never"
export MODEL_PREFLIGHT_ENABLED="true"
export MODEL_PREFLIGHT_MIN_VERSIONS="gpt-5.6-*:0.144.0"
export CODEX_CALL_LOG="$TMP_DIR/codex-calls.log"
export STUB_CODEX_VERSION="0.144.0"
mkdir -p "$REPO_DIR"

cat > "$CODEX_BIN" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CODEX_CALL_LOG:?}"
if [ "${1:-}" = "--version" ]; then
  printf 'codex-cli %s\n' "${STUB_CODEX_VERSION:-0.144.0}"
  exit 0
fi
cat >/dev/null
printf '%s\n' '{"type":"result","is_error":false}'
exit "${STUB_CODEX_EXEC_RC:-0}"
STUB
chmod +x "$CODEX_BIN"

reset_case() {
  : > "$CODEX_CALL_LOG"
  mp_clear_last_config_error
  unset STUB_CODEX_EXEC_RC
  export STUB_CODEX_VERSION="0.144.0"
  export MODEL_PREFLIGHT_ENABLED="true"
}

reset_case
export STUB_CODEX_VERSION="0.143.9"
rc=0
codex_exec_prompt "StageA" "gpt-5.6-luna" "prompt" > "$TMP_DIR/out" 2> "$TMP_DIR/err" || rc=$?
calls="$(cat "$CODEX_CALL_LOG")"
assert_eq "known model insufficient version returns rc 78 before exec" "78" "$rc"
assert_eq "known model insufficient version only calls --version" "--version" "$calls"
assert_not_contains "known model insufficient version does not run codex exec" "$calls" "exec -C"

reset_case
rc=0
codex_exec_prompt "StageA" "gpt-5.9-next" "prompt" > "$TMP_DIR/out" 2> "$TMP_DIR/err" || rc=$?
calls="$(cat "$CODEX_CALL_LOG")"
assert_eq "unknown model reaches codex exec" "0" "$rc"
assert_not_contains "unknown model does not call --version" "$calls" "--version"
assert_contains "unknown model command includes exec" "$calls" "exec -C"

reset_case
export MODEL_PREFLIGHT_ENABLED="false"
export STUB_CODEX_VERSION="0.143.9"
rc=0
codex_exec_prompt "StageA" "gpt-5.6-luna" "prompt" > "$TMP_DIR/out" 2> "$TMP_DIR/err" || rc=$?
calls="$(cat "$CODEX_CALL_LOG")"
assert_eq "disabled preflight reaches codex exec" "0" "$rc"
assert_not_contains "disabled preflight skips --version" "$calls" "--version"
assert_contains "disabled preflight command includes exec" "$calls" "exec -C"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
