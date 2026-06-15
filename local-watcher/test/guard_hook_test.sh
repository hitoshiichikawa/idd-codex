#!/usr/bin/env bash
#
# 用途: local-watcher/hooks/idd-codex-guard.sh の G0/G1/G2 判定を PreToolUse JSON fixture で検証する。
# 配置先: local-watcher/test/guard_hook_test.sh
# 依存: bash 4+, jq
# 実行: bash local-watcher/test/guard_hook_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SH="$SCRIPT_DIR/../hooks/idd-codex-guard.sh"

if [ ! -x "$HOOK_SH" ]; then
  echo "ERROR: cannot execute hook script at $HOOK_SH" >&2
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

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
