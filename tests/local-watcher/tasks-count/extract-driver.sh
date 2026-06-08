#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# extract-driver.sh — tc_count_tasks / tc_classify の fixture 回帰テスト
#
# 用途: `local-watcher/bin/idd-codex-issue-watcher.sh` 内の純粋関数群
#       （tc_log / tc_warn / tc_error / tc_count_tasks / tc_classify）を
#       fixture (`fixtures/tasks-*.md`) に対して走らせ、期待 count と
#       期待 classification と diff する。全件 pass で exit 0、不一致あれば
#       該当 fixture 名と期待 / 実測を出力して exit 1。
#
# 配置: tests/local-watcher/tasks-count/extract-driver.sh
# 依存: bash 4+, awk, grep, mktemp
# 設計参照: docs/specs/147-feat-harness-tasks-md-task-codex-auto-dev-issu/design.md
#           (Testing Strategy / Integration Tests)
# 既存形式: tests/local-watcher/stage-a-verify/extract-driver.sh と同形式
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# 自身の場所から repo root を解決する（呼び出し元 cwd に依存しない）。
_DRV_DIR="$(cd "$(dirname "$0")" && pwd)"
_REPO_ROOT="$(cd "$_DRV_DIR/../../.." && pwd)"
_WATCHER_SH="$_REPO_ROOT/local-watcher/bin/idd-codex-issue-watcher.sh"
_FIXTURE_DIR="$_DRV_DIR/fixtures"

if [ ! -f "$_WATCHER_SH" ]; then
  echo "ERROR: watcher script not found at $_WATCHER_SH" >&2
  exit 2
fi
if [ ! -d "$_FIXTURE_DIR" ]; then
  echo "ERROR: fixture dir not found at $_FIXTURE_DIR" >&2
  exit 2
fi

# watcher 本体を source するとメイン処理が走るため、対象関数だけを awk で抽出して
# source する。`tc_log` / `tc_warn` / `tc_error` / `tc_count_tasks` / `tc_classify`
# の 5 関数を順に切り出す（tc_classify は内部で tc_warn を呼ぶため依存解決のため
# 全 5 関数を含める）。
_EXTRACTED=$(mktemp -t tc-extract-XXXXXX.sh)
trap 'rm -f "$_EXTRACTED"' EXIT
awk '
  /^tc_log\(\) \{/         { in_fn = 1 }
  /^tc_warn\(\) \{/        { in_fn = 1 }
  /^tc_error\(\) \{/       { in_fn = 1 }
  /^tc_count_tasks\(\) \{/ { in_fn = 1 }
  /^tc_classify\(\) \{/    { in_fn = 1 }
  in_fn { print }
  in_fn && /^\}$/ { in_fn = 0; print "" }
' "$_WATCHER_SH" > "$_EXTRACTED"

if ! [ -s "$_EXTRACTED" ]; then
  echo "ERROR: tc_count_tasks / tc_classify を $_WATCHER_SH から抽出できませんでした" >&2
  exit 2
fi

# tc_log / tc_warn が参照する $REPO を test 用の値で固定し、watcher の本体起動
# サイドエフェクトと衝突しないようにする。
REPO="test/tasks-count"
TC_WARN_LOWER=8
TC_WARN_UPPER=10
TC_ESCALATE_LOWER=11
export REPO TC_WARN_LOWER TC_WARN_UPPER TC_ESCALATE_LOWER

# shellcheck source=/dev/null
. "$_EXTRACTED"

# ── 期待値テーブル ──
# fixture 名（basename） → "<expected_count>:<expected_classification>"
# classification は normal / warn / escalate の 3 値のいずれか。
# macOS 標準 bash 3.2 互換のため、連想配列ではなく case 関数で持つ。
tc_expected_for() {
  case "$1" in
    tasks-7.md) printf '%s\n' "7:normal" ;;
    tasks-8.md) printf '%s\n' "8:warn" ;;
    tasks-10.md) printf '%s\n' "10:warn" ;;
    tasks-11.md) printf '%s\n' "11:escalate" ;;
    tasks-empty.md) printf '%s\n' "0:normal" ;;
    # 旧計数（全 checkbox 計上）なら 8:warn。canonical（最上位・未完了のみ）で 4:normal。
    # 子 1.1/1.2/2.1・完了 5./完了 deferrable 2.1 を除外し、最上位未完了 1./2.(deferrable)/3./4. の 4 件。
    tasks-mixed-checkbox.md) printf '%s\n' "4:normal" ;;
    # #216 回帰ロック: feedman #41 を模した「最上位 7 + 子多数 + 完了数件」fixture。
    # 旧計数（全 checkbox）なら 15、canonical（最上位・未完了のみ）なら 7。
    # 子タスク除外・完了 [x] 除外を明示的にロックする。
    tasks-toplevel-vs-flat.md) printf '%s\n' "7:normal" ;;
    *) return 1 ;;
  esac
}

_pass=0
_fail=0
_failed_names=()

for _fixture_path in "$_FIXTURE_DIR"/tasks-*.md; do
  _name=$(basename "$_fixture_path")
  if ! _expected=$(tc_expected_for "$_name"); then
    echo "WARN: 期待値テーブル未登録 fixture=$_name (skip)" >&2
    continue
  fi
  _expected_count="${_expected%%:*}"
  _expected_class="${_expected##*:}"

  # tc_count_tasks は stderr に warning を出すことがあるため、stdout のみ取得。
  _actual_count=$(tc_count_tasks "$_fixture_path" 2>/dev/null || echo "ERR")
  _actual_class=$(tc_classify "$_actual_count" 2>/dev/null || echo "ERR")

  if [ "$_actual_count" = "$_expected_count" ] \
      && [ "$_actual_class" = "$_expected_class" ]; then
    _pass=$((_pass + 1))
    printf '  ok   %s (count=%s class=%s)\n' "$_name" "$_actual_count" "$_actual_class"
  else
    _fail=$((_fail + 1))
    _failed_names+=("$_name")
    printf '  FAIL %s\n' "$_name"
    printf '    expected: count=%s class=%s\n' "$_expected_count" "$_expected_class"
    printf '    actual:   count=%s class=%s\n' "$_actual_count" "$_actual_class"
  fi
done

# ── 追加の classify 境界値検証（fixture に依存しない純粋関数テスト）──
# Req 2.1 / 2.2 / 2.3 の閾値境界が classify 単独で動くことを確認する。
declare -a _CLASSIFY_CASES=(
  "0:normal"
  "7:normal"
  "8:warn"
  "9:warn"
  "10:warn"
  "11:escalate"
  "50:escalate"
)
for _case in "${_CLASSIFY_CASES[@]}"; do
  _input="${_case%%:*}"
  _exp="${_case##*:}"
  _got=$(tc_classify "$_input" 2>/dev/null)
  if [ "$_got" = "$_exp" ]; then
    _pass=$((_pass + 1))
    printf '  ok   classify(%s)=%s\n' "$_input" "$_got"
  else
    _fail=$((_fail + 1))
    _failed_names+=("classify($_input)")
    printf '  FAIL classify(%s) expected=%s actual=%s\n' "$_input" "$_exp" "$_got"
  fi
done

# ── fallback 検証 ──
# Req 2.2: 閾値 env var 非整数で既定値（8/10/11）にフォールバック
_orig_lower="$TC_WARN_LOWER"
TC_WARN_LOWER="abc"
_got=$(tc_classify 9 2>/dev/null)
TC_WARN_LOWER="$_orig_lower"
if [ "$_got" = "warn" ]; then
  _pass=$((_pass + 1))
  echo "  ok   classify(9) with bad TC_WARN_LOWER → fallback warn"
else
  _fail=$((_fail + 1))
  _failed_names+=("classify-bad-env")
  echo "  FAIL classify(9) with bad TC_WARN_LOWER expected=warn actual=$_got"
fi

# count 非整数で normal にフォールバック
_got=$(tc_classify "not-an-int" 2>/dev/null)
if [ "$_got" = "normal" ]; then
  _pass=$((_pass + 1))
  echo "  ok   classify(not-an-int) → fallback normal"
else
  _fail=$((_fail + 1))
  _failed_names+=("classify-bad-count")
  echo "  FAIL classify(not-an-int) expected=normal actual=$_got"
fi

# tc_count_tasks: 不在ファイル → return 1
if tc_count_tasks "/no/such/path/tasks.md" >/dev/null 2>&1; then
  _fail=$((_fail + 1))
  _failed_names+=("count-missing-file")
  echo "  FAIL tc_count_tasks(missing file) expected non-zero exit"
else
  _pass=$((_pass + 1))
  echo "  ok   tc_count_tasks(missing file) → return 1"
fi

echo
echo "summary: pass=$_pass fail=$_fail total=$((_pass + _fail))"

if [ "$_fail" -gt 0 ]; then
  echo "failed cases: ${_failed_names[*]}" >&2
  exit 1
fi
exit 0
