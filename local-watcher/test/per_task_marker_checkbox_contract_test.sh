#!/usr/bin/env bash
#
# 用途: per-task Reviewer が regression-test-only commit の後続にある
#       `docs(tasks): mark <id> as done` marker commit を review range に含めても、
#       対象 task checkbox の `[ ]` -> `[x]` 更新だけを boundary 逸脱扱いしない契約を
#       shell fixture で固定する。Issue #26 / task 3 の regression coverage。
#
# 配置先: local-watcher/test/per_task_marker_checkbox_contract_test.sh
# 依存:   bash 4+, awk, git, grep
# 実行:   bash local-watcher/test/per_task_marker_checkbox_contract_test.sh
# 前提:   実 LLM reviewer は起動しない。prompt 文字列と git diff range を検証対象にする。

set -euo pipefail

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

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_extract_learnings")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_resolve_diff_range")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "build_per_task_implementer_prompt")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "build_per_task_reviewer_prompt")"

for fn in pt_extract_learnings pt_resolve_diff_range build_per_task_implementer_prompt build_per_task_reviewer_prompt; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded from idd-codex-issue-watcher.sh" >&2
    exit 2
  fi
done

PASS=0
FAIL=0

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  ok: $label"
    PASS=$((PASS + 1))
  else
    echo "  NG: $label" >&2
    echo "    expected: $expected" >&2
    echo "    actual  : $actual" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  if grep -Fq -- "$needle" <<<"$haystack"; then
    echo "  ok: $label"
    PASS=$((PASS + 1))
  else
    echo "  NG: $label" >&2
    echo "    missing: $needle" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  if grep -Fq -- "$needle" <<<"$haystack"; then
    echo "  NG: $label" >&2
    echo "    unexpected: $needle" >&2
    FAIL=$((FAIL + 1))
  else
    echo "  ok: $label"
    PASS=$((PASS + 1))
  fi
}

TMPROOT="$(mktemp -d)"
cleanup() {
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

REPO_WORK="$TMPROOT/repo"
SPEC_DIR_REL="docs/specs/26-marker-contract"
TASK_ID="1.1"
BASE_BRANCH="main"

git init --quiet "$REPO_WORK"
cd "$REPO_WORK"
  git config user.email "test@example.com"
  git config user.name "Test User"
  current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
  if [ "$current_branch" != "$BASE_BRANCH" ]; then
    git checkout -b "$BASE_BRANCH" --quiet
  fi

  mkdir -p "$SPEC_DIR_REL" local-watcher/test
  cat > "$SPEC_DIR_REL/tasks.md" <<'EOF'
# Implementation Plan

- [ ] 1. 親タスク
  - [ ] 1.1 regression fixture を追加する
    - _Requirements:_ 5.1, 5.2, 5.3
    - _Boundary:_ Marker Classification Regression Test
EOF
  cat > "$SPEC_DIR_REL/impl-notes.md" <<'EOF'
# Impl Notes

## Implementation Notes

### Task 1

- 採用方針: 先行 task の learning fixture。
EOF
  git add "$SPEC_DIR_REL/tasks.md" "$SPEC_DIR_REL/impl-notes.md"
  git commit --quiet -m "docs(spec): add marker contract fixture"

  git checkout -b codex/issue-26-marker-fixture --quiet

  cat > local-watcher/test/regression_fixture_test.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "regression fixture"
EOF
  git add local-watcher/test/regression_fixture_test.sh
  git commit --quiet -m "test(watcher): reproduce marker reviewer range"

  sed -i.bak 's/^\([[:space:]]*- \)\[ \] 1\.1 /\1[x] 1.1 /' "$SPEC_DIR_REL/tasks.md"
  rm -f "$SPEC_DIR_REL/tasks.md.bak"
  git add "$SPEC_DIR_REL/tasks.md"
  git commit --quiet -m "docs(tasks): mark 1.1 as done"

REPO_DIR="$REPO_WORK"
NUMBER="26"
TITLE="[Bug] per-task Reviewer marker checkbox contract"
URL="https://github.com/example/idd-codex/issues/26"
BODY="fixture body"
BRANCH="codex/issue-26-marker-fixture"
REPO="example/idd-codex"
export BASE_BRANCH BODY BRANCH NUMBER REPO REPO_DIR SPEC_DIR_REL TITLE URL

  range_line="$(pt_resolve_diff_range "$TASK_ID")"
  range_start="$(printf '%s' "$range_line" | cut -f1)"
  range_end="$(printf '%s' "$range_line" | cut -f2)"
  base_sha="$(git rev-parse "$BASE_BRANCH")"
  marker_sha="$(git rev-parse HEAD)"

  echo "[case1] regression-test-only commit + canonical marker commit の range 解決"
  assert_eq "range_start is base branch SHA" "$base_sha" "$range_start"
  assert_eq "range_end is marker commit SHA" "$marker_sha" "$range_end"

  range_subjects="$(git log --format=%s --reverse "$range_start..$range_end")"
  assert_contains "range includes regression-test-only commit" "$range_subjects" "test(watcher): reproduce marker reviewer range"
  assert_contains "range includes canonical marker commit" "$range_subjects" "docs(tasks): mark 1.1 as done"

  echo "[case2] marker commit は対象 task checkbox flip のみ"
  marker_subject="$(git log -1 --format=%s "$range_end")"
  assert_eq "marker subject is canonical" "docs(tasks): mark 1.1 as done" "$marker_subject"

  marker_files="$(git diff-tree --no-commit-id --name-only -r "$range_end")"
  assert_eq "marker changes tasks.md only" "$SPEC_DIR_REL/tasks.md" "$marker_files"

  marker_diff="$(git diff "${range_end}^..${range_end}" -- "$SPEC_DIR_REL/tasks.md")"
  assert_contains "marker removes target unchecked checkbox" "$marker_diff" "-  - [ ] 1.1 regression fixture を追加する"
  assert_contains "marker adds target checked checkbox" "$marker_diff" "+  - [x] 1.1 regression fixture を追加する"
  assert_not_contains "marker does not edit _Requirements:_" "$marker_diff" "-    - _Requirements:_"
  assert_not_contains "marker does not edit _Boundary:_" "$marker_diff" "-    - _Boundary:_"

  echo "[case3] per-task prompt は marker 分類契約を明示する"
  implementer_prompt="$(build_per_task_implementer_prompt "$TASK_ID")"
  reviewer_prompt="$(build_per_task_reviewer_prompt "$TASK_ID" "$range_start" "$range_end" "1" "none")"

  assert_contains "implementer prompt shares canonical subject" "$implementer_prompt" "docs(tasks): mark <id> as done"
  assert_contains "implementer prompt limits marker diff to checkbox only" "$implementer_prompt" "差分は当該 task 行の checkbox"
  assert_contains "implementer prompt forbids unrelated checkbox edits" "$implementer_prompt" "無関係 task の checkbox"

  assert_contains "reviewer prompt includes exact marker subject" "$reviewer_prompt" "docs(tasks): mark 1.1 as done"
  assert_contains "reviewer prompt says marker may be in range" "$reviewer_prompt" "この review range には、当該 task 完了時の marker commit が含まれ得ます"
  assert_contains "reviewer prompt allows canonical checkbox artifact" "$reviewer_prompt" "allowed orchestration artifact として扱い"
  assert_contains "reviewer prompt does not reject solely for marker checkbox" "$reviewer_prompt" "それだけを理由に \`boundary 逸脱\` で reject"
  assert_contains "reviewer prompt keeps non-canonical subject reject-eligible" "$reviewer_prompt" "marker commit subject が \`docs(tasks): mark 1.1 as done\` に完全一致しない変更"
  assert_contains "reviewer prompt keeps task body and annotation edits reject-eligible" "$reviewer_prompt" "task 本文、\`_Requirements:_\`、\`_Boundary:_\`、\`_Depends:_\`、task 順序の変更"
  assert_contains "reviewer prompt keeps non-marker spec edits reject-eligible" "$reviewer_prompt" "marker commit 以外での spec artifact 更新"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo "RESULT: FAIL" >&2
  exit 1
fi
echo "RESULT: PASS"
