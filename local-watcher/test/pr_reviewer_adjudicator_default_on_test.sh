#!/usr/bin/env bash
#
# 用途: Issue #138 で実施した `PR_REVIEWER_ADJUDICATOR_ENABLED` の既定反転
#       （opt-in / 既定 OFF → opt-out / 既定 ON。idd-claude #412 / PR #423 の移植）の
#       値正規化挙動を検証するスモークテスト。
#
#       検証観点:
#         - 未設定で ON に正規化される（default ON）
#         - 空文字で ON に正規化される
#         - =true で ON のまま
#         - =false で OFF（opt-out 明示のみ OFF / 本変更前と等価）
#         - =True / =FALSE / =0 / =1 / typo はすべて ON に正規化される（opt-out の安全側）
#         - adj_gate_enabled の厳密 `=true` 判定契約は #138 後も不変
#         - 前提不成立時ガード: gate OFF（=false 明示）で adj_run_for_pr が副作用ゼロの
#           即 return 0（gh / claude / log 発火ゼロ）
#         - 本体 watcher ソースの正規化コード（case 文 + デフォルト有効化フラグ正規化ループ）
#           が期待パターンを含むこと（mirror drift 検出）
#
# 配置先: local-watcher/test/pr_reviewer_adjudicator_default_on_test.sh
# 依存:   bash 4+, awk, grep
# 実行:   bash local-watcher/test/pr_reviewer_adjudicator_default_on_test.sh
#
# 検証手段:
#   idd-codex-issue-watcher.sh 本体トップレベルの `case` 文 + 「デフォルト有効化フラグの
#   値正規化」ループによる 2 段正規化を本テスト内に等価コピーした関数を作り、各 env 値で
#   resolve した結果を直接観測する（issue-watcher.sh 本体は大量の startup 依存物を抱えて
#   いるため source できない / 既存 normalize 系テストと同じイディオム）。
#   等価コピーのドリフトは末尾の mirror drift 検出（本体ソースへの grep）で検出する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/idd-codex-issue-watcher.sh"
ADJ_SH="$SCRIPT_DIR/../bin/idd-codex-modules/adjudicator.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find idd-codex-issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi
if [ ! -f "$ADJ_SH" ]; then
  echo "ERROR: cannot find adjudicator.sh at $ADJ_SH" >&2
  exit 2
fi

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

# normalize_adjudicator_enabled: issue-watcher.sh の正規化 2 段（case + ループ）の等価実装。
#   入力: $1 = 生の env 値（空文字は ""）
#         $2 = "set" or "unset"（unset 状態を再現するため）
#   出力: stdout に最終正規化後の値（"true" or "false"）
normalize_adjudicator_enabled() {
  local raw="$1"
  local mode="$2"
  # 1 段目: `${VAR:-true}` で既定 true、続いて `case false) :;; *) true` で正規化
  local v1
  if [ "$mode" = "unset" ]; then
    v1="${_ADJ_UNSET_PROBE:-true}"
  else
    # 空文字は `${VAR:-true}` で既定 true に展開される（bash の `:-` 仕様）
    v1="${raw:-true}"
  fi
  case "$v1" in
    false) : ;;
    *)     v1="true" ;;
  esac
  # 2 段目: 「デフォルト有効化フラグの値正規化」ループ（issue-watcher.sh の `for _idd_flag`
  # と等価。`=false` で false に、それ以外は true に固定する）
  local v2
  if [ "$v1" = "false" ]; then
    v2="false"
  else
    v2="true"
  fi
  printf '%s' "$v2"
}

# ─── 値正規化マトリクス（#138 既定反転） ───

echo "--- PR_REVIEWER_ADJUDICATOR_ENABLED default-flip normalization (#138) ---"

# 未設定 → ON（default ON）
unset _ADJ_UNSET_PROBE 2>/dev/null || true
assert_eq "unset → true (default ON)" \
  "true" "$(normalize_adjudicator_enabled "" "unset")"

# 空文字 → ON
assert_eq "'' (empty) → true" \
  "true" "$(normalize_adjudicator_enabled "" "set")"

# =true → ON
assert_eq "'true' → true" \
  "true" "$(normalize_adjudicator_enabled "true" "set")"

# =false → OFF（明示 opt-out は本変更前と等価）
assert_eq "'false' (explicit opt-out) → false" \
  "false" "$(normalize_adjudicator_enabled "false" "set")"

# 大文字違い / 数値 / typo → ON（opt-out の安全側 = 有効に倒す）
assert_eq "'False' (capitalized) → true" \
  "true" "$(normalize_adjudicator_enabled "False" "set")"
assert_eq "'FALSE' (all caps) → true" \
  "true" "$(normalize_adjudicator_enabled "FALSE" "set")"
assert_eq "'True' (capitalized) → true" \
  "true" "$(normalize_adjudicator_enabled "True" "set")"
assert_eq "'TRUE' (all caps) → true" \
  "true" "$(normalize_adjudicator_enabled "TRUE" "set")"
assert_eq "'1' → true" \
  "true" "$(normalize_adjudicator_enabled "1" "set")"
assert_eq "'0' → true (NOT a valid OFF value)" \
  "true" "$(normalize_adjudicator_enabled "0" "set")"
assert_eq "'flase' (typo) → true" \
  "true" "$(normalize_adjudicator_enabled "flase" "set")"
assert_eq "'on' → true" \
  "true" "$(normalize_adjudicator_enabled "on" "set")"
assert_eq "'off' → true (NOT a valid OFF value)" \
  "true" "$(normalize_adjudicator_enabled "off" "set")"

# ─── adj_gate_enabled の契約は不変（厳密 =true で ON、それ以外 OFF） ───

echo ""
echo "--- adj_gate_enabled contract (unchanged after #138) ---"

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
eval "$(extract_function "$ADJ_SH" "adj_gate_enabled")"

export PR_REVIEWER_ADJUDICATOR_ENABLED="true"
rc=0; adj_gate_enabled || rc=$?
assert_eq "adj_gate_enabled: normalized=true → ON (rc=0)" "0" "$rc"

export PR_REVIEWER_ADJUDICATOR_ENABLED="false"
rc=0; adj_gate_enabled || rc=$?
assert_eq "adj_gate_enabled: normalized=false → OFF (rc=1)" "1" "$rc"

# ─── 前提不成立時ガード: gate OFF で adj_run_for_pr が副作用ゼロの即 return 0 ───
# =false 明示（opt-out）環境では adj_run_for_pr が gh / claude / adj_log を一切発火させず
# 即 return 0 する（本変更導入前の opt-in 既定 OFF と完全に等価な挙動）。
# adj_run_for_pr の依存関数はすべて「呼ばれたら FAIL 記録」の sentinel stub にする。

echo ""
echo "--- adj_run_for_pr: gate OFF early-return guard (=false opt-out equivalence) ---"

# shellcheck disable=SC1090
eval "$(extract_function "$ADJ_SH" "adj_run_for_pr")"

SENTINEL_CALLS=0
# shellcheck disable=SC2317
adj_log() { SENTINEL_CALLS=$((SENTINEL_CALLS + 1)); }
# shellcheck disable=SC2317
adj_warn() { SENTINEL_CALLS=$((SENTINEL_CALLS + 1)); }
# shellcheck disable=SC2317
adj_apply_label_decision() { SENTINEL_CALLS=$((SENTINEL_CALLS + 1)); }
# shellcheck disable=SC2317
adj_apply_status_decision() { SENTINEL_CALLS=$((SENTINEL_CALLS + 1)); }
# shellcheck disable=SC2317
adj_log_summary() { SENTINEL_CALLS=$((SENTINEL_CALLS + 1)); }
# shellcheck disable=SC2317
adj_extract_findings() { SENTINEL_CALLS=$((SENTINEL_CALLS + 1)); echo "[]"; }
# shellcheck disable=SC2317
gh() { SENTINEL_CALLS=$((SENTINEL_CALLS + 1)); return 0; }
# shellcheck disable=SC2317
claude() { SENTINEL_CALLS=$((SENTINEL_CALLS + 1)); return 0; }

export PR_REVIEWER_ADJUDICATOR_ENABLED="false"
rc=0
adj_run_for_pr "123" "abc1234" "## 指摘事項\n- dummy" "https://example.invalid/pr/123" "codex/issue-1" || rc=$?
assert_eq "gate OFF: adj_run_for_pr → rc=0（即 return）" "0" "$rc"
assert_eq "gate OFF: 依存関数（gh / claude / adj_* / log）呼び出しゼロ" "0" "$SENTINEL_CALLS"

# ─── mirror drift 検出: 本体ソースが期待正規化パターンを含むこと ───
# 本テスト冒頭の normalize_adjudicator_enabled は本体コードの等価コピーであるため、
# 本体側の該当行が変わったら本テストも FAIL してコピーの同期を強制する。

echo ""
echo "--- watcher source mirror drift detection ---"

rc=0
grep -q 'PR_REVIEWER_ADJUDICATOR_ENABLED="${PR_REVIEWER_ADJUDICATOR_ENABLED:-true}"' "$WATCHER_SH" || rc=1
assert_eq "watcher: 既定値が :-true（default ON）" "0" "$rc"

# case 文が `false) : ;;` + `*) true` 形（=false 厳密一致のみ OFF）であること
rc=0
awk '/^case "\$PR_REVIEWER_ADJUDICATOR_ENABLED" in$/{f=1} f&&/false\) : ;;/{hit1=1} f&&/\*\)     PR_REVIEWER_ADJUDICATOR_ENABLED="true" ;;/{hit2=1} f&&/^esac$/{exit} END{exit !(hit1&&hit2)}' "$WATCHER_SH" || rc=1
assert_eq "watcher: case 正規化が =false 厳密一致のみ OFF" "0" "$rc"

rc=0
awk '/for _idd_flag in/{f=1} f&&/PR_REVIEWER_ADJUDICATOR_ENABLED; do/{hit=1} f&&/^done$/{exit} END{exit !hit}' "$WATCHER_SH" || rc=1
assert_eq "watcher: デフォルト有効化フラグ正規化ループに PR_REVIEWER_ADJUDICATOR_ENABLED が登録済み" "0" "$rc"

rc=0
grep -q 'pr-reviewer-adjudicator=\${PR_REVIEWER_ADJUDICATOR_ENABLED}' "$WATCHER_SH" || rc=1
assert_eq "watcher: cycle startup ログに pr-reviewer-adjudicator= を出力" "0" "$rc"

# ─── サマリ ───

echo ""
echo "================================"
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
