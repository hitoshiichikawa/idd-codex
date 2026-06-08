#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-issue-watcher.sh の Stage Checkpoint Resume スラグ照合
#       ガード (`_stage_checkpoint_assert_slug_match`) を fixture で検証する
#       スモークテスト。Issue #114 で導入。
#
#       検証範囲:
#         - スラグ一致時に 0 を返し、ログ行 `stage-checkpoint: slug-match ...` を出す
#         - スラグ不一致時に 1 を返し、ログ行 `stage-checkpoint: slug-mismatch ...` を出す
#         - mismatch 時に `_slug_mismatch_escalate` を呼び出す（stub で観測）
#         - NUMBER 未設定 / spec dir が `<N>-` で始まらない異常系 → mismatch 扱い (NFR 2.1)
#
# 配置先: local-watcher/test/slug_match_guard_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/slug_match_guard_test.sh
# 前提:   idd-codex-issue-watcher.sh から関数定義を awk で切り出して eval で読み込み、
#         `gh` / `slot_log` / `_slug_mismatch_escalate` は test 内で stub する。

set -euo pipefail

# Note: 本テストは gh / slot_log / _slug_mismatch_escalate を関数定義で stub する。
# 静的解析では stub 関数の本体が "unreachable" に見えるが、実体は eval / export -f に
# より _stage_checkpoint_assert_slug_match から呼ばれるので SC2317 は意図的に抑止する
# （個別の関数定義先頭で disable する）。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
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

# ─── 依存関数のうち副作用を持つものを stub する ───
#
# `_stage_checkpoint_assert_slug_match` は内部で `_slug_mismatch_escalate` を呼び、
# `_slug_mismatch_escalate` は `gh issue edit/comment` + `slot_log` を呼ぶ。テスト時は
# escalation の "呼ばれた事実" と引数だけを観測したいので、`_slug_mismatch_escalate` を
# stub に差し替える（real 実装をロードしない）。

ESCALATE_CALL_LOG=""

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "_normalize_slug")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "_stage_checkpoint_assert_slug_match")"

# 既存スタブ: gh / slot_log / _slug_mismatch_escalate
# shellcheck disable=SC2317
gh() {
  # 呼び出されたら fail させたい（_stage_checkpoint_assert_slug_match は直接 gh を呼ばない）
  echo "UNEXPECTED gh call: $*" >&2
  return 1
}
export -f gh

# shellcheck disable=SC2317
slot_log() {
  # silent
  :
}
export -f slot_log

# shellcheck disable=SC2317
_slug_mismatch_escalate() {
  ESCALATE_CALL_LOG="${ESCALATE_CALL_LOG}|kind=$1 expected=$2 found=$3 target=$4"
  return 0
}

if ! declare -F _stage_checkpoint_assert_slug_match >/dev/null; then
  echo "ERROR: _stage_checkpoint_assert_slug_match not loaded" >&2
  exit 2
fi

# ─── アサーションヘルパ ───
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

assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  case "$haystack" in
    *"$needle"*)
      echo "PASS: $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
    *)
      echo "FAIL: $label"
      echo "  needle  : $(printf '%q' "$needle")"
      echo "  haystack: $(printf '%q' "$haystack")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
  esac
}

# テストで LOG はファイル不要、stdout 取り込みで確認
TMP_LOG=$(mktemp -t slug-guard-test-XXXXXX.log)
export LOG="$TMP_LOG"
trap 'rm -f "$TMP_LOG"' EXIT

# ─── テストケース ───

echo "--- _stage_checkpoint_assert_slug_match cases (Issue #114 Req 1, 3, 4) ---"

# Case 1: 一致 → return 0, slug-match 行を出力, escalate 未呼び出し
NUMBER=114
ESCALATE_CALL_LOG=""
: > "$TMP_LOG"
rc=0
_stage_checkpoint_assert_slug_match "bug-watcher-slug-guard" "/tmp/wt/docs/specs/114-bug-watcher-slug-guard" >/dev/null || rc=$?
assert_eq "Req 1.3: match → return 0" "0" "$rc"
assert_contains "Req 4.1: match 時に stage-checkpoint: slug-match ログ出力" \
  "stage-checkpoint: slug-match issue=#114 expected=bug-watcher-slug-guard found=bug-watcher-slug-guard" \
  "$(cat "$TMP_LOG")"
assert_eq "Req 1.3: match 時に escalate 未呼び出し" "" "$ESCALATE_CALL_LOG"

# Case 2: 不一致 → return 1, slug-mismatch 行を出力, escalate 呼び出し
NUMBER=68
ESCALATE_CALL_LOG=""
: > "$TMP_LOG"
rc=0
_stage_checkpoint_assert_slug_match "feat-new-feature" "/tmp/wt/docs/specs/68-old-unrelated-feature" >/dev/null || rc=$?
assert_eq "Req 1.4: mismatch → return 1" "1" "$rc"
assert_contains "Req 4.2: mismatch 時に stage-checkpoint: slug-mismatch ログ出力（NFR 3.2: 3 値含む）" \
  "stage-checkpoint: slug-mismatch issue=#68 expected=feat-new-feature found=old-unrelated-feature" \
  "$(cat "$TMP_LOG")"
assert_contains "Req 3.1, 3.2: mismatch 時に escalate 呼び出し（kind=spec-dir）" \
  "kind=spec-dir expected=feat-new-feature found=old-unrelated-feature target=/tmp/wt/docs/specs/68-old-unrelated-feature" \
  "$ESCALATE_CALL_LOG"

# Case 3: NUMBER 未設定 → NFR 2.1 の安全側挙動で mismatch 扱い
unset NUMBER
ESCALATE_CALL_LOG=""
: > "$TMP_LOG"
rc=0
_stage_checkpoint_assert_slug_match "any-slug" "/tmp/wt/docs/specs/99-any-slug" >/dev/null || rc=$?
assert_eq "NFR 2.1: NUMBER 未設定 → mismatch 扱い（return 1）" "1" "$rc"
assert_contains "NFR 2.1: NUMBER 未設定でも slug-mismatch ログ出力" \
  "stage-checkpoint: slug-mismatch" \
  "$(cat "$TMP_LOG")"

# Case 4: basename が `<N>-` で始まらない異常系 → mismatch 扱い
NUMBER=114
ESCALATE_CALL_LOG=""
: > "$TMP_LOG"
rc=0
_stage_checkpoint_assert_slug_match "bug-watcher-slug-guard" "/tmp/wt/docs/specs/999-broken-prefix" >/dev/null || rc=$?
assert_eq "NFR 2.1: <N>- 接頭辞欠落時 → mismatch (return 1)" "1" "$rc"
assert_contains "NFR 2.1: <N>- 接頭辞欠落時に slug-mismatch ログ出力" \
  "stage-checkpoint: slug-mismatch issue=#114 expected=bug-watcher-slug-guard found=" \
  "$(cat "$TMP_LOG")"

# Case 5: 数字接頭辞の prefix が部分一致のみ（例: 1- と 11-）→ basename が "1-foo" で
# NUMBER=11 の場合、prefix を剥がせないため found="" 扱い → mismatch
NUMBER=11
ESCALATE_CALL_LOG=""
: > "$TMP_LOG"
rc=0
_stage_checkpoint_assert_slug_match "anything" "/tmp/wt/docs/specs/1-foo" >/dev/null || rc=$?
assert_eq "Req 1.2: 番号部分一致は不一致として扱う" "1" "$rc"

# Case 6: spec dir 名に `<N>-` が複数回現れる（例: 11-11-foo）→ 接頭辞 1 回だけ剥がす
# basename="11-11-foo", NUMBER=11 → "${base#${NUMBER}-}" は "11-foo"。expected と
# "11-foo" を比較する。
# shellcheck disable=SC2034
NUMBER=11
export NUMBER  # _stage_checkpoint_assert_slug_match から参照させる
ESCALATE_CALL_LOG=""
: > "$TMP_LOG"
rc=0
_stage_checkpoint_assert_slug_match "11-foo" "/tmp/wt/docs/specs/11-11-foo" >/dev/null || rc=$?
assert_eq "Req 1.2: <N>- prefix を 1 回だけ剥がす（部分一致を許さない）" "0" "$rc"
assert_contains "Req 4.1: 部分一致シナリオで slug-match を出す" \
  "stage-checkpoint: slug-match issue=#11 expected=11-foo found=11-foo" \
  "$(cat "$TMP_LOG")"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
