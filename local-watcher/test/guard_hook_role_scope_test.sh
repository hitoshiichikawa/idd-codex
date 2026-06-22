#!/usr/bin/env bash
#
# 用途: idd-codex-guard.sh の G3（read-only-writer role 書き込みスコープ強制 / #80）を
#       PreToolUse JSON fixture で検証する。reviewer/debugger role のとき、許可 notes 以外への
#       repo 書き込みを deny し、許可 notes・temp・他 role は allow することを確認する。
# 実行: bash local-watcher/test/guard_hook_role_scope_test.sh
# 依存: bash 4+, jq

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SH="$SCRIPT_DIR/../hooks/idd-codex-guard.sh"
[ -x "$HOOK_SH" ] || { echo "ERROR: hook not executable: $HOOK_SH" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/idd-codex-g3.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
export IDD_HOOK_BASE_BRANCH="main"
export IDD_CODEX_HOOKS_DIR="$TMP_DIR/hooks"
export IDD_CODEX_HOOKS_CONFIG_FILE="$TMP_DIR/codex/idd-codex-guard.config.toml"
mkdir -p "$IDD_CODEX_HOOKS_DIR" "$(dirname "$IDD_CODEX_HOOKS_CONFIG_FILE")"

PASS=0; FAIL=0
json_write()  { jq -n --arg p "$1" '{tool_name:"Write", tool_input:{file_path:$p}}'; }
json_nb()     { jq -n --arg p "$1" '{tool_name:"NotebookEdit", tool_input:{notebook_path:$p}}'; }
json_patch()  { jq -n --arg c "$1" '{tool_name:"apply_patch", tool_input:{command:$c}}'; }
json_bash()   { jq -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

# assert_role <label> <role> <expected allow|deny> <json>
assert_role() {
  local label="$1" role="$2" expected="$3" input="$4" out actual
  out="$(printf '%s' "$input" | IDD_HOOK_ROLE="$role" "$HOOK_SH")"
  if jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 <<<"$out"; then actual="deny"; else actual="allow"; fi
  if [ "$actual" = "$expected" ]; then echo "PASS: $label ($actual)"; PASS=$((PASS+1));
  else echo "FAIL: $label expected=$expected actual=$actual out=$out"; FAIL=$((FAIL+1)); fi
}

# repo パスは非 temp の文字列を使う（hook は /tmp 配下を scratch として allow するため、
# fixture を /tmp 下に置くと source 改変も誤って allow されてしまう。hook はパス文字列の
# basename しか見ず実在を要求しないので、存在しない非 temp パスで判定を検証できる）。
REPO="/work/myrepo/docs/specs/1-x"
SRC="/work/myrepo/local-watcher/bin/idd-codex-issue-watcher.sh"

# reviewer: notes 以外への書き込みは deny
assert_role "reviewer Write source → deny" "reviewer" "deny" "$(json_write "$SRC")"
assert_role "reviewer Write review-notes.md → allow" "reviewer" "allow" "$(json_write "$REPO/review-notes.md")"
assert_role "reviewer apply_patch source → deny" "reviewer" "deny" "$(json_patch "*** Begin Patch
*** Update File: $SRC
@@
-a
+b
*** End Patch")"
assert_role "reviewer apply_patch review-notes.md → allow" "reviewer" "allow" "$(json_patch "*** Begin Patch
*** Update File: $REPO/review-notes.md
@@
-a
+b
*** End Patch")"
assert_role "reviewer apply_patch Add source → deny" "reviewer" "deny" "$(json_patch "*** Begin Patch
*** Add File: /work/myrepo/evil.sh
@@
+x
*** End Patch")"
assert_role "reviewer Write /tmp scratch → allow" "reviewer" "allow" "$(json_write "/tmp/reviewer-scratch.txt")"
assert_role "reviewer NotebookEdit source.ipynb → deny" "reviewer" "deny" "$(json_nb "/work/myrepo/nb.ipynb")"
assert_role "reviewer git push feature は G3 で触らない（allow）" "reviewer" "allow" "$(json_bash "git push origin codex/issue-1-x")"

# debugger: debugger-notes.md のみ許可
assert_role "debugger Write debugger-notes.md → allow" "debugger" "allow" "$(json_write "$REPO/debugger-notes.md")"
assert_role "debugger Write source → deny" "debugger" "deny" "$(json_write "$SRC")"
assert_role "debugger Write review-notes.md → deny（debugger の許可外）" "debugger" "deny" "$(json_write "$REPO/review-notes.md")"

# 制限対象外 role / 未設定 → 無制限（後方互換）
assert_role "developer Write source → allow" "developer" "allow" "$(json_write "$SRC")"
assert_role "role 未設定 Write source → allow" "" "allow" "$(json_write "$SRC")"
assert_role "multi-role 'product-manager developer' Write source → allow" "product-manager developer" "allow" "$(json_write "$SRC")"

# G3 が既存 G0/G1/G2 を壊さないことの確認（reviewer でも base push は依然 deny）
assert_role "reviewer base push は依然 deny（G1 維持）" "reviewer" "deny" "$(json_bash "git push origin main")"

echo "──────────────"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1; echo "ALL GREEN"
