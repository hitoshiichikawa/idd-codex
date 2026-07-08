#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-modules/pr-reviewer.sh の `pr_already_processed`
#       関数が PR コメントを全ページ走査し、marker 総数に依らない (sha, kind)
#       単位の重複判定を返すことを検証する単体スモークテスト（Issue #141、
#       idd-claude #420 移植）。
#
# 背景:
#   pr_already_processed は `gh api /repos/.../issues/<n>/comments`（デフォルト
#   per_page=30・非ページネート）でコメントを取得していたため、コメントが 30 件を
#   超え marker が 1 ページ目に無い PR では常に「未存在」と誤判定し、
#   exec-fail-escalated advisory 等が毎サイクル再投稿されていた。本テストは
#   `--paginate --slurp` + `per_page=100` + jq `(add // []) | any(...)` への修正が
#   30 件以下 / 31 件以上（複数ページ） / gh API 失敗 の各経路で正しく動作することを
#   検証する。
#
# 対象関数:
#   - pr_already_processed: hidden marker `<!-- idd-codex:pr-reviewer sha=<sha>
#     kind=<kind> tool=<tool> -->` の存在を全コメントから検出する重複判定
#
# 既存テストと同じイディオム（pr_reviewer_exec_fail_streak_test.sh 参照）:
#   extract_function で対象関数を awk 抽出して eval。依存（gh / timeout / pr_warn）
#   は stub 化し、gh stub に「ページ数」と「marker を埋め込むコメント」を仕込んで
#   `--paginate --slurp` 経路の挙動を再現する。
#
# 配置先: local-watcher/test/pr_already_processed_pagination_test.sh
# 依存:   bash 4+, awk, grep, jq, mktemp
# 実行:   bash local-watcher/test/pr_already_processed_pagination_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_MOD="$SCRIPT_DIR/../bin/idd-codex-modules/pr-reviewer.sh"

if [ ! -f "$PR_MOD" ]; then
  echo "ERROR: cannot find pr-reviewer.sh at $PR_MOD" >&2
  exit 2
fi

# extract_function イディオム（pr_reviewer_exec_fail_streak_test.sh と同一）
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

for fn in pr_already_processed pr_build_marker; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$PR_MOD" "$fn")"
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# グローバル env（遅延束縛で抽出関数本体から参照される）
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
PR_REVIEWER_GIT_TIMEOUT="120"

PASS_COUNT=0
FAIL_COUNT=0

assert_rc() {
  local label="$1"; local expected_rc="$2"; shift 2
  local actual_rc=0
  "$@" >/dev/null 2>&1 || actual_rc=$?
  if [ "$expected_rc" = "$actual_rc" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected rc: $expected_rc"
    echo "  actual rc  : $actual_rc"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_eq() {
  local label="$1"; local expected="$2"; local actual="$3"
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

# ── 共通 stub ─────────────────────────────────────────────────────────────────
# timeout: 第 1 引数（秒数）を捨てて残りを実行する素通し stub
# shellcheck disable=SC2317
timeout() {
  shift
  "$@"
}

# 観測ログ用 stub（pr_warn は WARN_LOG に行追加）
WARN_LOG=""
GH_CALL_LOG=""
reset_stub_state() {
  WARN_LOG="$(mktemp)"
  GH_CALL_LOG="$(mktemp)"
}
cleanup_stub_state() {
  rm -f "$WARN_LOG" "$GH_CALL_LOG" 2>/dev/null || true
}
# shellcheck disable=SC2317
pr_warn() { echo "$*" >>"$WARN_LOG"; }
# shellcheck disable=SC2317
pr_log()  { :; }

# ── gh stub のページネーション再現 ───────────────────────────────────────────
# GH_PAGE_FILES: 各ページの JSON 配列ファイルパス（space 区切り、page1〜N の順）
# GH_FAIL_ON_PAGE: そのページの取得を失敗扱いにする 1-based index（0 = 失敗なし）
# GH_PAGINATE_RC: 全体としての終了コード（route 用、既定 0）
# 本実装は `gh api --paginate --slurp <path>` 呼び出しを前提として、ページ群を
# `[[page1...], [page2...], ...]` 形式の outer 配列として stdout へ出力する。
# 途中ページ失敗の場合は GH_FAIL_ON_PAGE 以降を切り捨て、rc=1 を返す（実 gh の
# --paginate が途中失敗で rc≠0 を返す挙動を模倣）。
GH_PAGE_FILES=""
GH_FAIL_ON_PAGE="0"
GH_PAGINATE_RC="0"

# shellcheck disable=SC2317
gh() {
  echo "gh $*" >>"$GH_CALL_LOG"
  # 引数列に --paginate / --slurp が含まれているかを検証
  local has_paginate="false"
  local has_slurp="false"
  local arg
  for arg in "$@"; do
    case "$arg" in
      --paginate) has_paginate="true" ;;
      --slurp)    has_slurp="true" ;;
    esac
  done
  if [ "$has_paginate" != "true" ] || [ "$has_slurp" != "true" ]; then
    # 期待していない呼び出し（--paginate --slurp なし）。テスト失敗を顕在化させる
    # ため exit 2 を返す（gh 本体の failure と同等の安全側 fallback で吸収される）。
    echo "gh stub: missing --paginate or --slurp" >&2
    return 2
  fi

  # outer 配列を組み立て: 各 page file を読み込んで `[` `,` `]` でラップする
  local pages_count=0
  local p
  for p in $GH_PAGE_FILES; do
    pages_count=$((pages_count + 1))
  done

  if [ "$pages_count" -eq 0 ]; then
    # 0 ページ（GH_PAGE_FILES 未設定）= 空のコメント配列 1 ページ
    printf '[[]]'
    return "$GH_PAGINATE_RC"
  fi

  printf '['
  local idx=0
  for p in $GH_PAGE_FILES; do
    idx=$((idx + 1))
    if [ "$GH_FAIL_ON_PAGE" -gt 0 ] && [ "$idx" -ge "$GH_FAIL_ON_PAGE" ]; then
      # このページから失敗 → outer 配列を閉じずに rc=1 で abort（gh --paginate 模倣）。
      # それまでに取得済みのページは stdout に残るが、呼び出し元の `if !` 分岐で
      # fallback 経路（rc=0 既存扱い）に倒れることを検証する。
      printf '\n'
      return 1
    fi
    if [ "$idx" -gt 1 ]; then
      printf ','
    fi
    cat "$p"
  done
  printf ']'
  return "$GH_PAGINATE_RC"
}

# ── ヘルパ: marker 付き / 無し のコメント JSON 配列ファイルを作る ─────────────
# make_page <out_file> <count> <marker_sha?> <marker_kind?>
#   out_file: 書き出し先 path
#   count:    そのページに含める comment 個数（>= 1）
#   marker_sha / marker_kind: 任意。指定するとそのページの末尾コメント本文に
#     `<!-- idd-codex:pr-reviewer sha=<sha> kind=<kind> tool=codex -->` を埋め込む。
make_page() {
  local out_file="$1"
  local count="$2"
  local marker_sha="${3:-}"
  local marker_kind="${4:-}"
  local i
  printf '[' >"$out_file"
  for i in $(seq 1 "$count"); do
    if [ "$i" -gt 1 ]; then printf ',' >>"$out_file"; fi
    if [ "$i" -eq "$count" ] && [ -n "$marker_sha" ] && [ -n "$marker_kind" ]; then
      # 末尾に marker 付きコメント
      printf '{"body":"<!-- idd-codex:pr-reviewer sha=%s kind=%s tool=codex -->"}' \
        "$marker_sha" "$marker_kind" >>"$out_file"
    else
      # marker 無しのダミー
      printf '{"body":"comment-%d"}' "$i" >>"$out_file"
    fi
  done
  printf ']' >>"$out_file"
}

VALID_SHA="abcdef0123456789abcdef0123456789abcdef01"
VALID_PR="123"

# ============================================================
# Section 1: 単ページ（コメント 30 件以下 / 後方互換）
# ============================================================
echo "--- Section 1: 単ページ 30 件以下 ---"

# Case 1.A: 30 件で marker が末尾に存在 → rc=0（既存）
reset_stub_state
PAGE1=$(mktemp)
make_page "$PAGE1" 30 "$VALID_SHA" "exec-fail-escalated"
GH_PAGE_FILES="$PAGE1"
GH_FAIL_ON_PAGE="0"
GH_PAGINATE_RC="0"
assert_rc "30 件 / marker 末尾 → rc=0（既存）" 0 \
  pr_already_processed "$VALID_PR" "$VALID_SHA" "exec-fail-escalated"
# 30 件以下では gh api 呼び出しは 1 回のみ
gh_count=$(grep -cE "^gh api " "$GH_CALL_LOG" || true)
assert_eq "30 件以下では gh api 呼び出しは 1 回のみ" "1" "$gh_count"
rm -f "$PAGE1"
cleanup_stub_state

# Case 1.B: 30 件で marker 無し → rc=1（未存在）
reset_stub_state
PAGE1=$(mktemp)
make_page "$PAGE1" 30
GH_PAGE_FILES="$PAGE1"
GH_FAIL_ON_PAGE="0"
GH_PAGINATE_RC="0"
assert_rc "30 件 / marker 無し → rc=1（未存在）" 1 \
  pr_already_processed "$VALID_PR" "$VALID_SHA" "exec-fail-escalated"
rm -f "$PAGE1"
cleanup_stub_state

# Case 1.C: 0 件のコメント → rc=1（未存在 / 空入力の境界値）
reset_stub_state
GH_PAGE_FILES=""
GH_FAIL_ON_PAGE="0"
GH_PAGINATE_RC="0"
assert_rc "コメント 0 件 → rc=1（未存在）" 1 \
  pr_already_processed "$VALID_PR" "$VALID_SHA" "exec-fail-escalated"
cleanup_stub_state

# ============================================================
# Section 2: 複数ページ（31 件以上 / 本 Issue のリグレッション境界）
# ============================================================
echo ""
echo "--- Section 2: 複数ページ 31 件以上 ---"

# Case 2.A: 2 ページ（100+5=105 件）で marker が最終ページにある → rc=0
# `per_page=100` を前提に、page1=100 件すべて marker 無し / page2=5 件で末尾に marker。
# これは「30 件超 / marker が page2 以降」の核心ケース（本 Issue の再現条件）。
reset_stub_state
PAGE1=$(mktemp); PAGE2=$(mktemp)
make_page "$PAGE1" 100
make_page "$PAGE2" 5 "$VALID_SHA" "exec-fail-escalated"
GH_PAGE_FILES="$PAGE1 $PAGE2"
GH_FAIL_ON_PAGE="0"
GH_PAGINATE_RC="0"
assert_rc "31 件以上 (105) / marker が最終ページ末尾 → rc=0（既存）" 0 \
  pr_already_processed "$VALID_PR" "$VALID_SHA" "exec-fail-escalated"
rm -f "$PAGE1" "$PAGE2"
cleanup_stub_state

# Case 2.B: 2 ページ（合計 105 件）で marker が **どこにも無い** → rc=1（未存在）
reset_stub_state
PAGE1=$(mktemp); PAGE2=$(mktemp)
make_page "$PAGE1" 100
make_page "$PAGE2" 5
GH_PAGE_FILES="$PAGE1 $PAGE2"
GH_FAIL_ON_PAGE="0"
GH_PAGINATE_RC="0"
assert_rc "31 件以上 (105) / marker が全ページに無い → rc=1（未存在）" 1 \
  pr_already_processed "$VALID_PR" "$VALID_SHA" "exec-fail-escalated"
rm -f "$PAGE1" "$PAGE2"
cleanup_stub_state

# Case 2.C: 3 ページ（合計 205 件）で marker が page2 中段 → rc=0（複数ページ走査の確認）
reset_stub_state
PAGE1=$(mktemp); PAGE2=$(mktemp); PAGE3=$(mktemp)
make_page "$PAGE1" 100
make_page "$PAGE2" 100 "$VALID_SHA" "review"
make_page "$PAGE3" 5
GH_PAGE_FILES="$PAGE1 $PAGE2 $PAGE3"
GH_FAIL_ON_PAGE="0"
GH_PAGINATE_RC="0"
assert_rc "3 ページ走査で page2 の marker (kind=review) を検出 → rc=0" 0 \
  pr_already_processed "$VALID_PR" "$VALID_SHA" "review"
rm -f "$PAGE1" "$PAGE2" "$PAGE3"
cleanup_stub_state

# Case 2.D: (sha, kind) 単位判定 — sha 一致 / kind 不一致は「未存在」(rc=1)
reset_stub_state
PAGE1=$(mktemp); PAGE2=$(mktemp)
make_page "$PAGE1" 100
make_page "$PAGE2" 1 "$VALID_SHA" "review"
GH_PAGE_FILES="$PAGE1 $PAGE2"
GH_FAIL_ON_PAGE="0"
GH_PAGINATE_RC="0"
# 同一 sha で kind=exec-fail-escalated を探す → review marker は対象外 → rc=1
assert_rc "sha 一致 / kind 不一致 → rc=1（(sha,kind) 単位判定）" 1 \
  pr_already_processed "$VALID_PR" "$VALID_SHA" "exec-fail-escalated"
rm -f "$PAGE1" "$PAGE2"
cleanup_stub_state

# Case 2.E: ちょうど 31 件（境界値）で marker が 31 件目（2 ページ目相当の位置）
reset_stub_state
PAGE1=$(mktemp); PAGE2=$(mktemp)
make_page "$PAGE1" 30
make_page "$PAGE2" 1 "$VALID_SHA" "exec-fail-escalated"
GH_PAGE_FILES="$PAGE1 $PAGE2"
GH_FAIL_ON_PAGE="0"
GH_PAGINATE_RC="0"
assert_rc "境界値 31 件目に marker → rc=0（既存）" 0 \
  pr_already_processed "$VALID_PR" "$VALID_SHA" "exec-fail-escalated"
rm -f "$PAGE1" "$PAGE2"
cleanup_stub_state

# ============================================================
# Section 3: gh API 失敗時の安全側フォールバック
# ============================================================
echo ""
echo "--- Section 3: 取得失敗時のフォールバック ---"

# Case 3.A: 初回ページから完全失敗 → rc=0（既存扱い）+ pr_warn 記録
reset_stub_state
GH_PAGE_FILES=""
GH_FAIL_ON_PAGE="0"
GH_PAGINATE_RC="1"   # gh stub は 0 ページでも RC=1 で完全失敗を再現
assert_rc "初回 gh API 失敗 → rc=0（安全側で既存扱い）" 0 \
  pr_already_processed "$VALID_PR" "$VALID_SHA" "exec-fail-escalated"
warn_count=$(grep -cE "コメント取得に失敗" "$WARN_LOG" || true)
assert_eq "失敗時 pr_warn が 1 行記録される" "1" "$warn_count"
cleanup_stub_state

# Case 3.B: 途中ページ失敗（page1 成功 / page2 失敗） → marker は page1 に無い場合でも
#           rc=0 既存扱い（安全側フォールバックの合流）
# stub 上は「2 ページ目を fetch しようとする」状態を作るため、GH_PAGE_FILES に
# ダミーの page2 entry を含め、GH_FAIL_ON_PAGE=2 で page2 のループ反復時に rc=1 で abort させる。
reset_stub_state
PAGE1=$(mktemp); PAGE2_FAIL=$(mktemp)
make_page "$PAGE1" 100             # marker 無し / 100 件
make_page "$PAGE2_FAIL" 1          # page2 entry（実際には reach されず破棄される）
GH_PAGE_FILES="$PAGE1 $PAGE2_FAIL"
GH_FAIL_ON_PAGE="2"                # page2 取得時に rc=1 で abort（gh --paginate 模倣）
GH_PAGINATE_RC="0"
assert_rc "途中ページ失敗 → rc=0（既存扱い、再投稿抑止）" 0 \
  pr_already_processed "$VALID_PR" "$VALID_SHA" "exec-fail-escalated"
warn_count=$(grep -cE "コメント取得に失敗" "$WARN_LOG" || true)
assert_eq "途中ページ失敗でも pr_warn を 1 行記録" "1" "$warn_count"
rm -f "$PAGE1" "$PAGE2_FAIL"
cleanup_stub_state

# ============================================================
# Section 4: per_page=100 / --paginate / --slurp が呼び出されている
# ============================================================
echo ""
echo "--- Section 4: gh 呼び出し引数の検証 ---"

reset_stub_state
PAGE1=$(mktemp)
make_page "$PAGE1" 1
GH_PAGE_FILES="$PAGE1"
GH_FAIL_ON_PAGE="0"
GH_PAGINATE_RC="0"
pr_already_processed "$VALID_PR" "$VALID_SHA" "exec-fail-escalated" >/dev/null 2>&1 || true
call_line=$(cat "$GH_CALL_LOG")
case "$call_line" in
  *"--paginate"*"--slurp"*|*"--slurp"*"--paginate"*)
    echo "PASS: gh api 呼び出しに --paginate / --slurp 両方が含まれる"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
  *)
    echo "FAIL: gh api 呼び出しに --paginate / --slurp が含まれない"
    echo "  call_line: $call_line"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
esac
case "$call_line" in
  *"per_page=100"*)
    echo "PASS: gh api 呼び出しに per_page=100 が含まれる（30 件以下 PR の呼び出し回数を増やさない）"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
  *)
    echo "FAIL: gh api 呼び出しに per_page=100 が含まれない"
    echo "  call_line: $call_line"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
esac
case "$call_line" in
  *"/repos/owner/test-repo/issues/${VALID_PR}/comments"*)
    echo "PASS: issue comments エンドポイントを使用"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
  *)
    echo "FAIL: issue comments エンドポイントが含まれない"
    echo "  call_line: $call_line"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
esac
rm -f "$PAGE1"
cleanup_stub_state

# ============================================================
# Summary
# ============================================================
echo ""
echo "=================================================="
echo "RESULT: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
echo "=================================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
