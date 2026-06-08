#!/usr/bin/env bash
#
# 本テストの対象は idd-codex-issue-watcher.sh の pt_extract_pending_tasks（#194 で導入、#251 で
# stage_checkpoint_resolve_resume_point の Stage A skip 判定にも再利用）。
# #251 の修正は「resolve が Stage B へ skip する前に pt_extract_pending_tasks で残必須
# タスクを確認し、残っていれば Stage A を再開する」ものなので、その判定入力である
# pt_extract_pending_tasks が次を満たすことを fixture で固定する:
#   - 親タスク完了 + 子/後続タスク未完（#239 の 1/8 状態）→ 残タスクを非空で返す（= Stage A 再開側）
#   - 全タスク完了 → 空（= 従来どおり Stage B skip 側）
#   - deferrable（`- [ ]*`）のみ残存 → 空（必須ではないので Stage A 再開しない）
#
# 配置先: local-watcher/test/stage_checkpoint_pending_tasks_test.sh
# 依存:   bash 4+, awk/grep/sed/sort
# 実行:   bash local-watcher/test/stage_checkpoint_pending_tasks_test.sh
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

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_extract_pending_tasks")"

if ! declare -F pt_extract_pending_tasks >/dev/null; then
  echo "ERROR: pt_extract_pending_tasks not loaded" >&2
  exit 2
fi

PASS=0
FAIL=0
assert_nonempty() {
  local out="$1" label="$2"
  if [ -n "$out" ]; then echo "  ok: ${label}（残=$(printf '%s' "$out" | tr '\n' ' ')）"; PASS=$((PASS+1));
  else echo "  NG: ${label}（空でない想定だが空）" >&2; FAIL=$((FAIL+1)); fi
}
assert_empty() {
  local out="$1" label="$2"
  if [ -z "$out" ]; then echo "  ok: ${label}（残なし）"; PASS=$((PASS+1));
  else echo "  NG: ${label}（空想定だが残=$(printf '%s' "$out" | tr '\n' ' ')）" >&2; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── ケース 1: task 1 完了 + 後続未完（#239 の 1/8 状態）→ 残あり（Stage A 再開側）──
cat > "$TMP/partial.md" <<'EOF'
- [x] 1. run-summary.sh モジュールの新規作成
- [x] 1.1 骨格
- [ ] 2. 本体への source 追加
- [ ] 3. mode 記録差し込み
- [ ]* 8.1 追加の deferrable テスト
EOF
echo "[case1] 親完了 + 後続必須未完（#239 相当）→ 残必須タスクあり"
assert_nonempty "$(pt_extract_pending_tasks "$TMP/partial.md")" "残必須タスクを検出（Stage A 再開）"

# ── ケース 2: 全タスク完了 → 空（従来どおり Stage B skip 側）──
cat > "$TMP/done.md" <<'EOF'
- [x] 1. モジュール作成
- [x] 1.1 骨格
- [x] 2. 配線
- [ ]* 3.1 deferrable テスト
EOF
echo "[case2] 全必須完了（deferrable のみ残）→ 残必須なし（Stage B skip 維持）"
assert_empty "$(pt_extract_pending_tasks "$TMP/done.md")" "全必須完了で空"

# ── ケース 3: deferrable（- [ ]*）のみ残存 → 空（必須扱いしない）──
cat > "$TMP/deferrable.md" <<'EOF'
- [x] 1. 実装
- [ ]* 2. 統合テスト追加（deferrable）
- [ ]* 3. 追加の fixture（deferrable）
EOF
echo "[case3] deferrable のみ残存 → 残必須なし"
assert_empty "$(pt_extract_pending_tasks "$TMP/deferrable.md")" "deferrable は pending に数えない"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then echo "RESULT: FAIL" >&2; exit 1; fi
echo "RESULT: PASS"
