<!-- SPDX-License-Identifier: MIT -->
<!-- Adapted from cc-sdd (https://github.com/gotalab/cc-sdd), MIT License, Copyright (c) gotalab -->

# tasks.md 生成ルール

Architect が出力する `tasks.md` は、Developer が迷わず実装を進められる粒度と、
トレーサビリティを持つアノテーションを持たせます。

## 基本フォーマット

### 単純タスクのみの場合

```markdown
- [ ] 1. <タスクの要約>
  - <詳細項目（必要な場合のみ）>
  - _Requirements: 1.1, 2.3_
```

### 親タスクと子タスクの構造を取る場合

```markdown
- [ ] 1. <親タスクの要約>
- [ ] 1.1 <子タスクの記述> (P)
  - <詳細項目 1>
  - <詳細項目 2>
  - _Requirements: 1.1, 1.2_
  - _Boundary: UserService, AuthController_
  - _Depends: 2.1_
```

## Checkbox 形式の必須化

`tasks.md` の **すべての実装タスク行**は、行頭が `- [ ]`（未完了）または `- [ ]*`（deferrable
印、後述）の checkbox 形式で開始することを **必須** とします。これは Developer の resume
機能（`IMPL_RESUME_PROGRESS_TRACKING=true`、Issue #67 / #112 以降の既定）が `- [ ]` → `- [x]`
の markdown checkbox 編集を進捗の **正本** として読む前提を確実に成立させるためです。

- **親タスク行・子タスク行のいずれにも checkbox を付与すること**
  （例: `- [ ] 1. ...` / `- [ ] 1.1 ...` のように親も子もリスト項目 + checkbox で書く）
- **markdown header のみ**（例: `## T-01: タスク名` / `### Task 1` / `#### 1.1 子タスク`）で
  タスクを表現することは **禁止**。タスク行は必ずリスト項目 (`- [ ]`) で書くこと
- 詳細項目（`_Requirements:_` 等のアノテーション行や説明箇条書き）は checkbox を持たない
  通常のリスト項目で構わない（タスクそのものを表現する行のみが checkbox 必須）
- 判定パターン（POSIX 互換 ERE）: `^- \[[ x]\]\*? ([0-9]+\.|[0-9]+\.[0-9]+(\.[0-9]+)*) ` — 行頭が
  `- [ ]` / `- [ ]*` / `- [x]` / `- [x]*` のいずれかで、続けて **最上位タスクは整数 ID + `.`
  + 半角スペース**（例: `- [ ] 1. <名前>`）、**子タスクは階層 ID + 半角スペース**（例:
  `- [ ] 1.1 <名前>` / `- [ ] 2.1.3 <名前>`）で始まる行をタスク行と認識する。通常 checklist
  の `- [ ] 1 PR ...` のように整数の後ろに `.` が無い行は、task ID `1` として扱わない

> **Mechanical Check との対応**: 上記必須化は Architect の自己レビュー時に
> [`design-review-gate.md`](./design-review-gate.md) の **tasks.md checkbox enforcement check**
> Mechanical Check が機械的に検証します（checkbox 不在のタスク行を 1 件でも検出した場合は
> 違反として報告し、Architect が `- [ ] N. <親タスク名>` / `- [ ] N.M <子タスク名>` 形式に
> 修正してから確定する）。per-task 実行対象の `tasks.md` では、少なくとも 1 件の
> watcher-compatible parent checkbox task（`- [ ] N. <title>`）が必要です。

## アノテーション

| キー | 必須? | 用途 |
|---|---|---|
| `_Requirements:_` | **必須** | 対応する requirement ID を列挙（numeric のみ、例: `1.1, 2.3`）。説明や括弧書きは付けない |
| `_Boundary:_` | 並列可タスク `(P)` でのみ必須 | 担当するコンポーネント名を列挙（design.md の Components 名と一致） |
| `_Depends:_` | 非自明な cross-boundary 依存のみ | 先行するタスク ID を列挙。自明な順序依存は省略 |

## Task Boundary Contract

`_Requirements:_` は per-task review の正準 scope です。各 task の `_Requirements:_` には、その task
完了時点で実装・テスト・レビュー可能な AC だけを列挙します。後続 task で初めて満たす AC や、
後続 task のテスト作業がないと検証できない coverage AC を先行 task の `_Requirements:_` に含めては
いけません。

- `_Requirements:_` に regression coverage / failure path / safety fallback / runtime behavior change
  の AC を含める場合、同 task の詳細項目に対応する test work（regression test、failure path test、
  safety fallback test、または shell-level test）を明記する
- 実行時挙動を変更する task は、原則として同 task に最低限の regression test または shell-level test
  を含める
- 対応 test work を後続 task に defer する場合、先行 task の `_Requirements:_` から未実施の
  coverage AC を外し、後続の dedicated test task 側の `_Requirements:_` にだけその AC を列挙する
- partial な先行 task と coverage task の関係は、先行 task の `_Boundary:_` または後続 task の
  `_Depends:_` で明示する。特に coverage task は、どの先行 task の検証を補完するかが分かるよう
  `_Depends:_` を付ける
- `- [ ]*` は既存の optional / deferrable なテストタスク表記として扱い、未完了の deferred test
  task を先行 task の per-task review の `missing test` 判定対象へ混ぜない

### 判断の具体例（同 task にテストを含めるか / 後続へ回すか）

抽象原則を具体化するための例です。迷ったら「先行 task 完了時点で Reviewer が `missing test` と
判定するのが自然か」で考えます（自然なら同 task にテストを置く）。

**原則として同 task にテストを含める**（実行時挙動 / 受入基準に直結するため）:

- 依存解決などで `gh` API 失敗時に unresolved 扱いへ倒す、`jq` parse 失敗時に WARN を出して
  誤判定しない等の **failure path / safety fallback** を変える
- **exit code / 戻り値の語義**を変える
- **ラベルの追加 / 削除 / 遷移条件**を変える
- GitFlow / single-branch など **mode ごとに分岐する本体ロジック**を変える
- 既存 env var の **default / 後方互換**に関わる分岐を追加する

**後続の dedicated test task へ defer してよい**（実挙動をまだ変えない / 単独では検証対象が無い）:

- テスト helper / fixture の抽出だけを先に行い、実挙動は変更しない
- 複数 task の部品が揃って初めて意味を持つ E2E smoke を最後にまとめる
- README / 設計メモのみを更新し、実行時挙動を変えない

defer する場合は、上記 boundary 規約（先行 task の `_Requirements:_` から未実施 coverage AC を外し、
task 本文と `_Depends:_` で「このタスクは部分実装でテストは task N」と明示）を必ず併用します。

## 並列マーカー `(P)`

- **並列実行可能**なタスクのみ末尾に ` (P)` を付ける
- 並列実行できないタスク（順序依存のあるタスク）には付けない（デフォルト=直列）
- `(P)` を付けるなら `_Boundary:_` を必須とする（並列時の競合境界を明示するため）

## ID 規則

- **numeric 階層 ID** のみ使用: `1`, `1.1`, `1.2`, `2`, `2.1` ...
- `T-01` や `FR-01` 形式の英字 ID は使わない（requirements.md の numeric ID と揃えるため）

## Optional なテストタスク

deferrable なテスト追加タスクは checkbox を `- [ ]*`（アスタリスク付き）と記述し、詳細項目で
対応する AC を説明します。**`- [ ]*` も checkbox 形式の一種**として扱われ、上記
「Checkbox 形式の必須化」節および Mechanical Check の判定で違反として報告されません:

```markdown
- [ ]* 1.3 統合テスト追加
  - 対応する受入基準のうち、現時点でカバレッジが不足する項目を補完
  - _Requirements: 1.1, 1.2_
```

## ガイドライン

- 各タスクは **1 commit 単位**で独立に完了可能な粒度にする
- 合計タスク数は **3〜10 件を目安**（多すぎる場合は design の File Structure Plan が大きすぎる可能性）
- 対応する `_Requirements:_` を必ず明示（トレーサビリティ確保）
- 親タスクに対する子タスクは、実装順序に沿って並べる

> **件数 enforcement との関係**: 上記「3〜10 件目安」は設計指針として有効ですが、Architect の
> 自己レビュー時に [`design-review-gate.md`](./design-review-gate.md) の **Budget overflow check**
> Mechanical Check が同じ件数を機械的に判定します（≤10 件 pass / 11〜13 件 consolidate→split /
> ≥14 件 forced split）。10 件以下の正常ケースで挙動は変化しません。カウントは **最上位
> numeric ID タスク**（`- [ ] 1.` / `- [ ] 2.` …）のみが対象で、子タスク（`1.1` 等）や deferrable
> テストタスク（`- [ ]*`）は数えません。

## turn 予算ガイドライン（per-task Implementer ループ運用時の粒度指針）

`PER_TASK_LOOP_ENABLED=true` の per-task Implementer ループ運用では、`tasks.md` の **1 タスクごと**に
fresh な Codex session で Implementer が起動され、各タスクの turn 数は `DEV_MAX_TURNS`（既定 60）
を上限として **タスク間で独立に消費**されます。前のタスクで余った turn を次のタスクへ繰り越す
ことはできません。

### fresh session 仕様（前提）

- per-task Implementer は **タスクごとに新規 Codex session で起動**する。session 状態（過去の
  reasoning / context）はタスク間で持ち越されず、turn カウンタも各タスクで 0 から始まる
- 一度 `error_max_turns`（`DEV_MAX_TURNS` 到達による Codex CLI 自発 exit）で失敗したタスクは、
  再試行時も **同一タスク内で再び 0 turn から開始**する（過去 turn は再利用できない）
- したがって「タスク間の turn 累積を増やす」「Issue 全体の turn 枠を引き上げる」といった発想は
  per-task ループ運用上 **無効**であり、turn 予算は常に「1 タスクが `DEV_MAX_TURNS` に収まるか」
  だけが効く

### 粒度指針（推奨）

- **1 タスクは `DEV_MAX_TURNS`（既定 60）以内に収まる粒度を目安とする**。設計段階で「実装 + テスト +
  軽い refactor が 1 commit で完了する」程度の小ささに刻んでおくと、`error_max_turns` の発生確率を
  運用前に下げられる
- **frontend / UI / テストが重い責務は細かく切る**:
  - 「UI = 1 component + 1 test = 1 task」を目安とする（複数 component を 1 タスクに束ねない）
  - UI / frontend は描画・状態・スタイル・テストのコンテキストを並行で抱えるため turn 消費が
    膨らみやすく、1 タスクに複数 component を束ねると `DEV_MAX_TURNS` 到達リスクが顕著に上がる
  - Visual regression / snapshot 系テストの追加が必要な場合は別タスクに分離してよい
- **重い子タスクは親に束ねず、トップレベル task に昇格させる**:
  - 子タスク（`1.1` / `1.2` …）の合計 turn 見積もりが親の 1 つあたり目安を上回りそうなら、子を
    親から切り出して別の最上位 task（`2` / `3` …）に昇格させる
  - 最上位 task は独立 commit 単位として消化されるため、昇格させた方が turn 予算管理が容易
- **既存ガイドライン（「3〜10 件目安」「checkbox 必須化」）との関係**: 本指針は上記ガイドラインの
  **上位ではなく補助**として機能する。件数上限（≤10 件）に収まる範囲で、各タスクの turn 予算を
  さらに意識する形で適用すること

### 強度（推奨どまり / Mechanical Check 不在）

本節のガイドラインは **推奨（指針）レベル**であり、`design-review-gate.md` の Mechanical Checks
（Budget overflow check / checkbox enforcement check / verify block well-formed check）のような
機械的な reject 条件としては宣言しません。理由は以下:

- タスクごとの turn 消費量は実装難度・既存コードベースの状態・テスト規模に依存し、設計段階で
  正確な事前見積もりが難しい
- 数値（`DEV_MAX_TURNS=60`）は将来変更され得るため、機械 enforcement に紐付けると追従コストが
  発生する
- 推奨に留めることで Architect / 人間設計者が判断材料として活用しつつ、reject 判定の自動化は
  既存 Mechanical Checks に集約できる

> **根拠**: per-task ループは fresh session 仕様により turn 数がタスク単位で独立消費されるため、
> 設計段階で 1 タスクの turn 予算を意識することが、運用時の `error_max_turns` 発生確率を直接
> 下げる最も効果の高い手段になる。`DEV_MAX_TURNS` の恒久引き上げ（後述 README の
> Troubleshooting 節参照）はタスク粒度の不適合を覆い隠す対症療法であり、根本的にはタスク粒度の
> 是正で対処することが推奨される（詳細な対応優先順は README「`per-task-implementer-failed` /
> `error_max_turns` 対応」節を参照）。

### Architect 自己レビュー時の検出観点との相互参照（#292）

本節（タスク生成段階の粒度指針）と対になる **Architect 自己レビュー段階の検出観点** は、
[`design-review-gate.md`](./design-review-gate.md) の「Task turn 予算 sanity check（過大 task
検出）」節を参照してください。同節では本節の粒度指針を踏まえた上で、`tasks.md` 確定直前に
点検すべき 5 つの検出シグナル（異種責務同居 / 兄弟比突出 / 新規ファイル件数の目安 / 重い子タスク
同居 / turn コスト密度差）と是正方針（責務不変の粒度分割）を観点として列挙しています。生成
（本節）と自己レビュー検出（`design-review-gate.md` 側）の双方を参照することで、過大 task の
発生確率を運用前に下げられます。

## 構造化 verify ブロック（stage-a-verify gate の input 契約）

stage-a-verify gate (#125) は Stage A（Developer 実装）完了直前に、`tasks.md` 中の
build/test/lint コマンドを watcher が独立再実行し、Developer の自己申告だけで build 不通が
Stage A を通過するのを防ぐゲートです。従来はコマンド特定を「verify keyword を含む行＝コマンド」
とみなすヒューリスティック抽出で行っていたため、ツール名で始まる散文（例: `- shellcheck 警告
ゼロを確認`）を誤ってコマンドとして実行する誤発火が繰り返し発生していました（#160 / #219 / #221）。

これを避けるため、Architect は再実行させたい verify コマンドを **センチネル付きの構造化ブロック**で
`tasks.md` に明示宣言できます（#224）。構造化ブロックがあると watcher はヒューリスティック推測を
行わず、ブロック内のコマンドのみを決定論的に実行対象として解決します。

### canonical 書式

センチネルコメント `<!-- stage-a-verify -->` の **直後**に fenced code block を 1 つ置き、
その中身に実行するコマンドを書きます:

```markdown
<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/idd-codex-modules/*.sh && bash docs/specs/<番号>-<slug>/test-fixtures/test-extract.sh
```
```

書式規約（well-formed 条件）:

- **センチネル**: 行を trim した結果が厳密に `<!-- stage-a-verify -->` に一致する行。前後の空白は
  許容するが、行内に他テキストを混ぜないこと
- **直後性**: センチネル行の次行以降で空行を任意個スキップした後の **最初の非空行が fence 開始**
  （trim 後 ` ``` ` 始まり）であること。fence 以外の非空行が先に来ると malformed として扱われる
- **fence 言語タグ**: ` ```sh ` / ` ```bash ` 等の言語タグは許容（タグ自体はコマンド中身に含まれない）
- **fence 終了**: 次に現れる ` ``` ` 行で閉じる。EOF まで閉じないと malformed
- **中身**: fence 内が trim 後すべて空だと malformed（空ブロック）。非空なら元の改行・インデントを
  保持してそのまま実行される

### 中身は散文ではなく実行可能コマンド

ブロックの中身は **実行可能なコマンドそのもの**として記述します（散文・説明箇条書き・タスク記述を
書かない）。複数行コマンドや `&&` / `||` / `;` 連結を含められます。watcher は中身を `bash -c` に
**そのまま**渡し、連結記号を watcher 側で解釈しません:

```markdown
<!-- stage-a-verify -->
```sh
shellcheck install.sh setup.sh &&
  actionlint .github/workflows/*.yml
```
```

### 既存 checkbox 規約・numeric ID 階層規約との非干渉

構造化 verify ブロックは **タスク行ではなく補助ブロック**です。本ファイル「Checkbox 形式の
必須化」節および [`design-review-gate.md`](./design-review-gate.md) の Budget overflow check /
checkbox enforcement check の判定パターンは、いずれも行頭 `- [ ]` / `- [ ]*` + watcher-compatible
numeric ID marker（親は `N.`、子は `N.M[.K...]`）で始まるタスク行を対象とします。センチネル行
（`<!-- ... -->`）も fence 行（` ``` `）も fence 中身も
これらの判定パターンに **マッチしない**ため、ブロックを追加してもタスク件数カウント・checkbox
enforcement は一切影響を受けません。

### 配置場所

ブロックの配置場所は任意です（パースはセンチネル基準で見出しに依存しません）。推奨は `tasks.md`
末尾の `## Verify` 見出し配下にまとめる形ですが、`## Verify` 見出し自体は必須ではありません:

```markdown
## Verify

本 spec の実装後、watcher が再実行すべき verify コマンドを以下の構造化ブロックで宣言する。

<!-- stage-a-verify -->
```sh
npm test && npm run lint && npm run build
```
```

### verify 対象が無い spec はブロックを省略できる

verify すべき build/test/lint コマンドが存在しない spec（純ドキュメント変更等）では、構造化ブロックを
省略して構いません。その場合 watcher は `STAGE_A_VERIFY_COMMAND` env → ヒューリスティック抽出 →
SKIPPED の順に fallback します（解決順序の詳細は README「Stage A Verify Gate (#125)」節を参照）。
構造化ブロックを持たない既存 spec は従来どおりヒューリスティック / env 経路で動作します（後方互換）。

なお、`design` モードを経由せず Architect が `tasks.md` を生成しない **design-less impl**
（tasks.md 不在。#204 等）は、構造化ブロック / ヒューリスティック抽出の入力となる `tasks.md`
自体が存在しないため stage-a-verify gate の **対象外（SKIP）**となります。これは未実装の
取りこぼしではなく「watcher は verify コマンドを推測しない」設計思想（#224 / #228 / #230）に
基づく **意図された仕様**であり、design-less impl の regression は Developer が実行するテストと
Reviewer の AC 判定で担保します（詳細は README「Stage A Verify Gate (#125)」節の
「design-less impl（tasks.md 不在）は gate 対象外」を参照）。

## 参考

- [cc-sdd `tasks.md` テンプレート](https://github.com/gotalab/cc-sdd/blob/main/.kiro/settings/templates/specs/tasks.md)
