#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# 用途: PR Iteration の usage-limit 風 fatal error 検出と、同一 round の
#       processing コメント重複抑止を検証するスモークテスト。
#
# 配置先: local-watcher/test/pi_usage_limit_fatal_test.sh
# 依存:   bash 4+, awk, jq, grep
# 実行:   bash local-watcher/test/pi_usage_limit_fatal_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_ITERATION_SH="$SCRIPT_DIR/../bin/idd-codex-modules/pr-iteration.sh"
MODEL_PREFLIGHT_SH="$SCRIPT_DIR/../bin/idd-codex-modules/model-preflight.sh"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/pi_usage_limit_fatal"

if [ ! -f "$PR_ITERATION_SH" ]; then
  echo "ERROR: cannot find pr-iteration.sh at $PR_ITERATION_SH" >&2
  exit 2
fi
if [ ! -f "$MODEL_PREFLIGHT_SH" ]; then
  echo "ERROR: cannot find model-preflight.sh at $MODEL_PREFLIGHT_SH" >&2
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

pi_log() { echo "LOG: $*" >&2; }
pi_warn() { echo "WARN: $*" >&2; }

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_SH" "pi_extract_usage_limit_reset_epoch")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_SH" "pi_detect_usage_limit_fatal")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_SH" "pi_processing_comment_exists")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_SH" "pi_post_processing_comment")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_SH" "pi_maybe_handle_model_config_error")"
# shellcheck source=../bin/idd-codex-modules/model-preflight.sh
. "$MODEL_PREFLIGHT_SH"

for fn in pi_extract_usage_limit_reset_epoch pi_detect_usage_limit_fatal pi_processing_comment_exists pi_post_processing_comment pi_maybe_handle_model_config_error mp_classify_codex_failure; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

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

echo "--- pi_detect_usage_limit_fatal cases (Issue #4) ---"

rc=0
out=$(pi_detect_usage_limit_fatal "$FIXTURE_DIR/usage-limit-with-reset.jsonl") || rc=$?
assert_eq "usage-limit 風 fatal + reset ありは検出する" "0" "$rc"
assert_eq "reset あり検出の path" "usage_limit_fatal" "$(printf '%s\n' "$out" | awk -F '\t' '{print $1}')"
if [[ "$(printf '%s\n' "$out" | awk -F '\t' '{print $2}')" =~ ^[0-9]+$ ]]; then
  assert_eq "reset epoch は数値" "true" "true"
else
  assert_eq "reset epoch は数値" "true" "false"
fi

rc=0
out=$(pi_detect_usage_limit_fatal "$FIXTURE_DIR/usage-limit-no-reset.jsonl") || rc=$?
assert_eq "usage-limit 風 fatal + reset なしも検出する" "0" "$rc"
assert_eq "reset なし検出の epoch は空" "" "$(printf '%s\n' "$out" | awk -F '\t' '{print $2}')"

rc=0
pi_detect_usage_limit_fatal "$FIXTURE_DIR/normal-error.jsonl" >/dev/null || rc=$?
assert_eq "通常 fatal error は usage-limit 扱いしない" "1" "$rc"

# Issue #170: codex-cli 0.144 系の workspace 系新文言（out of credits）も検出する
# （reset なし → epoch 空で有界 retry marker 経路へ）。
rc=0
out=$(pi_detect_usage_limit_fatal "$FIXTURE_DIR/usage-limit-workspace-credits.jsonl") || rc=$?
assert_eq "workspace out-of-credits fatal を検出する (Issue #170)" "0" "$rc"
assert_eq "workspace out-of-credits の path" "usage_limit_fatal" "$(printf '%s\n' "$out" | awk -F '\t' '{print $1}')"
assert_eq "workspace out-of-credits の epoch は空" "" "$(printf '%s\n' "$out" | awk -F '\t' '{print $2}')"

# Issue #170: 文頭大文字 ` Try again at <絶対日付>.`（0.144 系 retry_suffix）でも
# reset epoch を抽出できる（[Tt] 両対応）。
rc=0
out=$(pi_detect_usage_limit_fatal "$FIXTURE_DIR/usage-limit-capital-try-again.jsonl") || rc=$?
assert_eq "capital Try-again fatal を検出する (Issue #170)" "0" "$rc"
if [[ "$(printf '%s\n' "$out" | awk -F '\t' '{print $2}')" =~ ^[0-9]+$ ]]; then
  assert_eq "capital Try-again の reset epoch は数値 (Issue #170)" "true" "true"
else
  assert_eq "capital Try-again の reset epoch は数値 (Issue #170)" "true" "false"
fi

echo ""
echo "--- processing comment duplicate guard cases (Issue #4) ---"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
comments_file="$tmp_dir/comments.json"
count_file="$tmp_dir/comment-count"
printf '[]\n' > "$comments_file"
printf '0\n' > "$count_file"

cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "api" ]; then
  jq -r '.[].body' "$PI_TEST_COMMENTS_FILE"
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "comment" ]; then
  body=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --body)
        shift
        body="${1:-}"
        ;;
    esac
    shift || true
  done
  tmp="${PI_TEST_COMMENTS_FILE}.tmp"
  jq --arg body "$body" '. + [{"body": $body}]' "$PI_TEST_COMMENTS_FILE" > "$tmp"
  mv "$tmp" "$PI_TEST_COMMENTS_FILE"
  count=$(cat "$PI_TEST_COUNT_FILE")
  printf '%s\n' "$((count + 1))" > "$PI_TEST_COUNT_FILE"
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 99
STUB
chmod +x "$tmp_dir/gh"

export PATH="$tmp_dir:$PATH"
export PI_TEST_COMMENTS_FILE="$comments_file"
export PI_TEST_COUNT_FILE="$count_file"
REPO="owner/repo"
PR_ITERATION_GIT_TIMEOUT=5
PR_ITERATION_MAX_ROUNDS=3

pi_post_processing_comment 57 2 3
pi_post_processing_comment 57 2 3

assert_eq "同一 PR/round の processing コメントは 1 回だけ投稿される" \
  "1" \
  "$(cat "$count_file")"
assert_eq "保存されたコメントに round marker が含まれる" \
  "true" \
  "$(jq -r 'any(.[]; (.body // "") | contains("idd-codex:pr-iteration-processing round=2"))' "$comments_file")"

echo ""
echo "--- PR iteration model config error adapter cases (#175 task 4) ---"

model_error_log="$tmp_dir/model-error.log"
printf 'fatal: unsupported model gpt-5.4-old\n' > "$model_error_log"
printf '[]\n' > "$comments_file"
mp_clear_last_config_error
rc=0
pi_maybe_handle_model_config_error 57 impl 2 "gpt-5.4-old" 1 "$model_error_log" false false || rc=$?
assert_eq "model error adapter returns handled" "0" "$rc"
comment_body="$(jq -r '.[0].body // ""' "$comments_file")"
assert_eq "model error comment is posted" "1" "$(jq 'length' "$comments_file")"
assert_eq "model error comment includes setting-error wording" \
  "true" \
  "$(jq -r 'any(.[]; (.body // "") | contains("モデル設定エラーの可能性"))' "$comments_file")"
assert_eq "model error comment includes sanitized reason" \
  "true" \
  "$(printf '%s' "$comment_body" | grep -Fq 'unsupported-model' && echo true || echo false)"
assert_eq "model error comment includes configured model" \
  "true" \
  "$(printf '%s' "$comment_body" | grep -Fq 'gpt-5.4-old' && echo true || echo false)"

printf '[]\n' > "$comments_file"
mp_clear_last_config_error
rc=0
pi_maybe_handle_model_config_error 57 impl 3 "gpt-5.6-luna" 78 "$model_error_log" false false || rc=$?
assert_eq "preflight rc 78 adapter returns handled" "0" "$rc"
assert_eq "preflight rc 78 posts setting-error comment" \
  "true" \
  "$(jq -r 'any(.[]; (.body // "") | contains("model-preflight-failed"))' "$comments_file")"

printf '[]\n' > "$comments_file"
mp_clear_last_config_error
rc=0
pi_maybe_handle_model_config_error 57 impl 4 "gpt-5.4-old" 1 "$model_error_log" true false >/dev/null || rc=$?
assert_eq "usage-limit observed skips model config comment" "1" "$rc"
assert_eq "usage-limit priority leaves no model comment" "0" "$(jq 'length' "$comments_file")"

printf '[]\n' > "$comments_file"
mp_clear_last_config_error
rc=0
pi_maybe_handle_model_config_error 57 impl 5 "gpt-5.4-old" 1 "$model_error_log" false true >/dev/null || rc=$?
assert_eq "529 observed skips model config comment" "1" "$rc"
assert_eq "529 priority leaves no model comment" "0" "$(jq 'length' "$comments_file")"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
