#!/usr/bin/env bash
# shellcheck shell=bash
# pr-iteration.sh — watcher の PR Iteration Processor モジュール
#
# 用途:
#   idd-codex-issue-watcher.sh から切り出した PR Iteration Processor (#26) の関数定義を集約する。
#   `codex-needs-iteration` ラベルが付いた idd-codex 管理下 PR を fresh context の Codex で
#   反復対応する。Phase A と同じ flock 境界内で直列実行され、対象 PR 集合は server-side
#   label query で Phase A と直交させている。標準機能としてデフォルト有効（#112）。
#   無効化は PR_ITERATION_ENABLED=false で明示する。
#   - 候補 PR 取得・フィルタ: pi_pr_has_label / pi_fetch_candidate_prs /
#     pi_general_filter_* / pi_collect_general_comments
#   - round / streak 管理: pi_resolve_max_rounds（kind 別 max rounds #122）/
#     pi_read_round_counter / pi_read_no_progress_streak / pi_read_last_run /
#     pi_write_marker / pi_post_processing_comment / pi_post_processing_marker
#   - ラベル確定 / 分類 / template: pi_finalize_labels / pi_finalize_labels_design /
#     pi_classify_pr_kind / pi_select_template
#   - 反復実行: build_recovery_hint（pi_ 命名でないが pi 系から呼ばれるため同居）/
#     pi_escalate_to_failed / pi_build_iteration_prompt / pi_detect_quota_soft_fail /
#     pi_branch_is_codex_pr_head / pi_auto_commit_and_push / pi_run_iteration /
#     process_pr_iteration（エントリ関数）
#
# 配置先:
#   $HOME/bin/idd-codex-modules/pr-iteration.sh（install.sh が local-watcher/bin/idd-codex-modules/ から配置する）
#
# 依存:
#   - 本モジュールは idd-codex-issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー pi_log / pi_warn / pi_error は core_utils.sh に定義済みのため本モジュールでは
#     再定義しない（#180 Part 2 で core_utils.sh へ集約済み）。
#   - グローバル変数（$REPO / $BASE_BRANCH / $PR_ITERATION_ENABLED /
#     $PR_ITERATION_MAX_ROUNDS* / $PR_ITERATION_GIT_TIMEOUT / $ITERATION_TEMPLATE* /
#     $LABEL_NEEDS_ITERATION / $LABEL_FAILED 等）は本体冒頭の Config ブロックで定義済み。
#     bash の遅延束縛により呼び出し時に解決される。
#   - top-level orchestration 呼び出し配線（process_pr_iteration || pi_warn ...）は
#     本体 entry point に残置する（本モジュールは関数定義のみ / #181 design.md）。
#   - 外部 CLI: gh / git / jq / codex。
#
# セットアップ参照先:
#   - 設計: docs/specs/181-feat-watcher-issue-watcher-sh-part-3-pr/design.md
#   - README「PR Iteration Processor」節

# PR ラベル一覧に特定ラベルが含まれるかを判定（jq で labels 配列を走査）
pi_pr_has_label() {
  local pr_json="$1"
  local label="$2"
  echo "$pr_json" | jq -e --arg l "$label" '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_fetch_candidate_prs: server-side + client-side の二段フィルタで候補 PR を返す
#   出力: stdout に jq 配列形式の JSON 1 行（候補なしなら "[]"）
#   AC 1.1, 1.2, 1.3, 1.4, 1.5, 8.4
# ─────────────────────────────────────────────────────────────────────────────
pi_fetch_candidate_prs() {
  local repo_owner="${REPO%%/*}"
  local prs_json
  # AC 1.1 / 1.4 / 1.5 / 8.4: codex-needs-iteration 付き、codex-failed /
  # codex-needs-rebase / codex-needs-quota-wait / codex-needs-decisions 無し、非 draft
  if ! prs_json=$(timeout "$PR_ITERATION_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "label:\"$LABEL_NEEDS_ITERATION\" -label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_REBASE\" -label:\"$LABEL_NEEDS_QUOTA_WAIT\" -label:\"$LABEL_NEEDS_DECISIONS\" -draft:true" \
      --json number,headRefName,baseRefName,isDraft,url,labels,headRepositoryOwner,body \
      --limit 50 2>/dev/null); then
    pi_warn "codex-needs-iteration PR の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    echo "[]"
    return 0
  fi

  # AC 1.2 / 1.3 / 1.4: クライアント側フィルタ（server filter の保険 + head pattern + fork 除外）
  # #35 AC 4.4 / 5.1: design pattern は PR_ITERATION_DESIGN_ENABLED=true のときのみ OR 条件に
  # 含める。#112 以降デフォルトは true。明示的に false を渡した場合のみ impl pattern だけで
  # 絞り込み、設計 PR は candidate 段階で除外される（= 設計 PR 拡張 #35 導入前と同一の挙動）。
  echo "$prs_json" | jq \
    --arg impl_pattern "$PR_ITERATION_HEAD_PATTERN" \
    --arg design_pattern "$PR_ITERATION_DESIGN_HEAD_PATTERN" \
    --arg design_enabled "$PR_ITERATION_DESIGN_ENABLED" \
    --arg owner "$repo_owner" \
    '[.[]
      | select(.isDraft == false)
      | select((.headRepositoryOwner.login // "") == $owner)
      | select(
          (.headRefName | test($impl_pattern))
          or
          ($design_enabled == "true" and (.headRefName | test($design_pattern)))
        )
    ]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_resolve_max_rounds: kind に対応する round 上限を解決する（Issue #122 Req 1）
#   入力: $1 = kind ("impl" / "design")
#   出力: stdout に 0 以上の整数（`0` は無制限の sentinel / Req 2）
#   返り値: 0=成功 / 1=未知 kind
#
#   優先順序（Req 1.1〜1.4）:
#     1. kind 固有 env（PR_ITERATION_MAX_ROUNDS_IMPL / PR_ITERATION_MAX_ROUNDS_DESIGN）が
#        非空ならその値を採用
#     2. 旧 PR_ITERATION_MAX_ROUNDS が設定されていれば両 kind の fallback として採用
#     3. いずれも未設定なら impl=3, design=0 を適用
#
#   設計判断:
#     - 値の妥当性（非負整数）は呼び出し元で `[ "$v" -ge "..." ]` 形式の比較に
#       入ってくる時点で bash の算術評価で検出されるため、ここでは defensive に
#       数値化のみ実施し、不正値（負・非数値）は受信時点で 0 にフォールバックさせない
#       （運用者の typo を握り潰さない方針 / 設計判断）。代わりに呼び出し元で
#       通常通り比較が落ちる挙動に任せる。
# ─────────────────────────────────────────────────────────────────────────────
pi_resolve_max_rounds() {
  local kind="$1"
  local kind_specific=""
  local default_value=""
  case "$kind" in
    impl)
      kind_specific="${PR_ITERATION_MAX_ROUNDS_IMPL:-}"
      default_value="3"
      ;;
    design)
      kind_specific="${PR_ITERATION_MAX_ROUNDS_DESIGN:-}"
      default_value="0"
      ;;
    *)
      pi_warn "pi_resolve_max_rounds: 未知の kind=${kind}"
      return 1
      ;;
  esac

  # Req 1.1 / 1.2: kind 固有 env が非空ならその値を採用
  if [ -n "$kind_specific" ]; then
    echo "$kind_specific"
    return 0
  fi
  # Req 1.3: 旧 PR_ITERATION_MAX_ROUNDS が「明示設定されている」場合は fallback として
  # 採用。冒頭で "${...:-3}" 展開されるため変数自体には常に値が入るが、設定有無は
  # PR_ITERATION_MAX_ROUNDS_LEGACY_SET フラグで判別する。明示設定されていれば旧運用
  # （impl/design 共通 3 round 制限）と互換になるよう、design 側にも同値を適用する。
  if [ "${PR_ITERATION_MAX_ROUNDS_LEGACY_SET:-false}" = "true" ]; then
    echo "${PR_ITERATION_MAX_ROUNDS}"
    return 0
  fi
  # Req 1.4: 全未設定なら kind ごとの default を返す（impl=3, design=0）
  echo "$default_value"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_read_round_counter: PR body から hidden marker の round 数を取得
#   入力: $1=pr_number
#   出力: stdout に round 数（marker 無しなら 0）
#   AC 7.1, 7.4
# ─────────────────────────────────────────────────────────────────────────────
pi_read_round_counter() {
  local pr_number="$1"
  local body
  if ! body=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null); then
    pi_warn "PR #${pr_number}: body 取得に失敗、round=0 として扱います"
    echo "0"
    return 0
  fi
  # marker 形式: <!-- idd-codex:pr-iteration round=N last-run=... -->
  # 複数検出時は最後（最新）の数値を採用 = fail-safe
  local round
  round=$(echo "$body" \
    | grep -oE 'idd-codex:pr-iteration round=[0-9]+' \
    | grep -oE '[0-9]+$' \
    | tail -1)
  echo "${round:-0}"
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_read_no_progress_streak: PR body から hidden marker の no-progress 連続カウンタを取得
#   入力: $1=pr_body (gh pr view --json body --jq '.body // ""' で取得済みの文字列)
#   出力: stdout に整数（key 不在 / marker 不在なら "0"）
#   返り値: 0 固定
#   Issue #122 Req 3.6 / 4.2 / 4.4 / 4.5
#
#   marker 形式: <!-- idd-codex:pr-iteration round=N last-run=ISO8601 no-progress-streak=K -->
#   既存 marker（no-progress-streak キー無し）の場合は "0" を返す（Req 4.2 / 4.4 後方互換）。
#   複数 marker がある場合は末尾を採用（既存 pi_read_round_counter / pi_read_last_run と整合）。
# ─────────────────────────────────────────────────────────────────────────────
pi_read_no_progress_streak() {
  local pr_body="${1-}"
  if [ -z "$pr_body" ]; then
    echo "0"
    return 0
  fi
  local streak
  streak=$(echo "$pr_body" \
    | grep -oE 'idd-codex:pr-iteration [^>]*no-progress-streak=[0-9]+' \
    | grep -oE 'no-progress-streak=[0-9]+' \
    | grep -oE '[0-9]+$' \
    | tail -1)
  echo "${streak:-0}"
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_read_last_run: PR body から hidden marker の last-run ISO8601 タイムスタンプを抽出
#   入力: $1=pr_body（gh pr view --json body --jq '.body // ""' で取得済みの文字列）
#   出力: stdout に last-run の ISO8601 文字列（例: "2026-04-25T12:34:56Z"）。
#         marker / last-run キーが無ければ空文字列を出力。
#   返り値: 0 固定（呼び出し元で空文字列を初回 round 扱いにする）
#   AC #55 Req 2.3, 2.4 / 4.1
#
#   marker 形式: <!-- idd-codex:pr-iteration round=N last-run=ISO8601 -->
#   複数検出時は最後（最新）の値を採用（pi_read_round_counter の `tail -1` と整合）。
#   読み取り専用であり、書き込み側は pi_post_processing_marker のまま温存（後方互換性）。
# ─────────────────────────────────────────────────────────────────────────────
pi_read_last_run() {
  local pr_body="${1-}"
  if [ -z "$pr_body" ]; then
    echo ""
    return 0
  fi
  local last_run
  # 1. marker 行を抽出 → 2. `last-run=...` 部分のみを抽出 → 3. 末尾を採用
  #    値部分はスペース・`>` 以外を許容（pi_post_processing_marker は ISO8601 UTC を打刻するが、
  #    fail-safe としてスペース直前 / `>` 直前まで拾う）。
  last_run=$(echo "$pr_body" \
    | grep -oE 'idd-codex:pr-iteration round=[0-9]+ last-run=[^ >]+' \
    | sed -E 's|.*last-run=||' \
    | tail -1)
  echo "${last_run:-}"
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_read_usage_fatal_count: PR body から usage-limit 風 fatal error の連続回数を取得
#   入力: $1=pr_body, $2=round
#   出力: stdout に整数（marker 不在なら "0"）
#   marker 形式: <!-- idd-codex:pr-iteration-usage-fatal round=N count=K -->
# ─────────────────────────────────────────────────────────────────────────────
pi_read_usage_fatal_count() {
  local pr_body="${1-}"
  local round="${2:-0}"
  if [ -z "$pr_body" ]; then
    echo "0"
    return 0
  fi
  local count
  count=$(echo "$pr_body" \
    | grep -oE "idd-codex:pr-iteration-usage-fatal round=${round} count=[0-9]+" \
    | grep -oE 'count=[0-9]+' \
    | grep -oE '[0-9]+$' \
    | tail -1)
  echo "${count:-0}"
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_filter_self: watcher 自身の自動投稿コメントを除外（marker ベース）
#   入力: stdin に一般コメント JSON 配列
#   出力: stdout にフィルタ後の JSON 配列
#   AC #55 Req 2.1, 2.7
#
#   判定: comment.body 中に PR Iteration Processor 自身の HTML hidden marker
#   (`idd-codex:pr-iteration` 系) を含むなら watcher 投稿として除外する。
#   PR reviewer の `idd-codex:pr-reviewer` marker は iteration 入力として残す。
#   GitHub user 同一性に依存しない（cron 実行ホストが異なる GitHub user で動いていても
#   確実に除外できる）。`@codex` 文字列には一切依存しない（Req 2.7）。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_filter_self() {
  jq '[.[] | select((.body // "") | test("<!--[[:space:]]*idd-codex:pr-iteration([[:space:]>-]|$)") | not)]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_filter_untrusted_authors: 未信頼 author のコメントを除外（Issue #50）
#   入力: stdin に raw comments JSON 配列（GitHub REST 形式。author_association を含む）
#   出力: stdout にフィルタ後の JSON 配列
#
#   公開 repo では誰でも PR にコメントでき、その本文がそのまま iteration プロンプト経由で
#   codex agent への指示として流れる（prompt injection 面）。信頼できる author_association
#   （既定 OWNER/MEMBER/COLLABORATOR）のコメントのみ採用し、外部ユーザの投稿を入力から外す。
#   env PR_ITERATION_TRUSTED_ASSOCIATIONS で上書き可能。raw 段（projection 前）で適用する
#   ため、後段の射影スキーマには author_association を持ち込まない（template 互換維持）。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_filter_untrusted_authors() {
  local trusted="${PR_ITERATION_TRUSTED_ASSOCIATIONS:-OWNER MEMBER COLLABORATOR}"
  jq --arg trusted "$trusted" '
    ($trusted | ascii_upcase | split(" ")) as $t
    | [ .[]? | select(((.author_association // "") | ascii_upcase) as $a | ($t | any(. == $a))) ]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_filter_resolved: 過去 round で対応済みと判定できるコメントを除外
#   入力: $1=last_run (ISO8601 string, 空文字列 = 初回 round)
#         stdin に一般コメント JSON 配列
#   出力: stdout にフィルタ後の JSON 配列
#   AC #55 Req 2.2, 2.3, 2.4, 2.5, 2.7
#
#   判定: last_run が空文字列なら no-op（全件採用 = 初回 round, Req 2.4）。
#         last_run が指定されている場合は `created_at > last_run` のコメントのみ採用。
#         境界（`==`）は採用側に倒さず除外する（fail-safe、設計判断 Req 2.3 解釈）。
#         比較は ISO8601 lex compare（GitHub の created_at は UTC `Z` 終端で揃う）。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_filter_resolved() {
  local last_run="${1-}"
  jq --arg last_run "$last_run" \
    '[.[] | select($last_run == "" or (.created_at // "") > $last_run)]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_filter_excessive: adjudicator が excessive と判定した指摘コメントを除外
#   入力: stdin に一般コメント JSON 配列
#   出力: stdout にフィルタ後の JSON 配列
#   Issue #404 Req 2.4, 2.5, 4.3 / NFR 1.1, NFR 2.2
#
#   判定: gate ON (PR_REVIEWER_ADJUDICATOR_ENABLED=true) のときのみ、comment.body 中に
#         `idd-codex:pr-adjudicator-excessive` を含む HTML hidden marker を持つコメントを
#         除外する。gate OFF / 未設定 / 不正値 / typo はすべて jq '.' で pass-through
#         （既存件数挙動を維持 / NFR 1.1）。env 値判定は厳密 `=true` 一致のみで ON とする
#         （idd-codex-issue-watcher.sh が `case true) ... *) false` 正規化済みの env を渡す
#         前提に整合 / adj_gate_enabled と同方針）。
#
#   設計判断（design.md Components and Interfaces 節）:
#     - gate 判定を本関数内で完結させ、呼び出し元（pi_collect_general_comments）からは
#       無条件で chain に挿入する形に倒す。これにより gate OFF 時の filter chain も
#       `self → resolved → excessive → event_style → truncate` の同一構成となり、
#       サマリ 1 行ログに `filtered_excessive=0` が常時記録される（観測可能性 / Req 4.4）
#     - 既存 pi_general_filter_self は `idd-codex:pr-iteration` prefix のみを対象とする。
#       `pr-adjudicator-excessive` は前方一致しないため self-filter と衝突しない（Req 4.3 /
#       NFR 1.2）。adjudicator 側 summary marker `idd-codex:pr-adjudicator sha=...` も
#       `pr-adjudicator-excessive` を substring に持たないため本関数を素通りする
#       （summary は iteration agent への情報として keep）。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_filter_excessive() {
  if [ "${PR_REVIEWER_ADJUDICATOR_ENABLED:-false}" = "true" ]; then
    jq '[.[] | select((.body // "") | contains("idd-codex:pr-adjudicator-excessive") | not)]'
  else
    jq '.'
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_filter_oos: adjudicator が out-of-scope と判定した指摘コメントを除外
#   入力: stdin に一般コメント JSON 配列
#   出力: stdout にフィルタ後の JSON 配列
#   Issue #146（idd-claude #437 移植）
#
#   判定: gate ON (PR_ITERATION_OOS_ENABLED=true) のときのみ、comment.body 中に
#         `idd-codex:pr-adjudicator-out-of-scope` を含む HTML hidden marker を持つ
#         コメントを除外する。gate OFF / 未設定 / 不正値 / typo はすべて jq '.' で
#         pass-through（既存件数挙動を維持）。env 値判定は厳密 `=true` 一致のみで ON とする
#         （idd-codex-issue-watcher.sh が `case true) ... *) false` 正規化済みの env を渡す
#         前提に整合 / pi_general_filter_excessive と同方針）。
#
#   設計判断:
#     - gate 判定を本関数内で完結させ、呼び出し元（pi_collect_general_comments）からは
#       無条件で chain に挿入する形に倒す。これにより gate OFF 時の filter chain も
#       `self → resolved → excessive → out-of-scope → event_style → truncate` の同一構成と
#       なり、サマリ 1 行ログに `filtered_oos=0` が常時記録される（観測可能性）
#     - prefix `pr-adjudicator-out-of-scope` は既存 `pr-adjudicator-excessive` /
#       `pr-iteration` のいずれとも前方一致しないため self-filter / excessive-filter と
#       衝突しない。adjudicator summary marker `idd-codex:pr-adjudicator sha=...` も
#       `pr-adjudicator-out-of-scope` を substring に持たないため本関数を素通りする
#       （summary は iteration agent への情報として keep）。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_filter_oos() {
  if [ "${PR_ITERATION_OOS_ENABLED:-false}" = "true" ]; then
    jq '[.[] | select((.body // "") | contains("idd-codex:pr-adjudicator-out-of-scope") | not)]'
  else
    jq '.'
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_filter_event_style: GitHub system 由来の event-style コメントを除外
#   入力: stdin に一般コメント JSON 配列
#   出力: stdout にフィルタ後の JSON 配列
#   AC #55 Req 2.6, 2.7
#
#   判定: user.type == "Bot" のコメント、および body が空のコメントを除外する。
#         /repos/.../issues/<n>/comments は基本的にユーザーコメントしか返さないため
#         保険的なフィルタだが、Req 2.6 を観測可能に保つために独立化する。
#         watcher 自身の投稿は marker で既に除外済みのため、ここで Bot を全体除外しても
#         二重除外にならず安全。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_filter_event_style() {
  jq '[.[] | select((.user.type // "") != "Bot" and (.body // "") != "")]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_truncate: 件数上限超過時に古い順 drop で削減
#   入力: $1=limit (件数上限)
#         stdin に一般コメント JSON 配列
#   出力: stdout に削減後の JSON 配列
#   AC #55 Req 3.1, 3.4
#
#   アルゴリズム:
#     1. 入力配列 length が limit 以下 → no-op（Req 3.4）
#     2. length > limit → created_at 昇順ソート → 末尾 limit 件を採用（古い順 drop）
#       新しいコメントが残るため、レビュワーが直近に追加した指摘を優先できる。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_truncate() {
  local limit="${1:-50}"
  jq --argjson limit "$limit" \
    'if length <= $limit then . else (sort_by(.created_at // "") | .[-$limit:]) end'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_collect_general_comments: 一般コメント収集 + 3 段フィルタ + 削減のオーケストレーション
#   入力: $1=pr_number
#         $2=pr_body (gh pr view --json body --jq '.body // ""' で取得済みの文字列)
#   出力: stdout に JSON 配列文字列。要素スキーマ:
#         { id, user, body, url, created_at }
#         取得失敗時 / コメント 0 件時は "[]"。
#   返り値: 0 固定（エラーは degraded path = "[]" + WARN ログに倒す）
#   AC #55 Req 1.1, 1.2, 1.5, 2.5, 3.2, 4.2, 4.3, 4.4, 4.6, 6.2, NFR 1.1, NFR 1.2,
#         NFR 2.1, NFR 2.2
#
#   設計判断:
#     - kind（design/impl）に依存する分岐を持たない（impl/design PR で共通呼び出し、Req 6.2）
#     - @codex 文字列を判定式に使わない（Req 2.7、`@codex` mention 必須を opt-out で
#       復活させる新規 env var を追加しない、Req 4.4）
#     - 上限値は内部定数 PI_GENERAL_MAX_COMMENTS（既定 50、env override 可）
#       README には載せない（運用上 default で十分、Req 4.4 の対象外）
#     - サマリは 1 行で出力し、truncate 発動時のみ pi_warn、それ以外は pi_log（NFR 2.2）
# ─────────────────────────────────────────────────────────────────────────────
pi_collect_general_comments() {
  local pr_number="$1"
  local pr_body="${2-}"
  local limit="${PI_GENERAL_MAX_COMMENTS:-50}"

  # 1. GitHub API から raw 一般コメントを取得（既存と同じ timeout / fall-back 方式）
  local raw_general
  if ! raw_general=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh api "/repos/${REPO}/issues/${pr_number}/comments" 2>/dev/null); then
    pi_warn "PR #${pr_number}: 一般コメント取得に失敗、空配列で続行"
    echo "[]"
    return 0
  fi

  # 1.5. Issue #50: 未信頼 author のコメントを除外（author_association を持つ raw 段で適用）。
  #      公開 repo では未信頼の外部コメント本文が codex agent への指示として流入しうるため、
  #      信頼できる author のコメントのみ後段へ渡す。
  local trusted_general
  if ! trusted_general=$(printf '%s' "$raw_general" | pi_general_filter_untrusted_authors 2>/dev/null); then
    pi_warn "PR #${pr_number}: author 信頼フィルタに失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  raw_general="$trusted_general"

  # 2. 射影: { id, user, body, url, created_at } のスキーマに整形（Req 6.2 / Data Model）
  local projected
  if ! projected=$(echo "$raw_general" | jq '[.[] | {
        id,
        user: (.user.login // ""),
        body: (.body // ""),
        url: .html_url,
        created_at: (.created_at // ""),
        "_meta_user_type": (.user.type // "")
      }]' 2>/dev/null); then
    pi_warn "PR #${pr_number}: 一般コメント JSON の整形に失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local fetched
  fetched=$(echo "$projected" | jq 'length' 2>/dev/null || echo "0")

  # 3. last-run TS を抽出（marker 不在時は空文字列 = 初回 round）
  local last_run
  last_run=$(pi_read_last_run "$pr_body")

  # 4. フィルタを順次適用しながら各段の length を測定
  #    順序: self → resolved → excessive → out-of-scope → event_style → truncate
  #    Issue #404: adjudicator が excessive と判定した指摘コメントを除外する excessive 段を
  #    resolved の直後 / event_style の前に挿入。gate OFF 時は内部で pass-through するため
  #    既存件数挙動には影響しない（NFR 1.1）。
  #    Issue #146: adjudicator が out-of-scope と判定した指摘コメントを除外する out-of-scope
  #    段を excessive の直後 / event_style の前に挿入。gate（PR_ITERATION_OOS_ENABLED）OFF 時は
  #    内部で pass-through するため既存件数挙動に影響しない。
  local after_self after_resolved after_excessive after_oos after_event final
  local filter_event_input

  # event_style filter は射影段で残した _meta_user_type を user.type の代理として使う
  # （元 jq schema を {id,user,body,url,created_at} に保つ理由: prompt template 互換）
  if ! after_self=$(echo "$projected" | pi_general_filter_self 2>/dev/null); then
    pi_warn "PR #${pr_number}: 自己投稿フィルタに失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local count_self
  count_self=$(echo "$after_self" | jq 'length' 2>/dev/null || echo "0")

  if ! after_resolved=$(echo "$after_self" | pi_general_filter_resolved "$last_run" 2>/dev/null); then
    pi_warn "PR #${pr_number}: 過去 round フィルタに失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local count_resolved
  count_resolved=$(echo "$after_resolved" | jq 'length' 2>/dev/null || echo "0")

  # Issue #404: excessive フィルタ（gate ON 時のみ marker 除外、OFF 時 pass-through）
  if ! after_excessive=$(echo "$after_resolved" | pi_general_filter_excessive 2>/dev/null); then
    pi_warn "PR #${pr_number}: excessive フィルタに失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local count_excessive
  count_excessive=$(echo "$after_excessive" | jq 'length' 2>/dev/null || echo "0")

  # Issue #146: out-of-scope フィルタ（gate ON 時のみ marker 除外、OFF 時 pass-through）
  if ! after_oos=$(echo "$after_excessive" | pi_general_filter_oos 2>/dev/null); then
    pi_warn "PR #${pr_number}: out-of-scope フィルタに失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local count_oos
  count_oos=$(echo "$after_oos" | jq 'length' 2>/dev/null || echo "0")

  # event_style フィルタは _meta_user_type を user.type 相当に詰め直してから判定する
  filter_event_input=$(echo "$after_oos" | jq '[.[] | . + {user: {type: ._meta_user_type, login: (.user)}}]' 2>/dev/null || echo "[]")
  if ! after_event=$(echo "$filter_event_input" | pi_general_filter_event_style 2>/dev/null); then
    pi_warn "PR #${pr_number}: event-style フィルタに失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  # スキーマ復元: user は文字列 (login) のみに戻し、_meta_user_type も落とす
  after_event=$(echo "$after_event" | jq '[.[] | {id, user: (.user.login // ""), body, url, created_at}]' 2>/dev/null || echo "[]")
  local count_event
  count_event=$(echo "$after_event" | jq 'length' 2>/dev/null || echo "0")

  if ! final=$(echo "$after_event" | pi_general_truncate "$limit" 2>/dev/null); then
    pi_warn "PR #${pr_number}: truncate に失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local count_final
  count_final=$(echo "$final" | jq 'length' 2>/dev/null || echo "0")

  # 5. サマリ 1 行ログ
  # Issue #404: filtered_excessive を filtered_resolved と filtered_event の間に追加。
  # gate OFF 時は pi_general_filter_excessive が pass-through するため filtered_excessive=0 と
  # なり、観測者が「gate が無効か機能してないか」をログ 1 行で確認できる（Req 4.4 観測可能性）。
  # Issue #146: filtered_oos を filtered_excessive と filtered_event の間に追加。
  # gate（PR_ITERATION_OOS_ENABLED）OFF 時は pi_general_filter_oos が pass-through するため
  # filtered_oos=0 となる（観測可能性 / 既存件数挙動不変）。
  local filtered_self filtered_resolved filtered_excessive filtered_oos filtered_event truncated
  filtered_self=$((fetched - count_self))
  filtered_resolved=$((count_self - count_resolved))
  filtered_excessive=$((count_resolved - count_excessive))
  filtered_oos=$((count_excessive - count_oos))
  filtered_event=$((count_oos - count_event))
  truncated=$((count_event - count_final))

  # サマリは stderr に出力する（本関数の stdout は JSON 配列に予約されているため）。
  # pi_warn は元々 stderr 直行、pi_log は stdout のため明示的に >&2 で逃がす。
  if [ "$truncated" -gt 0 ]; then
    pi_warn "PR #${pr_number} general comments: fetched=${fetched}, filtered_self=${filtered_self}, filtered_resolved=${filtered_resolved}, filtered_excessive=${filtered_excessive}, filtered_oos=${filtered_oos}, filtered_event=${filtered_event}, truncated=${truncated} (limit=${limit}), final=${count_final}"
  else
    pi_log "PR #${pr_number} general comments: fetched=${fetched}, filtered_self=${filtered_self}, filtered_resolved=${filtered_resolved}, filtered_excessive=${filtered_excessive}, filtered_oos=${filtered_oos}, filtered_event=${filtered_event}, truncated=0, final=${count_final}" >&2
  fi

  echo "$final"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_post_processing_marker: PR body に hidden marker を書き込み + 着手表明コメント投稿
#   入力: $1=pr_number, $2=new_round
#   AC 6.1, 7.1
#   戻り値: 0=成功, 1=失敗（呼び出し元で iteration を中断）
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# pi_write_marker: PR body の hidden marker を round + last-run + no-progress-streak
#   の 3 フィールド形式で書き換える（Issue #122 Req 4.1 / 4.3 / 4.5）。
#   入力: $1=pr_number, $2=round, $3=no_progress_streak
#   戻り値: 0=成功, 1=失敗（呼び出し元で WARN + 据え置き、Req 5.4）
#
#   設計判断:
#     - marker prefix `<!-- idd-codex:pr-iteration ` と既存キー名 `round` / `last-run`
#       は変更しない（Req 4.3 / NFR 1.2）。`no-progress-streak=K` を末尾に追加。
#     - 既存 marker の置換 sed は `last-run=[^>]*` で末尾 `-->` 直前まで全部食うため、
#       旧フォーマット（no-progress-streak 無し）も同じ正規表現で吸収できる（Req 4.4）。
#     - 副作用なし（PR body 書き込み 1 回のみ。コメント投稿は呼び出し元で別途実施）。
# ─────────────────────────────────────────────────────────────────────────────
pi_write_marker() {
  local pr_number="$1"
  local round="$2"
  local streak="$3"
  local oos_streak="${4-}"
  local oos_fingerprint="${5-}"
  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  local body
  if ! body=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null); then
    pi_warn "PR #${pr_number}: body 取得に失敗、marker 更新をスキップ"
    return 1
  fi

  # Issue #146: gate ON（PR_ITERATION_OOS_ENABLED=true）かつ第 4/5 引数が渡されたときのみ、
  # marker 末尾に `oos-no-progress-streak=J oos-fingerprint=<H>` を追記する。gate OFF（既定）/
  # 引数未指定では 3 フィールドのまま既存 marker と byte 互換。既存 sed の `last-run=[^>]*` は
  # oos フィールド有無どちらの旧 marker も吸収するため後方互換（下記コメント参照）。
  # oos_fingerprint は pi_oos_fingerprint 産の hex ハッシュ（未信頼入力ではない）だが、
  # 防御的に英数字以外を除去してから埋め込む（sed 置換文字列への特殊文字混入防止）。
  local oos_suffix=""
  if [ "${PR_ITERATION_OOS_ENABLED:-false}" = "true" ] && [ -n "$oos_streak" ]; then
    case "$oos_streak" in ''|*[!0-9]*) oos_streak=0 ;; esac
    oos_fingerprint=$(printf '%s' "$oos_fingerprint" | tr -cd '0-9a-zA-Z')
    oos_suffix=" oos-no-progress-streak=${oos_streak} oos-fingerprint=${oos_fingerprint}"
  fi
  local marker="<!-- idd-codex:pr-iteration round=${round} last-run=${now} no-progress-streak=${streak}${oos_suffix} -->"
  local new_body
  if echo "$body" | grep -qE 'idd-codex:pr-iteration round=[0-9]+'; then
    # 既存 marker を最新 marker で置換（複数あった場合も全部 1 つに集約）。
    # `last-run=[^>]*` は末尾 `-->` 直前まで貪欲に食うため、no-progress-streak 有無の
    # どちらの旧 marker も同じ regex で置換できる（Req 4.4）。
    new_body=$(echo "$body" | sed -E "s|<!-- idd-codex:pr-iteration round=[0-9]+ last-run=[^>]*-->|${marker}|g")
  else
    # 末尾に追記（前置の改行で見やすく）
    new_body="${body}

${marker}"
  fi

  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" --body "$new_body" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: PR body の hidden marker 更新に失敗"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_post_processing_comment: round 着手表明コメントを投稿する（marker 書き込みなし）
#   入力: $1=pr_number, $2=new_round, $3=max_rounds (表示用、`0`=無制限表記)
#   戻り値: 0 固定（コメント投稿失敗は WARN のみ。ラベル誤遷移リスクが無いため
#           round 全体を失敗扱いにはしない / NFR 1.1 既存挙動踏襲）
#   Issue #122 Req 1.6 / 2.4
#
#   設計判断:
#     - 既存 pi_post_processing_marker は「marker 書き込み + コメント投稿」の合成だったが、
#       #122 で「失敗 round では marker を据え置く」（Req 5）が必要になったため、
#       marker 書き込みは round 終了時に成功 path でのみ行うよう分離した。
#     - コメントは round 開始時の人間向け視認用なので、codex 実行前に投稿する
#       （既存挙動 NFR 1.1 と等価）。
# ─────────────────────────────────────────────────────────────────────────────
pi_post_processing_comment() {
  local pr_number="$1"
  local new_round="$2"
  local max_rounds="${3:-$PR_ITERATION_MAX_ROUNDS}"

  local max_display
  if [ "$max_rounds" = "0" ]; then
    max_display="無制限"
  else
    max_display="$max_rounds"
  fi
  local processing_msg
  processing_msg=$(printf '%s\n%s' \
    ":robot: PR Iteration Processor が処理を開始しました (round ${new_round}/${max_display})。" \
    "<!-- idd-codex:pr-iteration-processing round=${new_round} -->")
  if pi_processing_comment_exists "$pr_number" "$new_round"; then
    pi_log "PR #${pr_number}: round=${new_round} の着手表明コメントは既に存在するため再投稿しません"
    return 0
  fi
  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$processing_msg" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: 着手表明コメントの投稿に失敗"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_processing_comment_exists: 同一 round の processing marker が既存コメントにあるか判定
#   入力: $1=pr_number, $2=round
#   戻り値: 0=存在する / 1=存在しない（取得失敗時も WARN のうえ存在しない扱い）
# ─────────────────────────────────────────────────────────────────────────────
pi_processing_comment_exists() {
  local pr_number="$1"
  local round="$2"
  local marker="<!-- idd-codex:pr-iteration-processing round=${round} -->"
  local bodies
  if ! bodies=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh api --paginate "/repos/${REPO}/issues/${pr_number}/comments?per_page=100" \
        --jq '.[].body' 2>/dev/null); then
    pi_warn "PR #${pr_number}: 既存 processing コメント取得に失敗、重複チェックをスキップ"
    return 1
  fi
  if printf '%s\n' "$bodies" | grep -Fq "$marker"; then
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_post_processing_marker: PR body に hidden marker を書き込み + 着手表明コメント投稿
#   （Issue #26 / #35 で導入された合成関数。互換性のため温存するが、Issue #122 以降の
#   pi_run_iteration は pi_write_marker / pi_post_processing_comment を直接呼ぶ。
#   外部から本関数を呼んでいる箇所が無いことを確認済み 2026-05 時点）
#   入力: $1=pr_number, $2=new_round, $3=streak (省略時 0 / 後方互換)
#         $4=max_rounds (表示用、省略時 PR_ITERATION_MAX_ROUNDS / 後方互換)
#   AC 6.1, 7.1 / Issue #122 Req 4.1 / 6.1
#   戻り値: 0=成功, 1=失敗（呼び出し元で iteration を中断）
# ─────────────────────────────────────────────────────────────────────────────
pi_post_processing_marker() {
  local pr_number="$1"
  local new_round="$2"
  local streak="${3:-0}"
  local max_rounds="${4:-$PR_ITERATION_MAX_ROUNDS}"

  if ! pi_write_marker "$pr_number" "$new_round" "$streak"; then
    return 1
  fi
  pi_post_processing_comment "$pr_number" "$new_round" "$max_rounds"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_finalize_labels: 成功時のラベル遷移（AC 6.2 / 6.4）
#   --remove-label と --add-label を同一コマンドで指定し原子的に実行
# ─────────────────────────────────────────────────────────────────────────────
pi_finalize_labels() {
  local pr_number="$1"
  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" gh pr edit "$pr_number" --repo "$REPO" \
      --remove-label "$LABEL_NEEDS_ITERATION" \
      --add-label "$LABEL_READY" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: ラベル遷移 (codex-needs-iteration -> codex-ready-for-review) に失敗"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_finalize_labels_design: 設計 PR 用のラベル遷移（#35 AC 3.1）
#   codex-needs-iteration 除去 + codex-awaiting-design-review 付与を 1 コマンドで原子的に発行
# ─────────────────────────────────────────────────────────────────────────────
pi_finalize_labels_design() {
  local pr_number="$1"
  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" gh pr edit "$pr_number" --repo "$REPO" \
      --remove-label "$LABEL_NEEDS_ITERATION" \
      --add-label "$LABEL_AWAITING_DESIGN" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: ラベル遷移 (codex-needs-iteration -> codex-awaiting-design-review) に失敗"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_classify_pr_kind: branch 名 + env vars から PR の iteration 種別を判定
#   入力: $1 = head_ref
#   出力: stdout に "design" / "impl" / "none" / "ambiguous" のいずれか
#   返り値: 0
#
#   優先順序（#35 AC 1.1〜1.4 / 4.4）:
#     1. impl pattern と design pattern の両方に合致 → ambiguous
#     2. design pattern のみ合致 + DESIGN_ENABLED=true → design
#     3. design pattern のみ合致 + DESIGN_ENABLED!=true → none（opt-out gate）
#     4. impl pattern のみ合致 → impl
#     5. どちらにも合致しない → none
#
#   副作用なし（純粋関数）。同一入力に対して同一結果。
# ─────────────────────────────────────────────────────────────────────────────
pi_classify_pr_kind() {
  local head_ref="$1"
  local matches_impl=false
  local matches_design=false

  if [[ "$head_ref" =~ $PR_ITERATION_HEAD_PATTERN ]]; then
    matches_impl=true
  fi
  if [[ "$head_ref" =~ $PR_ITERATION_DESIGN_HEAD_PATTERN ]]; then
    matches_design=true
  fi

  if [ "$matches_impl" = "true" ] && [ "$matches_design" = "true" ]; then
    echo "ambiguous"
    return 0
  fi
  if [ "$matches_design" = "true" ]; then
    if [ "$PR_ITERATION_DESIGN_ENABLED" = "true" ]; then
      echo "design"
    else
      echo "none"
    fi
    return 0
  fi
  if [ "$matches_impl" = "true" ]; then
    echo "impl"
    return 0
  fi
  echo "none"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_select_template: kind から prompt template ファイルパスを返す（#35 AC 2.x）
#   入力: $1 = kind ("design" / "impl")
#   出力: stdout に template ファイルパス
#   返り値: 0=ok, 1=template 未配置（呼び出し元で iteration を中断）
# ─────────────────────────────────────────────────────────────────────────────
pi_select_template() {
  local kind="$1"
  local path=""
  case "$kind" in
    design) path="$ITERATION_TEMPLATE_DESIGN" ;;
    impl)   path="$ITERATION_TEMPLATE" ;;
    *)
      pi_warn "pi_select_template: 未知の kind=${kind}"
      return 1
      ;;
  esac
  if [ ! -f "$path" ]; then
    pi_warn "pi_select_template: template not found for kind=${kind}: ${path}"
    return 1
  fi
  echo "$path"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# build_recovery_hint (Issue #65 Req 3.1〜3.4)
#
# `codex-failed` ラベル付与時に escalation コメントへ含める「手動復旧手順」共通
# 文字列を組み立てる。
#
# 事故事例（2026-04-29 / Issue #52 復旧時 PR #62 orphan 化）の再発を防ぐため、
# 以下を必ず含める:
#   - ラベル操作の正しい順序: `codex-ready-for-review` 先付与 → `codex-failed` 除去
#   - 順序逆転で再 pickup → 既存 PR が orphan 化するリスク注意
#   - PR 無し時は `codex-failed` 除去のみで再 pickup される旨
#
# 入力: $1 = pr_present ("yes"|"no"|"unknown"; 既定 "unknown")
# 出力: stdout に markdown 文字列（escalation コメント本文の末尾に append される想定）
# 副作用: なし（純粋関数）
#
# 呼び出し側: mark_issue_failed / _slot_mark_failed / pi_escalate_to_failed
# ─────────────────────────────────────────────────────────────────────────────
build_recovery_hint() {
  local pr_present="${1:-unknown}"
  case "$pr_present" in
    yes|no|unknown) ;;
    *) pr_present="unknown" ;;
  esac

  cat <<'EOF'

---

### 手動復旧の正しい手順 (Issue #65)

ラベル操作の順序を間違えると、watcher が次サイクルで再 pickup し、既存の
PR を `force-push` で破壊する事故が起こります（過去事例: PR #62 orphan 化）。

EOF

  case "$pr_present" in
    yes)
      cat <<'EOF'
**この Issue には既に PR が紐付いています**。復旧する場合は順序が重要です:

1. `codex-ready-for-review` ラベルを **先に付与** する
2. その後で `codex-failed` ラベルを除去する

`codex-failed` を先に外すと、`codex-auto-dev` のみが残った状態になり、watcher が次
サイクルで再 pickup → impl-resume が起動して既存 PR が `force-push` 破壊
される可能性があります。

なお watcher 側にも Pre-Claim Filter が組まれているため、linked impl PR が
OPEN/MERGED の場合は claim が抑止されますが、二重ガードのために順序は厳守
してください。

EOF
      ;;
    no)
      cat <<'EOF'
**この Issue には現時点で PR が紐付いていません**。復旧する場合:

- `codex-failed` を除去すると次サイクルで watcher が再 pickup します
  （PR が無ければ Pre-Claim Filter は素通りするため、impl/Triage が再起動
  されます）
- これ以上自動再実行したくない場合は `codex-failed` を残したまま
  `codex-auto-dev` を外す方法もあります

EOF
      ;;
    *)
      cat <<'EOF'
**復旧手順は PR の有無で分岐します**:

- PR が既に作成済みの場合: `codex-ready-for-review` を **先に付与** してから
  `codex-failed` を除去する。順序を逆にすると watcher が次サイクルで再
  pickup し、impl-resume が起動して既存 PR が `force-push` 破壊される
  可能性があります。
- PR が無い場合: `codex-failed` を除去すると次サイクルで再 pickup される
  ため、自動再実行を望まないときは `codex-auto-dev` も外す。

watcher 側にも Pre-Claim Filter（linked impl PR が OPEN/MERGED なら claim
を抑止）が組まれていますが、二重ガードのため順序は厳守してください。

EOF
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_escalate_to_failed: 上限到達時の codex-failed 昇格 + エスカレコメント
#   入力: $1=pr_number, $2=round, $3=max_rounds, $4=reason (任意, 既定 "max-rounds")
#         $5=streak (任意, reason=no-progress のとき表示する連続カウンタ値)
#   AC 7.2, 7.3 / Issue #122 Req 3.5
#
#   reason: "max-rounds"（既定）または "no-progress"。コメント本文と理由表示を切り替える。
# ─────────────────────────────────────────────────────────────────────────────
pi_escalate_to_failed() {
  local pr_number="$1"
  local round="$2"
  local max_rounds="$3"
  local reason="${4:-max-rounds}"
  local streak="${5:-0}"

  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" gh pr edit "$pr_number" --repo "$REPO" \
      --remove-label "$LABEL_NEEDS_ITERATION" \
      --add-label "$LABEL_FAILED" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: codex-failed 昇格時のラベル遷移に失敗"
    return 1
  fi

  local escalation_body
  if [ "$reason" = "no-progress" ]; then
    # Issue #122 Req 3.5: no-progress 連続上限到達時の専用本文
    local no_progress_limit="${PR_ITERATION_NO_PROGRESS_LIMIT:-3}"
    read -r -d '' escalation_body <<EOF || true
## :rotating_light: PR Iteration no-progress 上限到達 (#122 no-progress loop guard)

本 PR は **no-progress 連続 ${streak} round** に達しました（上限
\`PR_ITERATION_NO_PROGRESS_LIMIT=${no_progress_limit}\`）。head branch への新規 commit が
${streak} round 連続で観測されなかったため、コスト暴走と無限ループを防ぐために
\`codex-needs-iteration\` ラベルを除去し、\`codex-failed\` ラベルに付け替えています。

### これまでの状況

- 累計 iteration: ${round} round
- no-progress 連続: ${streak} round
- no-progress 上限値: ${no_progress_limit} round
- 進捗 commit が連続して無いため自動 iteration を停止

### 次に人間が取るべきアクション

1. これまでのレビューコメントと自動修正履歴を読み、Codex が「対応不要」と
   判断していたのか、対応に失敗していたのかを確認する
2. 必要に応じて手動で修正 commit を積む
3. 自動 iteration を再開したい場合:
   - PR 本文の \`<!-- idd-codex:pr-iteration round=N ... -->\` 行を **手動で削除**（カウンタリセット）
   - \`codex-failed\` ラベルを除去
   - \`codex-needs-iteration\` ラベルを付け直す
4. これ以上自動 iteration を行わない場合は \`codex-failed\` を残したまま手動レビューに移行

---

_本コメントは PR Iteration Processor (#122 no-progress loop guard) が自動投稿しました。_
EOF
  else
    read -r -d '' escalation_body <<EOF || true
## :rotating_light: PR Iteration 上限到達 (#26 PR Iteration Processor)

本 PR の累計自動 iteration 回数が上限 (\`max_rounds=${max_rounds}\`) に達しました。
\`codex-needs-iteration\` ラベルを除去し、\`codex-failed\` ラベルに付け替えています。

### これまでの状況

- 累計 iteration: ${round} round
- 上限値: ${max_rounds} round
- 上限到達のため自動 iteration を停止

### 次に人間が取るべきアクション

1. これまでのレビューコメントと自動修正履歴を読み、Codex の判断を確認する
2. 必要に応じて手動で修正 commit を積む
3. 自動 iteration を再開したい場合:
   - PR 本文の \`<!-- idd-codex:pr-iteration round=N ... -->\` 行を **手動で削除**（カウンタリセット）
   - \`codex-failed\` ラベルを除去
   - \`codex-needs-iteration\` ラベルを付け直す
4. これ以上自動 iteration を行わない場合は \`codex-failed\` を残したまま手動レビューに移行

---

_本コメントは PR Iteration Processor (#26) が自動投稿しました。_
EOF
  fi
  # Issue #65 Req 3.1/3.2/3.3/3.4: 手動復旧手順を末尾に append。
  # pi_escalate_to_failed は PR Iteration（codex-needs-iteration ラベル付き PR）からの遷移
  # であり、文脈上 PR が必ず存在するため pr_present="yes" を渡す。
  escalation_body="${escalation_body}
$(build_recovery_hint "yes")"

  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$escalation_body" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: エスカレコメントの投稿に失敗（ラベル遷移は完了済み）"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_build_iteration_prompt: 指定 template に変数を注入
#   入力: $1=pr_number, $2=pr_json, $3=round, $4=template_path（省略時は impl 用既定）
#   出力: stdout に prompt 文字列
#   AC 3.1, 3.2, 3.3, 3.4, 3.5（#26）/ #35 で kind 引数の代わりに template path を受け取る
# ─────────────────────────────────────────────────────────────────────────────
pi_build_iteration_prompt() {
  local pr_number="$1"
  local pr_json="$2"
  local round="$3"
  # #35: template path を呼び出し元から渡す。省略時は impl 用 template を使う（後方互換）。
  local tmpl_path="${4:-$ITERATION_TEMPLATE}"
  # Issue #122 Req 1.6: kind 別に解決した round 上限を template の {{MAX_ROUNDS}} に
  # 反映する。省略時は旧 PR_ITERATION_MAX_ROUNDS を使う（後方互換）。`0` は無制限の
  # sentinel として template に文字列 `0` を渡す。template 側で表示時にどう翻訳するかは
  # template の責務（既存 template は `{{MAX_ROUNDS}}` をそのまま表示するため、`0` の
  # ときの「無制限」表記は本関数では行わず、prompt 上の数値として `0` を保持する。
  # 着手表明コメント側では `0`→`無制限` 表示に翻訳する: pi_post_processing_marker 参照）。
  local max_rounds_param="${5:-$PR_ITERATION_MAX_ROUNDS}"

  local pr_title pr_url head_ref base_ref pr_body
  pr_title=$(echo "$pr_json" | jq -r '.title // ""')
  pr_url=$(echo "$pr_json"   | jq -r '.url // ""')
  head_ref=$(echo "$pr_json" | jq -r '.headRefName // ""')
  base_ref=$(echo "$pr_json" | jq -r '.baseRefName // ""')
  pr_body=$(echo "$pr_json"  | jq -r '.body // ""')

  # title が JSON で取れていない場合（pr_json は --json title を含まないかも）は gh で補完
  if [ -z "$pr_title" ]; then
    pr_title=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" --json title --jq '.title // ""' 2>/dev/null || echo "")
  fi

  # 関連 Issue 番号: head branch (`codex/issue-N-...`) → PR body の順で抽出
  local issue_number=""
  issue_number=$(echo "$head_ref" | grep -oE 'issue-[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  if [ -z "$issue_number" ]; then
    issue_number=$(echo "$pr_body" | grep -oE '#[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  fi

  local spec_dir=""
  local requirements_md="(関連 Issue が見つからないか、対応する requirements.md が存在しません)"
  if [ -n "$issue_number" ]; then
    local found
    found=$(ls -d "${REPO_DIR}/docs/specs/${issue_number}-"* 2>/dev/null | head -1 || true)
    if [ -n "$found" ] && [ -f "${found}/requirements.md" ]; then
      spec_dir="docs/specs/$(basename "$found")"
      requirements_md=$(cat "${found}/requirements.md")
    fi
  fi

  # PR diff は prompt に inline で埋め込まない（Issue #97: 大差分時の `Argument list
  # too long` 回避のため、`PI_PR_DIFF` 環境変数も廃止。Iteration サブエージェントが
  # template の指示に従い、自身で `gh pr diff <N> --repo <REPO>` および
  # `git diff <base>..<head> -- <path>` を Bash ツールで実行して取得する設計に切り替えた）

  # AC 3.1: 最新 review の line コメントを取得（reviews 配列の最後の要素 = 時系列で最新）
  local line_comments_json="[]"
  local reviews_json latest_review_id
  if reviews_json=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh api "/repos/${REPO}/pulls/${pr_number}/reviews" 2>/dev/null); then
    latest_review_id=$(echo "$reviews_json" | jq -r 'if length > 0 then (.[length-1].id|tostring) else "" end')
    if [ -n "$latest_review_id" ]; then
      local raw_line
      if raw_line=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
          gh api "/repos/${REPO}/pulls/${pr_number}/reviews/${latest_review_id}/comments" 2>/dev/null); then
        # #400 移植: 一般コメント側 pi_general_filter_self と同じく、PR Iteration 自身の
        # `idd-codex:pr-iteration` marker を line コメントからも除外する（自分の出力を
        # iteration 入力へ還流させない）。`idd-codex:pr-reviewer` の指摘は残す（actionable）。
        line_comments_json=$(echo "$raw_line" \
          | jq '[.[]
                | {id, path, line, user: (.user.login // ""), body}
                | select((.body // "") | test("<!--[[:space:]]*idd-codex:pr-iteration([[:space:]>-]|$)") | not)]')
      fi
    fi
  fi

  # #55: 一般コメント収集（mention 篩い分けを撤廃 + 自己投稿 / 過去 round / system 除外
  #     + 大量時 truncate）。kind に依存せず impl/design 共通で同一ロジックを通す（Req 6.2）。
  local general_comments_json
  general_comments_json=$(pi_collect_general_comments "$pr_number" "$pr_body")

  # template に変数を注入する。
  # 単一行値（PR 番号 / タイトル / URL 等）は awk -v で渡し、行内の {{KEY}} を文字列置換。
  # 複数行値（LINE_COMMENTS_JSON / GENERAL_COMMENTS_JSON / REQUIREMENTS_MD）は awk -v で
  # 改行を扱えないため、export 経由で ENVIRON[] から取得し、「行全体が {{KEY}} のみ」の
  # テンプレ行をブロックごと置換する（template はその前提で書かれている）。
  # NOTE (#97): PR diff は MAX_ARG_STRLEN (131,072 B) 超過で execve() が E2BIG を返す
  # 事案を避けるため env 経由でも渡さない。Iteration サブエージェントが Bash で取得する。
  if [ ! -f "$tmpl_path" ]; then
    pi_warn "template not found: $tmpl_path"
    return 1
  fi

  # 改行入り値を子プロセスに渡すため export
  export PI_LINE_JSON="$line_comments_json"
  export PI_GENERAL_JSON="$general_comments_json"
  export PI_REQS_MD="$requirements_md"

  awk \
    -v repo="$REPO" \
    -v pr_number="$pr_number" \
    -v pr_title="$pr_title" \
    -v pr_url="$pr_url" \
    -v head_ref="$head_ref" \
    -v base_ref="$base_ref" \
    -v round="$round" \
    -v max_rounds="$max_rounds_param" \
    -v issue_number="${issue_number:-(none)}" \
    -v spec_dir="${spec_dir:-(none)}" \
    '
    function repl(s, key, val,    out, idx) {
      out = ""
      while ((idx = index(s, key)) > 0) {
        out = out substr(s, 1, idx-1) val
        s = substr(s, idx + length(key))
      }
      return out s
    }
    {
      # 行全体が複数行プレースホルダの場合は ENVIRON 経由で展開
      if ($0 == "{{LINE_COMMENTS_JSON}}")    { print ENVIRON["PI_LINE_JSON"]; next }
      if ($0 == "{{GENERAL_COMMENTS_JSON}}") { print ENVIRON["PI_GENERAL_JSON"]; next }
      if ($0 == "{{REQUIREMENTS_MD}}")       { print ENVIRON["PI_REQS_MD"]; next }
      line = $0
      line = repl(line, "{{REPO}}", repo)
      line = repl(line, "{{PR_NUMBER}}", pr_number)
      line = repl(line, "{{PR_TITLE}}", pr_title)
      line = repl(line, "{{PR_URL}}", pr_url)
      line = repl(line, "{{HEAD_REF}}", head_ref)
      line = repl(line, "{{BASE_REF}}", base_ref)
      line = repl(line, "{{ROUND}}", round)
      line = repl(line, "{{MAX_ROUNDS}}", max_rounds)
      line = repl(line, "{{ISSUE_NUMBER}}", issue_number)
      line = repl(line, "{{SPEC_DIR}}", spec_dir)
      print line
    }
    ' "$tmpl_path"
  local awk_rc=$?

  unset PI_LINE_JSON PI_GENERAL_JSON PI_REQS_MD
  return $awk_rc
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_detect_quota_soft_fail: stream-json から Codex Max 5h quota の警告閾値到達を検知
#   入力: stdin に Codex `--output-format stream-json` の出力（1 行 1 JSON）
#   出力: stdout に検出 1 件 1 行（タブ区切り）。検出無しなら無出力。
#         形式: <detection_path>\t<surpassed_threshold>
#           detection_path: 現状 `rate_limit_warning` 固定
#           surpassed_threshold: 検出時の surpassedThreshold 値（小数文字列）
#   返り値: 0 固定（解析失敗行・非該当行は無視して継続。`qa_detect_rate_limit` と同じ
#           resilience 設計 / Req 5.4 互換）
#
#   検出条件 (#118 Req 1.1):
#     - `type == "rate_limit_event"` かつ
#     - `status == "allowed_warning"`（top-level）または
#       `rate_limit_info.status == "allowed_warning"`（ネスト位置）かつ
#     - `surpassedThreshold >= 0.9`（top-level の `surpassedThreshold` または
#       `rate_limit_info.surpassedThreshold` のどちらかが 0.9 以上）
#
#   この関数は `QUOTA_AWARE_ENABLED` 設定とは独立に呼ばれる（Req 5.1）。
#   `qa_detect_rate_limit` とは独立した関数として配置（Req 5.3: dispatcher 連携なし）。
# ─────────────────────────────────────────────────────────────────────────────
pi_detect_quota_soft_fail() {
  jq -R -r '
    . as $line
    | (try ($line | fromjson) catch null)
    | select(type == "object") as $j

    # status を top-level / ネスト位置の両方で探索
    | (
        ($j.status? // ($j.rate_limit_info? // {}).status? // "")
      ) as $status

    # surpassedThreshold を top-level / ネスト位置の両方で探索
    | (
        ($j.surpassedThreshold? // ($j.rate_limit_info? // {}).surpassedThreshold? // null)
      ) as $threshold

    # type == "rate_limit_event" かつ status == "allowed_warning" かつ
    # threshold が数値かつ >= 0.9 のときのみ出力
    | select(
        $j.type? == "rate_limit_event"
        and $status == "allowed_warning"
        and ($threshold | type) == "number"
        and $threshold >= 0.9
      )

    | "rate_limit_warning\t\($threshold)"
  ' 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_extract_usage_limit_reset_epoch: usage-limit 風 message から reset epoch を抽出
#   入力: $1=message
#   出力: stdout に UNIX epoch（抽出不能なら空）
# ─────────────────────────────────────────────────────────────────────────────
pi_extract_usage_limit_reset_epoch() {
  local message="${1:-}"
  if [ -z "$message" ]; then
    echo ""
    return 0
  fi

  local raw
  raw=$(printf '%s\n' "$message" \
    | sed -nE 's/.*try again at ([A-Z][a-z]{2} [0-9]{1,2}(st|nd|rd|th)?, [0-9]{4} [0-9]{1,2}:[0-9]{2} (AM|PM)).*/\1/p' \
    | tail -1)
  if [ -z "$raw" ]; then
    echo ""
    return 0
  fi

  local normalized
  normalized=$(printf '%s\n' "$raw" | sed -E 's/([0-9]+)(st|nd|rd|th)/\1/g')
  local epoch=""
  if epoch=$(date -d "$normalized" '+%s' 2>/dev/null); then
    echo "$epoch"
    return 0
  fi
  if epoch=$(date -j -f '%b %e, %Y %I:%M %p' "$normalized" '+%s' 2>/dev/null); then
    echo "$epoch"
    return 0
  fi
  echo ""
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_detect_usage_limit_fatal: stream-json log から usage-limit 風 fatal error を検出
#   入力: $1=log_path
#   出力: 検出時のみ `<path>\t<reset_epoch>\t<message>` を 1 行
#   戻り値: 0=検出 / 1=検出なし / 2=log 不在
# ─────────────────────────────────────────────────────────────────────────────
pi_detect_usage_limit_fatal() {
  local log_path="${1:-}"
  if [ -z "$log_path" ] || [ ! -f "$log_path" ] || [ ! -r "$log_path" ]; then
    return 2
  fi

  local message
  message=$(jq -R -r '
    . as $line
    | (try ($line | fromjson) catch null)
    | select(type == "object") as $j
    | [
        ($j.message? // empty),
        ($j.error? // {} | .message? // empty),
        ($j.item? // {} | .message? // empty)
      ][]
    | select(type == "string")
    | select(test("usage limit|purchase more credits|try again at"; "i"))
  ' "$log_path" 2>/dev/null | tail -1)

  if [ -z "$message" ]; then
    return 1
  fi

  local epoch
  epoch=$(pi_extract_usage_limit_reset_epoch "$message")
  printf 'usage_limit_fatal\t%s\t%s\n' "$epoch" "$message"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_write_usage_fatal_marker: reset 不明 usage-limit 風 fatal の有界 retry marker を更新
#   入力: $1=pr_number, $2=round, $3=count
# ─────────────────────────────────────────────────────────────────────────────
pi_write_usage_fatal_marker() {
  local pr_number="$1"
  local round="$2"
  local count="$3"
  local body
  if ! body=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null); then
    pi_warn "PR #${pr_number}: usage-limit fatal marker 用 body 取得に失敗"
    return 1
  fi

  local marker="<!-- idd-codex:pr-iteration-usage-fatal round=${round} count=${count} -->"
  local new_body
  if echo "$body" | grep -qE "idd-codex:pr-iteration-usage-fatal round=${round} count=[0-9]+"; then
    new_body=$(echo "$body" | sed -E "s|<!-- idd-codex:pr-iteration-usage-fatal round=${round} count=[0-9]+ -->|${marker}|g")
  else
    new_body="${body}

${marker}"
  fi

  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" --body "$new_body" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: usage-limit fatal marker 更新に失敗"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_handle_usage_limit_fatal: PR Iteration の usage-limit 風 fatal error を退避分類する
#   入力: $1=pr_number, $2=kind, $3=round, $4=log_path, $5=detect_line
#   戻り値: 0=退避済み / 1=退避失敗または bounded retry 継続
# ─────────────────────────────────────────────────────────────────────────────
pi_handle_usage_limit_fatal() {
  local pr_number="$1"
  local kind="$2"
  local round="$3"
  local log_path="$4"
  local detect_line="$5"

  local rest reset_epoch message
  rest="${detect_line#*$'\t'}"
  reset_epoch="${rest%%$'\t'*}"
  message="${rest#*$'\t'}"
  local reset_iso=""
  if [ -n "$reset_epoch" ]; then
    reset_iso=$(qa_format_iso8601 "$reset_epoch")
    qa_persist_reset_time "pr-${pr_number}" "$reset_epoch" \
      || pi_warn "PR #${pr_number}: reset_epoch=${reset_epoch} の永続化に失敗（ラベル退避は継続）"
    if ! timeout "$PR_ITERATION_GIT_TIMEOUT" gh pr edit "$pr_number" --repo "$REPO" \
        --remove-label "$LABEL_NEEDS_ITERATION" \
        --add-label "$LABEL_NEEDS_QUOTA_WAIT" >/dev/null 2>&1; then
      pi_warn "PR #${pr_number}: usage-limit fatal quota-wait ラベル遷移に失敗"
      return 1
    fi

    local wait_body
    read -r -d '' wait_body <<EOF || true
## ⏸️ PR Iteration quota wait

PR Iteration 中に Codex CLI が usage-limit 風の fatal error を返したため、本 PR を
\`${LABEL_NEEDS_QUOTA_WAIT}\` に退避し、\`${LABEL_NEEDS_ITERATION}\` を除去しました。

### 検知情報

- kind: \`${kind}\`
- round: ${round}
- reset 予定時刻 (UNIX epoch): \`${reset_epoch}\`
- reset 予定時刻 (ISO 8601): \`${reset_iso}\`
- log: \`${log_path}\`

reset 予定時刻 + grace 経過後、PR Iteration Processor が本 PR を
\`${LABEL_NEEDS_ITERATION}\` に戻します。即時再開する場合は
\`${LABEL_NEEDS_QUOTA_WAIT}\` を外して \`${LABEL_NEEDS_ITERATION}\` を付け直してください。

<!-- idd-codex:pr-iteration-quota-wait round=${round} reset=${reset_epoch} -->
EOF
    if ! timeout "$PR_ITERATION_GIT_TIMEOUT" \
        gh pr comment "$pr_number" --repo "$REPO" --body "$wait_body" >/dev/null 2>&1; then
      pi_warn "PR #${pr_number}: usage-limit fatal quota-wait コメント投稿に失敗"
    fi
    pi_log "PR #${pr_number}: kind=${kind} round=${round} usage-limit fatal detected reset_epoch=${reset_epoch} action=quota-wait"
    return 0
  fi

  local pr_body prev_count new_count retry_limit
  pr_body=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
    gh pr view "$pr_number" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null || echo "")
  prev_count=$(pi_read_usage_fatal_count "$pr_body" "$round")
  new_count=$((prev_count + 1))
  retry_limit="${PR_ITERATION_USAGE_FATAL_RETRY_LIMIT:-1}"
  pi_write_usage_fatal_marker "$pr_number" "$round" "$new_count" || true

  if [ "$new_count" -lt "$retry_limit" ]; then
    pi_warn "PR #${pr_number}: kind=${kind} round=${round} usage-limit fatal reset 不明 count=${new_count}/${retry_limit} (bounded retry)"
    return 1
  fi

  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" gh pr edit "$pr_number" --repo "$REPO" \
      --remove-label "$LABEL_NEEDS_ITERATION" \
      --add-label "$LABEL_NEEDS_DECISIONS" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: usage-limit fatal decisions ラベル遷移に失敗"
    return 1
  fi

  local decisions_body
  read -r -d '' decisions_body <<EOF || true
## 🤔 PR Iteration usage-limit 風 fatal error

PR Iteration 中に Codex CLI が usage-limit 風の fatal error を返しましたが、reset 予定時刻を
抽出できませんでした。同一 round の無制限再試行を止めるため、本 PR から
\`${LABEL_NEEDS_ITERATION}\` を除去し、\`${LABEL_NEEDS_DECISIONS}\` に退避しています。

### 検知情報

- kind: \`${kind}\`
- round: ${round}
- bounded retry count: ${new_count}/${retry_limit}
- log: \`${log_path}\`
- message: \`${message}\`

人間が quota 起因と判断して再開する場合は \`${LABEL_NEEDS_DECISIONS}\` を外し、
\`${LABEL_NEEDS_ITERATION}\` を付け直してください。

<!-- idd-codex:pr-iteration-usage-fatal round=${round} count=${new_count} -->
EOF
  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$decisions_body" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: usage-limit fatal decisions コメント投稿に失敗"
  fi
  pi_log "PR #${pr_number}: kind=${kind} round=${round} usage-limit fatal reset unknown count=${new_count}/${retry_limit} action=needs-decisions"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_branch_is_codex_pr_head: branch 名が auto-commit 許可規約に一致するか判定
#   入力: $1 = branch 名
#   返り値: 0 = 一致（`codex/issue-<N>-<slug>` 形式）/ 1 = 不一致
#
#   人間の branch に対する誤 auto-commit 防止のガード（#118 Req 3.2 / 3.4）。
#   現状は `^codex/issue-[0-9]+-` で固定（Out of Scope: branch 命名規約拡張）。
# ─────────────────────────────────────────────────────────────────────────────
pi_branch_is_codex_pr_head() {
  local branch="${1:-}"
  [[ "$branch" =~ ^codex/issue-[0-9]+- ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_auto_commit_and_push: 指定 branch に対して未コミット差分を `git add -A` →
#   `git commit -m "$msg"` → `git push origin <branch>` で退避する
#   入力: $1 = commit message（1 行目）。本文 + Co-Authored-By を関数側で付与する。
#         $2 = branch 名（push 先 / safety 用に呼び出し時点の current branch と一致前提）
#   返り値: 0 = 成功 / 1 = 失敗（add / commit / push のいずれか）
#
#   設計判断:
#     - `git add -A` で削除も含む全変更を取り込む（中途終了時の意図不明差分を漏らさない）。
#     - commit には `Co-Authored-By: Codex <noreply@openai.com>` を含める
#       （#118 Req 1.3 / 2.3 / 3.3 で固定）。
#     - push は plain `git push origin <branch>`（force 系を使わない）。push 失敗は
#       上位で WARN 扱い（Req 1.5 / 2.4 / 3.5）。
#     - 呼び出し前に `pi_branch_is_codex_pr_head` でガードする責務は呼び出し元。
# ─────────────────────────────────────────────────────────────────────────────
pi_auto_commit_and_push() {
  local msg="$1"
  local branch="$2"
  local full_msg
  full_msg=$(printf '%s\n\nCo-Authored-By: Codex <noreply@openai.com>\n' "$msg")

  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" git add -A >/dev/null 2>&1; then
    pi_warn "auto-commit: git add -A に失敗 (branch=${branch})"
    return 1
  fi
  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" git commit -m "$full_msg" >/dev/null 2>&1; then
    pi_warn "auto-commit: git commit に失敗 (branch=${branch})"
    return 1
  fi
  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" git push origin "$branch" >/dev/null 2>&1; then
    pi_warn "auto-commit: git push origin ${branch} に失敗"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_resolve_success_action: Codex rc=0 後のラベル確定アクションを決める
#   入力: $1=commit_pushed ("true" / "false"), $2=new_streak, $3=no_progress_limit
#   出力: stdout に "success" / "hold" / "escalate"
#   返り値: 0 固定
#
#   Issue #3: head branch に新規 commit がない round は、明示的な reply-only success
#   contract が未定義の現状では success label transition へ進めない。streak が上限
#   未満なら hold、上限以上なら no-progress escalation に倒す。
# ─────────────────────────────────────────────────────────────────────────────
pi_resolve_success_action() {
  local commit_pushed="$1"
  local new_streak="$2"
  local no_progress_limit="$3"

  if [ "$commit_pushed" != "true" ]; then
    if [ "$new_streak" -ge "$no_progress_limit" ]; then
      echo "escalate"
    else
      echo "hold"
    fi
    return 0
  fi

  echo "success"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_pr_has_pr_reviewer_quota_marker: PR Reviewer 由来の quota wait marker を持つか判定
#   戻り値: 0=marker あり / 1=marker なし or API failure
# ─────────────────────────────────────────────────────────────────────────────
pi_pr_has_pr_reviewer_quota_marker() {
  local pr_number="$1"
  local comments_json
  if ! comments_json=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh api "/repos/${REPO}/issues/${pr_number}/comments" 2>/dev/null); then
    return 1
  fi
  printf '%s\n' "$comments_json" | jq -e '
    [
      .[]?.body // ""
      | if contains("idd-codex:pr-reviewer-quota-wait reset=") then
          "wait"
        elif contains("idd-codex:pr-reviewer-quota-resume reset=") then
          "resume"
        else empty end
    ] | last == "wait"
  ' >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_process_quota_resume: usage-limit 風 fatal で待機中の PR を reset 後に iteration へ戻す
#   戻り値: 0 固定（API 失敗は WARN で後続継続）
# ─────────────────────────────────────────────────────────────────────────────
pi_process_quota_resume() {
  local prs_json
  if ! prs_json=$(timeout "$PR_ITERATION_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "label:\"$LABEL_NEEDS_QUOTA_WAIT\"" \
      --json number,url \
      --limit 50 2>/dev/null); then
    pi_warn "codex-needs-quota-wait PR の取得に失敗（PR Iteration 本処理は継続）"
    return 0
  fi

  local count
  count=$(printf '%s\n' "$prs_json" | jq 'length' 2>/dev/null || echo 0)
  if [ "$count" -eq 0 ]; then
    return 0
  fi

  local now_epoch
  now_epoch=$(date -u +%s)
  local pr_number pr_url reset_epoch threshold
  while IFS=$'\t' read -r pr_number pr_url; do
    [ -z "$pr_number" ] && continue
    if pi_pr_has_pr_reviewer_quota_marker "$pr_number"; then
      pi_log "PR #${pr_number}: PR Reviewer quota wait marker 検出 → PR Iteration resume では触らない"
      continue
    fi
    if ! reset_epoch=$(qa_load_reset_time "pr-${pr_number}"); then
      pi_warn "PR #${pr_number}: quota wait reset 時刻読み出し失敗 → ラベル維持"
      continue
    fi
    threshold=$((reset_epoch + QUOTA_RESUME_GRACE_SEC))
    if [ "$now_epoch" -lt "$threshold" ]; then
      pi_log "PR #${pr_number}: quota-wait 継続 reset_epoch=${reset_epoch} wait_sec=$((threshold - now_epoch)) (${pr_url})"
      continue
    fi
    if timeout "$PR_ITERATION_GIT_TIMEOUT" gh pr edit "$pr_number" --repo "$REPO" \
        --remove-label "$LABEL_NEEDS_QUOTA_WAIT" \
        --add-label "$LABEL_NEEDS_ITERATION" >/dev/null 2>&1; then
      local resume_body
      resume_body=":arrow_forward: PR Iteration quota wait の reset 時刻を経過したため、\`${LABEL_NEEDS_QUOTA_WAIT}\` を外し \`${LABEL_NEEDS_ITERATION}\` に戻しました。

<!-- idd-codex:pr-iteration-quota-resume reset=${reset_epoch} -->"
      if ! timeout "$PR_ITERATION_GIT_TIMEOUT" \
          gh pr comment "$pr_number" --repo "$REPO" --body "$resume_body" >/dev/null 2>&1; then
        pi_warn "PR #${pr_number}: quota resume コメント投稿に失敗"
      fi
      pi_log "PR #${pr_number}: quota-wait resumed reset_epoch=${reset_epoch} elapsed_sec=$((now_epoch - reset_epoch))"
    else
      pi_warn "PR #${pr_number}: quota wait resume ラベル遷移に失敗"
    fi
  done < <(printf '%s\n' "$prs_json" | jq -r '.[] | [.number, .url] | @tsv')

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_route_out_of_scope_escalate: out-of-scope 指摘を既定経路へ還流する共通ヘルパ
#   入力: $1=pr_number, $2=sha, $3=decisions_json（adjudicator 由来 / 空文字列許容）,
#         $4=source_kind（"adjudicator" | "developer-marker:<kind>" | "content-no-progress" 等の
#            観測ラベル）,
#         $5=out_of_scope_count（観測ログ用 / 空なら "?" 表示）
#   出力: なし（pi_log / pi_warn のみ）
#   戻り値: 0=ok（ルーティング実施 / 冪等 skip 含む）/ 2=入力検証失敗
#   Issue #146（idd-claude #437 移植）
#
#   設計判断:
#     - adjudicator 経路（adj_route_out_of_scope）と Developer marker / 内容ベース no-progress
#       経路（pi_run_iteration）の複数経路から共通呼び出しされる単一ルーティング実体。
#     - ルート解決: PR_ITERATION_OOS_ROUTE が `codex-needs-decisions`（既定）→
#       `codex-needs-iteration` 除去 + `codex-needs-decisions` 付与 + 追跡コメント投稿。
#       `design-reflow` / `spawn-issue` は env 値として将来予約し、本実装では
#       `codex-needs-decisions` に正規化する（外部への新規 Issue 作成は opt-in gate 体系上
#       本 spec の Non-Goal。idd-codex-issue-watcher.sh の env 正規化と二重防御）。
#     - 冪等性: 投稿コメントに hidden marker
#       `<!-- idd-codex:pr-iteration-oos-routed sha=<sha> -->` を付与し、同一 PR・同一 SHA で
#       既存 marker 検出時は再ルーティングを skip する。
#     - 失敗時（ラベル付与 / コメント投稿）は WARN 1 行を残し silent fail しない。
#       既存の codex-needs-iteration 据え置き挙動を壊さないよう rc=0 で返す（安全側）。
#     - 観測ログ: `reason=out-of-scope route=<route>` を含む 1 行を機械抽出可能形式で出力。
#     - 未信頼値（reason / file）は jq @tsv でリテラル抽出してから printf へ渡す
#       （jq filter inline 展開禁止 / AGENTS.md §6）。sed / eval / bash -c へは渡さない。
# ─────────────────────────────────────────────────────────────────────────────
pi_route_out_of_scope_escalate() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local decisions_json="${3:-}"
  local source_kind="${4:-unknown}"
  local out_of_scope_count="${5:-?}"

  # gate OFF（既定）→ 即 return 0（防御的二重確認。呼び出し元も gate 判定済み）
  if [ "${PR_ITERATION_OOS_ENABLED:-false}" != "true" ]; then
    return 0
  fi

  # 入力検証: PR 番号 / SHA を gh 引数に使う前に厳密検証する。
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    pi_warn "pi_route_out_of_scope_escalate: 無効な PR 番号 '${pr_number}'"
    return 2
  fi
  if ! [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    pi_warn "PR #${pr_number}: pi_route_out_of_scope_escalate: 無効な SHA '${sha}'"
    return 2
  fi

  # ルート解決: 本実装では `codex-needs-decisions` のみ。未知値は安全側で needs-decisions に丸める。
  local route="${PR_ITERATION_OOS_ROUTE:-needs-decisions}"
  case "$route" in
    needs-decisions) : ;;
    design-reflow|spawn-issue|*) route="needs-decisions" ;;
  esac
  local label="${LABEL_NEEDS_DECISIONS:-codex-needs-decisions}"
  local iteration_label="${LABEL_NEEDS_ITERATION:-codex-needs-iteration}"
  local timeout_s="${PR_ITERATION_GIT_TIMEOUT:-120}"

  # 冪等性: 同一 PR・同一 SHA で既ルーティング済みなら skip する。
  local routed_marker="<!-- idd-codex:pr-iteration-oos-routed sha=${sha} -->"
  local body
  body=$(timeout "$timeout_s" \
    gh pr view "$pr_number" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null || echo "")
  # コメント側 marker も走査する（PR body だけでは過去ルーティングコメントを拾えないため）。
  local existing_comment_markers=""
  existing_comment_markers=$(timeout "$timeout_s" \
    gh api "/repos/${REPO}/issues/${pr_number}/comments" --jq '.[].body' 2>/dev/null \
    | grep -F -- "idd-codex:pr-iteration-oos-routed sha=${sha}" 2>/dev/null || true)
  case "${body}${existing_comment_markers}" in
    *"idd-codex:pr-iteration-oos-routed sha=${sha}"*)
      pi_log "PR #${pr_number}: reason=out-of-scope route=${route} action=skip-already-routed sha=${sha}（冪等）"
      return 0
      ;;
  esac

  # out-of-scope 指摘の判定根拠を TSV 化して追跡コメント本文に並べる。
  # 未信頼値（reason / file）は jq @tsv でリテラル抽出してから printf へ渡す（inline 展開禁止）。
  local detail_lines=""
  if [ -n "$decisions_json" ]; then
    local oos_rows
    oos_rows=$(printf '%s' "$decisions_json" | jq -r '
      .decisions // []
      | map(select(.verdict == "out-of-scope"))
      | .[]
      | [ (.id | tostring), (.file // ""), ((.line // 0) | tostring), (.reason // .message // "") ]
      | @tsv
    ' 2>/dev/null) || oos_rows=""
    if [ -n "$oos_rows" ]; then
      while IFS=$'\t' read -r oid ofile oline oreason; do
        [ -z "$oid" ] && continue
        detail_lines="${detail_lines}- id: ${oid} / ${ofile}:${oline} — ${oreason}
"
      done <<<"$oos_rows"
    fi
  fi

  # 1. `codex-needs-iteration` 除去（round 候補プールから外す）。失敗は WARN + 続行（安全側）。
  if ! timeout "$timeout_s" \
      gh pr edit "$pr_number" --repo "$REPO" --remove-label "$iteration_label" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: out-of-scope 還流で '${iteration_label}' 除去に失敗（既存挙動据え置きで安全側）"
  fi

  # 2. 還流ラベル付与（既定 codex-needs-decisions）。失敗は WARN（silent fail 禁止）。
  if ! timeout "$timeout_s" \
      gh pr edit "$pr_number" --repo "$REPO" --add-label "$label" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: out-of-scope 還流ラベル '${label}' 付与失敗（silent fail せず WARN）"
  fi

  # 3. 追跡コメント投稿 + 冪等 marker。失敗は WARN（silent fail 禁止）。
  local route_body
  route_body=$(printf '## 自動裁定: out-of-scope へ還流（人間判断要求）\n\nround を消費させる legitimate 指摘が残っていない一方、当該 PR の権限では requirements.md / design.md / tasks.md の確定事項を変更できない out-of-scope 指摘が残存しています。本 PR を自動 iteration から外し、%s ラベルで人間判断へ還流します（source=%s）。\n\n### out-of-scope 指摘の還流候補\n\n%s\n%s\n' \
    "$label" "$source_kind" "$detail_lines" "$routed_marker")
  if ! timeout "$timeout_s" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$route_body" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: out-of-scope 還流コメント投稿失敗（sha=${sha} / ラベルは付与済みで追跡可能）"
  fi

  # 4. 観測ログ: PR 番号 / source / 打ち切り理由 / route を 1 行で機械抽出可能に。
  pi_log "PR #${pr_number}: source=${source_kind} out_of_scope=${out_of_scope_count} reason=out-of-scope route=${route} sha=${sha} action=escalated-to-${label}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_detect_developer_oos_marker: Developer（Codex）応答ログから out-of-scope 構造化マーカーを検出
#   入力: $1=log_file（pi_run_iteration が保存する codex `--json` JSONL 応答ログのパス）
#   出力: stdout に検出したマーカー種別（"design" | "spec-stale"）。不在 / 不能 / 語彙外は空。
#   戻り値: 0 固定（fail-safe）
#   Issue #146（idd-claude #437 移植 / idd-codex 固有調整: JSONL agent message 抽出）
#
#   判定: 応答ログの agent message 本文（JSONL イベント中の text / message フィールド。
#         codex CLI の版差に備えて `item.text`（item_type=agent_message）と
#         `msg.message`（msg.type=agent_message）の両形式を探索）を実改行に展開したうえで、
#         厳密書式 `^OUT-OF-SCOPE:[[:space:]]+(design|spec-stale)[[:space:]]*$` を行頭一致で
#         検出する（許容語彙集合 {design, spec-stale} のみ / 前後空白許容）。JSONL として
#         parse できない plain text ログにも同じ行頭一致 grep を fallback 適用する。
#         許容語彙集合外（例: `OUT-OF-SCOPE: foo`）・行中言及・マーカー不在は空返し
#         （安全側 = 従来 round 進行）。最初に一致した行の種別を返す。
#   セキュリティ: 未信頼入力（Developer 応答ログ本文）は jq / grep / awk のみで処理し、
#         sed 置換 / eval / bash -c へ展開しない。抽出種別は case whitelist で最終検証する。
# ─────────────────────────────────────────────────────────────────────────────
pi_detect_developer_oos_marker() {
  local log_file="${1:-}"
  # fail-safe: ログ不在 / 読み取り不能は空返し（誤った打ち切りを防ぐ安全側）。
  if [ -z "$log_file" ] || [ ! -r "$log_file" ]; then
    echo ""
    return 0
  fi

  # JSONL イベントから agent message 本文を抽出（jq -r で escape 済み \n が実改行に展開される）。
  # codex --json の版差（item.completed 形式 / proto msg 形式）を両対応で探索する。
  local agent_text
  agent_text=$(jq -R -r '
    . as $line
    | (try ($line | fromjson) catch null)
    | select(type == "object") as $j
    | [
        ($j.item? // {} | select(((.item_type? // .type? // "") == "agent_message")) | (.text? // empty)),
        ($j.msg? // {} | select((.type? // "") == "agent_message") | (.message? // empty))
      ][]
    | select(type == "string")
  ' "$log_file" 2>/dev/null) || agent_text=""

  local pattern='^OUT-OF-SCOPE:[[:space:]]+(design|spec-stale)[[:space:]]*$'
  local matched=""
  if [ -n "$agent_text" ]; then
    matched=$(printf '%s\n' "$agent_text" | grep -E -- "$pattern" 2>/dev/null | head -1 || true)
  fi
  # fallback: plain text ログ（JSONL でない場合）にも同じ行頭一致 grep を適用する。
  # JSONL の行は `{` 始まりのため本 fallback にはマッチしない（誤検出しない）。
  if [ -z "$matched" ]; then
    matched=$(grep -E -- "$pattern" "$log_file" 2>/dev/null | head -1 || true)
  fi
  if [ -z "$matched" ]; then
    echo ""
    return 0
  fi

  # 種別語彙のみを抽出し、case whitelist で最終検証する（sed 不使用 / awk で切り出し）。
  local kind
  kind=$(printf '%s\n' "$matched" | awk '{ print $2 }')
  case "$kind" in
    design|spec-stale) echo "$kind" ;;
    *) echo "" ;;
  esac
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_oos_fingerprint: out-of-scope 指摘内容の同一性判定キー（fingerprint）を算出する純粋関数
#   入力: $1=decisions_json（out-of-scope finding を含む JSON / 空許容）
#   出力: stdout に fingerprint 文字列（16 進ハッシュ。入力に out-of-scope が無ければ
#         空入力相当の安定ハッシュ）
#   戻り値: 0 固定
#   Issue #146（idd-claude #437 移植）
#
#   設計判断:
#     - out-of-scope finding 群の severity / file / message（message 不在時は reason）を
#       正規化連結し sha256（不能環境は cksum）で fingerprint を生成する。
#     - 「同じ設計レベル矛盾を指している限り同一」を意図し、head commit SHA には依存しない
#       （SHA が毎 round 変化しても内容が同じなら同一 fingerprint）。内容が実質変化すれば
#       fingerprint も変わる。順序非依存にするため severity/file/message タプルを sort して
#       から連結する。
#     - 純粋関数（副作用なし / グローバル参照なし）→ extract_function テストで隔離検証可能。
#     - 未信頼値は jq @tsv でリテラル抽出（filter inline 展開禁止）。
# ─────────────────────────────────────────────────────────────────────────────
pi_oos_fingerprint() {
  local decisions_json="${1:-}"
  local material=""
  if [ -n "$decisions_json" ]; then
    material=$(printf '%s' "$decisions_json" | jq -r '
      [ (.decisions // [])
        | .[]
        | select(.verdict == "out-of-scope")
        | [ (.severity // ""), (.file // ""), (.message // .reason // "") ]
        | @tsv
      ]
      | sort
      | .[]
    ' 2>/dev/null) || material=""
  fi
  # sha256sum を優先し、不能環境（無い / 失敗）は cksum にフォールバックする。
  local hash
  if command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$material" | sha256sum 2>/dev/null | awk '{print $1}')
  fi
  if [ -z "${hash:-}" ]; then
    hash=$(printf '%s' "$material" | cksum 2>/dev/null | awk '{print $1}')
  fi
  echo "${hash:-0}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_read_oos_no_progress_streak: PR body marker から内容ベース no-progress 連続カウンタを取得
#   入力: $1=pr_body（gh pr view --json body --jq '.body // ""' で取得済みの文字列）
#   出力: stdout に整数（key 不在 / marker 不在なら "0"）
#   戻り値: 0 固定
#   Issue #146（idd-claude #437 移植）
#
#   marker 形式: <!-- idd-codex:pr-iteration round=N last-run=... no-progress-streak=K
#                oos-no-progress-streak=J oos-fingerprint=<H> -->
#   既存 marker（oos-no-progress-streak キー無し）の場合は "0" を返す（後方互換）。
#   既存 pi_read_no_progress_streak（SHA ベース）とは独立した別カウンタ（既存不変）。
# ─────────────────────────────────────────────────────────────────────────────
pi_read_oos_no_progress_streak() {
  local pr_body="${1-}"
  if [ -z "$pr_body" ]; then
    echo "0"
    return 0
  fi
  local streak
  streak=$(echo "$pr_body" \
    | grep -oE 'idd-codex:pr-iteration [^>]*oos-no-progress-streak=[0-9]+' \
    | grep -oE 'oos-no-progress-streak=[0-9]+' \
    | grep -oE '[0-9]+$' \
    | tail -1)
  echo "${streak:-0}"
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_read_oos_fingerprint: PR body marker から直前 round の out-of-scope fingerprint を取得
#   入力: $1=pr_body
#   出力: stdout に fingerprint 文字列（key 不在 / marker 不在なら空文字列）
#   戻り値: 0 固定
#   Issue #146（idd-claude #437 移植）
# ─────────────────────────────────────────────────────────────────────────────
pi_read_oos_fingerprint() {
  local pr_body="${1-}"
  if [ -z "$pr_body" ]; then
    echo ""
    return 0
  fi
  local fp
  fp=$(echo "$pr_body" \
    | grep -oE 'idd-codex:pr-iteration [^>]*oos-fingerprint=[0-9a-zA-Z]+' \
    | grep -oE 'oos-fingerprint=[0-9a-zA-Z]+' \
    | awk -F= '{ print $2 }' \
    | tail -1)
  echo "${fp:-}"
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_next_oos_no_progress_streak: 内容ベース no-progress 連続カウンタの次値を求める純粋関数
#   入力: $1=prev_fingerprint（直前 round の fingerprint / 空許容）
#         $2=current_fingerprint（今 round の fingerprint）
#         $3=prev_streak（前サイクルまでの内容ベース no-progress 連続カウンタ値）
#   出力: stdout に次の streak 値
#           fingerprint 同一（かつ非空）→ prev_streak + 1（内容が変わらず堂々巡り）
#           fingerprint 変化 / 空 → "0"（内容が実質変化 = リセット）
#   戻り値: 0 固定
#   Issue #146（idd-claude #437 移植）
#
#   設計判断:
#     - SHA（head commit）には依存せず fingerprint（内容ハッシュ）の同一性のみで加算する。
#       head SHA が毎 round 変化しても fingerprint 同一なら streak は加算される。
#     - prev_fingerprint / current_fingerprint のいずれかが空のときは加算しない（初回 round /
#       取得失敗時に誤って escalate に倒さない安全側 = 0 リセット）。
#     - 純粋関数（副作用なし）→ extract_function テストで隔離検証可能。
# ─────────────────────────────────────────────────────────────────────────────
pi_next_oos_no_progress_streak() {
  local prev_fingerprint="${1-}"
  local current_fingerprint="${2-}"
  local prev_streak="${3-}"
  if [ -n "$prev_fingerprint" ] && [ -n "$current_fingerprint" ] && [ "$prev_fingerprint" = "$current_fingerprint" ]; then
    if [[ "$prev_streak" =~ ^[0-9]+$ ]]; then
      echo "$((prev_streak + 1))"
    else
      echo "1"
    fi
    return 0
  fi
  echo "0"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_run_iteration: 1 PR 分の iteration を実行（fresh context Codex 起動）
#   入力: $1=pr_json
#   戻り値: 0=success(commit+push), 1=failure/hold, 2=escalated(round上限到達),
#           3=skip (kind=none/ambiguous, #35)
#   AC 3.6, 4.x, 5.x, 6.2, 6.3, 7.x, 8.3, 9.2, NFR 1.1, NFR 1.3 (#26)
#   #35: kind 判定で design / impl を分岐し、template と finalize 関数を切り替える
# ─────────────────────────────────────────────────────────────────────────────
pi_run_iteration() {
  local pr_json="$1"
  local pr_number head_ref base_ref pr_url
  pr_number=$(echo "$pr_json" | jq -r '.number')
  head_ref=$(echo "$pr_json"  | jq -r '.headRefName')
  base_ref=$(echo "$pr_json"  | jq -r '.baseRefName')
  pr_url=$(echo "$pr_json"    | jq -r '.url')

  # #35 AC 1.1〜1.4 / 4.4: kind 判定（design / impl / none / ambiguous）
  local kind
  kind=$(pi_classify_pr_kind "$head_ref")

  case "$kind" in
    none)
      pi_log "PR #${pr_number}: kind=none head=${head_ref} (does not match design/impl pattern), skip"
      return 3
      ;;
    ambiguous)
      pi_warn "PR #${pr_number}: kind=ambiguous head=${head_ref} (matches both design and impl pattern), skip"
      return 3
      ;;
    design|impl) : ;;
    *)
      pi_warn "PR #${pr_number}: kind=${kind} (unknown), skip"
      return 3
      ;;
  esac

  # #35 AC 2.x: kind に応じた template path を取得
  local tmpl_path
  if ! tmpl_path=$(pi_select_template "$kind"); then
    pi_warn "PR #${pr_number}: kind=${kind} 用 template が取得できず iteration 中止"
    return 1
  fi

  # Issue #122 Req 1: kind に応じて round 上限を解決（旧 PR_ITERATION_MAX_ROUNDS は
  # 両 kind 共通の fallback）。`0` は無制限の sentinel（Req 2.1〜2.4）。
  local max_rounds
  max_rounds=$(pi_resolve_max_rounds "$kind")
  local max_display
  if [ "$max_rounds" = "0" ]; then
    max_display="無制限"
  else
    max_display="$max_rounds"
  fi

  # Issue #122 Req 3 / 4: PR body から round と no-progress 連続カウンタの両方を抽出。
  # body 取得は pi_read_round_counter で 1 回、pi_read_no_progress_streak は同じ
  # body をローカル抽出するため二重 fetch を避けて pr_body を共有取得する。
  local pr_body_for_marker
  pr_body_for_marker=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
    gh pr view "$pr_number" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null || echo "")
  local round
  round=$(echo "$pr_body_for_marker" \
    | grep -oE 'idd-codex:pr-iteration round=[0-9]+' \
    | grep -oE '[0-9]+$' \
    | tail -1)
  round="${round:-0}"
  local prev_streak
  prev_streak=$(pi_read_no_progress_streak "$pr_body_for_marker")

  # Issue #146: gate ON のとき内容ベース no-progress 連続カウンタ + 直前 fingerprint を
  # 同じ pr_body から抽出する（既存 SHA ベース streak とは独立 / 既存不変）。
  # gate OFF では本変数を参照しない（早期打ち切り自体が no-op）。
  local prev_oos_streak="0" prev_oos_fingerprint=""
  if [ "${PR_ITERATION_OOS_ENABLED:-false}" = "true" ]; then
    prev_oos_streak=$(pi_read_oos_no_progress_streak "$pr_body_for_marker")
    prev_oos_fingerprint=$(pi_read_oos_fingerprint "$pr_body_for_marker")
  fi
  # Issue #146: 閾値未満で round が継続するとき marker へ永続化する内容ベース no-progress
  # streak / fingerprint。gate OFF / out-of-scope 経路を通らなかった場合は空のまま
  # （pi_write_marker は空引数を受けて従来 3 フィールド marker を書く / byte 互換）。
  local _pi_oos_marker_streak="" _pi_oos_marker_fingerprint=""

  # Issue #122 Req 2.1 / 2.3: max_rounds=0 は「round 数超過のみによる escalate を行わない」
  # （AC 2.1: design / AC 2.3: impl）。max_rounds>0 のときは round >= max で escalate。
  if [ "$max_rounds" != "0" ] && [ "$round" -ge "$max_rounds" ]; then
    # Issue #122 Req 6.4: PR 番号 / kind / round / max / 原因を 1 行に整形
    pi_log "PR #${pr_number}: kind=${kind} round=${round} max=${max_rounds} reason=max-rounds escalate"
    pi_escalate_to_failed "$pr_number" "$round" "$max_rounds" "max-rounds" || true
    return 2
  fi

  local next_round=$((round + 1))

  # Issue #122 Req 4 / 5: marker は round 終了時の成功 path でのみ書き込む。
  # 着手表明コメントは round 開始時に投稿（人間向け視認用、既存挙動 NFR 1.1）。
  pi_post_processing_comment "$pr_number" "$next_round" "$max_rounds"

  pi_log "PR #${pr_number}: kind=${kind} round=${next_round}/${max_display} 着手 (${pr_url})"

  # #118 Req 1.1 / 2.1: soft-fail 検知用 / 自動回復結果のサブシェル <-> 親 通信用に
  # tmpfile を 2 つ用意する。
  #   - $pi_soft_fail_file : 検出 1 件 1 行（`pi_detect_quota_soft_fail` の出力）
  #   - $pi_recover_file   : サブシェル終端で書き出す自動回復結果の 1 行。
  #                          書式: `<kind>:<result>` 例: `soft-fail-commit:ok`,
  #                                `post-round-commit:ok`, `post-round-commit:fail`,
  #                                `none:` （回復不要 / dirty なし）
  # Issue #122 Req 3: subshell <-> 親 で SHA 比較用に before/after の 2 行も tmpfile に書き出す。
  #   - $pi_sha_file : 1 行目=before_sha, 2 行目=after_sha
  local pi_soft_fail_file pi_recover_file pi_sha_file pi_usage_fatal_file
  if ! pi_soft_fail_file=$(idd_secure_mktemp "pi-softfail-${pr_number}"); then
    pi_warn "PR #${pr_number}: soft-fail secure tempfile の作成に失敗"
    return 1
  fi
  if ! pi_recover_file=$(idd_secure_mktemp "pi-recover-${pr_number}"); then
    rm -f "$pi_soft_fail_file"
    pi_warn "PR #${pr_number}: recovery secure tempfile の作成に失敗"
    return 1
  fi
  if ! pi_sha_file=$(idd_secure_mktemp "pi-sha-${pr_number}"); then
    rm -f "$pi_soft_fail_file" "$pi_recover_file"
    pi_warn "PR #${pr_number}: SHA secure tempfile の作成に失敗"
    return 1
  fi
  if ! pi_usage_fatal_file=$(idd_secure_mktemp "pi-usage-fatal-${pr_number}"); then
    rm -f "$pi_soft_fail_file" "$pi_recover_file" "$pi_sha_file"
    pi_warn "PR #${pr_number}: usage-limit secure tempfile の作成に失敗"
    return 1
  fi
  # Issue #146: subshell <-> 親 で Developer（Codex）構造化マーカーの検出種別を渡すための
  # tmpfile（1 行: "design" | "spec-stale" | ""）。gate OFF では書かない（空のまま）。
  local pi_oos_marker_file
  if ! pi_oos_marker_file=$(idd_secure_mktemp "pi-oosmark-${pr_number}"); then
    rm -f "$pi_soft_fail_file" "$pi_recover_file" "$pi_sha_file" "$pi_usage_fatal_file"
    pi_warn "PR #${pr_number}: oos-marker secure tempfile の作成に失敗"
    return 1
  fi
  : > "$pi_soft_fail_file"
  : > "$pi_recover_file"
  : > "$pi_sha_file"
  : > "$pi_usage_fatal_file"
  : > "$pi_oos_marker_file"

  # サブシェル + trap で必ず base branch に戻す（AC 8.3）
  local rc=0
  (
    set +e
    # shellcheck disable=SC2064
    trap "git checkout '${BASE_BRANCH}' >/dev/null 2>&1" EXIT

    # head branch を fresh に checkout（origin の最新状態に追従、AC 4.4）
    if ! timeout "$PR_ITERATION_GIT_TIMEOUT" git fetch origin "$head_ref" >/dev/null 2>&1; then
      pi_warn "PR #${pr_number}: git fetch origin ${head_ref} に失敗"
      exit 1
    fi
    if ! timeout "$PR_ITERATION_GIT_TIMEOUT" git checkout -B "$head_ref" "origin/${head_ref}" >/dev/null 2>&1; then
      pi_warn "PR #${pr_number}: head branch '${head_ref}' の checkout に失敗"
      exit 1
    fi

    # Issue #122 Req 3.1 / 3.2: round 開始時の HEAD を記録。round 終了時に同じ branch の
    # HEAD と比較して「新規 commit が push されたか」を判定する。
    local before_sha
    before_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
    printf '%s\n' "$before_sha" > "$pi_sha_file"

    # prompt を生成（#35: kind に応じた template path を渡す / #122: kind 別 max_rounds を渡す）
    local prompt
    if ! prompt=$(pi_build_iteration_prompt "$pr_number" "$pr_json" "$next_round" "$tmpl_path" "$max_rounds"); then
      pi_warn "PR #${pr_number}: prompt 組み立てに失敗"
      exit 1
    fi

    # AC 3.6: fresh context で起動（--resume / --continue は使わない）
    # NFR 1.1: --max-turns で turn 数上限
    local pi_log_file
    pi_log_file="$LOG_DIR/pr-iteration-${kind}-${pr_number}-round${next_round}-$(date +%Y%m%d-%H%M%S).log"

    # #118 Req 1.1 / 5.1: codex の stream-json 出力を tee で 2 系統に分岐。
    #   - 系統 1: 既存通り $pi_log_file へ append（観測ログを壊さない / NFR 1.2）。
    #   - 系統 2: pi_detect_quota_soft_fail で `allowed_warning` イベントを検出し
    #            $pi_soft_fail_file に書き出す。QUOTA_AWARE_ENABLED とは独立に動作する
    #            （Req 5.1）。
    # set -e / pipefail 配下で `tee` や `jq` の非 0 exit を握り潰さないよう、
    # PIPESTATUS を即座にコピーしてから codex 本体の exit code を取り出す。
    local codex_rc=0
    set +e
    codex_exec_prompt "PR-iteration-${kind}-r${next_round}" "$PR_ITERATION_DEV_MODEL" "$prompt" \
        2>&1 \
      | tee -a "$pi_log_file" \
      | pi_detect_quota_soft_fail \
      > "$pi_soft_fail_file"
    local _pi_pipestatus=("${PIPESTATUS[@]}")
    set -e
    codex_rc="${_pi_pipestatus[0]:-0}"

    local usage_limit_fatal_observed=false
    if [ "$codex_rc" -ne 0 ]; then
      pi_warn "PR #${pr_number}: kind=${kind} Codex 実行が失敗 (log: ${pi_log_file})"
      local _pi_usage_rc=0
      local _pi_usage_line=""
      _pi_usage_line=$(pi_detect_usage_limit_fatal "$pi_log_file") || _pi_usage_rc=$?
      if [ "$_pi_usage_rc" -eq 0 ]; then
        pi_handle_usage_limit_fatal "$pr_number" "$kind" "$next_round" "$pi_log_file" "$_pi_usage_line" || true
        usage_limit_fatal_observed=true
        printf '%s' "usage-limit-fatal" > "$pi_usage_fatal_file"
      fi
      # codex 失敗時も round 中に部分編集が残っている可能性があるため、後段の自動回復に
      # 続ける。検出 file の有無にかかわらず post-round-recover 経路で dirty を退避する。
      #
      # Issue #259: 失敗ログから Codex API 一時混雑エラー (529 Overloaded) の痕跡を検出
      # した場合、PR コメントとして一時障害である旨と次回ポーリングサイクルで自動再試行
      # される旨を投稿する。検知ロジックが失敗・例外を起こしても既存の codex-needs-iteration
      # 据え置き / codex-failed 遷移 / post-round-recover 経路を妨げないよう、すべての
      # 副作用は `|| true` で握り、grep の失敗（一致なし）と区別する。
      #   - 検知あり (rc=0) → PR コメント投稿 + INFO ログ
      #   - 検知なし (rc=1) → INFO ログのみ
      #   - ログ不在 (rc=2) → WARN ログのみ（既存処理は継続 / Req 1.5）
      if [ "$usage_limit_fatal_observed" != "true" ]; then
        local _pi_529_rc=0
        codex_log_detect_529 "$pi_log_file" || _pi_529_rc=$?
        case "$_pi_529_rc" in
          0)
            pi_log "PR #${pr_number}: kind=${kind} round=${next_round} 529-overloaded detected (log: ${pi_log_file})"
            local _pi_529_body
            _pi_529_body=":warning: **Codex API 一時混雑エラー (529 Overloaded)**: 混雑のため一時処理を中断しました。進捗（Round数等）は据え置かれ、次のポーリングサイクルで自動再試行します。

<!-- idd-codex:pr-iteration-529-warning round=${next_round} -->"
            if ! timeout "$PR_ITERATION_GIT_TIMEOUT" \
                gh pr comment "$pr_number" --repo "$REPO" --body "$_pi_529_body" >/dev/null 2>&1; then
              pi_warn "PR #${pr_number}: kind=${kind} round=${next_round} 529 警告コメントの投稿に失敗 (既存処理は継続)"
            fi
            ;;
          2)
            pi_warn "PR #${pr_number}: kind=${kind} round=${next_round} 529 検知用ログファイルが不在または読み取り不能のためスキップ (log: ${pi_log_file})"
            ;;
          *)
            pi_log "PR #${pr_number}: kind=${kind} round=${next_round} 529-overloaded not detected"
            ;;
        esac
      fi
    else
      pi_log "PR #${pr_number}: kind=${kind} Codex 実行完了 (log: ${pi_log_file})"
    fi

    # Issue #146: gate ON のとき Developer（Codex）応答ログから out-of-scope 構造化マーカーを
    # 検出し、種別（design / spec-stale / 不在は空）を tmpfile 経由で親へ渡す。検出は読み取り
    # 専用・fail-safe（pi_detect_developer_oos_marker はログ不在でも空返し）。gate OFF では
    # 本ブロックを skip し空のまま（既存フロー byte 互換）。
    if [ "${PR_ITERATION_OOS_ENABLED:-false}" = "true" ]; then
      local _pi_dev_oos_marker
      _pi_dev_oos_marker=$(pi_detect_developer_oos_marker "$pi_log_file")
      printf '%s' "$_pi_dev_oos_marker" > "$pi_oos_marker_file"
    fi

    # #118 Req 1.2 / 2.1 / 2.2: round 終了時点の dirty 判定と自動回復。
    # 設計判断:
    #   - 「soft-fail を検出 かつ 差分あり」「soft-fail なし かつ 差分あり」「差分なし」の 3 系統。
    #   - soft-fail 検出が優先（Req 2.5）。
    #   - branch ガードは pi_branch_is_codex_pr_head で実施（人間 branch には auto-commit しない）。
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    local soft_fail_observed=false
    if [ -s "$pi_soft_fail_file" ]; then
      soft_fail_observed=true
    fi
    local has_dirty=false
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      has_dirty=true
    fi

    # branch ガード（Req 3.2 / 3.4 の round-内版）: 想定外 branch に居る場合は
    # auto-commit せず WARN（codex 失敗時の subshell 早期 exit や fetch/checkout 失敗で
    # current_branch が head_ref と乖離するシナリオを安全側に倒す）。
    if [ "$has_dirty" = "true" ] && ! pi_branch_is_codex_pr_head "$current_branch"; then
      pi_warn "PR #${pr_number}: kind=${kind} round=${next_round} 想定外 branch '${current_branch}' に dirty 検出 (auto-commit 抑止)"
      printf '%s' "post-round-commit:fail" > "$pi_recover_file"
      if [ "$codex_rc" -ne 0 ]; then
        exit 1
      fi
      # codex 成功なのに branch 不一致は構造上ほぼ起きない（防御的）。後続で finalize しないよう fail を返す。
      exit 1
    fi

    local recover_status="none:"
    if [ "$has_dirty" = "true" ]; then
      if [ "$soft_fail_observed" = "true" ]; then
        # Req 1.2 / 1.3 / 2.5: soft-fail 時の commit message
        if pi_auto_commit_and_push \
            "docs(specs): partial round-${next_round} output before quota cutoff (auto-recovered)" \
            "$current_branch"; then
          recover_status="soft-fail-commit:ok"
        else
          recover_status="soft-fail-commit:fail"
        fi
      else
        # Req 2.2 / 2.3: 通常 dirty 時の commit message
        if pi_auto_commit_and_push \
            "docs(specs): recover uncommitted round-${next_round} output (auto)" \
            "$current_branch"; then
          recover_status="post-round-commit:ok"
        else
          recover_status="post-round-commit:fail"
        fi
      fi
    elif [ "$soft_fail_observed" = "true" ]; then
      # 差分は無いが soft-fail を観測した（差分前に round が打ち切られた稀ケース）
      recover_status="soft-fail-commit:ok"
    fi
    printf '%s' "$recover_status" > "$pi_recover_file"

    # Issue #122 Req 3.1 / 3.2: 自動回復まで含む round 終了時点の HEAD を記録。
    # before_sha と異なれば新規 commit が push された（reply-only 経路で codex 自身が
    # commit+push した場合、または pi_auto_commit_and_push で auto-commit した場合の両方をカバー）。
    local after_sha
    after_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
    printf '%s\n%s\n' "$before_sha" "$after_sha" > "$pi_sha_file"

    # codex 自体の rc を引き継ぐ（失敗は呼び出し元で WARN + codex-needs-iteration 残置に倒れる）
    exit "$codex_rc"
  )
  rc=$?
  # 保険: 呼び出し元でも base branch に戻す
  git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true

  # #118 Req 1.1 / 4.1 / 4.2: 自動回復結果を読み取ってログ + 後続挙動を分岐
  local recover_status="none:"
  if [ -s "$pi_recover_file" ]; then
    recover_status=$(cat "$pi_recover_file")
  fi
  local soft_fail_summary=""
  if [ -s "$pi_soft_fail_file" ]; then
    # 検出が複数行ある場合は最後の値を採用（最新 utilization）。tab 区切り 2 列目。
    soft_fail_summary=$(awk -F '\t' 'NF >= 2 { last = $2 } END { print last }' "$pi_soft_fail_file")
  fi
  # Issue #122 Req 3.1 / 3.2: SHA 比較で「新規 commit が push されたか」判定
  local before_sha="" after_sha=""
  if [ -s "$pi_sha_file" ]; then
    before_sha=$(sed -n '1p' "$pi_sha_file")
    after_sha=$(sed -n '2p' "$pi_sha_file")
  fi
  local usage_fatal_status=""
  if [ -s "$pi_usage_fatal_file" ]; then
    usage_fatal_status=$(cat "$pi_usage_fatal_file")
  fi
  # Issue #146: Developer（Codex）構造化マーカー検出種別（gate OFF / 不在は空）を読み取る。
  local dev_oos_marker=""
  if [ -s "$pi_oos_marker_file" ]; then
    dev_oos_marker=$(cat "$pi_oos_marker_file")
  fi
  rm -f "$pi_soft_fail_file" "$pi_recover_file" "$pi_sha_file" "$pi_usage_fatal_file" "$pi_oos_marker_file"

  # Issue #122 Req 5: 失敗扱い（quota soft-fail / codex crash / post-round-commit fail）の
  # round では marker を据え置く（round counter / no-progress streak いずれも増減させない）。
  # 成功 path（recover_status=post-round-commit:ok or none:）のみ marker を更新する。
  case "$recover_status" in
    soft-fail-commit:ok)
      # Req 1.1 / 1.2 / 1.4 / 4.1 (#118): soft-fail 検出 + auto-commit 成功 → codex-needs-iteration 据え置き
      # Issue #122 Req 5.1 / 5.2: marker 更新せず prev_round / prev_streak のまま温存
      pi_log "PR #${pr_number}: kind=${kind} round=${next_round} quota-soft-fail utilization=${soft_fail_summary} action=auto-commit+keep-label"
      return 1
      ;;
    soft-fail-commit:fail)
      # Req 1.5 (#118): auto-commit / push 失敗 → WARN + codex-needs-iteration 据え置き
      # Issue #122 Req 5.1 / 5.2: 同上、marker 据え置き
      pi_warn "PR #${pr_number}: kind=${kind} round=${next_round} quota-soft-fail utilization=${soft_fail_summary} action=auto-commit-failed (codex-needs-iteration を残置)"
      return 1
      ;;
    post-round-commit:ok)
      # Req 2.1 / 2.2 / 4.2 (#118): 通常 dirty + auto-commit 成功 → 通常 finalize に進む
      pi_log "PR #${pr_number}: kind=${kind} round=${next_round} post-round-recover branch=${head_ref} action=success"
      ;;
    post-round-commit:fail)
      # Req 2.4 / 4.3 (#118): auto-commit / push 失敗 → WARN + 終了
      # Issue #122 Req 5.3: marker 据え置き（counter / streak を加算しない）
      pi_warn "PR #${pr_number}: kind=${kind} round=${next_round} post-round-recover branch=${head_ref} action=fail"
      return 1
      ;;
    none:|"")
      : # 回復不要（dirty なし）
      ;;
    *)
      pi_warn "PR #${pr_number}: kind=${kind} 未知の recover_status='${recover_status}' (codex-needs-iteration を残置)"
      return 1
      ;;
  esac

  if [ "$usage_fatal_status" = "usage-limit-fatal" ]; then
    pi_log "PR #${pr_number}: kind=${kind} round=${next_round} action=usage-limit-fatal-handled"
    return 1
  fi

  if [ $rc -eq 0 ]; then
    # Issue #146: gate ON のとき、通常 finalize / no-progress 判定の前に out-of-scope 経路を
    # 評価する。gate OFF（既定）では本ブロックを完全 skip し既存フローへ進む（byte 互換）。
    if [ "${PR_ITERATION_OOS_ENABLED:-false}" = "true" ]; then
      # adjudicator が投稿した out-of-scope marker コメントを収集し、内容ベース fingerprint を
      # 算出するための decisions-like JSON を組み立てる（severity / file / message を保持）。
      # marker `<!-- idd-codex:pr-adjudicator-out-of-scope id=<N> sha=<sha> -->` を持つコメント
      # 本文から severity / file / 理由 を抽出する。取得失敗は空 JSON（fail-safe）。
      local oos_decisions_json="{}"
      local _pi_oos_comments
      _pi_oos_comments=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
        gh api "/repos/${REPO}/issues/${pr_number}/comments" 2>/dev/null \
        | jq -c '[.[] | select((.body // "") | contains("idd-codex:pr-adjudicator-out-of-scope")) | {body}]' 2>/dev/null) \
        || _pi_oos_comments="[]"
      if [ -n "$_pi_oos_comments" ] && [ "$_pi_oos_comments" != "[]" ]; then
        # コメント本文から `- severity:` / `- file:` / `- 理由（...）:` の行を拾って
        # decisions[] を再構成する（adj_post_decision_comment の投稿書式に対応）。未信頼値は
        # jq 内 capture でリテラル処理する（inline 展開禁止）。fingerprint は
        # severity/file/message のみ使用するため message には理由行を充てる。
        oos_decisions_json=$(printf '%s' "$_pi_oos_comments" | jq -c '
          { decisions: [ .[]
            | .body as $b
            | { verdict: "out-of-scope",
                severity: (($b | capture("(?m)^- severity: (?<v>.*)$").v) // ""),
                file:     (($b | capture("(?m)^- file: (?<v>.*)$").v) // ""),
                message:  (($b | capture("(?m)^- 理由（[^）]*）: (?<v>.*)$").v) // "") }
          ] }
        ' 2>/dev/null) || oos_decisions_json="{}"
      fi

      local current_oos_fingerprint
      current_oos_fingerprint=$(pi_oos_fingerprint "$oos_decisions_json")

      # (a) Developer が out-of-scope 構造化マーカーを宣言した round は finalize せず
      #     即ルーティングへ引き渡す（in-scope 実害が残っていない前提を Developer 判断で確定 /
      #     SHA ベース no-progress とは別の内容ベース早期打ち切り）。
      if [ -n "$dev_oos_marker" ]; then
        pi_log "PR #${pr_number}: kind=${kind} round=${next_round} reason=developer-oos-marker marker=${dev_oos_marker} action=route-out-of-scope"
        pi_route_out_of_scope_escalate "$pr_number" "$after_sha" "$oos_decisions_json" "developer-marker:${dev_oos_marker}" "?" || true
        return 2
      fi

      # (b) 内容ベース no-progress 早期打ち切り。fingerprint 同一（SHA 変化に依存しない）で
      #     連続したら streak を加算し、閾値到達で max_rounds 到達前に打ち切ってルーティング
      #     する。fingerprint 変化でリセット。out-of-scope 指摘が 1 件も無い round は
      #     oos_decisions_json が空 → fingerprint は「空集合ハッシュ」で安定し、指摘なしの
      #     round が連続しても打ち切り対象にしない（out-of-scope marker コメント不在時は
      #     streak を必ず 0 リセットする下記ガードで担保）。
      if [ "$_pi_oos_comments" = "[]" ] || [ -z "$_pi_oos_comments" ]; then
        # out-of-scope 指摘なし → 内容ベース streak をリセットして通常フローへ。
        _pi_oos_marker_streak="0"
        _pi_oos_marker_fingerprint=""
      else
        local next_oos_streak
        next_oos_streak=$(pi_next_oos_no_progress_streak "$prev_oos_fingerprint" "$current_oos_fingerprint" "$prev_oos_streak")
        local _pi_oos_limit="${PR_ITERATION_OOS_NO_PROGRESS_LIMIT:-2}"
        case "$_pi_oos_limit" in ''|*[!0-9]*) _pi_oos_limit=2 ;; esac
        if [[ "$next_oos_streak" =~ ^[0-9]+$ ]] && [ "$next_oos_streak" -ge "$_pi_oos_limit" ]; then
          pi_log "PR #${pr_number}: kind=${kind} round=${next_round} reason=oos-content-no-progress oos-no-progress-streak=${next_oos_streak} limit=${_pi_oos_limit} action=route-out-of-scope"
          pi_route_out_of_scope_escalate "$pr_number" "$after_sha" "$oos_decisions_json" "content-no-progress" "?" || true
          return 2
        fi
        # 閾値未満: oos streak / fingerprint を marker に永続化して次 round で比較する。
        # 通常 SHA ベース streak と round counter の更新は下流の pi_write_marker に委ねるため、
        # ここでは値だけ控えて pi_write_marker 呼び出し時に渡す。
        _pi_oos_marker_streak="$next_oos_streak"
        _pi_oos_marker_fingerprint="$current_oos_fingerprint"
      fi
    fi

    # Issue #122 Req 3.1 / 3.2: SHA 比較で「新規 commit が push されたか」判定。
    # before_sha と after_sha が異なれば新規 commit あり（codex 自身による commit+push、
    # または pi_auto_commit_and_push 経由の auto-commit、いずれもカバー）。
    local commit_pushed=false
    if [ -n "$before_sha" ] && [ -n "$after_sha" ] && [ "$before_sha" != "$after_sha" ]; then
      commit_pushed=true
    fi
    # Issue #122 Req 3.1 / 3.2: no-progress 連続カウンタの更新
    local new_streak
    if [ "$commit_pushed" = "true" ]; then
      new_streak=0
    else
      new_streak=$((prev_streak + 1))
    fi

    # Issue #122 Req 6.2: round 終了時点で no-progress 連続カウンタが加算されたら
    # PR 番号 / kind / 加算後の連続カウンタ / 上限値を 1 行ログに記録
    if [ "$commit_pushed" = "false" ]; then
      pi_log "PR #${pr_number}: kind=${kind} round=${next_round} no-progress-streak=${new_streak} limit=${PR_ITERATION_NO_PROGRESS_LIMIT}"
    fi

    # Issue #122 Req 5.4 / Req 4.1: marker 書き込み。失敗は Req 5.4 の通り ERROR + 据え置き
    # Issue #146: gate ON で out-of-scope 経路を通過した round は oos streak / fingerprint も
    # 併せて永続化する（第 4/5 引数）。gate OFF / 経路未通過では空のまま渡し、pi_write_marker
    # が従来 3 フィールド marker を書く（byte 互換）。
    if ! pi_write_marker "$pr_number" "$next_round" "$new_streak" "$_pi_oos_marker_streak" "$_pi_oos_marker_fingerprint"; then
      pi_error "PR #${pr_number}: kind=${kind} round=${next_round} marker 書き込みに失敗 (codex-needs-iteration を残置)"
      return 1
    fi

    # Issue #3 / #122 Req 3.3 / 6.3: commit が無い round は success label transition に進めない。
    # 明示的な reply-only success contract は未定義のため、no-progress limit 未満は hold、
    # limit 到達時のみ no-progress escalation に倒す。
    local success_action
    success_action=$(pi_resolve_success_action "$commit_pushed" "$new_streak" "$PR_ITERATION_NO_PROGRESS_LIMIT")
    case "$success_action" in
      escalate)
        pi_log "PR #${pr_number}: kind=${kind} round=${next_round} no-progress-streak=${new_streak} limit=${PR_ITERATION_NO_PROGRESS_LIMIT} reason=no-progress escalate"
        pi_escalate_to_failed "$pr_number" "$next_round" "$max_rounds" "no-progress" "$new_streak" || true
        return 2
        ;;
      hold)
        pi_log "PR #${pr_number}: kind=${kind} round=${next_round} action=hold (codex-needs-iteration を残置; no new commit)"
        return 1
        ;;
      success)
        : ;;
      *)
        pi_warn "PR #${pr_number}: kind=${kind} round=${next_round} unknown success_action='${success_action}' (codex-needs-iteration を残置)"
        return 1
        ;;
    esac

    # AC 6.2 (#26) / #35 AC 3.1 / 3.2: kind に応じたラベル遷移
    local finalize_ok=false
    case "$kind" in
      design)
        if pi_finalize_labels_design "$pr_number"; then
          pi_log "PR #${pr_number}: kind=${kind} round=${next_round} action=success (codex-needs-iteration -> codex-awaiting-design-review)"
          finalize_ok=true
        fi
        ;;
      impl)
        if pi_finalize_labels "$pr_number"; then
          pi_log "PR #${pr_number}: kind=${kind} round=${next_round} action=success (codex-needs-iteration -> codex-ready-for-review)"
          finalize_ok=true
        fi
        ;;
    esac
    if [ "$finalize_ok" = "true" ]; then
      return 0
    fi
    pi_warn "PR #${pr_number}: kind=${kind} ラベル遷移失敗、codex-needs-iteration を残置"
    return 1
  else
    # AC 6.3 (#26) / #35 AC 3.3: 失敗 → codex-needs-iteration を残し WARN
    # Issue #122 Req 5.3: codex CLI が非 0 終了した round では marker 据え置き
    # （上記 case で recover_status が none: / post-round-commit:ok のときのみここに来るが、
    # rc != 0 の場合は codex が失敗しているので marker は触らない）
    pi_log "PR #${pr_number}: kind=${kind} round=${next_round} action=fail (codex-needs-iteration を残置)"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# process_pr_iteration: PR Iteration Processor のエントリ関数
#   AC 1.6, 2.1, 2.2, 8.5, 9.1, 9.3, NFR 1.2, NFR 2.3
# ─────────────────────────────────────────────────────────────────────────────
process_pr_iteration() {
  # AC 2.1: opt-out gate（#112 以降デフォルト有効。PR_ITERATION_ENABLED=false で無効化）
  if [ "$PR_ITERATION_ENABLED" != "true" ]; then
    return 0
  fi

  # NFR 2.3 / AC 8.5: dirty working tree 検知
  # #118 Req 3.1〜3.5: 前 cycle で round が途中終了して dirty を残した場合、
  # current branch が `codex/issue-<N>-<slug>` 命名規約に合致するときは auto-commit /
  # push で clean state に戻し、Processor の本処理を継続する。合致しない branch では
  # ERROR + skip（既存挙動と同じ安全側）。QUOTA_AWARE_ENABLED とは独立（Req 5.2）。
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    local _pi_pre_branch _pi_dirty_paths _pi_pre_issue
    _pi_pre_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    # dirty 一覧は `git status --porcelain` の `XY path` 列を末尾だけ取り出し、コンマ区切り化
    _pi_dirty_paths=$(git status --porcelain 2>/dev/null | awk '{
      $1=""; sub(/^ /, ""); printf "%s%s", (NR>1?",":""), $0
    }')
    # branch 名から PR 番号を派生（Req 4.2: PR 番号 / branch / 種別 / 結果 を出力）
    _pi_pre_issue=$(echo "$_pi_pre_branch" | grep -oE 'issue-[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
    # Req 3.1: branch 名と dirty パス一覧をログに記録（recover/skip 双方の経路で出力）
    pi_log "pre-cycle dirty 検出 issue=#${_pi_pre_issue:-?} branch=${_pi_pre_branch} paths=${_pi_dirty_paths}"

    if pi_branch_is_codex_pr_head "$_pi_pre_branch"; then
      # Req 3.2 / 3.3: 規約一致 branch に対して auto-commit / push して継続
      if pi_auto_commit_and_push \
          "docs(specs): recover pre-cycle dirty state on ${_pi_pre_branch} (auto)" \
          "$_pi_pre_branch"; then
        # 本処理は BASE_BRANCH で動かすため、回復後に BASE_BRANCH に戻す。
        # `set -e` 配下なので checkout 失敗時は次の git ops で検出され ERROR に倒れる。
        git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
        # Req 4.2: PR 番号 / branch / 種別 / 結果 を 1 行で出力
        pi_log "pre-cycle-recover issue=#${_pi_pre_issue:-?} branch=${_pi_pre_branch} action=success"
      else
        # Req 3.5: 自動回復失敗は ERROR + skip（次サイクルで再評価）
        pi_error "pre-cycle-recover issue=#${_pi_pre_issue:-?} branch=${_pi_pre_branch} action=fail (PR Iteration Processor をスキップします)"
        return 0
      fi
    else
      # Req 3.4: codex/issue-<N>-<slug> 規約外の branch では auto-commit せず skip
      pi_error "dirty working tree を検出しました（branch=${_pi_pre_branch} は codex/issue-<N>-<slug> 規約外）。PR Iteration Processor をスキップします。"
      return 0
    fi
  fi

  pi_process_quota_resume

  # Issue #122 Req 6.1 / NFR 3.1: kind 別 round 上限の解決値と no-progress 上限を
  # 1 行サマリログで出力（grep 'max_rounds_impl=' で機械抽出可能）。
  local _resolved_max_impl _resolved_max_design
  _resolved_max_impl=$(pi_resolve_max_rounds "impl")
  _resolved_max_design=$(pi_resolve_max_rounds "design")
  pi_log "サイクル開始 (max_prs=${PR_ITERATION_MAX_PRS}, max_rounds_impl=${_resolved_max_impl}, max_rounds_design=${_resolved_max_design}, no_progress_limit=${PR_ITERATION_NO_PROGRESS_LIMIT}, model=${PR_ITERATION_DEV_MODEL}, design_enabled=${PR_ITERATION_DESIGN_ENABLED}, timeout=${PR_ITERATION_GIT_TIMEOUT}s)"

  local prs_json
  prs_json=$(pi_fetch_candidate_prs)
  local total
  total=$(echo "$prs_json" | jq 'length')

  # #35 NFR 3.2: 候補 PR の design / impl 内訳をログに記録（kind=ambiguous も含む）。
  # candidate 段階では impl pattern OR (DESIGN_ENABLED=true AND design pattern) で絞られる
  # ため、ここでは bash 側で同じ正規表現照合を行って breakdown を出す。
  local design_count=0
  local impl_count=0
  local ambiguous_count=0
  if [ "$total" -gt 0 ]; then
    local breakdown
    breakdown=$(echo "$prs_json" | jq -r \
      --arg impl_pattern "$PR_ITERATION_HEAD_PATTERN" \
      --arg design_pattern "$PR_ITERATION_DESIGN_HEAD_PATTERN" \
      --arg design_enabled "$PR_ITERATION_DESIGN_ENABLED" \
      '[.[] | .headRefName] as $heads
       | reduce $heads[] as $h ({"design":0, "impl":0, "ambiguous":0};
           if ($h | test($impl_pattern)) and ($h | test($design_pattern))
             then .ambiguous += 1
           elif ($h | test($design_pattern)) and ($design_enabled == "true")
             then .design += 1
           elif ($h | test($impl_pattern))
             then .impl += 1
           else . end)
       | "\(.design) \(.impl) \(.ambiguous)"')
    # shellcheck disable=SC2086
    set -- $breakdown
    design_count="${1:-0}"
    impl_count="${2:-0}"
    ambiguous_count="${3:-0}"
  fi

  local target_count="$total"
  local skipped_overflow=0

  if [ "$total" -gt "$PR_ITERATION_MAX_PRS" ]; then
    target_count="$PR_ITERATION_MAX_PRS"
    skipped_overflow=$((total - PR_ITERATION_MAX_PRS))
    pi_log "対象候補 ${total} 件中、上限 ${PR_ITERATION_MAX_PRS} 件のみ処理（${skipped_overflow} 件は次回持ち越し、内訳: design=${design_count}, impl=${impl_count}, ambiguous=${ambiguous_count}）"
  else
    pi_log "対象候補 ${total} 件、処理対象 ${target_count} 件（内訳: design=${design_count}, impl=${impl_count}, ambiguous=${ambiguous_count}）"
  fi

  if [ "$target_count" -eq 0 ]; then
    pi_log "サマリ: success=0, fail=0, skip=0, escalated=0, overflow=${skipped_overflow} (design=0, impl=0)"
    return 0
  fi

  local success=0
  local fail=0
  local skip=0
  local escalated=0

  local pr_iter
  pr_iter=$(echo "$prs_json" | jq -c ".[0:${target_count}][]")

  if [ -z "$pr_iter" ]; then
    pi_log "サマリ: success=0, fail=0, skip=0, escalated=0, overflow=${skipped_overflow} (design=0, impl=0)"
    return 0
  fi

  while IFS= read -r pr_json; do
    local rc=0
    pi_run_iteration "$pr_json" || rc=$?
    case $rc in
      0)  success=$((success + 1)) ;;
      2)  escalated=$((escalated + 1)) ;;
      3)  skip=$((skip + 1)) ;;       # #35: kind=none / ambiguous は skip としてカウント
      *)  fail=$((fail + 1)) ;;
    esac
    # 各 PR 処理後に保険で base branch に戻す
    git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
  done <<< "$pr_iter"

  # #35 NFR 3.1 / 3.2: サマリにも design / impl 内訳を出して grep 集計可能にする
  pi_log "サマリ: success=${success}, fail=${fail}, skip=${skip}, escalated=${escalated}, overflow=${skipped_overflow} (design=${design_count}, impl=${impl_count})"

  # 念のため最終確認で base branch に戻す
  git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
}
