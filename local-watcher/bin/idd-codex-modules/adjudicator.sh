#!/usr/bin/env bash
# shellcheck shell=bash
# adjudicator.sh — watcher の PR Reviewer Adjudicator モジュール (#404)
#
# 用途:
#   idd-codex-issue-watcher.sh から分離した PR Reviewer Adjudicator (#404) の関数定義を集約する。
#   `PR_REVIEWER_ADJUDICATOR_ENABLED=true` のとき codex 由来のレビュー指摘
#   （`pr-reviewer.sh` の `pr_run_review_for_pr` が PR コメントに投稿した本文）を入力に
#   各指摘を **legitimate（実害）** / **excessive（過剰）** に分類する Claude adjudicator
#   ステップを提供し、`codex-needs-iteration` ラベル + `claude-review` commit status の最終
#   確定権を adjudicator 側に移譲する。設計の詳細は
#   docs/specs/404-feat-pr-reviewer-codex-advisory-claude-a/design.md を参照。
#
#   - opt-in gate 判定: adj_gate_enabled
#     既に正規化済みの `PR_REVIEWER_ADJUDICATOR_ENABLED`（idd-codex-issue-watcher.sh の
#     Config ブロックで `case true) ... *) false` に正規化済み）を厳密 `=true` で評価する。
#     重複正規化は行わない（既定値の責任は呼び出し側 / Req 5.1）。
#   - codex 指摘 parse: adj_extract_findings
#     codex stdout の `## 指摘事項` 配下 bullet 行を awk で抽出し、JSON 配列化する。
#     reconciliation check 内蔵: `## 指摘事項` 配下の bullet 総数と parse 件数を突合し、
#     不一致を検出した場合は WARN を stderr に出し戻り値 4 を返す（書式ドリフトによる
#     silent 取りこぼし防止 / Req 1.1, 5.5）。
#
# 配置先:
#   $HOME/bin/idd-codex-modules/adjudicator.sh（install.sh が local-watcher/bin/idd-codex-modules/ から配置する）
#
# 依存:
#   - 本モジュールは idd-codex-issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - 関数 prefix `adj_` で namespace する。
#   - ロガー adj_log / adj_warn / adj_error は core_utils.sh に定義済み（#404 task 1 で追加）。
#     本モジュールは bash の遅延束縛で参照するのみで、再定義しない。
#   - グローバル変数（$REPO / $PR_REVIEWER_ADJUDICATOR_ENABLED 他 5 env / $LABEL_NEEDS_ITERATION）は
#     本体冒頭の Config ブロックで定義済み（idd-codex-issue-watcher.sh / task 1 で追加）。本モジュールは
#     env を消費するのみで、再宣言・再正規化しない。
#   - 外部 CLI: jq（指摘 JSON 化に使用）/ claude（adjudicator 本体）。

# ─────────────────────────────────────────────────────────────────────────────
# adj_gate_enabled: opt-in gate 評価（既に正規化済みの env を厳密一致で判定）
#   入力: なし（env のみ参照）
#   出力: なし
#   戻り値: 0 = ON / 1 = OFF
#
#   idd-codex-issue-watcher.sh の Config ブロックで `PR_REVIEWER_ADJUDICATOR_ENABLED` は
#   `case true) ... *) false` で正規化されているため、本関数は厳密 `=true` 判定のみ行う
#   （既定 / 未設定 / typo / 大文字違い等はすべて OFF / Req 5.1 安全側 / 重複正規化はしない）。
# ─────────────────────────────────────────────────────────────────────────────
adj_gate_enabled() {
  if [ "${PR_REVIEWER_ADJUDICATOR_ENABLED:-false}" = "true" ]; then
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# adj_extract_findings: codex stdout から `## 指摘事項` 配下の bullet 行を抽出し JSON 配列化
#   入力: $1 = review_text（codex stdout の全文）
#   出力: stdout に [{"severity":"high|medium|low","file":"...","line":N,"message":"..."}, ...]
#         （指摘ゼロ / `## 指摘事項` 不在 / 「指摘なし」のみの場合は `[]` を出力）
#   戻り値: 0 = ok / 4 = reconciliation mismatch（呼び出し元で fail-safe へ倒す）
#
#   アルゴリズム（design.md Components and Interfaces 節の関数 contract 準拠）:
#     1. awk で `## 指摘事項` 見出しを探し、その下から次の `## ` 始まり見出し（または EOF）
#        までを抽出範囲とする。
#     2. 抽出範囲内で行頭が `- ` で始まる bullet 行をすべて数える（reconciliation 用 total）。
#     3. うち書式
#          - [high|medium|low] <file>:<line> — <内容>
#        に厳密一致するもののみ parse して TSV を吐く（severity / file / line / message）。
#        `—` は em dash (U+2014) で codex 出力テンプレ (`pr_default_prompt`) と整合。
#     4. TSV 各行を jq で JSON object 化し、`jq -s '.'` で配列化（未信頼入力は
#        `--arg` でリテラル渡し / jq filter inline 展開禁止）。
#     5. bullet 総数 != parse 件数を検出した場合は WARN を stderr に出し戻り値 4 を返す。
#        ただし「指摘なし」のみ（bullet 総数 0、行頭プレーン 1 行のみ）は reconcile 対象外
#        として `[]` rc=0 で返す（codex VERDICT 経路の通常成功ケース）。
# ─────────────────────────────────────────────────────────────────────────────
adj_extract_findings() {
  local review_text="${1:-}"

  # awk で `## 指摘事項` 見出しから次 `## ` 見出し or EOF までを抽出。
  # 抽出結果は (a) bullet 総数 (b) parse 成功 TSV の 2 つを同時に算出するため、
  # awk 内で 2 系統の出力（"BULLET_TOTAL=<N>" 1 行 + parse 成功 TSV 行群）を吐き、
  # 呼び出し側で分離する。
  local awk_out
  awk_out=$(awk '
    BEGIN {
      in_section = 0
      bullet_total = 0
    }
    # 範囲開始: 行 trim 後が "## 指摘事項" に一致
    {
      line = $0
      # rtrim
      sub(/[[:space:]]+$/, "", line)
    }
    /^## 指摘事項[[:space:]]*$/ {
      in_section = 1
      next
    }
    # 範囲終了: 次の "## " 始まり見出し（"## 指摘事項" は上で処理済み）
    in_section && /^## / {
      in_section = 0
      next
    }
    in_section {
      # bullet 行（行頭が "- "）をカウント
      if (line ~ /^- /) {
        bullet_total++
        # 厳密 parse: "- [high|medium|low] <file>:<line> — <内容>"
        # em dash は U+2014（UTF-8: 0xE2 0x80 0x94）。bash の文字列リテラル経由で awk に
        # 渡される正規表現中の "—" はそのまま UTF-8 byte 列としてマッチする。
        if (match(line, /^- \[(high|medium|low)\] [^[:space:]:]+:[0-9]+ — /)) {
          # severity: [<sev>] を抽出
          sev = line
          sub(/^- \[/, "", sev)
          sub(/\].*$/, "", sev)
          # file:line を抽出（severity 部の後）
          rest = line
          sub(/^- \[(high|medium|low)\] /, "", rest)
          # rest は "<file>:<line> — <内容>" の形
          # "<file>:<line>" 部分を切り出し（最初の " — " で分割）
          pos = index(rest, " — ")
          if (pos > 0) {
            head = substr(rest, 1, pos - 1)
            msg  = substr(rest, pos + length(" — "))
            # head の最後の ":" で file と line を分割（file 名に "." は含まれ得るが ":" は含まない前提）
            colon = 0
            for (i = length(head); i >= 1; i--) {
              if (substr(head, i, 1) == ":") { colon = i; break }
            }
            if (colon > 0) {
              fil = substr(head, 1, colon - 1)
              lin = substr(head, colon + 1)
              # line は [0-9]+ のみであることを念のため検査
              if (lin ~ /^[0-9]+$/) {
                # TSV: severity \t file \t line \t message
                # awk の "\t" はタブ文字。message 中のタブは存在しない前提（codex 出力にタブはない）。
                printf "PARSED\t%s\t%s\t%s\t%s\n", sev, fil, lin, msg
              }
            }
          }
        }
      }
    }
    END {
      printf "BULLET_TOTAL=%d\n", bullet_total
    }
  ' <<<"$review_text")

  # awk_out の最後の "BULLET_TOTAL=<N>" 行を抽出し、それ以外の PARSED 行を parse 成功分とする。
  local bullet_total parsed_lines
  bullet_total=$(printf '%s\n' "$awk_out" | grep -E '^BULLET_TOTAL=[0-9]+$' | tail -n 1 | sed 's/^BULLET_TOTAL=//')
  parsed_lines=$(printf '%s\n' "$awk_out" | grep -E '^PARSED\b' || true)

  if [ -z "$bullet_total" ]; then
    bullet_total=0
  fi

  # parse 成功件数
  local parsed_count=0
  if [ -n "$parsed_lines" ]; then
    parsed_count=$(printf '%s\n' "$parsed_lines" | wc -l | tr -d '[:space:]')
  fi

  # JSON 配列化: TSV 各行を jq で object 化 → `jq -s '.'` で配列化
  # 未信頼入力（codex 出力 / PR コメント由来）は `--arg` でリテラル渡し（jq filter inline 展開禁止）。
  local json_out
  if [ "$parsed_count" -eq 0 ]; then
    json_out="[]"
  else
    json_out=$(printf '%s\n' "$parsed_lines" | while IFS=$'\t' read -r _marker sev fil lin msg; do
      jq -nc \
        --arg severity "$sev" \
        --arg file "$fil" \
        --argjson line "$lin" \
        --arg message "$msg" \
        '{severity: $severity, file: $file, line: $line, message: $message}'
    done | jq -sc '.')
  fi

  printf '%s\n' "$json_out"

  # reconciliation check: bullet 総数 != parse 件数を検出した場合は WARN + rc=4。
  # ただし bullet 総数 0（`## 指摘事項` 見出し配下に bullet 行が 1 件も無い / 「指摘なし」
  # プレーン行のみのケース）は reconcile 対象外。
  if [ "$bullet_total" -gt 0 ] && [ "$bullet_total" -ne "$parsed_count" ]; then
    adj_warn "reconciliation mismatch: bullets=${bullet_total} parsed=${parsed_count}"
    return 4
  fi

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# adj_classify_findings: Claude adjudicator を 1 回呼び出し、各指摘に分類を付与
#   入力: $1 = pr_number
#         $2 = sha (head sha; 7〜40 桁 hex)
#         $3 = findings_json (adj_extract_findings 出力。JSON 配列文字列)
#         $4 = spec_dir_hint (絶対パス。空 / 不在なら `(none)` 埋め込み)
#         $5 = base_ref (省略時 `(none)`)
#         $6 = head_ref (省略時 `(none)`)
#   出力: stdout に [{"id":N,"severity":"...","file":"...","line":N,
#                     "verdict":"legitimate|excessive","reason":"..."}, ...] を含む
#         decisions JSON object（adjudicator-prompt.tmpl の出力契約と同形 /
#         `{"decisions":[...],"summary":{...}}`）
#   戻り値: 0 = ok / 1 = claude exec 失敗 (timeout / rc!=0 / prompt 解決失敗)
#           2 = JSON parse 失敗（claude 出力本文から JSON 抽出不能 / valid でない）
#           3 = workspace-modified 検出（read-only invariant 違反）
#
#   引数構成の根拠:
#     - design.md interface 表は厳密 4 引数だが、adjudicator-prompt.tmpl の `{BASE}` /
#       `{HEAD}` placeholder 流し込みのため base_ref / head_ref を追加引数 5,6 で受ける。
#     - `{REVIEW_TEXT}` placeholder は findings_json を `## 指摘事項` 形式に再構成して渡す。
#
#   アルゴリズム:
#     1. PR 番号 / SHA / base_ref / head_ref の shell metachar 検査
#        （review_text は claude prompt 本文に渡るのみで shell には展開されないため本関数では検査しない）。
#     2. PR 番号 = ^[0-9]+$ / SHA = ^[0-9a-f]{7,40}$ の strict 検証。
#     3. findings_json が `[]` / 空文字なら早期 return（`{"decisions":[],"summary":...}` rc=0）。
#     4. prompt 本文の解決順序:
#        a. `PR_REVIEWER_ADJUDICATOR_PROMPT` env が非空 → その値を本文として直接使う。
#        b. 空なら `$HOME/bin/idd-codex-adjudicator-prompt.tmpl` をファイルから読む（既定）。
#        c. ファイル不在 / HOME 解決不能 → adj_warn + rc=1。
#     5. プレースホルダ置換: `{PR}` / `{SHA}` / `{BASE}` / `{HEAD}` / `{REVIEW_TEXT}` /
#        `{SPEC_DIR}` / `{REQUIREMENTS_MD}` を bash パラメータ展開で置換。
#     6. mktemp で prompt 一時ファイル作成 + 本文書き込み（trap で削除）。
#     7. claude 起動: timeout + claude -p --output-format json --permission-mode plan --model。
#        `--permission-mode plan` は Claude 側で Bash / Edit / Write を構造的にブロックする
#        defense-in-depth（bypassPermissions 不使用）。
#     8. read-only invariant 検査: 実行直後に `git status --porcelain` でワークツリー変更
#        検出。検出時は `git checkout -- .` で tracked 変更を破棄し rc=3 を返す。
#     9. claude --output-format json は `{"type":"result","subtype":"success","result":"...", ...}`
#        を返す。`jq -r '.result // empty'` で本文を抜き、本文中の JSON を再 parse して stdout に流す。
#
#   注意: fallback モード（`PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL`）の適用は **呼び出し元
#         adj_run_for_pr の責務**。本関数は rc を返すだけ。
# ─────────────────────────────────────────────────────────────────────────────
adj_classify_findings() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local findings_json="${3:-}"
  local spec_dir_hint="${4:-}"
  local base_ref="${5:-}"
  local head_ref="${6:-}"

  # PR 番号 / SHA strict 検証（pr-reviewer.sh の hardening 踏襲）
  case "$pr_number" in
    ''|*[!0-9]*)
      adj_warn "adj_classify_findings: PR 番号が不正 (pr='${pr_number}')"
      return 1
      ;;
  esac
  if ! [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    adj_warn "adj_classify_findings: SHA が不正 (sha='${sha}')"
    return 1
  fi

  # shell metacharacter 検査（pr_number / sha / base / head に対し / review_text は対象外）
  local v
  for v in "$pr_number" "$sha" "$base_ref" "$head_ref"; do
    # shellcheck disable=SC2016  # 単一引用符内の $( は意図した「リテラル文字列の検出パターン」
    case "$v" in
      *';'* | *'|'* | *'&'* | *'`'* | *'$('* )
        adj_warn "adj_classify_findings: shell metacharacter 検出 (pr='${pr_number}' sha='${sha}' base='${base_ref}' head='${head_ref}')"
        return 1
        ;;
    esac
  done

  # findings_json 早期 return（空配列 / 空文字なら claude を起動しない）
  if [ -z "$findings_json" ] || [ "$findings_json" = "[]" ]; then
    printf '%s\n' '{"decisions":[],"summary":{"total":0,"legitimate":0,"excessive":0}}'
    return 0
  fi

  # findings_json valid JSON 配列か検証
  local findings_count
  if ! findings_count=$(printf '%s' "$findings_json" | jq -e 'if type=="array" then length else error("not-array") end' 2>/dev/null); then
    adj_warn "adj_classify_findings: findings_json が valid JSON 配列ではない"
    return 1
  fi
  if [ "$findings_count" -eq 0 ]; then
    printf '%s\n' '{"decisions":[],"summary":{"total":0,"legitimate":0,"excessive":0}}'
    return 0
  fi

  # prompt 本文の解決（env override → tmpl ファイル）
  local prompt_body=""
  if [ -n "${PR_REVIEWER_ADJUDICATOR_PROMPT:-}" ]; then
    prompt_body="${PR_REVIEWER_ADJUDICATOR_PROMPT}"
  else
    local home_dir="${HOME:-}"
    if [ -z "$home_dir" ]; then
      adj_warn "adj_classify_findings: HOME 解決不能のため idd-codex-adjudicator-prompt.tmpl を読めません"
      return 1
    fi
    local tmpl_path="${home_dir}/bin/idd-codex-adjudicator-prompt.tmpl"
    if [ ! -f "$tmpl_path" ]; then
      adj_warn "adj_classify_findings: ${tmpl_path} が存在しません"
      return 1
    fi
    if ! prompt_body=$(cat "$tmpl_path" 2>/dev/null); then
      adj_warn "adj_classify_findings: ${tmpl_path} の読み込みに失敗"
      return 1
    fi
  fi

  # {REVIEW_TEXT} 用に findings_json から `## 指摘事項` 形式の bullet 行を再構成。
  # 未信頼入力（codex 出力由来）は jq の --argjson でリテラル渡し、filter inline 展開禁止。
  local review_text_body
  review_text_body=$(printf '%s' "$findings_json" | jq -r '
    "## 指摘事項\n" +
    ([.[] | "- [\(.severity)] \(.file):\(.line) — \(.message)"] | join("\n"))
  ' 2>/dev/null) || {
    adj_warn "adj_classify_findings: findings_json から REVIEW_TEXT 再構成に失敗"
    return 1
  }

  # {SPEC_DIR} / {REQUIREMENTS_MD} 解決
  local spec_dir_val="(none)"
  local requirements_md_val="(none)"
  if [ -n "$spec_dir_hint" ] && [ -d "$spec_dir_hint" ]; then
    spec_dir_val="$spec_dir_hint"
    local req_path="${spec_dir_hint}/requirements.md"
    if [ -f "$req_path" ]; then
      requirements_md_val=$(cat "$req_path" 2>/dev/null) || requirements_md_val="(none)"
    fi
  fi

  # base / head の `(none)` 既定値
  local base_val="${base_ref:-(none)}"
  local head_val="${head_ref:-(none)}"
  [ -z "$base_val" ] && base_val="(none)"
  [ -z "$head_val" ] && head_val="(none)"

  # プレースホルダ置換（bash パラメータ展開 / 既存 pr_substitute_placeholders 流）
  local rendered="$prompt_body"
  rendered="${rendered//\{PR\}/$pr_number}"
  rendered="${rendered//\{SHA\}/$sha}"
  rendered="${rendered//\{BASE\}/$base_val}"
  rendered="${rendered//\{HEAD\}/$head_val}"
  rendered="${rendered//\{REVIEW_TEXT\}/$review_text_body}"
  rendered="${rendered//\{SPEC_DIR\}/$spec_dir_val}"
  rendered="${rendered//\{REQUIREMENTS_MD\}/$requirements_md_val}"

  # mktemp で prompt 一時ファイル / 出力 tempfile を作成し、trap で削除
  local prompt_file out_file err_file
  if ! prompt_file=$(mktemp -t idd-codex-adjudicator-prompt.XXXXXX 2>/dev/null); then
    adj_warn "adj_classify_findings: prompt 一時ファイル作成に失敗"
    return 1
  fi
  if ! out_file=$(mktemp -t idd-codex-adjudicator-out.XXXXXX 2>/dev/null); then
    rm -f "$prompt_file" 2>/dev/null || true
    adj_warn "adj_classify_findings: out tempfile 作成に失敗"
    return 1
  fi
  if ! err_file=$(mktemp -t idd-codex-adjudicator-err.XXXXXX 2>/dev/null); then
    rm -f "$prompt_file" "$out_file" 2>/dev/null || true
    adj_warn "adj_classify_findings: err tempfile 作成に失敗"
    return 1
  fi
  # shellcheck disable=SC2064
  trap "rm -f '$prompt_file' '$out_file' '$err_file' 2>/dev/null || true" RETURN

  printf '%s' "$rendered" > "$prompt_file"

  # claude CLI 起動。`--permission-mode plan` で write 系ツールを Claude 側でブロック
  # （bypassPermissions 不使用）。`eval` は使わず timeout + claude を直接呼ぶ。
  # adjudicator は claude（codex ではない）であるため、CLI 呼び出しは claude のまま。
  local exec_rc=0
  local timeout_s="${PR_REVIEWER_ADJUDICATOR_EXEC_TIMEOUT:-300}"
  local model="${PR_REVIEWER_ADJUDICATOR_MODEL:-claude-sonnet-4-5}"

  timeout "$timeout_s" claude \
    -p "$(cat "$prompt_file")" \
    --output-format json \
    --permission-mode plan \
    --model "$model" \
    >"$out_file" 2>"$err_file" || exec_rc=$?

  # read-only invariant 検査（実行直後 / pr_execute_review_command 流用）。
  # adjudicator は claude を read-only で起動するが、defense-in-depth として
  # ワークツリー変更を検出した場合は tracked 変更を破棄し rc=3 を返す。
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    git checkout -- . >/dev/null 2>&1 || true
    adj_warn "adj_classify_findings: workspace-modified を検出（read-only 違反）"
    return 3
  fi

  if [ "$exec_rc" -ne 0 ]; then
    local err_excerpt
    err_excerpt=$(tail -c 512 "$err_file" 2>/dev/null || true)
    adj_warn "adj_classify_findings: claude exec 失敗 (rc=${exec_rc}, err_tail='${err_excerpt}')"
    return 1
  fi

  # claude --output-format json の出力は SDK 標準フォーマット
  # `{"type":"result","subtype":"success","result":"<本文>", ...}` で、`result` フィールドに
  # adjudicator-prompt.tmpl の出力契約に従う JSON 本文が文字列として埋め込まれている。
  local result_body
  result_body=$(jq -r '.result // empty' "$out_file" 2>/dev/null) || {
    adj_warn "adj_classify_findings: claude 出力のトップレベル JSON parse 失敗"
    return 2
  }
  if [ -z "$result_body" ]; then
    adj_warn "adj_classify_findings: claude 出力に .result が含まれない"
    return 2
  fi

  # result 本文中に前置き散文や code fence が混入する case に備え、最初の `{` から
  # 最後の `}` までを雑に切り出す（防御的）。
  local stripped
  stripped=$(printf '%s' "$result_body" | awk '
    BEGIN { started = 0; depth = 0 }
    {
      for (i = 1; i <= length($0); i++) {
        ch = substr($0, i, 1)
        if (!started) {
          if (ch == "{") { started = 1; depth = 1; printf "%s", ch }
        } else {
          printf "%s", ch
          if (ch == "{") depth++
          else if (ch == "}") {
            depth--
            if (depth == 0) { printf "\n"; exit }
          }
        }
      }
      if (started) printf "\n"
    }
  ')

  # 最終 valid JSON 検証
  if ! printf '%s' "$stripped" | jq -e '.' >/dev/null 2>&1; then
    adj_warn "adj_classify_findings: 切り出した本文が valid JSON でない"
    return 2
  fi

  printf '%s\n' "$stripped"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# adj_validate_decisions: 分類 JSON の妥当性を schema 検証
#   入力: $1 = findings_json (adj_extract_findings 出力)
#         $2 = decisions_json (adj_classify_findings 出力。
#              `{"decisions":[...],"summary":{...}}` 形)
#   戻り値: 0 = valid / 1 = invalid（呼び出し元で fail-safe = 全件 legitimate に倒す /
#                                    Req 1.4「迷ったら legitimate」の徹底）
#   出力: stdout 出力なし。invalid 検出時のみ adj_warn を 1 行 stderr に出す。
#
#   検証項目（adjudicator-prompt.tmpl の出力契約 / design.md「Data Models」と整合）:
#     1. decisions_json が valid JSON object かつ `.decisions` が array で、
#        `.summary` が object であること
#     2. findings_json が `[]` / 空配列なら decisions も `[]` であること
#     3. `length(.decisions) == length(findings_json)`（件数一致 / Req 1.5）
#     4. 各 decisions 要素に `id` / `verdict` / `reason` が存在し、`verdict` が
#        `legitimate` または `excessive` 厳密一致であること
#     5. decisions の `id` フィールドが 1〜N の連番（軽い sanity check）
#     6. `summary.total == length(.decisions)` かつ
#        `summary.legitimate + summary.excessive == summary.total`
#
#   invalid 時の呼び出し元責務:
#     - 呼び出し元 adj_run_for_pr は本関数が rc=1 を返した場合、全 finding を legitimate と
#       扱う sentinel に倒す（Req 1.4 保守的判定の徹底）。
#     - 本関数自体は sentinel 値を返さない（rc のみで invalid を伝える）。
# ─────────────────────────────────────────────────────────────────────────────
adj_validate_decisions() {
  local findings_json="${1:-}"
  local decisions_json="${2:-}"

  # findings_json の件数算出（不正なら 0 扱い）
  local findings_count=0
  if [ -n "$findings_json" ]; then
    findings_count=$(printf '%s' "$findings_json" | jq -r 'if type=="array" then length else 0 end' 2>/dev/null) || findings_count=0
    case "$findings_count" in
      ''|*[!0-9]*) findings_count=0 ;;
    esac
  fi

  # decisions_json は valid JSON object でかつ `.decisions` が array、`.summary` が object か
  if [ -z "$decisions_json" ]; then
    adj_warn "validation failed: decisions_json が空"
    return 1
  fi
  if ! printf '%s' "$decisions_json" | jq -e 'type == "object" and (.decisions | type == "array") and (.summary | type == "object")' >/dev/null 2>&1; then
    adj_warn "validation failed: decisions_json が JSON object でないか .decisions/.summary 構造が不正"
    return 1
  fi

  local decisions_count
  decisions_count=$(printf '%s' "$decisions_json" | jq -r '.decisions | length' 2>/dev/null)
  case "$decisions_count" in
    ''|*[!0-9]*) decisions_count=0 ;;
  esac

  # findings が空 → decisions も空でなければ不整合
  if [ "$findings_count" -eq 0 ]; then
    if [ "$decisions_count" -ne 0 ]; then
      adj_warn "validation failed: findings 空だが decisions=${decisions_count} 件"
      return 1
    fi
    # findings 空 + decisions 空 → 妥当
    return 0
  fi

  # 件数一致（Req 1.5）
  if [ "$decisions_count" -ne "$findings_count" ]; then
    adj_warn "validation failed: 件数不一致 findings=${findings_count} decisions=${decisions_count}"
    return 1
  fi

  # 各 decisions 要素に id / verdict / reason が存在し、verdict が legitimate|excessive 厳密一致か
  if ! printf '%s' "$decisions_json" | jq -e '
    .decisions | all(
      (has("id") and (.id | type == "number")) and
      (has("verdict") and (.verdict == "legitimate" or .verdict == "excessive")) and
      (has("reason") and (.reason | type == "string"))
    )
  ' >/dev/null 2>&1; then
    adj_warn "validation failed: decisions 各要素の id/verdict/reason 検証失敗"
    return 1
  fi

  # id が 1〜N の連番（軽い sanity check / adjudicator-prompt.tmpl の id 採番規約と整合）
  if ! printf '%s' "$decisions_json" | jq -e --argjson n "$decisions_count" '
    ([.decisions[].id] | sort) == ([range(1; $n + 1)])
  ' >/dev/null 2>&1; then
    adj_warn "validation failed: id が 1〜${decisions_count} の連番でない"
    return 1
  fi

  # summary 検証: summary.total == decisions count / summary.legitimate + excessive == total
  if ! printf '%s' "$decisions_json" | jq -e --argjson n "$decisions_count" '
    (.summary.total == $n) and
    ((.summary.legitimate + .summary.excessive) == .summary.total) and
    (.summary.legitimate == ([.decisions[] | select(.verdict == "legitimate")] | length)) and
    (.summary.excessive == ([.decisions[] | select(.verdict == "excessive")] | length))
  ' >/dev/null 2>&1; then
    adj_warn "validation failed: summary 集計が decisions の verdict 集計と不整合"
    return 1
  fi

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# adj_apply_label_decision: 裁定結果に基づき codex-needs-iteration ラベルを add/remove
#   入力: $1 = pr_number, $2 = legitimate_count
#   出力: なし（log のみ）
#   戻り値: 0 = ok / 1 = ラベル操作失敗 / 2 = 入力検証失敗
#
#   Req: 2.1 (legitimate ≥1 で needs-iteration 付与/維持) /
#        2.2 (legitimate ゼロで needs-iteration 解消) /
#        2.3 (codex 失敗 = findings 空 = legitimate ゼロ経路でも本関数として一貫処理)
#
#   挙動:
#     - legitimate_count > 0 → `gh pr edit --add-label <needs-iteration>`（既付与で冪等 no-op）
#     - legitimate_count == 0 → `gh pr edit --remove-label <needs-iteration>`（未付与で冪等 no-op）
#     - gh の `--add-label` / `--remove-label` は既存ラベル / 不在ラベルに対しても idempotent。
#       追加前 / 削除前の現状確認は行わず、`gh` の冪等性に委ねる（pr_add_iteration_label の
#       既存設計と同方針）。
#     - 失敗時は WARN を 1 行残して rc=1 を返す。silent fail にしない（design.md Error Handling）。
# ─────────────────────────────────────────────────────────────────────────────
adj_apply_label_decision() {
  local pr_number="${1:-}"
  local legitimate_count="${2:-}"

  # 入力検証（pr_publish_commit_status と同方針）
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    adj_warn "adj_apply_label_decision: 無効な PR 番号 '${pr_number}'"
    return 2
  fi
  case "$legitimate_count" in
    ''|*[!0-9]*)
      adj_warn "adj_apply_label_decision: 無効な legitimate_count '${legitimate_count}'"
      return 2
      ;;
  esac

  local label="${LABEL_NEEDS_ITERATION:-codex-needs-iteration}"
  local timeout_s="${PR_REVIEWER_GIT_TIMEOUT:-120}"

  if [ "$legitimate_count" -gt 0 ]; then
    if ! timeout "$timeout_s" \
        gh pr edit "$pr_number" --repo "$REPO" --add-label "$label" >/dev/null 2>&1; then
      adj_warn "adj_apply_label_decision: PR #${pr_number}: ${label} 付与失敗"
      return 1
    fi
    adj_log "PR #${pr_number}: ${label} を付与（legitimate=${legitimate_count} / 既付与で冪等 no-op）"
  else
    if ! timeout "$timeout_s" \
        gh pr edit "$pr_number" --repo "$REPO" --remove-label "$label" >/dev/null 2>&1; then
      adj_warn "adj_apply_label_decision: PR #${pr_number}: ${label} 解消失敗"
      return 1
    fi
    adj_log "PR #${pr_number}: ${label} を解消（legitimate=0 / 未付与で冪等 no-op）"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# adj_read_reviewer_verdict: head_ref の review-notes.md 最終 verdict を読む
#   入力: $1 = head_ref（例: codex/issue-404-...）
#   出力: stdout に "approve" / "reject" / ""（不在 / RESULT 行不在）のいずれか
#   戻り値: 0 固定（不在 / 取得失敗は空文字列として返す）
#
#   Req: 3.3 / 3.5（Reviewer 先行優先 / Architecture Decision: claude-review publisher contention）
#
#   挙動:
#     - head_ref から issue 番号を抽出（`codex/issue-<N>-...`）。一致しなければ空文字列。
#     - `git ls-tree --name-only origin/<head_ref> -- docs/specs/` で <N>- 始まりの spec
#       ディレクトリを解決。
#     - `git show origin/<head_ref>:<spec>/review-notes.md` の中身を grep し、最終 `RESULT:`
#       行から approve / reject を抽出（design.md 関数 contract）。
#     - review-notes.md 不在 / RESULT 行不在は **空文字列**を返す（adjudicator は legitimate
#       件数のみで判定する経路へ落ちる / Behavior contract）。
#     - 取得失敗（ls-tree / cat-file / git show 失敗）も空文字列で返す（fail-safe）。
#
#   注: cwd は呼び出し元（idd-codex-issue-watcher.sh の processor 経路）で REPO_DIR を維持している前提。
#       本関数は git ls-tree / git show のみ呼び出し副作用なし。
# ─────────────────────────────────────────────────────────────────────────────
adj_read_reviewer_verdict() {
  local head_ref="${1:-}"

  if [ -z "$head_ref" ]; then
    printf '%s\n' ""
    return 0
  fi

  # head_ref から issue 番号を抽出
  local issue_number=""
  if [[ "$head_ref" =~ ^codex/issue-([0-9]+)- ]]; then
    issue_number="${BASH_REMATCH[1]}"
  fi
  if [ -z "$issue_number" ]; then
    printf '%s\n' ""
    return 0
  fi

  local timeout_s="${PR_REVIEWER_GIT_TIMEOUT:-120}"

  # spec dir を origin/<head_ref> の tree から解決
  local tree_out spec_dir_rel=""
  if ! tree_out=$(timeout "$timeout_s" \
      git ls-tree --name-only "origin/${head_ref}" -- "docs/specs/" 2>/dev/null); then
    printf '%s\n' ""
    return 0
  fi
  spec_dir_rel=$(printf '%s\n' "$tree_out" \
    | awk -v n="${issue_number}-" -F/ '$3 != "" && index($3, n) == 1 { print "docs/specs/" $3; exit }')
  if [ -z "$spec_dir_rel" ]; then
    printf '%s\n' ""
    return 0
  fi

  local notes_rel="${spec_dir_rel}/review-notes.md"

  # review-notes.md 存在確認（不在は空文字列で返す）
  if ! git cat-file -e "origin/${head_ref}:${notes_rel}" 2>/dev/null; then
    printf '%s\n' ""
    return 0
  fi

  # git show で内容を取得し、最終 `RESULT: approve|reject` 行を抽出。
  local notes_body
  if ! notes_body=$(git show "origin/${head_ref}:${notes_rel}" 2>/dev/null); then
    printf '%s\n' ""
    return 0
  fi
  if [ -z "$notes_body" ]; then
    printf '%s\n' ""
    return 0
  fi

  local matches last
  matches=$(printf '%s' "$notes_body" \
    | grep -oE 'RESULT:[[:space:]]+(approve|reject)([^[:alnum:]_]|$)' 2>/dev/null || true)
  if [ -z "$matches" ]; then
    printf '%s\n' ""
    return 0
  fi
  last=$(printf '%s\n' "$matches" | tail -n 1)
  case "$last" in
    *approve*) printf '%s\n' "approve" ;;
    *reject*)  printf '%s\n' "reject"  ;;
    *)         printf '%s\n' ""        ;;
  esac
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# adj_apply_status_decision: 裁定結果 + Reviewer verdict から claude-review status を publish
#   入力: $1 = pr_number, $2 = sha, $3 = legitimate_count, $4 = pr_url, $5 = head_ref
#   出力: なし（log は pr_publish_claude_status / pr_publish_commit_status 側で）
#   戻り値: pr_publish_claude_status の戻り値（0/1/2/3/4）
#
#   Req: 3.2 (claude-review publish 主体) / 3.3 (legitimate ゼロで success) /
#        3.4 (legitimate ≥1 で failure) / 3.5 (Reviewer reject で failure 強制 / 先行優先)
#
#   挙動（Architecture Decision: claude-review publisher contention / Reviewer 先行優先）:
#     1. `adj_read_reviewer_verdict <head_ref>` で Reviewer の最終 verdict を取得
#     2. verdict が "reject" → legitimate_count に依らず result="reject"（status=failure）を publish
#     3. それ以外（"approve" / "" 不在 / RESULT 行不在）→ legitimate_count で分岐:
#        - legitimate_count > 0 → result="reject"（failure）
#        - legitimate_count == 0 → result="approve"（success）
#     4. `pr_publish_claude_status` を流用（既存 idd-codex 関数 = claude-review context publisher / #108）
# ─────────────────────────────────────────────────────────────────────────────
adj_apply_status_decision() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local legitimate_count="${3:-}"
  local pr_url="${4:-}"
  local head_ref="${5:-}"

  # 入力検証（後段 pr_publish_commit_status でも検証されるが、ここで Reviewer 先行優先の
  # 経路に進む前に早期 reject しておく）
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    adj_warn "adj_apply_status_decision: 無効な PR 番号 '${pr_number}'"
    return 2
  fi
  if ! [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    adj_warn "adj_apply_status_decision: 無効な sha '${sha}'"
    return 2
  fi
  case "$legitimate_count" in
    ''|*[!0-9]*)
      adj_warn "adj_apply_status_decision: 無効な legitimate_count '${legitimate_count}'"
      return 2
      ;;
  esac

  # Reviewer 先行優先（Behavior contract 2 / Req 3.5）
  local reviewer_verdict
  reviewer_verdict=$(adj_read_reviewer_verdict "$head_ref" 2>/dev/null || true)

  local result
  if [ "$reviewer_verdict" = "reject" ]; then
    # 独立 Reviewer reject は legitimate 件数に依らず failure に倒す（上書き防止）
    result="reject"
    adj_log "PR #${pr_number}: Reviewer reject 検出（review-notes.md）→ claude-review=failure（legitimate=${legitimate_count} を上書き / 先行優先）"
  else
    # Reviewer 不在 / RESULT 行不在 / approve のいずれかなら legitimate 件数のみで verdict 決定
    if [ "$legitimate_count" -gt 0 ]; then
      result="reject"
      adj_log "PR #${pr_number}: legitimate=${legitimate_count} → claude-review=failure（Reviewer verdict='${reviewer_verdict}'）"
    else
      result="approve"
      adj_log "PR #${pr_number}: legitimate=0 → claude-review=success（Reviewer verdict='${reviewer_verdict}'）"
    fi
  fi

  # target_url は呼び出し元から渡された PR URL を流用（pr_publish_codex_status と対称）。
  pr_publish_claude_status "$pr_number" "$sha" "$result" "$pr_url"
  return $?
}

# ─────────────────────────────────────────────────────────────────────────────
# adj_post_decision_comment: 裁定結果サマリ + excessive 個別 marker を PR コメントに投稿
#   入力: $1 = pr_number, $2 = sha, $3 = findings_json, $4 = decisions_json
#   出力: なし（log のみ）
#   戻り値: 0 = ok（重複 skip 含む）/ 1 = 投稿失敗 / 2 = 入力検証失敗
#
#   Req: 4.1 (PR コメント or ログで観測可能) / 4.3 (hidden marker key の self-filter 非衝突) /
#        NFR 1.2 (excessive 個別 marker は pi_general_filter_excessive の入力キー)
#
#   挙動:
#     1. (sha, kind=decision) 重複チェック: `idd-codex:pr-adjudicator sha=<sha> kind=decision`
#        prefix で既存コメントを検査（pr_already_processed は `idd-codex:pr-reviewer` prefix
#        固定のため流用せず、同等の検査を adjudicator 専用 prefix でインライン）。
#     2. summary コメント本文を組み立て、末尾に hidden marker
#        `<!-- idd-codex:pr-adjudicator sha=<sha> kind=decision -->` を付与して投稿
#     3. excessive と判定された finding ごとに hidden marker
#        `<!-- idd-codex:pr-adjudicator-excessive id=<N> sha=<sha> -->` を含む追加コメントを
#        1 件投稿（pi 側 self-filter のキーとして使う / NFR 1.2）。
#
#   prefix 設計（design.md Data Models）:
#     - `pr-adjudicator` prefix は既存 `pr-reviewer` / `pr-iteration` のいずれとも前方一致
#       しない（self-filter 規約と非衝突 / Req 4.3）。
# ─────────────────────────────────────────────────────────────────────────────
adj_post_decision_comment() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local findings_json="${3:-}"
  local decisions_json="${4:-}"

  # 入力検証
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    adj_warn "adj_post_decision_comment: 無効な PR 番号 '${pr_number}'"
    return 2
  fi
  if ! [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    adj_warn "adj_post_decision_comment: 無効な sha '${sha}'"
    return 2
  fi

  local timeout_s="${PR_REVIEWER_GIT_TIMEOUT:-120}"

  # ── 重複判定: 既存コメントに同 (sha, kind=decision) marker が在れば skip ──
  # 同等の検査を `idd-codex:pr-adjudicator` prefix で行う（jq --arg でリテラル渡し）。
  local comments_json
  if comments_json=$(timeout "$timeout_s" \
      gh api "/repos/${REPO}/issues/${pr_number}/comments" 2>/dev/null); then
    if echo "$comments_json" | jq -e \
        --arg sha "$sha" \
        'any(.[]; (.body // "") | test("idd-codex:pr-adjudicator sha=" + $sha + "[^>]*kind=decision"))' \
        >/dev/null 2>&1; then
      adj_log "PR #${pr_number}: 裁定コメント既存（sha=${sha} kind=decision）→ 再投稿 skip"
      return 0
    fi
  else
    # 取得失敗時は安全側（重複投稿回避）に倒し既存扱いで skip（pr_already_processed と同方針）
    adj_warn "PR #${pr_number}: 既存コメント取得失敗（重複判定を skip = 安全側で既存扱い）"
    return 0
  fi

  # ── サマリコメント本文の組み立て ──
  # decisions_json から legitimate / excessive 件数とサマリ表を組み立てる。
  local total legitimate excessive
  total=$(printf '%s' "$decisions_json" | jq -r '.summary.total // 0' 2>/dev/null || echo "0")
  legitimate=$(printf '%s' "$decisions_json" | jq -r '.summary.legitimate // 0' 2>/dev/null || echo "0")
  excessive=$(printf '%s' "$decisions_json" | jq -r '.summary.excessive // 0' 2>/dev/null || echo "0")
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  case "$legitimate" in ''|*[!0-9]*) legitimate=0 ;; esac
  case "$excessive" in ''|*[!0-9]*) excessive=0 ;; esac

  local summary_body
  summary_body=$(printf '## 自動裁定サマリ\n\n- total: %s\n- legitimate: %s\n- excessive: %s\n\n<!-- idd-codex:pr-adjudicator sha=%s kind=decision -->\n' \
    "$total" "$legitimate" "$excessive" "$sha")

  if ! timeout "$timeout_s" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$summary_body" >/dev/null 2>&1; then
    adj_warn "PR #${pr_number}: 裁定サマリコメント投稿失敗（sha=${sha}）"
    return 1
  fi
  adj_log "PR #${pr_number}: 裁定サマリコメント投稿（sha=${sha} total=${total} legit=${legitimate} excess=${excessive}）"

  # ── excessive 個別 marker コメントの投稿 ──
  # findings_json と decisions_json を id で突合し、verdict=excessive のものに対して
  # 1 件ずつ marker 付きコメントを投稿する（pi 側 self-filter のキー / NFR 1.2）。
  if [ "$excessive" -gt 0 ]; then
    local excessive_rows
    # excessive な decisions の (id, severity, file, line, reason) を TSV 化
    excessive_rows=$(printf '%s' "$decisions_json" | jq -r '
      .decisions
      | map(select(.verdict == "excessive"))
      | .[]
      | [ (.id | tostring), (.severity // ""), (.file // ""), ((.line // 0) | tostring), (.reason // "") ]
      | @tsv
    ' 2>/dev/null) || excessive_rows=""

    if [ -n "$excessive_rows" ]; then
      while IFS=$'\t' read -r fid fseverity ffile fline freason; do
        [ -z "$fid" ] && continue
        local body
        body=$(printf '## 自動裁定: excessive\n\n- id: %s\n- severity: %s\n- file: %s\n- line: %s\n- 理由: %s\n\n<!-- idd-codex:pr-adjudicator-excessive id=%s sha=%s -->\n' \
          "$fid" "$fseverity" "$ffile" "$fline" "$freason" "$fid" "$sha")
        if ! timeout "$timeout_s" \
            gh pr comment "$pr_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
          adj_warn "PR #${pr_number}: excessive marker コメント投稿失敗（id=${fid} sha=${sha}）"
          # 個別 marker 投稿失敗は致命的ではないため、サマリは投稿済みのまま続行
          continue
        fi
        adj_log "PR #${pr_number}: excessive marker 投稿（id=${fid} sha=${sha}）"
      done <<<"$excessive_rows"
    fi
  fi

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# adj_resolve_spec_dir_from_head_ref: head_ref から docs/specs/<N>-<slug>/ 絶対パスを解決
#   入力: $1 = head_ref（例: codex/issue-404-impl-foo）
#   出力: stdout に絶対パス（`pwd` 基準で resolve）または空文字列（不在 / 解決不能時）
#   戻り値: 0 固定（fail-safe / 解決不能でも空文字列で返す）
#
#   挙動:
#     - head_ref から issue 番号を抽出（`codex/issue-<N>-...`）。一致しなければ空文字列。
#     - `git ls-tree --name-only origin/<head_ref> -- docs/specs/` で <N>- 始まりの spec
#       ディレクトリを解決。
#     - 解決された相対パスを cwd 基準で結合して絶対パス相当を返す。
#     - 取得失敗 / 不在は空文字列で返す（fail-safe）。
#
#   注: 本関数は read-only（git ls-tree のみ）で副作用なし。cwd が REPO_DIR であることを前提とする
#       （pr-reviewer.sh からの hook 呼び出し時点で REPO_DIR / NFR 1.1）。
# ─────────────────────────────────────────────────────────────────────────────
adj_resolve_spec_dir_from_head_ref() {
  local head_ref="${1:-}"
  if [ -z "$head_ref" ]; then
    printf '%s\n' ""
    return 0
  fi

  local issue_number=""
  if [[ "$head_ref" =~ ^codex/issue-([0-9]+)- ]]; then
    issue_number="${BASH_REMATCH[1]}"
  fi
  if [ -z "$issue_number" ]; then
    printf '%s\n' ""
    return 0
  fi

  local timeout_s="${PR_REVIEWER_GIT_TIMEOUT:-120}"
  local tree_out spec_dir_rel=""
  if ! tree_out=$(timeout "$timeout_s" \
      git ls-tree --name-only "origin/${head_ref}" -- "docs/specs/" 2>/dev/null); then
    printf '%s\n' ""
    return 0
  fi
  spec_dir_rel=$(printf '%s\n' "$tree_out" \
    | awk -v n="${issue_number}-" -F/ '$3 != "" && index($3, n) == 1 { print "docs/specs/" $3; exit }')
  if [ -z "$spec_dir_rel" ]; then
    printf '%s\n' ""
    return 0
  fi

  # 相対パスを cwd 基準で絶対化（pwd は呼び出し元 REPO_DIR の前提）
  local cwd
  cwd=$(pwd 2>/dev/null) || cwd=""
  if [ -n "$cwd" ]; then
    printf '%s\n' "${cwd}/${spec_dir_rel}"
  else
    printf '%s\n' "$spec_dir_rel"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# adj_log_summary: 裁定 1 行サマリを観測ログに出力
#   入力: $1 = pr_number, $2 = sha, $3 = total, $4 = legitimate, $5 = excessive
#   出力: adj_log 1 行のみ（NFR 1.1 観測ログ 10 行以内に収める集計形式 / Req 4.2）
#   戻り値: 0 固定
# ─────────────────────────────────────────────────────────────────────────────
adj_log_summary() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local total="${3:-0}"
  local legitimate="${4:-0}"
  local excessive="${5:-0}"
  adj_log "裁定サマリ pr=#${pr_number} sha=${sha} total=${total} legitimate=${legitimate} excessive=${excessive}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# adj_synthesize_all_legitimate_decisions: fallback 用に「全 finding を legitimate と扱う」
#   decisions JSON を合成する（Req 1.4「迷ったら legitimate」の徹底）
#   入力: $1 = findings_json (adj_extract_findings 出力)
#   出力: stdout に `{"decisions":[...全件 legitimate...],"summary":{...}}` を流す
#   戻り値: 0 = ok / 1 = findings_json が不正
#
#   用途:
#     - adj_classify_findings 失敗（rc=1/2/3）/ adj_validate_decisions 失敗（rc=1）/
#       adj_extract_findings reconciliation mismatch（rc=4）時、`legitimate` fallback モードで
#       「全 finding を legitimate 扱い」に倒すための合成 decisions を生成する。
#     - adj_post_decision_comment / adj_apply_status_decision の入力契約に揃える。
# ─────────────────────────────────────────────────────────────────────────────
adj_synthesize_all_legitimate_decisions() {
  local findings_json="${1:-[]}"

  # findings_json が valid JSON 配列か検証
  if ! printf '%s' "$findings_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    return 1
  fi

  printf '%s' "$findings_json" | jq -c '
    . as $f
    | (length) as $n
    | {
        decisions: [
          range(0; $n) as $i
          | {
              id: ($i + 1),
              severity: ($f[$i].severity // ""),
              file: ($f[$i].file // ""),
              line: ($f[$i].line // 0),
              verdict: "legitimate",
              reason: "fallback: 確信が持てないため legitimate に倒す（Req 1.4）"
            }
        ],
        summary: { total: $n, legitimate: $n, excessive: 0 }
      }
  '
}

# ─────────────────────────────────────────────────────────────────────────────
# adj_run_for_pr: 1 PR 分の adjudicator フローをオーケストレートする
#   入力: $1 = pr_number, $2 = sha, $3 = review_text（codex stdout 全文。空 = codex 失敗）,
#         $4 = pr_url, $5 = head_ref
#   出力: adj_log によるサマリ 1 行（NFR 1.1 / Req 4.2）と各内部関数のログ
#   戻り値: 常に 0（呼び出し元 pr_run_review_for_pr は `|| adj_warn` で吸収するが、本関数
#           自身も fail-safe で非ゼロ exit を伝搬しない / Invariants）
#
#   Req: 2.6, 3.1, 3.2, 3.6, 4.2, 5.2, 5.4 / NFR 1.1, NFR 2.1
#
#   フロー（design.md sequenceDiagram / Components and Interfaces 節 + Error Handling 節）:
#     0. gate OFF → 即 return 0（NFR 2.1 観測ログ diff ゼロ）
#     1. review_text 空（codex exec-failed）→ findings ゼロ経路へ合流（Req 2.3 / 3.6）
#     2. adj_extract_findings → rc=4（reconciliation mismatch）→ fallback モード適用
#     3. findings ゼロ → label remove + status publish（Reviewer 先行優先は内部で処理）
#     4. MAX_FINDINGS で truncate（コスト抑制 / WARN 1 行）
#     5. adj_classify_findings → rc=1/2/3 → fallback モード適用
#     6. adj_validate_decisions → rc=1 → fallback モード適用
#     7. 正常経路: adj_apply_label_decision → adj_apply_status_decision → adj_post_decision_comment
#     8. adj_log_summary で 1 行サマリ
#
#   fallback モード（PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL）:
#     - passthrough（既定）: publish / label / marker を全て skip（idd-codex は catch-up を
#       移植していないため、単に adjudicator を実行しなかったかのように扱い、既存 #108 2nd gate /
#       独立 Reviewer の verdict を尊重する経路に委ねる）。
#     - legitimate: 全 finding を legitimate 扱い（needs-iteration 維持 + claude-review=failure）
# ─────────────────────────────────────────────────────────────────────────────
adj_run_for_pr() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local review_text="${3:-}"
  local pr_url="${4:-}"
  local head_ref="${5:-}"

  # 0. gate OFF 早期 return（NFR 2.1 完全 no-op / gh / claude / log 発火ゼロ）
  if ! adj_gate_enabled; then
    return 0
  fi

  # 入力検証（後段 publisher でも検証されるが、早期 reject）
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    adj_warn "adj_run_for_pr: 無効な PR 番号 '${pr_number}'"
    return 0
  fi
  if ! [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    adj_warn "adj_run_for_pr: 無効な sha '${sha}'"
    return 0
  fi

  local fallback_mode="${PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL:-passthrough}"

  # 1. review_text 空（codex exec-failed）→ findings ゼロ経路へ合流（Req 2.3 / 3.6）
  if [ -z "$review_text" ]; then
    adj_log "PR #${pr_number}: codex review_text 空（codex exec-failed）→ findings ゼロ経路（Req 3.6）"
    adj_apply_label_decision "$pr_number" "0" || true
    adj_apply_status_decision "$pr_number" "$sha" "0" "$pr_url" "$head_ref" || true
    adj_log_summary "$pr_number" "$sha" "0" "0" "0"
    return 0
  fi

  # 2. findings 抽出（reconciliation check 内蔵）
  local findings_json findings_rc=0
  findings_json=$(adj_extract_findings "$review_text") || findings_rc=$?

  if [ "$findings_rc" -eq 4 ]; then
    # reconciliation mismatch → fallback モード適用
    adj_warn "PR #${pr_number}: findings reconciliation mismatch → fallback=${fallback_mode}"
    if [ "$fallback_mode" = "legitimate" ]; then
      # 全件 legitimate に倒して publish 経路へ
      local synth_decisions
      if synth_decisions=$(adj_synthesize_all_legitimate_decisions "$findings_json" 2>/dev/null); then
        local total leg
        total=$(printf '%s' "$synth_decisions" | jq -r '.summary.total // 0' 2>/dev/null || echo "0")
        leg=$(printf '%s' "$synth_decisions" | jq -r '.summary.legitimate // 0' 2>/dev/null || echo "0")
        case "$total" in ''|*[!0-9]*) total=0 ;; esac
        case "$leg" in ''|*[!0-9]*) leg=0 ;; esac
        adj_apply_label_decision "$pr_number" "$leg" || true
        adj_apply_status_decision "$pr_number" "$sha" "$leg" "$pr_url" "$head_ref" || true
        adj_post_decision_comment "$pr_number" "$sha" "$findings_json" "$synth_decisions" || true
        adj_log_summary "$pr_number" "$sha" "$total" "$leg" "0"
      else
        adj_warn "PR #${pr_number}: fallback=legitimate 経路で decisions 合成失敗 → skip"
      fi
    else
      adj_log "PR #${pr_number}: fallback=passthrough → adjudicator skip（publish / label / marker なし）"
    fi
    return 0
  fi

  # findings_json は valid JSON 配列のはず（adj_extract_findings の契約）
  local findings_count
  findings_count=$(printf '%s' "$findings_json" | jq -r 'if type=="array" then length else 0 end' 2>/dev/null || echo "0")
  case "$findings_count" in ''|*[!0-9]*) findings_count=0 ;; esac

  # 3. findings ゼロ経路（指摘なし / `## 指摘事項` 不在 等。codex VERDICT 経路の通常成功ケース）
  if [ "$findings_count" -eq 0 ]; then
    adj_apply_label_decision "$pr_number" "0" || true
    adj_apply_status_decision "$pr_number" "$sha" "0" "$pr_url" "$head_ref" || true
    adj_log_summary "$pr_number" "$sha" "0" "0" "0"
    return 0
  fi

  # 4. MAX_FINDINGS で truncate（コスト抑制 / WARN 1 行）
  local max_findings="${PR_REVIEWER_ADJUDICATOR_MAX_FINDINGS:-50}"
  case "$max_findings" in ''|*[!0-9]*) max_findings=50 ;; esac
  if [ "$findings_count" -gt "$max_findings" ]; then
    adj_warn "PR #${pr_number}: findings_count=${findings_count} > MAX=${max_findings} → 先頭 ${max_findings} 件に truncate"
    findings_json=$(printf '%s' "$findings_json" | jq -c --argjson n "$max_findings" '.[0:$n]')
    findings_count="$max_findings"
  fi

  # 5. spec_dir / base_ref / head_ref を解決して classify 呼び出し
  local spec_dir
  spec_dir=$(adj_resolve_spec_dir_from_head_ref "$head_ref")
  local base_ref="${BASE_BRANCH:-main}"

  local decisions_json classify_rc=0
  decisions_json=$(adj_classify_findings "$pr_number" "$sha" "$findings_json" "$spec_dir" "$base_ref" "$head_ref") || classify_rc=$?

  if [ "$classify_rc" -ne 0 ]; then
    # rc=1/2/3 すべて fallback モード適用
    adj_warn "PR #${pr_number}: adj_classify_findings 失敗 (rc=${classify_rc}) → fallback=${fallback_mode}"
    if [ "$fallback_mode" = "legitimate" ]; then
      local synth_decisions
      if synth_decisions=$(adj_synthesize_all_legitimate_decisions "$findings_json" 2>/dev/null); then
        local total leg
        total=$(printf '%s' "$synth_decisions" | jq -r '.summary.total // 0' 2>/dev/null || echo "0")
        leg=$(printf '%s' "$synth_decisions" | jq -r '.summary.legitimate // 0' 2>/dev/null || echo "0")
        case "$total" in ''|*[!0-9]*) total=0 ;; esac
        case "$leg" in ''|*[!0-9]*) leg=0 ;; esac
        adj_apply_label_decision "$pr_number" "$leg" || true
        adj_apply_status_decision "$pr_number" "$sha" "$leg" "$pr_url" "$head_ref" || true
        adj_post_decision_comment "$pr_number" "$sha" "$findings_json" "$synth_decisions" || true
        adj_log_summary "$pr_number" "$sha" "$total" "$leg" "0"
      else
        adj_warn "PR #${pr_number}: fallback=legitimate 経路で decisions 合成失敗 → skip"
      fi
    else
      adj_log "PR #${pr_number}: fallback=passthrough → adjudicator skip（publish / label / marker なし）"
    fi
    return 0
  fi

  # 6. validate（Req 1.5 件数一致 / verdict / summary 整合）
  if ! adj_validate_decisions "$findings_json" "$decisions_json"; then
    adj_warn "PR #${pr_number}: adj_validate_decisions 失敗 → fallback=${fallback_mode}"
    if [ "$fallback_mode" = "legitimate" ]; then
      local synth_decisions
      if synth_decisions=$(adj_synthesize_all_legitimate_decisions "$findings_json" 2>/dev/null); then
        local total leg
        total=$(printf '%s' "$synth_decisions" | jq -r '.summary.total // 0' 2>/dev/null || echo "0")
        leg=$(printf '%s' "$synth_decisions" | jq -r '.summary.legitimate // 0' 2>/dev/null || echo "0")
        case "$total" in ''|*[!0-9]*) total=0 ;; esac
        case "$leg" in ''|*[!0-9]*) leg=0 ;; esac
        adj_apply_label_decision "$pr_number" "$leg" || true
        adj_apply_status_decision "$pr_number" "$sha" "$leg" "$pr_url" "$head_ref" || true
        adj_post_decision_comment "$pr_number" "$sha" "$findings_json" "$synth_decisions" || true
        adj_log_summary "$pr_number" "$sha" "$total" "$leg" "0"
      else
        adj_warn "PR #${pr_number}: fallback=legitimate 経路で decisions 合成失敗 → skip"
      fi
    else
      adj_log "PR #${pr_number}: fallback=passthrough → adjudicator skip（publish / label / marker なし）"
    fi
    return 0
  fi

  # 7. 正常経路（label → status → comment）
  local total legitimate excessive
  total=$(printf '%s' "$decisions_json" | jq -r '.summary.total // 0' 2>/dev/null || echo "0")
  legitimate=$(printf '%s' "$decisions_json" | jq -r '.summary.legitimate // 0' 2>/dev/null || echo "0")
  excessive=$(printf '%s' "$decisions_json" | jq -r '.summary.excessive // 0' 2>/dev/null || echo "0")
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  case "$legitimate" in ''|*[!0-9]*) legitimate=0 ;; esac
  case "$excessive" in ''|*[!0-9]*) excessive=0 ;; esac

  adj_apply_label_decision "$pr_number" "$legitimate" || true
  adj_apply_status_decision "$pr_number" "$sha" "$legitimate" "$pr_url" "$head_ref" || true
  adj_post_decision_comment "$pr_number" "$sha" "$findings_json" "$decisions_json" || true

  # 8. 1 行サマリ（NFR 1.1 観測ログ ≤10 行 / Req 4.2）
  adj_log_summary "$pr_number" "$sha" "$total" "$legitimate" "$excessive"
  return 0
}
