#!/usr/bin/env bash
#
# 用途: local-watcher/bin/idd-codex-issue-watcher.sh の「役割定義 prompt 注入」
#       (#15 harness fix) で追加した 3 関数を fixture で検証する。
#
#         - codex_agent_roles_for_stage:  stage_label → role 名のマッピング
#         - codex_strip_frontmatter:      .codex/agents/*.md の YAML frontmatter 除去
#         - codex_build_role_preamble:    役割定義 preamble の組み立て / トグル / fail-open
#
#       Codex CLI には Claude Code の subagent 自動ロード機構が無く、移植時に
#       Developer / Reviewer 等の役割定義が一切 context に入らない（出力品質低下）
#       回帰を防ぐための gate。
#
# 配置先: local-watcher/test/codex_role_injection_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/codex_role_injection_test.sh

# MODE / CODEX_INJECT_ROLE_DEFS は eval で抽出した関数（codex_agent_roles_for_stage /
# codex_build_role_preamble）が global として読むため、本ファイル直書きの代入を shellcheck は
# 「未使用」と誤検出する（データフローが eval 越しで追えない）。SC2034 をファイル全体で抑止する。
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

# 対象関数だけを awk で切り出して eval する（script 全体を source しない）。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "codex_agent_roles_for_stage")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "codex_strip_frontmatter")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "codex_build_role_preamble")"

for fn in codex_agent_roles_for_stage codex_strip_frontmatter codex_build_role_preamble; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# ─── テスト用の fake REPO_DIR / .codex/agents 足場 ───
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
REPO_DIR="$TMPDIR_TEST/repo"
export REPO_DIR
mkdir -p "$REPO_DIR/.codex/agents"

cat >"$REPO_DIR/.codex/agents/developer.md" <<'EOF'
---
name: developer
description: Developer エージェント
tools: Read, Write, Edit, Bash
model: gpt-5.5
---

あなたはシニアソフトウェアエンジニアです。
# テスト作成ルール
Red→Green→Refactor を厳守する。
EOF

cat >"$REPO_DIR/.codex/agents/product-manager.md" <<'EOF'
---
name: product-manager
---

あなたは Product Manager です。EARS 形式で AC を書く。
EOF

# ─── アサーションヘルパ ───
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
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label (needle not found: $(printf '%q' "$needle"))"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label (needle unexpectedly found: $(printf '%q' "$needle"))"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ─── 1. codex_agent_roles_for_stage マッピング ───
MODE="impl"
assert_eq "roles StageA impl (PM+Dev 同居 exec)" "product-manager developer" "$(codex_agent_roles_for_stage "StageA")"
MODE="impl-resume"
assert_eq "roles StageA impl-resume → developer のみ（設計確定済み）" "developer" "$(codex_agent_roles_for_stage "StageA")"
unset MODE
assert_eq "roles StageA MODE 未設定 → PM+Dev（catch-all）" "product-manager developer" "$(codex_agent_roles_for_stage "StageA")"
assert_eq "roles StageA-redo → developer"   "developer"   "$(codex_agent_roles_for_stage "StageA-redo")"
assert_eq "roles StageA-prime-blocked → developer（effort 群と別軸）" "developer" "$(codex_agent_roles_for_stage "StageA-prime-blocked")"
assert_eq "roles StageA-pp → developer"     "developer"   "$(codex_agent_roles_for_stage "StageA-pp")"
assert_eq "roles PerTask-Impl-* → developer" "developer"  "$(codex_agent_roles_for_stage "PerTask-Impl-1.1")"
assert_eq "roles PerTask-Rev-* → reviewer"  "reviewer"    "$(codex_agent_roles_for_stage "PerTask-Rev-1.1-r2-a1")"
assert_eq "roles Reviewer-* → reviewer"     "reviewer"    "$(codex_agent_roles_for_stage "Reviewer-r2-a1")"
assert_eq "roles Debugger-* → debugger"     "debugger"    "$(codex_agent_roles_for_stage "Debugger-blocked-1.1")"
assert_eq "roles design → architect"        "architect"   "$(codex_agent_roles_for_stage "design")"
assert_eq "roles PR-iteration-design → architect" "architect" "$(codex_agent_roles_for_stage "PR-iteration-design-r2")"
assert_eq "roles PR-iteration-impl → developer"   "developer" "$(codex_agent_roles_for_stage "PR-iteration-impl-r2")"
assert_eq "roles StageC → project-manager"  "project-manager" "$(codex_agent_roles_for_stage "StageC")"
assert_eq "roles AutoRebase-* → developer"  "developer"   "$(codex_agent_roles_for_stage "AutoRebase-42")"
assert_eq "roles Triage → 空（注入なし）"   ""            "$(codex_agent_roles_for_stage "Triage")"
assert_eq "roles 未知 stage → developer (catch-all)" "developer" "$(codex_agent_roles_for_stage "SomethingNew")"

# ─── 2. codex_strip_frontmatter ───
stripped="$(codex_strip_frontmatter "$REPO_DIR/.codex/agents/developer.md")"
assert_not_contains "frontmatter 行 'name:' が除去される" "$stripped" "name: developer"
assert_not_contains "frontmatter 区切り '---' が除去される" "$stripped" "---"
assert_contains "body は残る（テスト作成ルール）" "$stripped" "Red→Green→Refactor"

# frontmatter が無いファイルは丸ごと残す
printf 'no frontmatter\nbody only\n' >"$REPO_DIR/plain.md"
assert_eq "frontmatter 無しは全行残す" "no frontmatter
body only" "$(codex_strip_frontmatter "$REPO_DIR/plain.md")"

# ─── 3. codex_build_role_preamble ───
# 3a. developer stage → developer.md body を含む preamble
CODEX_INJECT_ROLE_DEFS=true
preamble_dev="$(codex_build_role_preamble "PerTask-Impl-1.1")"
assert_contains "preamble に ROLE DEFINITION ヘッダ" "$preamble_dev" "ROLE DEFINITION"
assert_contains "preamble に developer role 名" "$preamble_dev" "ROLE DEFINITION（厳守）— developer"
assert_contains "preamble に developer body" "$preamble_dev" "Red→Green→Refactor"
assert_not_contains "preamble に frontmatter が漏れない" "$preamble_dev" "tools: Read"

# 3b. StageA は PM + Developer 両方を注入
preamble_sa="$(codex_build_role_preamble "StageA")"
assert_contains "StageA preamble に product-manager block" "$preamble_sa" "— product-manager"
assert_contains "StageA preamble に developer block" "$preamble_sa" "— developer"

# 3c. CODEX_INJECT_ROLE_DEFS=false → 空（後方互換エスケープハッチ）
CODEX_INJECT_ROLE_DEFS=false
assert_eq "トグル false で注入なし（空）" "" "$(codex_build_role_preamble "PerTask-Impl-1.1")"
CODEX_INJECT_ROLE_DEFS=true

# 3d. Triage は role 無し → 空
assert_eq "Triage は注入なし（空）" "" "$(codex_build_role_preamble "Triage")"

# 3e. role ファイル欠落 → 空 + stderr に WARN（fail-open / silent fail にしない）
rm -f "$REPO_DIR/.codex/agents/reviewer.md"  # 元々存在しない（明示）
warn_out="$( codex_build_role_preamble "Reviewer-r1-a1" 2>&1 1>/dev/null )"
preamble_missing="$( codex_build_role_preamble "Reviewer-r1-a1" 2>/dev/null )"
assert_eq "欠落時 stdout は空（fail-open）" "" "$preamble_missing"
assert_contains "欠落時 stderr に loud WARN" "$warn_out" "WARN: 役割定義が見つかりません"

# ─── サマリ ───
echo ""
echo "──────────────────────────────────────────"
echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
if [ "$FAIL_COUNT" -ne 0 ]; then
  exit 1
fi
echo "ALL GREEN"
