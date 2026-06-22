#!/usr/bin/env bash
#
# 用途: per-task ループの「人間判断待ち」ルーティングを検証する。
#   - detect_needs_decision_marker: impl-notes.md の `NEEDS_DECISION:` 行を抽出
#   - pt_mark_no_progress_failed: NEEDS_DECISION marker があれば codex-needs-decisions、
#     無ければ従来どおり codex-failed にルートする
# 実行: bash local-watcher/test/per_task_needs_decision_test.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
[ -f "$WATCHER_SH" ] || { echo "ERROR: watcher not found" >&2; exit 2; }

extract_function() {
  awk -v fn="${2}() {" '$0==fn{i=1} i{print} i&&$0=="}"{i=0}' "$1"
}
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "detect_needs_decision_marker")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "pt_mark_no_progress_failed")"
for fn in detect_needs_decision_marker pt_mark_no_progress_failed; do
  declare -F "$fn" >/dev/null || { echo "ERROR: $fn not loaded" >&2; exit 2; }
done

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
REPO_DIR="$TMP/repo"; SPEC_DIR_REL="docs/specs/52-x"; LOG="$TMP/log"
LABEL_NEEDS_DECISIONS="codex-needs-decisions"
mkdir -p "$REPO_DIR/$SPEC_DIR_REL"; : > "$LOG"
NOTES="$REPO_DIR/$SPEC_DIR_REL/impl-notes.md"

# pt_mark_no_progress_failed が呼ぶ依存をスタブ化（どちらにルートされたか記録）
ROUTE=""
pt_log() { :; }
mark_issue_needs_decisions() { ROUTE="needs-decisions:$1"; }
mark_issue_failed() { ROUTE="failed:$1"; }

PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (exp=$(printf %q "$2") act=$(printf %q "$3"))"; FAIL=$((FAIL+1)); fi; }

# ─── detect_needs_decision_marker ───
printf '## Notes\n本文\n' > "$NOTES"
rc=0; out=$(detect_needs_decision_marker "$NOTES") || rc=$?
eq "marker 無し → rc=1" "1" "$rc"

printf '## Notes\nNEEDS_DECISION: pinned tag と checksum 方針を決めてください\n' > "$NOTES"
out=$(detect_needs_decision_marker "$NOTES"); rc=$?
eq "marker あり → rc=0" "0" "$rc"
eq "marker text を抽出" "pinned tag と checksum 方針を決めてください" "$out"

printf 'NEEDS_DECISION: A: B を決める\n' > "$NOTES"
eq "text 中の : を保持" "A: B を決める" "$(detect_needs_decision_marker "$NOTES")"

rc=0; detect_needs_decision_marker "$TMP/absent.md" >/dev/null || rc=$?
eq "ファイル不在 → rc=1" "1" "$rc"

# ─── pt_mark_no_progress_failed ルーティング ───
# (a) NEEDS_DECISION marker あり → codex-needs-decisions、rc=0
printf 'NEEDS_DECISION: pinned tag を決定してください\n' > "$NOTES"
ROUTE=""; r=0; pt_mark_no_progress_failed "1" "initial" "1" || r=$?
eq "marker ありは needs-decisions へ" "needs-decisions:per-task-implementer-needs-decision" "$ROUTE"
eq "marker ありは return 0" "0" "$r"

# (b) marker 無し → 従来どおり codex-failed
printf '## Notes\n（確認事項なし）\n' > "$NOTES"
ROUTE=""; pt_mark_no_progress_failed "1" "initial" "1" || true
eq "marker 無しは codex-failed のまま" "failed:per-task-implementer-no-progress" "$ROUTE"

# (c) impl-notes.md 不在 → 従来どおり codex-failed（後方互換）
rm -f "$NOTES"
ROUTE=""; pt_mark_no_progress_failed "1" "round2-redo" "2" || true
eq "impl-notes 不在は codex-failed のまま" "failed:per-task-implementer-no-progress" "$ROUTE"

echo "──────────────"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1; echo "ALL GREEN"
