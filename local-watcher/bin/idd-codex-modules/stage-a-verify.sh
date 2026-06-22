#!/usr/bin/env bash
# shellcheck shell=bash
# stage-a-verify.sh — watcher の Stage A Verify ゲートモジュール
#
# 用途:
#   idd-codex-issue-watcher.sh から切り出した Stage A Verify Module (#125) の関数定義を集約する。
#   Stage A（Developer 実装）完了直前に tasks.md 末尾の build/test/lint コマンド（verify
#   タスク）を Stage A Verify が独立再実行し、Developer の自己申告のみで build
#   不通が Stage A を通過するのを防ぐゲート。STAGE_A_VERIFY_ENABLED で gate。
#   - sav_log / sav_warn / sav_error           : `stage-a-verify:` prefix logger
#   - _sav_cmd_starts_with_keyword             : verify keyword 行頭一致判定
#   - stage_a_verify_extract_command           : tasks.md 末尾走査 + keyword 一致抽出
#   - stage_a_verify_extract_verify_block       : tasks.md センチネル付き構造化 verify ブロックの厳密パース抽出
#   - stage_a_verify_resolve_command           : 構造化ブロック → env → heuristic → SKIPPED の 4 段 fallback 連鎖
#   - stage_a_verify_round_path / _read_round / _bump_round / _reset_round
#                                              : sidecar による round counter 永続化
#   - _sav_handle_failure                      : round=1 差し戻し / round=2 escalate
#   - stage_a_verify_run                       : 統合ランナー（戻り値 0=pass / 1=差し戻し / 2=codex-failed）
#
# 分割の経緯（#181 design.md decision 2）:
#   Part 1 境界マップは Stage A Verify を impl-gates.sh へ集約する想定だったが、Issue #181
#   のスコープは stage_a_verify_run / sav_* のみで sc_*（Stage Checkpoint）/ tc_*（Tasks Count）
#   は対象外のため、独立モジュール stage-a-verify.sh として分離する。元コードでは
#   sav_* は 2 つの非連続領域（Region 1: logger〜reset_round / Region 2: _sav_handle_failure /
#   stage_a_verify_run）に分かれていたが、source は全関数を実行前に読み込むため 1 ファイルへ
#   統合しても挙動は等価（元コードの「順序維持」コメントは可読性配慮でランタイム要件ではない）。
#
# 配置先:
#   $HOME/bin/idd-codex-modules/stage-a-verify.sh（install.sh が local-watcher/bin/idd-codex-modules/ から配置する）
#
# 依存:
#   - 本モジュールは idd-codex-issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$REPO / $REPO_DIR / $SPEC_DIR_REL / $LOG_DIR / $NUMBER /
#     $STAGE_A_VERIFY_ENABLED / $STAGE_A_VERIFY_COMMAND / $STAGE_A_VERIFY_TIMEOUT 等）は
#     本体冒頭の Config ブロックで定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - cross-module 呼び出し: _sav_handle_failure → mark_issue_failed（impl-pipeline 系 / 本体）。
#     stage_a_verify_run → _sav_handle_failure。いずれも run_impl_pipeline 実行前に全モジュールが
#     source されるため、呼び出し時点で定義済みであり挙動不変。
#   - call site（run_impl_pipeline 内の stage_a_verify_run）は本体に残置する。
#   - 外部 CLI: gh / git / codex / timeout。
#
# セットアップ参照先:
#   - 設計: docs/specs/181-feat-watcher-issue-watcher-sh-part-3-pr/design.md（decision 2）
#   - 機能設計: docs/specs/125-feat-watcher-stage-a-tasks-md-verify-bui/design.md

# stage-a-verify 専用ロガー（既存 qa_log と同形式 / Issue #119 規約）。
# 行頭 `[YYYY-MM-DD HH:MM:SS] [$REPO] stage-a-verify:` の 3 段 prefix を維持し、
# `grep '\[.*\] stage-a-verify:'` で全件抽出可能（NFR 4.1, NFR 4.2）。
sav_log() {
  echo "[$(date '+%F %T')] [$REPO] stage-a-verify: $*"
}
sav_warn() {
  echo "[$(date '+%F %T')] [$REPO] stage-a-verify: WARN: $*" >&2
}
sav_error() {
  echo "[$(date '+%F %T')] [$REPO] stage-a-verify: ERROR: $*" >&2
}

# ─── _sav_source_requires_sandbox ───
#
# Stage A Verify の解決手段が repository 由来かを判定する。structured-block と heuristic は
# `tasks.md` 由来であり、Issue / PR prompt injection の影響を受けうる未信頼入力として扱う。
# env-command は operator が cron / launchd で明示した既存 escape hatch のため、従来の直接実行
# semantics を維持する（Issue #51 Option A）。
_sav_source_requires_sandbox() {
  case "${1:-}" in
    structured-block|heuristic) return 0 ;;
    *) return 1 ;;
  esac
}

# ─── _sav_sandbox_profile_is_forbidden ───
#
# `codex sandbox -P :danger-full-access` は sandbox 境界を確立しないため、repository 由来 verify
# では fail-closed する。custom profile の内容は Codex config 側の責務だが、明示的な no-sandbox
# built-in はここで拒否し、非 sandbox 権限へのフォールバックを防ぐ。
_sav_sandbox_profile_is_forbidden() {
  case "${1:-}" in
    ":danger-full-access"|"danger-full-access") return 0 ;;
    *) return 1 ;;
  esac
}

# ─── _sav_run_repo_command_in_codex_sandbox ───
#
# `tasks.md` 由来の verify コマンドを Codex CLI の sandbox runner 内で実行する。親 watcher は
# `codex sandbox` プロセスを起動するだけで、未信頼コマンド自体を非 sandbox の `bash -c` へ
# 直接渡さない。sandbox helper / profile が使えない場合も非 sandbox へ fallback しない。
#
# 入力:
#   $1 = 実行する shell コマンド（複数行 / メタ文字を保持）
#   $2 = timeout 秒
# 戻り値: `codex sandbox ... bash -c "$cmd"` の exit code（timeout は 124）
_sav_run_repo_command_in_codex_sandbox() {
  local cmd="$1"
  local timeout_sec="$2"
  local profile="${STAGE_A_VERIFY_SANDBOX_PROFILE:-:workspace}"

  if _sav_sandbox_profile_is_forbidden "$profile"; then
    sav_error "sandbox profile refuses repository-derived verify source profile=$profile reason=no-sandbox"
    return 126
  fi

  sav_log "sandbox EXEC profile=$profile boundary=codex-sandbox"
  timeout --kill-after=10 "$timeout_sec" \
    "${CODEX_BIN:-codex}" sandbox -P "$profile" -C "$REPO_DIR" -- bash -c "$cmd"
}

# ─── _sav_cmd_starts_with_keyword ───
#
# 抽出した shell コマンド ($1) が verify keyword 集合のいずれかで「行頭一致」
# するかを確認する。`stage_a_verify_run` の Gate 3 として `stage_a_verify_extract_command`
# 側の strict 抽出に対する defense-in-depth として使う（#160 Req 5.3）。
#
# 注: keyword 集合の Single Source of Truth は `stage_a_verify_extract_command`
#     内の awk script に渡される `_SAV_KEYWORDS` である。本関数の keyword リストは
#     当該定義と **完全一致** している必要があり、追加時は両方を更新すること
#     （tasks-generation.md の design.md「Components and Interfaces /
#     stage_a_verify_extract_command」を参照）。
#     抽出関数側で既に行頭一致を保証しているため、本関数のチェックが SKIPPED に
#     倒すケースは「将来抽出関数の挙動が緩んだ場合のセーフティネット」と
#     「将来の caller 拡張」を想定したもの。
#
# 入力: $1 = 抽出済み shell コマンド文字列
# 戻り値: 0 = いずれかの keyword で開始 / 1 = 一致しない（= SKIPPED 候補）
_sav_cmd_starts_with_keyword() {
  local cmd="$1"
  case "$cmd" in
    "./gradlew"*) return 0 ;;
    "gradle "*) return 0 ;;
    "mvn "*) return 0 ;;
    "npm test"*) return 0 ;;
    "npm run"*) return 0 ;;
    "npm ci"*) return 0 ;;
    "pnpm "*) return 0 ;;
    "yarn "*) return 0 ;;
    "cargo "*) return 0 ;;
    "go test"*) return 0 ;;
    "go build"*) return 0 ;;
    "go vet"*) return 0 ;;
    "pytest"*) return 0 ;;
    "python -m pytest"*) return 0 ;;
    "python -m unittest"*) return 0 ;;
    "make test"*) return 0 ;;
    "make build"*) return 0 ;;
    "make check"*) return 0 ;;
    "make verify"*) return 0 ;;
    "bundle exec"*) return 0 ;;
    "rake "*) return 0 ;;
    "dotnet test"*) return 0 ;;
    "dotnet build"*) return 0 ;;
    "shellcheck"*) return 0 ;;
    "actionlint"*) return 0 ;;
    "tox "*) return 0 ;;
    "swift test"*) return 0 ;;
    "swift build"*) return 0 ;;
  esac
  return 1
}

# ─── stage_a_verify_extract_command ───
#
# `tasks.md` を 1 パスで走査し、抽出キーワード集合に一致した行のうち
# **末尾（ファイル末尾に最も近いもの）** 1 行を stdout に出力する（Req 1.1, 1.2）。
# 抽出は言語非依存な文字列パターンのみで行う（AST 解析しない、Req 1.5 / NFR 2.1）。
#
# 入力: 環境変数 REPO_DIR / SPEC_DIR_REL
# 戻り値: 0 = 抽出成功 / 1 = 一致なし or tasks.md 不在
# stdout: 抽出した shell コマンド 1 行（成功時のみ）
#
# 抽出キーワード集合は design.md「Components and Interfaces /
# stage_a_verify_extract_command」で確定したもの。新言語追加時はここに 1 行追加する
# だけで対応可能。未対応言語は `STAGE_A_VERIFY_COMMAND` env で escape する。
stage_a_verify_extract_command() {
  local tasks_path="$REPO_DIR/$SPEC_DIR_REL/tasks.md"
  [ -f "$tasks_path" ] || return 1

  # 言語非依存 keyword 集合。BSD awk では -v の値に実改行を含めると parse error に
  # なるため、macOS 互換の区切り文字形式で渡す。
  # 各 keyword は「行に部分一致したら verify タスクとみなす」最小単位。
  #   - `./gradlew` / `gradle ` / `mvn ` : JVM 系 build tool
  #   - `npm test` / `npm run` / `npm ci` / `pnpm ` / `yarn ` : Node.js 系
  #     （`npm install` は依存解決なので含めない）
  #   - `cargo ` : Rust
  #   - `go test` / `go build` / `go vet` : Go
  #   - `pytest` / `python -m pytest` / `python -m unittest` : Python
  #   - `make test` / `make build` / `make check` / `make verify` : make（target 限定）
  #   - `bundle exec` / `rake ` : Ruby
  #   - `dotnet test` / `dotnet build` : .NET
  #   - `shellcheck` / `actionlint` : shell 系プロジェクト（idd-codex 自身を含む）
  #   - `tox ` : Python tox
  #   - `swift test` / `swift build` : Swift
  local _SAV_KEYWORDS
  _SAV_KEYWORDS="./gradlew|gradle |mvn |npm test|npm run|npm ci|pnpm |yarn |cargo |go test|go build|go vet|pytest|python -m pytest|python -m unittest|make test|make build|make check|make verify|bundle exec|rake |dotnet test|dotnet build|shellcheck|actionlint|tox |swift test|swift build"

  # awk 1 パス走査で「直近で keyword に一致した行」を変数 last に保持し、
  # ファイル末尾まで読んだら最後の保持値を出力する（= 末尾に最も近い 1 行、
  # Req 1.2 / #160 Req 1.3, 2.2, 2.3）。O(N) 線形時間（NFR 3.1 / #160 NFR 2.1）。
  #
  # #160 修正: backtick で囲まれたインラインコードスパン（`...`）が行内にあり、
  #   その中身が keyword に一致した場合、**スパン内の中身のみ** を抽出する
  #   （Req 1.1）。散文 + backtick で書かれた verify 行（例: `- lint 緑:
  #   \`./gradlew :app:lintDebug\` で新規 error なし`）が exit 127 を起こす
  #   regression（#125 で導入）を解消する。
  #   同一行に複数のインラインコードスパンが存在する場合は、最初に keyword に
  #   一致したスパンの中身を採用（Req 1.2）。
  #   行内に backtick がペアで存在せず、行全体が keyword に部分一致した場合は
  #   従来通り「装飾除去後の行全体」を採用する（Req 2.1 / 後方互換）。
  #   複数行 fenced code block（` ``` ` フェンスで囲まれた範囲）内の行は
  #   抽出対象から除外する（Req 3.1）。
  # 装飾 strip:
  #   - 行頭の "- " / "  - " / "  - [ ] " 等の markdown bullet と list checkbox
  #   - 行頭 / 行末の空白
  # 抽出結果は装飾を除いたコマンド本体のみ（後段の `bash -c` で実行可能な形）。
  local result
  result=$(awk -v kws="$_SAV_KEYWORDS" '
    BEGIN {
      n = split(kws, ARR, /\|/)
      last = ""
      in_fence = 0
    }
    {
      raw = $0
      # 複数行 fenced code block の境界判定（行頭 ``` で開閉、言語タグ任意）。
      # in_fence 状態の行は keyword マッチ対象から除外する（#160 Req 3.1, 3.2）。
      if (raw ~ /^[[:space:]]*```/) {
        in_fence = (in_fence == 0) ? 1 : 0
        next
      }
      if (in_fence) { next }

      line = raw
      # markdown bullet / checkbox / アスタリスク（deferrable 印）の装飾除去
      sub(/^[[:space:]]+/, "", line)
      sub(/^-[[:space:]]+/, "", line)
      sub(/^\[[[:space:]xX]\]\*?[[:space:]]+/, "", line)
      sub(/^[0-9]+(\.[0-9]+)*[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)

      # インラインコードスパン抽出（#160 Req 1.1, 1.2）:
      #   バッククォートで囲まれた中身を順に走査し、最初に keyword に**行頭一致**
      #   したスパンの中身を採用する。
      #   #160 round=2 (Req 5.3): `index(candidate, kw) > 0` だと
      #   `cd app && ./gradlew test` のように冒頭が keyword 以外のスパンも
      #   採用してしまい、`bash -c "cd app && ..."` が走って意図せず副作用を起こす
      #   恐れがあるため `== 1` （= 行頭一致）に厳格化する。span の冒頭が keyword
      #   で始まらない場合は当該 span を抽出対象から外し、次の span を走査する。
      span_hit = 0
      span_content = ""
      tail = line
      while (1) {
        p1 = index(tail, "`")
        if (p1 == 0) { break }
        rest = substr(tail, p1 + 1)
        p2 = index(rest, "`")
        if (p2 == 0) { break }
        candidate = substr(rest, 1, p2 - 1)
        for (i = 1; i <= n; i++) {
          kw = ARR[i]
          if (kw == "") continue
          if (index(candidate, kw) == 1) {
            span_content = candidate
            span_hit = 1
            break
          }
        }
        if (span_hit) { break }
        tail = substr(rest, p2 + 1)
      }
      if (span_hit) {
        last = span_content
        next
      }

      # backtick 無し / backtick はあるが keyword 不一致の場合は、装飾除去後の
      # 行全体が keyword で**行頭一致**するか判定する（#160 Req 2.1 後方互換 +
      # Req 5.3）。
      # ただし line に backtick がペアで含まれる場合は「散文+backtick で keyword は
      # スパン外にしか出現しない」ケース（#160 の本丸 regression）なので行全体採用
      # は誤動作を起こす。よって backtick ペアが存在する場合は line fallback を
      # 行わず、当該行を抽出候補から除外する（Req 1.4 / Req 5.1）。
      # #160 round=2 (Req 5.3): 部分一致 `index(...) > 0` だと
      # `lint を実行する` のような散文の "lint" を `./gradlew :app:lintDebug`
      # 等とマッチさせる可能性があるため、行頭一致 `index(...) == 1` に厳格化する。
      # 既存 12 fixture はいずれも装飾除去後の行頭が keyword で始まるため挙動不変。
      bt_count = gsub(/`/, "`", line)
      if (bt_count >= 2) { next }

      for (i = 1; i <= n; i++) {
        kw = ARR[i]
        if (kw == "") continue
        if (index(line, kw) == 1) {
          last = line
          break
        }
      }
    }
    END {
      if (last != "") print last
    }
  ' "$tasks_path")

  [ -n "$result" ] || return 1
  printf '%s\n' "$result"
}

# ─── stage_a_verify_extract_verify_block ───
#
# `tasks.md` のセンチネル付き構造化 verify ブロックから、verify コマンドを
# 決定論的に抽出する純関数（Req 1.1, 1.4, 1.5 / NFR 3.1, NFR 3.2, NFR 4.1）。
# 散文をコマンドと誤認するヒューリスティック抽出（#160/#219/#221 で誤発火）を
# 構造的に避けるための input 契約パス。本関数はヒューリスティック抽出
# （stage_a_verify_extract_command）とは抽出基準が根本的に異なる
# （行頭 keyword 一致 vs センチネル + fence 構造）ため、既存 awk を拡張せず
# 独立関数として分離する（design.md「Components and Interfaces」）。
#
# 入力: 環境変数 REPO_DIR / SPEC_DIR_REL
# 戻り値: 0 = well-formed ブロック抽出成功 / 1 = ブロック無し or malformed or tasks.md 不在
# stdout: 抽出したコマンド（成功時のみ。複数行は改行・インデント込みで保持）
#
# パース規約（design.md「パース規約（決定論化の詳細）」と同一基準）:
#   - センチネル: 行を trim した結果が厳密に `<!-- stage-a-verify -->` に一致する行を
#     アンカー行とする（前後空白許容、行内の他テキストは不可）。
#   - 直後性: アンカー行の次行以降で空行を任意個スキップした後の最初の非空行が
#     fence 開始（trim 後 ``` で始まる）であること。fence 以外の非空行が先に来たら
#     malformed → return 1。
#   - fence 言語タグ（```sh / ```bash 等）は読み飛ばし、タグ自体は中身に含めない。
#   - fence 終了: 次に現れる trim 後 ``` 行で閉じる。EOF まで閉じなければ malformed。
#   - 中身: fence 開始行と終了行の間の全行。trim 後すべて空なら malformed（空ブロック扱い）。
#     非空なら元の改行・インデントを保持して出力（`&&` 連結や複数行コマンドの意味を壊さない）。
#   - 複数ブロック: 上記を満たす最初のアンカー + fence のみ採用し、以降は無視（決定論）。
#
# 副作用なし（tasks.md を書き換えない、NFR 3.2）。同一入力に同一結果（NFR 3.1）。
stage_a_verify_extract_verify_block() {
  local tasks_path="$REPO_DIR/$SPEC_DIR_REL/tasks.md"
  [ -f "$tasks_path" ] || return 1

  # awk 1 パス走査で「最初の well-formed アンカー + fence」を状態機械で抽出する。
  # state 遷移:
  #   0 = アンカー未検出。trim 後が厳密にセンチネルの行を見つけたら state=1。
  #   1 = アンカー検出済・fence 開始待ち。空行はスキップ。最初の非空行が fence 開始
  #       （trim 後 ``` で始まる）なら state=2、それ以外の非空行なら malformed として
  #       打ち切り（done=1 のまま中身を出さず終了 → END で return 1 相当）。
  #   2 = fence 内・中身収集中。trim 後 ``` の行で閉じて done=1。閉じる前に EOF なら
  #       未クローズ → 中身を出さない。fence 内の各行は raw のまま buf に蓄積する
  #       （元の改行・インデントを保持、Req 1.4）。
  # closed=1 かつ 中身が trim 後非空のときのみ buf を改行込みで出力する。
  # 一致した最初のブロックで done=1 とし、以降は state=0 のまま何もしない（決定論）。
  local result
  result=$(awk '
    BEGIN {
      state = 0       # 0=アンカー待ち / 1=fence 開始待ち / 2=fence 内
      done_flag = 0   # 最初のブロックを処理し終えたら 1（以降は無視）
      closed = 0      # fence が閉じたか
      nonblank = 0    # fence 中身に非空行が 1 行でもあったか
      buf = ""        # fence 中身バッファ（raw を改行区切りで蓄積）
      buf_n = 0       # buf に積んだ行数
    }
    {
      if (done_flag) { next }

      raw = $0
      # trim（行頭行末の空白除去）した判定用文字列を作る。
      t = raw
      sub(/^[[:space:]]+/, "", t)
      sub(/[[:space:]]+$/, "", t)

      if (state == 0) {
        # アンカー行検出（trim 後の厳密一致）。行内の他テキストは不可。
        if (t == "<!-- stage-a-verify -->") {
          state = 1
        }
        next
      }

      if (state == 1) {
        # アンカー直後の空行は任意個スキップ。
        if (t == "") { next }
        # 最初の非空行が fence 開始でなければ malformed → 打ち切り。
        if (t ~ /^```/) {
          state = 2
          next
        }
        done_flag = 1   # malformed。中身を出さずに以降を無視。
        next
      }

      if (state == 2) {
        # fence 終了行（trim 後 ``` で開始）で閉じる。言語タグは開始行のみに付く
        # 想定だが、終了行は単独の ``` が canonical。trim 後 ``` 始まりで閉じる。
        if (t ~ /^```/) {
          closed = 1
          done_flag = 1
          next
        }
        # fence 内の中身は raw のまま蓄積（元の改行・インデントを保持、Req 1.4）。
        if (t != "") { nonblank = 1 }
        if (buf_n == 0) { buf = raw } else { buf = buf "\n" raw }
        buf_n++
        next
      }
    }
    END {
      # well-formed 条件: fence が閉じ、かつ中身に非空行が 1 行以上ある。
      if (closed && nonblank) {
        printf "%s\n", buf
      }
    }
  ' "$tasks_path")

  [ -n "$result" ] || return 1
  printf '%s\n' "$result"
}

# ─── _SAV_RESOLVED_SOURCE ───
#
# 直近の `stage_a_verify_resolve_command` がどの解決手段でコマンドを確定したかを
# 記録するモジュールスコープ変数（design.md「Decision: source の stage_a_verify_run
# への伝達方法」採用案）。値域: structured-block / env-command / heuristic / 空（未解決）。
# `stage_a_verify_run` の Gate 3 bypass 判定が参照する。resolve 呼び出しの度に冒頭で
# 初期化され、前回呼び出しの残値で誤判定しない（NFR 3.1）。
#
# 注意（サブシェル境界）: `stage_a_verify_run` は resolve を command substitution
# （`cmd=$(stage_a_verify_resolve_command)`）で呼ぶため、サブシェル内で代入した
# `_SAV_RESOLVED_SOURCE` は親（run）のプロセスへ伝播しない。そこで resolve は確定した
# source を round counter と同じ流儀の sidecar（`.stage-a-verify-source`）へも書き出し、
# run 側は `_sav_read_resolved_source` でそれを読み戻して Gate 3 判定に使う。モジュール変数
# 代入（同一プロセス内呼び出し用）と sidecar 書き出し（サブシェル越え用）を併用することで、
# 設計の「source をモジュールスコープで共有する」意図をサブシェル境界でも成立させる。
_SAV_RESOLVED_SOURCE=""

# ─── _SAV_LAST_OUTCOME（run サマリ用 outcome 露出 / #239 task 5） ───
#
# 直近の `stage_a_verify_run` がどの outcome で抜けたかを記録するモジュールスコープ変数。
# 値域: success / skip / disabled / round1 / round2 / 空（未実行）。`stage_a_verify_run` は
# call site（run_impl_pipeline）と同一プロセスで呼ばれる（command substitution ではない）
# ため、ここに代入した値は call site から読める（_SAV_RESOLVED_SOURCE のサブシェル境界問題は
# resolve が command substitution で呼ばれることに起因するもので、run 自体には当てはまらない）。
# call site は本変数を読み `rs_record_sav` に渡して run サマリの `stage-a-verify=` を確定する。
#
# 設計意図: stage_a_verify_run の戻り値（0/1/2）だけでは success/skip/disabled の 3 状態
# （いずれも return 0）を区別できないため（Req 4.2 が skip/disabled の明示を要求）、戻り値
# 契約を変えずに outcome を別チャネル（本変数）で露出する。`sav_log` の既存出力フォーマット・
# 既存ログ行は一切変更しない（NFR 1.1）。本変数は変数代入のみの副作用で、ラベル遷移 / exit
# code / 既存ログ行に影響しない（NFR 1.2）。
_SAV_LAST_OUTCOME=""

# ─── _sav_source_path ───
#
# source sidecar の絶対パスを stdout に出す。round counter sidecar
# （`stage_a_verify_round_path`）と同じ spec dir 配下に `.stage-a-verify-source` を置く。
# worktree slot ごとの `$REPO_DIR` が自然に slot 隔離を担保する。
#
# 入力: 環境変数 REPO_DIR / SPEC_DIR_REL
# stdout: 絶対パス（必ず 1 行）
_sav_source_path() {
  printf '%s\n' "$REPO_DIR/$SPEC_DIR_REL/.stage-a-verify-source"
}

# ─── _sav_set_resolved_source ───
#
# 解決手段名 ($1) をモジュール変数 `_SAV_RESOLVED_SOURCE` と source sidecar の双方へ記録する。
# モジュール変数は同一プロセス内呼び出し用、sidecar は command substitution のサブシェル
# 境界を越えて `stage_a_verify_run`（親プロセス）へ source を伝える用途。sidecar 書き込み
# 失敗は致命ではない（Gate 3 が heuristic 同様の defense-in-depth に倒れるだけ）ため警告に留める。
#
# 入力: $1 = 解決手段名（structured-block / env-command / heuristic）
_sav_set_resolved_source() {
  _SAV_RESOLVED_SOURCE="$1"
  local path
  path=$(_sav_source_path)
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  printf '%s\n' "$1" > "$path" 2>/dev/null || \
    sav_warn "source sidecar 書き込みに失敗 path=$path source=$1（Gate 3 bypass 判定が defense-in-depth に倒れます）"
}

# ─── _sav_read_resolved_source ───
#
# source sidecar から直近の解決手段名を stdout に出す。不在 / 読み取り不能なら空文字。
# `stage_a_verify_run` が Gate 3 bypass 判定のために読む（サブシェル越えの source 共有）。
#
# 入力: 環境変数 REPO_DIR / SPEC_DIR_REL
# stdout: 解決手段名 1 行（不在時は空）
_sav_read_resolved_source() {
  local path
  path=$(_sav_source_path)
  if [ -f "$path" ]; then
    head -n1 "$path" 2>/dev/null | tr -d '[:space:]'
  fi
}

# ─── _sav_reset_resolved_source ───
#
# source sidecar を削除する。resolve 冒頭で前回値をクリアし、未解決（SKIPPED）時に
# 古い source が残って次回 run の Gate 3 判定を誤らせないようにする。不在時は no-op。
_sav_reset_resolved_source() {
  local path
  path=$(_sav_source_path)
  rm -f "$path" 2>/dev/null || true
}

# ─── stage_a_verify_resolve_command ───
#
# verify コマンドを 4 段の fallback 連鎖で決定論的に解決する（design.md「Components and
# Interfaces / stage_a_verify_resolve_command」/ Req 2）。解決順序:
#   1. 構造化 verify ブロック（stage_a_verify_extract_verify_block 成功）→ source=structured-block
#   2. `STAGE_A_VERIFY_COMMAND` env 非空 → source=env-command（散文誤認回避の固定 escape hatch）
#   3. ヒューリスティック抽出（stage_a_verify_extract_command 成功）→ source=heuristic
#   4. いずれも不可 → return 1（SKIPPED, Req 2.3）
# 各段で解決した手段名を `_SAV_RESOLVED_SOURCE` に記録し、`sav_log` で `source=<手段>` の
# 1 行を stderr に出す（NFR 2.1）。stdout はコマンド本体のみに保つ（複数行コマンドを
# そのまま返せるよう、source ログは stdout に混ぜない）。
#
# 構造化ブロックを env の上に置くため、ブロックを持たない既存 spec は第 1 段を素通りし
# env（設定済みなら）または heuristic に到達 → 本機能導入前と user-observable に同一
# （NFR 1.1）。design-less impl（tasks.md 不在）は第 1/第 3 段が return 1 となり、結果として
# 既存の env→SKIPPED 順序に一致する（Req 2.5）。
#
# design-less impl（tasks.md 不在）の SKIPPED は未実装の取りこぼしではなく、
# 「watcher は verify コマンドを推測しない」設計思想（#224 / #228 / #230）に基づく
# 意図された仕様である。tasks.md を持たない design-less impl で verify を推測すると
# 散文誤認事故（#160 / #219 / #221）と同根の問題に逆戻りするため、推測せず SKIP する。
# regression は Developer のテストと Reviewer の AC 判定で担保する（README「Stage A
# Verify Gate (#125)」節参照）。
#
# 入力: 環境変数 STAGE_A_VERIFY_COMMAND / REPO_DIR / SPEC_DIR_REL
# 戻り値: 0 = 解決成功 / 1 = SKIPPED（いずれの手段でも解決不能）
# stdout: 解決した shell コマンド（成功時のみ。構造化ブロック由来は複数行を改行込みで保持）
# stderr: source=<structured-block|env-command|heuristic> の 1 行（sav_log 経由、NFR 2.1）
# 副作用: モジュールスコープ変数 _SAV_RESOLVED_SOURCE を設定する
stage_a_verify_resolve_command() {
  # 前回呼び出しの残値で Gate 3 bypass を誤判定しないよう、毎回冒頭で初期化する
  # （モジュール変数 + sidecar の双方）。
  _SAV_RESOLVED_SOURCE=""
  _sav_reset_resolved_source

  local cmd

  # ── 第 1 段: 構造化 verify ブロック（input 契約・最優先） ──
  if cmd=$(stage_a_verify_extract_verify_block); then
    _sav_set_resolved_source "structured-block"
    sav_log "resolve source=structured-block" >&2
    printf '%s\n' "$cmd"
    return 0
  fi

  # ── 第 2 段: STAGE_A_VERIFY_COMMAND env（固定 escape hatch） ──
  if [ -n "${STAGE_A_VERIFY_COMMAND:-}" ]; then
    _sav_set_resolved_source "env-command"
    sav_log "resolve source=env-command" >&2
    printf '%s\n' "$STAGE_A_VERIFY_COMMAND"
    return 0
  fi

  # ── 第 3 段: ヒューリスティック抽出（後方互換 fallback） ──
  if cmd=$(stage_a_verify_extract_command) && [ -n "$cmd" ]; then
    _sav_set_resolved_source "heuristic"
    sav_log "resolve source=heuristic" >&2
    printf '%s\n' "$cmd"
    return 0
  fi

  # ── いずれも不可: SKIPPED ──
  return 1
}

# ─── _sav_state_dir ───
#
# round counter を置く永続化先ベースディレクトリを stdout に出す（#246）。
# 旧実装は worktree 配下（`$REPO_DIR/$SPEC_DIR_REL/`）に置いていたが、毎サイクル
# 冒頭の worktree reset（`git reset --hard` + `git clean -fdx`）で untracked/ignored
# が消去されるため counter も消え、連続失敗時に round が毎回 1 にリセットされて
# round=2（escalate）へ到達しない無限 round=1 ループが発生していた（#238/#239/#243）。
#
# これを避けるため、永続化先を **worktree 外**（`$HOME/.idd-codex/issue-watcher/` 配下、LOG_DIR
# と同流儀の `$HOME/.idd-codex/issue-watcher/<種別>/$REPO_SLUG`）へ移す。`$HOME/.idd-codex/issue-watcher/`
# は `$REPO_DIR` の外なので `git clean -fdx` の対象外＝worktree reset で消えない。
# テスト容易性のため新規 optional env var `STAGE_A_VERIFY_STATE_DIR` で base を上書き
# 可能にする（既定付き / 既存 env var 名と非衝突）。
#
# REPO_SLUG が未設定の場合は REPO から防御的に派生し silent fail を避ける（AGENTS.md 規約）。
#
# 入力: 環境変数 STAGE_A_VERIFY_STATE_DIR（任意） / REPO_SLUG（任意） / REPO（fallback 用）
# stdout: 絶対パス（必ず 1 行 / 末尾スラッシュなし）
_sav_state_dir() {
  local repo_slug="${REPO_SLUG:-}"
  if [ -z "$repo_slug" ]; then
    # REPO_SLUG 未設定時は REPO（owner/name）から派生。REPO も無ければ "_unknown"。
    repo_slug="$(printf '%s' "${REPO:-_unknown}" | tr '/' '-')"
  fi
  printf '%s\n' "${STAGE_A_VERIFY_STATE_DIR:-$HOME/.idd-codex/issue-watcher/state/$repo_slug}"
}

# ─── _sav_round_key ───
#
# round counter を Issue 番号 + branch で一意化するキーを stdout に出す（#246 / Req 3.x）。
# branch にはスラッシュ（`codex/issue-246-impl-...`）が含まれるためファイル名に使えるよう
# 非英数字（`/` 含む）を `-` へサニタイズする。BRANCH 不在時は SLUG、それも無ければ
# SPEC_DIR_REL 由来へ防御的にフォールバックし silent fail を避ける。
#
# 入力: 環境変数 NUMBER / BRANCH（任意） / SLUG（任意） / SPEC_DIR_REL（任意）
# stdout: ファイル名に使えるキー文字列（必ず 1 行）
_sav_round_key() {
  local number="${NUMBER:-0}"
  local ref="${BRANCH:-}"
  if [ -z "$ref" ]; then
    ref="${SLUG:-}"
  fi
  if [ -z "$ref" ]; then
    # SPEC_DIR_REL（docs/specs/<N>-<slug>）の basename から派生。
    ref="$(basename "${SPEC_DIR_REL:-_nobranch}")"
  fi
  # 英数字・ドット・アンダースコア・ハイフン以外を `-` へサニタイズ（`/` 含む）。
  local sanitized
  sanitized="$(printf '%s' "$ref" | tr -c 'A-Za-z0-9._-' '-')"
  printf '%s\n' "${number}-${sanitized}"
}

# ─── stage_a_verify_round_path ───
#
# round counter ファイルの絶対パスを stdout に出す。永続化先は worktree 外の
# state dir（`_sav_state_dir`）配下に Issue 番号 + branch で一意化したキー
# （`_sav_round_key`）で `<key>.stage-a-verify-round` を 1 つ置く（#246）。
# worktree slot / repo 隔離は state dir の REPO_SLUG と key の branch が担保する。
#
# 入力: 環境変数 STAGE_A_VERIFY_STATE_DIR / REPO_SLUG / REPO / NUMBER / BRANCH / SLUG
# stdout: 絶対パス（必ず 1 行）
stage_a_verify_round_path() {
  local base key
  base=$(_sav_state_dir)
  key=$(_sav_round_key)
  printf '%s\n' "$base/$key.stage-a-verify-round"
}

# ─── stage_a_verify_read_round ───
#
# round counter を stdout に整数で出す。ファイル不在は "0"（未失敗）。
# 不正な内容（非数値）は安全側で "0" にフォールバック。
#
# 入力: 環境変数 REPO_DIR / SPEC_DIR_REL
# stdout: 整数 1 行 ("0" / "1" / "2" 等)
# 戻り値: 0（read は失敗しない設計）
stage_a_verify_read_round() {
  local path
  path=$(stage_a_verify_round_path)
  local val=""
  if [ -f "$path" ]; then
    val=$(head -n1 "$path" 2>/dev/null | tr -d '[:space:]')
  fi
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$val"
  else
    printf '%s\n' "0"
  fi
}

# ─── stage_a_verify_bump_round ───
#
# round counter を 1 増やして永続化する。不在からの初回呼び出しは "1" を書く。
# 書き込み失敗（disk full / permission denied 等）は sav_error で警告し、
# 呼び出し元（_sav_handle_failure）は read_round の結果が 0 のままになるので
# 差し戻し挙動（round=1）に倒れる安全側設計。
#
# 戻り値: 0 = 書き込み成功 / 1 = 書き込み失敗
stage_a_verify_bump_round() {
  local path cur next
  path=$(stage_a_verify_round_path)
  cur=$(stage_a_verify_read_round)
  next=$((cur + 1))
  # spec dir 自体が存在しない場合は SKIPPED 経路で呼ばれていないはずだが、念のため mkdir -p
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  if ! printf '%d\n' "$next" > "$path" 2>/dev/null; then
    sav_error "round counter 書き込みに失敗 path=$path next=$next"
    return 1
  fi
  return 0
}

# ─── stage_a_verify_reset_round ───
#
# round counter sidecar を削除する。SUCCESS / codex-failed escalate 後に呼ぶ。
# 不在時は no-op（rm -f の挙動に従う）。
stage_a_verify_reset_round() {
  local path
  path=$(stage_a_verify_round_path)
  rm -f "$path" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# 以下は元 idd-codex-issue-watcher.sh では Region 2（mark_issue_failed 定義後の位置）に
# 置かれていた失敗ハンドラ / 統合ランナー。#181 Part 3 で Region 1 と 1 モジュールへ
# 統合した（source-before-execution により定義順序はランタイム挙動へ影響しない）。
# ─────────────────────────────────────────────────────────────────────────────

# ─── _sav_handle_failure ───
#
# stage_a_verify_run の失敗パス共通処理。round counter を bump し、
# round=1 なら Developer 差し戻し（Issue コメント投稿 + return 1）、
# round=2 以降なら mark_issue_failed 経由で codex-failed 化（return 2）。
# `codex-needs-iteration` ラベルは Issue 側には付与しない既存契約（NFR 1.2）を維持。
#
# 入力:
#   $1 = kind ("timeout" | "exit")
#   $2 = detail (timeout 秒 | exit code)
# 戻り値:
#   1 = Developer 差し戻し（次 tick で stage-a-verify 再評価）
#   2 = codex-failed 付与済み（watcher 退出）
_sav_handle_failure() {
  local kind="$1"
  local detail="$2"
  stage_a_verify_bump_round || sav_error "round counter 書き込みに失敗（差し戻し挙動を強制）"
  local round
  round=$(stage_a_verify_read_round)
  case "$round" in
    1)
      sav_log "round=1 outcome=codex-needs-iteration (Developer 差し戻し)"
      # round=1 差し戻しコメント。`codex-needs-iteration` ラベルは PR 専用契約であり
      # Issue 側には付与しない（NFR 1.2 / 既存 L2860 / L5989 契約）。次 tick で
      # Stage Checkpoint が START_STAGE=B を返しても、Stage B 開始前の
      # stage-a-verify ゲートで再評価される（design.md「stage-a-verify と
      # Stage Checkpoint の協調」参照）。
      local comment_body
      comment_body="🔁 stage-a-verify が失敗しました（round=1 / ${kind}=${detail}）。

\`tasks.md\` 末尾の verify タスク（build/test/lint）を Stage A Verify で独立再実行したところ、exit code が 0 以外でした。

- 検出されたコマンドの実行結果はログ \`${LOG:-(unknown)}\` を参照
- 次サイクルで Developer が再実装し、Stage B 開始前に stage-a-verify が再評価されます
- 修正後に \`./gradlew\` / \`npm test\` 等のローカル成功を確認してから commit/push してください

本機能の詳細: README「Stage A Verify Gate (#125)」節 / Issue #125"
      gh issue comment "$NUMBER" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1 || \
        sav_warn "gh issue comment 投稿に失敗（差し戻し挙動は継続）"
      return 1
      ;;
    *)
      sav_log "round=$round outcome=codex-failed (escalate to human)"
      stage_a_verify_reset_round
      local extra_body
      extra_body="stage-a-verify（\`tasks.md\` 末尾 verify タスクの独立再実行）が連続 ${round} 回失敗しました（${kind}=${detail}）。

- 検出コマンドの実行結果はログ \`${LOG:-(unknown)}\` を参照
- \`tasks.md\` 末尾の build/test/lint コマンドをローカルで通してから \`codex-failed\` を外してください
- 一時的に gate を skip したい場合は cron / launchd 側で \`STAGE_A_VERIFY_ENABLED=false\` を渡してください（Req 4.1 / NFR 1.1）

本機能の詳細: README「Stage A Verify Gate (#125)」節 / Issue #125"
      mark_issue_failed "stageA-verify" "$extra_body"
      return 2
      ;;
  esac
}

# ─── stage_a_verify_run ───
#
# Stage A Verify Module の統合ランナー。`run_impl_pipeline` の Stage A 成功直後・
# Stage B 開始直前から 1 度だけ呼ばれる。
#
# 入力 (環境変数経由):
#   REPO / REPO_DIR / SPEC_DIR_REL / NUMBER / LOG
#   STAGE_A_VERIFY_ENABLED / STAGE_A_VERIFY_TIMEOUT / STAGE_A_VERIFY_COMMAND
# 戻り値:
#   0 = SUCCESS / SKIPPED / DISABLED → Stage A 完全完了として続行
#   1 = FAILED (round=1) → 差し戻し済、次 tick で再試行
#   2 = FAILED (round=2 以降) → mark_issue_failed 済（codex-failed 付与）、watcher 退出
# 副作用:
#   - cron.log / $LOG に 1 行以上の `[$REPO] stage-a-verify:` ログ（NFR 4.1）
#   - round counter sidecar の read/bump/reset
#   - 失敗時に gh issue comment（round=1 差し戻し / round=2 は mark_issue_failed が発火）
#
# 不変条件:
#   - 1 回の呼び出しで `stage-a-verify:` 行を必ず 1 行以上出力（NFR 4.1）
#   - repository 由来の cmd は `codex sandbox ... bash -c` に **そのまま**渡し、watcher 側で
#     `&&` / `||` / `;` を解釈しない（Issue #51 Req 2.4）
#   - `STAGE_A_VERIFY_COMMAND` 由来の cmd は operator override として既存の直接実行 semantics
#     を維持する
stage_a_verify_run() {
  # run サマリ用 outcome（#239 task 5）。各 return 直前で確定する。
  _SAV_LAST_OUTCOME=""
  # ── Gate 1: DISABLED ──
  # `STAGE_A_VERIFY_ENABLED=false` 明示時のみ skip（`=false` 厳密一致、Req 4.1 /
  # NFR 1.1）。`:-true` で `unset` も既定有効として扱う。
  if [ "${STAGE_A_VERIFY_ENABLED:-true}" = "false" ]; then
    sav_log "DISABLED reason=env-opt-out"
    _SAV_LAST_OUTCOME="disabled"
    return 0
  fi

  # ── Gate 2: SKIPPED（解決できない / 一致なし）──
  # design-less impl（tasks.md 不在）は resolve の全段が解決失敗となりここで SKIPPED に倒れる。
  # これは意図された仕様であり（#230）、round counter を増やさず Stage A を続行する。
  local cmd
  if ! cmd=$(stage_a_verify_resolve_command); then
    sav_log "SKIPPED reason=no-verify-task-in-tasks-md"
    _SAV_LAST_OUTCOME="skip"
    return 0
  fi
  # resolve は command substitution のサブシェルで実行されるため、サブシェル内で代入した
  # `_SAV_RESOLVED_SOURCE` は親（run）へ伝播しない。resolve が併せて書き出した source sidecar
  # を読み戻して Gate 3 判定に使う（サブシェル越えの source 共有、design.md Decision 採用案）。
  local resolved_source
  resolved_source=$(_sav_read_resolved_source)

  # ── Gate 3: SKIPPED（抽出した cmd が keyword で開始しない）──
  # heuristic 経路の `stage_a_verify_extract_command` 側で行頭一致を保証しているが、
  # defense-in-depth として実行直前にも確認する（#160 Req 5.3）。bypass 条件:
  #   - `STAGE_A_VERIFY_COMMAND` env が非空（運用者が明示指定した escape hatch 経路、Req 4.1）
  #   - 構造化ブロック由来（source=structured-block）。Architect が設計 PR で人間レビュー済みの
  #     input 契約であり、env 経路と同じ信頼境界として Gate 3 を免除する（#224 Req 3.1 /
  #     design.md「Decision: source の stage_a_verify_run への伝達方法」採用案）
  if [ -z "${STAGE_A_VERIFY_COMMAND:-}" ] && [ "$resolved_source" != "structured-block" ]; then
    if ! _sav_cmd_starts_with_keyword "$cmd"; then
      sav_log "SKIPPED reason=cmd-does-not-start-with-keyword cmd=$(printf '%q' "$cmd")"
      _SAV_LAST_OUTCOME="skip"
      return 0
    fi
  fi

  # ── Execute ──
  local _timeout="${STAGE_A_VERIFY_TIMEOUT:-600}"
  # cmd の shell エスケープは printf %q で安全側に倒し、ログ復元性を確保する。
  sav_log "EXEC issue=#${NUMBER:-?} source=${resolved_source:-unknown} timeout=${_timeout}s cmd=$(printf '%q' "$cmd")"
  local rc=0
  if _sav_source_requires_sandbox "$resolved_source"; then
    # repository 由来 verify は Codex sandbox runner に委譲し、sandbox 確立失敗時も
    # watcher / cron ユーザーの非 sandbox `bash -c` へ fallback しない（Issue #51 Req 1.2, 1.3）。
    _sav_run_repo_command_in_codex_sandbox "$cmd" "$_timeout" >> "$LOG" 2>&1 || rc=$?
  else
    # operator が明示した STAGE_A_VERIFY_COMMAND は既存 semantics を維持する。
    # subshell `(cd && ...)` で cwd を REPO_DIR に隔離（NFR 5.1）。
    # `timeout --kill-after=10 "$_timeout"` で暴走を時間でも遮断し、タイムアウト到達時は
    # 子孫プロセスも SIGKILL する（NFR 5.2）。
    (cd "$REPO_DIR" && timeout --kill-after=10 "$_timeout" bash -c "$cmd") \
        >> "$LOG" 2>&1 || rc=$?
  fi

  # ── 結果分岐 ──
  case "$rc" in
    0)
      sav_log "SUCCESS exit=0"
      stage_a_verify_reset_round
      _SAV_LAST_OUTCOME="success"
      return 0
      ;;
    124)
      sav_warn "TIMEOUT timeout=${_timeout}s exit=124"
      local _hf_rc=0
      _sav_handle_failure "timeout" "$_timeout" || _hf_rc=$?
      # _sav_handle_failure 戻り値（1=round1 差し戻し / 2=round2 escalate）を run サマリ
      # outcome へマップ（Req 4.3）。戻り値はそのまま伝搬し既存契約を変えない（NFR 1.2）。
      case "$_hf_rc" in
        1) _SAV_LAST_OUTCOME="round1" ;;
        2) _SAV_LAST_OUTCOME="round2" ;;
      esac
      return "$_hf_rc"
      ;;
    *)
      sav_warn "FAILED exit=$rc"
      local _hf_rc=0
      _sav_handle_failure "exit" "$rc" || _hf_rc=$?
      case "$_hf_rc" in
        1) _SAV_LAST_OUTCOME="round1" ;;
        2) _SAV_LAST_OUTCOME="round2" ;;
      esac
      return "$_hf_rc"
      ;;
  esac
}
