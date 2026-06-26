#!/usr/bin/env bash
#
# 用途: PR Reviewer Adjudicator (#404) で追加した label / status publish 反映と
#       Reviewer 先行優先関数群の挙動を、PATH 経由ではなく shell 関数 stub の gh / git で
#       検証するスモークテスト。
#
#       対象関数:
#         - adj_apply_label_decision    (codex-needs-iteration add/remove 冪等)
#         - adj_read_reviewer_verdict   (head_ref / review-notes.md から RESULT 抽出)
#         - adj_apply_status_decision   (Reviewer 先行優先 + claude-review publish)
#         - adj_post_decision_comment   (hidden marker 投稿 + 重複防止)
#
#       検証する受入基準（docs/specs/404-feat-pr-reviewer-codex-advisory-claude-a/requirements.md）:
#         - Req 2.1 legitimate ≥1 で codex-needs-iteration 付与/維持
#         - Req 2.2 legitimate ゼロで codex-needs-iteration 解消
#         - Req 2.3 codex 失敗（findings 空 = legitimate ゼロ）で codex-needs-iteration 解消
#         - Req 3.2 adjudicator が claude-review を publish
#         - Req 3.3 legitimate ゼロ + Reviewer reject 不在 → success
#         - Req 3.4 legitimate ≥1 → failure
#         - Req 3.5 Reviewer reject 検出 → failure（legitimate ゼロでも上書き / 先行優先）
#         - Req 4.1 PR コメントとして観測可能（hidden marker 付き）
#         - Req 4.3 / NFR 1.2 marker prefix `pr-adjudicator` が pi self-filter `pr-iteration` と非衝突
#
# 配置先: local-watcher/test/adj_publish_decision_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/adj_publish_decision_test.sh

set -euo pipefail

# 抽出関数経由で参照される変数（stub state / env）が shellcheck から未使用に見える対策。
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADJ_SH="$SCRIPT_DIR/../bin/idd-codex-modules/adjudicator.sh"
PR_MOD="$SCRIPT_DIR/../bin/idd-codex-modules/pr-reviewer.sh"

if [ ! -f "$ADJ_SH" ]; then
  echo "ERROR: cannot find adjudicator.sh at $ADJ_SH" >&2
  exit 2
fi
if [ ! -f "$PR_MOD" ]; then
  echo "ERROR: cannot find pr-reviewer.sh at $PR_MOD" >&2
  exit 2
fi

# 既存テストと同じイディオム: 対象スクリプトから 1 関数だけを awk で切り出して eval。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# adjudicator.sh から 4 関数を抽出（adj_apply_status_decision は pr_publish_claude_status を
# 呼ぶため、pr_publish_claude_status / pr_publish_commit_status / pr_status_check_enabled も
# pr-reviewer.sh から抽出して同一プロセスに読み込む）。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$ADJ_SH" "adj_apply_label_decision")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$ADJ_SH" "adj_read_reviewer_verdict")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$ADJ_SH" "adj_apply_status_decision")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$ADJ_SH" "adj_post_decision_comment")"
# pr-reviewer.sh から status publish 関連の流用先を抽出
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_MOD" "pr_status_check_enabled")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_MOD" "pr_publish_commit_status")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_MOD" "pr_publish_claude_status")"

for fn in adj_apply_label_decision adj_read_reviewer_verdict adj_apply_status_decision \
          adj_post_decision_comment \
          pr_status_check_enabled pr_publish_commit_status pr_publish_claude_status; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# グローバル env（遅延束縛で抽出関数本体から参照される）。
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
PR_REVIEWER_GIT_TIMEOUT="120"
# shellcheck disable=SC2034
LABEL_NEEDS_ITERATION="codex-needs-iteration"

# pr_publish_commit_status は idd_secure_mktemp を使うため stub する（err-file 用 tempfile）。
# shellcheck disable=SC2317
idd_secure_mktemp() {
  mktemp "/tmp/adj-pub-test.${1:-x}.XXXXXX" 2>/dev/null || mktemp
}

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
  local haystack="$2"
  local needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "PASS: $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
    *)
      echo "FAIL: $label"
      echo "  expected to contain: $(printf '%q' "$needle")"
      echo "  actual             : $(printf '%q' "$haystack")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
  esac
}

assert_not_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "FAIL: $label"
      echo "  expected NOT to contain: $(printf '%q' "$needle")"
      echo "  actual                 : $(printf '%q' "$haystack")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
    *)
      echo "PASS: $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
  esac
}

# ── stub state ──
# 各種コール記録ファイル / fixture 制御変数を初期化
reset_stub_state() {
  GH_CALL_LOG="$(mktemp)"
  GIT_CALL_LOG="$(mktemp)"
  LOG_LOG="$(mktemp)"
  WARN_LOG="$(mktemp)"
  GH_NEXT_RC="${GH_NEXT_RC:-0}"
  # shellcheck disable=SC2034 # pr_publish_commit_status 抽出関数経由で参照される
  PR_STATUS_GATE_SUPPRESS_LOGGED=0

  # gh stub 制御
  # GH_API_BODY: gh api /repos/.../comments の stdout（jq でテスト）
  # GH_API_RC:   gh api の戻り値
  GH_API_BODY="[]"
  GH_API_RC=0

  # git stub 制御
  GIT_TREE_OUT=""
  GIT_LSTREE_RC=0
  GIT_CATFILE_RC=0
  GIT_SHOW_OUT=""
  GIT_SHOW_RC=0
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$GIT_CALL_LOG" "$LOG_LOG" "$WARN_LOG" 2>/dev/null || true
}

# adj_log / adj_warn stub: 観測用 file に追記
# shellcheck disable=SC2317
adj_log()   { echo "$*" >>"$LOG_LOG"; }
# shellcheck disable=SC2317
adj_warn()  { echo "$*" >>"$WARN_LOG"; }
# pr_log / pr_warn は pr_publish_claude_status / pr_publish_commit_status 流用経路で
# 呼ばれる（同一プロセスに読み込んだため）。観測用 file に追記する。
# shellcheck disable=SC2317
pr_log()    { echo "$*" >>"$LOG_LOG"; }
# shellcheck disable=SC2317
pr_warn()   { echo "$*" >>"$WARN_LOG"; }

# timeout stub: 最初の引数（秒数）を捨てて残りを実行
# shellcheck disable=SC2317
timeout() {
  shift
  "$@"
}

# gh stub: 呼び出し痕跡を記録し、シナリオ別に挙動を切り替える
# shellcheck disable=SC2317
gh() {
  echo "gh $*" >>"$GH_CALL_LOG"
  case "${1:-}" in
    api)
      # 第 2 引数以降にパスや POST メソッド指定
      # /repos/.../comments の GET 経路: stdout に GH_API_BODY を流す
      # POST repos/.../statuses/<sha> の経路: status publish。stdout は空でよい
      local arg
      for arg in "$@"; do
        case "$arg" in
          *"/issues/"*"/comments"*) printf '%s' "$GH_API_BODY"; return "$GH_API_RC" ;;
        esac
      done
      return "${GH_NEXT_RC:-0}"
      ;;
    pr)
      # pr comment / pr edit
      return "${GH_NEXT_RC:-0}"
      ;;
    *)
      return "${GH_NEXT_RC:-0}"
      ;;
  esac
}

# git stub: ls-tree / cat-file -e / show を fixture から制御
# shellcheck disable=SC2317
git() {
  echo "git $*" >>"$GIT_CALL_LOG"
  case "${1:-}" in
    ls-tree)
      printf '%s' "$GIT_TREE_OUT"
      return "${GIT_LSTREE_RC:-0}"
      ;;
    cat-file)
      return "${GIT_CATFILE_RC:-0}"
      ;;
    show)
      printf '%s' "$GIT_SHOW_OUT"
      return "${GIT_SHOW_RC:-0}"
      ;;
    *)
      return 0
      ;;
  esac
}

count_calls() {
  local pattern="$1"
  local file="$2"
  local n
  n=$( { grep -E -- "$pattern" "$file" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

# 共通 fixture
VALID_SHA="abcdef0123456789abcdef0123456789abcdef01"
VALID_PR="404"
HEAD_REF="codex/issue-404-impl-foo"
PR_URL="https://github.com/owner/test-repo/pull/404"

# ============================================================
# Section A: adj_apply_label_decision
# ============================================================
echo "--- Section A: adj_apply_label_decision ---"

# A.1: legitimate=2 → --add-label codex-needs-iteration 呼び出し
reset_stub_state
local_rc=0
adj_apply_label_decision "$VALID_PR" "2" || local_rc=$?
assert_eq "A.1 (legitimate=2): rc=0" "0" "$local_rc"
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 2.1: --add-label codex-needs-iteration が呼ばれる" "$gh_line" "pr edit $VALID_PR --repo owner/test-repo --add-label codex-needs-iteration"
add_count=$(count_calls "add-label" "$GH_CALL_LOG")
assert_eq "Req 2.1: --add-label の呼び出し回数=1" "1" "$add_count"
remove_count=$(count_calls "remove-label" "$GH_CALL_LOG")
assert_eq "Req 2.1: --remove-label の呼び出しゼロ" "0" "$remove_count"
cleanup_stub_state

# A.2: legitimate=0 → --remove-label codex-needs-iteration 呼び出し
reset_stub_state
local_rc=0
adj_apply_label_decision "$VALID_PR" "0" || local_rc=$?
assert_eq "A.2 (legitimate=0): rc=0" "0" "$local_rc"
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 2.2: --remove-label codex-needs-iteration が呼ばれる" "$gh_line" "pr edit $VALID_PR --repo owner/test-repo --remove-label codex-needs-iteration"
remove_count=$(count_calls "remove-label" "$GH_CALL_LOG")
assert_eq "Req 2.2: --remove-label の呼び出し回数=1" "1" "$remove_count"
add_count=$(count_calls "add-label" "$GH_CALL_LOG")
assert_eq "Req 2.2: --add-label の呼び出しゼロ" "0" "$add_count"
cleanup_stub_state

# A.3: 入力検証
reset_stub_state
local_rc=0
adj_apply_label_decision "invalid" "1" || local_rc=$?
assert_eq "A.3 (PR 番号不正): rc=2" "2" "$local_rc"
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "A.3 (PR 番号不正): gh 呼び出しゼロ" "0" "$gh_count"
cleanup_stub_state

reset_stub_state
local_rc=0
adj_apply_label_decision "$VALID_PR" "abc" || local_rc=$?
assert_eq "A.3' (legitimate_count 非数値): rc=2" "2" "$local_rc"
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "A.3' (legitimate_count 非数値): gh 呼び出しゼロ" "0" "$gh_count"
cleanup_stub_state

# ============================================================
# Section B: adj_read_reviewer_verdict
# ============================================================
echo ""
echo "--- Section B: adj_read_reviewer_verdict ---"

# B.1: review-notes.md 不在 → 空文字列
reset_stub_state
GIT_TREE_OUT="docs/specs/
docs/specs/404-feat-foo/
"
GIT_CATFILE_RC=1  # file 不在
verdict=$(adj_read_reviewer_verdict "$HEAD_REF" 2>/dev/null)
assert_eq "B.1: review-notes.md 不在 → 空文字列" "" "$verdict"
cleanup_stub_state

# B.2: RESULT 行不在 → 空文字列
reset_stub_state
GIT_TREE_OUT="docs/specs/404-feat-foo/
"
GIT_CATFILE_RC=0
GIT_SHOW_OUT=$'# Review Notes\n\n（RESULT 行が無いノート）'
verdict=$(adj_read_reviewer_verdict "$HEAD_REF" 2>/dev/null)
assert_eq "B.2: RESULT 行不在 → 空文字列" "" "$verdict"
cleanup_stub_state

# B.3: RESULT: approve
reset_stub_state
GIT_TREE_OUT="docs/specs/404-feat-foo/
"
GIT_CATFILE_RC=0
GIT_SHOW_OUT=$'# Review Notes\n\n## 判定\n\nRESULT: approve\n'
verdict=$(adj_read_reviewer_verdict "$HEAD_REF" 2>/dev/null)
assert_eq "B.3: RESULT: approve → \"approve\"" "approve" "$verdict"
cleanup_stub_state

# B.4: RESULT: reject
reset_stub_state
GIT_TREE_OUT="docs/specs/404-feat-foo/
"
GIT_CATFILE_RC=0
GIT_SHOW_OUT=$'# Review Notes\n\n## 判定\n\n- **Category**: AC 未カバー\n- **Target**: 1.2\n\nRESULT: reject\n'
verdict=$(adj_read_reviewer_verdict "$HEAD_REF" 2>/dev/null)
assert_eq "B.4: RESULT: reject → \"reject\"" "reject" "$verdict"
cleanup_stub_state

# B.5: head_ref パターン外 → 空文字列
reset_stub_state
verdict=$(adj_read_reviewer_verdict "feature/non-codex-branch" 2>/dev/null)
assert_eq "B.5: head_ref パターン外 → 空文字列" "" "$verdict"
git_count=$(count_calls "^git " "$GIT_CALL_LOG")
assert_eq "B.5: head_ref パターン外で git 呼び出しゼロ（早期 return）" "0" "$git_count"
cleanup_stub_state

# ============================================================
# Section C: adj_apply_status_decision (5 ケース; design.md 表)
# ============================================================
echo ""
echo "--- Section C: adj_apply_status_decision (Reviewer 先行優先 / 5 ケース) ---"

# AND 二重 opt-in を有効化（pr_publish_commit_status 内 gate 通過）。
# 抽出関数（extract_function + eval）経由で参照されるため shellcheck からは未使用に見える。
# shellcheck disable=SC2034
PR_REVIEWER_STATUS_CHECK_ENABLED="true"
# shellcheck disable=SC2034
FULL_AUTO_ENABLED="true"

# 共通 spec dir fixture
SPEC_TREE='docs/specs/
docs/specs/404-feat-foo/
'
APPROVE_NOTES_BODY=$'# Review Notes\n\nRESULT: approve\n'
REJECT_NOTES_BODY=$'# Review Notes\n\n- **Category**: AC 未カバー\n- **Target**: 1.2\n\nRESULT: reject\n'

# C.1: legit ≥1 + Reviewer approve → failure（Req 3.4）
reset_stub_state
GIT_TREE_OUT="$SPEC_TREE"
GIT_CATFILE_RC=0
GIT_SHOW_OUT="$APPROVE_NOTES_BODY"
local_rc=0
adj_apply_status_decision "$VALID_PR" "$VALID_SHA" "2" "$PR_URL" "$HEAD_REF" || local_rc=$?
assert_eq "C.1 (legit=2 + approve): rc=0" "0" "$local_rc"
gh_line=$(cat "$GH_CALL_LOG")
post_count=$(count_calls "^gh api -X POST repos/owner/test-repo/statuses/$VALID_SHA" "$GH_CALL_LOG")
assert_eq "C.1: status POST 1 回" "1" "$post_count"
assert_contains "Req 3.4: state=failure" "$gh_line" "state=failure"
assert_contains "Req 3.4: context=claude-review" "$gh_line" "context=claude-review"
cleanup_stub_state

# C.2: legit ゼロ + Reviewer approve → success（Req 3.3）
reset_stub_state
GIT_TREE_OUT="$SPEC_TREE"
GIT_CATFILE_RC=0
GIT_SHOW_OUT="$APPROVE_NOTES_BODY"
local_rc=0
adj_apply_status_decision "$VALID_PR" "$VALID_SHA" "0" "$PR_URL" "$HEAD_REF" || local_rc=$?
assert_eq "C.2 (legit=0 + approve): rc=0" "0" "$local_rc"
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 3.3: state=success" "$gh_line" "state=success"
assert_contains "Req 3.3: context=claude-review" "$gh_line" "context=claude-review"
cleanup_stub_state

# C.3: legit ゼロ + Reviewer reject → failure（Req 3.5 先行優先 / 上書き防止）
reset_stub_state
GIT_TREE_OUT="$SPEC_TREE"
GIT_CATFILE_RC=0
GIT_SHOW_OUT="$REJECT_NOTES_BODY"
local_rc=0
adj_apply_status_decision "$VALID_PR" "$VALID_SHA" "0" "$PR_URL" "$HEAD_REF" || local_rc=$?
assert_eq "C.3 (legit=0 + reject): rc=0" "0" "$local_rc"
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 3.5: state=failure（Reviewer reject 先行優先 / legit=0 上書き）" "$gh_line" "state=failure"
log_line=$(cat "$LOG_LOG")
assert_contains "Req 3.5: log に Reviewer reject 検出を明示" "$log_line" "Reviewer reject 検出"
cleanup_stub_state

# C.4: codex 失敗（findings 空 → legit ゼロ）+ Reviewer approve → success（Req 2.3 / 3.6）
reset_stub_state
GIT_TREE_OUT="$SPEC_TREE"
GIT_CATFILE_RC=0
GIT_SHOW_OUT="$APPROVE_NOTES_BODY"
local_rc=0
adj_apply_status_decision "$VALID_PR" "$VALID_SHA" "0" "$PR_URL" "$HEAD_REF" || local_rc=$?
assert_eq "C.4 (codex 失敗 + approve): rc=0" "0" "$local_rc"
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 2.3 / 3.6: state=success（codex 失敗でも legit=0 + Reviewer reject 不在）" "$gh_line" "state=success"
cleanup_stub_state

# C.5: claude 失敗時相当（fallback で legit=0 として呼ばれる経路）+ Reviewer approve → success
reset_stub_state
GIT_TREE_OUT="$SPEC_TREE"
GIT_CATFILE_RC=0
GIT_SHOW_OUT="$APPROVE_NOTES_BODY"
local_rc=0
adj_apply_status_decision "$VALID_PR" "$VALID_SHA" "0" "$PR_URL" "$HEAD_REF" || local_rc=$?
assert_eq "C.5 (claude 失敗→fallback legit=0 + approve): rc=0" "0" "$local_rc"
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 3.3: state=success（claude 失敗 fallback でも Reviewer reject 不在で success）" "$gh_line" "state=success"
cleanup_stub_state

# 入力検証
reset_stub_state
local_rc=0
adj_apply_status_decision "invalid" "$VALID_SHA" "1" "$PR_URL" "$HEAD_REF" || local_rc=$?
assert_eq "C.in.1 (PR 番号不正): rc=2" "2" "$local_rc"
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "C.in.1: gh 呼び出しゼロ" "0" "$gh_count"
cleanup_stub_state

reset_stub_state
local_rc=0
adj_apply_status_decision "$VALID_PR" "not-a-sha" "1" "$PR_URL" "$HEAD_REF" || local_rc=$?
assert_eq "C.in.2 (sha 不正): rc=2" "2" "$local_rc"
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "C.in.2: gh 呼び出しゼロ" "0" "$gh_count"
cleanup_stub_state

# ============================================================
# Section D: adj_post_decision_comment
# ============================================================
echo ""
echo "--- Section D: adj_post_decision_comment (hidden marker + 重複防止) ---"

FINDINGS_2=$(jq -nc '[
  {severity:"high",   file:"foo.sh", line:10, message:"重大バグ A"},
  {severity:"medium", file:"bar.sh", line:25, message:"警告 B"}
]')
DECISIONS_MIXED=$(jq -nc '{
  decisions: [
    {id:1, severity:"high",   file:"foo.sh", line:10, verdict:"legitimate", reason:"AC 1.1 直結"},
    {id:2, severity:"medium", file:"bar.sh", line:25, verdict:"excessive",  reason:"主観的スタイル"}
  ],
  summary: {total:2, legitimate:1, excessive:1}
}')

# D.1: marker 付き summary を投稿 + excessive 個別 marker
reset_stub_state
GH_API_BODY="[]"  # 既存コメントなし
local_rc=0
adj_post_decision_comment "$VALID_PR" "$VALID_SHA" "$FINDINGS_2" "$DECISIONS_MIXED" || local_rc=$?
assert_eq "D.1: rc=0" "0" "$local_rc"

# summary コメント = pr comment 1 回 + excessive 1 件 = 2 件投稿
comment_count=$(count_calls "^gh pr comment $VALID_PR" "$GH_CALL_LOG")
assert_eq "D.1: 投稿件数 = summary(1) + excessive(1) = 2" "2" "$comment_count"
log_line=$(cat "$LOG_LOG")
assert_contains "Req 4.1: 裁定サマリコメント投稿ログに sha" "$log_line" "sha=$VALID_SHA"
assert_contains "Req 4.1: 裁定サマリ件数 total=2 を記録" "$log_line" "total=2"
assert_contains "NFR 1.2: excessive marker ログに id=2" "$log_line" "id=2"
cleanup_stub_state

# D.2: marker 文字列の検査（専用 stub gh で --body 値を log し本文 marker を直接検査する）
reset_stub_state
# shellcheck disable=SC2317
gh() {
  if [ "${1:-}" = "pr" ] && [ "${2:-}" = "comment" ]; then
    # --body の次の引数を取り出す
    local body=""
    local seen_body=0
    for arg in "$@"; do
      if [ "$seen_body" = "1" ]; then
        body="$arg"
        seen_body=0
        echo "GHCOMMENT_BODY: $body" >>"$GH_CALL_LOG"
        continue
      fi
      if [ "$arg" = "--body" ]; then
        seen_body=1
      fi
    done
    return 0
  fi
  case "${1:-}" in
    api)
      printf '%s' "$GH_API_BODY"
      return "$GH_API_RC"
      ;;
    *) return 0 ;;
  esac
}
GH_API_BODY="[]"
local_rc=0
adj_post_decision_comment "$VALID_PR" "$VALID_SHA" "$FINDINGS_2" "$DECISIONS_MIXED" || local_rc=$?
assert_eq "D.2: rc=0" "0" "$local_rc"
body_log=$(cat "$GH_CALL_LOG")
# summary marker
assert_contains "Req 4.1: summary 本文に hidden marker prefix idd-codex:pr-adjudicator" "$body_log" "idd-codex:pr-adjudicator sha=$VALID_SHA kind=decision"
# excessive 個別 marker（id=2 が excessive）
assert_contains "NFR 1.2: excessive 個別 marker prefix pr-adjudicator-excessive" "$body_log" "idd-codex:pr-adjudicator-excessive id=2 sha=$VALID_SHA"
# Req 4.3 / NFR 1.2: marker prefix が pi self-filter の prefix と非衝突
assert_not_contains "Req 4.3: marker prefix が pr-iteration と非衝突（衝突 prefix なし）" "$body_log" "idd-codex:pr-iteration"
cleanup_stub_state

# stub gh を元に戻す（後続テストへの影響を避ける）
# shellcheck disable=SC2317
gh() {
  echo "gh $*" >>"$GH_CALL_LOG"
  case "${1:-}" in
    api)
      local arg
      for arg in "$@"; do
        case "$arg" in
          *"/issues/"*"/comments"*) printf '%s' "$GH_API_BODY"; return "$GH_API_RC" ;;
        esac
      done
      return "${GH_NEXT_RC:-0}"
      ;;
    pr) return "${GH_NEXT_RC:-0}" ;;
    *)  return "${GH_NEXT_RC:-0}" ;;
  esac
}

# D.3: 既存 (sha, kind=decision) で skip（重複防止）
reset_stub_state
# 既存コメントに同 sha + kind=decision の marker が含まれる JSON 配列を返す。
GH_API_BODY=$(jq -nc --arg sha "$VALID_SHA" \
  '[ { "body": ("## 自動裁定サマリ\n\n<!-- idd-codex:pr-adjudicator sha=" + $sha + " kind=decision -->") } ]')
local_rc=0
adj_post_decision_comment "$VALID_PR" "$VALID_SHA" "$FINDINGS_2" "$DECISIONS_MIXED" || local_rc=$?
assert_eq "D.3 (既存 marker): rc=0" "0" "$local_rc"
# pr comment は呼ばれない（skip）
comment_count=$(count_calls "^gh pr comment $VALID_PR" "$GH_CALL_LOG")
assert_eq "D.3: 重複防止で gh pr comment ゼロ" "0" "$comment_count"
log_line=$(cat "$LOG_LOG")
assert_contains "D.3: log に skip 理由（既存 sha + kind=decision）" "$log_line" "再投稿 skip"
cleanup_stub_state

# D.4: prefix `pr-adjudicator` が `pr-iteration` 非衝突を文字列マッチで再確認
reset_stub_state
GH_API_BODY="[]"
# 専用 body 観測 stub を再設置
# shellcheck disable=SC2317
gh() {
  if [ "${1:-}" = "pr" ] && [ "${2:-}" = "comment" ]; then
    local body=""
    local seen_body=0
    for arg in "$@"; do
      if [ "$seen_body" = "1" ]; then
        body="$arg"
        seen_body=0
        echo "GHCOMMENT_BODY: $body" >>"$GH_CALL_LOG"
        continue
      fi
      if [ "$arg" = "--body" ]; then
        seen_body=1
      fi
    done
    return 0
  fi
  case "${1:-}" in
    api) printf '%s' "$GH_API_BODY"; return "$GH_API_RC" ;;
    *) return 0 ;;
  esac
}
local_rc=0
adj_post_decision_comment "$VALID_PR" "$VALID_SHA" "$FINDINGS_2" "$DECISIONS_MIXED" || local_rc=$?
body_log=$(cat "$GH_CALL_LOG")
# pr-iteration prefix が混入していないこと（self-filter 衝突なし）
assert_not_contains "Req 4.3 / NFR 1.2: prefix pr-iteration が混入しない" "$body_log" "idd-codex:pr-iteration"
# pr-adjudicator prefix は厳密に含まれている
assert_contains "Req 4.3 / NFR 1.2: prefix pr-adjudicator が summary に含まれる" "$body_log" "idd-codex:pr-adjudicator sha="
assert_contains "Req 4.3 / NFR 1.2: prefix pr-adjudicator-excessive が含まれる" "$body_log" "idd-codex:pr-adjudicator-excessive id="
cleanup_stub_state

# ─── サマリ ───
echo ""
echo "================================"
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
