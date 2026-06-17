#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-modules/promote-pipeline.sh の
#       po_load_edit_paths が Issue #50 の信頼済み author 境界を守ることを検証する。
#
#       検証観点:
#         - OWNER / MEMBER / COLLABORATOR の marker は採用する
#         - 未信頼 author の marker は混在しても採用しない
#         - 未信頼 author の marker が最後でも last-wins を上書きしない
#         - 信頼済み marker 不在、API / jq / JSON 不正時は [] を返し return 0
#         - array 内の非文字列要素は除外する
#
# 配置先: local-watcher/test/po_load_edit_paths_trusted_authors_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/po_load_edit_paths_trusted_authors_test.sh
# 前提:   promote-pipeline.sh から po_load_edit_paths() のみを awk で切り出して
#         eval で読み込み、gh は fixture を返す stub に差し替える。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMOTE_PIPELINE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/promote-pipeline.sh"

if [ ! -f "$PROMOTE_PIPELINE_SH" ]; then
  echo "ERROR: cannot find promote-pipeline.sh at $PROMOTE_PIPELINE_SH" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
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
eval "$(extract_function "$PROMOTE_PIPELINE_SH" "po_load_edit_paths")"

if ! declare -F po_load_edit_paths >/dev/null; then
  echo "ERROR: po_load_edit_paths not loaded" >&2
  exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
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

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
comments_file="$tmp_dir/comments.json"
call_log="$tmp_dir/gh-calls.log"

cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$PO_LOAD_EDIT_PATHS_TEST_CALL_LOG"
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  if [ "${PO_LOAD_EDIT_PATHS_TEST_GH_FAIL:-false}" = "true" ]; then
    exit 22
  fi
  cat "$PO_LOAD_EDIT_PATHS_TEST_COMMENTS"
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 99
STUB
chmod +x "$tmp_dir/gh"

export PATH="$tmp_dir:$PATH"
export REPO="owner/repo"
export PO_LOAD_EDIT_PATHS_TEST_COMMENTS="$comments_file"
export PO_LOAD_EDIT_PATHS_TEST_CALL_LOG="$call_log"
export PO_LOAD_EDIT_PATHS_TEST_GH_FAIL="false"

set_comments() {
  printf '%s\n' "$1" >"$comments_file"
  : >"$call_log"
  export PO_LOAD_EDIT_PATHS_TEST_GH_FAIL="false"
}

set_invalid_comments() {
  printf '%s\n' "$1" >"$comments_file"
  : >"$call_log"
  export PO_LOAD_EDIT_PATHS_TEST_GH_FAIL="false"
}

set_gh_failure() {
  printf '{"comments":[]}\n' >"$comments_file"
  : >"$call_log"
  export PO_LOAD_EDIT_PATHS_TEST_GH_FAIL="true"
}

run_loader() {
  local expected="$1"
  local label="$2"
  local rc=0
  local out
  out=$(po_load_edit_paths 50) || rc=$?
  assert_eq "$label: return code" "0" "$rc"
  assert_eq "$label" "$expected" "$out"
  assert_eq "$label: gh issue view は 1 回だけ呼ぶ" \
    "1" \
    "$(wc -l <"$call_log" | tr -d ' ')"
  assert_eq "$label: gh issue view 引数" \
    "issue view 50 --repo owner/repo --json comments" \
    "$(cat "$call_log")"
}

marker_comment() {
  local assoc="$1"
  local payload="$2"
  jq -nc --arg assoc "$assoc" --arg payload "$payload" \
    '{author_association: $assoc, body: ("before\n<!-- idd-codex:edit-paths-json:" + $payload + " -->\nafter")}'
}

comments_array() {
  jq -nc '$ARGS.positional | map(fromjson) | {comments: .}' --args "$@"
}

echo "--- po_load_edit_paths trusted author cases (Issue #50) ---"

set_comments "$(comments_array \
  "$(marker_comment "OWNER" '["local-watcher/","README.md"]')")"
run_loader '["local-watcher/","README.md"]' \
  "信頼済み OWNER の marker は採用される"

set_comments "$(comments_array \
  "$(marker_comment "CONTRIBUTOR" '["evil/"]')" \
  "$(marker_comment "MEMBER" '["trusted/"]')" \
  "$(marker_comment "NONE" '["ignored/"]')")"
run_loader '["trusted/"]' \
  "未信頼 marker が混在しても信頼済み marker だけ採用される"

set_comments "$(comments_array \
  "$(marker_comment "COLLABORATOR" '["trusted-last-wins-base/"]')" \
  "$(marker_comment "NONE" '["evil-last/"]')")"
run_loader '["trusted-last-wins-base/"]' \
  "未信頼 marker が最後でも last-wins を上書きしない"

set_comments "$(comments_array \
  "$(marker_comment "NONE" '["outsider/"]')" \
  "$(marker_comment "CONTRIBUTOR" '["contributor/"]')")"
run_loader '[]' \
  "信頼済み marker 不在時は [] を返す"

set_comments '{"comments":[{"author_association":"OWNER","body":"no marker here"}]}'
run_loader '[]' \
  "marker 不在時は [] を返す"

set_comments "$(comments_array \
  "$(marker_comment "OWNER" 'not-json')")"
run_loader '[]' \
  "信頼済み marker の JSON 不正時は [] を返す"

set_comments "$(comments_array \
  "$(marker_comment "OWNER" '{"path":"README.md"}')")"
run_loader '[]' \
  "信頼済み marker が array 以外なら [] を返す"

set_comments "$(comments_array \
  "$(marker_comment "OWNER" '["README.md",42,null,"local-watcher/"]')")"
run_loader '["README.md","local-watcher/"]' \
  "信頼済み marker の array 内非文字列要素は除外される"

set_invalid_comments '{not valid json'
run_loader '[]' \
  "jq failure 時は [] を返す"

set_gh_failure
run_loader '[]' \
  "gh issue view failure 時は [] を返す"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
