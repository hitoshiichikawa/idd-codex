#!/usr/bin/env bash
#
# 本テストの fake 依存（gh）は eval で読み込んだ stage_a_verify_round1_defer から
# 間接的にのみ呼ばれるため unreachable 扱いになり、env var（NUMBER / REPO / LOG /
# LABEL_PICKED / LABEL_CLAIMED）も eval 済み関数内でのみ参照されるため unused 扱いに
# なる。いずれも false positive のためファイル全体で抑止する（既存
# stage_c_existing_pr_guard_test.sh / parse_review_result_test.sh と同じ扱い）。
# shellcheck disable=SC2317,SC2034
#
# 用途: local-watcher/bin/idd-codex-issue-watcher.sh の stage_a_verify_round1_defer
#       (Issue #219) を fake gh で検証するスモークテスト。
#
#       背景: stage-a-verify round=1 差し戻し経路が `codex-picked-up` を除去せず
#       return していたため、dispatcher の候補クエリ（`-label:"codex-picked-up"`）
#       から除外され当該 Issue が二度と再 pickup されず stuck になっていた。本関数は
#       per-task hold (#198) と同様に codex-picked-up / codex-claimed を除去して
#       bare codex-auto-dev candidate へ復帰させる。
#
#       検証観点:
#         - gh issue edit が codex-picked-up / codex-claimed の両方を --remove-label
#           で呼ぶ（再 pickup 可能化）
#         - gh 成功時 return 0 / $LOG に「除去 → bare codex-auto-dev candidate へ復帰」ログ
#         - gh 失敗時 return 1（fail-open） / $LOG に WARN ログ（ラベル残置の旨）
#
# 配置先: local-watcher/test/stage_a_verify_round1_defer_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/stage_a_verify_round1_defer_test.sh
# 前提:   idd-codex-issue-watcher.sh から stage_a_verify_round1_defer 定義のみを awk で抽出し
#         eval で current shell に読み込む（トップレベル副作用を回避）。gh はテスト側
#         で fake を定義し、呼び出し引数を記録する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

# idd-codex-issue-watcher.sh から該当関数 1 個だけを抽出する（インデント無しの単独 `}` まで）。
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
eval "$(extract_function "$WATCHER_SH" "stage_a_verify_round1_defer")"

if ! declare -F stage_a_verify_round1_defer >/dev/null; then
  echo "ERROR: stage_a_verify_round1_defer not loaded" >&2
  exit 2
fi

# ── 共有 env / fake ──────────────────────────────────────────────────────────
NUMBER=219
REPO="owner/repo"
LABEL_PICKED="codex-picked-up"
LABEL_CLAIMED="codex-claimed"

PASS=0
FAIL=0

# fake gh: 呼び出し引数を $GH_ARGS_FILE に追記し、$GH_RC を返す。
GH_RC=0
gh() {
  printf '%s\n' "$*" >> "$GH_ARGS_FILE"
  return "$GH_RC"
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

# ── ケース 1: gh 成功 → return 0 / 両ラベル除去 / 復帰ログ ────────────────────
echo "[case1] gh 成功: codex-picked-up + codex-claimed を除去し return 0"
GH_ARGS_FILE="$(mktemp)"
LOG="$(mktemp)"
GH_RC=0
rc=0
stage_a_verify_round1_defer || rc=$?
gh_args="$(cat "$GH_ARGS_FILE")"
log_body="$(cat "$LOG")"
assert_eq "$rc" "0" "gh 成功時の戻り値は 0"
assert_contains "$gh_args" "issue edit 219" "gh issue edit が対象 Issue #219 で呼ばれる"
assert_contains "$gh_args" "--remove-label codex-picked-up" "codex-picked-up を除去する"
assert_contains "$gh_args" "--remove-label codex-claimed" "codex-claimed を除去する"
assert_contains "$log_body" "bare codex-auto-dev candidate へ復帰" "復帰ログが出力される"
rm -f "$GH_ARGS_FILE" "$LOG"

# ── ケース 2: gh 失敗 → return 1（fail-open） / WARN ログ ─────────────────────
echo "[case2] gh 失敗: fail-open で return 1 / WARN ログ（ラベル残置）"
GH_ARGS_FILE="$(mktemp)"
LOG="$(mktemp)"
GH_RC=1
rc=0
stage_a_verify_round1_defer || rc=$?
log_body="$(cat "$LOG")"
assert_eq "$rc" "1" "gh 失敗時の戻り値は 1（fail-open）"
assert_contains "$log_body" "WARN" "WARN ログが出力される"
assert_contains "$log_body" "手動除去で復旧可能" "手動復旧の案内ログが出力される"
rm -f "$GH_ARGS_FILE" "$LOG"

# ── 結果 ─────────────────────────────────────────────────────────────────────
echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo "RESULT: FAIL" >&2
  exit 1
fi
echo "RESULT: PASS"
