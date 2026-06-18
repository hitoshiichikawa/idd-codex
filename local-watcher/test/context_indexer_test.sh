#!/usr/bin/env bash
#
# 用途: CONTEXT_INDEXER_ENABLED=true 時の十分性判定と最大 1 回 state を検証する。
# 配置先: local-watcher/test/context_indexer_test.sh
# 依存: bash 4+, git, awk, sed
# 実行: bash local-watcher/test/context_indexer_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/context-map.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find context-map module at $MODULE_SH" >&2
  exit 2
fi

# shellcheck source=../bin/idd-codex-modules/context-map.sh
. "$MODULE_SH"

for fn in \
  ci_context_needs_indexer \
  ci_record_indexer_marker \
  cm_write_context_map; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

REPO_DIR="$TMPDIR_TEST/repo"
SPEC_DIR_REL="docs/specs/36-context-indexer"
LOG="$TMPDIR_TEST/context-indexer.log"
NUMBER="36"
BASE_BRANCH="main"
export REPO_DIR SPEC_DIR_REL LOG NUMBER BASE_BRANCH

git init -q "$REPO_DIR"
git -C "$REPO_DIR" checkout -q -b main
git -C "$REPO_DIR" config user.email "test@example.com"
git -C "$REPO_DIR" config user.name "Test User"

mkdir -p "$REPO_DIR/$SPEC_DIR_REL" "$REPO_DIR/local-watcher/bin" "$REPO_DIR/local-watcher/test"

cat > "$REPO_DIR/local-watcher/bin/sufficient.sh" <<'EOF'
#!/usr/bin/env bash
ci_sufficient_anchor() {
  :
}
EOF

cat > "$REPO_DIR/local-watcher/test/sufficient_test.sh" <<'EOF'
#!/usr/bin/env bash
ci_sufficient_anchor
EOF

cat > "$REPO_DIR/$SPEC_DIR_REL/requirements.md" <<'EOF'
# Requirements
EOF

cat > "$REPO_DIR/$SPEC_DIR_REL/design.md" <<'EOF'
# Design
EOF

cat > "$REPO_DIR/$SPEC_DIR_REL/tasks.md" <<'EOF'
# Implementation Plan

- [ ] 1.1 deterministic context が十分な task
  - `ci_sufficient_anchor` を anchor として使う。
  - _Requirements:_ 2.1
  - _Boundary:_ `local-watcher/bin/sufficient.sh`, `local-watcher/test/sufficient_test.sh`

- [ ] 1.2 deterministic context が曖昧な task
  - 候補ファイルはあるが anchor と候補 test がない。
  - _Requirements:_ 2.2
  - _Boundary:_ `local-watcher/bin/ambiguous.sh`

- [ ] 1.3 docs-only task
  - README だけを更新する。
  - _Requirements:_ 2.1
  - _Boundary:_ `README.md`
EOF

cat > "$REPO_DIR/README.md" <<'EOF'
# Fixture
EOF

git -C "$REPO_DIR" add .
git -C "$REPO_DIR" commit -q -m "base fixture"
git -C "$REPO_DIR" checkout -q -b feature/prior-task

cat > "$REPO_DIR/local-watcher/bin/prior.sh" <<'EOF'
#!/usr/bin/env bash
ci_prior_anchor() {
  :
}
EOF

cat > "$REPO_DIR/local-watcher/test/prior_test.sh" <<'EOF'
#!/usr/bin/env bash
ci_prior_anchor
EOF

git -C "$REPO_DIR" add local-watcher/bin/prior.sh local-watcher/test/prior_test.sh
git -C "$REPO_DIR" commit -q -m "prior task changes"

CONTEXT_MAP_ENABLED=true
CONTEXT_INDEXER_ENABLED=true
export CONTEXT_MAP_ENABLED CONTEXT_INDEXER_ENABLED

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

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

CONTEXT_INDEXER_ENABLED=false
export CONTEXT_INDEXER_ENABLED
assert_eq \
  "disabled gate always skips indexer" \
  "$(ci_context_needs_indexer "1.2" "implementer" "" "")" \
  "skip:disabled"

CONTEXT_INDEXER_ENABLED=true
export CONTEXT_INDEXER_ENABLED
assert_eq \
  "sufficient deterministic context skips indexer" \
  "$(ci_context_needs_indexer "1.1" "implementer" "" "")" \
  "skip:sufficient"

assert_eq \
  "docs-only explicit boundary skips anchors and tests requirement" \
  "$(ci_context_needs_indexer "1.3" "implementer" "" "")" \
  "skip:sufficient-docs-only"

assert_eq \
  "ambiguous deterministic context permits indexer despite prior-task diff" \
  "$(ci_context_needs_indexer "1.2" "implementer" "" "")" \
  "needed:anchors-tests-missing"

cm_write_context_map "1.2" "implementer" "" ""
ci_record_indexer_marker "1.2" "implementer" "" "" "success" "anchors-tests-missing"
assert_eq \
  "success marker prevents repeated implementer indexer run" \
  "$(ci_context_needs_indexer "1.2" "implementer" "" "")" \
  "skip:already-run"

cm_write_context_map "1.2" "implementer" "" ""
map_body="$(sed -n '1,260p' "$REPO_DIR/$SPEC_DIR_REL/context-map.md")"
assert_contains \
  "context map rewrite preserves success marker" \
  "$map_body" \
  "context-indexer: task=1.2 stage=implementer range=none result=success reason=anchors-tests-missing"

ci_record_indexer_marker "1.2" "reviewer" "abc123" "def456" "fallback" "runner-failed"
assert_eq \
  "fallback marker also prevents repeated reviewer indexer run" \
  "$(ci_context_needs_indexer "1.2" "reviewer" "abc123" "def456")" \
  "skip:already-run"

log_body="$(sed -n '1,120p' "$LOG")"
assert_contains \
  "context-indexer log records skip or needed decision" \
  "$log_body" \
  "context-indexer: task=1.2 stage=implementer decision=skip:already-run"

if [ "$FAIL_COUNT" -ne 0 ]; then
  echo "FAIL: $FAIL_COUNT assertions failed ($PASS_COUNT passed)" >&2
  exit 1
fi

echo "PASS: all $PASS_COUNT assertions"
