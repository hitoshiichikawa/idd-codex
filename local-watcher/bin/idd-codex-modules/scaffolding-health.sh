#!/usr/bin/env bash
# shellcheck shell=bash
# scaffolding-health.sh — watcher の scaffolding health gate / doctor モジュール
#
# 用途:
#   worktree 内の `.codex/agents` / `.codex/rules` 足場の到達性を「実際に届いて
#   いるか」のレベルで能動検証・可視化する scaffolding health gate (#238) と、各
#   crontab repo の装備状態を副作用なく点検する doctor サブコマンドの関数定義を
#   集約する。#237 は `.codex/` を worktree へ届ける delivery 側の対策であり、本
#   モジュールは delivery が届いたかを検証する側を担い、ルール非装備の degraded
#   実行が silent に agent stage へ進む事故を構造的に防ぐ。
#   - sh_log / sh_warn / sh_error              : `scaffolding-health:` 3 段 prefix logger
#   - sh_inspect_scaffolding                   : 指定 worktree の agents/rules 非空到達性検査
#                                                （純関数 / read-only / 0=full / 1=missing / 2=indeterminate）
#   - _sh_emit_visibility_signal               : 欠落時の Issue コメント可視シグナル（冪等 / fail-open）
#   - sh_preflight_gate                        : Slot Runner から呼ぶ preflight gate（WARN + 可視
#                                                シグナル + HALT 分岐 / 0=継続 / 1=HALT）
#   - sh_doctor_check_scaffolding              : doctor 点検: agents/rules 到達性（Req 4.2 / read-only）
#   - sh_doctor_check_clis                     : doctor 点検: gh/jq/flock/git/codex 存否（Req 4.3）
#   - sh_doctor_check_labels                   : doctor 点検: 必須ラベル存否（Req 4.4 / read-only）
#   - sh_doctor_check_base_branch              : doctor 点検: base ブランチ解決可否（Req 4.5 / read-only）
#   - sh_doctor_run                            : doctor 統合: 全項目集約 + full/degraded 一覧レポート
#
# 配置先:
#   $HOME/bin/idd-codex-modules/scaffolding-health.sh（install.sh が local-watcher/bin/idd-codex-modules/ から配置する）
#
# 依存:
#   - 本モジュールは idd-codex-issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$REPO / $NUMBER / $REPO_DIR / $BASE_BRANCH / $SCAFFOLDING_HEALTH_HALT 等）は
#     本体冒頭の Config ブロックで定義済み。bash の遅延束縛により呼び出し時に解決される
#     （sh_inspect_scaffolding 自体は $REPO に依存しない純関数）。
#   - 外部 CLI: date / find / test 演算子（`[ -d ]` 等）。gate の可視シグナルと doctor は
#     gh / jq / git も使う（いずれも read-only な参照のみ。可視シグナルの gh issue comment を除く）。
#
# セットアップ参照先:
#   - 要件: docs/specs/238-feat-watcher-scaffolding-health-gate-wor/requirements.md
#   - 設計: docs/specs/238-feat-watcher-scaffolding-health-gate-wor/design.md

# scaffolding-health 専用ロガー（既存 sav_* / qa_* と同形式 / Issue #119 規約）。
# 行頭 `[YYYY-MM-DD HH:MM:SS] [$REPO] scaffolding-health:` の 3 段 prefix を維持し、
# `grep '\[.*\] scaffolding-health:'` で全件抽出可能（Req 1.2, 1.4, 3.2, NFR 2.1）。
# sh_log は stdout、sh_warn / sh_error は >&2。$REPO は本体側グローバルの遅延束縛。
sh_log() {
  echo "[$(date '+%F %T')] [$REPO] scaffolding-health: $*"
}
sh_warn() {
  echo "[$(date '+%F %T')] [$REPO] scaffolding-health: WARN: $*" >&2
}
sh_error() {
  echo "[$(date '+%F %T')] [$REPO] scaffolding-health: ERROR: $*" >&2
}

# ─── sh_inspect_scaffolding ───
# 指定 worktree 配下の `.codex/agents` / `.codex/rules` の非空到達性を判定する純検査関数。
#
# 入力:
#   $1 = 検査対象の worktree 絶対パス（その配下の .codex/agents, .codex/rules を見る）
# stdout:
#   missing 時のみ機械可読サマリ `agents=<ok|missing> rules=<ok|missing>` を 1 行出力。
#   full 時・indeterminate 時は stdout に何も出さない。
# 戻り値:
#   0 = full          : 両ディレクトリに非空の通常ファイルが 1 つ以上ある
#   1 = missing       : いずれかのディレクトリが不在 or 空
#   2 = indeterminate : 真の I/O 異常で存否を確定できない（fail-open。呼び出し側で warn 継続）
#
# 制約:
#   - 副作用なし（read-only）。worktree / FS へ書き込まない。
#   - 同一 worktree 状態に対して常に同一戻り値（冪等 / Req 5.3, NFR 5.1）。
#   - 「非空の通常ファイルが 1 つ以上」を到達性 OK の基準とする（内容の正当性は検査しない）。
#     隠しファイル・サブディレクトリは到達性判定に算入しない（`find -type f -size +0c` 相当）。
#   - 「.codex/agents が単に不在」は missing であって indeterminate ではない。indeterminate は
#     test 自体が下せない真の I/O 異常に限定し、fail-open を濫用しない（design Decision 4）。
# Precondition: $1 は非空文字列（呼び出し側が $WT を渡す）。
sh_inspect_scaffolding() {
  local wt="${1:-}"

  # Precondition: 検査対象パスが空ならディレクトリ存否を確定できない真の異常として
  # indeterminate に倒す（fail-open / Req 3.1）。
  if [ -z "$wt" ]; then
    return 2
  fi

  local agents_dir="$wt/.codex/agents"
  local rules_dir="$wt/.codex/rules"

  # 親 `.codex` がファイル等で観測不能（dir でないのに存在する）な真の I/O 異常は
  # indeterminate に倒す。`.codex` が単に不在のケースは missing 経路で扱う（agents/rules
  # も不在として後段で missing 判定される）ため、ここでは弾かない。
  local codex_dir="$wt/.codex"
  if [ -e "$codex_dir" ] && [ ! -d "$codex_dir" ]; then
    return 2
  fi

  # 各ディレクトリに非空の通常ファイルが 1 つ以上あるかを判定する内部ヘルパ。
  # ディレクトリ不在 / 空 / 0 バイトファイルのみは NG（= missing 要素）。
  local agents_ok="missing"
  local rules_ok="missing"

  if [ -d "$agents_dir" ] && [ -n "$(find "$agents_dir" -type f -size +0c -print -quit 2>/dev/null)" ]; then
    agents_ok="ok"
  fi
  if [ -d "$rules_dir" ] && [ -n "$(find "$rules_dir" -type f -size +0c -print -quit 2>/dev/null)" ]; then
    rules_ok="ok"
  fi

  if [ "$agents_ok" = "ok" ] && [ "$rules_ok" = "ok" ]; then
    return 0
  fi

  echo "agents=${agents_ok} rules=${rules_ok}"
  return 1
}

# ─── _sh_emit_visibility_signal ───
# 足場欠落検出時に当該 Issue 上へ人間可視の痕跡（Issue コメント）を冪等・fail-open で残す。
#
# 入力:
#   $1 = 欠落サマリ（sh_inspect_scaffolding の stdout。例: "agents=missing rules=ok"）
#   env: REPO / NUMBER
# 戻り値:
#   常に 0（fail-open。投稿失敗・確認失敗で gate を倒さない / Req 1.3, NFR 5.1）
#
# 冪等性（Req 5.3 / NFR 5.1）:
#   コメント本文に機械可読マーカー `<!-- scaffolding-health:missing -->` を埋め込み、投稿前に
#   `gh issue view --json comments` で同マーカーの既存コメント有無を確認し、既存なら投稿を抑止する
#   （sticky comment 抑止パターン踏襲）。マーカー確認失敗時は fail-open で投稿を試みる
#   （取りこぼしより重複の方が安全）。
#
# 副作用:
#   - missing 検出時のみ Issue へコメント 1 件（冪等）。git 作業ツリー / FS へは書き込まない。
_sh_emit_visibility_signal() {
  local summary="${1:-}"
  local marker="<!-- scaffolding-health:missing -->"

  # 既存マーカーの有無を確認して重複投稿を抑止する（冪等）。確認に失敗した場合は
  # fail-open で投稿を試みる（取りこぼしより重複の方が安全）。
  local existing
  if existing=$(gh issue view "$NUMBER" --repo "$REPO" --json comments \
        --jq '.comments[].body' 2>/dev/null); then
    case "$existing" in
      *"$marker"*)
        sh_log "可視シグナル: 既存マーカー検出のためコメント投稿を抑止（冪等 / issue=#${NUMBER}）"
        return 0
        ;;
    esac
  else
    sh_warn "可視シグナル: 既存コメント確認に失敗（fail-open で投稿を試行 / issue=#${NUMBER}）"
  fi

  # コメント本文。固定テンプレ + 欠落サマリのみ（外部注入文字列を含めない / Security 節）。
  local body
  body="⚠️ scaffolding health gate が \`.codex\` 足場の欠落を検出しました（worktree への delivery が届いていない可能性）。

- 欠落サマリ: \`${summary}\`
- 影響: \`.codex/agents\` / \`.codex/rules\` が非空で揃わないと PM / Architect / Developer / Reviewer がルール非装備の degraded 状態で実行されます（#237 delivery / #238 verify）
- 対処: 当該 repo の \`.codex/\` delivery（gitignore / tracking 設定）を確認してください
- 本コメントは可視化のみ（既定）。停止挙動は \`SCAFFOLDING_HEALTH_HALT=on\` で opt-in できます

本機能の詳細: README「Scaffolding Health Gate / doctor (#238)」節
${marker}"

  if ! gh issue comment "$NUMBER" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    sh_warn "可視シグナル: gh issue comment 投稿に失敗（gate は継続 / issue=#${NUMBER}）"
  fi
  return 0
}

# ─── sh_preflight_gate ───
# Slot Runner から `_worktree_inject_codex` 直後・`_hook_invoke` 直前に 1 度だけ呼ばれる
# preflight ゲート。検査 → WARN → 可視シグナル → HALT 分岐を統合する。
#
# 入力:
#   $1 = worktree 絶対パス。env: SCAFFOLDING_HEALTH_HALT / REPO / NUMBER
# 戻り値:
#   0 = 継続してよい（full / 可視化のみ continue / fail-open continue）
#   1 = HALT（agent stage へ進めず人間判断待ちへ。呼び出し側が return 0 で当該 Issue を当該
#       サイクル終了する。codex-failed は付けない / Req 2.2）
#
# 不変条件:
#   - 1 回の呼び出しで必ず 1 行以上の `scaffolding-health:` ログを出す（silent 禁止 /
#     Req 1.4 / NFR 2.1）。
#   - full 時は Issue へ一切書き込まない（NO-OP / tracked 運用 repo の false positive 0 件 /
#     Req 1.5 / 5.1 / NFR 1.1）。
#   - indeterminate（戻り値 2）は HALT opt-in でも停止に倒さず継続する（Req 3.1, 3.3）。
sh_preflight_gate() {
  local wt="${1:-}"

  local summary=""
  local rc=0
  # sh_inspect_scaffolding は missing 時に stdout へサマリを出すため、戻り値とサマリの
  # 両方を取り込む（戻り値は `|| rc=$?` で捕捉し set -e で落とさない）。
  summary=$(sh_inspect_scaffolding "$wt") || rc=$?

  case "$rc" in
    0)
      # full: NO-OP。tracked 運用 repo はここに到達し WARN を出さない（Req 1.5 / 5.1 / NFR 1.1）。
      sh_log "outcome=pass scaffolding=full（agents/rules 双方非空 / NO-OP）"
      return 0
      ;;
    1)
      # missing: loud WARN（欠落内容含む）＋ 可視シグナル（Req 1.2 / 1.3）。
      sh_warn "足場欠落を検出: ${summary}（worktree=${wt}）"
      _sh_emit_visibility_signal "$summary"

      # HALT 値正規化: `on` 厳密一致のみ HALT。それ以外（off/未設定/空/true/On/typo）は
      # 既定の可視化のみ継続（stage-a-verify.sh の env 厳密一致判定パターン踏襲 / Req 2.1, 2.3）。
      case "${SCAFFOLDING_HEALTH_HALT:-off}" in
        on)
          sh_log "outcome=halt scaffolding=missing SCAFFOLDING_HEALTH_HALT=on（人間判断待ちへ遷移）"
          return 1
          ;;
        *)
          sh_log "outcome=continue scaffolding=missing SCAFFOLDING_HEALTH_HALT=off（可視化のみ・進行継続）"
          return 0
          ;;
      esac
      ;;
    *)
      # indeterminate（戻り値 2 / 真の I/O 異常）: warn を残して継続（fail-open）。
      # HALT opt-in でも停止に倒さない（検査異常で無実の Issue を止めない / Req 3.1, 3.2, 3.3）。
      sh_warn "足場検査が確定不能（I/O 異常等）: fail-open で継続（worktree=${wt}）"
      sh_log "outcome=continue scaffolding=indeterminate（fail-open / HALT opt-in でも停止しない）"
      return 0
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# doctor 点検サブコマンド（#238 Req 4 / 全 read-only・副作用なし）
#
# `idd-codex-issue-watcher.sh --doctor` から `sh_doctor_run` が 1 度呼ばれ、各 `sh_doctor_check_*` を
# 集約して repo を full / degraded として識別できる一覧レポートを出力する。すべての点検は
# read-only であり、git 作業ツリー・index・refs を変更せず、Issue / PR / ラベルへ書き込む API を
# 呼ばない（NFR 4.1）。
#
# 各 `sh_doctor_check_*` の契約:
#   - stdout に `  <項目名>: <ok|degraded|unknown> (<詳細>)` を 1 行出力する（レポート行）。
#   - 戻り値 0 = ok / 1 = degraded。点検不能（gh 不達等）は degraded ではなく `unknown` 表示とし、
#     戻り値は 0（unknown は repo 全体 degraded への昇格に算入しない / Error Handling 節）。
# ─────────────────────────────────────────────────────────────────────────────

# ─── sh_doctor_check_scaffolding ───
# REPO_DIR 配下の `.codex/agents` / `.codex/rules` 非空到達性を点検する（Req 4.2）。
# sh_inspect_scaffolding を流用し、$1=REPO_DIR を検査対象とする。
# 入力: env REPO_DIR
# 戻り値: 0 = ok / 1 = degraded
sh_doctor_check_scaffolding() {
  local summary=""
  local rc=0
  summary=$(sh_inspect_scaffolding "$REPO_DIR") || rc=$?
  case "$rc" in
    0)
      printf '  %-42s: %s (%s)\n' "scaffolding (.codex/agents,.codex/rules)" "ok" "agents=ok rules=ok"
      return 0
      ;;
    1)
      printf '  %-42s: %s (%s)\n' "scaffolding (.codex/agents,.codex/rules)" "degraded" "$summary"
      return 1
      ;;
    *)
      printf '  %-42s: %s (%s)\n' "scaffolding (.codex/agents,.codex/rules)" "unknown" "検査確定不能（I/O 異常等）"
      return 0
      ;;
  esac
}

# ─── sh_doctor_check_clis ───
# 依存 CLI（gh / jq / flock / git / codex）の存在可否を `command -v` で点検する（Req 4.3）。
# 戻り値: 0 = 全在 ok / 1 = 1 つ以上欠落 degraded
sh_doctor_check_clis() {
  local missing=""
  local cli
  for cli in gh jq flock git codex; do
    if ! command -v "$cli" >/dev/null 2>&1; then
      missing="${missing:+$missing }$cli"
    fi
  done
  if [ -z "$missing" ]; then
    printf '  %-42s: %s\n' "required CLIs (gh/jq/flock/git/codex)" "ok"
    return 0
  fi
  printf '  %-42s: %s (missing: %s)\n' "required CLIs (gh/jq/flock/git/codex)" "degraded" "$missing"
  return 1
}

# ─── sh_doctor_check_labels ───
# ワークフローが前提とする必須ラベル集合の存在可否を `gh label list`（read-only）で点検する
# （Req 4.4）。`gh` 不達等で点検不能なときは degraded ではなく `unknown` 表示（戻り値 0）。
#
# 必須ラベル集合の Single Source of Truth は本関数に明示列挙する。
# ⚠️ 乖離注意: ラベル定義の正本は `.github/scripts/idd-codex-labels.sh` の `LABELS` 配列だが、
#   doctor は別実行基盤（本体 source モジュール）であり共有コードを持てないため、ワークフロー
#   進行に必須な中核ラベルのみを本関数に再列挙している。`idd-codex-labels.sh` 側のラベル名を
#   変更・追加した場合は本関数の `_required` も同期更新すること（両者の乖離はドリフトを招く）。
# 戻り値: 0 = 全在 ok または unknown（点検不能）/ 1 = 1 つ以上欠落 degraded
sh_doctor_check_labels() {
  # ワークフロー進行に必須な中核ラベル（idd-codex-labels.sh の LABELS 配列のうち中核分を再列挙）。
  local _required=( codex-auto-dev codex-claimed codex-picked-up codex-ready-for-review codex-failed \
    codex-needs-decisions codex-awaiting-design-review codex-needs-iteration codex-needs-rebase )

  local list_json=""
  if ! list_json=$(gh label list --repo "$REPO" --limit 1000 --json name 2>/dev/null); then
    printf '  %-42s: %s (%s)\n' "required labels" "unknown" "gh label list 不達（read-only 点検不能）"
    return 0
  fi

  local missing=""
  local lbl
  for lbl in "${_required[@]}"; do
    # jq で当該ラベル名の存在を確認（read-only）。
    if ! printf '%s' "$list_json" | jq -e --arg n "$lbl" '.[] | select(.name == $n)' >/dev/null 2>&1; then
      missing="${missing:+$missing }$lbl"
    fi
  done

  if [ -z "$missing" ]; then
    printf '  %-42s: %s\n' "required labels" "ok"
    return 0
  fi
  printf '  %-42s: %s (missing: %s)\n' "required labels" "degraded" "$missing"
  return 1
}

# ─── sh_doctor_check_base_branch ───
# base ブランチ（origin/${BASE_BRANCH}）の解決可否を `git rev-parse --verify`（read-only）で
# 点検する（Req 4.5）。git 作業ツリー / index / refs を変更しない。
# 入力: env REPO_DIR / BASE_BRANCH
# 戻り値: 0 = 解決可 ok / 1 = 解決不能 degraded
sh_doctor_check_base_branch() {
  local ref="origin/${BASE_BRANCH}"
  if git -C "$REPO_DIR" rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
    printf '  %-42s: %s\n' "base branch (${ref})" "ok"
    return 0
  fi
  printf '  %-42s: %s (%s)\n' "base branch (${ref})" "degraded" "解決不能（fetch 済みか / ブランチ名を確認）"
  return 1
}

# ─── sh_doctor_run ───
# doctor の統合ランナー。現行 env で解決された REPO / REPO_DIR / BASE_BRANCH の 1 組を点検し、
# 全 `sh_doctor_check_*` を集約して full / degraded を識別できる一覧レポートを出力する（Req 4.1,
# 4.6）。1 項目でも degraded なら repo 全体を degraded と表示する。点検不能項目は unknown 表示で
# あり、repo 全体 degraded への昇格に算入しない（Error Handling 節）。
#
# 入力: env REPO / REPO_DIR / BASE_BRANCH
# stdout: 構造化された点検レポート（ヘッダ + 各項目 + RESULT 行）
# 戻り値: 0（レポート出力完了。degraded 検出は異常終了ではない / Req 5.2。dispatch 側で exit $?）
#
# 性能（NFR 3.1）: ローカル検査主体で repo 1 件あたり数秒以内。`gh label list` のネットワーク
# 待ちは NFR 3.1 の「ネットワーク待ち時間を除き」に該当する。
# read-only（NFR 4.1）: git/Issue/PR/ラベルへ書き込まない。
sh_doctor_run() {
  echo "=== idd-codex doctor: ${REPO} (REPO_DIR=${REPO_DIR}) ==="

  local overall="full"

  # 各点検を実行する。点検が degraded（戻り値 1）を返したら repo 全体を degraded に昇格させる。
  # unknown（点検不能）は戻り値 0 のため昇格に算入しない（レポート行に unknown と表示済み）。
  sh_doctor_check_scaffolding || overall="degraded"
  sh_doctor_check_clis        || overall="degraded"
  sh_doctor_check_labels      || overall="degraded"
  sh_doctor_check_base_branch || overall="degraded"

  echo "  ----------------------------------------------------------------"
  echo "  RESULT: ${overall}"
  return 0
}
