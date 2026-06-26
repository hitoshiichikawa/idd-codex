#!/usr/bin/env bash
# shellcheck shell=bash
# pr-reviewer.sh — watcher の PR Reviewer Processor モジュール (#261)
#
# 用途:
#   idd-codex-issue-watcher.sh から分離した PR Reviewer Processor (#261) の関数定義を集約する。
#   `PR_REVIEWER_ENABLED=true` のとき外部 AI レビューツール（`codex` または
#   `antigravity` (バイナリ名 `agy`)）を呼び出し、open PR に対するレビュー結果を
#   PR コメントとして投稿し、修正要求の VERDICT を検出した場合に `codex-needs-iteration`
#   ラベルを付与して既存 PR Iteration Processor (#26) のループへ接続する。
#   - 入口: process_pr_reviewer（dispatcher から呼ばれる）
#   - tool 解決と排他検証: pr_resolve_tool（出力: `codex` / `antigravity` /
#     `none` / `conflict`、戻り値 0 = ok / 1 = conflict / 2 = none）
#   - 健全性チェック: pr_check_tool_installed / pr_check_tool_authenticated
#   - 重複防止 marker: pr_build_marker / pr_already_processed（gh api comments + jq）
#   - 候補 PR 列挙: pr_fetch_candidate_prs（open + 非 draft + head pattern + 非 fork）
#   - レビュー実行: pr_build_prompt_file / pr_substitute_placeholders /
#     pr_execute_review_command（subshell + trap で head checkout / BASE 復帰 /
#     read-only invariant 検査）
#   - コメント投稿: pr_post_review_comment / pr_post_error_comment（hidden marker 付き）
#   - VERDICT 検出 / formal review / ラベル付与:
#     pr_detect_iteration_keyword / pr_detect_approval_keyword /
#     pr_resolve_review_verdict / pr_try_post_formal_approval /
#     pr_add_iteration_label
#   - 1 PR 分のレビューを統括: pr_run_review_for_pr
#
# 配置先:
#   $HOME/bin/idd-codex-modules/pr-reviewer.sh（install.sh が local-watcher/bin/idd-codex-modules/ から配置する）
#
# 依存:
#   - 本モジュールは idd-codex-issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー pr_log / pr_warn / pr_error は core_utils.sh に定義済み（#261 task 1 で追加）。
#   - グローバル変数（$REPO / $BASE_BRANCH / $PR_REVIEWER_ENABLED /
#     $PR_REVIEWER_TOOL / $PR_REVIEWER_CODEX_ENABLED / $PR_REVIEWER_ANTIGRAVITY_ENABLED /
#     $PR_REVIEWER_MAX_PRS / $PR_REVIEWER_EXEC_TIMEOUT 等）は本体冒頭の Config ブロックで
#     定義される予定（task 7 で配線）。bash の遅延束縛により呼び出し時に解決される。
#   - top-level orchestration 呼び出し配線（process_pr_reviewer || pr_warn ...）は
#     本体 entry point に残置する（本モジュールは関数定義のみ）。
#   - 外部 CLI: gh / git / jq / codex / agy（健全性チェック・レビュー実行で使用）。
#
# セットアップ参照先:
#   - 設計: docs/specs/261-feat-pr-codex-antigravity/design.md
#   - README「PR Reviewer Processor (#261)」節（task 8 で追加予定）

# ─────────────────────────────────────────────────────────────────────────────
# pr_resolve_tool: PR_REVIEWER_TOOL / *_CODEX_ENABLED / *_ANTIGRAVITY_ENABLED から
#   使用ツールを解決する（design.md Decision 1 の解決順序）
#
#   入力: 環境変数のみ
#     - PR_REVIEWER_TOOL: canonical な単一値（"codex" / "antigravity" / それ以外）
#     - PR_REVIEWER_CODEX_ENABLED: alias（"=true" 厳密一致のみ有効）
#     - PR_REVIEWER_ANTIGRAVITY_ENABLED: alias（"=true" 厳密一致のみ有効）
#   出力: stdout に "codex" / "antigravity" / "none" / "conflict" のいずれか 1 語
#   戻り値: 0 = ok（codex / antigravity）
#           1 = conflict（両方有効化、排他エラー）
#           2 = none（どちらも有効化されていない）
#   AC: 2.1, 2.2, 2.3, 2.5, NFR 3.1
#
#   解決順序（design.md Decision 1）:
#     1. PR_REVIEWER_TOOL が "codex" / "antigravity" に厳密一致 → 当該値を採用
#     2. PR_REVIEWER_TOOL が 上記 2 値以外で非空 → WARN + alias fallback
#     3. alias を独立評価:
#        - codex_on  = (PR_REVIEWER_CODEX_ENABLED == "true")
#        - agy_on    = (PR_REVIEWER_ANTIGRAVITY_ENABLED == "true")
#     4. 片方のみ true → 採用、両方 true → conflict、両方 false → none
# ─────────────────────────────────────────────────────────────────────────────
pr_resolve_tool() {
  local tool_canonical="${PR_REVIEWER_TOOL:-}"
  local codex_on="${PR_REVIEWER_CODEX_ENABLED:-false}"
  local agy_on="${PR_REVIEWER_ANTIGRAVITY_ENABLED:-false}"

  # Step 1: PR_REVIEWER_TOOL が canonical 2 値に厳密一致 → 即採用
  case "$tool_canonical" in
    codex)
      echo "codex"
      return 0
      ;;
    antigravity)
      echo "antigravity"
      return 0
      ;;
    "")
      # 未設定 → alias 評価へフォールスルー
      ;;
    *)
      # canonical 2 値以外の非空値 → WARN + alias 評価へフォールバック（Decision 1 step 6）
      # pr_warn は stderr に出すため stdout の "tool 名" 契約を汚さない
      pr_warn "PR_REVIEWER_TOOL='${tool_canonical}' は canonical 値 (codex|antigravity) ではありません。PR_REVIEWER_CODEX_ENABLED / PR_REVIEWER_ANTIGRAVITY_ENABLED で alias 解決します"
      ;;
  esac

  # Step 2: alias 独立評価（厳密 =true のみ有効。それ以外（"True" / "1" / typo）は false 扱い）
  if [ "$codex_on" = "true" ] && [ "$agy_on" = "true" ]; then
    # AC 2.3: 排他エラー
    pr_error "PR_REVIEWER_CODEX_ENABLED と PR_REVIEWER_ANTIGRAVITY_ENABLED の両方が有効化されています（排他エラー）"
    echo "conflict"
    return 1
  fi

  if [ "$codex_on" = "true" ]; then
    # AC 2.1
    echo "codex"
    return 0
  fi

  if [ "$agy_on" = "true" ]; then
    # AC 2.2
    echo "antigravity"
    return 0
  fi

  # AC 2.5: どちらも無効
  # stdout は "none" の単一 token のみを返す契約のため、観測ログは >&2 へ。
  # 呼び出し元 process_pr_reviewer は command substitution で stdout を捕捉する。
  pr_log "tool 未指定（PR_REVIEWER_TOOL 未設定 かつ PR_REVIEWER_{CODEX,ANTIGRAVITY}_ENABLED いずれも true ではない）。サイクルを skip します" >&2
  echo "none"
  return 2
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_check_tool_installed: 指定ツールの実行ファイルが PATH 上に存在するか確認
#
#   入力: $1 = "codex" | "antigravity"
#         （Decision 2 / 3: antigravity の実バイナリ名は `agy`）
#   出力: なし（観測ログは pr_log のみ）
#   戻り値: 0 = ok (installed) / 1 = not-installed
#   AC: 3.1
#
#   - `command -v "$bin"` で PATH 上の実行ファイル存在を確認する pure check。
#     stdout は捨てて戻り値のみを契約とする（呼び出し元は rc で分岐）。
#   - "codex" / "antigravity" 以外の入力は内部矛盾（pr_resolve_tool が canonical
#     2 値以外を返すことは無い設計）。安全側に倒し、観測ログを残して
#     not-installed (rc=1) 相当を返す。
# ─────────────────────────────────────────────────────────────────────────────
pr_check_tool_installed() {
  local tool="${1:-}"
  local bin=""

  case "$tool" in
    codex)
      bin="codex"
      ;;
    antigravity)
      bin="agy"
      ;;
    *)
      pr_error "pr_check_tool_installed: 未知の tool 名 '${tool}'（'codex' / 'antigravity' のいずれか）。not-installed として扱います"
      return 1
      ;;
  esac

  if command -v "$bin" >/dev/null 2>&1; then
    pr_log "tool installed check: tool=${tool} bin=${bin} result=ok"
    return 0
  fi

  pr_log "tool installed check: tool=${tool} bin=${bin} result=not-installed"
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_check_tool_authenticated: 指定ツールが認証済みか確認
#
#   入力: $1 = "codex" | "antigravity"
#   出力: なし（観測ログは pr_log のみ。auth コマンドの stdout/stderr は破棄）
#   戻り値: 0 = ok (authenticated)
#           1 = not-authenticated
#           2 = check 機構が無効（env 未設定 / 空文字 = 既定 skip）
#   AC: 3.2
#
#   - `PR_REVIEWER_<TOOL>_AUTH_CMD` env を解決し、空文字なら skip (rc=2)。
#     既定値は task 7 で idd-codex-issue-watcher.sh 本体側に焼き込まれる:
#       - codex: `codex login status`
#       - agy:   `""`（既定 skip。Decision 3）
#     本 task 範囲では env 未設定 = 空文字扱い = skip で OK。
#   - 非空なら `bash -c "$auth_cmd"` を `>/dev/null 2>&1` で stdout/stderr を完全
#     破棄して実行（Security Considerations: auth token / 認証 URL 等の流出防止）。
#   - 終了コード 0 → ok (rc=0)、非ゼロ → not-authenticated (rc=1)。
#   - `eval` は使わない（Decision 9）。`bash -c` で subshell に閉じ込める。
# ─────────────────────────────────────────────────────────────────────────────
pr_check_tool_authenticated() {
  local tool="${1:-}"
  local auth_cmd=""

  case "$tool" in
    codex)
      auth_cmd="${PR_REVIEWER_CODEX_AUTH_CMD:-}"
      ;;
    antigravity)
      auth_cmd="${PR_REVIEWER_ANTIGRAVITY_AUTH_CMD:-}"
      ;;
    *)
      pr_error "pr_check_tool_authenticated: 未知の tool 名 '${tool}'（'codex' / 'antigravity' のいずれか）。skip として扱います"
      return 2
      ;;
  esac

  if [ -z "$auth_cmd" ]; then
    # AC 3.2 既定: 空文字 = check 機構が無効（skip）
    pr_log "tool authenticated check: tool=${tool} result=skipped (auth cmd unset)"
    return 2
  fi

  # auth コマンド実行: stdout / stderr を完全破棄（Security Considerations）
  if bash -c "$auth_cmd" >/dev/null 2>&1; then
    pr_log "tool authenticated check: tool=${tool} result=ok"
    return 0
  fi

  pr_log "tool authenticated check: tool=${tool} result=not-authenticated"
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_build_marker: hidden HTML comment 形式の重複防止 marker を構築（task 4.1）
#   入力: $1 = sha (headRefOid), $2 = kind, $3 = tool (省略時 none)
#   出力: stdout に marker 文字列 1 個（末尾改行なし）
#   AC: 6.1, 6.4
#
#   形式: <!-- idd-codex:pr-reviewer sha=<sha> kind=<kind> tool=<tool> -->
#   design.md State / Marker Contract と byte 一致。GitHub 上では非表示。
#   design.md の interface 表は ($1=sha, $2=kind) の 2 引数表記だが、marker 契約は
#   tool= 属性を含むため第 3 引数 tool を追加している（impl-notes.md に記録）。
# ─────────────────────────────────────────────────────────────────────────────
pr_build_marker() {
  local sha="${1:-}"
  local kind="${2:-}"
  local tool="${3:-none}"
  printf '<!-- idd-codex:pr-reviewer sha=%s kind=%s tool=%s -->' "$sha" "$kind" "$tool"
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_already_processed: 同一 (sha, kind) marker が既存コメントに在るか判定（task 4.1）
#   入力: $1 = pr_number, $2 = sha, $3 = kind
#   出力: なし
#   戻り値: 0 = 既存（skip すべき）/ 1 = 未存在（処理を続行してよい）
#   AC: 3.3, 6.2, 6.3, NFR 4.1
#
#   - `gh api /repos/$REPO/issues/<n>/comments` で全コメントを取得し、jq で
#     marker（sha と kind の双方一致）の存在を test する（tool 属性は照合に使わない
#     = Decision 6 の (sha, kind) 単位重複判定）。
#   - sha は hex、kind は固定語彙のため正規表現メタ文字を含まず test() に安全。
#   - gh API 失敗時は **安全側（重複投稿回避）** に倒し「既存扱い (rc=0)」で skip。
#     SHA が不変なら次サイクルで再評価されるため self-heal する（NFR 3.1 で WARN 記録）。
# ─────────────────────────────────────────────────────────────────────────────
pr_already_processed() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local kind="${3:-}"

  local comments_json
  if ! comments_json=$(timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh api "/repos/${REPO}/issues/${pr_number}/comments" 2>/dev/null); then
    pr_warn "PR #${pr_number}: コメント取得に失敗（marker 重複判定をスキップ＝安全側で既存扱い）"
    return 0
  fi

  if echo "$comments_json" | jq -e \
      --arg sha "$sha" \
      --arg kind "$kind" \
      'any(.[]; (.body // "") | test("idd-codex:pr-reviewer sha=" + $sha + "[^>]*kind=" + $kind))' \
      >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_fetch_candidate_prs: 候補 PR を JSON 配列で返す（task 4.2）
#   出力: stdout に jq 配列形式の JSON 1 行（候補なし / 失敗時は "[]"）
#   戻り値: 0 固定（失敗は degraded path = "[]" + WARN に倒す）
#   AC: 7.1, 7.2, 7.3
#
#   - server-side: `--state open --search "-draft:true"`（open + draft 除外、AC 7.1/7.2）
#   - client-side fail-safe: `select(.isDraft == false)`（draft 二重防御、AC 7.2）+
#     head pattern 一致（PR_REVIEWER_HEAD_PATTERN、既定 `^codex/`）+
#     fork 除外（headRepositoryOwner.login == owner）。既存 pi_fetch_candidate_prs 踏襲。
#   - PR を伴わない Issue は gh pr list の対象外のため自然に除外される（AC 7.3）。
#   - 上限件数 (PR_REVIEWER_MAX_PRS) の truncate は呼び出し元 process_pr_reviewer で
#     total / target / overflow をログ出力しながら行う（NFR 3.1 観測性、pi 踏襲）。
# ─────────────────────────────────────────────────────────────────────────────
pr_fetch_candidate_prs() {
  local repo_owner="${REPO%%/*}"
  local prs_json
  if ! prs_json=$(timeout "$PR_REVIEWER_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "-draft:true" \
      --json number,headRefName,headRefOid,baseRefName,isDraft,url,headRepositoryOwner \
      --limit 50 2>/dev/null); then
    pr_warn "候補 PR の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    echo "[]"
    return 0
  fi

  echo "$prs_json" | jq \
    --arg pattern "$PR_REVIEWER_HEAD_PATTERN" \
    --arg owner "$repo_owner" \
    '[.[]
      | select(.isDraft == false)
      | select((.headRepositoryOwner.login // "") == $owner)
      | select(.headRefName | test($pattern))
    ]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_default_prompt: 内蔵 default レビュープロンプトを stdout に出力（task 5.1）
#   入力: なし
#   出力: stdout に prompt 本文（{BASE} / {HEAD} / {PR} は未置換のまま）
#
#   design.md「Default Review Prompt」節の本文と **byte 一致**させること。
#   quoted heredoc（'EOF'）なので {BASE} 等・`$(...)` は展開されずリテラル保持される。
# ─────────────────────────────────────────────────────────────────────────────
pr_default_prompt() {
  cat <<'PR_REVIEWER_DEFAULT_PROMPT_EOF'
あなたは熟練のソフトウェアレビュアーです。base ブランチ {BASE} と head ブランチ {HEAD}
の差分（git diff {BASE}...{HEAD}）を対象に PR #{PR} をレビューしてください。

# 網羅性要求（最優先）
- 差分全体を 1 パスで網羅的に走査し、検出した指摘は **列挙漏れなく一度に** 出力すること。
- 同一観点で複数箇所に同種の問題がある場合は **drip-feed（小出し）せず**、最初のパスで
  該当箇所をすべて列挙すること。「他にも同様の箇所がある」等の曖昧な要約で済ませない。
- 1 パスで全件出すことを優先し、レビュー往復回数を最小化する（収束遅延を避ける）。
- 重要度の濃淡付け（high / medium / low）は付与するが、low を理由に列挙を省略しないこと。

# レビュー観点（優先度順）
1. 正確性のバグ: ロジック誤り・境界条件・null/空入力・競合・例外未処理
2. 受入基準の未カバー: docs/specs/ に requirements.md があれば AC と差分を突き合わせる
3. テスト不足: 変更された分岐に対応するテストの欠落
4. セキュリティ退行: 入力検証・認証・機密情報露出・コマンドインジェクション
5. 後方互換性の破壊: 既存 env var / 出力契約の変更

# spec 文書間整合チェック（条件付き適用）
差分に `docs/specs/<番号>-<slug>/` 配下のファイル変更（`requirements.md` / `design.md` /
`tasks.md` のいずれか）が含まれる **場合に限り**、以下の整合性を 1 パス目で突き合わせて
検査すること。差分に `docs/specs/` 配下のファイルが含まれない PR では本節をスキップし、
上記「レビュー観点」の実施を阻害しないこと。

- requirements ⇄ design: `requirements.md` の各 AC（numeric ID）が `design.md` で
  カバーされているか（Components / Interfaces / Traceability 等で対応関係が追えるか）。
- design ⇄ tasks: `design.md` の Components / Interfaces が `tasks.md` のタスクで
  実装手順化されているか（実装漏れ・タスク分割の不足が無いか）。
- tasks ⇄ requirements: `tasks.md` の各タスクの `_Requirements:_` アノテーションが
  `requirements.md` に実在する AC ID を参照しているか（存在しない ID への参照や
  欠落が無いか）。

不整合は通常のレビュー指摘と同じ `[high|medium|low] <file>:<line> — <内容と根拠>` 形式で
「指摘事項」セクションに **列挙漏れなく** 一括で出力すること。

# 制約
- ファイルを編集しないこと。所見の報告のみ（read-only）。
- 差分に実在する file:line を根拠として必ず引用する。推測で書かない。
- スタイル / lint レベルの指摘は対象外。

# 出力（日本語・Markdown、この構造を厳守）
## 概要
<2〜3 文の総評>
## 指摘事項
- [high|medium|low] <file>:<line> — <内容と根拠>
（指摘が無ければ「指摘なし」）
## 結論
（本文の最終行に、次のいずれか 1 行だけを単独で出力すること）
VERDICT: codex-needs-iteration
VERDICT: approve
PR_REVIEWER_DEFAULT_PROMPT_EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_build_prompt_file: レビュー prompt を解決し一時ファイルに書き出す（task 5.1）
#   入力: $1 = pr_number, $2 = base_ref, $3 = head_ref
#   出力: stdout に一時ファイルパス（呼び出し元が trap で削除）
#   戻り値: 0 = ok / 1 = secure tempfile 作成失敗
#   AC: 4.3
#
#   - 解決順序: PR_REVIEWER_PROMPT が非空 → それ。空なら内蔵 default（Decision 9 で
#     PR_REVIEWER_<TOOL>_PROMPT は YAGNI として不採用 / design 確認事項 4）。
#   - 解決済み prompt 中の {BASE} / {HEAD} / {PR} を bash パラメータ置換でリテラル置換。
#   - 一時ファイル経由で argv に渡すことで prompt 本文を cmd 文字列に注入しない
#     （Security Considerations / Decision 9）。
#   - stdout にファイルパスを返す契約のため、本関数内では pr_log を使わず
#     pr_warn（stderr）のみ使用する（stdout 汚染防止）。
# ─────────────────────────────────────────────────────────────────────────────
pr_build_prompt_file() {
  local pr_number="$1"
  local base_ref="$2"
  local head_ref="$3"

  local prompt="${PR_REVIEWER_PROMPT:-}"
  if [ -z "$prompt" ]; then
    prompt="$(pr_default_prompt)"
  fi

  prompt="${prompt//\{BASE\}/$base_ref}"
  prompt="${prompt//\{HEAD\}/$head_ref}"
  prompt="${prompt//\{PR\}/$pr_number}"

  local tmpfile
  if ! tmpfile=$(idd_secure_mktemp "pr-reviewer-prompt-${pr_number}"); then
    pr_warn "PR #${pr_number}: prompt 一時ファイルの作成に失敗"
    return 1
  fi
  printf '%s\n' "$prompt" > "$tmpfile"
  printf '%s' "$tmpfile"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_placeholder_reject_reason: placeholder 値の拒否理由を返す（Issue #52 Req 6）
#   入力: $1 = field(base|head|pr), $2 = value
#   出力: ok または reason category
#   戻り値: 0 固定
# ─────────────────────────────────────────────────────────────────────────────
pr_placeholder_reject_reason() {
  local field="$1"
  local value="$2"

  if [ -z "$value" ] || [ "$value" = "null" ]; then
    printf 'empty'
    return 0
  fi
  case "$value" in
    -*) printf 'leading-option'; return 0 ;;
    *$'\n'* | *$'\r'*) printf 'newline'; return 0 ;;
  esac

  if [ "$field" = "pr" ] && ! [[ "$value" =~ ^[0-9]+$ ]]; then
    printf 'non-numeric-pr'
    return 0
  fi

  local command_substitution_marker="\$("
  local backtick_marker="\`"
  if [[ "$value" == *"$command_substitution_marker"* || "$value" == *"$backtick_marker"* ]]; then
    printf 'command-substitution'
    return 0
  fi

  case "$value" in
    *'>'* | *'<'*) printf 'redirection'; return 0 ;;
    *'*'* | *'?'* | *'['*) printf 'glob'; return 0 ;;
    *';'* | *'|'* | *'&'*) printf 'shell-separator'; return 0 ;;
  esac

  if ! [[ "$value" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    printf 'unsafe-character'
    return 0
  fi

  printf 'ok'
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_validate_placeholder_value: PR-derived placeholder 値を data として検証する
#   入力: $1 = field(base|head|pr), $2 = value, $3 = pr_number_for_log(optional)
#   戻り値: 0 = ok / 1 = rejected
#
#   rejected value は public comment に出さず、local warning も raw value ではなく
#   PR number / field / reason category のみを出す。
# ─────────────────────────────────────────────────────────────────────────────
pr_validate_placeholder_value() {
  local field="$1"
  local value="$2"
  local pr_context="${3:-unknown}"
  local reason
  reason=$(pr_placeholder_reject_reason "$field" "$value")
  if [ "$reason" = "ok" ]; then
    return 0
  fi

  if ! [[ "$pr_context" =~ ^[0-9]+$ ]]; then
    pr_context="unknown"
  fi
  pr_warn "PR #${pr_context}: placeholder rejected field=${field} reason=${reason}; skip"
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_substitute_placeholders: 実行コマンドのプレースホルダ置換（task 5.1）
#   入力: $1 = cmd_template, $2 = base_ref, $3 = head_ref, $4 = pr_number,
#         $5 = prompt_file_path
#   出力: stdout に置換済みコマンド文字列
#   戻り値: 0 = ok / 1 = unsafe placeholder value（呼び出し元は当該 PR を skip）
#   AC: 4.3, Issue #52 Req 6.1, 6.2, 6.5
#
#   - 置換対象: {BASE} / {HEAD} / {PR} / {PROMPT_FILE}
#   - 注入値（GitHub 由来の branch 名 / PR 番号）は field ごとに allowlist 検査し、
#     newline / redirection / glob / command substitution / separator / leading option /
#     non-numeric PR number を WARN + skip で拒否する。
#   - prompt_file_path は secure tempfile helper 由来の自前パスのため検査対象外。cmd_template は
#     運用者入力（信頼境界内）かつ正当な `$(cat '...')` を含むため検査しない。
#   - stdout に結果を返す契約のため pr_log は使わず pr_warn（stderr）のみ使用。
# ─────────────────────────────────────────────────────────────────────────────
pr_substitute_placeholders() {
  local cmd_template="$1"
  local base_ref="$2"
  local head_ref="$3"
  local pr_number="$4"
  local prompt_file="$5"

  local pr_context="$pr_number"
  pr_validate_placeholder_value "base" "$base_ref" "$pr_context" || return 1
  pr_validate_placeholder_value "head" "$head_ref" "$pr_context" || return 1
  pr_validate_placeholder_value "pr" "$pr_number" "$pr_context" || return 1

  local out="$cmd_template"
  out="${out//\{BASE\}/$base_ref}"
  out="${out//\{HEAD\}/$head_ref}"
  out="${out//\{PR\}/$pr_number}"
  out="${out//\{PROMPT_FILE\}/$prompt_file}"
  printf '%s' "$out"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_write_exec_failure_diagnostic: non-quota exec failure の local artifact を残す
#   入力: $1=pr_number, $2=sha, $3=tool, $4=exit_rc, $5=stdout_file, $6=stderr_file
#   出力: stdout に diagnostic artifact path（作成不能なら空）
#   戻り値: 0 固定
# ─────────────────────────────────────────────────────────────────────────────
pr_write_exec_failure_diagnostic() {
  local pr_number="$1"
  local sha="$2"
  local tool="$3"
  local exec_rc="$4"
  local out_file="$5"
  local err_file="$6"

  local diagnostic_file
  if ! diagnostic_file=$(idd_secure_mktemp "pr-reviewer-diagnostic-${pr_number}"); then
    pr_warn "PR #${pr_number}: exec-failed diagnostic artifact の作成に失敗"
    printf '\n'
    return 0
  fi

  {
    printf 'PR Reviewer execution failure diagnostic\n'
    printf 'pr_number=%s\n' "$pr_number"
    printf 'sha=%s\n' "$sha"
    printf 'tool=%s\n' "$tool"
    printf 'exit=%s\n' "$exec_rc"
    printf '\n[stdout]\n'
    cat "$out_file" 2>/dev/null || true
    printf '\n[stderr]\n'
    cat "$err_file" 2>/dev/null || true
  } > "$diagnostic_file"

  pr_error "PR #${pr_number}: exec-failed diagnostic retained path=${diagnostic_file} reason=non-quota-exec-failure"
  printf '%s\n' "$diagnostic_file"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_execute_review_command: head checkout + レビュー実行 + read-only 検査（task 5.2）
#   入力: $1 = head_ref, $2 = resolved_cmd, $3 = tool,
#         $4 = out_file, $5 = err_file, $6 = result_file
#   出力: out_file へ stdout、err_file へ stderr、result_file へ実行結果トークン
#   戻り値: 0 固定（結果判定は result_file 経由）
#   AC: 4.1, 4.2, 4.5（read-only invariant: Decision 8 / eval 不使用: Decision 9）
#
#   result_file に書き出すトークン（呼び出し元が parse）:
#     - `fetch-fail`         : git fetch 失敗（一時的 / コメント投稿しない）
#     - `checkout-fail`      : git checkout 失敗（同上）
#     - `ran:<rc>:clean`     : 実行完了、ワークツリー変更なし（rc=コマンド終了コード）
#     - `ran:<rc>:modified`  : 実行完了したがワークツリーを変更（read-only 違反）
#
#   - design.md interface 表は ($1=command_string, $2=tool) の 2 引数 + stdout 返却
#     表記だが、(a) head checkout を本関数内で行う（AC 4.1）/ (b) stdout・stderr・
#     実行結果を分離して呼び出し元へ渡す必要がある（exec-failed コメントへ stderr
#     1KB 抜粋を含めるため / AC 4.5）ため、tempfile 渡しに拡張している
#     （impl-notes.md に記録）。
#   - サブシェル + EXIT trap で必ず BASE_BRANCH に戻す（副作用を残さない invariant）。
#   - `eval` は使わず `bash -c "$resolved_cmd"` で subshell に閉じ込める（Decision 9）。
#   - 実行直後に `git status --porcelain` でワークツリー変更を検査し、検出時は
#     `git checkout -- .` で tracked 変更を破棄し `modified` を報告（Decision 8）。
# ─────────────────────────────────────────────────────────────────────────────
pr_execute_review_command() {
  local head_ref="$1"
  local resolved_cmd="$2"
  local tool="$3"
  local out_file="$4"
  local err_file="$5"
  local result_file="$6"

  : > "$out_file"
  : > "$err_file"
  : > "$result_file"

  (
    set +e
    # shellcheck disable=SC2064
    trap "git checkout '${BASE_BRANCH}' >/dev/null 2>&1" EXIT

    # head branch を fresh に checkout（origin 最新へ追従、AC 4.1）
    if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" git fetch origin "$head_ref" >/dev/null 2>&1; then
      pr_warn "head '${head_ref}' の git fetch に失敗"
      printf 'fetch-fail\n' > "$result_file"
      exit 0
    fi
    if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" git checkout -B "$head_ref" "origin/${head_ref}" >/dev/null 2>&1; then
      pr_warn "head '${head_ref}' の checkout に失敗"
      printf 'checkout-fail\n' > "$result_file"
      exit 0
    fi

    # レビュー実行（AC 4.2、eval 不使用 / Decision 9。stdout / stderr を分離保存）
    local exec_rc=0
    timeout "$PR_REVIEWER_EXEC_TIMEOUT" bash -c "$resolved_cmd" >"$out_file" 2>"$err_file" || exec_rc=$?

    # read-only invariant 検査（Decision 8）。untracked は `git clean` で消すと
    # `.antigravitycli/` 等の運用ツール生成物を巻き込むため tracked 変更のみ破棄する。
    local wsmod="clean"
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      git checkout -- . >/dev/null 2>&1 || true
      wsmod="modified"
    fi
    printf 'ran:%s:%s\n' "$exec_rc" "$wsmod" > "$result_file"
    exit 0
  )
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_post_review_comment: レビュー結果コメントを投稿（task 5.3）
#   入力: $1 = pr_number, $2 = sha, $3 = review_text, $4 = tool (省略時 none)
#   戻り値: 0 = ok / 1 = 投稿失敗
#   AC: 4.4, 6.1, 6.4
#
#   - review_text 末尾に hidden marker（kind=review）を付与し gh pr comment で投稿。
#   - design.md interface 表は ($1,$2,$3) の 3 引数表記だが marker の tool= 属性
#     のため第 4 引数 tool を追加（pr_build_marker と同様 / impl-notes.md に記録）。
# ─────────────────────────────────────────────────────────────────────────────
pr_post_review_comment() {
  local pr_number="$1"
  local sha="$2"
  local review_text="$3"
  local tool="${4:-none}"

  local marker body
  marker=$(pr_build_marker "$sha" "review" "$tool")
  body=$(printf '%s\n\n%s' "$review_text" "$marker")

  if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    pr_warn "PR #${pr_number}: レビュー結果コメントの投稿に失敗"
    return 1
  fi
  pr_log "PR #${pr_number}: レビュー結果コメント投稿 kind=review tool=${tool} sha=${sha}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_post_error_comment: エラーコメントを投稿（task 5.3）
#   入力: $1 = pr_number, $2 = sha, $3 = kind, $4 = detail, $5 = tool (省略時 none)
#   戻り値: 0 = ok（重複 skip 含む）/ 1 = 投稿失敗
#   AC: 2.4, 3.1, 3.2, 3.3, 3.4, 4.5, 6.1, 6.4
#
#   - 本文冒頭に運用者が人間判断で識別できる見出し `## 自動レビューエラー`（AC 3.4）。
#   - 同一 (sha, kind) marker が既存なら再投稿しない（AC 3.3 / 6.2、冪等 NFR 4.1）。
#   - design.md interface 表は ($1〜$4) の 4 引数表記だが marker の tool= 属性のため
#     第 5 引数 tool を追加（impl-notes.md に記録）。
# ─────────────────────────────────────────────────────────────────────────────
pr_post_error_comment() {
  local pr_number="$1"
  local sha="$2"
  local kind="$3"
  local detail="$4"
  local tool="${5:-none}"

  # AC 3.3 / 6.2: 同一 (sha, kind) が既存なら再投稿しない
  if pr_already_processed "$pr_number" "$sha" "$kind"; then
    pr_log "PR #${pr_number}: kind=${kind} sha=${sha} のエラーコメントは既存のため再投稿しません（重複防止）"
    return 0
  fi

  local marker body
  marker=$(pr_build_marker "$sha" "$kind" "$tool")
  body=$(printf '## 自動レビューエラー\n\n%s\n\n%s' "$detail" "$marker")

  if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    pr_warn "PR #${pr_number}: エラーコメント (kind=${kind}) の投稿に失敗"
    return 1
  fi
  pr_log "PR #${pr_number}: エラーコメント投稿 kind=${kind} tool=${tool} sha=${sha}"
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════
# Issue #403 移植: 同一 sha の連続 exec 失敗 streak を per-PR JSON に永続化し、上限到達で
#   外部レビューツール呼び出しを抑止する（codex exec-failed の無限リトライが rate-limit を
#   持続させる事故を防ぐ）。state は repo-slug 分離（failed-recovery と同方針）。新 sha では
#   streak が reset されるため push でレビュー自動再開。quota（reset epoch 解析可）は既存
#   pr_handle_quota_wait 経路で別処理されるため streak には数えない（呼び出し側で increment を
#   quota 分岐より後の non-quota 失敗経路のみに置く）。
# ═════════════════════════════════════════════════════════════════════════════

# pr_exec_fail_state_path: per-PR の exec-fail streak state JSON 絶対パス（純粋関数）
pr_exec_fail_state_path() {
  printf '%s/pr-%s.json\n' "$PR_REVIEWER_EXEC_FAIL_STATE_DIR" "$1"
}

# pr_read_exec_fail_streak: 現 sha に対応する連続失敗数を返す（sha 不一致 / 不在 / 破損は 0）
#   入力: $1=pr_number $2=sha / 出力: stdout に整数（fail-open）
pr_read_exec_fail_streak() {
  local pr_number="$1" sha="$2" path val
  path="$(pr_exec_fail_state_path "$pr_number")"
  if [ ! -f "$path" ]; then printf '0'; return 0; fi
  val=$(jq -r --arg s "$sha" 'if (.sha // "") == $s then (.streak // 0) else 0 end' "$path" 2>/dev/null)
  [[ "$val" =~ ^[0-9]+$ ]] || val=0
  printf '%s' "$val"
  return 0
}

# pr_record_exec_fail: 現 sha の連続失敗数を +1（sha 変化時は 1 にリセット）して atomic 永続化
#   入力: $1=pr_number $2=sha / 出力: stdout に新 streak / 戻り値: 0（永続化失敗でも継続）
pr_record_exec_fail() {
  local pr_number="$1" sha="$2" path prev new tmp
  path="$(pr_exec_fail_state_path "$pr_number")"
  prev="$(pr_read_exec_fail_streak "$pr_number" "$sha")"
  new=$((prev + 1))
  if ! mkdir -p "$PR_REVIEWER_EXEC_FAIL_STATE_DIR" 2>/dev/null; then
    pr_warn "PR #${pr_number}: exec-fail state dir 作成に失敗（streak 抑止が効かない可能性）"
    printf '%s' "$new"; return 0
  fi
  tmp="$(idd_secure_mktemp "pr-exec-fail-${pr_number}" 2>/dev/null || true)"
  if [ -n "$tmp" ] \
      && jq -nc --arg s "$sha" --argjson n "$new" '{sha:$s, streak:$n}' > "$tmp" 2>/dev/null \
      && mv -f "$tmp" "$path" 2>/dev/null; then
    :
  else
    [ -n "$tmp" ] && rm -f "$tmp" 2>/dev/null || true
    pr_warn "PR #${pr_number}: exec-fail streak の永続化に失敗（次サイクルで再評価）"
  fi
  printf '%s' "$new"
  return 0
}

# pr_reset_exec_fail: レビュー成功時に streak state を消去（best-effort / 戻り値 0）
pr_reset_exec_fail() {
  local path
  path="$(pr_exec_fail_state_path "$1")"
  if [ -f "$path" ]; then rm -f "$path" 2>/dev/null || true; fi
  return 0
}

# pr_exec_fail_limit_reached: 現 sha の連続失敗が PR_REVIEWER_EXEC_FAIL_LIMIT に達したか
#   入力: $1=pr_number $2=sha / 戻り値: 0 = 到達（抑止）/ 1 = 未達
pr_exec_fail_limit_reached() {
  local pr_number="$1" sha="$2" streak
  streak="$(pr_read_exec_fail_streak "$pr_number" "$sha")"
  [ "$streak" -ge "$PR_REVIEWER_EXEC_FAIL_LIMIT" ] 2>/dev/null || return 1
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_detect_usage_limit_reset_epoch: review command の stdout/stderr から usage-limit reset を抽出
#   入力: 任意個の log file path
#   出力: reset epoch（抽出不能なら空）
#   戻り値: 0 固定
# ─────────────────────────────────────────────────────────────────────────────
pr_detect_usage_limit_reset_epoch() {
  local file detect_line rest epoch message raw
  for file in "$@"; do
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
      continue
    fi
    detect_line=$(qa_detect_rate_limit < "$file" \
      | awk -F '\t' '$1 == "usage_limit_fatal" { last = $0 } END { print last }')
    if [ -n "$detect_line" ]; then
      rest="${detect_line#*$'\t'}"
      epoch="${rest%%$'\t'*}"
      message="${rest#*$'\t'}"
      if ! [[ "$epoch" =~ ^[0-9]+$ ]]; then
        epoch=$(qa_extract_usage_limit_reset_epoch "$message")
      fi
      if [[ "$epoch" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$epoch"
        return 0
      fi
    fi
  done

  for file in "$@"; do
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
      continue
    fi
    raw=$(grep -iE 'usage limit|purchase more credits|try again at' "$file" 2>/dev/null | tail -1 || true)
    [ -n "$raw" ] || continue
    epoch=$(qa_extract_usage_limit_reset_epoch "$raw")
    if [[ "$epoch" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$epoch"
      return 0
    fi
  done
  printf '\n'
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_handle_quota_wait: PR Reviewer 由来の usage-limit fatal を quota wait へ退避
#   入力: $1=pr_number, $2=sha, $3=tool, $4=reset_epoch
#   戻り値: 0=退避処理済み / 1=ラベル遷移失敗
# ─────────────────────────────────────────────────────────────────────────────
pr_handle_quota_wait() {
  local pr_number="$1"
  local sha="$2"
  local tool="$3"
  local reset_epoch="$4"
  local reset_iso
  reset_iso=$(qa_format_iso8601 "$reset_epoch")

  qa_persist_reset_time "pr-reviewer-${pr_number}" "$reset_epoch" \
    || pr_warn "PR #${pr_number}: PR Reviewer quota reset_epoch=${reset_epoch} の永続化に失敗（ラベル退避は継続）"

  if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" gh pr edit "$pr_number" --repo "$REPO" \
      --add-label "$LABEL_NEEDS_QUOTA_WAIT" >/dev/null 2>&1; then
    pr_warn "PR #${pr_number}: PR Reviewer quota wait ラベル付与に失敗"
    return 1
  fi

  local body marker
  marker="<!-- idd-codex:pr-reviewer-quota-wait reset=${reset_epoch} sha=${sha} tool=${tool} -->"
  body="## ⏸️ PR Reviewer quota wait

PR Reviewer 実行中に Codex CLI が usage-limit fatal error を返したため、本 PR を
\`${LABEL_NEEDS_QUOTA_WAIT}\` に退避しました。

### 検知情報

- tool: \`${tool}\`
- sha: \`${sha}\`
- reset 予定時刻 (UNIX epoch): \`${reset_epoch}\`
- reset 予定時刻 (ISO 8601): \`${reset_iso}\`

reset 予定時刻 + grace 経過後、PR Reviewer Processor が \`${LABEL_NEEDS_QUOTA_WAIT}\` を外し、
次サイクルで同じ PR を再レビュー候補として扱います。

${marker}"

  if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    pr_warn "PR #${pr_number}: PR Reviewer quota wait コメント投稿に失敗"
  fi
  pr_log "PR #${pr_number}: usage-limit fatal detected reset_epoch=${reset_epoch} action=quota-wait"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_reviewer_quota_marker_reset: PR Reviewer quota wait marker から reset epoch を読む
#   入力: $1=pr_number
#   出力: reset epoch（marker 不在なら空）
#   戻り値: 0=marker あり / 1=marker なし or API failure
# ─────────────────────────────────────────────────────────────────────────────
pr_reviewer_quota_marker_reset() {
  local pr_number="$1"
  local comments_json
  if ! comments_json=$(timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh api "/repos/${REPO}/issues/${pr_number}/comments" 2>/dev/null); then
    return 1
  fi

  local reset_epoch
  reset_epoch=$(printf '%s\n' "$comments_json" | jq -r '
    [
      .[]?.body // ""
      | if test("idd-codex:pr-reviewer-quota-wait reset=[0-9]+") then
          (match("idd-codex:pr-reviewer-quota-wait reset=([0-9]+)") | {kind: "wait", reset: .captures[0].string})
        elif test("idd-codex:pr-reviewer-quota-resume reset=[0-9]+") then
          (match("idd-codex:pr-reviewer-quota-resume reset=([0-9]+)") | {kind: "resume", reset: .captures[0].string})
        else empty end
    ] | last // {} | select(.kind == "wait") | .reset // ""
  ' 2>/dev/null)
  if [[ "$reset_epoch" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$reset_epoch"
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_process_quota_resume: PR Reviewer 由来の quota wait を reset 後に再レビュー候補へ戻す
#   戻り値: 0 固定（API 失敗は WARN で後続継続）
# ─────────────────────────────────────────────────────────────────────────────
pr_process_quota_resume() {
  local prs_json
  if ! prs_json=$(timeout "$PR_REVIEWER_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "label:\"$LABEL_NEEDS_QUOTA_WAIT\"" \
      --json number,url \
      --limit 50 2>/dev/null); then
    pr_warn "PR Reviewer quota wait PR の取得に失敗（後続処理は継続）"
    return 0
  fi

  local now_epoch
  now_epoch=$(date -u +%s)
  local pr_number pr_url reset_epoch marker_epoch reset_epoch_state threshold
  while IFS=$'\t' read -r pr_number pr_url; do
    [ -n "$pr_number" ] || continue
    if ! marker_epoch=$(pr_reviewer_quota_marker_reset "$pr_number"); then
      continue
    fi
    reset_epoch="$marker_epoch"
    if reset_epoch_state=$(qa_load_reset_time "pr-reviewer-${pr_number}" 2>/dev/null); then
      if [[ "$reset_epoch_state" =~ ^[0-9]+$ ]]; then
        reset_epoch="$reset_epoch_state"
      fi
    fi
    threshold=$((reset_epoch + QUOTA_RESUME_GRACE_SEC))
    if [ "$now_epoch" -lt "$threshold" ]; then
      pr_log "PR #${pr_number}: reviewer quota-wait 継続 reset_epoch=${reset_epoch} wait_sec=$((threshold - now_epoch)) (${pr_url})"
      continue
    fi
    if timeout "$PR_REVIEWER_GIT_TIMEOUT" gh pr edit "$pr_number" --repo "$REPO" \
        --remove-label "$LABEL_NEEDS_QUOTA_WAIT" >/dev/null 2>&1; then
      local resume_body
      resume_body=":arrow_forward: PR Reviewer quota wait の reset 時刻を経過したため、\`${LABEL_NEEDS_QUOTA_WAIT}\` を外しました。次サイクルで再レビュー候補になります。

<!-- idd-codex:pr-reviewer-quota-resume reset=${reset_epoch} -->"
      if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" \
          gh pr comment "$pr_number" --repo "$REPO" --body "$resume_body" >/dev/null 2>&1; then
        pr_warn "PR #${pr_number}: PR Reviewer quota resume コメント投稿に失敗"
      fi
      pr_log "PR #${pr_number}: reviewer quota-wait resumed reset_epoch=${reset_epoch} elapsed_sec=$((now_epoch - reset_epoch))"
    else
      pr_warn "PR #${pr_number}: PR Reviewer quota wait resume ラベル遷移に失敗"
    fi
  done < <(printf '%s\n' "$prs_json" | jq -r '.[] | [.number, .url] | @tsv')

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_detect_iteration_keyword: レビュー結果から VERDICT token を検出（task 6）
#   入力: $1 = pr_number（ログ用）, $2 = review_text
#   出力: stdout にマッチ件数（整数。0 のとき "0"）
#   戻り値: 0 固定
#   AC: 5.1, 5.3, 5.4
#
#   - PR_REVIEWER_ITERATION_PATTERN（既定は line-anchored の
#     `^[[:space:]]*VERDICT:[[:space:]]*codex-needs-iteration[[:space:]]*$`、Decision 4）を
#     `grep -E -i -c` で照合し、マッチ行数を返す。
#   - 件数とパターンを観測ログに記録（AC 5.4 / NFR 3.1）。stdout に件数を返す契約の
#     ため、ログは pr_log を stderr へリダイレクトして出力する（stdout 汚染防止）。
#   - ラベル付与は呼び出し元（件数 > 0 のとき pr_add_iteration_label）が行う。
# ─────────────────────────────────────────────────────────────────────────────
pr_detect_iteration_keyword() {
  local pr_number="$1"
  local review_text="$2"
  local pattern="${PR_REVIEWER_ITERATION_PATTERN}"

  local count
  count=$(printf '%s' "$review_text" | grep -E -i -c "$pattern" 2>/dev/null || true)
  count="${count:-0}"

  pr_log "PR #${pr_number}: iteration keyword 検出 matches=${count} pattern='${pattern}'" >&2
  printf '%s' "$count"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_detect_approval_keyword: レビュー結果から approve VERDICT token を検出
#   入力: $1 = pr_number（ログ用）, $2 = review_text
#   出力: stdout にマッチ件数（整数。0 のとき "0"）
#   戻り値: 0 固定
#
#   - approve は line-anchored の `VERDICT: approve` 単独行のみを承認 signal とする。
#   - iteration と同じく grep -E -i で照合し、stdout は件数だけに保つ。
# ─────────────────────────────────────────────────────────────────────────────
pr_detect_approval_keyword() {
  local pr_number="$1"
  local review_text="$2"
  local pattern='^[[:space:]]*VERDICT:[[:space:]]*approve[[:space:]]*$'

  local count
  count=$(printf '%s' "$review_text" | grep -E -i -c "$pattern" 2>/dev/null || true)
  count="${count:-0}"

  pr_log "PR #${pr_number}: approve keyword 検出 matches=${count} pattern='${pattern}'" >&2
  printf '%s' "$count"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_resolve_review_verdict: review_text から approve / iteration / none / conflict を解決
#   入力: $1 = pr_number, $2 = review_text
#   出力: stdout に approve | iteration | none | conflict の 1 token
#   戻り値: 0 固定
#
#   - approve と iteration が混在した場合は conflict とし、呼び出し元で iteration
#     ラベル付与を優先する。approve signal は公開しない。
# ─────────────────────────────────────────────────────────────────────────────
pr_resolve_review_verdict() {
  local pr_number="$1"
  local review_text="$2"

  local approve_count iteration_count
  approve_count=$(pr_detect_approval_keyword "$pr_number" "$review_text")
  iteration_count=$(pr_detect_iteration_keyword "$pr_number" "$review_text")
  approve_count="${approve_count:-0}"
  iteration_count="${iteration_count:-0}"

  if [ "$approve_count" -gt 0 ] 2>/dev/null && [ "$iteration_count" -gt 0 ] 2>/dev/null; then
    pr_warn "PR #${pr_number}: approve と iteration の VERDICT が混在しています。approve signal は公開せず iteration 扱いにします"
    printf 'conflict'
    return 0
  fi
  if [ "$iteration_count" -gt 0 ] 2>/dev/null; then
    printf 'iteration'
    return 0
  fi
  if [ "$approve_count" -gt 0 ] 2>/dev/null; then
    printf 'approve'
    return 0
  fi
  printf 'none'
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_try_post_formal_approval: approve verdict を GitHub formal review として投稿
#   入力: $1 = pr_number, $2 = sha, $3 = review_text, $4 = tool
#   戻り値: 0 = formal review 投稿成功 / 1 = 投稿不可または失敗
#
#   - failure は非致命 WARN とし、既存の review comment + marker 投稿を継続させる。
#   - marker は PR comment 側に残すため、formal review body には review_text だけを渡す。
# ─────────────────────────────────────────────────────────────────────────────
pr_try_post_formal_approval() {
  local pr_number="$1"
  local sha="$2"
  local review_text="$3"
  local tool="${4:-none}"

  local body_file err_file
  if ! body_file=$(idd_secure_mktemp "pr-reviewer-approval-body-${pr_number}"); then
    pr_warn "PR #${pr_number}: formal approval body 一時ファイルの作成に失敗（marker approval fallback を継続）"
    return 1
  fi
  if ! err_file=$(idd_secure_mktemp "pr-reviewer-approval-stderr-${pr_number}"); then
    rm -f "$body_file"
    pr_warn "PR #${pr_number}: formal approval stderr 一時ファイルの作成に失敗（marker approval fallback を継続）"
    return 1
  fi

  printf '%s\n' "$review_text" > "$body_file"

  if timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh pr review "$pr_number" --repo "$REPO" --approve --body-file "$body_file" >/dev/null 2>"$err_file"; then
    rm -f "$body_file" "$err_file"
    pr_log "PR #${pr_number}: GitHub formal approval を投稿 tool=${tool} sha=${sha}"
    return 0
  fi

  local err_excerpt
  err_excerpt=$(head -c 512 "$err_file" 2>/dev/null || echo "")
  rm -f "$body_file" "$err_file"
  if [ -n "$err_excerpt" ]; then
    pr_warn "PR #${pr_number}: GitHub formal approval 投稿に失敗（${err_excerpt}）。marker approval fallback を継続 tool=${tool} sha=${sha}"
  else
    pr_warn "PR #${pr_number}: GitHub formal approval 投稿に失敗（権限/self-review/API 制約または timeout の可能性）。marker approval fallback を継続 tool=${tool} sha=${sha}"
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_add_iteration_label: codex-needs-iteration ラベルを付与（task 6）
#   入力: $1 = pr_number
#   戻り値: 0 = ok / 1 = 付与失敗
#   AC: 5.1, 5.2
#
#   - `gh pr edit --add-label` は既付与で冪等（再付与は no-op、AC 5.2）。
#   - 既存 PR Iteration Processor (#26) は本ラベルを起動条件とするため、付与により
#     次サイクルで iteration ループへ自動接続される。
# ─────────────────────────────────────────────────────────────────────────────
pr_add_iteration_label() {
  local pr_number="$1"
  if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" --add-label "$LABEL_NEEDS_ITERATION" >/dev/null 2>&1; then
    pr_warn "PR #${pr_number}: ${LABEL_NEEDS_ITERATION} ラベルの付与に失敗"
    return 1
  fi
  pr_log "PR #${pr_number}: ${LABEL_NEEDS_ITERATION} ラベルを付与（既付与なら冪等 no-op）"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_status_check_enabled: commit status publish の AND 二重 opt-in gate (#98)
#   戻り値: 0 = 両 gate ON / 1 = いずれか OFF（no-op）。副作用なし。
#   `PR_REVIEWER_STATUS_CHECK_ENABLED=true` かつ `FULL_AUTO_ENABLED=true`（#97 kill
#   switch）の双方が厳密一致のときのみ ON。Config で正規化済みだが遅延束縛のため
#   `:-false` fallback で安全側に倒す。
# ─────────────────────────────────────────────────────────────────────────────
pr_status_check_enabled() {
  if [ "${PR_REVIEWER_STATUS_CHECK_ENABLED:-false}" != "true" ]; then
    return 1
  fi
  if [ "${FULL_AUTO_ENABLED:-false}" != "true" ]; then
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_publish_commit_status: commit status を 1 件 publish する低レベルヘルパー (#98)
#   入力: $1=pr_number $2=sha $3=context $4=state $5=description $6=target_url(省略可)
#   戻り値: 0=成功 / 1=gate OFF(no-op) / 2=入力検証失敗 / 3=API 失敗
#   副作用: gate ON 時のみ `gh api -X POST /repos/{REPO}/statuses/{sha}`。
#   失敗は silent fail せず WARN + 続行（パイプライン本体を止めない）。
# ─────────────────────────────────────────────────────────────────────────────
pr_publish_commit_status() {
  local pr_number="$1" sha="$2" context="$3" state="$4" description="$5" target_url="${6:-}"

  # AND 二重 opt-in gate。OFF 時の suppression ログは cycle あたり 1 行に制限。
  # FULL_AUTO_ENABLED 起因の抑止は #97 のログに委ね、本 gate OFF のみ記録する。
  if ! pr_status_check_enabled; then
    if [ "${PR_REVIEWER_STATUS_CHECK_ENABLED:-false}" != "true" ] \
        && [ "${PR_STATUS_GATE_SUPPRESS_LOGGED:-0}" != "1" ]; then
      pr_log "commit status publish suppressed by PR_REVIEWER_STATUS_CHECK_ENABLED gate (no-op)"
      PR_STATUS_GATE_SUPPRESS_LOGGED=1
    fi
    return 1
  fi

  # 未信頼入力検証（silent fail せず WARN して return 2）
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    pr_warn "commit status publish: 不正な pr_number='${pr_number}'"; return 2
  fi
  if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    pr_warn "commit status publish: 不正な sha='${sha}'（40桁小文字hex期待）"; return 2
  fi
  case "$state" in
    success|failure|pending|error) : ;;
    *) pr_warn "commit status publish: 不正な state='${state}'"; return 2 ;;
  esac
  if [ -z "$context" ]; then
    pr_warn "commit status publish: context が空"; return 2
  fi

  # description 整形（空ならデフォルト / 72 字超は切り詰め）
  if [ -z "$description" ]; then
    description="${context}: ${state}"
  fi
  if [ "${#description}" -gt 72 ]; then
    description="${description:0:72}"
  fi

  # gh api 引数を配列で構築（-f key=val で JSON body を組むため inline 展開リスクが低い）。
  # target_url が空のときは -f target_url= を渡さない（空 URL 誤判定回避）。
  local -a api_args=(-X POST "repos/${REPO}/statuses/${sha}" \
    -f "state=$state" -f "context=$context" -f "description=$description")
  if [ -n "$target_url" ]; then
    api_args+=(-f "target_url=$target_url")
  fi

  local err_file api_rc=0
  err_file=$(idd_secure_mktemp "pr-status-${pr_number}" 2>/dev/null || true)
  if [ -n "$err_file" ]; then
    timeout "$PR_REVIEWER_GIT_TIMEOUT" gh api "${api_args[@]}" >/dev/null 2>"$err_file" || api_rc=$?
  else
    timeout "$PR_REVIEWER_GIT_TIMEOUT" gh api "${api_args[@]}" >/dev/null 2>&1 || api_rc=$?
  fi

  if [ "$api_rc" -ne 0 ]; then
    local err_tail=""
    if [ -n "$err_file" ]; then
      err_tail=$(tail -c 512 "$err_file" 2>/dev/null | tr '\n' ' ')
      rm -f "$err_file"
    fi
    pr_warn "commit status publish FAILED: pr=#${pr_number} sha=${sha} context=${context} state=${state} rc=${api_rc} stderr='${err_tail}'"
    return 3
  fi
  [ -n "$err_file" ] && rm -f "$err_file"
  pr_log "commit status published: pr=#${pr_number} sha=${sha} context=${context} state=${state}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_publish_codex_status: codex Reviewer の verdict を codex-review status へ写す (#98)
#   入力: $1=pr_number $2=sha $3=verdict(approve|iteration|conflict|...) $4=pr_url
#   戻り値: pr_publish_commit_status の戻り値をそのまま返す。
#   approve → success / それ以外（iteration / conflict 等）→ failure。
#   target_url はコメント permalink が取れないため PR URL に fallback。
# ─────────────────────────────────────────────────────────────────────────────
pr_publish_codex_status() {
  local pr_number="$1" sha="$2" verdict="$3" pr_url="${4:-}"
  local state description
  case "$verdict" in
    approve) state="success"; description="codex: approve" ;;
    *)       state="failure"; description="codex: ${verdict}" ;;
  esac
  pr_publish_commit_status "$pr_number" "$sha" "codex-review" "$state" "$description" "$pr_url"
}

# ═════════════════════════════════════════════════════════════════════════════
# Issue #108 / D-04: 2nd gate（claude-review commit status / claude CLI shell-out）
#   1st gate（codex-review）と同じ SHA を、独立に `claude` CLI でレビューし
#   `claude-review` status を publish する feature toggle。`PR_REVIEWER_SECOND_GATE=claude`
#   かつ status-check gate（PR_REVIEWER_STATUS_CHECK_ENABLED + FULL_AUTO_ENABLED）ON 時のみ。
#   OFF（既定）では claude-review を一切 publish しない（未 publish status での永久 pending 回避）。
# ═════════════════════════════════════════════════════════════════════════════

# pr_second_gate_enabled: 2nd gate（claude）が有効かを判定する（副作用なし）
#   戻り値: 0 = PR_REVIEWER_SECOND_GATE=claude かつ pr_status_check_enabled / 1 = それ以外
pr_second_gate_enabled() {
  [ "${PR_REVIEWER_SECOND_GATE:-off}" = "claude" ] || return 1
  pr_status_check_enabled || return 1
  return 0
}

# pr_check_claude_installed: `claude` CLI が PATH 上にあるか
#   戻り値: 0 = あり / 1 = 不在
pr_check_claude_installed() {
  if command -v claude >/dev/null 2>&1; then
    pr_log "2nd gate: claude installed check result=ok"
    return 0
  fi
  pr_log "2nd gate: claude installed check result=not-installed"
  return 1
}

# pr_check_claude_authenticated: claude の認証チェック（PR_REVIEWER_CLAUDE_AUTH_CMD）
#   戻り値: 0 = ok / 1 = not-authenticated / 2 = check 無効（env 空 = 既定 skip）
#   auth コマンドの stdout/stderr は完全破棄（auth token 流出防止）。eval 不使用。
pr_check_claude_authenticated() {
  local auth_cmd="${PR_REVIEWER_CLAUDE_AUTH_CMD:-}"
  if [ -z "$auth_cmd" ]; then
    pr_log "2nd gate: claude authenticated check result=skipped (auth cmd unset)"
    return 2
  fi
  if bash -c "$auth_cmd" >/dev/null 2>&1; then
    pr_log "2nd gate: claude authenticated check result=ok"
    return 0
  fi
  pr_log "2nd gate: claude authenticated check result=not-authenticated"
  return 1
}

# pr_publish_claude_status: claude verdict を claude-review status へ写す（#98 publish を再利用）
#   入力: $1=pr_number $2=sha $3=verdict(approve|iteration|conflict|none) $4=pr_url
#   approve → success / それ以外 → failure。context は `claude-review`。
pr_publish_claude_status() {
  local pr_number="$1" sha="$2" verdict="$3" pr_url="${4:-}"
  local state description
  case "$verdict" in
    approve) state="success"; description="claude: approve" ;;
    *)       state="failure"; description="claude: ${verdict}" ;;
  esac
  pr_publish_commit_status "$pr_number" "$sha" "claude-review" "$state" "$description" "$pr_url"
}

# pr_run_claude_second_gate: 1 PR の 2nd gate（claude）レビュー + claude-review publish
#   入力: $1=pr_number $2=sha $3=head_ref $4=base_ref $5=pr_url
#   戻り値: 0 固定（本体パイプラインを阻害しない / best-effort hardening）
#   claude 不在 / 未認証 / 実行失敗 / 空出力 → WARN + **claude-review を publish しない**
#   （保守的: required check 化されていれば pending 維持＝未検証 merge を防ぐ）。
pr_run_claude_second_gate() {
  local pr_number="$1" sha="$2" head_ref="$3" base_ref="$4" pr_url="${5:-}"

  if ! pr_check_claude_installed; then
    pr_warn "2nd gate: claude CLI が見つかりません（claude-review は publish せず skip / 本体継続）"
    return 0
  fi
  local auth_rc=0
  pr_check_claude_authenticated || auth_rc=$?
  if [ "$auth_rc" -eq 1 ]; then
    pr_warn "2nd gate: claude CLI 認証チェックに失敗（claude-review は publish せず skip / 本体継続）"
    return 0
  fi

  local prompt_file out_file err_file result_file
  if ! prompt_file=$(pr_build_prompt_file "$pr_number" "$base_ref" "$head_ref"); then
    pr_warn "2nd gate: prompt 構築に失敗（PR #${pr_number}・skip）"
    return 0
  fi
  out_file=$(idd_secure_mktemp "pr-claude-out-${pr_number}" 2>/dev/null || true)
  err_file=$(idd_secure_mktemp "pr-claude-err-${pr_number}" 2>/dev/null || true)
  result_file=$(idd_secure_mktemp "pr-claude-res-${pr_number}" 2>/dev/null || true)
  if [ -z "$out_file" ] || [ -z "$err_file" ] || [ -z "$result_file" ]; then
    pr_warn "2nd gate: 一時ファイル作成に失敗（PR #${pr_number}・skip）"
    rm -f "$prompt_file" "$out_file" "$err_file" "$result_file" 2>/dev/null || true
    return 0
  fi

  local resolved_cmd
  if ! resolved_cmd=$(pr_substitute_placeholders "$PR_REVIEWER_CLAUDE_CMD" "$base_ref" "$head_ref" "$pr_number" "$prompt_file"); then
    pr_warn "2nd gate: コマンド placeholder 置換に失敗（unsafe 値・PR #${pr_number}・skip）"
    rm -f "$prompt_file" "$out_file" "$err_file" "$result_file" 2>/dev/null || true
    return 0
  fi

  pr_execute_review_command "$head_ref" "$resolved_cmd" "claude" "$out_file" "$err_file" "$result_file"
  local result exec_rc wsmod
  result=$(cat "$result_file" 2>/dev/null || echo "")
  case "$result" in
    fetch-fail|checkout-fail)
      pr_warn "2nd gate: head '${head_ref}' の取得に失敗 (${result})・PR #${pr_number}・claude-review は publish せず skip"
      rm -f "$prompt_file" "$out_file" "$err_file" "$result_file" 2>/dev/null || true
      return 0
      ;;
  esac
  exec_rc=$(printf '%s' "$result" | awk -F: '{print $2}')
  wsmod=$(printf '%s' "$result" | awk -F: '{print $3}')
  exec_rc="${exec_rc:-1}"

  if [ "$wsmod" = "modified" ] || [ "$exec_rc" -ne 0 ]; then
    pr_warn "2nd gate: claude レビュー実行に失敗 (result=${result})・PR #${pr_number}・claude-review は publish せず skip（本体継続）"
    rm -f "$prompt_file" "$out_file" "$err_file" "$result_file" 2>/dev/null || true
    return 0
  fi

  local review_text
  review_text=$(cat "$out_file" 2>/dev/null || echo "")
  if [ -z "$review_text" ]; then
    pr_warn "2nd gate: claude レビュー出力が空・PR #${pr_number}・claude-review は publish せず skip"
    rm -f "$prompt_file" "$out_file" "$err_file" "$result_file" 2>/dev/null || true
    return 0
  fi

  local verdict
  verdict=$(pr_resolve_review_verdict "$pr_number" "$review_text")
  pr_log "PR #${pr_number}: 2nd gate (claude) verdict=${verdict} sha=${sha}"
  pr_publish_claude_status "$pr_number" "$sha" "$verdict" "$pr_url" || true

  rm -f "$prompt_file" "$out_file" "$err_file" "$result_file" 2>/dev/null || true
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_run_review_for_pr: 1 PR 分のレビューを統括する（task 4〜6 の orchestration）
#   入力: $1 = pr_json（pr_fetch_candidate_prs の単一要素）, $2 = tool
#   戻り値: 0 = success / 1 = failure（一時的・skip 相当）/ 2 = skip（重複検出）/
#           3 = exec-error（実行失敗 / workspace-modified / 空出力）
#   AC: 4.1, 4.2, 4.3, 4.4, 4.5, 5.1〜5.4, 6.1〜6.4
#
#   フロー: 重複判定(kind=review) → prompt 生成 → cmd 置換 → レビュー実行 →
#           結果判定（fetch/checkout-fail / workspace-modified / exec-failed /
#           空出力 / 成功）→ 成功時はコメント投稿 + VERDICT 検出 + ラベル付与。
# ─────────────────────────────────────────────────────────────────────────────
pr_run_review_for_pr() {
  local pr_json="$1"
  local tool="$2"

  local pr_number head_ref base_ref sha pr_url
  pr_number=$(echo "$pr_json" | jq -r '.number')
  head_ref=$(echo "$pr_json"  | jq -r '.headRefName')
  base_ref=$(echo "$pr_json"  | jq -r '.baseRefName')
  sha=$(echo "$pr_json"       | jq -r '.headRefOid')
  pr_url=$(echo "$pr_json"    | jq -r '.url')

  if [ -z "$base_ref" ] || [ "$base_ref" = "null" ]; then
    base_ref="$BASE_BRANCH"
  fi

  # AC 6.2 / NFR 4.1: 同一 (sha, kind=review) が既存なら重複レビューを行わない
  if pr_already_processed "$pr_number" "$sha" "review"; then
    pr_log "PR #${pr_number}: sha=${sha} は既にレビュー済み（kind=review marker 検出）。skip"
    return 2
  fi

  # #403 移植: 同一 sha の連続 exec 失敗が上限に達したら外部レビューツール呼び出しを抑止
  # （無限リトライによる rate-limit 持続を防ぐ）。新規 commit を push して sha が変われば
  # streak は reset され自動再開。エスカレーションコメントは 1 回のみ（kind 重複防止）・ラベルは付与しない。
  if pr_exec_fail_limit_reached "$pr_number" "$sha"; then
    local _ef_streak
    _ef_streak="$(pr_read_exec_fail_streak "$pr_number" "$sha")"
    pr_post_error_comment "$pr_number" "$sha" "exec-fail-escalated" \
      "レビューツール \`${tool}\` の実行が同一 sha で連続失敗（${_ef_streak}/${PR_REVIEWER_EXEC_FAIL_LIMIT} 回）したため、当該 sha への外部レビュー呼び出しを抑止します（rate-limit 持続の防止）。**新規 commit を push** すると自動的にレビューを再開します。ラベルは付与しません（診断は watcher ローカルログ / 既存 diagnostic artifact を参照）。" \
      "$tool"
    pr_log "PR #${pr_number}: exec-fail-streak 上限到達 (${_ef_streak}/${PR_REVIEWER_EXEC_FAIL_LIMIT}) tool=${tool} sha=${sha} → 外部レビュー抑止"
    return 2
  fi

  pr_log "PR #${pr_number}: レビュー着手 tool=${tool} head=${head_ref} base=${base_ref} sha=${sha} (${pr_url})"

  # cmd template を tool 別に解決
  local cmd_template
  case "$tool" in
    codex)       cmd_template="${PR_REVIEWER_CODEX_CMD}" ;;
    antigravity) cmd_template="${PR_REVIEWER_ANTIGRAVITY_CMD}" ;;
    *)
      pr_warn "PR #${pr_number}: 未知の tool '${tool}'、skip"
      return 1
      ;;
  esac

  # prompt tempfile + 実行結果受け渡し tempfile を親で生成し、RETURN trap で確実に削除。
  local prompt_file out_file err_file result_file
  if ! prompt_file=$(pr_build_prompt_file "$pr_number" "$base_ref" "$head_ref"); then
    pr_warn "PR #${pr_number}: prompt 生成に失敗、skip"
    return 1
  fi
  if ! out_file=$(idd_secure_mktemp "pr-reviewer-out-${pr_number}"); then
    rm -f "$prompt_file"
    pr_warn "PR #${pr_number}: stdout secure tempfile の作成に失敗、skip"
    return 1
  fi
  if ! err_file=$(idd_secure_mktemp "pr-reviewer-stderr-${pr_number}"); then
    rm -f "$prompt_file" "$out_file"
    pr_warn "PR #${pr_number}: stderr secure tempfile の作成に失敗、skip"
    return 1
  fi
  if ! result_file=$(idd_secure_mktemp "pr-reviewer-result-${pr_number}"); then
    rm -f "$prompt_file" "$out_file" "$err_file"
    pr_warn "PR #${pr_number}: result secure tempfile の作成に失敗、skip"
    return 1
  fi
  local cleanup_cmd
  printf -v cleanup_cmd 'rm -f %q %q %q %q' "$prompt_file" "$out_file" "$err_file" "$result_file"
  # shellcheck disable=SC2064  # secure tempfile paths are shell-escaped into a fixed cleanup command.
  trap "$cleanup_cmd" RETURN

  # プレースホルダ置換（{BASE}/{HEAD}/{PR}/{PROMPT_FILE}）+ unsafe value 検査（AC 4.3 / Issue #52 Req 6）
  local resolved_cmd
  if ! resolved_cmd=$(pr_substitute_placeholders "$cmd_template" "$base_ref" "$head_ref" "$pr_number" "$prompt_file"); then
    return 1
  fi

  # レビュー実行（git checkout は subshell 内 / trap で BASE_BRANCH 復帰、AC 4.1/4.2）
  pr_execute_review_command "$head_ref" "$resolved_cmd" "$tool" "$out_file" "$err_file" "$result_file"

  local result
  result=$(cat "$result_file" 2>/dev/null || echo "")

  case "$result" in
    fetch-fail|checkout-fail)
      # 一時的な git/gh 失敗 → WARN + skip（コメント投稿しない / Error 戦略 3 層目）
      pr_warn "PR #${pr_number}: head '${head_ref}' の取得に失敗 (${result})、当該 PR を skip"
      return 1
      ;;
  esac

  local exec_rc wsmod
  exec_rc=$(printf '%s' "$result" | awk -F: '{print $2}')
  wsmod=$(printf '%s' "$result" | awk -F: '{print $3}')
  exec_rc="${exec_rc:-1}"

  # read-only invariant 違反（Decision 8）→ workspace-modified エラーコメント、exec-error
  if [ "$wsmod" = "modified" ]; then
    pr_error "PR #${pr_number}: レビュー実行がワークツリーを変更しました（read-only invariant 違反）。tracked 変更を破棄し workspace-modified を報告"
    pr_post_error_comment "$pr_number" "$sha" "workspace-modified" \
      "レビューツール \`${tool}\` の実行がワークツリーを変更しました。read-only 制約に違反するため tracked 変更を破棄しました。ツールの sandbox / read-only 設定（codex は \`--sandbox read-only\`）と \`PR_REVIEWER_*_CMD\` を確認してください。" \
      "$tool"
    pr_record_exec_fail "$pr_number" "$sha" >/dev/null  # #403: 連続失敗カウント（再現性ある失敗）
    return 3
  fi

  # 実行失敗（非ゼロ終了）→ public は generic、raw stdout/stderr は local diagnostic artifact に限定
  if [ "$exec_rc" -ne 0 ]; then
    local quota_reset_epoch
    quota_reset_epoch=$(pr_detect_usage_limit_reset_epoch "$out_file" "$err_file")
    if [[ "$quota_reset_epoch" =~ ^[0-9]+$ ]]; then
      pr_handle_quota_wait "$pr_number" "$sha" "$tool" "$quota_reset_epoch" || true
      return 2
    fi

    local diagnostic_file correlation_token detail
    diagnostic_file=$(pr_write_exec_failure_diagnostic "$pr_number" "$sha" "$tool" "$exec_rc" "$out_file" "$err_file")
    correlation_token="unavailable"
    if [ -n "$diagnostic_file" ]; then
      correlation_token="$(basename "$diagnostic_file")"
    fi
    pr_error "PR #${pr_number}: レビュー実行コマンドが非ゼロ終了 (exit=${exec_rc}, tool=${tool}, correlation=${correlation_token})"
    # shellcheck disable=SC2016  # 単一引用符内のバッククォートは markdown inline code のリテラル
    detail=$(printf 'レビュー実行コマンドが非ゼロ終了しました。詳細は watcher のローカルログまたは診断 artifact を確認してください。\n\n- PR: #%s\n- sha: `%s`\n- tool: `%s`\n- exit: `%s`\n- correlation: `%s`' \
      "$pr_number" "$sha" "$tool" "$exec_rc" "$correlation_token")
    pr_post_error_comment "$pr_number" "$sha" "exec-failed" "$detail" "$tool"
    pr_record_exec_fail "$pr_number" "$sha" >/dev/null  # #403: non-quota exec 失敗を streak に計上
    return 3
  fi

  # 成功: stdout をレビュー結果として収集（AC 4.2）
  local review_text
  review_text=$(cat "$out_file" 2>/dev/null || echo "")

  # antigravity (agy) は --output-format json のため最終 message を jq 抽出。
  # 実機の JSON schema は未確定のため複数キーを試し、失敗時は raw stdout に fail-safe
  # （実装時に `agy --help` 出力で確定し impl-notes.md に記録 / design 確認事項 1）。
  if [ "$tool" = "antigravity" ]; then
    local extracted
    extracted=$(printf '%s' "$review_text" | jq -r '.message // .text // .response // empty' 2>/dev/null || echo "")
    if [ -n "$extracted" ]; then
      review_text="$extracted"
    fi
  fi

  if [ -z "$review_text" ]; then
    pr_warn "PR #${pr_number}: レビュー結果が空。exec-failed として扱う"
    pr_post_error_comment "$pr_number" "$sha" "exec-failed" \
      "レビュー実行は成功しましたが出力が空でした（tool=${tool}）。\`PR_REVIEWER_*_CMD\` / prompt を確認してください。" \
      "$tool"
    pr_record_exec_fail "$pr_number" "$sha" >/dev/null  # #403: 空出力（再現性ある失敗）を streak に計上
    return 3
  fi

  # #403: レビュー出力を得られた（= exec 成功）→ 連続失敗 streak を消去。
  pr_reset_exec_fail "$pr_number"

  local verdict
  verdict=$(pr_resolve_review_verdict "$pr_number" "$review_text")
  pr_log "PR #${pr_number}: review verdict=${verdict} tool=${tool} sha=${sha}"

  if [ "$verdict" = "approve" ]; then
    pr_try_post_formal_approval "$pr_number" "$sha" "$review_text" "$tool" || true
  fi

  # AC 4.4: レビュー結果コメント投稿（marker kind=review）。formal approval が失敗しても
  # current-SHA の marker comment を残し、後段 Merge Queue の fallback signal にする。
  if ! pr_post_review_comment "$pr_number" "$sha" "$review_text" "$tool"; then
    return 1
  fi

  # AC 5.1〜5.4: iteration / conflict は codex-needs-iteration ラベル付与を優先し、
  # approve signal は公開しない。
  if [ "$verdict" = "iteration" ] || [ "$verdict" = "conflict" ]; then
    pr_add_iteration_label "$pr_number"
  fi

  # codex-review commit status を publish（AND 二重 opt-in gate ON 時のみ / #98）。
  # auto-merge(#99) の required status check の source になる。publish 失敗は
  # パイプラインを止めない（best-effort / pr_publish_commit_status が WARN 済み）。
  pr_publish_codex_status "$pr_number" "$sha" "$verdict" "$pr_url" || true

  # 2nd gate（claude-review / #108）。toggle OFF（既定）では no-op。同一 SHA を claude で
  # 独立レビューし claude-review status を publish する。best-effort（本体を止めない）。
  if pr_second_gate_enabled; then
    pr_run_claude_second_gate "$pr_number" "$sha" "$head_ref" "$base_ref" "$pr_url" || true
  fi

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_broadcast_error_to_prs: 候補 PR 全件に同種エラーコメントを投稿（内部 helper）
#   入力: $1 = prs_json（jq 配列）, $2 = kind, $3 = tool, $4 = detail
#   戻り値: 0 固定
#   AC: 2.4, 3.1, 3.2（cycle-level エラーを対象 PR へ broadcast。重複防止は
#       pr_post_error_comment 内の (sha, kind) marker 判定に委譲）
#
#   - conflict-tool / not-installed / not-authenticated は「サイクル単位で確定するが
#     通知先は個々の対象 PR」という性質のため、健全性チェックを 1 回だけ実施し、
#     その結果を候補 PR 全件へ配る（各 PR で sha=headRefOid を marker に使う）。
# ─────────────────────────────────────────────────────────────────────────────
pr_broadcast_error_to_prs() {
  local prs_json="$1"
  local kind="$2"
  local tool="$3"
  local detail="$4"

  local pr_iter
  pr_iter=$(echo "$prs_json" | jq -c '.[]' 2>/dev/null || echo "")
  [ -z "$pr_iter" ] && return 0

  while IFS= read -r pr_json; do
    [ -z "$pr_json" ] && continue
    local pr_number sha
    pr_number=$(echo "$pr_json" | jq -r '.number')
    sha=$(echo "$pr_json" | jq -r '.headRefOid')
    pr_post_error_comment "$pr_number" "$sha" "$kind" "$detail" "$tool" || true
  done <<< "$pr_iter"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# process_pr_reviewer: dispatcher から呼ばれるエントリ関数
#   入力: なし（env var 群を読む）
#   出力: なし（log のみ）
#   戻り値: 0 固定（後続 processor を阻害しないため / dispatcher fail-continue 契約）
#   AC 1.1, 1.2, 1.3, 2.x, 3.x, 7.x, NFR 1.1, NFR 3.1, NFR 4.1
#
#   処理順:
#     ① opt-in gate（PR_REVIEWER_ENABLED=true 厳密一致のみ。それ以外は早期 return）
#     ② tool 解決（pr_resolve_tool: codex/antigravity/none/conflict）
#     ③ サイクル開始の 1 行サマリログ（NFR 3.1）
#     ④ none（rc=2）→ 静かに skip（PR 列挙もコメントも行わない、AC 2.5）
#     ⑤ 候補 PR 列挙（conflict broadcast / review loop の双方で必要）
#     ⑥ conflict（rc=1）→ 候補 PR へ kind=conflict-tool を broadcast して中止（AC 2.3/2.4）
#     ⑦ 候補 0 件 → サマリログのみで return
#     ⑧ 未インストール（AC 3.1）→ kind=not-installed を broadcast して中止
#     ⑨ 未認証（AC 3.2）→ kind=not-authenticated を broadcast して中止
#     ⑩ MAX_PRS で truncate（total / target / overflow をログ、NFR 3.1）
#     ⑪ レビュー loop（pr_run_review_for_pr）→ rc 集計 → サマリログ
# ─────────────────────────────────────────────────────────────────────────────
process_pr_reviewer() {
  # ① AC 1.1 / NFR 1.1: opt-in gate（=true 厳密一致のみ有効。それ以外は全て OFF）
  if [ "${PR_REVIEWER_ENABLED:-false}" != "true" ]; then
    return 0
  fi

  # ② AC 2.x: tool 解決（stdout に tool 名 / 戻り値で状態を返す）
  local resolved_tool resolve_rc=0
  resolved_tool=$(pr_resolve_tool) || resolve_rc=$?

  # ③ AC 1.2 / NFR 3.1: サイクル開始の 1 行サマリログ
  pr_log "cycle start: tool=${resolved_tool} max_prs=${PR_REVIEWER_MAX_PRS:-unset} git_timeout=${PR_REVIEWER_GIT_TIMEOUT:-unset}s exec_timeout=${PR_REVIEWER_EXEC_TIMEOUT:-unset}s head_pattern=${PR_REVIEWER_HEAD_PATTERN:-unset}"

  # ④ AC 2.5: none（rc=2）は PR 列挙もコメントも行わず静かに skip
  if [ "$resolve_rc" -eq 2 ]; then
    return 0
  fi

  # PR Reviewer 由来の usage-limit quota wait は、reset+grace 経過後に quota ラベルだけ外し、
  # review marker を付けないまま次サイクルで同じ PR を再レビュー候補へ戻す。
  pr_process_quota_resume

  # ⑤ 候補 PR 列挙（AC 7.x）
  local prs_json total
  prs_json=$(pr_fetch_candidate_prs)
  total=$(echo "$prs_json" | jq 'length' 2>/dev/null || echo 0)

  # ⑥ AC 2.3 / 2.4: conflict（rc=1）は候補 PR へ排他エラーを broadcast して中止
  if [ "$resolve_rc" -eq 1 ]; then
    pr_broadcast_error_to_prs "$prs_json" "conflict-tool" "none" \
      "\`codex\` と \`antigravity\` の両方が有効化されています（排他エラー）。\`PR_REVIEWER_TOOL\` もしくは \`PR_REVIEWER_CODEX_ENABLED\` / \`PR_REVIEWER_ANTIGRAVITY_ENABLED\` のいずれか一方のみを有効化してください。"
    pr_log "サマリ: tool=conflict reviewed=0 skip=0 fail=0 errored=${total}（conflict-tool broadcast）"
    return 0
  fi

  # 以降 resolved_tool は codex / antigravity（resolve_rc==0）

  # ⑦ 候補 0 件 → サマリのみ
  if [ "$total" -eq 0 ]; then
    pr_log "サマリ: tool=${resolved_tool} reviewed=0 skip=0 fail=0 errored=0（候補 PR なし）"
    return 0
  fi

  # ⑧ AC 3.1: 未インストール → 候補 PR へ broadcast して中止（健全性チェックは 1 回）
  if ! pr_check_tool_installed "$resolved_tool"; then
    pr_broadcast_error_to_prs "$prs_json" "not-installed" "$resolved_tool" \
      "レビューツール \`${resolved_tool}\` の実行ファイルが PATH 上に見つかりません。watcher 実行環境にインストールし、認証を済ませてください。"
    pr_log "サマリ: tool=${resolved_tool} reviewed=0 skip=0 fail=0 errored=${total}（not-installed broadcast）"
    return 0
  fi

  # ⑨ AC 3.2: 未認証 → 候補 PR へ broadcast して中止（rc=2 は check 無効 = skip 扱い）
  local auth_rc=0
  pr_check_tool_authenticated "$resolved_tool" || auth_rc=$?
  if [ "$auth_rc" -eq 1 ]; then
    pr_broadcast_error_to_prs "$prs_json" "not-authenticated" "$resolved_tool" \
      "レビューツール \`${resolved_tool}\` が未認証です。watcher 実行環境で認証を済ませてください。"
    pr_log "サマリ: tool=${resolved_tool} reviewed=0 skip=0 fail=0 errored=${total}（not-authenticated broadcast）"
    return 0
  fi

  # ⑩ MAX_PRS で truncate（total / target / overflow をログ、NFR 3.1）
  local target_count="$total" skipped_overflow=0
  if [ "$total" -gt "$PR_REVIEWER_MAX_PRS" ]; then
    target_count="$PR_REVIEWER_MAX_PRS"
    skipped_overflow=$((total - PR_REVIEWER_MAX_PRS))
    pr_log "対象候補 ${total} 件中、上限 ${PR_REVIEWER_MAX_PRS} 件のみ処理（${skipped_overflow} 件は次回持ち越し）"
  else
    pr_log "対象候補 ${total} 件、処理対象 ${target_count} 件"
  fi

  # ⑪ レビュー loop
  local reviewed=0 skip=0 fail=0 errored=0
  local pr_iter
  pr_iter=$(echo "$prs_json" | jq -c ".[0:${target_count}][]" 2>/dev/null || echo "")
  if [ -z "$pr_iter" ]; then
    pr_log "サマリ: tool=${resolved_tool} reviewed=0 skip=0 fail=0 errored=0（iterate 対象なし）"
    return 0
  fi

  while IFS= read -r pr_json; do
    [ -z "$pr_json" ] && continue
    local rc=0
    pr_run_review_for_pr "$pr_json" "$resolved_tool" || rc=$?
    case $rc in
      0) reviewed=$((reviewed + 1)) ;;
      2) skip=$((skip + 1)) ;;
      3) errored=$((errored + 1)) ;;
      *) fail=$((fail + 1)) ;;
    esac
    # 各 PR 処理後に保険で base branch に戻す（レビューは subshell 内で完結するが念のため）
    git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
  done <<< "$pr_iter"

  pr_log "サマリ: tool=${resolved_tool} reviewed=${reviewed} skip=${skip} fail=${fail} errored=${errored} overflow=${skipped_overflow}"

  # 念のため最終確認で base branch に戻す
  git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
  return 0
}
