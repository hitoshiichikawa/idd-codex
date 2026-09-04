#!/usr/bin/env bash
#
# 用途: model-preflight.sh の version map / override / preflight gate を検証する。
# 配置先: local-watcher/test/model_preflight_test.sh
# 依存: bash 4+
# 実行: bash local-watcher/test/model_preflight_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_UTILS_SH="$SCRIPT_DIR/../bin/idd-codex-modules/core_utils.sh"
MODEL_PREFLIGHT_SH="$SCRIPT_DIR/../bin/idd-codex-modules/model-preflight.sh"

if [ ! -f "$CORE_UTILS_SH" ]; then
  echo "ERROR: cannot find core_utils.sh at $CORE_UTILS_SH" >&2
  exit 2
fi
if [ ! -f "$MODEL_PREFLIGHT_SH" ]; then
  echo "ERROR: cannot find model-preflight.sh at $MODEL_PREFLIGHT_SH" >&2
  exit 2
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/idd-codex-model-preflight-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

export REPO="owner/repo"
export CODEX_BIN="$TMP_DIR/codex-bin"
export MP_TEST_CALL_LOG="$TMP_DIR/codex-calls.log"

cat >"$CODEX_BIN" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MP_TEST_CALL_LOG:?}"
case "${STUB_CODEX_MODE:-ok}" in
  ok) printf 'codex-cli %s\n' "${STUB_CODEX_VERSION:-0.144.0}" ;;
  unparsable) printf 'codex-cli dev\n' ;;
  fail) printf 'codex failed to report version\n' >&2; exit 42 ;;
esac
STUB
chmod +x "$CODEX_BIN"

PASS_COUNT=0
FAIL_COUNT=0

# shellcheck source=../bin/idd-codex-modules/core_utils.sh
. "$CORE_UTILS_SH"
# shellcheck source=../bin/idd-codex-modules/model-preflight.sh
. "$MODEL_PREFLIGHT_SH"

reset_env() {
  unset MODEL_PREFLIGHT_ENABLED
  unset MODEL_PREFLIGHT_MIN_VERSIONS
  export STUB_CODEX_MODE="ok"
  export STUB_CODEX_VERSION="0.144.0"
  : >"$MP_TEST_CALL_LOG"
  mp_clear_last_config_error
}

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected: $expected"
    echo "  actual  : $actual"
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
      echo "  missing: $needle"
      echo "  actual : $haystack"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
  esac
}

assert_rc() {
  local label="$1"
  local expected="$2"
  shift 2
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $label (rc=$actual)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected rc: $expected"
    echo "  actual rc  : $actual"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

run_preflight_capture() {
  local stage="$1"
  local model="$2"
  local out_file="$3"
  local rc=0
  mp_preflight_model "$stage" "$model" >"$out_file.stdout" 2>"$out_file.stderr" || rc=$?
  printf '%s' "$rc" >"$out_file.rc"
}

reset_env
assert_eq "default map requires gpt-5.6 at 0.144.0" \
  "0.144.0" "$(mp_required_version_for_model "gpt-5.6-luna")"

reset_env
export MODEL_PREFLIGHT_MIN_VERSIONS="gpt-5.7-*:0.150.0"
assert_eq "override map replaces default map" \
  "" "$(mp_required_version_for_model "gpt-5.6-luna")"
assert_eq "override map matches configured model" \
  "0.150.0" "$(mp_required_version_for_model "gpt-5.7-sol")"

reset_env
warn_file="$TMP_DIR/malformed.warn"
export MODEL_PREFLIGHT_MIN_VERSIONS="broken,gpt-5.6-*:0.144.0,:0.1.0,gpt-x:dev"
required="$(mp_required_version_for_model "gpt-5.6-sol" 2>"$warn_file")"
assert_eq "malformed override keeps valid entries" "0.144.0" "$required"
warn_body="$(cat "$warn_file")"
assert_contains "malformed override logs WARN" "$warn_body" "model-preflight: WARN:"
assert_contains "malformed override log includes skipped entry" "$warn_body" "broken"
assert_contains "malformed invalid version is skipped" "$warn_body" "gpt-x:dev"

reset_env
export STUB_CODEX_VERSION="0.143.9"
capture="$TMP_DIR/insufficient"
run_preflight_capture "stage-a" "gpt-5.6-luna" "$capture"
assert_eq "known model insufficient version returns rc 78" "78" "$(cat "$capture.rc")"
insufficient_err="$(cat "$capture.stderr")"
assert_contains "insufficient log includes model" "$insufficient_err" "model=gpt-5.6-luna"
assert_contains "insufficient log includes current version" "$insufficient_err" "current=0.143.9"
assert_contains "insufficient log includes required version" "$insufficient_err" "required=0.144.0"
assert_contains "insufficient log includes update guidance" "$insufficient_err" "codex update"
assert_eq "insufficient preflight only calls codex --version" "--version" "$(cat "$MP_TEST_CALL_LOG")"

reset_env
capture="$TMP_DIR/unknown"
run_preflight_capture "stage-a" "gpt-5.9-typo" "$capture"
assert_eq "unknown model passes preflight" "0" "$(cat "$capture.rc")"
assert_eq "unknown model does not call codex --version" "" "$(cat "$MP_TEST_CALL_LOG")"

reset_env
export STUB_CODEX_MODE="unparsable"
capture="$TMP_DIR/unparsable"
run_preflight_capture "stage-a" "gpt-5.6-luna" "$capture"
assert_eq "known model unparsable codex version returns rc 78" "78" "$(cat "$capture.rc")"
assert_contains "unparsable log includes extraction reason" "$(cat "$capture.stderr")" "version-unparseable"

reset_env
export STUB_CODEX_MODE="fail"
capture="$TMP_DIR/version-command-failed"
run_preflight_capture "stage-a" "gpt-5.6-luna" "$capture"
assert_eq "known model codex version command failure returns rc 78" "78" "$(cat "$capture.rc")"
assert_contains "command failure log includes reason" "$(cat "$capture.stderr")" "codex-version-command-failed"

reset_env
export CODEX_BIN="$TMP_DIR/missing-codex"
capture="$TMP_DIR/codex-command-not-found"
run_preflight_capture "stage-a" "gpt-5.6-luna" "$capture"
assert_eq "known model missing codex command returns rc 78" "78" "$(cat "$capture.rc")"
assert_contains "command-not-found log includes reason" "$(cat "$capture.stderr")" "codex-command-not-found"
export CODEX_BIN="$TMP_DIR/codex-bin"

reset_env
export MODEL_PREFLIGHT_ENABLED="false"
export STUB_CODEX_MODE="fail"
capture="$TMP_DIR/disabled"
run_preflight_capture "stage-a" "gpt-5.6-luna" "$capture"
assert_eq "disabled preflight passes without codex version call" "0" "$(cat "$capture.rc")"
assert_eq "disabled preflight does not call codex" "" "$(cat "$MP_TEST_CALL_LOG")"

reset_env
export STUB_CODEX_VERSION="0.144.0-beta.1"
assert_rc "known model equal version with suffix passes" "0" \
  mp_preflight_model "stage-a" "gpt-5.6-terra"

reset_env
plain_model_error="$TMP_DIR/model-not-found.log"
printf '%s\n' "Error: model not found: gpt-5.4-old" > "$plain_model_error"
detect_out="$(mp_detect_model_error "gpt-5.4-old" "$plain_model_error")"
assert_contains "classifier detects model not found reason" "$detect_out" "model-not-found"
assert_contains "classifier output includes artifact path" "$detect_out" "$plain_model_error"

reset_env
stream_model_error="$TMP_DIR/unsupported-model.jsonl"
printf '%s\n' '{"type":"error","message":"Unsupported model: gpt-5.6-slo"}' > "$stream_model_error"
detect_out="$(mp_detect_model_error "gpt-5.6-slo" "$stream_model_error")"
assert_contains "classifier detects unsupported model from stream-json line" "$detect_out" "unsupported-model"

reset_env
account_model_error="$TMP_DIR/model-account.log"
printf '%s\n' "The selected model is not available for your account." > "$account_model_error"
detect_out="$(mp_detect_model_error "gpt-5.6-luna" "$account_model_error")"
assert_contains "classifier detects account availability model error" "$detect_out" "model-not-available-for-account"

reset_env
normal_error="$TMP_DIR/normal-error.log"
printf '%s\n' "regular tool failure" > "$normal_error"
rc=0
mp_detect_model_error "gpt-5.5" "$normal_error" >/dev/null 2>&1 || rc=$?
assert_eq "classifier does not classify normal errors" "1" "$rc"

reset_env
missing_artifact="$TMP_DIR/missing-artifact.log"
rc=0
mp_detect_model_error "gpt-5.5" "$missing_artifact" >/dev/null 2>&1 || rc=$?
assert_eq "classifier reports unreadable artifacts separately" "2" "$rc"

reset_env
mp_record_config_error "post-run" "StageA" "gpt-5.4-old" "model-not-found" "$plain_model_error"
summary="$(mp_build_last_config_error_summary)"
assert_contains "config summary states setting error possibility" "$summary" "モデル設定エラーの可能性"
assert_contains "config summary includes failing model" "$summary" "gpt-5.4-old"
assert_contains "config summary includes recovery guidance" "$summary" "codex update"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
