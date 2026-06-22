#!/usr/bin/env bash
#
# 用途: CONTEXT_MAP_ENABLED=true の per-task context-map 生成と prompt 注入を検証する。
# 配置先: local-watcher/test/context_map_prompt_test.sh
# 依存: bash 4+, git, awk, sed
# 実行: bash local-watcher/test/context_map_prompt_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/context-map.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find watcher at $WATCHER_SH" >&2
  exit 2
fi
if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find context-map module at $MODULE_SH" >&2
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

for fn in \
  build_issue_context_block \
  pt_extract_learnings \
  build_per_task_implementer_prompt \
  build_per_task_reviewer_prompt; do
  # shellcheck disable=SC1090
  eval "$(extract_function "$WATCHER_SH" "$fn")"
done

# shellcheck source=../bin/idd-codex-modules/context-map.sh
. "$MODULE_SH"

for fn in ci_context_indexer_enabled cm_write_context_map cm_build_prompt_block build_per_task_implementer_prompt build_per_task_reviewer_prompt; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

REPO_DIR="$TMPDIR_TEST/repo"
SPEC_DIR_REL="docs/specs/34-context-map"
LOG="$TMPDIR_TEST/context-map.log"
REPO="owner/test"
NUMBER="34"
TITLE="context map test"
URL="https://github.com/owner/test/issues/34"
BODY="context map body"
BRANCH="codex/issue-34-context-map"
BASE_BRANCH="main"
export REPO_DIR SPEC_DIR_REL LOG REPO NUMBER TITLE URL BODY BRANCH BASE_BRANCH

git init -q "$REPO_DIR"
git -C "$REPO_DIR" checkout -q -b main
git -C "$REPO_DIR" config user.email "test@example.com"
git -C "$REPO_DIR" config user.name "Test User"

mkdir -p "$REPO_DIR/$SPEC_DIR_REL" "$REPO_DIR/local-watcher/bin" "$REPO_DIR/local-watcher/test"

cat > "$REPO_DIR/AGENTS.md" <<'EOF'
# AGENTS
EOF

cat > "$REPO_DIR/local-watcher/bin/idd-codex-issue-watcher.sh" <<'EOF'
#!/usr/bin/env bash
cm_existing_anchor() {
  :
}
EOF

cat > "$REPO_DIR/local-watcher/test/context_map_existing_test.sh" <<'EOF'
#!/usr/bin/env bash
cm_existing_anchor
EOF

cat > "$REPO_DIR/$SPEC_DIR_REL/requirements.md" <<'EOF'
# Requirements

1. When context map is enabled, watcher shall inject it.
EOF

cat > "$REPO_DIR/$SPEC_DIR_REL/design.md" <<'EOF'
# Design

Context map design.
EOF

cat > "$REPO_DIR/$SPEC_DIR_REL/tasks.md" <<'EOF'
# Implementation Plan

- [ ] 1. context mapを生成する
  - 親タスク。
  - _Requirements:_ 1
  - _Boundary:_ `local-watcher/bin/idd-codex-issue-watcher.sh`, `local-watcher/test/context_map_existing_test.sh`

- [ ] 1.1 context map生成とprompt注入を実装する
  - `cm_existing_anchor` を anchor として使う。
  - _Requirements:_ 1
  - _Boundary:_ `local-watcher/bin/idd-codex-issue-watcher.sh`
  - _Depends:_ 1

- [ ] 1.2 後続タスク
  - _Requirements:_ 1
  - _Boundary:_ README.md
EOF

cat > "$REPO_DIR/$SPEC_DIR_REL/impl-notes.md" <<'EOF'
# Implementation Notes

## Implementation Notes

### Task 1
- 採用方針: 既存 watcher 関数に限定する
EOF

git -C "$REPO_DIR" add .
git -C "$REPO_DIR" commit -q -m "base fixture"

printf '%s\n' "# changed by fixture" >> "$REPO_DIR/local-watcher/bin/idd-codex-issue-watcher.sh"
git -C "$REPO_DIR" add local-watcher/bin/idd-codex-issue-watcher.sh
git -C "$REPO_DIR" commit -q -m "feat: change watcher"

RANGE_START="$(git -C "$REPO_DIR" rev-parse HEAD~1)"
RANGE_END="$(git -C "$REPO_DIR" rev-parse HEAD)"
CONTEXT_MAP_PATH="$REPO_DIR/$SPEC_DIR_REL/context-map.md"

PASS_COUNT=0
FAIL_COUNT=0

assert_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  missing: $(printf '%q' "$needle")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  unexpected: $(printf '%q' "$needle")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_file_exists() {
  local label="$1"
  local path="$2"
  if [ -f "$path" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  missing file: $path"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_file_not_exists() {
  local label="$1"
  local path="$2"
  if [ ! -e "$path" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  unexpected file: $path"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

CONTEXT_MAP_ENABLED=false
CONTEXT_INDEXER_ENABLED=false
export CONTEXT_MAP_ENABLED
export CONTEXT_INDEXER_ENABLED
rm -f "$CONTEXT_MAP_PATH"
cm_write_context_map "1.1" "implementer" "" ""
assert_file_not_exists "flag off does not write context-map.md" "$CONTEXT_MAP_PATH"
prompt_off="$(build_per_task_implementer_prompt "1.1")"
assert_not_contains "flag off implementer prompt has no context map block" "$prompt_off" "## Context Map"
if ci_context_indexer_enabled; then
  echo "FAIL: indexer gate rejects false"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "PASS: indexer gate rejects false"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

CONTEXT_MAP_ENABLED=true
CONTEXT_INDEXER_ENABLED=True
export CONTEXT_MAP_ENABLED
export CONTEXT_INDEXER_ENABLED
if ci_context_indexer_enabled; then
  echo "FAIL: indexer gate rejects non-strict true"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "PASS: indexer gate rejects non-strict true"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

CONTEXT_INDEXER_ENABLED=false
export CONTEXT_INDEXER_ENABLED
cm_write_context_map "1.1" "implementer" "" ""
assert_file_exists "flag on writes context-map.md" "$CONTEXT_MAP_PATH"
map_body="$(sed -n '1,220p' "$CONTEXT_MAP_PATH")"
assert_contains "context map records target task" "$map_body" "- Task: \`1.1\`"
assert_contains "context map separates deterministic section" "$map_body" "## Deterministic Metadata"
assert_contains "context map records skipped indexer status" "$map_body" "## Indexer Status"
assert_contains "context map records disabled indexer reason" "$map_body" "- Reason: \`disabled\`"
assert_contains "context map records boundary file" "$map_body" "local-watcher/bin/idd-codex-issue-watcher.sh"
assert_contains "context map records anchor" "$map_body" "cm_existing_anchor"
assert_contains "context map records anchor-derived test" "$map_body" "local-watcher/test/context_map_existing_test.sh"
assert_contains "context map records constraints" "$map_body" "repo-wide \`rg --files\`"

prompt_on="$(build_per_task_implementer_prompt "1.1")"
assert_contains "flag on implementer prompt injects context map block" "$prompt_on" "## Context Map"
assert_contains "implementer prompt includes context-map path" "$prompt_on" "$SPEC_DIR_REL/context-map.md"
assert_contains "implementer prompt asks to read candidate context first" "$prompt_on" "Developer はまず Candidate Files / Anchors / Candidate Tests"
assert_contains "implementer prompt declares bounded context-map slice" "$prompt_on" "Slice: bounded first 180 lines"
assert_contains "implementer prompt includes candidate file" "$prompt_on" "local-watcher/bin/idd-codex-issue-watcher.sh"

CONTEXT_INDEXER_ENABLED=true
export CONTEXT_INDEXER_ENABLED
if ci_context_indexer_enabled; then
  echo "PASS: indexer gate accepts strict true"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: indexer gate accepts strict true"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
cm_write_context_map "1.1" "implementer" "" ""
map_with_indexer_gate="$(sed -n '1,220p' "$CONTEXT_MAP_PATH")"
assert_contains "indexer opt-in does not change deterministic map before runner task" "$map_with_indexer_gate" "local-watcher/bin/idd-codex-issue-watcher.sh"

cm_write_context_map "1.1" "reviewer" "$RANGE_START" "$RANGE_END"
reviewer_map="$(sed -n '1,220p' "$CONTEXT_MAP_PATH")"
assert_contains "reviewer context map records diff range" "$reviewer_map" "- Diff range:"
assert_contains "reviewer context map includes changed file" "$reviewer_map" "local-watcher/bin/idd-codex-issue-watcher.sh"

reviewer_prompt="$(build_per_task_reviewer_prompt "1.1" "$RANGE_START" "$RANGE_END" "1" "(none)")"
assert_contains "reviewer prompt injects context map block" "$reviewer_prompt" "## Context Map"
assert_contains "reviewer prompt asks to read diff and candidates first" "$reviewer_prompt" "Reviewer はまず diff range / Candidate Files / Anchors / Candidate Tests"
assert_contains "reviewer prompt keeps final judgment boundary" "$reviewer_prompt" "最終判断は tasks.md、要件、実際の diff"
assert_contains "reviewer prompt keeps bounded review instruction" "$reviewer_prompt" "本 range のみ"

if [ "$FAIL_COUNT" -ne 0 ]; then
  echo "FAIL: $FAIL_COUNT assertions failed ($PASS_COUNT passed)" >&2
  exit 1
fi

echo "PASS: all $PASS_COUNT assertions"
