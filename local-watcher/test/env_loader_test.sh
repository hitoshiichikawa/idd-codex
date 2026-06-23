#!/usr/bin/env bash
#
# 用途: env-loader.sh（idd-claude #386/F8 移植）を検証する。env ファイルの解決順
#       （WATCHER_ENV_FILE / 規約パス / 相対パス拒否 / 候補なし）/ 1 行パース（空行・
#       コメント・構文不正 skip）/ **precedence（inline cron env > env ファイル）** /
#       値評価（$HOME/$(...)展開・コマンド置換失敗の安全停止）/ **値を warn に出さない**
#       / el_load の silent no-op を stub で確認する。
#
# 配置先: local-watcher/test/env_loader_test.sh
# 依存:   bash 4+, awk, mktemp
# 実行:   bash local-watcher/test/env_loader_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/env-loader.sh"
[ -f "$MODULE_SH" ] || { echo "ERROR: not found: $MODULE_SH" >&2; exit 2; }

extract_function() {
  local script="$1" fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

for fn in el_log el_warn el_resolve_env_file el_apply_env_file el_load; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$MODULE_SH" "$fn")"
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done

REPO="owner/repo"; REPO_SLUG="owner-repo"
WARN_LOG=""
# el_warn を捕捉用に上書き（VALUE 非出力の検証で使う）。el_log は stdout 観測のため実体維持。
el_warn() { printf '%s\n' "$*" >>"$WARN_LOG"; }

reset_state() { WARN_LOG="$(mktemp)"; }
warn_text() { cat "$WARN_LOG" 2>/dev/null || true; }

PASS_COUNT=0; FAIL_COUNT=0
assert_eq() { local l="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1)); else echo "FAIL: $l"; echo "  exp=$(printf '%q' "$e") act=$(printf '%q' "$a")"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }
assert_not_contains() { local l="$1" h="$2" n="$3"; case "$h" in *"$n"*) echo "FAIL: $l ('$n' が出力された)"; FAIL_COUNT=$((FAIL_COUNT+1));; *) echo "PASS: $l"; PASS_COUNT=$((PASS_COUNT+1));; esac; }
rc_of() { local fn="$1"; shift; local r=0; "$fn" "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }

# ════════════════════════════════════════════════════════════════════════════
echo "--- 1. el_resolve_env_file（探索順 / 相対拒否 / 候補なし）---"
TMPHOME="$(mktemp -d)"; HOME="$TMPHOME"
EXPLICIT="$(mktemp)"; printf 'X=1\n' > "$EXPLICIT"
WATCHER_ENV_FILE="$EXPLICIT"
assert_eq "WATCHER_ENV_FILE(絶対) → 採用" "$EXPLICIT" "$(el_resolve_env_file)"
WATCHER_ENV_FILE="relative/path.env"
# 相対パス → 拒否 → 規約パスも無ければ rc1
assert_eq "相対 WATCHER_ENV_FILE → 拒否(rc1)" "1" "$(rc_of el_resolve_env_file)"
# 規約パス
unset WATCHER_ENV_FILE
mkdir -p "$TMPHOME/.idd-codex"; CONV="$TMPHOME/.idd-codex/owner-repo.env"; printf 'Y=2\n' > "$CONV"
assert_eq "規約パス \$HOME/.idd-codex/<slug>.env → 採用" "$CONV" "$(el_resolve_env_file)"
rm -f "$CONV"
assert_eq "候補なし → rc 1" "1" "$(rc_of el_resolve_env_file)"

echo ""; echo "--- 2. el_apply_env_file（パース / precedence / 値評価）---"
reset_state
ENVF="$(mktemp)"
cat > "$ENVF" <<'EOF'
# comment line
AUTO_MERGE_ENABLED=true

  FAILED_RECOVERY_MAX_ATTEMPTS=7
HOMEY=$HOME/sub
SUBST=$(echo computed)
bad line no equals
ALREADY_SET=fromfile
EOF
unset AUTO_MERGE_ENABLED FAILED_RECOVERY_MAX_ATTEMPTS HOMEY SUBST 2>/dev/null || true
ALREADY_SET="frominline"   # inline cron env を模倣（precedence で勝つべき）
HOME="/tmp/fakehome"
el_apply_env_file "$ENVF" >/dev/null 2>&1
assert_eq "通常 KEY=VALUE export" "true" "${AUTO_MERGE_ENABLED:-UNSET}"
assert_eq "先頭空白 trim + export" "7" "${FAILED_RECOVERY_MAX_ATTEMPTS:-UNSET}"
assert_eq "\$HOME 展開" "/tmp/fakehome/sub" "${HOMEY:-UNSET}"
assert_eq "\$(...) コマンド置換展開" "computed" "${SUBST:-UNSET}"
assert_eq "precedence: 既設定 KEY は不上書き" "frominline" "${ALREADY_SET:-UNSET}"
assert_eq "構文不正行 warn 1 件" "1" "$(grep -c '構文不正行 skip' "$WARN_LOG" || true)"
unset AUTO_MERGE_ENABLED FAILED_RECOVERY_MAX_ATTEMPTS HOMEY SUBST ALREADY_SET 2>/dev/null || true

echo ""; echo "--- 3. コマンド置換失敗 → 安全停止 + 値を warn に出さない ---"
reset_state
ENVF2="$(mktemp)"
printf 'BADK=$(this_cmd_does_not_exist_zzz SECRETVAL123)\n' > "$ENVF2"
unset BADK 2>/dev/null || true
el_apply_env_file "$ENVF2" >/dev/null 2>&1
assert_eq "置換失敗 → KEY 未設定のまま" "UNSET" "${BADK:-UNSET}"
assert_eq "置換失敗 → warn 1 件" "1" "$(grep -c '値評価に失敗' "$WARN_LOG" || true)"
assert_not_contains "warn に VALUE(機密候補)を出さない" "$(warn_text)" "SECRETVAL123"

echo ""; echo "--- 4. el_load（候補なし silent / 採用時ログ）---"
reset_state
TMPHOME2="$(mktemp -d)"; HOME="$TMPHOME2"; unset WATCHER_ENV_FILE 2>/dev/null || true
OUT=$(el_load 2>&1)
assert_eq "候補なし → rc 0 / 出力なし(silent)" "" "$OUT"
# 採用時: 規約パスを置いてログ 1 行（値は出さない）。
# el_load は export を現在シェルへ伝播させたいので $(...) サブシェルではなく redirect で捕捉。
mkdir -p "$TMPHOME2/.idd-codex"; printf 'SLACK_WEBHOOK_URL=https://hooks.test/SECRETXYZ\n' > "$TMPHOME2/.idd-codex/owner-repo.env"
unset SLACK_WEBHOOK_URL 2>/dev/null || true
OUT_FILE="$(mktemp)"; el_load > "$OUT_FILE" 2>&1; OUT="$(cat "$OUT_FILE")"
case "$OUT" in *"env ファイル採用"*) echo "PASS: 採用時にパスを 1 行ログ"; PASS_COUNT=$((PASS_COUNT+1));; *) echo "FAIL: 採用ログ不在"; FAIL_COUNT=$((FAIL_COUNT+1));; esac
assert_not_contains "採用ログに値(webhook)を出さない" "$OUT" "SECRETXYZ"
assert_eq "採用時に env 値が export される" "https://hooks.test/SECRETXYZ" "${SLACK_WEBHOOK_URL:-UNSET}"
unset SLACK_WEBHOOK_URL 2>/dev/null || true

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
