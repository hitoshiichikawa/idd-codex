#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-issue-watcher.sh の Issue #122（PR_ITERATION_MAX_ROUNDS の
#       kind 別分離 + no-progress ループ検知）で追加した関数群を fixture で検証する
#       スモークテスト。
#
#       対象関数:
#         - pi_resolve_max_rounds (Issue #122 Req 1.1〜1.4)
#         - pi_read_no_progress_streak (Req 3.6 / 4.2 / 4.4 / 4.5)
#
#       本テストは、idd-codex-issue-watcher.sh の冒頭での env 解決処理（特に
#       PR_ITERATION_MAX_ROUNDS_LEGACY_SET の検知）を再現するため、各テストケースで
#       env を unset / set し直してから対象関数を呼び出します。
#
# 配置先: local-watcher/test/pi_max_rounds_kind_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/pi_max_rounds_kind_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
# #181 Part 3 で PR Iteration Processor の関数群（pi_resolve_max_rounds /
# pi_read_no_progress_streak ほか）は modules/pr-iteration.sh へ切り出された。
# 抽出元を本体から pr-iteration.sh へ repoint する。
PR_ITERATION_SH="$SCRIPT_DIR/../bin/modules/pr-iteration.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi
if [ ! -f "$PR_ITERATION_SH" ]; then
  echo "ERROR: cannot find pr-iteration.sh at $PR_ITERATION_SH" >&2
  exit 2
fi

# 既存テストと同じイディオム: 対象スクリプトから 1 関数だけを awk で切り出して
# eval で読み込む。トップレベル副作用は回避する。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# pi_warn / pi_log / pi_error は本テストで stderr に出すだけで良い（実装では env
# 依存だが、ここでは副作用の確認は不要）。stub を定義しておく。
pi_warn()  { echo "WARN: $*" >&2; }
pi_log()   { echo "LOG: $*" >&2; }
pi_error() { echo "ERR: $*" >&2; }

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_SH" "pi_resolve_max_rounds")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_SH" "pi_read_no_progress_streak")"

if ! declare -F pi_resolve_max_rounds >/dev/null; then
  echo "ERROR: pi_resolve_max_rounds not loaded" >&2
  exit 2
fi
if ! declare -F pi_read_no_progress_streak >/dev/null; then
  echo "ERROR: pi_read_no_progress_streak not loaded" >&2
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

# ─── pi_resolve_max_rounds (Issue #122 Req 1) ───

echo "--- pi_resolve_max_rounds cases (Issue #122 Req 1.1〜1.4) ---"

# Req 1.1: kind 固有 env (IMPL) が設定されている場合、その値を採用
PR_ITERATION_MAX_ROUNDS_IMPL=5
PR_ITERATION_MAX_ROUNDS_DESIGN=""
PR_ITERATION_MAX_ROUNDS=3
PR_ITERATION_MAX_ROUNDS_LEGACY_SET="true"
assert_eq "Req 1.1: PR_ITERATION_MAX_ROUNDS_IMPL=5 → impl は 5 を返す" \
  "5" \
  "$(pi_resolve_max_rounds impl)"

# Req 1.2: kind 固有 env (DESIGN) が設定されている場合、その値を採用
PR_ITERATION_MAX_ROUNDS_IMPL=""
PR_ITERATION_MAX_ROUNDS_DESIGN=10
PR_ITERATION_MAX_ROUNDS=3
PR_ITERATION_MAX_ROUNDS_LEGACY_SET="true"
assert_eq "Req 1.2: PR_ITERATION_MAX_ROUNDS_DESIGN=10 → design は 10 を返す" \
  "10" \
  "$(pi_resolve_max_rounds design)"

# Req 1.2: design 固有が `0` 明示なら 0 を返す（無制限 sentinel / Req 2.1）
PR_ITERATION_MAX_ROUNDS_IMPL=""
PR_ITERATION_MAX_ROUNDS_DESIGN=0
PR_ITERATION_MAX_ROUNDS=3
PR_ITERATION_MAX_ROUNDS_LEGACY_SET="true"
assert_eq "Req 1.2 + 2.1: PR_ITERATION_MAX_ROUNDS_DESIGN=0 → design は 0 を返す（無制限 sentinel）" \
  "0" \
  "$(pi_resolve_max_rounds design)"

# Req 1.3: kind 固有が未設定 + 旧 env が設定 → 旧 env の値を両 kind に適用
PR_ITERATION_MAX_ROUNDS_IMPL=""
PR_ITERATION_MAX_ROUNDS_DESIGN=""
PR_ITERATION_MAX_ROUNDS=7
PR_ITERATION_MAX_ROUNDS_LEGACY_SET="true"
assert_eq "Req 1.3: 旧 env=7 のみ設定 → impl は 7" \
  "7" \
  "$(pi_resolve_max_rounds impl)"
assert_eq "Req 1.3: 旧 env=7 のみ設定 → design も 7（design 固有 default 0 ではない）" \
  "7" \
  "$(pi_resolve_max_rounds design)"

# Req 1.4: 全 env 未設定 → impl=3, design=0
PR_ITERATION_MAX_ROUNDS_IMPL=""
PR_ITERATION_MAX_ROUNDS_DESIGN=""
PR_ITERATION_MAX_ROUNDS=3
PR_ITERATION_MAX_ROUNDS_LEGACY_SET="false"
assert_eq "Req 1.4: 全 env 未設定 → impl は default 3" \
  "3" \
  "$(pi_resolve_max_rounds impl)"
assert_eq "Req 1.4: 全 env 未設定 → design は default 0（無制限）" \
  "0" \
  "$(pi_resolve_max_rounds design)"

# Req 1.1 + 1.3: kind 固有と旧 env の両方が設定 → kind 固有が優先
PR_ITERATION_MAX_ROUNDS_IMPL=2
PR_ITERATION_MAX_ROUNDS_DESIGN=8
PR_ITERATION_MAX_ROUNDS=99
PR_ITERATION_MAX_ROUNDS_LEGACY_SET="true"
assert_eq "Req 1.1 優先: 旧 env=99, IMPL=2 → impl は 2" \
  "2" \
  "$(pi_resolve_max_rounds impl)"
assert_eq "Req 1.2 優先: 旧 env=99, DESIGN=8 → design は 8" \
  "8" \
  "$(pi_resolve_max_rounds design)"

# Req 2.3: impl 固有を 0 にして無制限化も可能
PR_ITERATION_MAX_ROUNDS_IMPL=0
PR_ITERATION_MAX_ROUNDS_DESIGN=""
PR_ITERATION_MAX_ROUNDS=3
PR_ITERATION_MAX_ROUNDS_LEGACY_SET="true"
assert_eq "Req 2.3: PR_ITERATION_MAX_ROUNDS_IMPL=0 → impl は 0（無制限）" \
  "0" \
  "$(pi_resolve_max_rounds impl)"

# 異常系: 未知の kind → 1 を返す
PR_ITERATION_MAX_ROUNDS_IMPL=""
PR_ITERATION_MAX_ROUNDS_DESIGN=""
PR_ITERATION_MAX_ROUNDS=3
PR_ITERATION_MAX_ROUNDS_LEGACY_SET="false"
rc=0
out=$(pi_resolve_max_rounds "unknown" 2>/dev/null) || rc=$?
assert_eq "未知の kind は rc=1（呼び出し元が安全側に倒せる）" "1" "$rc"

echo ""

# ─── pi_read_no_progress_streak (Issue #122 Req 3.6 / 4.2 / 4.4 / 4.5) ───

echo "--- pi_read_no_progress_streak cases (Issue #122 Req 3.6 / 4.2 / 4.4 / 4.5) ---"

# Req 4.4: 新しい marker（no-progress-streak キー無し）→ 0 を返す
old_body='PR description.

<!-- idd-codex:pr-iteration round=2 last-run=2026-05-20T10:00:00Z -->'
assert_eq "Req 4.4: 既存 marker（no-progress-streak 無し）は 0 として解釈" \
  "0" \
  "$(pi_read_no_progress_streak "$old_body")"

# Req 4.1 + 4.2: 新しい marker（no-progress-streak=2）→ 2 を返す
new_body='PR description.

<!-- idd-codex:pr-iteration round=3 last-run=2026-05-20T10:00:00Z no-progress-streak=2 -->'
assert_eq "Req 4.1 / 4.2: no-progress-streak=2 を含む marker → 2" \
  "2" \
  "$(pi_read_no_progress_streak "$new_body")"

# Req 4.5: 複数 marker → 末尾を採用
multi_body='Old marker stash:
<!-- idd-codex:pr-iteration round=1 last-run=2026-05-19T10:00:00Z no-progress-streak=1 -->

Latest:
<!-- idd-codex:pr-iteration round=5 last-run=2026-05-20T10:00:00Z no-progress-streak=4 -->'
assert_eq "Req 4.5: 複数 marker は末尾値（4）を採用" \
  "4" \
  "$(pi_read_no_progress_streak "$multi_body")"

# Req 4.2: marker 自体が無い PR body → 0
no_marker_body='PR description without any iteration marker.'
assert_eq "Req 4.2 / 4.4: marker 不在は 0 として解釈" \
  "0" \
  "$(pi_read_no_progress_streak "$no_marker_body")"

# 境界: 空 body → 0
assert_eq "境界: 空 body → 0" \
  "0" \
  "$(pi_read_no_progress_streak "")"

# Req 4.3 / 4.5: 旧 marker（streak 無し）+ 新 marker（streak 有り）混在 → 新の値を採用
mixed_body='Legacy marker:
<!-- idd-codex:pr-iteration round=2 last-run=2026-05-19T10:00:00Z -->

Then upgraded:
<!-- idd-codex:pr-iteration round=3 last-run=2026-05-20T10:00:00Z no-progress-streak=2 -->'
assert_eq "Req 4.5: 旧 + 新 marker 混在 → 末尾の新値 2 を採用" \
  "2" \
  "$(pi_read_no_progress_streak "$mixed_body")"

# Req 4.3: round=0 や streak=0 でも数値として読める
zero_body='<!-- idd-codex:pr-iteration round=0 last-run=2026-05-20T10:00:00Z no-progress-streak=0 -->'
assert_eq "Req 4.3: streak=0 を明示した marker → 0" \
  "0" \
  "$(pi_read_no_progress_streak "$zero_body")"

echo ""

# ─── pi_read_round_counter 後方互換性確認 ───
# round counter 読み出しが no-progress-streak 拡張で壊れていないことを確認

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_SH" "pi_read_round_counter")"

if ! declare -F pi_read_round_counter >/dev/null; then
  echo "ERROR: pi_read_round_counter not loaded" >&2
  exit 2
fi

# 拡張された marker から round を取り出す機能のため、関数を直接呼ばずに
# regex の互換性のみを確認（pi_read_round_counter は gh 呼び出しを伴うため
# fixture body から regex で抽出する）。

echo "--- pi_read_round_counter 拡張 marker 互換性 (Req 4.3 / 4.4) ---"

# 旧 marker からの round 抽出
old_marker='<!-- idd-codex:pr-iteration round=2 last-run=2026-05-20T10:00:00Z -->'
extracted=$(echo "$old_marker" | grep -oE 'idd-codex:pr-iteration round=[0-9]+' | grep -oE '[0-9]+$' | tail -1)
assert_eq "Req 4.3: 旧 marker から round=2 を抽出" "2" "$extracted"

# 新 marker からの round 抽出（no-progress-streak の存在で壊れないこと）
new_marker='<!-- idd-codex:pr-iteration round=5 last-run=2026-05-20T10:00:00Z no-progress-streak=2 -->'
extracted=$(echo "$new_marker" | grep -oE 'idd-codex:pr-iteration round=[0-9]+' | grep -oE '[0-9]+$' | tail -1)
assert_eq "Req 4.3 / 4.4: 新 marker（streak 付き）から round=5 を抽出" "5" "$extracted"

echo ""

# ─── pi_write_marker / pi_read_last_run の sed 互換性 (Req 4.3 / 4.4) ───
# pi_write_marker は gh コマンドが必要なので関数本体は呼ばない。代わりに sed regex の
# 振る舞いのみを fixture body で確認する。

echo "--- pi_write_marker 置換 regex の旧 marker 吸収性 (Req 4.4) ---"

# 旧 marker（streak 無し）を新 marker（streak=3）で置換できる
input='Body.
<!-- idd-codex:pr-iteration round=1 last-run=2026-05-19T10:00:00Z -->'
new_marker='<!-- idd-codex:pr-iteration round=2 last-run=2026-05-20T10:00:00Z no-progress-streak=3 -->'
output=$(echo "$input" | sed -E "s|<!-- idd-codex:pr-iteration round=[0-9]+ last-run=[^>]*-->|${new_marker}|g")
expected='Body.
<!-- idd-codex:pr-iteration round=2 last-run=2026-05-20T10:00:00Z no-progress-streak=3 -->'
assert_eq "Req 4.4: 旧 marker を新 marker で置換できる（同一 regex で吸収）" \
  "$expected" \
  "$output"

# 新 marker（streak 付き）も同じ regex で置換できる
input='Body.
<!-- idd-codex:pr-iteration round=2 last-run=2026-05-20T10:00:00Z no-progress-streak=2 -->'
new_marker='<!-- idd-codex:pr-iteration round=3 last-run=2026-05-20T11:00:00Z no-progress-streak=0 -->'
output=$(echo "$input" | sed -E "s|<!-- idd-codex:pr-iteration round=[0-9]+ last-run=[^>]*-->|${new_marker}|g")
expected='Body.
<!-- idd-codex:pr-iteration round=3 last-run=2026-05-20T11:00:00Z no-progress-streak=0 -->'
assert_eq "Req 4.4: 新 marker → 新 marker の更新も同 regex で動作" \
  "$expected" \
  "$output"

# 既存 pi_read_last_run の regex は streak 付き marker でも last-run 値のみ拾う
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_SH" "pi_read_last_run")"

if ! declare -F pi_read_last_run >/dev/null; then
  echo "ERROR: pi_read_last_run not loaded" >&2
  exit 2
fi

streak_body='<!-- idd-codex:pr-iteration round=3 last-run=2026-05-20T10:00:00Z no-progress-streak=2 -->'
assert_eq "Req 4.3: streak 付き marker からも last-run を正しく抽出" \
  "2026-05-20T10:00:00Z" \
  "$(pi_read_last_run "$streak_body")"

old_marker_body='<!-- idd-codex:pr-iteration round=1 last-run=2026-05-19T10:00:00Z -->'
assert_eq "Req 4.3: 旧 marker からも従来通り last-run を抽出" \
  "2026-05-19T10:00:00Z" \
  "$(pi_read_last_run "$old_marker_body")"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
