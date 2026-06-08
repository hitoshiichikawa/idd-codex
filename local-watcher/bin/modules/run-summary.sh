#!/usr/bin/env bash
# shellcheck shell=bash
# run-summary.sh — watcher の Per-Run Evidence Summary モジュール (#239)
#
# 用途:
#   1 サイクル（impl / impl-resume / design）で実際にどの stage / gate が走り、どう判定
#   されたかを機械可読な 1 行 run サマリとして既存ログに追記する observability を提供する。
#   現状は成果物（impl-notes.md / review-notes.md / PR）の有無からしか実行実態を事後推定
#   できず、独立 Reviewer ゲートが degraded して効いていなかった実行（#238 背景）や
#   stage-a-verify が SKIP された実行、scaffolding（.codex/agents / .codex/rules）欠落を
#   外形検出できない。本モジュールはサイクル横断で実行実態を per-slot 蓄積する状態コレクタ
#   （rs_* 記録関数）と、サイクル終端で 1 行を整形出力する emitter（rs_emit）を集約する。
#   - rs_init                    : 状態変数群を既定値に初期化（サイクル冒頭で 1 回）
#   - rs_set_mode                : mode を記録（impl / impl-resume / design）
#   - rs_set_issue               : 対象 Issue 番号を記録
#   - rs_record_stage            : 実行された stage（A / A' / B / B' / C）を重複排除して蓄積
#   - rs_set_scaffolding         : scaffolding 有無を記録（ok / missing）
#   - rs_record_reviewer         : Reviewer の独立起動・verdict・round を記録
#   - rs_record_sav              : stage-a-verify の結果・round を記録
#   - rs_record_error            : degraded 兆候の検出を記録（errors=yes へ）
#   - rs_scan_degraded_log       : LOG から degraded 兆候を grep し errors を更新（fail-open）
#   - rs_set_result              : 最終遷移を記録（ready / iteration / failed / hold）
#   - rs_emit                    : 蓄積状態を `run-summary:` 1 行に整形出力（EXIT trap から呼ぶ）
#
# 設計方針（design.md「状態蓄積方式の決定」節）:
#   状態は _slot_run_issue サブシェル内のグローバル scalar 変数群（RUN_SUMMARY_* prefix）に
#   持つ。サブシェル `( ) &` 単位で自動隔離されるため並列 slot で状態が混ざらない。連想配列や
#   一時ファイルは使わない。変数は export しない（Codex 子プロセスへの汚染防止）。
#   value は ASCII 固定・空白を含めない（grep / awk 抽出の robustness）。
#
# 配置先:
#   $HOME/bin/modules/run-summary.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは idd-codex-issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数 ${REPO}（prefix 整形用）/ ${LOG}（degraded スキャン対象）は本体側で定義される
#     前提。bash の遅延束縛により呼び出し時に解決される。未定義でも ${VAR:-default} で防御する。
#   - 環境変数 RUN_SUMMARY_ENABLED（既定 true / `=false` で無効化＝出力なし）は rs_emit 時に
#     評価する（rs_init でスナップショットしない。ログノイズ off スイッチ / NFR 1.3）。
#   - 外部 CLI: date / grep（POSIX。ripgrep は使わない / NFR 3.1）。新規外部サービス呼び出しなし。
#
# セットアップ参照先:
#   - 設計: docs/specs/239-feat-watcher-per-run-evidence-stage-gate/design.md
#   - 要件: docs/specs/239-feat-watcher-per-run-evidence-stage-gate/requirements.md

# ─── degraded 兆候パターン（Single Source of Truth） ───
#
# rs_scan_degraded_log が $LOG を grep する際に errors=yes へ上げる固定パターン集合
# （design.md「degraded 兆候のスキャン契約」節 / Req 6.2）。grep -E で評価するため
# ERE。拡張時は本配列のみを更新する（SSoT）。
RUN_SUMMARY_DEGRADED_PATTERNS=(
  'No such file or directory'
  'Agent type .* not found'
  'subagent .* not found'
)

# ─── rs_init ───
#
# run 状態変数群（RUN_SUMMARY_* prefix）を既定値に初期化する。サイクル冒頭で 1 回呼ぶ
# 前提だが、未呼び出しでも rs_emit は ${VAR:-default} で既定値を吐ける（フェイルセーフ）。
# RUN_SUMMARY_ENABLED は env を尊重するためここではスナップショットしない（rs_emit 時に評価）。
# Req 1.2, 1.3, NFR 1.3, NFR 2.2, NFR 3.1
rs_init() {
  RUN_SUMMARY_ISSUE='#?'          # issue=  既定（未確定）
  RUN_SUMMARY_MODE='unknown'      # mode=   既定（未確定）
  RUN_SUMMARY_STAGES=''           # stages= 内部蓄積（空=none として emit）
  RUN_SUMMARY_REVIEWER='n/a'      # reviewer= 既定（非該当 / 未起動）
  RUN_SUMMARY_SAV='n/a'           # stage-a-verify= 既定（非該当 / 未実行）
  RUN_SUMMARY_SCAFFOLDING='unknown' # scaffolding= 既定（未判定）
  RUN_SUMMARY_ERRORS='no'         # errors= 既定（兆候なし）
  RUN_SUMMARY_RESULT='unknown'    # result= 既定（最終遷移未確定）
  return 0
}

# ─── rs_set_mode ───
#
# 実行モードを記録する。副作用は変数代入のみ（戻り値常に 0）。
# Args: $1 = "impl" | "impl-resume" | "design"
# Req 1.2, 2.x
rs_set_mode() {
  RUN_SUMMARY_MODE="${1:-unknown}"
  return 0
}

# ─── rs_set_issue ───
#
# 対象 Issue 番号を記録する。`#<N>` 形式に正規化（既に `#` 始まりならそのまま）。
# 副作用は変数代入のみ（戻り値常に 0）。
# Args: $1 = Issue 番号（"239" または "#239"）
# Req 1.3
rs_set_issue() {
  local num="${1:-}"
  if [ -z "$num" ]; then
    RUN_SUMMARY_ISSUE='#?'
  elif [ "${num#\#}" != "$num" ]; then
    # 既に `#` 始まり
    RUN_SUMMARY_ISSUE="$num"
  else
    RUN_SUMMARY_ISSUE="#${num}"
  fi
  return 0
}

# ─── rs_record_stage ───
#
# 実行された stage を重複排除して実行順に蓄積する。`A'`（Stage A redo）は `Ap`、
# `B'`（round 2）は `Bp` と表記して prime 記号・カンマ衝突を避ける（design.md フォーマット表）。
# 同じ stage を 2 回記録しても 1 回だけ列挙する。副作用は変数代入のみ（戻り値常に 0）。
# Args: $1 = "A" | "A'" | "Ap" | "B" | "B'" | "Bp" | "C"
# Req 2.1, 2.2, 2.3
rs_record_stage() {
  local stage="${1:-}"
  [ -z "$stage" ] && return 0
  # prime 記号を Ap / Bp 表記へ正規化
  case "$stage" in
    "A'") stage='Ap' ;;
    "B'") stage='Bp' ;;
  esac
  # 重複排除（カンマ区切りの既存集合に同一値があれば追加しない）
  case ",${RUN_SUMMARY_STAGES}," in
    *",${stage},"*) return 0 ;;
  esac
  if [ -z "$RUN_SUMMARY_STAGES" ]; then
    RUN_SUMMARY_STAGES="$stage"
  else
    RUN_SUMMARY_STAGES="${RUN_SUMMARY_STAGES},${stage}"
  fi
  return 0
}

# ─── rs_set_scaffolding ───
#
# scaffolding 有無を記録する。副作用は変数代入のみ（戻り値常に 0）。
# Args: $1 = "ok" | "missing"
# Req 5.1, 5.2
rs_set_scaffolding() {
  RUN_SUMMARY_SCAFFOLDING="${1:-unknown}"
  return 0
}

# ─── rs_record_reviewer ───
#
# Reviewer の独立起動・verdict・round を記録する（design.md「Reviewer 独立起動判定の意味づけ」節）。
#   independent + approve + round → reviewer=independent:approve:r<n>
#   independent + reject  + round → reviewer=independent:reject:r<n>
#   independent + quota   + round → reviewer=independent:quota:r<n>
#   degraded            + round → reviewer=degraded:r<n>（verdict なし）
# round 未指定時は r? とする。副作用は変数代入のみ（戻り値常に 0）。
# Args: $1 = "independent" | "degraded"
#       $2 = verdict（"approve" | "reject" | "quota"） / degraded では無視
#       $3 = round（整数）
# Req 3.1, 3.2, 3.3, 3.4
rs_record_reviewer() {
  local state="${1:-}"
  local verdict="${2:-}"
  local round="${3:-}"
  local rtag="r${round:-?}"
  case "$state" in
    independent)
      if [ -n "$verdict" ]; then
        RUN_SUMMARY_REVIEWER="independent:${verdict}:${rtag}"
      else
        RUN_SUMMARY_REVIEWER="independent:${rtag}"
      fi
      ;;
    degraded)
      RUN_SUMMARY_REVIEWER="degraded:${rtag}"
      ;;
    *)
      # 非該当 / 未知 state は既定 n/a を維持
      :
      ;;
  esac
  return 0
}

# ─── rs_record_sav ───
#
# stage-a-verify ゲートの結果・round を記録する。副作用は変数代入のみ（戻り値常に 0）。
# Args: $1 = "success" | "round1" | "round2" | "skip" | "disabled"
# Req 4.1, 4.2, 4.3
rs_record_sav() {
  local state="${1:-}"
  [ -z "$state" ] && return 0
  RUN_SUMMARY_SAV="$state"
  return 0
}

# ─── rs_record_error ───
#
# degraded 兆候の検出を記録する（errors=yes へ上げる）。reason は記録のみで run サマリ行へ
# 転記しない（機密漏洩面の最小化 / Security Considerations）。副作用は変数代入のみ（戻り値常に 0）。
# Args: $1 = reason（ログ転記しないラベル）
# Req 6.1, 6.2
rs_record_error() {
  RUN_SUMMARY_ERRORS='yes'
  return 0
}

# ─── rs_scan_degraded_log ───
#
# ${LOG}（または引数の logfile）を grep し、degraded 兆候パターン
# （RUN_SUMMARY_DEGRADED_PATTERNS）のいずれかが出現したら errors=yes に上げる（Req 6.2）。
# LOG 不在 / 読めない場合は errors を変更せず warn も出さない（fail-open / 既定 no を維持）。
# 各 stage 完了直後に累積実行する想定。grep -q がマッチ無しで return 1 を返しても set -e で
# 落ちないよう if で吸収する。副作用は変数代入のみ（戻り値常に 0）。
# Args: $1 = logfile（省略時は ${LOG}）
# Req 6.1, 6.2, 6.3, NFR 3.1
rs_scan_degraded_log() {
  local logfile="${1:-${LOG:-}}"
  # LOG 不在 / 空 / 読めない → fail-open（errors 変更なし）
  [ -z "$logfile" ] && return 0
  [ -r "$logfile" ] || return 0
  local pattern
  for pattern in "${RUN_SUMMARY_DEGRADED_PATTERNS[@]}"; do
    if grep -qE "$pattern" "$logfile" 2>/dev/null; then
      RUN_SUMMARY_ERRORS='yes'
      return 0
    fi
  done
  return 0
}

# ─── rs_set_result ───
#
# サイクルの最終遷移を記録する。副作用は変数代入のみ（戻り値常に 0）。
# Args: $1 = "codex-ready-for-review" | "codex-needs-iteration" | "codex-failed" | "hold"
# Req 7.1, 7.2
rs_set_result() {
  RUN_SUMMARY_RESULT="${1:-unknown}"
  return 0
}

# ─── rs_emit ───
#
# 蓄積した状態を `run-summary:` 1 行に整形して stdout 出力する（EXIT trap から呼ぶ）。
# 固定 prefix `[YYYY-MM-DD HH:MM:SS] [$REPO] run-summary:`（既存 logger 慣習 / Req 8.1）に
# key=value を固定順（issue mode stages reviewer stage-a-verify scaffolding errors result）で
# 1 行に連結する（Req 8.2, 8.3）。
#   - RUN_SUMMARY_ENABLED=false 時は即 return 0（無効化＝出力なし / NFR 1.3）。env を rs_emit
#     時に評価する（rs_init でスナップショットしない）。
#   - 全ての参照を ${VAR:-default} で防御し、未初期化でも既定値 1 行を吐く（フェイルセーフ）。
#   - 内部処理を fail-open とし echo 失敗・変数未定義で exit code を変えない（NFR 4.1）。
#     呼び出し側は `trap 'rs_emit || true' EXIT` で更に二重に吸収する。
# Req 1.1, 1.4, 8.1, 8.2, 8.3, NFR 1.3, NFR 2.1, NFR 4.1
rs_emit() {
  # 無効化（env を尊重）: 出力せず即 return 0
  case "${RUN_SUMMARY_ENABLED:-true}" in
    false|0|no|off) return 0 ;;
  esac

  local ts repo issue mode stages reviewer sav scaffolding errors result
  ts="$(date '+%F %T' 2>/dev/null)" || ts='?'
  repo="${REPO:-?}"
  issue="${RUN_SUMMARY_ISSUE:-#?}"
  mode="${RUN_SUMMARY_MODE:-unknown}"
  # stages 内部蓄積が空なら none として emit（Req 2.2）
  stages="${RUN_SUMMARY_STAGES:-}"
  [ -z "$stages" ] && stages='none'
  reviewer="${RUN_SUMMARY_REVIEWER:-n/a}"
  sav="${RUN_SUMMARY_SAV:-n/a}"
  scaffolding="${RUN_SUMMARY_SCAFFOLDING:-unknown}"
  errors="${RUN_SUMMARY_ERRORS:-no}"
  result="${RUN_SUMMARY_RESULT:-unknown}"

  echo "[${ts}] [${repo}] run-summary: issue=${issue} mode=${mode} stages=${stages} reviewer=${reviewer} stage-a-verify=${sav} scaffolding=${scaffolding} errors=${errors} result=${result}" || true
  return 0
}
