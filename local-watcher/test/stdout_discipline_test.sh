#!/usr/bin/env bash
#
# 用途: dispatcher / promote-pipeline の machine-readable stdout に human-readable
#       log が混入しないことを検証する。Issue #11 回帰テスト。
#
# 配置先: local-watcher/test/stdout_discipline_test.sh
# 依存:   bash 4+, jq
# 実行:   bash local-watcher/test/stdout_discipline_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/../bin"
WATCHER_SH="$BIN_DIR/idd-codex-issue-watcher.sh"
CORE_UTILS_SH="$BIN_DIR/modules/core_utils.sh"
PROMOTE_PIPELINE_SH="$BIN_DIR/modules/promote-pipeline.sh"

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
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
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -Fq -- "$needle"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  needle: $(printf '%q' "$needle")"
    echo "  in    : $(printf '%q' "$haystack")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -Fq -- "$needle"; then
    echo "FAIL: $label"
    echo "  unexpected needle: $(printf '%q' "$needle")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

assert_ok() {
  local label="$1"
  shift
  if "$@"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

echo "--- dispatcher stdout discipline simulation ---"

PARALLEL_SLOTS=4
declare -a _DISPATCHER_SLOT_PIDS=()

dispatcher_log() {
  echo "[2026-06-08 22:14:24] dispatcher: $*"
}

dispatcher_error() {
  echo "[2026-06-08 22:14:24] dispatcher: ERROR: $*" >&2
}

_dispatcher_reap_finished_slots() {
  dispatcher_log "slot-1: completed (pid=12345)"
}

_slot_acquire() {
  [ "$1" = "1" ]
}

_dispatcher_find_free_slot() {
  _dispatcher_reap_finished_slots >&2
  local n
  for ((n=1; n<=PARALLEL_SLOTS; n++)); do
    if [ -n "${_DISPATCHER_SLOT_PIDS[$n]:-}" ]; then
      continue
    fi
    if _slot_acquire "$n"; then
      echo "$n"
      return 0
    fi
  done
  return 1
}

_dispatcher_validate_slot_id() {
  local slot="$1"
  if [[ ! "$slot" =~ ^[1-9][0-9]*$ ]]; then
    dispatcher_error "invalid slot id detected before dispatch: '${slot//$'\n'/\\n}'"
    return 1
  fi
  if [ "$slot" -gt "$PARALLEL_SLOTS" ]; then
    dispatcher_error "slot id out of range before dispatch: '$slot' (PARALLEL_SLOTS=$PARALLEL_SLOTS)"
    return 1
  fi
  return 0
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

dispatcher_err="$TMPROOT/dispatcher.err"
slot="$(_dispatcher_find_free_slot 2>"$dispatcher_err")"
assert_eq "completion log is not captured in slot return value" "1" "$slot"
assert_contains "completion log remains observable on stderr" \
  "dispatcher: slot-1: completed" "$(cat "$dispatcher_err")"
assert_ok "clean slot id validates" _dispatcher_validate_slot_id "$slot"

invalid_slot=$'[2026-06-08 22:14:24] dispatcher: slot-1: completed (pid=12345)\n1'
if _dispatcher_validate_slot_id "$invalid_slot" 2>"$TMPROOT/invalid.err"; then
  echo "FAIL: contaminated slot id is rejected"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "PASS: contaminated slot id is rejected"
  PASS_COUNT=$((PASS_COUNT + 1))
fi
assert_contains "invalid slot error is observable" \
  "invalid slot id detected before dispatch" "$(cat "$TMPROOT/invalid.err")"

assert_contains "watcher redirects reap logs away from slot stdout" \
  "_dispatcher_reap_finished_slots >&2" "$(sed -n '/_dispatcher_find_free_slot()/,/^}/p' "$WATCHER_SH")"
assert_contains "watcher validates slot before worker dispatch" \
  "_dispatcher_validate_slot_id \"\$slot\"" "$(sed -n '/空き slot 探索/,/Slot Runner をバックグラウンド起動/p' "$WATCHER_SH")"

echo "--- promote-pipeline stdout discipline (real function with fake gh) ---"

FAKEBIN="$TMPROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  printf '%s\n' '[{"number":101,"headRepositoryOwner":{"login":"owner"},"closingIssuesReferences":[{"number":18}]}]'
  exit 0
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  printf '%s\n' '{"labels":[]}'
  exit 0
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "edit" ]; then
  exit 0
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  printf '%s\n' '18'
  printf '%s\n' '14'
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 99
EOF
chmod +x "$FAKEBIN/gh"

cat > "$FAKEBIN/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
shift
exec "$@"
EOF
chmod +x "$FAKEBIN/timeout"

export PATH="$FAKEBIN:$PATH"
export REPO="owner/repo"
export BASE_BRANCH="develop"
export PROMOTE_GIT_TIMEOUT="60"
export LABEL_STAGED_FOR_RELEASE="codex-staged-for-release"

# shellcheck source=/dev/null
source "$CORE_UTILS_SH"
# shellcheck source=/dev/null
source "$PROMOTE_PIPELINE_SH"

promote_err="$TMPROOT/promote.err"
promote_out="$(pp_collect_merged_issues 2>"$promote_err")"

assert_eq "promote issue-number stdout remains machine-readable" \
  $'18\n14' "$promote_out"
assert_not_contains "promote issue-number stdout excludes log prefix" \
  "promote-pipeline:" "$promote_out"
assert_contains "promote auto-label log remains observable on stderr" \
  "auto-label サマリ" "$(cat "$promote_err")"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
