#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-issue-watcher.sh の Triage プロンプト描画
#       (_triage_render_prompt) が、未信頼の Issue タイトル等をリテラル置換し、
#       command injection（sed の e コマンド等）を成立させないことを検証する
#       回帰テスト。Issue #47（sed e-command RCE）で追加。
#
#       検証観点:
#         - 旧実装の sed RCE payload を流しても外部コマンドが実行されない
#         - プレースホルダがタイトル値で正しく置換される
#         - `&`（bash 5.1+ の置換特殊文字）がリテラルとして残る
#         - バックスラッシュがリテラルとして残る（awk -v の解釈差を回避）
#         - タイトルに別プレースホルダ文字列が含まれても再展開しない
#
# 配置先: local-watcher/test/triage_prompt_render_safety_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/triage_prompt_render_safety_test.sh
# 前提:   issue-watcher.sh から _triage_render_prompt() のみを awk で切り出して eval で
#         読み込み、トップレベル副作用は回避する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "_triage_render_prompt")"

if ! declare -F _triage_render_prompt >/dev/null; then
  echo "ERROR: _triage_render_prompt not loaded" >&2
  exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected: $(printf '%q' "$expected")"
    echo "  actual  : $(printf '%q' "$actual")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
TMPL="$TMP_DIR/triage.tmpl"
cat >"$TMPL" <<'EOF'
Number: {{NUMBER}}
Title: {{TITLE}}
URL: {{URL}}
File: {{FILE}}
EOF

echo "--- _triage_render_prompt safety cases (Issue #47) ---"

# 1. 旧 sed 実装で RCE になっていた payload を流しても外部コマンドが実行されない
PWN_MARKER="$TMP_DIR/PWNED"
rm -f "$PWN_MARKER"
evil_title="A\\|; e touch $PWN_MARKER"
out=$(_triage_render_prompt "$TMPL" 42 "$evil_title" "https://example/42" "/tmp/x.json")
assert_eq "RCE payload は実行されない（マーカーファイル未生成）" \
  "absent" \
  "$([ -e "$PWN_MARKER" ] && echo present || echo absent)"
assert_eq "RCE payload はリテラルとして本文に残る" \
  "true" \
  "$(printf '%s\n' "$out" | grep -qF "Title: $evil_title" && echo true || echo false)"

# 2. 通常タイトルが正しく置換される
out=$(_triage_render_prompt "$TMPL" 7 "Fix login bug" "https://example/7" "/tmp/y.json")
assert_eq "NUMBER が置換される" "Number: 7" "$(printf '%s\n' "$out" | sed -n '1p')"
assert_eq "TITLE が置換される" "Title: Fix login bug" "$(printf '%s\n' "$out" | sed -n '2p')"

# 3. `&`（bash 5.1+ の置換特殊文字）がリテラルとして残る
out=$(_triage_render_prompt "$TMPL" 8 "rename A & B" "https://example/8" "/tmp/z.json")
assert_eq "& はリテラルとして保持される（マッチ文字列に化けない）" \
  "Title: rename A & B" \
  "$(printf '%s\n' "$out" | sed -n '2p')"

# 4. バックスラッシュがリテラルとして残る（awk -v 解釈差の回避）
out=$(_triage_render_prompt "$TMPL" 9 'path C:\new\tmp' "https://example/9" "/tmp/w.json")
assert_eq "バックスラッシュがリテラル保持される" \
  'Title: path C:\new\tmp' \
  "$(printf '%s\n' "$out" | sed -n '2p')"

# 5. repl() は自身が挿入した値を再走査しない（{{TITLE}} を含むタイトルは無限展開しない）
out=$(_triage_render_prompt "$TMPL" 10 '{{TITLE}}' "https://example/10" "/tmp/v.json")
assert_eq "挿入値内の {{TITLE}} は再展開されずリテラルとして残る" \
  "Title: {{TITLE}}" \
  "$(printf '%s\n' "$out" | sed -n '2p')"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
