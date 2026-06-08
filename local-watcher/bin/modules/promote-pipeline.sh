#!/usr/bin/env bash
# shellcheck shell=bash
# promote-pipeline.sh — watcher の Promote Pipeline + Path Overlap プロセッサモジュール
#
# 用途:
#   idd-codex-issue-watcher.sh から切り出した 2 つの processor 群の関数定義を集約する。
#   - Promote Pipeline (#15): ST base 昇格パイプライン。Phase A により BASE_BRANCH に
#     merge された変更について ST check-run 結果をポーリングし、success なら
#     PROMOTION_TARGET_BRANCH への fast-forward 昇格、failure なら git revert + reopen +
#     codex-st-failed 付与を行う（PROMOTE_PIPELINE_ENABLED=true の opt-in 機能）。
#     pp_resolve_target_branch / pp_collect_merged_issues / pp_get_st_state /
#     pp_handle_st_failure / pp_handle_st_success / pp_do_promote / process_promote_pipeline ほか。
#   - Path Overlap Checker (#18, Phase E): 同サイクル内 dispatch 競合予防・待機。
#     Triage 結果の edit_paths を永続化し、in-flight Issue と top-level path が重複する
#     場合に codex-awaiting-slot ラベルを付与して dispatch を見送る。
#     po_parse_triage_edit_paths / po_compute_overlap / po_check_dispatch_gate /
#     po_apply_awaiting_slot / po_clear_awaiting_slot ほか。
#   Path Overlap (po_*) は独立モジュール化せず本モジュールへ同居させる（#181 design.md
#   decision 3。元コードで po_* は pp_* 定義群の物理的内部に挟まれていた経緯と Part 1
#   境界マップの同居指定に従う）。
#
# 配置先:
#   $HOME/bin/modules/promote-pipeline.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは idd-codex-issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー pp_log / pp_warn / pp_error は core_utils.sh に定義済みのため本モジュールでは
#     再定義しない（#180 Part 2 で core_utils.sh へ集約済み）。po_log / po_warn は本体由来の
#     ため本モジュールへ移す。
#   - グローバル変数（$REPO / $BASE_BRANCH / $PROMOTION_TARGET_BRANCH / $PROMOTE_MODE /
#     $PROMOTE_PIPELINE_ENABLED / $PATH_OVERLAP_CHECK / $LABEL_STAGED_FOR_RELEASE /
#     $LABEL_ST_FAILED 等）は本体冒頭の Config ブロックで定義済み。bash の遅延束縛により
#     呼び出し時に解決される。
#   - top-level orchestration 呼び出し配線（process_promote_pipeline || pp_warn ...）は
#     本体 entry point に残置する（本モジュールは関数定義のみ / #181 design.md）。
#   - dispatcher が po_check_dispatch_gate を、本モジュール内部から po_apply/clear_awaiting_slot を呼ぶ。
#   - 外部 CLI: gh / git / jq。
#
# セットアップ参照先:
#   - 設計: docs/specs/181-feat-watcher-issue-watcher-sh-part-3-pr/design.md
#   - README「Phase B Promote Pipeline」「Path Overlap Checker (Phase E)」節

po_log() {
  echo "[$(date '+%F %T')] [$REPO] path-overlap: $*"
}
po_warn() {
  echo "[$(date '+%F %T')] [$REPO] path-overlap: WARN: $*" >&2
}

# ─── Phase E: Triage Edit-Paths Parser (#18 Req 2.4 / 2.5) ───
# Triage 結果 JSON から edit_paths 配列を fail-safe に抽出する。
# - key 不在 / null / 非配列 / 要素に文字列以外混入はすべて空配列にフォールバック
# - 既存 5 keys 抽出（jq -r '.status' 等）は変更しない（Req 2.5）
#
# Args: $1 = Triage 結果 JSON ファイルパス
# Stdout: JSON 配列文字列（必ず `[...]` 形式、空でも `[]`）
# Return: 0 always（失敗時は `[]` を返す fail-safe）
po_parse_triage_edit_paths() {
  local triage_file="$1"
  if [ ! -f "$triage_file" ]; then
    echo '[]'
    return 0
  fi
  # `// []` で key 不在を吸収、`if type=="array" then ... else [] end` で型不正吸収、
  # `map(select(type=="string"))` で文字列以外を除外。jq 失敗時も `[]` を返す。
  jq -c '
    (.edit_paths // [])
    | if type == "array" then
        map(select(type == "string"))
      else
        []
      end
  ' "$triage_file" 2>/dev/null || echo '[]'
}

# ─── Phase E: Path Overlap Persister (#18 Req 3.1〜3.4 / 12.1) ───
# Triage で得た edit_paths を Issue 上に sticky comment として保存する。同じ marker
# (<!-- idd-codex:edit-paths:v1 -->) を持つ既存コメントがあれば PATCH で上書き、
# 無ければ新規 create する（Req 3.3 重複防止）。
#
# 本文形式（人間可読 md リスト + 機械可読 hidden JSON marker の 2 段構成）:
#
#   ## Triage edit_paths（Phase E）
#
#   本 Issue が編集見込みの top-level path:
#
#   - `local-watcher/`
#   - `README.md`
#
#   *(自動生成: Path Overlap Checker。本機能の詳細は README の「Phase E」節を参照)*
#
#   <!-- idd-codex:edit-paths:v1 -->
#   <!-- idd-codex:edit-paths-json:["local-watcher/","README.md"] -->
#
# Args: $1 = issue number, $2 = edit_paths JSON 配列文字列
# Return: 0 = persist OK / 1 = persist 失敗（呼び出し側は warn のみで Triage 全体は成功扱い）
po_persist_edit_paths() {
  local issue_number="$1"
  local edit_paths_json="$2"

  # 本文 md リストを組み立てる（空配列なら "なし" 表示）
  local list_md
  list_md=$(echo "$edit_paths_json" | jq -r '
    if length == 0 then
      "_(Triage は確信のある edit_paths を推定できませんでした)_"
    else
      map("- `" + . + "`") | join("\n")
    end
  ' 2>/dev/null || echo '_(edit_paths 抽出失敗)_')

  local marker_v1="<!-- idd-codex:edit-paths:v1 -->"
  local json_marker
  # JSON marker を 1 行に整形（jq -c で改行なしの compact 形式）
  json_marker="<!-- idd-codex:edit-paths-json:${edit_paths_json} -->"

  local body
  read -r -d '' body <<EOF || true
## Triage edit_paths（Phase E）

本 Issue が編集見込みの top-level path:

${list_md}

*(自動生成: Path Overlap Checker。本機能の詳細は README の「Phase E」節を参照)*

${marker_v1}
${json_marker}
EOF

  # 既存 sticky comment を gh API で検索（URL 末尾の `#issuecomment-<numeric-id>` から
  # REST API id を抽出。`.comments[].id` は GraphQL の base64 id なので使えない）。
  local comments_json
  if ! comments_json=$(gh issue view "$issue_number" --repo "$REPO" --json comments 2>/dev/null); then
    return 1
  fi
  local existing_url
  existing_url=$(echo "$comments_json" | jq -r '
    (.comments // [])
    | map(select(.body | contains("<!-- idd-codex:edit-paths:v1 -->")))
    | .[0].url // ""
  ' 2>/dev/null || echo "")
  local existing_comment_id=""
  if [ -n "$existing_url" ]; then
    existing_comment_id=$(printf '%s' "$existing_url" \
      | sed -nE 's/.*#issuecomment-([0-9]+)$/\1/p')
  fi

  if [ -n "$existing_comment_id" ]; then
    # 既存 sticky comment を PATCH で上書き（Req 3.3）
    if ! gh api -X PATCH "/repos/${REPO}/issues/comments/${existing_comment_id}" \
        -f body="$body" >/dev/null 2>&1; then
      return 1
    fi
  else
    # 新規作成
    if ! gh issue comment "$issue_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
      return 1
    fi
  fi
  return 0
}

# ─── Phase E: Path Overlap Loader (#18 Req 12.1) ───
# Issue の sticky comment から edit_paths JSON を読み出す。marker 不在 / API 失敗 /
# 形式異常はすべて空配列 `[]` を返す fail-safe。
# 1 candidate あたり gh issue view --json comments を **1 回のみ** 呼ぶ（Req 12.1）。
#
# Args: $1 = issue number
# Stdout: edit_paths JSON 配列文字列（必ず `[...]` 形式、抽出失敗時は `[]`）
# Return: 0 always
po_load_edit_paths() {
  local issue_number="$1"
  local comments_json
  if ! comments_json=$(gh issue view "$issue_number" --repo "$REPO" --json comments 2>/dev/null); then
    echo '[]'
    return 0
  fi
  # 全コメントから marker 行を抽出 → JSON 部を取り出して valid array かチェック
  local extracted
  extracted=$(echo "$comments_json" \
    | jq -r '.comments // [] | map(.body) | .[]' 2>/dev/null \
    | sed -nE 's/.*<!-- idd-codex:edit-paths-json:(.*) -->.*/\1/p' \
    | tail -1)
  if [ -z "$extracted" ]; then
    echo '[]'
    return 0
  fi
  # extracted が valid な JSON 配列であることを jq で再検証してから返す
  local validated
  validated=$(echo "$extracted" | jq -c '
    if type == "array" then
      map(select(type == "string"))
    else
      []
    end
  ' 2>/dev/null || echo '[]')
  echo "$validated"
}

# ─── Phase E: Holder Label Set Resolver (#221 Req 1.1 / 2.1 / 3.1〜3.3 / 4.1 / NFR1.1) ───
# 呼び出しコンテキストと branch 設定から、in-flight holder とみなすラベル集合を CSV で返す。
# holder の本質は「dispatch 先 base ブランチにまだ取り込まれていない作業」であるため、
# multi-branch（gitflow）運用の dispatch 文脈では develop 統合済みの `codex-staged-for-release` を
# holder から除外する。それ以外（promote / single-branch / 判定不能）は full 集合を返す。
#
# holder 集合決定の真理値表（design.md D3）:
#   context    | BASE_BRANCH vs PROMOTION_TARGET_BRANCH | 返す集合
#   dispatch   | != （multi-branch / gitflow）          | 6 ラベル（codex-staged-for-release 除外）… Req 1.1
#   dispatch   | == （single-branch）                   | 7 ラベル（full / ゼロ差分）       … NFR 1.1
#   promote    | （不問）                               | 7 ラベル（full / SfR 維持）        … Req 2.1
#   不明な値    | （不問）                               | 7 ラベル（full / fail-safe）       … Req 4.1
#
# invariants: 返す CSV は常に 6 基本ラベル
#   codex-claimed / codex-picked-up / codex-awaiting-design-review / codex-ready-for-review /
#   codex-needs-iteration / codex-needs-rebase
# を含む（NFR 1.2）。コンテキストで変動するのは `codex-staged-for-release` の有無のみ。
#
# Args:
#   $1 = context（"dispatch" | "promote"）
# Stdout: holder ラベル CSV（空白なしカンマ区切り。dispatch×multi-branch では
#         codex-staged-for-release を含まない）
# Return: 0 always（判定不能でも full 集合を返す fail-safe / Req 4.1）
po_resolve_holder_labels() {
  local context="${1:-}"

  # 6 基本ラベルは常時集合内（NFR 1.2 invariant）。`$LABEL_*` 定数は本体 Config ブロックで
  # 束縛済みだが、未束縛時にも安全側へ倒すため `:-` で既定リテラルへ fallback する。
  local base_labels
  base_labels="${LABEL_CLAIMED:-codex-claimed},${LABEL_PICKED:-codex-picked-up},${LABEL_AWAITING_DESIGN:-codex-awaiting-design-review},${LABEL_READY:-codex-ready-for-review},${LABEL_NEEDS_ITERATION:-codex-needs-iteration},${LABEL_NEEDS_REBASE:-codex-needs-rebase}"

  # full 集合 = 6 基本ラベル + codex-staged-for-release（ラベル文字列はハードコード重複させず
  # `$LABEL_STAGED_FOR_RELEASE` 定数を参照する / task 明記）。
  local staged_label="${LABEL_STAGED_FOR_RELEASE:-codex-staged-for-release}"
  local full_labels="${base_labels},${staged_label}"

  # dispatch かつ multi-branch（BASE_BRANCH != PROMOTION_TARGET_BRANCH）のみ
  # codex-staged-for-release を除外する。それ以外は full 集合（fail-safe / 安全側）。
  if [ "$context" = "dispatch" ] && [ "${BASE_BRANCH:-main}" != "${PROMOTION_TARGET_BRANCH:-main}" ]; then
    echo "$base_labels"
    return 0
  fi

  echo "$full_labels"
  return 0
}

# ─── Phase E: Label OR-clause Builder (#221 Req 1.2 / 4.2 / NFR 1.1) ───
# holder ラベル CSV を `gh issue list --search` 用の OR clause
# `label:"X" OR label:"Y" OR ...` へ組み立てる。空要素・前後空白は除去し、
# 有効ラベルが 1 つも無ければ空文字列を返す（caller が full 集合へ fallback / Req 4.2）。
#
# 重要（#221 NFR 1.1 ゼロ差分）: 現行 7 ラベル CSV を与えた場合の出力は
#   label:"codex-claimed" OR label:"codex-picked-up" OR label:"codex-awaiting-design-review"
#   OR label:"codex-ready-for-review" OR label:"codex-needs-iteration" OR label:"codex-needs-rebase"
#   OR label:"codex-staged-for-release"
# と完全一致し、これを (...) で挟んだ search_query が現行固定クエリと文字列一致する。
#
# Args: $1 = holder labels CSV
# Stdout: OR clause 文字列（有効ラベル 0 件なら空文字列）
# Return: 0 always
po_build_label_or_clause() {
  local csv="${1:-}"
  local clause=""
  local elem
  # CSV をカンマで分割。各要素の前後空白を除去し、空要素はスキップする。
  local IFS=','
  for elem in $csv; do
    # 前後の空白（スペース / タブ）を除去
    elem="${elem#"${elem%%[![:space:]]*}"}"
    elem="${elem%"${elem##*[![:space:]]}"}"
    [ -z "$elem" ] && continue
    if [ -z "$clause" ]; then
      clause="label:\"${elem}\""
    else
      clause="${clause} OR label:\"${elem}\""
    fi
  done
  printf '%s' "$clause"
  return 0
}

# ─── Phase E: In-Flight Collector (#18 Req 4.1〜4.4 / 5.3 / 8.1) ───
# 現サイクルの in-flight Issue（候補自身を除く）を gh で 1 回列挙し、各 Issue の
# edit_paths を読み出して **union 配列**と **path → holder Issue 番号配列の map**
# の両方を含む JSON object を返す。
#
# 戻り値の JSON object schema:
#   {
#     "union":   ["local-watcher/", "README.md"],         # 正規化前の paths を union
#     "holders": {                                          # 正規化前の path → holders
#       "local-watcher/": [39, 40],
#       "README.md":      [40]
#     }
#   }
#
# Note: holders map のキーは **正規化前の生 path**（in-flight Issue が persist した
# まま）。`po_check_dispatch_gate` 側で overlap path（正規化済 top-level）と
# 突合する際は同じ `normalize` 関数を holders map のキーにも適用してから引く。
#
# Req 12.1 補足: API 呼び出し回数は本拡張で増えていない。各 in-flight Issue について
# `po_load_edit_paths` を 1 回呼ぶのは従来同様で、その戻り値から union と holders map
# を同時に構築するだけ。candidate 側の `po_load_edit_paths` も 1 回のまま。
#
# in-flight 判定ラベル（Req 4.1）: 第 2 引数 holder_labels（CSV）で与えられる集合を使う。
#   default（引数省略時）= 現行 7 ラベル集合 #221 NFR 1.1 ゼロ差分:
#     codex-claimed, codex-picked-up, codex-awaiting-design-review, codex-ready-for-review,
#     codex-needs-iteration, codex-needs-rebase, codex-staged-for-release
#   dispatch×multi-branch 文脈では呼び出し側が codex-staged-for-release を除いた 6 ラベル
#   集合を渡す（#221 Req 1.2 / 1.4）。
# 除外（Req 4.2）: codex-st-failed, codex-awaiting-slot（集合非依存で固定維持）
# 候補自身を除外（Req 4.3）、同 repo のみ（Req 4.4: --repo "$REPO" 固定）
#
# Args:
#   $1 = candidate issue number
#   $2 = holder labels CSV（省略時 default = 現行 7 ラベル集合 / 後方互換 #221 NFR 1.1）
# Stdout: JSON object `{"union": [...], "holders": {path: [issue#, ...]}}`
# Return: 0 = 列挙 OK / 1 = gh API 失敗（caller は fail-open で empty 扱い + warn）
po_collect_inflight_issues() {
  local candidate="$1"
  # #221 task 2: holder ラベル集合を第 2 引数で受ける。default は現行 7 ラベル集合に
  # 固定（引数を渡さない既存呼び出し = single-branch 運用は現行クエリと完全一致 / NFR 1.1）。
  local holder_labels="${2:-codex-claimed,codex-picked-up,codex-awaiting-design-review,codex-ready-for-review,codex-needs-iteration,codex-needs-rebase,codex-staged-for-release}"

  # 与えられた CSV を `label:"X" OR label:"Y" OR ...` 形式へ動的に組み立てる。
  # `gh issue list --label A --label B` は AND になるため `--search 'label:A OR ...'`
  # 形式を使う（既存 Phase B / Phase D が同形式を採用済）。
  # fail-safe（#221 Req 4.2）: CSV が空 / 不正で有効ラベルが 1 つも得られない場合は
  # full 7 ラベル集合へ fallback する（holder から誤って外さない安全側）。
  local label_clause
  label_clause=$(po_build_label_or_clause "$holder_labels")
  if [ -z "$label_clause" ]; then
    label_clause=$(po_build_label_or_clause "codex-claimed,codex-picked-up,codex-awaiting-design-review,codex-ready-for-review,codex-needs-iteration,codex-needs-rebase,codex-staged-for-release")
  fi

  local search_query
  search_query="is:open is:issue (${label_clause}) -label:\"codex-st-failed\" -label:\"codex-awaiting-slot\""
  local issues_json
  if ! issues_json=$(gh issue list --repo "$REPO" \
      --search "$search_query" \
      --json number \
      --limit 50 2>/dev/null); then
    return 1
  fi

  # 候補自身を除外（Req 4.3）、各 Issue について po_load_edit_paths を呼んで
  # union（unique 済 path 配列）と holders map（path → [issue#, ...]）を併走更新する。
  local accum
  accum='{"union": [], "holders": {}}'
  local n
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    if [ "$n" = "$candidate" ]; then
      continue
    fi
    local paths
    paths=$(po_load_edit_paths "$n")
    # accum := accum + (paths を union に merge / 各 path に対し holders[path] に n を追記)
    # holders は array で持ち、重複 issue# は jq の unique で抑止する。
    accum=$(jq -nc \
      --argjson acc "$accum" \
      --argjson paths "$paths" \
      --argjson holder "$n" '
      .union as $_ |
      $acc
      | .union = (.union + $paths | unique)
      | reduce $paths[] as $p (
          .;
          .holders[$p] = ((.holders[$p] // []) + [$holder] | unique)
        )
    ')
  done < <(echo "$issues_json" | jq -r '.[].number')

  echo "$accum"
  return 0
}

# ─── Phase E: Holder Resolver (#18 Req 5.3 / 8.1) ───
# overlap path（正規化済 top-level）と holders map（正規化前 path → [issue#, ...]）
# から、各 overlap path に対応する holder Issue 番号配列を解決する。
#
# 既存 `po_compute_overlap` の `normalize` 規約（先頭 `./` 剥がし / 連続スラッシュ
# 圧縮 / top-level セグメント + `/`）を holders map の生キーにも適用してから
# 突合する。
#
# Args: $1 = overlap JSON 配列（正規化済 top-level path 文字列）
#       $2 = holders map JSON（正規化前 path → [issue#, ...]）
# Stdout: JSON object `{overlap_path: [issue#, ...], ...}`
#         （overlap path はすべてキーに登場。holder が見つからない場合は空配列）
# Return: 0 always
po_resolve_overlap_holders() {
  local overlap_json="$1"
  local holders_json="$2"
  jq -nc \
    --argjson overlap "$overlap_json" \
    --argjson holders "$holders_json" '
    def normalize:
      sub("^\\./"; "")
      | gsub("/+"; "/")
      | if test("/") then
          (split("/")[0] + "/")
        else
          .
        end;
    # holders の生キーを normalize して bucket 化（同一 top-level に複数 raw path が
    # 寄ってきた場合は holders を merge して unique）
    ($holders | to_entries
      | map(.key |= normalize)
      | group_by(.key)
      | map({ key: .[0].key, value: (map(.value) | add | unique) })
      | from_entries
    ) as $bucket
    | reduce $overlap[] as $p (
        {};
        .[$p] = ($bucket[$p] // [])
      )
  '
}

# ─── Phase E: Holders Log Formatter (#18 Req 8.1) ───
# overlap-holders map から overlap log line 用の holders フィールド文字列
# （例: "#39,#40"）を生成する。重複 Issue# は除去、ソートして並び順を安定化。
#
# Args: $1 = overlap-holders map JSON（po_resolve_overlap_holders 出力）
# Stdout: "#<N>,#<M>,..." or "" (holders が 1 件も無い場合)
# Return: 0 always
po_format_holders_for_log() {
  local map_json="$1"
  echo "$map_json" | jq -r '
    [.[] | .[]] | unique | sort | map("#" + tostring) | join(",")
  ' 2>/dev/null || echo ""
}

# ─── Phase E: Overlap Table Markdown Formatter (#18 Req 5.3) ───
# overlap-holders map を sticky comment 本文の表形式 markdown に整形する。
# design.md「Awaiting-Slot Sticky Comment Format」（design.md:855-863）参照。
#
# 出力例:
#   | 重複 path | 保持中の Issue |
#   |---|---|
#   | `local-watcher/` | #39, #40 |
#   | `README.md` | #40 |
#
# Args: $1 = overlap-holders map JSON
# Stdout: markdown 表（先頭の見出し 2 行 + 各 overlap path 1 行）
# Return: 0 always
po_format_holders_table_md() {
  local map_json="$1"
  {
    echo '| 重複 path | 保持中の Issue |'
    echo '|---|---|'
    echo "$map_json" | jq -r '
      to_entries
      | sort_by(.key)
      | map(
          "| `" + .key + "` | " +
          (
            if (.value | length) == 0 then
              "_(holder 不明)_"
            else
              (.value | unique | sort | map("#" + tostring) | join(", "))
            end
          ) + " |"
        )
      | .[]
    ' 2>/dev/null
  }
}

# ─── Phase E: Overlap Engine (#18 Req 5.1 / 5.5 / 5.6) ───
# candidate と in-flight の path 配列の積集合を top-level 粒度で計算する。
#
# 正規化規約:
#   - 先頭 `./` を剥がす
#   - 連続スラッシュ `/+` を `/` 1 つに圧縮
#   - スラッシュを含むなら先頭セグメント + `/` を返す（ディレクトリ扱い）
#   - スラッシュを含まないならそのまま（ルート直下ファイル扱い）
#
# 例:
#   `local-watcher/bin/foo.sh` → `local-watcher/`
#   `README.md`                → `README.md`
#   `./docs/specs/18-foo/req.md` → `docs/`
#
# candidate が空配列なら常に積集合は空（Req 5.5 候補不在は dispatch 阻止しない）。
#
# Args: $1 = candidate edit_paths JSON 配列, $2 = in-flight union JSON 配列
# Stdout: 交差 JSON 配列（正規化済 top-level key、重複排除済）
# Return: 0 always
po_compute_overlap() {
  local cand_json="$1"
  local inflight_json="$2"
  jq -nc \
    --argjson c "$cand_json" \
    --argjson f "$inflight_json" '
    def normalize:
      sub("^\\./"; "")
      | gsub("/+"; "/")
      | if test("/") then
          (split("/")[0] + "/")
        else
          .
        end;
    ($c | map(normalize) | unique) as $cn
    | ($f | map(normalize) | unique) as $fn
    | $cn | map(select(. as $p | $fn | index($p)))
  '
}

# ─── Phase E: Awaiting Slot State Machine — apply (#18 Req 5.2 / 5.3 / 8.2) ───
# `codex-awaiting-slot` ラベルを付与（冪等）し、説明 sticky comment を post / update する。
#
# sticky comment marker: <!-- idd-codex:codex-awaiting-slot:v1 -->
# 同一 Issue に 1 件のみ。既存 marker 付きコメントがあれば PATCH で上書き、無ければ
# 新規 create する（cron tick ごとのノイズ累積を抑制）。
#
# 本文には Req 5.3 が要求する「どの path がどの in-flight Issue に保持されているか」
# を表形式（design.md「Awaiting-Slot Sticky Comment Format」L855-863 準拠）で表示する。
#
# Args: $1 = candidate issue number
#       $2 = overlap JSON 配列（正規化済 top-level path 文字列、後方互換用）
#       $3 = overlap-holders map JSON（path → [issue#, ...]、Req 5.3 holder 情報）
# Return: 0 = apply OK / 1 = 致命的失敗（呼び出し側 warn）
po_apply_awaiting_slot() {
  local issue_number="$1"
  local overlap_json="$2"
  local holders_map_json="${3:-}"

  # ラベル付与（冪等。既付与でも error にならない）。
  # #187: ラベル付与に失敗しても early return せず、警告ログを残した上で sticky comment
  # 投稿へ処理を継続する。これによりラベルが付与できなかったケースでも「なぜ Issue が
  # 止まっているか」を Issue 上のコメントから読み取れるようにする（Req 1.1 / 1.2 / 3.1）。
  # コメント投稿/更新はラベル付与の成否に依存せず必ず試行する。
  if gh issue edit "$issue_number" --repo "$REPO" \
      --add-label "$LABEL_AWAITING_SLOT" >/dev/null 2>&1; then
    po_log "codex-awaiting-slot added candidate=#${issue_number}"
  else
    po_warn "issue=#${issue_number} codex-awaiting-slot ラベル付与に失敗（見送り理由コメントの投稿は継続）"
  fi

  # sticky comment 本文の組み立て
  # holders_map_json が与えられた場合は表形式（| 重複 path | 保持中の Issue |）で
  # 表示する（Req 5.3 + design.md L855-863）。未指定 / 空 map の場合は path のみの
  # md リストにフォールバック（後方互換）。
  local overlap_section
  if [ -n "$holders_map_json" ] && \
      [ "$(echo "$holders_map_json" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
    overlap_section=$(po_format_holders_table_md "$holders_map_json")
  else
    overlap_section=$(echo "$overlap_json" | jq -r '
      if length == 0 then
        "_(overlap path が空ですが本コメントが呼ばれました。状態不整合の可能性あり)_"
      else
        map("- `" + . + "`") | join("\n")
      end
    ' 2>/dev/null || echo '_(overlap 抽出失敗)_')
  fi

  local marker="<!-- idd-codex:codex-awaiting-slot:v1 -->"
  local body
  read -r -d '' body <<EOF || true
## ⏸️ Dispatch を見送り中（Phase E Path Overlap Checker）

本 Issue が編集見込みの top-level path のうち、以下が現在 in-flight 中の他 Issue と重複しています。

${overlap_section}

先行 Issue の PR が merge されて in-flight 集合から外れた次サイクルで \`codex-awaiting-slot\`
ラベルが自動除去され、本 Issue は通常 dispatch に戻ります。手動介入は不要です。

詳細は README の「Path Overlap Checker (Phase E)」節を参照してください。

${marker}
EOF

  # sticky 化: 既存 marker 付きコメントを検索 → あれば PATCH、無ければ新規 create
  local comments_json
  if ! comments_json=$(gh issue view "$issue_number" --repo "$REPO" --json comments 2>/dev/null); then
    # コメント取得失敗時は新規 create を試みる（best-effort）
    gh issue comment "$issue_number" --repo "$REPO" --body "$body" >/dev/null 2>&1 || true
    return 0
  fi
  local existing_url
  existing_url=$(echo "$comments_json" | jq -r '
    (.comments // [])
    | map(select(.body | contains("<!-- idd-codex:codex-awaiting-slot:v1 -->")))
    | .[0].url // ""
  ' 2>/dev/null || echo "")
  local existing_comment_id=""
  if [ -n "$existing_url" ]; then
    existing_comment_id=$(printf '%s' "$existing_url" \
      | sed -nE 's/.*#issuecomment-([0-9]+)$/\1/p')
  fi
  if [ -n "$existing_comment_id" ]; then
    gh api -X PATCH "/repos/${REPO}/issues/comments/${existing_comment_id}" \
      -f body="$body" >/dev/null 2>&1 || true
  else
    gh issue comment "$issue_number" --repo "$REPO" --body "$body" >/dev/null 2>&1 || true
  fi
  return 0
}

# ─── Phase E: Awaiting Slot State Machine — clear (#18 Req 6.2 / 6.4 / 8.3) ───
# `codex-awaiting-slot` ラベルを除去する（冪等）。説明 sticky comment は事後監査用に残置する。
#
# Args: $1 = candidate issue number
# Return: 0 = clear OK / 1 = ラベル除去失敗（呼び出し側 warn → 次サイクルで再試行）
po_clear_awaiting_slot() {
  local issue_number="$1"
  if ! gh issue edit "$issue_number" --repo "$REPO" \
      --remove-label "$LABEL_AWAITING_SLOT" >/dev/null 2>&1; then
    return 1
  fi
  po_log "codex-awaiting-slot cleared candidate=#${issue_number} (overlap empty)"
  return 0
}

# ─── Phase E: Busy-Cycle Wait Visibility — state dir resolver (#228 Req 3 / NFR 4) ───
# 多忙サイクル待ちの「連続見送り tick 数」を永続化するローカル state ディレクトリを返す。
# GitHub API を一切呼ばずローカルファイルだけで継続 tick 数を数えるため、in-flight 列挙
# 回数・edit_paths 読み出し回数を本機能導入前から増やさない（NFR 4.1 / 4.2）。
#
# 配置: $LOG_DIR/busy-wait-state/（LOG_DIR は repo ごとに分離済み = repo 間で衝突しない）
# Stdout: state ディレクトリの絶対パス
# Return: 0 always（mkdir 失敗は呼び出し側が tee せず継続。state 不能でも dispatch は阻害しない）
po_busy_wait_state_dir() {
  local dir="${LOG_DIR:-$HOME/.idd-codex/issue-watcher/logs}/busy-wait-state"
  mkdir -p "$dir" >/dev/null 2>&1 || true
  printf '%s' "$dir"
}

# ─── Phase E: Busy-Cycle Wait Visibility — tick counter (#228 Req 3.1 / 3.2 / 3.4 / NFR 4) ───
# candidate Issue について「dispatch を見送った連続サイクル数」を 1 増やし、累計を返す。
# ローカル state ファイル（issue-<N>.tick）に整数を持つだけで GitHub API は呼ばない。
# 既存値が非数値 / 欠落 / 不正なら 0 とみなしてから +1 する（fail-safe）。
#
# Args: $1 = candidate issue number
# Stdout: 加算後の連続見送り tick 数（>= 1）
# Return: 0 always
po_busy_wait_tick() {
  local issue_number="$1"
  local dir
  dir=$(po_busy_wait_state_dir)
  local f="${dir}/issue-${issue_number}.tick"
  local cur=0
  if [ -f "$f" ]; then
    cur=$(cat "$f" 2>/dev/null || echo 0)
    # 非数値混入 fail-safe（途中で壊れたファイル / 手動編集等）
    case "$cur" in
      ''|*[!0-9]*) cur=0 ;;
    esac
  fi
  local next=$((cur + 1))
  printf '%s' "$next" > "$f" 2>/dev/null || true
  printf '%s' "$next"
  return 0
}

# ─── Phase E: Busy-Cycle Wait Visibility — tick reset (#228 Req 3.3 / NFR 4) ───
# candidate Issue の連続見送り tick state を 0 へリセット（state ファイル削除）する。
# dispatch に成功した / 見送り要因が解消したサイクルで呼び、次に再び見送られたときは
# tick を 1 から数え直す（transient と継続待機を区別する / Req 3.3 / 3.4）。
#
# Args: $1 = candidate issue number
# Return: 0 always（ファイル不在でも error にしない / 冪等）
po_busy_wait_reset() {
  local issue_number="$1"
  local dir
  dir=$(po_busy_wait_state_dir)
  rm -f "${dir}/issue-${issue_number}.tick" >/dev/null 2>&1 || true
  return 0
}

# ─── Phase E: Busy-Cycle Wait Visibility — signal apply (#228 Req 3.1〜3.2 / 4.1〜4.2 / 5.3) ───
# 多忙サイクル待ちが可視化閾値を超えた Issue へ、待機中である旨の sticky comment を
# post / update し `codex-awaiting-slot` ラベルを付与する。冪等性のため専用 marker
# <!-- idd-codex:busy-wait:v1 --> 付きコメントを 1 件に集約する（既存
# codex-awaiting-slot:v1 / edit-paths:v1 marker とは別管理 = 既存マーカー契約不変 / Req 5.3）。
# ラベル付与失敗でも sticky comment 投稿は継続する（Req 1.4 と同方針）。
#
# Args: $1 = candidate issue number
#       $2 = 連続見送り tick 数（本文へ埋め込む）
#       $3 = 待機理由テキスト（"全 slot 使用中" 等。本文へ埋め込む）
# Return: 0 = apply OK / 1 = 致命的失敗（呼び出し側 warn）
po_apply_busy_wait_signal() {
  local issue_number="$1"
  local tick_count="$2"
  local reason="${3:-空き slot 不足}"

  # ラベル付与（冪等。既付与でも error にならない）。失敗しても sticky comment 投稿へ継続。
  if gh issue edit "$issue_number" --repo "$REPO" \
      --add-label "$LABEL_AWAITING_SLOT" >/dev/null 2>&1; then
    po_log "busy-wait codex-awaiting-slot added candidate=#${issue_number} ticks=${tick_count}"
  else
    po_warn "issue=#${issue_number} busy-wait codex-awaiting-slot ラベル付与に失敗（可視化コメントの投稿は継続）"
  fi

  local marker="<!-- idd-codex:busy-wait:v1 -->"
  local body
  read -r -d '' body <<EOF || true
## ⏳ Dispatch 待機中（多忙サイクル待ち / Phase E）

本 Issue は dispatch 候補として評価されましたが、${reason}のため ${tick_count} サイクル連続で
slot へ投入できず待機しています（path-overlap 由来の見送りではありません）。

- 待機理由: ${reason}
- 連続見送りサイクル数: ${tick_count}

先行 Issue の処理が完了して空き slot が生まれた次サイクルで本 Issue は通常 dispatch に戻り、
本コメントが付与した \`codex-awaiting-slot\` ラベルは自動除去されます。手動介入は不要です。

詳細は README の「Path Overlap Checker (Phase E)」節「多忙サイクル待ちの可視化」を参照してください。

${marker}
EOF

  # sticky 化: 既存 marker 付きコメントを検索 → あれば PATCH、無ければ新規 create
  # （cron tick ごとのノイズ累積を抑制 / Req 4.1 / 4.2 / NFR 2.1）。
  local comments_json
  if ! comments_json=$(gh issue view "$issue_number" --repo "$REPO" --json comments 2>/dev/null); then
    gh issue comment "$issue_number" --repo "$REPO" --body "$body" >/dev/null 2>&1 || true
    return 0
  fi
  local existing_url
  existing_url=$(echo "$comments_json" | jq -r '
    (.comments // [])
    | map(select(.body | contains("<!-- idd-codex:busy-wait:v1 -->")))
    | .[0].url // ""
  ' 2>/dev/null || echo "")
  local existing_comment_id=""
  if [ -n "$existing_url" ]; then
    existing_comment_id=$(printf '%s' "$existing_url" \
      | sed -nE 's/.*#issuecomment-([0-9]+)$/\1/p')
  fi
  if [ -n "$existing_comment_id" ]; then
    gh api -X PATCH "/repos/${REPO}/issues/comments/${existing_comment_id}" \
      -f body="$body" >/dev/null 2>&1 || true
  else
    gh issue comment "$issue_number" --repo "$REPO" --body "$body" >/dev/null 2>&1 || true
  fi
  return 0
}

# ─── Phase E: Busy-Cycle Wait Visibility — orchestrator (#228 Req 3.1〜3.4 / 5.1 / 5.2) ───
# dispatcher の busy-wait 経路（候補が全 gate を通過したが空き slot を確保できず当該
# サイクルの dispatch を見送った地点）から呼ぶ。連続見送り tick を 1 増やし、可視化閾値
# （PATH_OVERLAP_BUSY_WAIT_THRESHOLD）に達したら可視化シグナルを残す。閾値未満では
# シグナルを残さない（transient 抑制 / Req 3.4 / NFR 1.1）。
#
# opt-in gate（Req 5.1 / 5.2）: PATH_OVERLAP_CHECK="true" 厳密一致のときのみ動作する。
# それ以外（未設定 / off / 不正値）は state ファイルも作らず即 return 0 = 本機能導入前と
# 完全に同一挙動（ローカル state も GitHub 状態も一切変更しない）。
#
# Args: $1 = candidate issue number
#       $2 = 待機理由テキスト（省略時 "空き slot 不足"）
# Return: 0 always（dispatch 経路を阻害しない）
po_check_busy_wait() {
  local candidate="$1"
  local reason="${2:-空き slot 不足}"

  # Req 5.1 / 5.2: opt-in gate（厳密一致 "true" のみ通す）。off 時は state も作らない。
  [ "${PATH_OVERLAP_CHECK:-off}" = "true" ] || return 0

  # 閾値の正規化: 0 / 空 / 非数値は安全側（連投しない）で既定 5 にフォールバック。
  local threshold="${PATH_OVERLAP_BUSY_WAIT_THRESHOLD:-5}"
  case "$threshold" in
    ''|*[!0-9]*) threshold=5 ;;
  esac
  [ "$threshold" -ge 1 ] 2>/dev/null || threshold=5

  # 連続見送り tick を 1 増やす（ローカル state のみ / GitHub API は呼ばない / NFR 4）。
  local ticks
  ticks=$(po_busy_wait_tick "$candidate")

  if [ "$ticks" -ge "$threshold" ]; then
    # NFR 3.1: 1 行ログに連続見送り tick 数・閾値・理由を含める。
    po_log "busy-wait visible candidate=#${candidate} ticks=${ticks} threshold=${threshold} reason=${reason}"
    if ! po_apply_busy_wait_signal "$candidate" "$ticks" "$reason"; then
      po_warn "issue=#${candidate} busy-wait 可視化シグナルの付与に失敗（次サイクルで再評価）"
    fi
  else
    # 閾値未満は transient とみなしシグナルを残さない（Req 3.4 / NFR 1.1）。
    po_log "busy-wait pending candidate=#${candidate} ticks=${ticks} threshold=${threshold} (閾値未満のため可視化なし)"
  fi
  return 0
}

# ─── Phase E: Dispatcher Integration Point (#18 Req 1.1〜1.4 / 5.x / 6.x / 12.2) ───
# _dispatcher_run の candidate ループ内、check_existing_impl_pr 通過直後・
# _dispatcher_find_free_slot 呼び出し前に挿入する gate 関数。
#
# 関数冒頭で `[ "$PATH_OVERLAP_CHECK" = "true" ] || return 0` で opt-in gate を成立
# させ、未設定 / off / 不正値（True / 1 / typo 等）は早期 return 0 = 従来挙動と
# 完全一致（Req 1.2 / 1.3 / NFR 1.1）。
#
# Args: $1 = candidate issue number, $2 = candidate labels JSON
#       （gh issue list の `.labels` フィールドを jq -c で取り出したもの）
# Return: 0 = claim を続行してよい / 1 = この cycle では dispatch skip（continue）
po_check_dispatch_gate() {
  local candidate="$1"
  local labels_json="$2"

  # Req 1.2 / 1.3 / 1.4: opt-in gate（厳密一致 "true" のみ通す）
  [ "$PATH_OVERLAP_CHECK" = "true" ] || return 0

  # 候補の edit_paths を sticky から読む（Req 5.5: marker 不在は空配列扱い）
  local cand_paths
  cand_paths=$(po_load_edit_paths "$candidate")

  # #221 task 3: dispatch 文脈の holder ラベル集合を解決する（Req 1.1 / 3.1）。
  # multi-branch（gitflow）運用では codex-staged-for-release を除外した 6 ラベル、
  # single-branch / 判定不能では full 7 ラベル集合（fail-safe）。
  local holder_labels full_labels
  holder_labels=$(po_resolve_holder_labels "dispatch")
  full_labels=$(po_resolve_holder_labels "promote")
  # NFR 3.1: 解決集合が full と異なる（codex-staged-for-release を除外した）場合のみ
  # 除外を判別可能にログ出力する。full と一致する場合（single-branch 等）は
  # ログを出さない（ゼロ差分 / NFR 1.1 を壊さない）。
  if [ "$holder_labels" != "$full_labels" ]; then
    po_log "holder-set context=dispatch excluded=${LABEL_STAGED_FOR_RELEASE:-codex-staged-for-release} base=${BASE_BRANCH:-main}"
  fi

  # in-flight union + holders map を取得（Req 4.1〜4.4 / 5.3 / 8.1）。
  # 解決済み holder 集合を注入する（#221 Req 1.1 / 1.3）。
  # 失敗時は fail-open で claim 続行
  local inflight_obj
  if ! inflight_obj=$(po_collect_inflight_issues "$candidate" "$holder_labels"); then
    po_warn "issue=#${candidate} in-flight 列挙に失敗、本サイクルは overlap 判定を skip して claim 続行"
    return 0
  fi
  local inflight_paths inflight_holders
  inflight_paths=$(echo "$inflight_obj" | jq -c '.union // []' 2>/dev/null || echo '[]')
  inflight_holders=$(echo "$inflight_obj" | jq -c '.holders // {}' 2>/dev/null || echo '{}')

  # overlap 計算（Req 5.1 / 5.6）
  local overlap overlap_count
  overlap=$(po_compute_overlap "$cand_paths" "$inflight_paths")
  overlap_count=$(echo "$overlap" | jq 'length' 2>/dev/null || echo 0)

  # 現状の codex-awaiting-slot ラベル付与状態（既存 labels_json から抽出）
  local has_awaiting
  has_awaiting=$(echo "$labels_json" \
    | jq -r --arg lbl "$LABEL_AWAITING_SLOT" \
        '[.[].name] | index($lbl) // empty' 2>/dev/null || echo "")

  if [ "$overlap_count" -gt 0 ]; then
    # Req 5.2 / 5.3 / 8.1 / 8.2: overlap 検出ログ（holders を含める）→ codex-awaiting-slot
    # 付与（冪等）と sticky comment の最新化。holders は overlap path（正規化済 top-level）
    # ごとに in-flight Issue 番号配列を解決し、log では unique sort で平坦化する。
    local overlap_holders_map holders_for_log paths_for_log
    overlap_holders_map=$(po_resolve_overlap_holders "$overlap" "$inflight_holders")
    holders_for_log=$(po_format_holders_for_log "$overlap_holders_map")
    paths_for_log=$(echo "$overlap" | jq -r 'join(",")')
    if [ -n "$holders_for_log" ]; then
      po_log "overlap detected candidate=#${candidate} paths=${paths_for_log} holders=${holders_for_log}"
    else
      # holders が空（in-flight が close 直後 / holder 不明等）でも paths は記録し、
      # holders=「-」で出力して欠落の事実をログに残す
      po_log "overlap detected candidate=#${candidate} paths=${paths_for_log} holders=-"
    fi
    # #257 Req 1.1 / 1.2 / 1.3 / 2.2 / NFR 3.1: codex-awaiting-slot ラベル付与状態に関わらず
    # 毎サイクル po_apply_awaiting_slot を呼ぶ。同関数は内部で
    #   ① ラベル付与（`gh issue edit --add-label` は既付与でも error にならず冪等）
    #   ② 既存 marker (<!-- idd-codex:codex-awaiting-slot:v1 -->) 付きコメントを検索
    #      → 既存ありなら `gh api -X PATCH` で本文を最新の overlap / holders で上書き
    #      → 無ければ `gh issue comment` で新規作成
    # を行うため、既に codex-awaiting-slot ラベルが付与されている Issue でも sticky comment
    # が最新ブロッカー情報へ更新される（ラベル / コメントとも Issue あたり 1 件を維持 /
    # NFR 3.1）。失敗しても警告ログのみで本サイクルの dispatch 見送り判定（return 1）
    # は継続する（Req 3.1 / 3.2 / 3.3）。
    if ! po_apply_awaiting_slot "$candidate" "$overlap" "$overlap_holders_map"; then
      po_warn "issue=#${candidate} codex-awaiting-slot 付与 / コメント更新に失敗（次サイクルで再評価）"
    fi
    return 1  # dispatch skip
  fi

  # overlap 空: Req 6.2 / 6.4 / 8.3 自然解消
  if [ -n "$has_awaiting" ]; then
    if ! po_clear_awaiting_slot "$candidate"; then
      po_warn "issue=#${candidate} codex-awaiting-slot 除去に失敗（次サイクルで再試行のため本 cycle は claim 見送り）"
      return 1
    fi
  fi
  return 0  # claim 続行
}

# ─── #243: flock skip 経路 path-overlap 可視化 — 候補評価コア ───
# 1 候補について read-only の overlap 評価を行い、検出時 apply / 解消時 clear を呼ぶ。
# po_check_dispatch_gate の overlap 判定部分（809-878 行）と同一の関数・引数・規約を
# 用い、評価ロジックの分岐を作らない（Req 7.1 / 7.2）。dispatch 固有の return（0=続行
# / 1=skip）は持たず、戻り値は呼び出し側の warn 判定にのみ使う。
#
# claim / dispatch / worktree・slot・dispatch ロックを取得せず、状態変更は
# codex-awaiting-slot ラベルと sticky comment の付与・除去・更新のみ（read＋label/comment）。
#
# Args: $1 = candidate issue number, $2 = candidate labels JSON
# Preconditions: cd "$REPO_DIR" 済み、可視化専用 flock 保持中。
# Return: 0 = 評価完了 / 1 = 評価中に警告（呼び出し側が warn ログを出す）
po__visibility_evaluate_candidate() {
  local candidate="$1"
  local labels_json="$2"

  # 候補の edit_paths を sticky から読む（marker 不在は空配列扱い / Req 7.1）
  local cand_paths
  cand_paths=$(po_load_edit_paths "$candidate")

  # dispatch 文脈と同一の holder ラベル集合を解決する（通常経路と同一規約 / Req 7.1）。
  # multi-branch（gitflow）運用では codex-staged-for-release を除外、single-branch / 判定不能
  # では full 集合（fail-safe）。
  local holder_labels
  holder_labels=$(po_resolve_holder_labels "dispatch")

  # in-flight union + holders map を read-only で取得（Req 2.3 / 7.1）。失敗時は
  # 当該候補のみ skip して warn 判定へ返す（fail-open / NFR 3.2）。
  local inflight_obj
  if ! inflight_obj=$(po_collect_inflight_issues "$candidate" "$holder_labels"); then
    return 1
  fi
  local inflight_paths inflight_holders
  inflight_paths=$(echo "$inflight_obj" | jq -c '.union // []' 2>/dev/null || echo '[]')
  inflight_holders=$(echo "$inflight_obj" | jq -c '.holders // {}' 2>/dev/null || echo '{}')

  # overlap 計算（通常経路と同一 / Req 7.1）
  local overlap overlap_count
  overlap=$(po_compute_overlap "$cand_paths" "$inflight_paths")
  overlap_count=$(echo "$overlap" | jq 'length' 2>/dev/null || echo 0)

  # 現状の codex-awaiting-slot ラベル付与状態（既存 labels_json から抽出）
  local has_awaiting
  has_awaiting=$(echo "$labels_json" \
    | jq -r --arg lbl "$LABEL_AWAITING_SLOT" \
        '[.[].name] | index($lbl) // empty' 2>/dev/null || echo "")

  if [ "$overlap_count" -gt 0 ]; then
    # overlap 検出ログ（候補番号・overlap path を識別可能に出力 / NFR 4.1）→
    # codex-awaiting-slot 付与（未付与時のみ / Req 1.2 / 1.3 / 5.3）。通常経路と同一の
    # sticky comment 出力形式（marker codex-awaiting-slot:v1 の冪等更新 / Req 5.1 / 5.2 / 7.2）。
    local overlap_holders_map holders_for_log paths_for_log
    overlap_holders_map=$(po_resolve_overlap_holders "$overlap" "$inflight_holders")
    holders_for_log=$(po_format_holders_for_log "$overlap_holders_map")
    paths_for_log=$(echo "$overlap" | jq -r 'join(",")')
    if [ -n "$holders_for_log" ]; then
      po_log "route=flock-skip overlap detected candidate=#${candidate} paths=${paths_for_log} holders=${holders_for_log}"
    else
      po_log "route=flock-skip overlap detected candidate=#${candidate} paths=${paths_for_log} holders=-"
    fi
    if [ -z "$has_awaiting" ]; then
      if ! po_apply_awaiting_slot "$candidate" "$overlap" "$overlap_holders_map"; then
        po_warn "route=flock-skip issue=#${candidate} codex-awaiting-slot 付与 / コメント投稿に失敗（次サイクルで再評価）"
        return 1
      fi
    fi
    return 0
  fi

  # overlap 空: 既付与なら自然解消（通常サイクルと共有の clear / Req 3.1）
  if [ -n "$has_awaiting" ]; then
    if ! po_clear_awaiting_slot "$candidate"; then
      po_warn "route=flock-skip issue=#${candidate} codex-awaiting-slot 除去に失敗（次サイクルで再試行）"
      return 1
    fi
  fi
  return 0
}

# ─── #243: flock skip 経路 path-overlap 可視化 — オーケストレータ ───
# flock skip コンテキストで dispatch を伴わない path-overlap 可視化パスを 1 サイクル
# 実行する。専用 flock 取得 → 候補列挙（claim 除外）→ 候補ごとに既存 po_* で overlap
# 評価 → codex-awaiting-slot＋sticky comment 付与（overlap あり）/ 除去（overlap なし & 既付与）。
#
# claim / dispatch / worktree・slot・dispatch ロックを取得しない（Req 2.1 / 2.2）。
# 状態変更操作はラベル付与・除去・sticky comment の post/update のみ（read＋label/comment）。
# 必ず return 0（呼び出し側の set -e 下でも watcher を異常終了させない / NFR 3.2 / NFR 1.1）。
#
# Args: なし（global $REPO / $REPO_DIR / $LOG_DIR / $PATH_OVERLAP_CHECK /
#       $PATH_OVERLAP_VISIBILITY_LOCK_FILE / $LABEL_* / $BASE_BRANCH /
#       $PROMOTION_TARGET_BRANCH に依存）。
# Stdout/Stderr: po_log / po_warn による 1 行ログ（経路識別子 route=flock-skip を含む）。
# Return: 0 always
po_run_flock_skip_visibility() {
  # ① opt-in gate（二重防御 / Req 6.1）。呼び出し側でも gate するが fail-safe に再確認。
  [ "${PATH_OVERLAP_CHECK:-off}" = "true" ] || return 0

  # ② 可視化専用 flock を別 fd（201）+ 別ファイルで非ブロッキング取得（Req 2.2 / 4.1）。
  #    本サイクルの ${LOCK_FILE}（fd 200）とは別ファイル・別 fd で取得し、worktree / slot /
  #    dispatch ロックは一切取得しない。
  local lock_file="${PATH_OVERLAP_VISIBILITY_LOCK_FILE:-${LOG_DIR}/flock-skip-visibility.lock}"
  if ! exec 201>"$lock_file" 2>/dev/null; then
    po_warn "route=flock-skip 専用ロックファイルを開けません lock=${lock_file}"
    return 0
  fi
  if ! flock -n 201; then
    # 別の可視化パスが進行中（多重起動抑止 / Req 4.1）。抑止事実を識別可能ログで残す（Req 4.2）。
    po_log "route=flock-skip visibility skipped (別の可視化パスが進行中 lock=${lock_file})"
    exec 201>&- 2>/dev/null || true
    return 0
  fi

  # ③ po_* の cwd 前提を満たす最小初期化（Req 2.4 / po_* 再利用）。失敗しても異常終了させない。
  if ! cd "$REPO_DIR" 2>/dev/null; then
    po_warn "route=flock-skip REPO_DIR へ cd 失敗 dir=${REPO_DIR}"
    exec 201>&- 2>/dev/null || true
    return 0
  fi

  po_log "route=flock-skip path-overlap visibility 開始"   # NFR 4.2 経路識別子

  # ④ codex-auto-dev 候補列挙（claim ラベル除外 = 本サイクル処理中 Issue を触らない / Req 2.4）。
  #    重要: _dispatcher_run の search_filter / DISPATCH_LIMIT は同関数の local 変数で本関数
  #    からは見えないため、同等の除外句・limit を本関数内で自前再構築する（既存 search_filter
  #    に変更を加えず安全側）。除外集合に処理中ラベル（codex-claimed / codex-picked-up）と
  #    既存 dispatcher の除外集合を必ず含めることで Req 2.4 を構造的に保証する。
  local vis_search_filter
  vis_search_filter="-label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_AWAITING_DESIGN\" -label:\"$LABEL_CLAIMED\" -label:\"$LABEL_PICKED\" -label:\"$LABEL_READY\" -label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_ITERATION\" -label:\"$LABEL_NEEDS_QUOTA_WAIT\" -label:\"$LABEL_STAGED_FOR_RELEASE\" -label:\"$LABEL_BLOCKED\""
  local vis_limit=5
  local candidates_json
  if ! candidates_json=$(gh issue list --repo "$REPO" --label "$LABEL_TRIGGER" --state open \
      --search "$vis_search_filter sort:created-asc" \
      --json number,labels --limit "$vis_limit" 2>/dev/null); then
    po_warn "route=flock-skip codex-auto-dev 候補列挙に失敗（本サイクルの可視化を skip）"   # NFR 3.2
    exec 201>&- 2>/dev/null || true
    return 0
  fi

  # ⑤ 候補ごとに既存 po_* で overlap 評価（通常経路と同一規約 / Req 7.1）。
  #    各候補の警告は warn ログして後続候補を継続する（fail-open / NFR 3.2）。
  local issue candidate labels_json
  while IFS= read -r issue; do
    [ -z "$issue" ] && continue
    candidate=$(echo "$issue" | jq -r '.number')
    labels_json=$(echo "$issue" | jq -c '.labels')
    po__visibility_evaluate_candidate "$candidate" "$labels_json" \
      || po_warn "route=flock-skip issue=#${candidate} 可視化評価で警告（後続候補は継続）"
  done < <(echo "$candidates_json" | jq -c '.[]')

  # ⑥ 専用 flock 解放
  exec 201>&- 2>/dev/null || true
  return 0
}

# pp_resolve_target_branch: `PROMOTION_TARGET_BRANCH` のリモート存在を検証し、
# `BASE_BRANCH` と異なることを確認する（Req 1.1.3, 1.2.2）。
# 戻り値: 0 = 検証 OK / 1 = 中止すべき状態
pp_resolve_target_branch() {
  # AC 1.1.3: BASE_BRANCH == PROMOTION_TARGET_BRANCH なら no-op として終了
  if [ "$BASE_BRANCH" = "$PROMOTION_TARGET_BRANCH" ]; then
    pp_log "BASE_BRANCH と PROMOTION_TARGET_BRANCH が同一 ('$BASE_BRANCH')、Phase B は no-op"
    return 1
  fi
  # AC 1.2.2: リモートに存在するか検証
  if ! timeout "$PROMOTE_GIT_TIMEOUT" \
      git ls-remote --exit-code --heads origin "$PROMOTION_TARGET_BRANCH" >/dev/null 2>&1; then
    pp_error "PROMOTION_TARGET_BRANCH '$PROMOTION_TARGET_BRANCH' がリモートに存在しません。promote を中止します。"
    return 1
  fi
  return 0
}

# pp_issue_has_label: Issue が指定ラベルを持つか確認するヘルパー。
# 戻り値: 0 = 持つ / 1 = 持たない or 取得失敗
pp_issue_has_label() {
  local issue_number="$1"
  local label="$2"
  local labels_json
  if ! labels_json=$(timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue view "$issue_number" --repo "$REPO" --json labels 2>/dev/null); then
    return 1
  fi
  echo "$labels_json" | jq -e --arg l "$label" \
    '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1
}

# pp_pr_issue_candidate_rows: merged PR JSON から staged-for-release 自動付与候補を抽出する。
# stdout は `<issue_number>\t<source>\t<pr_number>` の 1 行 1 候補。human-readable log は出さない。
# closing refs は既存互換として managed 判定なしで読むが、body plain reference は managed PR
# （同一 repo の `codex/issue-<N>-impl-*` branch、または codex/ branch + title issue 表記）
# に限定して読む。caller 側は fork PR を除外済みだが、本 helper でも same-repo を再確認する。
pp_pr_issue_candidate_rows() {
  local pr_json="$1"
  local repo_owner="$2"
  echo "$pr_json" | jq -r --arg owner "$repo_owner" '
    def issue_nums_from_text:
      (. // "" | tostring) as $text
      | [ $text
          | scan("(#|[Ii][Ss][Ss][Uu][Ee][ -]?)([0-9]+)")
          | .[1]
          | tonumber?
        ];
    def issue_nums_from_head:
      [ try ((.headRefName // "")
          | capture("^codex/issue-(?<n>[0-9]+)-impl(-resume)?-").n
          | tonumber) catch empty ];
    def same_repo:
      ((.headRepositoryOwner.login // "") == $owner)
      and ((.isCrossRepository // false) != true);
    def codex_head:
      ((.headRefName // "") | startswith("codex/"));
    . as $pr
    | ($pr.number // "") as $pr_number
    | if (same_repo | not) then
        empty
      else
        (issue_nums_from_head) as $head_nums
        | (($pr.title // "") | issue_nums_from_text) as $title_nums
        | ((($head_nums | length) > 0)
            or (codex_head and (($title_nums | length) > 0))) as $managed
        | [
            (($pr.closingIssuesReferences // [])[]
              | (.number? | tonumber?)
              | select(. != null)
              | { issue: ., source: "closing-ref" }),
            (if ($head_nums | length) > 0 then
              ($head_nums[] | { issue: ., source: "head" })
            else empty end),
            (if (codex_head and (($title_nums | length) > 0)) then
              ($title_nums[] | { issue: ., source: "title" })
            else empty end),
            (if $managed then
              (($pr.body // "") | issue_nums_from_text[] | { issue: ., source: "body-plain" })
            else empty end)
          ]
        | unique_by(.issue, .source)
        | sort_by(.issue, .source)
        | .[]
        | "\(.issue)\t\(.source)\t\($pr_number)"
      end
  ' 2>/dev/null
}

# pp_collect_merged_issues: Phase A 直後の状態で「`BASE_BRANCH` に merge 済みかつ
# closing refs / managed PR の branch・title・plain reference から対象 Issue を抽出し、
# 未付与の Issue には `codex-staged-for-release` を自動付与する。fork PR は除外する（NFR 2.4）。
# 自動付与と人間付与の source 区別は行わない（Req 2.1.2、同一ラベル共有）。
#
# stdout: 現時点で `codex-staged-for-release` を持つ全 open Issue の番号を 1 行 1 件で出力
#         （次のステップで ST 判定する対象集合になる）
# Requirements: 2.1, NFR 2.4, NFR 5.2
pp_collect_merged_issues() {
  local repo_owner="${REPO%%/*}"
  local recent_merged_prs_json
  # 1. is:merged base:$BASE_BRANCH の直近 PR を取得（最新 50 件、Req 5.2 範囲）
  if ! recent_merged_prs_json=$(timeout "$PROMOTE_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state merged \
      --base "$BASE_BRANCH" \
      --json number,headRepositoryOwner,isCrossRepository,headRefName,baseRefName,title,body,mergeCommit,closingIssuesReferences,mergedAt,updatedAt \
      --limit 50 2>/dev/null); then
    pp_warn "merged PR の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    return 0
  fi

  # 2. fork PR を除外（NFR 2.4）し、closing refs / managed PR resolver から Issue 番号を抽出
  local pr_objects
  if ! pr_objects=$(echo "$recent_merged_prs_json" | jq -c '
      sort_by(.mergedAt // .updatedAt // "") | reverse | .[]
    ' 2>/dev/null); then
    pp_warn "merged PR JSON の解析に失敗しました（auto-label は安全側で skip）"
    pr_objects=""
  fi

  local candidate_rows=""
  local pr_json pr_number pr_base pr_rows
  while IFS= read -r pr_json; do
    [ -n "$pr_json" ] || continue
    pr_number=$(echo "$pr_json" | jq -r '.number // "unknown"' 2>/dev/null || echo "unknown")
    pr_base=$(echo "$pr_json" | jq -r '.baseRefName // ""' 2>/dev/null || echo "")
    # gh pr list --base が主フィルタ。baseRefName が取れる場合のみ二重確認する。
    if [ -n "$pr_base" ] && [ "$pr_base" != "$BASE_BRANCH" ]; then
      pp_warn "pr=#${pr_number} baseRefName=${pr_base} が BASE_BRANCH=${BASE_BRANCH} と一致しないため auto-label skip"
      continue
    fi
    if ! pr_rows=$(pp_pr_issue_candidate_rows "$pr_json" "$repo_owner"); then
      pp_warn "pr=#${pr_number} Issue 候補の解析に失敗しました（当該 PR の auto-label は skip）"
      continue
    fi
    if [ -n "$pr_rows" ]; then
      if [ -n "$candidate_rows" ]; then
        candidate_rows="${candidate_rows}
${pr_rows}"
      else
        candidate_rows="$pr_rows"
      fi
    fi
  done <<< "$pr_objects"

  local linked_issues=""
  if [ -n "$candidate_rows" ]; then
    linked_issues=$(printf '%s\n' "$candidate_rows" | awk -F '\t' '
      $1 ~ /^[0-9]+$/ { seen[$1] = 1 }
      END {
        for (n in seen) print n
      }
    ' | sort -n)
  fi

  # 3. 各 Issue について `codex-staged-for-release` ラベルの有無を確認し、
  #    未付与なら自動付与する（重複付与は抑止 / Req 2.1.1, 2.1.3）
  local added=0
  local skipped=0
  if [ -n "$linked_issues" ]; then
    while IFS= read -r issue_number; do
      [ -n "$issue_number" ] || continue
      local candidate_sources candidate_prs
      candidate_sources=$(printf '%s\n' "$candidate_rows" | awk -F '\t' -v issue="$issue_number" '
        $1 == issue && !seen[$2]++ {
          out = out (out ? "," : "") $2
        }
        END { print out }
      ')
      candidate_prs=$(printf '%s\n' "$candidate_rows" | awk -F '\t' -v issue="$issue_number" '
        $1 == issue && !seen[$3]++ {
          out = out (out ? "," : "") "#" $3
        }
        END { print out }
      ')
      if pp_issue_has_label "$issue_number" "$LABEL_STAGED_FOR_RELEASE"; then
        # AC 2.1.3: 既付与なら API 再送しない
        skipped=$((skipped + 1))
        continue
      fi
      # AC 2.1.1: 未付与に対して自動付与
      if timeout "$PROMOTE_GIT_TIMEOUT" \
          gh issue edit "$issue_number" --repo "$REPO" \
            --add-label "$LABEL_STAGED_FOR_RELEASE" >/dev/null 2>&1; then
        pp_log "issue=#${issue_number} action=label-add label=${LABEL_STAGED_FOR_RELEASE} source=auto resolver_sources=${candidate_sources:-unknown} prs=${candidate_prs:-unknown}" >&2
        added=$((added + 1))
      else
        pp_warn "issue=#${issue_number} codex-staged-for-release 自動付与に失敗（後続 Issue は継続）"
      fi
    done <<< "$linked_issues"
  fi

  pp_log "auto-label サマリ: codex-staged-for-release-added=${added}, already-labeled-skipped=${skipped}" >&2

  # 4. 全 codex-staged-for-release 付き open Issue の番号を stdout に出力（自動 + 人間
  #    付与の両方を含む / Req 2.1.2）。後続 ST 判定の対象集合になる。
  timeout "$PROMOTE_GIT_TIMEOUT" gh issue list --repo "$REPO" \
    --label "$LABEL_STAGED_FOR_RELEASE" --state open \
    --json number --limit 100 --jq '.[].number' 2>/dev/null \
    || pp_warn "codex-staged-for-release 付き Issue 一覧の取得に失敗（per-Issue 処理を見送る）"
}

# pp_resolve_merge_sha: Issue に対応する直近の merge commit SHA を解決する。
# まず既存互換の closedByPullRequestsReferences 経路を使い、解決できない場合は
# BASE_BRANCH merged PR の managed resolver で no-closing-keyword PR の mergeCommit.oid を探す。
#
# 入力: $1 = Issue 番号
# 出力（stdout）: merge commit SHA（解決できた場合）
# 戻り値: 0 = 解決成功 / 1 = 失敗（対応 PR が見つからない・取得失敗等）
pp_resolve_merge_sha() {
  local issue_number="$1"
  local pr_list_json
  if ! pr_list_json=$(timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue view "$issue_number" --repo "$REPO" \
        --json closedByPullRequestsReferences 2>/dev/null); then
    pp_warn "issue=#${issue_number} closedByPullRequestsReferences の取得に失敗"
  else
    # PR ごとに mergeCommit.oid を取得（必要に応じて gh pr view で補完）
    local pr_numbers
    if pr_numbers=$(echo "$pr_list_json" | jq -r \
        '[.closedByPullRequestsReferences // [] | .[]
          | select(.state == "MERGED")
          | .number] | sort | reverse | .[]' 2>/dev/null); then
      local pr_number merge_sha
      while IFS= read -r pr_number; do
        [ -n "$pr_number" ] || continue
        merge_sha=$(timeout "$PROMOTE_GIT_TIMEOUT" \
          gh pr view "$pr_number" --repo "$REPO" \
            --json mergeCommit --jq '.mergeCommit.oid // ""' 2>/dev/null) || continue
        if [ -n "$merge_sha" ] && [ "$merge_sha" != "null" ]; then
          echo "$merge_sha"
          return 0
        fi
      done <<< "$pr_numbers"
    else
      pp_warn "issue=#${issue_number} closedByPullRequestsReferences JSON の解析に失敗"
    fi
  fi

  # no-closing-keyword managed PR では Issue 側の closedBy refs が空になるため、
  # BASE_BRANCH merged PR の managed resolver から対象 Issue を含む PR を探す。
  local repo_owner="${REPO%%/*}"
  local recent_merged_prs_json
  if ! recent_merged_prs_json=$(timeout "$PROMOTE_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state merged \
      --base "$BASE_BRANCH" \
      --json number,headRepositoryOwner,isCrossRepository,headRefName,baseRefName,title,body,mergeCommit,closingIssuesReferences,mergedAt,updatedAt \
      --limit 50 2>/dev/null); then
    pp_warn "issue=#${issue_number} merge SHA fallback 用 merged PR 取得に失敗"
    return 1
  fi

  local pr_objects
  if ! pr_objects=$(echo "$recent_merged_prs_json" | jq -c '
      sort_by(.mergedAt // .updatedAt // "") | reverse | .[]
    ' 2>/dev/null); then
    pp_warn "issue=#${issue_number} merge SHA fallback 用 merged PR JSON の解析に失敗"
    return 1
  fi

  local pr_json pr_number pr_base pr_rows merge_sha
  while IFS= read -r pr_json; do
    [ -n "$pr_json" ] || continue
    pr_number=$(echo "$pr_json" | jq -r '.number // "unknown"' 2>/dev/null || echo "unknown")
    pr_base=$(echo "$pr_json" | jq -r '.baseRefName // ""' 2>/dev/null || echo "")
    if [ -n "$pr_base" ] && [ "$pr_base" != "$BASE_BRANCH" ]; then
      continue
    fi
    if ! pr_rows=$(pp_pr_issue_candidate_rows "$pr_json" "$repo_owner"); then
      pp_warn "issue=#${issue_number} pr=#${pr_number} merge SHA fallback 候補の解析に失敗"
      continue
    fi
    if ! printf '%s\n' "$pr_rows" | awk -F '\t' -v issue="$issue_number" '$1 == issue { found=1 } END { exit(found ? 0 : 1) }'; then
      continue
    fi
    merge_sha=$(echo "$pr_json" | jq -r '.mergeCommit.oid // ""' 2>/dev/null || echo "")
    if [ -n "$merge_sha" ] && [ "$merge_sha" != "null" ]; then
      echo "$merge_sha"
      return 0
    fi
    pp_warn "issue=#${issue_number} pr=#${pr_number} managed PR を検出したが mergeCommit.oid が空"
  done <<< "$pr_objects"
  return 1
}

# pp_get_st_state: 1 つの Issue について、リンクされた最新の `BASE_BRANCH` 上
# merge commit に対する ST check-run の状態を取得する。
#
# 入力: $1 = Issue 番号
# 出力（stdout）: 内部状態 5 種のいずれか
#   "success"   ST check-run が完了 & conclusion=success
#   "failure"   ST check-run が完了 & conclusion=failure/cancelled/timed_out/action_required
#   "pending"   ST check-run が in_progress / queued / pending
#   "missing"   ST check-run が見つからない or conclusion 不一致
#   "skip-warn" ST_CHECK_RUN_NAME 未設定（Req 2.2.3）
# 戻り値: 常に 0（呼び出し元で文字列分岐）
# Requirements: 2.2
pp_get_st_state() {
  local issue_number="$1"
  # AC 2.2.3: ST_CHECK_RUN_NAME 未設定なら skip-warn（呼び出し元で WARN ログ）
  if [ -z "$ST_CHECK_RUN_NAME" ]; then
    echo "skip-warn"
    return 0
  fi
  # AC 2.2.5: Issue にリンクされた merge commit を解決できなければ missing
  local merge_sha
  if ! merge_sha=$(pp_resolve_merge_sha "$issue_number"); then
    echo "missing"
    return 0
  fi
  [ -n "$merge_sha" ] || { echo "missing"; return 0; }
  # AC 2.2.1: check-runs API で対象 commit に対する check-run 一覧を取得
  local check_runs_json
  if ! check_runs_json=$(timeout "$PROMOTE_GIT_TIMEOUT" \
      gh api "repos/$REPO/commits/$merge_sha/check-runs" \
        --jq '.check_runs' 2>/dev/null); then
    echo "missing"
    return 0
  fi
  # AC 2.2.2: ST_CHECK_RUN_NAME と完全一致する check-run を抽出し、最新採用
  local target
  target=$(echo "$check_runs_json" | jq -c --arg n "$ST_CHECK_RUN_NAME" \
    '[.[] | select(.name == $n)]
      | sort_by(.completed_at // .started_at // "")
      | last' 2>/dev/null) || target="null"
  if [ -z "$target" ] || [ "$target" = "null" ]; then
    echo "missing"
    return 0
  fi
  # AC 2.2.4: status + conclusion で結果判定
  local status conclusion
  status=$(echo "$target" | jq -r '.status // ""')
  conclusion=$(echo "$target" | jq -r '.conclusion // ""')
  case "$status" in
    completed)
      case "$conclusion" in
        success)
          echo "success"
          ;;
        failure|cancelled|timed_out|action_required)
          echo "failure"
          ;;
        *)
          # neutral / skipped / stale / unknown は missing 扱い
          echo "missing"
          ;;
      esac
      ;;
    queued|in_progress|pending|"")
      echo "pending"
      ;;
    *)
      echo "pending"
      ;;
  esac
}

# pp_resolve_st_log_url: ST check-run の details_url を解決する（取得失敗時は空文字列）。
# 入力: $1 = Issue 番号, $2 = merge commit SHA
# 出力（stdout）: details_url または空文字列
pp_resolve_st_log_url() {
  local merge_sha="$2"
  [ -n "$ST_CHECK_RUN_NAME" ] || { echo ""; return 0; }
  [ -n "$merge_sha" ] || { echo ""; return 0; }
  local check_runs_json
  if ! check_runs_json=$(timeout "$PROMOTE_GIT_TIMEOUT" \
      gh api "repos/$REPO/commits/$merge_sha/check-runs" \
        --jq '.check_runs' 2>/dev/null); then
    echo ""
    return 0
  fi
  echo "$check_runs_json" | jq -r --arg n "$ST_CHECK_RUN_NAME" \
    '[.[] | select(.name == $n)]
      | sort_by(.completed_at // .started_at // "")
      | last
      | (.details_url // .html_url // "")' 2>/dev/null \
    || echo ""
}

# pp_do_revert: `BASE_BRANCH` 上で merge commit を `git revert -m 1` して
# `--force-with-lease` で push する（NFR 2.1）。サブシェル内で `trap` を仕掛けて
# `BASE_BRANCH` checkout 状態への復帰を保証する（NFR 2.3）。
#
# 入力: $1 = revert 対象の merge commit SHA
# 戻り値:
#   0 = revert + push 成功
#   1 = push 失敗（リモート先行等）。呼び出し元で codex-st-failed 付与を保留（Req 2.4.6）
#   2 = revert 自体が失敗 / checkout / pull 失敗
pp_do_revert() {
  local merge_sha="$1"
  (
    set +e
    # 復帰用 trap: revert を中断したら `git revert --abort` し、$BASE_BRANCH に戻る
    trap 'git revert --abort >/dev/null 2>&1; git checkout "'"$BASE_BRANCH"'" >/dev/null 2>&1' EXIT
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git checkout "$BASE_BRANCH" >/dev/null 2>&1; then
      exit 2
    fi
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git pull --ff-only origin "$BASE_BRANCH" >/dev/null 2>&1; then
      exit 2
    fi
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git revert -m 1 --no-edit "$merge_sha" >/dev/null 2>&1; then
      exit 2
    fi
    # NFR 2.1: --force-with-lease のみ。--force 単独は使用しない
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git push --force-with-lease origin "$BASE_BRANCH" >/dev/null 2>&1; then
      exit 1
    fi
    exit 0
  )
}

# pp_handle_st_failure: ST failure と判定された Issue について、対応する merge
# commit を revert + push、Issue reopen、`codex-st-failed` 付与、ST log URL を含む
# 1 件のコメント投稿を実施する（Req 2.4）。fail-continue を維持し、1 件失敗しても
# 他 Issue の処理は継続する（NFR 3.1）。
#
# 入力: $1 = Issue 番号
# 戻り値: 0 = 全操作成功 / 1 = いずれかが失敗（呼び出し元でカウンタにのみ反映）
pp_handle_st_failure() {
  local issue_number="$1"
  local merge_sha st_log_url
  if ! merge_sha=$(pp_resolve_merge_sha "$issue_number"); then
    pp_warn "issue=#${issue_number} merge SHA 解決失敗 → ST failure 処理を見送り action=skip"
    return 1
  fi
  # AC 2.4.2: revert commit を作成して push。push 失敗 → codex-st-failed 付与を保留
  local revert_rc=0
  pp_do_revert "$merge_sha" || revert_rc=$?
  case "$revert_rc" in
    0)
      :
      ;;
    1)
      # AC 2.4.6: push 失敗（リモート先行等）→ codex-st-failed 保留 + WARN
      pp_warn "issue=#${issue_number} revert push 失敗（リモート先行等）→ codex-st-failed 付与を保留 action=skip merge_sha=${merge_sha:0:7}"
      return 1
      ;;
    *)
      pp_warn "issue=#${issue_number} revert 自体に失敗（既に revert 済み等）→ ST failure 処理を見送り action=skip merge_sha=${merge_sha:0:7}"
      return 1
      ;;
  esac
  # AC 2.4.1 + 2.4.4: codex-st-failed 付与 + codex-staged-for-release 除去を 1 call に集約
  if ! timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue edit "$issue_number" --repo "$REPO" \
        --add-label "$LABEL_ST_FAILED" \
        --remove-label "$LABEL_STAGED_FOR_RELEASE" >/dev/null 2>&1; then
    pp_warn "issue=#${issue_number} ラベル付与/除去に失敗（revert は実施済み） action=label-fail"
    # ラベル操作の失敗は致命的でないため、reopen / comment は継続する
  fi
  # AC 2.4.3: Issue reopen
  if ! timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue reopen "$issue_number" --repo "$REPO" >/dev/null 2>&1; then
    # 既に open の場合や API エラーでも次の comment を試みる
    pp_warn "issue=#${issue_number} Issue reopen に失敗（既に open の可能性あり、comment 投稿は継続）"
  fi
  # AC 2.4.3: ST log URL を含む 1 件のステータスコメントを投稿
  st_log_url=$(pp_resolve_st_log_url "$issue_number" "$merge_sha")
  local comment_body
  read -r -d '' comment_body <<EOF || true
## 🔁 ST failure 自動 revert (Phase B Promote Pipeline)

\`${BASE_BRANCH}\` に merge された変更について、ST check-run **\`${ST_CHECK_RUN_NAME}\`** が
**failure** と判定されたため、watcher が \`git revert -m 1\` で自動 revert しました。

### Revert 対象 merge commit

- SHA (short): \`${merge_sha:0:7}\`
- ST log URL: ${st_log_url:-_(取得失敗)_}

### 推奨アクション

- ST failure の原因を確認し、修正用 PR を本 Issue にリンクして作成してください
- 本 Issue は \`codex-st-failed\` ラベル付きで自動 reopen されています

---

_本コメントは Phase B Promote Pipeline Processor が自動投稿しました。_
EOF
  if ! timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue comment "$issue_number" --repo "$REPO" \
        --body "$comment_body" >/dev/null 2>&1; then
    pp_warn "issue=#${issue_number} ステータスコメント投稿に失敗（revert / label / reopen は実施済み）"
  fi
  pp_log "issue=#${issue_number} ST=failure action=revert+label-add+label-remove+reopen+comment merge_sha=${merge_sha:0:7} label=${LABEL_ST_FAILED}"
  return 0
}

# pp_handle_st_success: ST success と判定された Issue から `codex-staged-for-release`
# ラベルを除去し、promote 候補集合（PROMOTE_CANDIDATES）に追加する。
# `PROMOTE_MODE=on-demand` の場合はラベル除去 / 集合追加とも行わず、人間トリガー
# を待つ（Req 3.2.5）。
#
# 入力: $1 = Issue 番号
# 戻り値: 0 = 成功 / 1 = 失敗（fail-continue で呼び出し側がカウントのみ実施）
# Requirements: 2.3, 3.2
pp_handle_st_success() {
  local issue_number="$1"
  # AC 3.2.5: on-demand モードはラベルを除去せず、PROMOTE_CANDIDATES にも入れない
  if [ "$PROMOTE_MODE" = "on-demand" ]; then
    pp_log "issue=#${issue_number} ST=success mode=on-demand action=hold-label-await-human-trigger"
    return 0
  fi
  # AC 2.3.1: codex-staged-for-release ラベルを除去
  if ! timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue edit "$issue_number" --repo "$REPO" \
        --remove-label "$LABEL_STAGED_FOR_RELEASE" >/dev/null 2>&1; then
    pp_warn "issue=#${issue_number} ST=success codex-staged-for-release 除去に失敗（後続 Issue は継続）"
    return 1
  fi
  # AC 2.3.2: promote 候補集合に追加
  PROMOTE_CANDIDATES+=("$issue_number")
  pp_log "issue=#${issue_number} ST=success action=label-remove+promote-queued label=${LABEL_STAGED_FOR_RELEASE}"
  return 0
}

# pp_process_one_issue: 1 件の Issue について ST 状態を取得し、状態別の
# アクション（success / failure / pending / missing / skip-warn）を実施する。
# 1 件の失敗が他 Issue 処理を止めないように戻り値で集計用カウンタにのみ反映
# する（NFR 3.1 fail-continue）。
#
# 入力: $1 = Issue 番号
# 副作用（成功時のみ加算する集計用変数、呼び出し側スコープで参照）:
#   PP_ST_SUCCESS_COUNT / PP_ST_FAILURE_COUNT / PP_ST_PENDING_COUNT /
#   PP_ST_MISSING_COUNT / PP_FAIL_COUNT
pp_process_one_issue() {
  local issue_number="$1"
  local st_state
  st_state=$(pp_get_st_state "$issue_number")
  case "$st_state" in
    success)
      if pp_handle_st_success "$issue_number"; then
        PP_ST_SUCCESS_COUNT=$((PP_ST_SUCCESS_COUNT + 1))
      else
        PP_FAIL_COUNT=$((PP_FAIL_COUNT + 1))
      fi
      ;;
    failure)
      if pp_handle_st_failure "$issue_number"; then
        PP_ST_FAILURE_COUNT=$((PP_ST_FAILURE_COUNT + 1))
      else
        PP_FAIL_COUNT=$((PP_FAIL_COUNT + 1))
      fi
      ;;
    pending)
      # AC 2.2.4: 未完了は次サイクルに持ち越す（ラベル変更なし）
      pp_log "issue=#${issue_number} ST=pending action=skip-next-cycle"
      PP_ST_PENDING_COUNT=$((PP_ST_PENDING_COUNT + 1))
      ;;
    missing)
      # AC 2.2.5: ST check-run が存在しない → WARN + 状態変更なし
      pp_warn "issue=#${issue_number} ST=missing action=skip（check-run 不在 or merge SHA 未解決）"
      PP_ST_MISSING_COUNT=$((PP_ST_MISSING_COUNT + 1))
      ;;
    skip-warn)
      # AC 2.2.3: ST_CHECK_RUN_NAME 未設定 → WARN + 当該サイクル no-op
      pp_warn "issue=#${issue_number} ST_CHECK_RUN_NAME 未設定 → ST 連動停止 action=skip"
      PP_ST_MISSING_COUNT=$((PP_ST_MISSING_COUNT + 1))
      ;;
    *)
      pp_warn "issue=#${issue_number} 未知の ST 状態 '${st_state}' action=skip"
      PP_FAIL_COUNT=$((PP_FAIL_COUNT + 1))
      ;;
  esac
  return 0
}

# pp_match_cron_field: 1 つの cron フィールド（分 / 時 / 日 / 月 / 曜日）を
# 現在値とマッチングする。標準 cron のサブパターン:
#   *           （任意の値にマッチ）
#   */N         （N で割り切れる値にマッチ）
#   A-B         （A 以上 B 以下にマッチ）
#   A,B,C       （いずれかの値にマッチ）
#   <整数>      （厳密一致）
#
# 入力: $1 = cron フィールド文字列, $2 = 現在値（整数）
# 戻り値: 0 = match / 1 = no match or 不正
pp_match_cron_field() {
  local field="$1"
  local value="$2"
  [ -n "$field" ] || return 1
  # 数値以外の現在値はマッチ不能
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  # `*` は全てにマッチ
  if [ "$field" = "*" ]; then
    return 0
  fi
  # `*/N` ステップ
  if [[ "$field" =~ ^\*/([0-9]+)$ ]]; then
    local step="${BASH_REMATCH[1]}"
    [ "$step" -gt 0 ] || return 1
    if [ $((10#$value % step)) -eq 0 ]; then
      return 0
    fi
    return 1
  fi
  # カンマ区切りリスト
  if [[ "$field" == *,* ]]; then
    local subfield
    IFS=',' read -ra _PP_CRON_PARTS <<< "$field"
    for subfield in "${_PP_CRON_PARTS[@]}"; do
      if pp_match_cron_field "$subfield" "$value"; then
        return 0
      fi
    done
    return 1
  fi
  # `A-B` レンジ
  if [[ "$field" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    local lo="${BASH_REMATCH[1]}"
    local hi="${BASH_REMATCH[2]}"
    if [ "$((10#$value))" -ge "$lo" ] && [ "$((10#$value))" -le "$hi" ]; then
      return 0
    fi
    return 1
  fi
  # 単一整数
  if [[ "$field" =~ ^[0-9]+$ ]]; then
    if [ "$((10#$value))" -eq "$((10#$field))" ]; then
      return 0
    fi
    return 1
  fi
  return 1
}

# pp_match_cron: 標準 cron 5 フィールド式（分 時 日 月 曜日）を現在時刻と比較する。
# `date '+%M %H %d %m %u'` で取得した現在時刻と、cron 各フィールドを `pp_match_cron_field`
# でマッチング。全フィールド一致なら 0、いずれか不一致 / 不正な書式なら 1 を返す。
#
# 入力: $1 = cron 式（5 フィールドのみ。`@daily` 等の特殊文字列は非対応）
# 戻り値: 0 = 現在時刻が cron 式に一致 / 1 = 不一致 or 不正な書式
# Requirements: 3.2.4, 3.2.6
pp_match_cron() {
  local cron="$1"
  [ -n "$cron" ] || return 1
  # 5 フィールドに分解
  local -a fields
  # shellcheck disable=SC2206 # 意図的に IFS=space で分割
  fields=( $cron )
  if [ "${#fields[@]}" -ne 5 ]; then
    return 1
  fi
  local now_min now_hour now_day now_mon now_dow
  now_min=$(date '+%M')
  now_hour=$(date '+%H')
  now_day=$(date '+%d')
  now_mon=$(date '+%m')
  now_dow=$(date '+%u')   # 1=Mon, 7=Sun（cron では 0/7 が Sun のため両対応が望ましい）
  pp_match_cron_field "${fields[0]}" "$now_min"  || return 1
  pp_match_cron_field "${fields[1]}" "$now_hour" || return 1
  pp_match_cron_field "${fields[2]}" "$now_day"  || return 1
  pp_match_cron_field "${fields[3]}" "$now_mon"  || return 1
  # 曜日: cron では 0=Sun, 1=Mon..6=Sat。`date +%u` は 1=Mon..7=Sun のため、
  # まず %u で比較し、cron 0 表記は %u=7（日曜）に丸めて再比較する
  if ! pp_match_cron_field "${fields[4]}" "$now_dow"; then
    if [ "$now_dow" = "7" ] && pp_match_cron_field "${fields[4]}" "0"; then
      :
    else
      return 1
    fi
  fi
  return 0
}

# pp_do_promote_if_eligible: `PROMOTE_MODE` 3 モード（continuous / batched /
# on-demand）の dispatcher。実際の fast-forward push 本体 `pp_do_promote`
# は本関数から呼び出される（task 5.2 で実装）。
#
# Requirements: 3.2.2, 3.2.3, 3.2.4, 3.2.5, 3.2.6
pp_do_promote_if_eligible() {
  case "$PROMOTE_MODE" in
    continuous)
      # AC 3.2.3: 即時 promote。promote 候補が 0 件なら何もしない
      if [ "${#PROMOTE_CANDIDATES[@]}" -gt 0 ]; then
        pp_do_promote
      else
        pp_log "mode=continuous promote 候補 0 件 → 本サイクルは promote なし"
      fi
      ;;
    batched)
      # AC 3.2.4 / 3.2.6: PROMOTE_CRON 一致時のみ実行
      if [ -z "$PROMOTE_CRON" ]; then
        pp_warn "mode=batched PROMOTE_CRON 未設定 → 本サイクルは promote なし"
        return 0
      fi
      if pp_match_cron "$PROMOTE_CRON"; then
        if [ "${#PROMOTE_CANDIDATES[@]}" -gt 0 ]; then
          pp_do_promote
        else
          pp_log "mode=batched cron 一致だが promote 候補 0 件 → 本サイクルは promote なし"
        fi
      else
        # AC 3.2.6: cron 不一致 / 不正な式は本サイクル no-op + WARN
        pp_log "mode=batched PROMOTE_CRON='${PROMOTE_CRON}' 現在時刻と不一致 → 本サイクルは promote なし"
      fi
      ;;
    on-demand)
      # AC 3.2.5: 人間トリガー待ち。何もしない + log
      pp_log "mode=on-demand 人間トリガーを待つ → promote は実行しない"
      ;;
    *)
      # AC 3.2.2: 不正値も on-demand にフォールバック
      pp_warn "mode='${PROMOTE_MODE}' は未知の値 → on-demand にフォールバック（promote 実行しない）"
      ;;
  esac
}

# pp_do_promote: `BASE_BRANCH` HEAD を `PROMOTION_TARGET_BRANCH` に fast-forward
# push する（NFR 2.1, NFR 2.2）。サブシェル内で `trap` を仕掛けて操作終了時に
# `BASE_BRANCH` checkout 状態へ復帰する（NFR 2.3 / Req 3.1.4）。
#
# fast-forward 不可（`PROMOTION_TARGET_BRANCH` 側が `BASE_BRANCH` の祖先でない）と
# 判定した場合は push を中止し、`promote-failed` 識別語を含む WARN を出す
# （Req 3.1.2, 3.1.3, NFR 4.1）。Issue 側のラベル状態は変更しない。
#
# 戻り値: 0 = promote 成功 / 1 = promote 失敗（呼び出し元は集計のみ）
pp_do_promote() {
  local rc=0
  (
    set +e
    trap 'git checkout "'"$BASE_BRANCH"'" >/dev/null 2>&1' EXIT
    # Req 3.1.1 準備: 最新の PROMOTION_TARGET_BRANCH を fetch
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git fetch origin "$PROMOTION_TARGET_BRANCH" >/dev/null 2>&1; then
      pp_warn "promote-failed: fetch '$PROMOTION_TARGET_BRANCH' に失敗"
      pp_notify_promote_failure "fetch failed"
      exit 1
    fi
    # AC 3.1.2: PROMOTION_TARGET_BRANCH が BASE_BRANCH の祖先か確認。
    # 祖先でない場合 fast-forward 不可 → 中止 + WARN（Req 3.1.3）
    if ! git merge-base --is-ancestor \
        "origin/$PROMOTION_TARGET_BRANCH" "origin/$BASE_BRANCH" 2>/dev/null; then
      pp_warn "promote-failed: '$PROMOTION_TARGET_BRANCH' が '$BASE_BRANCH' の祖先でないため fast-forward 不可"
      pp_notify_promote_failure "non-fast-forward"
      exit 1
    fi
    # NFR 2.1 / 2.2: fast-forward 限定 push（--force 系オプションを付けず
    # 自然な ff push）。non-fast-forward は git server が reject する
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git push origin \
          "refs/remotes/origin/${BASE_BRANCH}:refs/heads/${PROMOTION_TARGET_BRANCH}" \
          >/dev/null 2>&1; then
      pp_warn "promote-failed: fast-forward push に失敗"
      pp_notify_promote_failure "ff-push failed"
      exit 1
    fi
    pp_log "promote-success: '$BASE_BRANCH' -> '$PROMOTION_TARGET_BRANCH' fast-forward OK (candidates=${#PROMOTE_CANDIDATES[@]})"
    exit 0
  ) || rc=$?
  # 親シェル側カウンタを更新（サブシェル内で変更したカウンタは失われるため）
  if [ "$rc" -eq 0 ]; then
    PP_PROMOTE_SUCCESS_COUNT=$((PP_PROMOTE_SUCCESS_COUNT + 1))
  else
    PP_PROMOTE_FAILED_COUNT=$((PP_PROMOTE_FAILED_COUNT + 1))
  fi
  return "$rc"
}

# pp_notify_promote_failure: promote 失敗時の通知。`PROMOTE_FAIL_NOTIFY_ISSUE` が
# 数値で指定されていれば該当 Issue に 1 件コメント投稿、未設定 / 不正値なら log のみ
# （Req 3.3.2, 3.3.3）。
pp_notify_promote_failure() {
  local reason="$1"
  # AC 3.3.3: 未設定 / 不正値（数値以外）は log のみ
  if [ -z "$PROMOTE_FAIL_NOTIFY_ISSUE" ] \
     || ! [[ "$PROMOTE_FAIL_NOTIFY_ISSUE" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  # AC 3.3.2: 1 件のコメント投稿（失敗してもサイクルは継続）
  local body
  read -r -d '' body <<EOF || true
## ⚠️ Phase B Promote Pipeline: promote 失敗

\`${BASE_BRANCH}\` -> \`${PROMOTION_TARGET_BRANCH}\` への fast-forward 昇格に失敗しました。

- reason: \`${reason}\`
- base: \`${BASE_BRANCH}\`
- target: \`${PROMOTION_TARGET_BRANCH}\`

watcher サイクルは継続しています。手動確認をお願いします。

---

_本コメントは Phase B Promote Pipeline Processor が自動投稿しました。_
EOF
  timeout "$PROMOTE_GIT_TIMEOUT" \
    gh issue comment "$PROMOTE_FAIL_NOTIFY_ISSUE" --repo "$REPO" \
      --body "$body" >/dev/null 2>&1 \
    || pp_warn "PROMOTE_FAIL_NOTIFY_ISSUE=#${PROMOTE_FAIL_NOTIFY_ISSUE} へのコメント投稿に失敗"
}

# pp_summary: サイクル終了時のサマリログを 1 行で出力する。grep 集計用に
# `[$REPO] promote-pipeline: サマリ:` prefix と `key=value` 形式で出力する
# （Req 5.1.3, 5.1.5, NFR 4.1）。
pp_summary() {
  pp_log "サマリ: st-success-promoted=${PP_ST_SUCCESS_COUNT}, st-failure-reverted=${PP_ST_FAILURE_COUNT}, pending-skip=${PP_ST_PENDING_COUNT}, missing-skip=${PP_ST_MISSING_COUNT}, promote-success=${PP_PROMOTE_SUCCESS_COUNT}, promote-failed=${PP_PROMOTE_FAILED_COUNT}, fail=${PP_FAIL_COUNT}"
}

# process_promote_pipeline: Promote Pipeline Processor のエントリポイント。
#
# 引数: なし（env var で全制御）
# 戻り値: 常に 0（fail-continue を維持し、後続 Processor を止めない / NFR 3.1）
# 副作用:
#   - 対象 Issue へのラベル付与・除去（codex-staged-for-release / codex-st-failed）
#   - 対象 Issue の reopen + コメント投稿（ST failure 時）
#   - $BASE_BRANCH への revert commit + push（ST failure 時）
#   - $BASE_BRANCH → $PROMOTION_TARGET_BRANCH への fast-forward push（promote 成功時）
#   - $PROMOTE_FAIL_NOTIFY_ISSUE への 1 件コメント（promote 失敗時、env 設定時のみ）
process_promote_pipeline() {
  # AC 1.1.1, NFR 1.1: opt-in gate。`=true` 明示以外はすべて no-op で早期 return
  if [ "$PROMOTE_PIPELINE_ENABLED" != "true" ]; then
    return 0
  fi

  pp_log "サイクル開始 (base=${BASE_BRANCH}, target=${PROMOTION_TARGET_BRANCH}, mode=${PROMOTE_MODE}, timeout=${PROMOTE_GIT_TIMEOUT}s)"

  # AC 1.1.3, 1.2.2: 2-branch model gate + PROMOTION_TARGET_BRANCH のリモート存在検証
  if ! pp_resolve_target_branch; then
    return 0
  fi

  # NFR 2.3: dirty working tree gate。promote / revert は clean な作業ツリーが前提
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    pp_error "dirty working tree を検知。promote / revert を中止します。"
    return 0
  fi

  # AC 2.1: merge 済み PR からリンク Issue を抽出 → 未付与に codex-staged-for-release を
  # 自動付与し、ST 判定対象（= 現在 codex-staged-for-release を持つ全 open Issue）を取得。
  local target_issues
  target_issues=$(pp_collect_merged_issues || true)

  if [ -z "$target_issues" ]; then
    pp_log "サマリ: 対象 Issue なし（codex-staged-for-release 付き Issue 0 件）"
    return 0
  fi

  # ST 判定対象 Issue 数を log に出力
  local target_count
  target_count=$(echo "$target_issues" | grep -c '^[0-9]' || true)
  pp_log "ST 判定対象: ${target_count} 件の Issue を検出"

  # 集計用カウンタと promote 候補集合を初期化（per-cycle 状態）
  PROMOTE_CANDIDATES=()
  PP_ST_SUCCESS_COUNT=0
  PP_ST_FAILURE_COUNT=0
  PP_ST_PENDING_COUNT=0
  PP_ST_MISSING_COUNT=0
  PP_FAIL_COUNT=0

  # AC 2.2〜2.4: 各 Issue について ST 状態取得 + アクション実施。
  # NFR 3.1: 1 件の失敗が他 Issue 処理を止めないよう `|| true` で吸収。
  local issue_number
  while IFS= read -r issue_number; do
    [ -n "$issue_number" ] || continue
    pp_process_one_issue "$issue_number" \
      || pp_warn "issue=#${issue_number} 想定外のエラー → 後続 Issue は継続"
  done <<< "$target_issues"

  # AC 3.1, 3.2: promote 候補集合を PROMOTE_MODE に応じて昇格実行。
  # 集計用カウンタは pp_do_promote / pp_do_promote_if_eligible 内部で更新する。
  PP_PROMOTE_SUCCESS_COUNT=0
  PP_PROMOTE_FAILED_COUNT=0
  # NFR 3.1: 失敗時も後続処理を止めないため `|| true` で吸収
  pp_do_promote_if_eligible || true

  # AC 5.1.3: サイクル終了時のサマリログを 1 行で出力
  pp_summary
}
