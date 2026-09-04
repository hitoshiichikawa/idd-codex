#!/usr/bin/env bash
#
# 用途: local-watcher/hooks/idd-codex-guard.sh の G0/G1/G2 判定を PreToolUse JSON fixture で検証する。
# 配置先: local-watcher/test/guard_hook_test.sh
# 依存: bash 4+, jq
# 実行: bash local-watcher/test/guard_hook_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SH="$SCRIPT_DIR/../hooks/idd-codex-guard.sh"
CORE_UTILS_SH="$SCRIPT_DIR/../bin/idd-codex-modules/core_utils.sh"
GUARD_MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/guard-hook.sh"

if [ ! -x "$HOOK_SH" ]; then
  echo "ERROR: cannot execute hook script at $HOOK_SH" >&2
  exit 2
fi
if [ ! -f "$CORE_UTILS_SH" ]; then
  echo "ERROR: cannot find core_utils.sh at $CORE_UTILS_SH" >&2
  exit 2
fi
if [ ! -f "$GUARD_MODULE_SH" ]; then
  echo "ERROR: cannot find guard-hook.sh at $GUARD_MODULE_SH" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 2
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/idd-codex-guard-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

export IDD_HOOK_BASE_BRANCH="main"
export IDD_CODEX_HOOKS_DIR="$TMP_DIR/hooks"
export IDD_CODEX_HOOKS_CONFIG_FILE="$TMP_DIR/codex/idd-codex-guard.config.toml"
mkdir -p "$IDD_CODEX_HOOKS_DIR" "$(dirname "$IDD_CODEX_HOOKS_CONFIG_FILE")"

PASS_COUNT=0
FAIL_COUNT=0

# shellcheck source=../bin/idd-codex-modules/core_utils.sh
. "$CORE_UTILS_SH"
# shellcheck source=../bin/idd-codex-modules/guard-hook.sh
. "$GUARD_MODULE_SH"

json_bash() {
  jq -n --arg cmd "$1" '{tool_name:"Bash", tool_input:{command:$cmd}}'
}

json_apply_patch() {
  jq -n --arg patch "$1" '{tool_name:"apply_patch", tool_input:{command:$patch}}'
}

json_write() {
  jq -n --arg path "$1" '{tool_name:"Write", tool_input:{file_path:$path}}'
}

run_hook() {
  local input="$1"
  printf '%s' "$input" | "$HOOK_SH"
}

assert_decision() {
  local label="$1"
  local expected="$2"
  local input="$3"
  local out actual reason
  out="$(run_hook "$input")"
  if jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 <<<"$out"; then
    actual="deny"
    reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<<"$out")"
  else
    actual="allow"
    reason=""
  fi

  if [ "$actual" = "$expected" ]; then
    echo "PASS: $label ($actual${reason:+: $reason})"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected: $expected"
    echo "  actual  : $actual"
    echo "  output  : $out"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_stdout() {
  local label="$1"
  local expected="$2"
  shift 2
  local out
  out="$("$@")"
  if [ "$out" = "$expected" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected: $expected"
    echo "  actual  : $out"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_rc() {
  local label="$1"
  local expected="$2"
  shift 2
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $label (rc=$actual)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected rc: $expected"
    echo "  actual rc  : $actual"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_decision "allow normal bash" "allow" "$(json_bash "echo idd-codex-guard-ok")"
assert_decision "deny base push explicit" "deny" "$(json_bash "git push origin main")"
assert_decision "deny base push refs/heads" "deny" "$(json_bash "git -C /tmp/repo push origin HEAD:refs/heads/main")"
assert_decision "deny base push implicit refs/heads" "deny" "$(json_bash "git push refs/heads/main")"
assert_decision "deny base push implicit remote" "deny" "$(json_bash "git push main")"
assert_decision "allow feature push" "allow" "$(json_bash "git push origin codex/issue-1-demo")"
assert_decision "deny force short" "deny" "$(json_bash "git push -f origin codex/issue-1-demo")"
assert_decision "deny force long" "deny" "$(json_bash "git push --force origin codex/issue-1-demo")"
assert_decision "allow force with lease" "allow" "$(json_bash "git push --force-with-lease origin codex/issue-1-demo")"
assert_decision "deny plus refspec" "deny" "$(json_bash "git push origin +HEAD:codex/issue-1-demo")"
assert_decision "deny delete base" "deny" "$(json_bash "git push origin --delete main")"
assert_decision "deny hook write" "deny" "$(json_write "$IDD_CODEX_HOOKS_DIR/idd-codex-guard.sh")"
assert_decision "deny config write" "deny" "$(json_write "$IDD_CODEX_HOOKS_CONFIG_FILE")"
assert_decision "deny hook bash mutation" "deny" "$(json_bash "rm -f $IDD_CODEX_HOOKS_DIR/idd-codex-guard.sh")"
assert_decision "deny hook apply_patch mutation" "deny" "$(json_apply_patch "*** Begin Patch
*** Update File: $IDD_CODEX_HOOKS_CONFIG_FILE
@@
-x
+y
*** End Patch")"
assert_decision "allow unrelated apply_patch" "allow" "$(json_apply_patch "*** Begin Patch
*** Update File: README.md
@@
-x
+y
*** End Patch")"

# ── Issue #49: コマンドパーサ・バイパス回帰（全 segment 走査 / 先頭トークン正規化 /
#    束ね短 flag / G0 mutator 拡張）──
assert_decision "deny push after no-op prefix (;)" "deny" "$(json_bash "true; git push --force origin main")"
assert_decision "deny push after no-op prefix (&&)" "deny" "$(json_bash "echo a && git push -f origin main")"
assert_decision "deny push after pipe" "deny" "$(json_bash "echo x | git push --force origin main")"
assert_decision "deny push via command wrapper" "deny" "$(json_bash "command git push -f origin main")"
assert_decision "deny push via env wrapper" "deny" "$(json_bash "env X=1 git push -f origin main")"
assert_decision "deny push via absolute path git" "deny" "$(json_bash "/usr/bin/git push -f origin main")"
assert_decision "deny push via bash -c wrapper" "deny" "$(json_bash 'bash -c "git push --force origin main"')"
assert_decision "deny bundled short force flag -fu" "deny" "$(json_bash "git push -fu origin codex/issue-1")"
assert_decision "deny self-mutation via cp" "deny" "$(json_bash "cp /dev/null $IDD_CODEX_HOOKS_DIR/idd-codex-guard.sh")"
assert_decision "deny self-mutation via ln" "deny" "$(json_bash "ln -sf /evil $IDD_CODEX_HOOKS_DIR/idd-codex-guard.sh")"
assert_decision "deny self-mutation via truncate" "deny" "$(json_bash "truncate -s0 $IDD_CODEX_HOOKS_DIR/idd-codex-guard.sh")"
assert_decision "deny self-mutation redirect no-space" "deny" "$(json_bash "echo x >$IDD_CODEX_HOOKS_DIR/idd-codex-guard.sh")"
assert_decision "deny self-mutation via bash -c rm" "deny" "$(json_bash "bash -c \"rm $IDD_CODEX_HOOKS_DIR/idd-codex-guard.sh\"")"
# 正当系（誤検知しないこと）
assert_decision "allow legit push after no-op prefix" "allow" "$(json_bash "true && git push origin codex/issue-1")"
assert_decision "allow bash -c with test command" "allow" "$(json_bash 'bash -c "npm test && npm run build"')"
assert_decision "allow rm in repo (non-protected)" "allow" "$(json_bash "rm -rf node_modules")"
assert_decision "allow read of protected path" "allow" "$(json_bash "cat $IDD_CODEX_HOOKS_DIR/idd-codex-guard.sh")"

# Issue #175 Task 1: shared semver helper regression.
assert_stdout "extract semver from codex --version output" "0.144.1" idd_extract_semver "codex-cli 0.144.1"
assert_rc "extract semver rejects missing version" "1" idd_extract_semver "codex-cli dev"
assert_rc "semver equal passes" "0" idd_compare_semver "0.144.0" "0.144.0"
assert_rc "semver greater passes" "0" idd_compare_semver "0.145.0" "0.144.9"
assert_rc "semver lesser fails" "1" idd_compare_semver "0.143.9" "0.144.0"
assert_rc "semver missing patch defaults to zero" "0" idd_compare_semver "0.144" "0.144.0"
assert_rc "semver suffix uses numeric prefix" "0" idd_compare_semver "0.144.0-beta.1" "0.144.0"
assert_rc "semver invalid actual is comparison error" "2" idd_compare_semver "dev" "0.144.0"
assert_rc "guard semver wrapper delegates shared helper" "0" guard_compare_semver "0.144.0-nightly" "0.144.0"

STUB_CODEX="$TMP_DIR/codex-bin"
cat >"$STUB_CODEX" <<'STUB'
#!/usr/bin/env bash
printf 'codex-cli %s\n' "${STUB_CODEX_VERSION:-0.144.0}"
STUB
chmod +x "$STUB_CODEX"
cat >"$IDD_CODEX_HOOKS_DIR/idd-codex-guard.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '{"hookSpecificOutput":{"permissionDecision":"allow"}}\n'
STUB
chmod +x "$IDD_CODEX_HOOKS_DIR/idd-codex-guard.sh"
printf 'command = "%s/idd-codex-guard.sh"\n' "$IDD_CODEX_HOOKS_DIR" >"$IDD_CODEX_HOOKS_CONFIG_FILE"

export REPO="owner/repo"
export CODEX_BIN="$STUB_CODEX"
export IDD_CODEX_HOOKS_ENABLED="true"
export IDD_CODEX_HOOKS_MIN_VERSION="0.144.0"
export IDD_CODEX_HOOKS_CONFIG_DIR="$TMP_DIR/codex"
export STUB_CODEX_VERSION="0.143.9"
assert_rc "guard preflight rejects older codex version" "11" guard_preflight
export STUB_CODEX_VERSION="0.144.0-beta.1"
assert_rc "guard preflight accepts equal version with suffix" "0" guard_preflight

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
