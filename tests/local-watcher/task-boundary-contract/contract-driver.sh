#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# contract-driver.sh — task-boundary contract の fixture 回帰テスト
#
# 用途: shared rule / Architect / Developer / Reviewer prompt の key phrase と root / repo-template
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
    $0 ~ "^- \\[[ x]\\]\\*? " task_id "([. ]|$)" { in_task = 1; print; next }
    in_task && /^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.? / { exit }
    in_task { print }
  ' "$_file"
}

block_has_annotation_id() {
  _block="$1"
  _key="$2"
  _expected="$3"
  printf '%s\n' "$_block" | grep -Eq "_${_key}:_?[^0-9]*(.*, )?${_expected}([^0-9]|$)"
}

block_has_requirements() {
  _block="$1"
  _expected="$2"
  block_has_annotation_id "$_block" "Requirements" "$_expected"
}

block_has_depends() {
  _block="$1"
  _expected="$2"
  block_has_annotation_id "$_block" "Depends" "$_expected"
}

block_has_test_term() {
  _block="$1"
  _term="$2"
  printf '%s\n' "$_block" | grep -Eiq "${_term}.*(test|fixture|テスト)"
}

block_has_required_test_work() {
  _block="$1"
  block_has_test_term "$_block" "regression coverage" \
    && block_has_test_term "$_block" "failure path" \
    && block_has_test_term "$_block" "safety fallback" \
    && block_has_test_term "$_block" "shell-level"
}

block_mentions_deferred_test_work() {
  _block="$1"
  printf '%s\n' "$_block" | grep -Eiq '(defer|deferred|後続 task|task 2)'
}

block_has_coverage_requirements() {
  _block="$1"
  block_has_requirements "$_block" "2\\.1" \
    && block_has_requirements "$_block" "2\\.2" \
    && block_has_requirements "$_block" "2\\.3" \
    && block_has_requirements "$_block" "2\\.4"
}

validate_same_task_coverage() {
  _file="$1"
  _task_1=$(task_block "1" "$_file")

  if block_has_coverage_requirements "$_task_1" \
      && block_has_required_test_work "$_task_1"; then
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
  if block_has_coverage_requirements "$_task_2" \
      && block_has_required_test_work "$_task_2" \
      && block_has_depends "$_task_2" "1"; then
    return 0
  fi
  return 1
}

validate_invalid_deferred_ac() {
  _file="$1"
  _task_1=$(task_block "1" "$_file")
  _task_2=$(task_block "2" "$_file")

  if block_has_coverage_requirements "$_task_1" \
      && block_mentions_deferred_test_work "$_task_1" \
      && block_has_coverage_requirements "$_task_2" \
      && block_has_required_test_work "$_task_2" \
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
    deferred-ac)
      if validate_invalid_deferred_ac "$_file" && ! validate_deferred_coverage "$_file"; then
        record_ok "$_name"
      else
        record_fail "$_name" "invalid deferred fixture did not expose prior-task coverage AC"
      fi
      ;;
    *)
      record_fail "$_name" "unknown fixture kind: $_kind"
      ;;
  esac
}

expect_invalid_as_same_task() {
  _name="$1"
  _file="$2"
  if validate_same_task_coverage "$_file"; then
    record_fail "$_name" "invalid deferred fixture unexpectedly satisfied same-task coverage contract"
  else
    record_ok "$_name"
  fi
}

expect_invalid_as_deferred() {
  _name="$1"
  _file="$2"
  if validate_deferred_coverage "$_file"; then
    record_fail "$_name" "invalid deferred fixture unexpectedly satisfied deferred coverage contract"
  else
    record_ok "$_name"
  fi
}

expect_valid_as_not_invalid() {
  _name="$1"
  _file="$2"
  if validate_invalid_deferred_ac "$_file"; then
    record_fail "$_name" "valid fixture unexpectedly matched invalid deferred AC shape"
  else
    record_ok "$_name"
  fi
}

expect_invalid_kind() {
  _name="$1"
  _kind="$2"
  _file="$3"
  case "$_kind" in
    deferred-ac)
      if validate_invalid_deferred_ac "$_file"; then
        record_ok "$_name"
      else
        record_fail "$_name" "invalid deferred fixture did not match expected invalid shape"
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
assert_contains "developer prompt references Task Boundary Contract" \
  "$_REPO_ROOT/.codex/agents/developer.md" 'Task Boundary Contract'
assert_contains "developer prompt treats Requirements tests as same-task work" \
  "$_REPO_ROOT/.codex/agents/developer.md" '必要 test は同 task 作業'
assert_contains "developer prompt excludes deferred coverage from current scope" \
  "$_REPO_ROOT/.codex/agents/developer.md" '後続 task に defer された coverage AC'
assert_contains "reviewer prompt limits missing test scope to current task" \
  "$_REPO_ROOT/.codex/agents/reviewer.md" 'missing test 判定対象.*当該 task の .*Requirements'
assert_contains "reviewer prompt does not reject deferred test task absence" \
  "$_REPO_ROOT/.codex/agents/reviewer.md" '後続 deferred test task の未実施'
assert_contains "README documents per-task missing test scope" \
  "$_REPO_ROOT/README.md" 'per-task review では .*missing test.* scope が当該 task の .*Requirements.* に限定'
assert_contains "README binds coverage AC to same-task test work" \
  "$_REPO_ROOT/README.md" 'coverage / failure / safety AC は同 task の test work と結び付ける'
assert_contains "README excludes deferred coverage AC from prior task" \
  "$_REPO_ROOT/README.md" '先行 task の .*Requirements.* から未実施 coverage AC を外し'
assert_contains "README keeps deferrable notation for deferred test tasks" \
  "$_REPO_ROOT/README.md" '.*- \[ \]\*.*deferred test task'

expect_valid "fixture same-task coverage is valid" \
  "same-task" "$_FIXTURE_DIR/tasks-same-task-coverage.md"
expect_valid_as_not_invalid "fixture same-task coverage is not invalid deferred AC" \
  "$_FIXTURE_DIR/tasks-same-task-coverage.md"
expect_valid "fixture deferred coverage is valid" \
  "deferred" "$_FIXTURE_DIR/tasks-deferred-coverage.md"
expect_valid_as_not_invalid "fixture deferred coverage is not invalid deferred AC" \
  "$_FIXTURE_DIR/tasks-deferred-coverage.md"
expect_invalid_kind "fixture invalid deferred AC shape is detected" \
  "deferred-ac" "$_FIXTURE_DIR/tasks-invalid-deferred-ac.md"
expect_invalid "fixture invalid deferred AC is rejected by deferred validator" \
  "deferred-ac" "$_FIXTURE_DIR/tasks-invalid-deferred-ac.md"
expect_invalid_as_same_task "fixture invalid deferred AC is not same-task valid" \
  "$_FIXTURE_DIR/tasks-invalid-deferred-ac.md"
expect_invalid_as_deferred "fixture invalid deferred AC is not deferred valid" \
  "$_FIXTURE_DIR/tasks-invalid-deferred-ac.md"

echo
echo "summary: pass=$_pass fail=$_fail total=$((_pass + _fail))"

if [ "$_fail" -gt 0 ]; then
  echo "failed cases: ${_failed_names[*]}" >&2
  exit 1
fi
exit 0
