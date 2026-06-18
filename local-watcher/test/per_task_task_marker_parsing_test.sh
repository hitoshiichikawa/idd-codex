#!/usr/bin/env bash
#
# 用途: per-task loop の watcher-compatible numeric checkbox task marker 判定を検証する。
# 配置先: local-watcher/test/per_task_task_marker_parsing_test.sh
# 依存: bash 4+, awk/grep/sed/sort
# 実行: bash local-watcher/test/per_task_task_marker_parsing_test.sh
# shellcheck disable=SC2317

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

extract_function() {
  local script="$1" fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "pt_log")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "pt_warn")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "pt_extract_pending_tasks")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "pt_has_watcher_compatible_tasks")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "pt_fail_no_compatible_tasks")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "pt_check_task_completed")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "run_per_task_loop")"

for fn in pt_extract_pending_tasks pt_has_watcher_compatible_tasks pt_fail_no_compatible_tasks pt_check_task_completed run_per_task_loop; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

PASS=0
FAIL=0

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ok: $label"
    PASS=$((PASS + 1))
  else
    echo "  NG: $label expected=[$expected] actual=[$actual]" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_rc() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" -eq "$actual" ]; then
    echo "  ok: $label"
    PASS=$((PASS + 1))
  else
    echo "  NG: $label expected_rc=$expected actual_rc=$actual" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local needle="$1" haystack="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  ok: $label"
    PASS=$((PASS + 1))
  else
    echo "  NG: $label missing=[$needle] actual=[$haystack]" >&2
    FAIL=$((FAIL + 1))
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/prose-checkbox.md" <<'EOF'
- [ ] 1 PR で大きすぎる場合は分割する
EOF

cat > "$TMP/parent.md" <<'EOF'
- [ ] 1. Baseline audit
EOF

cat > "$TMP/child.md" <<'EOF'
- [ ] 1.1 子タスク
EOF

cat > "$TMP/heading-only.md" <<'EOF'
## 1. Baseline audit

- [ ] 1 PR で大きすぎる場合は分割する
EOF

echo "[case1] prose checkbox は pending task ID として抽出しない"
assert_eq "" "$(pt_extract_pending_tasks "$TMP/prose-checkbox.md")" "prose checkbox '- [ ] 1 PR ...' は task 1 ではない"

echo "[case2] parent marker は task ID 1 として抽出する"
assert_eq "1" "$(pt_extract_pending_tasks "$TMP/parent.md")" "parent '- [ ] 1. ...' は task 1"

echo "[case3] child marker は task ID 1.1 として抽出する"
assert_eq "1.1" "$(pt_extract_pending_tasks "$TMP/child.md")" "child '- [ ] 1.1 ...' は task 1.1"

echo "[case4] completion check は prose checkbox を task 1 と扱わない"
check_rc=0
pt_check_task_completed "$TMP/prose-checkbox.md" "1" || check_rc=$?
assert_rc 2 "$check_rc" "task 1 の checkbox 行不在として fail-safe rc=2"

echo "[case5] heading-only tasks.md は per-task startup で actionable failure"
REPO_DIR="$TMP/repo"
SPEC_DIR_REL="docs/specs/68-bug-watcher-tasks-md-checkbox-numeric-ta"
LOG="$TMP/per-task.log"
mkdir -p "$REPO_DIR/$SPEC_DIR_REL"
cp "$TMP/heading-only.md" "$REPO_DIR/$SPEC_DIR_REL/tasks.md"
: > "$LOG"
LAST_FAILED_CATEGORY=""
LAST_FAILED_BODY=""
mark_issue_failed() {
  LAST_FAILED_CATEGORY="$1"
  LAST_FAILED_BODY="$2"
}

loop_rc=0
run_per_task_loop || loop_rc=$?
assert_rc 1 "$loop_rc" "run_per_task_loop は marker 0 件で失敗する"
assert_eq "per-task-no-compatible-tasks" "$LAST_FAILED_CATEGORY" "failure category を記録する"
assert_contains "watcher-compatible numeric checkbox task marker が 0 件" "$LAST_FAILED_BODY" "diagnostic が marker 契約不在を説明する"
assert_contains "$SPEC_DIR_REL/tasks.md" "$LAST_FAILED_BODY" "diagnostic が対象 tasks.md を示す"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo "RESULT: FAIL" >&2
  exit 1
fi
echo "RESULT: PASS"
