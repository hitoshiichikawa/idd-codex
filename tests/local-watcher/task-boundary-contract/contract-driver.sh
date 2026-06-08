#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# contract-driver.sh — task-boundary contract の fixture 回帰テスト
#
# 用途: shared rule / Architect prompt の key phrase と root / repo-template
#       byte-identical 同期、valid / invalid tasks.md fixture の same-task
#       coverage と deferred coverage 境界を検証する。
#
# 配置: tests/local-watcher/task-boundary-contract/contract-driver.sh
# 依存: bash 4+, awk, grep, diff
# 設計参照: docs/specs/21--bug-architect-task-per-task-review/design.md
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

_DRV_DIR="$(cd "$(dirname "$0")" && pwd)"
_REPO_ROOT="$(cd "$_DRV_DIR/../../.." && pwd)"
_FIXTURE_DIR="$_DRV_DIR/fixtures"

_fail=0
_pass=0
_failed_names=()

record_ok() {
  _pass=$((_pass + 1))
  printf '  ok   %s\n' "$1"
}

record_fail() {
  _fail=$((_fail + 1))
  _failed_names+=("$1")
  printf '  FAIL %s\n' "$1"
  if [ "$#" -gt 1 ]; then
    printf '    %s\n' "$2"
  fi
}

assert_contains() {
  _name="$1"
  _file="$2"
  _pattern="$3"
  if grep -Eq "$_pattern" "$_file"; then
    record_ok "$_name"
  else
    record_fail "$_name" "missing pattern: $_pattern"
  fi
}

assert_diff_clean() {
  _name="$1"
  _left="$2"
  _right="$3"
  if diff -r "$_left" "$_right" >/dev/null; then
    record_ok "$_name"
  else
    record_fail "$_name" "diff -r $_left $_right reported drift"
  fi
}

task_block() {
  _task_id="$1"
  _file="$2"
  awk -v task_id="$_task_id" '
    $0 ~ "^- \\[ \\]\\*? " task_id "([. ]|$)" { in_task = 1; print; next }
    in_task && /^- \[ \]\*? [0-9]+(\.[0-9]+)*\.? / { exit }
    in_task { print }
  ' "$_file"
}

block_has_requirements() {
  _block="$1"
  _expected="$2"
  printf '%s\n' "$_block" | grep -Eq "_Requirements:([^0-9]|.*, )${_expected}([^0-9]|$)"
}

block_has_test_work() {
  _block="$1"
  printf '%s\n' "$_block" | grep -Eiq '(regression|failure path|safety fallback|shell-level).*(test|fixture)|テスト'
}

block_has_depends() {
  _block="$1"
  _expected="$2"
  printf '%s\n' "$_block" | grep -Eq "_Depends:([^0-9]|.*, )${_expected}([^0-9]|$)"
}

validate_same_task_coverage() {
  _file="$1"
  _task_1=$(task_block "1" "$_file")

  if block_has_requirements "$_task_1" "2\\.1" \
      && block_has_requirements "$_task_1" "2\\.2" \
      && block_has_requirements "$_task_1" "2\\.3" \
      && block_has_requirements "$_task_1" "2\\.4" \
      && block_has_test_work "$_task_1"; then
    return 0
  fi
  return 1
}

validate_deferred_coverage() {
  _file="$1"
  _task_1=$(task_block "1" "$_file")
  _task_2=$(task_block "2" "$_file")

  if block_has_requirements "$_task_1" "2\\.1" \
      || block_has_requirements "$_task_1" "2\\.2" \
      || block_has_requirements "$_task_1" "2\\.3" \
      || block_has_requirements "$_task_1" "2\\.4"; then
    return 1
  fi
  if block_has_requirements "$_task_2" "2\\.1" \
      && block_has_requirements "$_task_2" "2\\.2" \
      && block_has_requirements "$_task_2" "2\\.3" \
      && block_has_requirements "$_task_2" "2\\.4" \
      && block_has_test_work "$_task_2" \
      && block_has_depends "$_task_2" "1"; then
    return 0
  fi
  return 1
}

expect_valid() {
  _name="$1"
  _kind="$2"
  _file="$3"
  case "$_kind" in
    same-task)
      if validate_same_task_coverage "$_file"; then
        record_ok "$_name"
      else
        record_fail "$_name" "same-task coverage fixture did not satisfy contract"
      fi
      ;;
    deferred)
      if validate_deferred_coverage "$_file"; then
        record_ok "$_name"
      else
        record_fail "$_name" "deferred coverage fixture did not satisfy contract"
      fi
      ;;
    *)
      record_fail "$_name" "unknown fixture kind: $_kind"
      ;;
  esac
}

expect_invalid() {
  _name="$1"
  _kind="$2"
  _file="$3"
  case "$_kind" in
    deferred)
      if validate_deferred_coverage "$_file"; then
        record_fail "$_name" "invalid deferred fixture unexpectedly satisfied contract"
      else
        record_ok "$_name"
      fi
      ;;
    *)
      record_fail "$_name" "unknown fixture kind: $_kind"
      ;;
  esac
}

if [ ! -d "$_FIXTURE_DIR" ]; then
  echo "ERROR: fixture dir not found at $_FIXTURE_DIR" >&2
  exit 2
fi

assert_diff_clean "agents root/template sync" "$_REPO_ROOT/.codex/agents" "$_REPO_ROOT/repo-template/.codex/agents"
assert_diff_clean "rules root/template sync" "$_REPO_ROOT/.codex/rules" "$_REPO_ROOT/repo-template/.codex/rules"

assert_contains "shared rule has Task Boundary Contract" \
  "$_REPO_ROOT/.codex/rules/tasks-generation.md" '^## Task Boundary Contract$'
assert_contains "shared rule limits Requirements to same task scope" \
  "$_REPO_ROOT/.codex/rules/tasks-generation.md" '実装・テスト・レビュー可能な AC だけ'
assert_contains "shared rule binds coverage to same-task test work" \
  "$_REPO_ROOT/.codex/rules/tasks-generation.md" 'regression coverage / failure path / safety fallback / runtime behavior change'
assert_contains "architect prompt references Task Boundary Contract" \
  "$_REPO_ROOT/.codex/agents/architect.md" 'Task Boundary Contract'
assert_contains "architect prompt has self-check for deferred coverage" \
  "$_REPO_ROOT/.codex/agents/architect.md" 'deferred coverage は先行 task の'

expect_valid "fixture same-task coverage is valid" \
  "same-task" "$_FIXTURE_DIR/tasks-same-task-coverage.md"
expect_valid "fixture deferred coverage is valid" \
  "deferred" "$_FIXTURE_DIR/tasks-deferred-coverage.md"
expect_invalid "fixture invalid deferred coverage is rejected" \
  "deferred" "$_FIXTURE_DIR/tasks-invalid-deferred-ac.md"

echo
echo "summary: pass=$_pass fail=$_fail total=$((_pass + _fail))"

if [ "$_fail" -gt 0 ]; then
  echo "failed cases: ${_failed_names[*]}" >&2
  exit 1
fi
exit 0
