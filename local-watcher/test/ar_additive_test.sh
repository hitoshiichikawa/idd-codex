#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-modules/auto-rebase.sh の #147（bootstrap 加算的
#       衝突緩和）で追加した:
#         - 純粋判定関数 ar_classify_additive（gate ON 時の二次判定）
#         - ar_classify_diff への二次判定フック（gate ON 加算的成立で mechanical 昇格）
#       を diff fixture で検証するスモークテスト。
#
#       検証する観点:
#         - gate OFF で従来判定（二次判定を呼ばない / no-op）
#         - bootstrap allowlist 空で二次判定 skip
#         - 全 path 閉 + 全 hunk 追加のみ → additive(=mechanical)
#         - 削除/変更 hunk を含むと not-additive（semantic 側）
#         - allowlist 外 path 混在で not-additive
#         - git diff 取得失敗で not-additive + return 1（保守的）
#         - additive 判定時に根拠ログを発火
#         - ar_classify_diff の結線（従来 semantic / MECHANICAL_PATHS 全一致 mechanical /
#           gate ON 加算的成立 mechanical 昇格）
#
# 配置先: local-watcher/test/ar_additive_test.sh
# 依存:   bash 4+, awk, grep, sed, mktemp
# 実行:   bash local-watcher/test/ar_additive_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/idd-codex-modules/auto-rebase.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find auto-rebase.sh at $MODULE_SH" >&2
  exit 2
fi

# 既存テスト（auto_rebase_semantic_test.sh）と同じイディオム: 対象スクリプトから
# 1 関数だけを awk で切り出して eval で読み込む。
extract_function() {
  local script="$1" fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# ar_classify_diff は内部で ar_classify_additive を呼ぶため、隔離抽出の特性上
# 依存関数も明示 source する必要がある。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "ar_classify_additive")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "ar_classify_diff")"

for fn in ar_classify_additive ar_classify_diff; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# ─── fixture 生成（自己完結: 一時ディレクトリに diff / names を書き出す） ───
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR" "$AR_LOG_TRACE"' EXIT

cat > "$FIXTURE_DIR/diff-add-only.txt" <<'EOF'
diff --git a/cmd/api/main.go b/cmd/api/main.go
index 1111111..2222222 100644
--- a/cmd/api/main.go
+++ b/cmd/api/main.go
@@ -10,6 +10,8 @@ import (
 	"example.com/app/internal/user"
 	"example.com/app/internal/order"
+	"example.com/app/internal/billing"
+	"example.com/app/internal/notify"
 )

 func main() {
@@ -30,4 +32,6 @@ func main() {
 	user.Mount(router)
 	order.Mount(router)
+	billing.Mount(router)
+	notify.Mount(router)
 }
EOF

cat > "$FIXTURE_DIR/diff-with-deletion.txt" <<'EOF'
diff --git a/cmd/api/main.go b/cmd/api/main.go
index 1111111..3333333 100644
--- a/cmd/api/main.go
+++ b/cmd/api/main.go
@@ -10,7 +10,7 @@ import (
 	"example.com/app/internal/user"
-	"example.com/app/internal/order"
+	"example.com/app/internal/billing"
 )

 func main() {
@@ -30,4 +30,5 @@ func main() {
 	user.Mount(router)
 	order.Mount(router)
+	billing.Mount(router)
 }
EOF

printf 'cmd/api/main.go\n' > "$FIXTURE_DIR/names-add-only.txt"
printf 'cmd/api/main.go\ninternal/user/service.go\n' > "$FIXTURE_DIR/names-path-out.txt"

# ─── stub: env / ロガー / git / timeout ───
# shellcheck disable=SC2034
AUTO_REBASE_GIT_TIMEOUT=60

# ar_log の発火を記録する stub（実体は core_utils.sh）。
AR_LOG_TRACE="$(mktemp)"
# shellcheck disable=SC2317
ar_log() {
  echo "$*" >> "$AR_LOG_TRACE"
}

# git stub の挙動を制御するグローバル:
#   GIT_NAMES_FIXTURE  : `git diff --name-only` が返すファイル（空なら空出力）
#   GIT_DIFF_FIXTURE   : `git diff`（unified）が返すファイル（空なら空出力）
#   GIT_NAMES_RC       : `git diff --name-only` の exit code
#   GIT_DIFF_RC        : `git diff`（unified）の exit code
GIT_NAMES_FIXTURE=""
GIT_DIFF_FIXTURE=""
GIT_NAMES_RC=0
GIT_DIFF_RC=0

# timeout stub: 第 1 引数（秒数）を捨てて残りを実行する。
# shellcheck disable=SC2317
timeout() { shift; "$@"; }

# git stub: --name-only の有無で 2 種類の呼び出しを分岐する。
# shellcheck disable=SC2317
git() {
  if [ "${1:-}" != "diff" ]; then
    return 0
  fi
  local is_name_only=false arg
  for arg in "$@"; do
    [ "$arg" = "--name-only" ] && is_name_only=true
  done
  if [ "$is_name_only" = "true" ]; then
    if [ -n "$GIT_NAMES_FIXTURE" ] && [ -f "$GIT_NAMES_FIXTURE" ]; then
      cat "$GIT_NAMES_FIXTURE"
    fi
    return "$GIT_NAMES_RC"
  fi
  if [ -n "$GIT_DIFF_FIXTURE" ] && [ -f "$GIT_DIFF_FIXTURE" ]; then
    cat "$GIT_DIFF_FIXTURE"
  fi
  return "$GIT_DIFF_RC"
}

reset_git_stub() {
  GIT_NAMES_FIXTURE=""
  GIT_DIFF_FIXTURE=""
  GIT_NAMES_RC=0
  GIT_DIFF_RC=0
  : > "$AR_LOG_TRACE"
}

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
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

# 1 行目 / 2 行目を取り出すヘルパ（呼び出しと rc を捕捉）。
LAST_RC=0
LINE1=""
LINE2=""
run_additive() {
  local out rc=0
  out=$(ar_classify_additive "$@") || rc=$?
  LAST_RC="$rc"
  LINE1=$(printf '%s\n' "$out" | sed -n '1p')
  LINE2=$(printf '%s\n' "$out" | sed -n '2p')
}

log_has() {
  grep -qE "$1" "$AR_LOG_TRACE"
}

# ============================================================
# Section 1: ar_classify_additive — 判定（純粋関数）
#   gate-off / paths-empty / additive / non-additive-hunk / path-out / diff-failed
# ============================================================
echo "--- Section 1: ar_classify_additive の判定（純粋関数） ---"

# 1.1: gate OFF → not-additive / gate-off、ログ未発火（no-op）
reset_git_stub
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_ENABLED="false"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_PATHS="cmd/api/main.go"
run_additive 100 "main" "codex/feat-x"
assert_eq "gate OFF で 1 行目 not-additive" "not-additive" "$LINE1"
assert_eq "gate OFF で理由 gate-off" "gate-off" "$LINE2"
assert_eq "gate OFF で return 0" "0" "$LAST_RC"
if log_has "."; then
  echo "FAIL: gate OFF で ar_log を呼ばない (no-op)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "PASS: gate OFF で ar_log を呼ばない (no-op)"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

# 1.1b: gate 不正値（TRUE / on / typo / 空）も OFF 同等（Config 正規化前提 + 関数内 fallback）
for v in "TRUE" "on" "off" "" "additive"; do
  reset_git_stub
  # shellcheck disable=SC2034
  AUTO_REBASE_ADDITIVE_ENABLED="$v"
  # shellcheck disable=SC2034
  AUTO_REBASE_ADDITIVE_PATHS="cmd/api/main.go"
  run_additive 100 "main" "codex/feat-x"
  assert_eq "AUTO_REBASE_ADDITIVE_ENABLED=$(printf '%q' "$v") は gate-off 扱い" "gate-off" "$LINE2"
done

# 1.2: gate ON + paths 空 → not-additive / paths-empty
reset_git_stub
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_ENABLED="true"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_PATHS=""
run_additive 101 "main" "codex/feat-x"
assert_eq "paths 空で 1 行目 not-additive" "not-additive" "$LINE1"
assert_eq "paths 空で理由 paths-empty" "paths-empty" "$LINE2"
assert_eq "paths 空で return 0" "0" "$LAST_RC"

# 1.3: gate ON + 全 path 閉 + 追加のみ → additive + 根拠ログ
reset_git_stub
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_ENABLED="true"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_PATHS="cmd/api/main.go,internal/**"
GIT_NAMES_FIXTURE="$FIXTURE_DIR/names-add-only.txt"
GIT_DIFF_FIXTURE="$FIXTURE_DIR/diff-add-only.txt"
run_additive 102 "main" "codex/feat-x"
assert_eq "追加のみで 1 行目 additive" "additive" "$LINE1"
assert_eq "additive 時 2 行目なし" "" "$LINE2"
assert_eq "additive で return 0" "0" "$LAST_RC"
if log_has "additive=additive"; then
  echo "PASS: additive 判定で根拠ログを発火"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: additive 判定で根拠ログを発火"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
if log_has "paths=cmd/api/main.go"; then
  echo "PASS: 根拠ログに対象 path を含む"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: 根拠ログに対象 path を含む"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# 1.4: 削除行を含む hunk → not-additive / non-additive-hunk
reset_git_stub
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_ENABLED="true"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_PATHS="cmd/api/main.go"
GIT_NAMES_FIXTURE="$FIXTURE_DIR/names-add-only.txt"
GIT_DIFF_FIXTURE="$FIXTURE_DIR/diff-with-deletion.txt"
run_additive 103 "main" "codex/feat-x"
assert_eq "削除行含みで 1 行目 not-additive" "not-additive" "$LINE1"
assert_eq "理由 non-additive-hunk" "non-additive-hunk" "$LINE2"
assert_eq "削除行含みで return 0" "0" "$LAST_RC"

# 1.5: allowlist 外 path 混在 → not-additive / path-out
reset_git_stub
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_ENABLED="true"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_PATHS="cmd/api/main.go"
GIT_NAMES_FIXTURE="$FIXTURE_DIR/names-path-out.txt"
GIT_DIFF_FIXTURE="$FIXTURE_DIR/diff-add-only.txt"
run_additive 104 "main" "codex/feat-x"
assert_eq "allowlist 外混在で 1 行目 not-additive" "not-additive" "$LINE1"
assert_eq "理由 path-out" "path-out" "$LINE2"
assert_eq "allowlist 外混在で return 0" "0" "$LAST_RC"

# 1.6: git diff 取得失敗 → not-additive / diff-failed + return 1
# (a) --name-only が非0 exit
reset_git_stub
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_ENABLED="true"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_PATHS="cmd/api/main.go"
GIT_NAMES_RC=1
run_additive 105 "main" "codex/feat-x"
assert_eq "--name-only 失敗で 1 行目 not-additive" "not-additive" "$LINE1"
assert_eq "理由 diff-failed" "diff-failed" "$LINE2"
assert_eq "--name-only 失敗で return 1" "1" "$LAST_RC"

# (b) unified diff が非0 exit（path 照合は通過後に失敗）
reset_git_stub
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_ENABLED="true"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_PATHS="cmd/api/main.go"
GIT_NAMES_FIXTURE="$FIXTURE_DIR/names-add-only.txt"
GIT_DIFF_RC=1
run_additive 106 "main" "codex/feat-x"
assert_eq "unified diff 失敗で 1 行目 not-additive" "not-additive" "$LINE1"
assert_eq "理由 diff-failed" "diff-failed" "$LINE2"
assert_eq "unified diff 失敗で return 1" "1" "$LAST_RC"

# ============================================================
# Section 2: ar_classify_diff への二次判定フック（結線）
#   gate OFF 従来 semantic / MECHANICAL_PATHS 全一致 mechanical /
#   gate ON 加算的成立 mechanical 昇格
# ============================================================
echo ""
echo "--- Section 2: ar_classify_diff の二次判定フック（結線） ---"

run_classify() {
  local out rc=0
  out=$(ar_classify_diff "$@") || rc=$?
  LAST_RC="$rc"
  LINE1=$(printf '%s\n' "$out" | sed -n '1p')
  LINE2=$(printf '%s\n' "$out" | sed -n '2p')
}

# 2.1: gate OFF + path 逸脱 → 従来 semantic（導入前と等価 / no-op）
reset_git_stub
# shellcheck disable=SC2034
MECHANICAL_PATHS="package-lock.json"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_ENABLED="false"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_PATHS="cmd/api/main.go"
GIT_NAMES_FIXTURE="$FIXTURE_DIR/names-add-only.txt"
GIT_DIFF_FIXTURE="$FIXTURE_DIR/diff-add-only.txt"
run_classify 200 "main" "codex/feat-x"
assert_eq "gate OFF + path 逸脱で従来 semantic" "semantic" "$LINE1"
assert_eq "gate OFF で unmatched path を 2 行目に出す" "cmd/api/main.go" "$LINE2"

# 2.2: gate ON でも MECHANICAL_PATHS 全一致なら従来 mechanical（二次判定経由せず）
reset_git_stub
# shellcheck disable=SC2034
MECHANICAL_PATHS="cmd/api/main.go"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_ENABLED="true"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_PATHS="cmd/api/main.go"
GIT_NAMES_FIXTURE="$FIXTURE_DIR/names-add-only.txt"
GIT_DIFF_FIXTURE="$FIXTURE_DIR/diff-add-only.txt"
run_classify 201 "main" "codex/feat-x"
assert_eq "MECHANICAL_PATHS 全一致で従来 mechanical（二次判定経由せず）" "mechanical" "$LINE1"
assert_eq "MECHANICAL_PATHS 全一致で 2 行目なし" "" "$LINE2"

# 2.3: gate ON + MECHANICAL_PATHS 逸脱 + 加算的成立 → mechanical 昇格
reset_git_stub
# shellcheck disable=SC2034
MECHANICAL_PATHS="package-lock.json"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_ENABLED="true"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_PATHS="cmd/api/main.go"
GIT_NAMES_FIXTURE="$FIXTURE_DIR/names-add-only.txt"
GIT_DIFF_FIXTURE="$FIXTURE_DIR/diff-add-only.txt"
run_classify 202 "main" "codex/feat-x"
assert_eq "gate ON 加算的成立で mechanical 昇格" "mechanical" "$LINE1"
assert_eq "加算的昇格時 2 行目なし（mechanical stdout 契約）" "" "$LINE2"

# 2.4: gate ON + MECHANICAL_PATHS 逸脱 + 削除行含み → semantic 維持
reset_git_stub
# shellcheck disable=SC2034
MECHANICAL_PATHS="package-lock.json"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_ENABLED="true"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_PATHS="cmd/api/main.go"
GIT_NAMES_FIXTURE="$FIXTURE_DIR/names-add-only.txt"
GIT_DIFF_FIXTURE="$FIXTURE_DIR/diff-with-deletion.txt"
run_classify 203 "main" "codex/feat-x"
assert_eq "gate ON でも削除行含みは semantic 維持" "semantic" "$LINE1"
assert_eq "semantic 維持時 unmatched path を 2 行目に出す" "cmd/api/main.go" "$LINE2"

# 2.5: gate ON + MECHANICAL_PATHS 逸脱 + bootstrap allowlist 外 path → semantic
reset_git_stub
# shellcheck disable=SC2034
MECHANICAL_PATHS="package-lock.json"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_ENABLED="true"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_PATHS="cmd/api/main.go"
GIT_NAMES_FIXTURE="$FIXTURE_DIR/names-path-out.txt"
GIT_DIFF_FIXTURE="$FIXTURE_DIR/diff-add-only.txt"
run_classify 204 "main" "codex/feat-x"
assert_eq "bootstrap allowlist 外 path で semantic 維持" "semantic" "$LINE1"

# ============================================================
# Summary
# ============================================================
echo ""
echo "=================================================="
echo "RESULT: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
echo "=================================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
