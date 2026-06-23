#!/usr/bin/env bash
#
# 用途: pi_build_iteration_prompt の line コメント射影に追加した self-filter（idd-claude
#       #400 移植）を検証する。PR Iteration 自身の `idd-codex:pr-iteration` marker を
#       line コメントから除外しつつ、`idd-codex:pr-reviewer` の review 指摘と通常の人間
#       コメントは iteration 入力として残すこと（空入力 no-progress stuck の回避）を確認する。
#
#       本テストは pr-iteration.sh の line コメント射影 jq 式と同一の式を検証する
#       （pi_build_iteration_prompt 内の `line_comments_json=$(... | jq ...)`）。
#
# 配置先: local-watcher/test/pi_line_comment_self_filter_test.sh
# 依存:   bash 4+, jq, grep
# 実行:   bash local-watcher/test/pi_line_comment_self_filter_test.sh

set -euo pipefail

PR_REVIEWER_ITER_MODULE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../bin/idd-codex-modules/pr-iteration.sh"
[ -f "$PR_REVIEWER_ITER_MODULE" ] || { echo "ERROR: not found: $PR_REVIEWER_ITER_MODULE" >&2; exit 2; }

# 退行防止: 本テストの jq 式が production（line コメント射影）と一致していることを確認する。
# production 側に projection + self-filter（test(...idd-codex:pr-iteration...)）が在ることを保証。
if ! grep -q 'idd-codex:pr-iteration(\[\[:space:\]>-\]|$)' "$PR_REVIEWER_ITER_MODULE"; then
  echo "ERROR: production の self-filter 述語が見つからない（式がドリフトした可能性）" >&2; exit 2
fi
grep -q 'id, path, line, user: (.user.login // ""), body' "$PR_REVIEWER_ITER_MODULE" || { echo "ERROR: line コメント射影が見つからない" >&2; exit 2; }

# production と同一の line コメント射影 + self-filter（pr-iteration.sh の該当行と一致させる）。
apply_line_filter() {
  jq '[.[]
        | {id, path, line, user: (.user.login // ""), body}
        | select((.body // "") | test("<!--[[:space:]]*idd-codex:pr-iteration([[:space:]>-]|$)") | not)]'
}

PASS_COUNT=0; FAIL_COUNT=0
assert_eq() { local l="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l (exp=$e act=$a)"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }

RAW='[
  {"id":1,"path":"a.sh","line":10,"user":{"login":"human"},"body":"ここ直して"},
  {"id":2,"path":"b.sh","line":20,"user":{"login":"bot"},"body":"[high] b.sh:20 — bug\n<!-- idd-codex:pr-reviewer sha=abc kind=review tool=codex -->"},
  {"id":3,"path":"c.sh","line":30,"user":{"login":"bot"},"body":"round 1 出力\n<!-- idd-codex:pr-iteration round=1 last-run=x no-progress-streak=0 -->"}
]'

OUT="$(printf '%s' "$RAW" | apply_line_filter)"

echo "--- line コメント self-filter ---"
assert_eq "結果件数 = 2（self 1 件を除外）" "2" "$(printf '%s' "$OUT" | jq 'length')"
assert_eq "人間コメント(id=1)は残る" "1" "$(printf '%s' "$OUT" | jq '[.[]|select(.id==1)]|length')"
assert_eq "pr-reviewer 指摘(id=2)は残る（actionable 入力）" "1" "$(printf '%s' "$OUT" | jq '[.[]|select(.id==2)]|length')"
assert_eq "pr-iteration 自身(id=3)は除外" "0" "$(printf '%s' "$OUT" | jq '[.[]|select(.id==3)]|length')"
assert_eq "射影スキーマに body を保持（filter 可能）" "true" "$(printf '%s' "$OUT" | jq 'all(.[]; has("body"))')"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
