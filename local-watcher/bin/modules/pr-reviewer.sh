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
#   $HOME/bin/modules/pr-reviewer.sh（install.sh が local-watcher/bin/modules/ から配置する）
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

# レビュー観点（優先度順）
1. 正確性のバグ: ロジック誤り・境界条件・null/空入力・競合・例外未処理
2. 受入基準の未カバー: docs/specs/ に requirements.md があれば AC と差分を突き合わせる
3. テスト不足: 変更された分岐に対応するテストの欠落
4. セキュリティ退行: 入力検証・認証・機密情報露出・コマンドインジェクション
5. 後方互換性の破壊: 既存 env var / 出力契約の変更

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
#   戻り値: 0 = ok / 1 = mktemp 失敗
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
  if ! tmpfile=$(mktemp -t idd-codex-pr-reviewer.XXXXXX 2>/dev/null); then
    pr_warn "PR #${pr_number}: prompt 一時ファイルの作成に失敗"
    return 1
  fi
  printf '%s\n' "$prompt" > "$tmpfile"
  printf '%s' "$tmpfile"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_substitute_placeholders: 実行コマンドのプレースホルダ置換（task 5.1）
#   入力: $1 = cmd_template, $2 = base_ref, $3 = head_ref, $4 = pr_number,
#         $5 = prompt_file_path
#   出力: stdout に置換済みコマンド文字列
#   戻り値: 0 = ok / 1 = metachar 検出（呼び出し元は当該 PR を skip）
#   AC: 4.3
#
#   - 置換対象: {BASE} / {HEAD} / {PR} / {PROMPT_FILE}
#   - 注入値（GitHub 由来の branch 名 / PR 番号）に shell metacharacter
#     （`;` `|` `&` `` ` `` `$(`）が混入していないか検査し、検出時は WARN + skip
#     （GitHub branch 命名規約では発生しないが防御的設計 / Security Considerations）。
#   - prompt_file_path は mktemp 由来の自前パスのため検査対象外。cmd_template は
#     運用者入力（信頼境界内）かつ正当な `$(cat '...')` を含むため検査しない。
#   - stdout に結果を返す契約のため pr_log は使わず pr_warn（stderr）のみ使用。
# ─────────────────────────────────────────────────────────────────────────────
pr_substitute_placeholders() {
  local cmd_template="$1"
  local base_ref="$2"
  local head_ref="$3"
  local pr_number="$4"
  local prompt_file="$5"

  local v
  for v in "$base_ref" "$head_ref" "$pr_number"; do
    # shellcheck disable=SC2016  # 単一引用符内の $( は意図した「リテラル文字列の検出パターン」
    case "$v" in
      *';'* | *'|'* | *'&'* | *'`'* | *'$('* )
        pr_warn "placeholder 値に shell metacharacter を検出（base='${base_ref}' head='${head_ref}' pr='${pr_number}'）。当該 PR を skip します"
        return 1
        ;;
    esac
  done

  local out="$cmd_template"
  out="${out//\{BASE\}/$base_ref}"
  out="${out//\{HEAD\}/$head_ref}"
  out="${out//\{PR\}/$pr_number}"
  out="${out//\{PROMPT_FILE\}/$prompt_file}"
  printf '%s' "$out"
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
  if ! body_file=$(mktemp -t idd-codex-pr-review-approve.XXXXXX 2>/dev/null); then
    pr_warn "PR #${pr_number}: formal approval body 一時ファイルの作成に失敗（marker approval fallback を継続）"
    return 1
  fi
  if ! err_file=$(mktemp -t idd-codex-pr-review-approve-err.XXXXXX 2>/dev/null); then
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
  out_file=$(mktemp -t idd-codex-pr-reviewer-out.XXXXXX 2>/dev/null || mktemp)
  err_file=$(mktemp -t idd-codex-pr-reviewer-err.XXXXXX 2>/dev/null || mktemp)
  result_file=$(mktemp -t idd-codex-pr-reviewer-res.XXXXXX 2>/dev/null || mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '${prompt_file}' '${out_file}' '${err_file}' '${result_file}'" RETURN

  # プレースホルダ置換（{BASE}/{HEAD}/{PR}/{PROMPT_FILE}）+ metachar 検査（AC 4.3）
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
    return 3
  fi

  # 実行失敗（非ゼロ終了）→ exec-failed エラーコメント（stderr 1KB 抜粋付き、AC 4.5）
  if [ "$exec_rc" -ne 0 ]; then
    local quota_reset_epoch
    quota_reset_epoch=$(pr_detect_usage_limit_reset_epoch "$out_file" "$err_file")
    if [[ "$quota_reset_epoch" =~ ^[0-9]+$ ]]; then
      pr_handle_quota_wait "$pr_number" "$sha" "$tool" "$quota_reset_epoch" || true
      return 2
    fi

    local err_excerpt detail
    err_excerpt=$(head -c 1024 "$err_file" 2>/dev/null || echo "")
    pr_error "PR #${pr_number}: レビュー実行コマンドが非ゼロ終了 (exit=${exec_rc}, tool=${tool})"
    # shellcheck disable=SC2016  # 単一引用符内のバッククォートは markdown コードフェンスのリテラル
    detail=$(printf 'レビュー実行コマンドが非ゼロ終了しました（exit=%s, tool=%s）。\n\n```\n%s\n```' \
      "$exec_rc" "$tool" "$err_excerpt")
    pr_post_error_comment "$pr_number" "$sha" "exec-failed" "$detail" "$tool"
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
    return 3
  fi

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
