#!/usr/bin/env bash
#
# 用途: qa_log_token_usage（#83 観測性）が codex の turn.completed.usage を堅牢に集計して
#       per-stage token サマリをログすることを検証する。
#   - 複数 turn の合算 / 欠損フィールドの 0 既定 / stderr 等の非 JSON 行混在への堅牢性
#   - turn.completed が 1 件も無ければログしない
# 実行: bash local-watcher/test/qa_token_usage_test.sh
# 依存: bash 4+, jq, awk

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/quota-aware.sh"
[ -f "$MODULE_SH" ] || { echo "ERROR: quota-aware.sh not found" >&2; exit 2; }

extract_function() {
  awk -v fn="${2}() {" '$0==fn{i=1} i{print} i&&$0=="}"{i=0}' "$1"
}
# shellcheck disable=SC1090
eval "$(extract_function "$MODULE_SH" "qa_log_token_usage")"
declare -F qa_log_token_usage >/dev/null || { echo "ERROR: fn not loaded" >&2; exit 2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
CAP="$TMP/cap.log"
# qa_log をスタブ化して捕捉（本物は core_utils 由来。ここでは出力内容のみ検証する）。
qa_log() { printf '%s\n' "$*" >>"$CAP"; }

PASS=0; FAIL=0
assert_contains() {
  if grep -qF "$2" "$CAP"; then echo "PASS: $1"; PASS=$((PASS+1));
  else echo "FAIL: $1 (missing '$2' in: $(tr '\n' '|' <"$CAP"))"; FAIL=$((FAIL+1)); fi
}
assert_empty_cap() {
  if [ ! -s "$CAP" ]; then echo "PASS: $1"; PASS=$((PASS+1));
  else echo "FAIL: $1 (unexpected: $(cat "$CAP"))"; FAIL=$((FAIL+1)); fi
}

# 1. 単一 turn.completed
: >"$CAP"
cat >"$TMP/s1.jsonl" <<'EOF'
{"type":"thread.started","thread_id":"t1"}
{"type":"turn.started"}
{"type":"item.completed","item":{"type":"agent_message","text":"OK"}}
{"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":50,"reasoning_output_tokens":30}}
EOF
qa_log_token_usage "StageA" "$TMP/s1.jsonl"
assert_contains "単一 turn の集計" "stage tokens label=StageA input=1000 cached_input=200 output=50 reasoning=30 total=1050 turns=1"

# 2. 複数 turn.completed は合算
: >"$CAP"
cat >"$TMP/s2.jsonl" <<'EOF'
{"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":10,"cached_input_tokens":5,"reasoning_output_tokens":2}}
{"type":"turn.completed","usage":{"input_tokens":200,"output_tokens":20,"cached_input_tokens":5,"reasoning_output_tokens":3}}
EOF
qa_log_token_usage "Reviewer" "$TMP/s2.jsonl"
assert_contains "複数 turn 合算" "input=300 cached_input=10 output=30 reasoning=5 total=330 turns=2"

# 3. stderr 等の非 JSON 行が混ざっても堅牢
: >"$CAP"
cat >"$TMP/s3.jsonl" <<'EOF'
Reading prompt from stdin...
{"type":"turn.started"}
garbage line not json
{"type":"turn.completed","usage":{"input_tokens":42,"output_tokens":8}}
EOF
qa_log_token_usage "Debugger" "$TMP/s3.jsonl"
assert_contains "非 JSON 行混在でも集計（欠損は 0 既定）" "input=42 cached_input=0 output=8 reasoning=0 total=50 turns=1"

# 4. turn.completed 無し → ログしない
: >"$CAP"
cat >"$TMP/s4.jsonl" <<'EOF'
{"type":"thread.started","thread_id":"t4"}
{"type":"item.completed","item":{"type":"agent_message","text":"hi"}}
EOF
qa_log_token_usage "StageC" "$TMP/s4.jsonl"
assert_empty_cap "turn.completed 無しはログしない"

# 5. ファイル不在 → 無害（ログしない）
: >"$CAP"
qa_log_token_usage "StageA" "$TMP/does-not-exist.jsonl"
assert_empty_cap "stream 不在は無害"

echo "──────────────"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1; echo "ALL GREEN"
