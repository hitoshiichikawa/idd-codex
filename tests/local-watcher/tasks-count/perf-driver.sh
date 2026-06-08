#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# perf-driver.sh — tc_count_tasks のパフォーマンステスト（NFR 3.1）
#
# 用途: 約 1 MB の tasks.md fixture を一時生成し、`tc_count_tasks` の wall clock を
#       計測する。1 秒以内に完了することを assert する（NFR 3.1: `tasks.md` 1 ファイル
#       あたりのカウント処理を 1 秒以内に完了する。対象 tasks.md のサイズが 1MB 以下
#       である前提）。
#
# 配置: tests/local-watcher/tasks-count/perf-driver.sh
# CI 化: しない（ローカル実行で十分。tasks.md L113-115 の deferrable 規約）
# 依存: bash 4+, awk, mktemp, date (+%s%N)
# 設計参照: docs/specs/147-feat-harness-tasks-md-task-codex-auto-dev-issu/design.md
#           (Performance Tests)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

_DRV_DIR="$(cd "$(dirname "$0")" && pwd)"
_REPO_ROOT="$(cd "$_DRV_DIR/../../.." && pwd)"
_WATCHER_SH="$_REPO_ROOT/local-watcher/bin/idd-codex-issue-watcher.sh"

if [ ! -f "$_WATCHER_SH" ]; then
  echo "ERROR: watcher script not found at $_WATCHER_SH" >&2
  exit 2
fi

_TMP=$(mktemp -d -t tc-perf-XXXXXX)
trap 'rm -rf "$_TMP"' EXIT

# ── 1 MB 程度の tasks.md を生成 ──
# 1 行あたり ~60 byte 程度の task 行を 20000 行生成すると 1.2〜1.3 MB になる。
# #216 で canonical regex（最上位 numeric ID の未完了のみ計数）に整合したため、
# regex が実際にマッチする最上位タスク行（`- [ ] $i. ...`）を生成して計数経路の
# 最悪ケースを計測する（旧版は子タスク `$i.$sub` を生成しており新 regex では
# 全行非マッチ＝count=0 になっていた）。
{
  echo "# Implementation Plan (perf fixture)"
  echo
  for i in $(seq 1 20000); do
    echo "- [ ] $i. Task number $i with padding text padding padding"
  done
} > "$_TMP/tasks.md"

_size=$(wc -c < "$_TMP/tasks.md")
echo "generated fixture: $_size bytes (~$((_size / 1024)) KB, 20000 task lines)"

# ── 関数抽出（既存 extract-driver.sh と同方式）──
awk '
  /^tc_log\(\) \{/         { in_fn = 1 }
  /^tc_warn\(\) \{/        { in_fn = 1 }
  /^tc_error\(\) \{/       { in_fn = 1 }
  /^tc_count_tasks\(\) \{/ { in_fn = 1 }
  /^tc_classify\(\) \{/    { in_fn = 1 }
  in_fn { print }
  in_fn && /^\}$/ { in_fn = 0; print "" }
' "$_WATCHER_SH" > "$_TMP/extracted.sh"

REPO="test/tasks-count-perf"
export REPO

# shellcheck source=/dev/null
. "$_TMP/extracted.sh"

# ── 計測 ──
# date +%s%N はナノ秒精度（GNU date）。macOS の BSD date は %N を解釈しないため、
# その環境では `time` コマンドにフォールバックする。
if _ns_test=$(date +%s%N 2>/dev/null) && [ "${_ns_test}" != "${_ns_test%N}" ]; then
  # GNU date を持たない環境（%N が展開されなかった場合）
  echo "WARN: date +%s%N が ns 精度を持たないため、計測は秒単位の概算になります" >&2
  _start=$(date +%s)
  _count=$(tc_count_tasks "$_TMP/tasks.md")
  _end=$(date +%s)
  _elapsed_ms=$(( (_end - _start) * 1000 ))
else
  _start_ns=$(date +%s%N)
  _count=$(tc_count_tasks "$_TMP/tasks.md")
  _end_ns=$(date +%s%N)
  _elapsed_ms=$(( (_end_ns - _start_ns) / 1000000 ))
fi

echo "tc_count_tasks: count=$_count elapsed=${_elapsed_ms}ms"

# ── assert NFR 3.1 ──
if [ "$_elapsed_ms" -lt 1000 ]; then
  echo "PASS: NFR 3.1 (< 1 second for ~1 MB tasks.md)"
  exit 0
else
  echo "FAIL: NFR 3.1 violated (elapsed=${_elapsed_ms}ms ≥ 1000ms)" >&2
  exit 1
fi
