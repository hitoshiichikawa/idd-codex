#!/usr/bin/env bash
#
# 用途: stale-pickup-reaper.sh の sr_check_session / sr_lockfile_is_held（Issue #180）を検証する。
#   slot lock file は永続配置されるため、「lock file が存在するが flock は解放済み・owner PID 不在」
#   を session 不在（rc=0）と判定できること、逆に lock が実際に保持されている / owner PID が生存
#   している場合は rc=1（claim を解除しない）を維持することを、Linux（flock + fuser）と
#   macOS（flock + lsof）の両経路で確認する。flock 不在時の pid-only fallback も検証する。
#
# 配置先: local-watcher/test/stale_pickup_reaper_session_test.sh
# 依存:   bash 4+, awk, flock(util-linux), mktemp, sleep
# 実行:   bash local-watcher/test/stale_pickup_reaper_session_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/stale-pickup-reaper.sh"
[ -f "$MODULE_SH" ] || { echo "ERROR: not found: $MODULE_SH" >&2; exit 2; }
command -v flock >/dev/null 2>&1 || { echo "SKIP: flock not available"; exit 0; }

extract_function() {
  local script="$1" fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}
for fn in sr_lockfile_is_held sr_check_session; do
  # shellcheck disable=SC1090
  eval "$(extract_function "$MODULE_SH" "$fn")"
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done

# ─── 環境 ───
TMPROOT="$(mktemp -d)"
HOLDER_PIDS=()
cleanup() {
  local p
  for p in "${HOLDER_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

REPO_SLUG="owner-repo"
SLOT_LOCK_DIR="$TMPROOT/locks"; mkdir -p "$SLOT_LOCK_DIR"
LOCK1="$SLOT_LOCK_DIR/${REPO_SLUG}-slot-1.lock"
LOCK2="$SLOT_LOCK_DIR/${REPO_SLUG}-slot-2.lock"
SHIM="$TMPROOT/shim"; mkdir -p "$SHIM"
# 必要最小限の実バイナリだけを symlink した PATH を作り、fuser / lsof / flock の「不在」を再現する。
SAFE_BIN="$TMPROOT/safebin"; mkdir -p "$SAFE_BIN"
for b in flock grep awk sed cat mktemp date sleep true rm seq chmod bash env pkill pgrep; do
  real=$(type -P "$b" 2>/dev/null || true)   # builtin（true 等）ではなく実バイナリを解決
  [ -n "$real" ] && ln -s "$real" "$SAFE_BIN/$b"
done
SAFE_BIN_NOFLOCK="$TMPROOT/safebin-noflock"; mkdir -p "$SAFE_BIN_NOFLOCK"
for b in grep awk sed cat mktemp date sleep true rm seq chmod bash env pkill pgrep; do
  real=$(type -P "$b" 2>/dev/null || true)
  [ -n "$real" ] && ln -s "$real" "$SAFE_BIN_NOFLOCK/$b"
done
ORIG_PATH="$PATH"
BASH_ABS="$(type -P bash)"

# pid tool stub: 環境変数 PIDTOOL_OUT の内容を出力する
FUSER_OUT_FILE="$TMPROOT/fuser.out"; LSOF_OUT_FILE="$TMPROOT/lsof.out"
: >"$FUSER_OUT_FILE"; : >"$LSOF_OUT_FILE"
make_shim() {  # $1 = tool name / $2 = out file
  # 制限 PATH 下でも起動できるよう bash は絶対パスで指定する
  cat >"$SHIM/$1" <<EOF
#!${BASH_ABS}
cat "$2"
exit 0
EOF
  chmod +x "$SHIM/$1"
}
use_tools() {  # 引数: 有効化する tool 名のリスト（空なら両方不在）。flock は SAFE_BIN 経由で常に有効
  rm -f "$SHIM/fuser" "$SHIM/lsof"
  local t
  for t in "$@"; do
    case "$t" in
      fuser) make_shim fuser "$FUSER_OUT_FILE" ;;
      lsof)  make_shim lsof  "$LSOF_OUT_FILE" ;;
    esac
  done
  PATH="$SHIM:$SAFE_BIN"
}
use_tools_noflock() {
  rm -f "$SHIM/fuser" "$SHIM/lsof"
  local t
  for t in "$@"; do
    case "$t" in
      fuser) make_shim fuser "$FUSER_OUT_FILE" ;;
      lsof)  make_shim lsof  "$LSOF_OUT_FILE" ;;
    esac
  done
  PATH="$SHIM:$SAFE_BIN_NOFLOCK"
}
restore_path() { PATH="$ORIG_PATH"; }

LAST_HOLDER=""
hold_lock() {  # $1 = lockfile。background で flock を握り続ける（pid は LAST_HOLDER に格納。$(...) で呼ばない）
  # stdout/stderr を切り離す: 呼び出し側の $(...) が background の fd を待ち続けないようにする
  "$SAFE_BIN/flock" -x "$1" "$SAFE_BIN/sleep" 30 >/dev/null 2>&1 &
  local p=$!
  HOLDER_PIDS+=("$p")
  # 取得完了を待つ（最大 ~2s）
  local _i
  LAST_HOLDER="$p"
  for _i in $("$SAFE_BIN/seq" 1 40); do
    if ! "$SAFE_BIN/flock" -n -x "$1" "$SAFE_BIN/true" 2>/dev/null; then return 0; fi
    "$SAFE_BIN/sleep" 0.05
  done
  return 0
}
release_all() {
  # flock は子プロセス（sleep）に lock fd を継承させるため、親だけ kill しても lock が残る。
  # 子 → 親の順に kill し、解放を観測してから戻る。
  local p c _i
  for p in "${HOLDER_PIDS[@]:-}"; do
    [ -n "$p" ] || continue
    for c in $("$SAFE_BIN/pgrep" -P "$p" 2>/dev/null || true); do kill -9 "$c" 2>/dev/null || true; done
    kill -9 "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
  HOLDER_PIDS=()
  for _i in $("$SAFE_BIN/seq" 1 40); do
    if "$SAFE_BIN/flock" -n -x "$LOCK1" "$SAFE_BIN/true" 2>/dev/null \
       && { [ ! -f "$LOCK2" ] || "$SAFE_BIN/flock" -n -x "$LOCK2" "$SAFE_BIN/true" 2>/dev/null; }; then
      return 0
    fi
    "$SAFE_BIN/sleep" 0.05
  done
  return 0
}
dead_pid() { ( : ) & local p=$!; wait "$p" 2>/dev/null || true; echo "$p"; }

PASS_COUNT=0; FAIL_COUNT=0
assert_eq() { local l="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l"; echo "  exp=$(printf '%q' "$e") act=$(printf '%q' "$a")"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }
rc_of() { local fn="$1"; shift; local r=0; "$fn" "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }

# ════════════════════════════════════════════════════════════════════════════
echo "--- 1. sr_lockfile_is_held ---"
: >"$LOCK1"
use_tools fuser
assert_eq "解放済み lock → 0" "0" "$(rc_of sr_lockfile_is_held "$LOCK1")"
hold_lock "$LOCK1"; HP="$LAST_HOLDER"
assert_eq "保持中 lock → 1" "1" "$(rc_of sr_lockfile_is_held "$LOCK1")"
release_all
assert_eq "解放後 → 0" "0" "$(rc_of sr_lockfile_is_held "$LOCK1")"
use_tools_noflock fuser
assert_eq "flock 不在 → 2（判定不能）" "2" "$(rc_of sr_lockfile_is_held "$LOCK1")"
restore_path

echo ""; echo "--- 2. sr_check_session: lock file 不在 ---"
rm -f "$LOCK1" "$LOCK2"
use_tools fuser
assert_eq "lock file 無し → 0(no session)" "0" "$(rc_of sr_check_session '{}')"
restore_path

echo ""; echo "--- 3. sr_check_session: 永続 lock file 存在 + 解放済み + owner PID 不在（#180 の本丸）---"
: >"$LOCK1"; : >"$LOCK2"
: >"$FUSER_OUT_FILE"; : >"$LSOF_OUT_FILE"
use_tools fuser
assert_eq "Linux(fuser) 経路: 解放済み + pid 無し → 0（旧実装は 1 で永久回収不能）" "0" "$(rc_of sr_check_session '{}')"
use_tools lsof
assert_eq "macOS(lsof) 経路: 解放済み + pid 無し → 0" "0" "$(rc_of sr_check_session '{}')"
use_tools
assert_eq "pid tool 不在でも解放済み → 0（flock 判定が先行）" "0" "$(rc_of sr_check_session '{}')"
restore_path

echo ""; echo "--- 4. sr_check_session: lock が実際に保持されている → 1（AC 4 / claim 解除しない）---"
hold_lock "$LOCK1"; HP="$LAST_HOLDER"
: >"$FUSER_OUT_FILE"; : >"$LSOF_OUT_FILE"
use_tools fuser
assert_eq "Linux: 保持中（fuser 空出力でも）→ 1" "1" "$(rc_of sr_check_session '{}')"
printf '%s\n' "$HP" >"$FUSER_OUT_FILE"
assert_eq "Linux: 保持中 + 生存 pid → 1" "1" "$(rc_of sr_check_session '{}')"
use_tools lsof
printf '%s\n' "$HP" >"$LSOF_OUT_FILE"
assert_eq "macOS: 保持中 + 生存 pid → 1" "1" "$(rc_of sr_check_session '{}')"
use_tools
assert_eq "保持中 + pid tool 不在 → 1（safe-side）" "1" "$(rc_of sr_check_session '{}')"
release_all
: >"$FUSER_OUT_FILE"; : >"$LSOF_OUT_FILE"
use_tools fuser
assert_eq "解放後は 0 に戻る（slot-2 は元々解放済み）" "0" "$(rc_of sr_check_session '{}')"
restore_path

echo ""; echo "--- 5. sr_check_session: flock 不在 → pid-only fallback（旧実装互換）---"
: >"$LOCK1"
use_tools_noflock fuser
: >"$FUSER_OUT_FILE"
assert_eq "flock 不在 + fuser 空 → 1（safe-side / 旧挙動）" "1" "$(rc_of sr_check_session '{}')"
printf '%s\n' "$$" >"$FUSER_OUT_FILE"
assert_eq "flock 不在 + 生存 pid → 1" "1" "$(rc_of sr_check_session '{}')"
DP=$(dead_pid)
printf '%s\n' "$DP" >"$FUSER_OUT_FILE"
assert_eq "flock 不在 + 非生存 pid のみ → 0" "0" "$(rc_of sr_check_session '{}')"
printf 'garbage\n' >"$FUSER_OUT_FILE"
assert_eq "flock 不在 + 非数値 pid のみ → 0（無視）" "0" "$(rc_of sr_check_session '{}')"
use_tools_noflock lsof
printf '%s\n' "$$" >"$LSOF_OUT_FILE"
assert_eq "flock 不在 + lsof 生存 pid → 1" "1" "$(rc_of sr_check_session '{}')"
use_tools_noflock
assert_eq "flock 不在 + pid tool 不在 → 1（safe-side）" "1" "$(rc_of sr_check_session '{}')"
restore_path

echo ""; echo "--- 6. 混在: slot-1 解放済み / slot-2 保持中 → 1 ---"
: >"$LOCK1"; : >"$LOCK2"
hold_lock "$LOCK2"; HP="$LAST_HOLDER"
use_tools fuser
printf '%s\n' "$HP" >"$FUSER_OUT_FILE"
assert_eq "いずれかの slot が保持中なら 1" "1" "$(rc_of sr_check_session '{}')"
release_all
restore_path

echo ""; echo "──────────────"
echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
echo "ALL GREEN"
