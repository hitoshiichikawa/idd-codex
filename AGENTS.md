# プロジェクトガイド（Codex CLI 全エージェント共通）

このファイルは Codex CLI 本体および全サブエージェントが毎回参照するプロジェクト憲章です。
**すべてのエージェントは、作業開始前にこのファイルを読み直してください。**

---

## このリポジトリについて

**idd-codex はツール / テンプレートリポジトリ** です。他の repo に配置する開発ワークフローテンプレートと、ローカル watcher スクリプト一式を提供します。

**重要: self-hosting (dogfooding)**: idd-codex 自身も idd-codex のワークフロー対象 repo として運用しています（`repo-template/` 一式を root にも配置）。**あなたが編集している watcher スクリプトやテンプレートそのものが、次回 cron 実行であなた自身を動かす**ことを意識してください。後方互換性と冪等性が極めて重要です。

**構成要素**:

- `local-watcher/` — ローカル実行用 bash スクリプト (`idd-codex-issue-watcher.sh`, Triage prompt template)
- `repo-template/` — 他 repo に配置するテンプレート (AGENTS.md, agents, rules, ISSUE_TEMPLATE, labels script)
- `install.sh` / `setup.sh` — インストーラ（ユーザースコープ、sudo 不要）
- `README.md` — 設計思想とセットアップ手順の主要ドキュメント

アプリケーションコード（JS/TS/Python バックエンド等）はありません。本体は **bash + markdown + GitHub issue template YAML**。

---

## 言語方針（思考言語と出力言語）

idd-codex self-hosting 上で稼働するすべての Codex エージェント（PM / Architect / Developer /
Reviewer / PjM）は、以下の方針で **内部思考言語と出力言語を使い分ける**こと。reasoning トークン
消費を抑制しつつ、運用者・レビュワーの可読性を維持するための規約です。

### 基本原則

- **内部思考（reasoning / chain-of-thought / 内部スクラッチパッド）は英語ベース**で行う
  （英語の方が同等内容を表現するのに必要なトークン数が少ないため）
- **ユーザーが直接読むアウトプットは日本語ベース**で出力する（運用者の可読性優先）
- 言及されていない種別は **既定で日本語ベース**を選択する（fallback ルール）

### 種別ごとの言語選択

| 種別 | 言語 | 補足 |
|---|---|---|
| LLM の内部 reasoning / scratchpad | **英語** | ユーザーに見えない領域。トークン効率優先 |
| GitHub Issue / PR の本文・コメント・レビューコメント | **日本語** | 運用者・レビュワー向け |
| `docs/specs/<番号>-<slug>/` 配下の markdown（`requirements.md` / `design.md` / `tasks.md` / `impl-notes.md` / `review-notes.md`） | **日本語** | 成果物の本文 |
| EARS トリガーキーワード（`When` / `If` / `While` / `Where` / `shall`） | **英語固定** | `.codex/rules/ears-format.md` の規約に従う。可変部のみ日本語可 |
| Conventional Commits プレフィックス（`feat` / `fix` / `docs` / `refactor` / `chore` / `test`） | **英語固定** | prefix と scope は ASCII |
| ブランチ名（`codex/issue-<番号>-<slug>`） | **英語固定** | slug は ASCII（lowercase ハイフン区切り） |
| 識別子・コマンド名・ファイルパス・env var 名・ラベル名 | **英語固定** | コード／運用と整合させる |
| コミットメッセージ本文（prefix 後の説明部分） | **日本語ベース** | 既存 git log 慣習に準拠（混在許容、技術用語の英語そのまま記述は可） |
| PR タイトル | **日本語ベース** | prefix（`feat(scope):` 等）は英語固定、説明部分は日本語 |
| bash スクリプトのログ出力（`echo` 文字列等） | **混在許容** | 既存実装に準拠。新規追加分は日本語ベースを推奨するが、既存実装の書き換えは本方針の対象外 |
| `.codex/agents/*.md` のエージェント定義本文 | **日本語** | 人間運用者向けの指示書きであり、エージェント自身の出力ではない |

### 既存規約との整合

- EARS の英語固定トリガーキーワードは本方針の例外規定に含まれる（reasoning 中もそのまま英語表記を保持）
- Conventional Commits / ブランチ命名規約 / 識別子は英語固定。日本語化しない
- 本方針と `.codex/rules/*.md` の他ルールに矛盾が生じた場合、エージェントは独自解釈で確定せず
  PM / 人間にエスカレーションする

---

## 技術スタック

- **スクリプト**: bash 4+ (Linux / macOS / WSL)
- **依存 CLI**: `gh`, `jq`, `flock`（Linux 標準、macOS は `brew install util-linux`）, `git`, `codex`
- **GitHub Actions**: Codex 版では未配布。公式・検証済み経路が固まるまで local watcher のみ
- **モデル**: Triage は `gpt-5.4-mini`、本実装は `gpt-5.5` をデフォルト
- **ランタイム追加なし**: Node.js / Python 等は依存しない

---

## コード規約

### bash スクリプト（本リポジトリのコア成果物）

- 冒頭で `set -euo pipefail` を必ず宣言
- 変数展開は常にクォート (`"$var"`, 配列は `"${arr[@]}"`)
- `which` ではなく `command -v` でコマンドの存在確認
- `~` ではなく `$HOME` を使う（cron は `~` を展開しない事故が起きる）
- ファイル冒頭のコメントで「用途 / 配置先 / 依存 / セットアップ参照先」を明記する（現行 `idd-codex-issue-watcher.sh` / `install.sh` 参照）
- 環境変数は `"${VAR:-default}"` で override 可能にし、**既存 env var 名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL` 等）は後方互換性のため壊さない**
- 破壊的操作（`git checkout`, `rm -rf`, `git push --force*`）の前に前提条件を check
- エラーメッセージは `>&2` に出す。標準出力は機械可読な結果用に予約する

### markdown（テンプレート類）

- h1 はファイル先頭 1 つのみ、以降は階層を一貫させる
- コードフェンスには言語タグを付ける（` ```bash ` / ` ```yaml ` 等）
- 内部リンクは相対パス、コード箇所は `file_path:line_number` 形式
- 絵文字はステータス表示に限定して節度を持つ

### yaml (GitHub Actions workflow)

- `actionlint` をクリアすること
- `permissions:` は最小権限に絞る
- secrets は `${{ secrets.NAME }}` で参照、echo しない

### 全体共通

- 単一責務の関数・セクションに分割する
- 設定値（URL、path prefix、default 値）はファイル冒頭の config ブロックにまとめる
- silent fail を作らない（失敗は exit code / log で明示）

---

## テスト・検証

**本リポジトリには unit test フレームワークはありません**。検証は以下の組み合わせ:

### 静的解析

- `shellcheck local-watcher/bin/*.sh install.sh setup.sh .github/scripts/*.sh` — 警告ゼロを目指す（accepted な info 級 false-positive は root の `.shellcheckrc` で抑止＝`SC2317`/`SC2012`。これにより stage-a-verify の素 `shellcheck` verify ブロックも accepted baseline を反映して通る）
- GitHub Actions workflow は Codex 版では未配布のため、workflow YAML の検査対象はありません
- `diff -r .codex/agents repo-template/.codex/agents` — root↔repo-template の agents の byte 一致検証（差分が出たら二重管理規約違反。片系統だけ更新したドリフトを検出する）
- `diff -r .codex/rules repo-template/.codex/rules` — root↔repo-template の rules の byte 一致検証（差分が出たら二重管理規約違反。片系統だけ更新したドリフトを検出する）

### 手動スモークテスト（変更した成果物ごとに実施）

- **`install.sh` 変更時**: 使い捨て scratch repo を `/tmp` に作り、`./install.sh --repo /tmp/scratch` を実行して冪等性とファイル配置を確認
- **`setup.sh` 変更時**: `IDD_CODEX_DIR=/tmp/setup-test bash setup.sh` で新規クローン / 既存ディレクトリ双方で動くこと
- **`idd-codex-issue-watcher.sh` 変更時**:
  - cron-like 最小 PATH での依存解決: `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'command -v codex gh jq flock git'`（`local-watcher/bin/idd-codex-issue-watcher.sh` 冒頭の PATH prepend を経由して解決されること）
  - dry run: `REPO=owner/test REPO_DIR=/tmp/test-repo $HOME/bin/idd-codex-issue-watcher.sh` を対象なし状態で流し、`処理対象の Issue なし` で正常終了すること
  - E2E: 本リポジトリに test issue を立てて watcher が Triage → PR 作成までできるか

### 冪等性

- `install.sh` / `setup.sh` / `.github/scripts/idd-codex-labels.sh` は再実行で破壊しない
- 既存ファイルがある場合は `.bak` バックアップまたは `--force` で opt-in 上書き

### dogfooding (E2E)

- 大きい機能変更は、本 repo 自身に対して `codex-auto-dev` Issue を立てて watcher が正しく拾えるかで最終確認する

---

## ブランチ・コミット規約

- ブランチ名: `codex/issue-<番号>-<slug>` を原則とする
- コミット: [Conventional Commits](https://www.conventionalcommits.org/) に準拠
  - `feat(scope): ...` / `fix(scope): ...` / `docs(scope): ...` / `refactor(scope): ...` / `chore(scope): ...` / `test(scope): ...`
  - 典型的な scope: `watcher` / `install` / `setup` / `workflow` / `codex`（`repo-template/AGENTS.md`）/ `readme` / `labels`
- 1 PR = 1 Issue を原則とする（スコープが膨らむ場合は PM が分割提案）

---

## 禁止事項

- base ブランチ（既定 `main`、`BASE_BRANCH` 設定によっては `develop` 等）への直接 push
- `.env` / Secrets 実値のコミット、スクリプト内 API Key ハードコード
- **後方互換性を壊す変更を無告知で入れる**（既存 env var 名変更 / cron 登録文字列の変更 / ラベル名変更 / exit code 意味変更）。破る場合は README に migration note を書き、必要なら deprecation 期間を設ける
- **sudo を必要とする手順の追加**（idd-codex はユーザースコープ前提。`install.sh` / `setup.sh` の root 実行検知を外さない）
- モデル ID のハードコード（env default で override 可能にする。`TRIAGE_MODEL` / `DEV_MODEL` 参照）
- **opt-in gate なしで新しい外部サービス呼び出しを有効化**。**注**: #112 で実施した「既に main で稼働しデフォルト false で配置された機能」のデフォルト反転（`MERGE_QUEUE_ENABLED` 等 8 種）は本禁止事項の対象外。新規外部サービス呼び出しの追加ではなく、既存機能のデフォルト値変更であるため。詳細は README の「オプション機能一覧」節の migration note を参照
- `repo-template/**` の破壊的変更を、既 installed の consumer repo への影響評価なしに入れる
- テストをコメントアウトして PR を出す（scope 外に分離する場合は Issue を切る）

---

## エージェント連携ルール

- **Product Manager** は実装方針を書かない。要件と受入基準の明確化に専念
- **Architect**（条件付き起動）は要件を変更しない。モジュール構成 / シェルスクリプト分割 / env var 設計 / 後方互換性方針 / ラベル体系 / template 互換性等の設計に専念
- **Developer** は仕様を追加・解釈しない。不明点は PM / Architect に差し戻す
- **Reviewer**（impl 系モードで自動起動）は Developer 完了後の独立レビューのみを担当し、要件・設計・実装・テストの追加や書き換えを行わない。判定は AC 未カバー / missing test / boundary 逸脱 の 3 カテゴリに限定する（スタイル / lint 観点では reject しない）
- **Project Manager** はコードを変更しない。PR 作成と進捗管理に専念
- Architect は Triage の `needs_architect: true` 時のみ PM と Developer の間に挟まれる
- Architect が起動した Issue では **設計 PR ゲート**を経由する
- Reviewer は impl / impl-resume の Developer 完了直後に **独立 context** で起動され、reject 時は Developer に最大 1 回だけ自動差し戻し、再 reject では `codex-failed` で人間に委ねる（差し戻しループは Reviewer 最大 2 回 / Developer 最大 2 回で打ち切り）
- Developer は `design.md` / `tasks.md` を書き換えない（人間レビュー済みのため）。矛盾は PR 本文「確認事項」で指摘する
- 成果物は `docs/specs/<番号>-<slug>/` 配下に保存する
  - `requirements.md`（PM）— EARS 形式の AC、numeric 階層 ID
  - `design.md`（Architect）— File Structure Plan / Components and Interfaces / Traceability
  - `tasks.md`（Architect）— `_Requirements:_` / `_Boundary:_` / `_Depends:_` / `(P)` アノテーション
  - `impl-notes.md`（Developer、補足）
  - `review-notes.md`（Reviewer、impl 系モードのみ）— 判定結果と Findings / 最終行 `RESULT: approve|reject`

### idd-codex 特有の設計上の注意

- **`local-watcher/bin/idd-codex-issue-watcher.sh` の変更**: 既稼働の cron / launchd を壊さない（env var 名、exit code 意味、ログ出力先、ラベル遷移契約を保つ）
- **`repo-template/**` の変更**: 既に installed の consumer repo にも影響する（`install.sh` 再実行で上書きされる）。破壊的変更は migration note 必須
- **`idd-codex-labels.sh` のラベルセット**: ラベル追加は OK、既存ラベル削除 / 名前変更は deprecation 期間を経てから
- **モデル ID デフォルト更新**: 既存ユーザが明示 override している前提で、env default のみ更新
- **README との二重管理**: 挙動を変えたら必ず README の該当箇所も同じ PR で更新する
- **root `.codex/{agents,rules}/` と `repo-template/.codex/{agents,rules}/` の二重管理**: 両者は別系統（root = idd-codex self-hosting が使用 / `repo-template/` = `install.sh --repo` で consumer repo に配布）。片方だけ更新すると **consumer に変更が届かない**か **idd-codex 自身が古い規約で動く**ドリフトが発生する（実例: #224 の構造化 verify ブロック規約・architect.md が root のみ更新で consumer 未配布／per-task ループ・BLOCKED 規約が repo-template のみで root の Developer・Reviewer に欠落）。`.codex/agents/*.md` / `.codex/rules/*.md` を変更したら **同一 PR で両系統に byte 一致で反映する**こと（逆方向も同様）。agents の base ブランチ参照は両系統とも `<BASE_BRANCH>` プレースホルダに統一し、root にも具体値 `main` を焼き込まない（orchestrator が解決値を prompt の `Compared to:` ヘッダで渡すため idd-codex でも正しく動く）。反映後に `diff -r .codex/agents repo-template/.codex/agents` と `diff -r .codex/rules repo-template/.codex/rules` が空であることを確認する。**AGENTS.md / README は consumer 固有内容を持つため本規約の対象外**（それぞれ root 用 / `repo-template/` 用に内容が異なってよい）
- **Phase B Promote Pipeline (#15)**: `PROMOTE_PIPELINE_ENABLED=true` の **明示的 opt-in 制**で、未設定 / `false` の場合は導入前と完全に同一の挙動を保つ。2-branch model（`BASE_BRANCH != PROMOTION_TARGET_BRANCH`）でのみ起動する。`codex-staged-for-release` ラベルは #100 の人間付与運用と同一ラベルを共有し、source 区別はしない。revert / promote はすべて `--force-with-lease` または fast-forward 限定で `--force`（無条件）は使わない

---

## 機能追加ガイドライン（コード・概念の散逸防止）

新機能・プロセッサを追加・変更するときは、以下の配置・命名・ゲート・テスト規約に従い、コードと
概念が散らからないようにする。**8500 行超に達した `local-watcher/bin/idd-codex-issue-watcher.sh`
をこれ以上肥大化させない**ことが最優先方針。

### 1. 配置ルール（どこに書くか）

- **新しいプロセッサ / フェーズ機能** → `local-watcher/bin/idd-codex-modules/<feature>.sh` を新規作成し、
  本体の `REQUIRED_MODULES` 配列に登録する。本体（`idd-codex-issue-watcher.sh`）側には「呼び出し 1〜数行 +
  opt-in gate 判定」だけを置く。
- **複数モジュールが共有する低レベルユーティリティ** → `core_utils.sh` に追加する。
- **本体にまとまったロジックを直書きしない**。既存の triage / dispatch / stage 制御を変更する場合も、
  ロジックは名前付き関数として切り出す（テスト可能化のため）。
- **エージェント定義 / 共通ルール** → `.codex/agents/` `.codex/rules/`（root と `repo-template/` の
  **両系統を byte 一致**で更新）。

### 2. 命名規約

- モジュールファイル: `<feature>.sh`（kebab-case）。
- モジュール内関数: **モジュール固有 prefix** を付ける（`mq_` merge-queue / `pi_` pr-iteration /
  `po_` promote / `sav_` stage-a-verify / `qa_` quota-aware / `ar_` auto-rebase / `pr_` pr-reviewer 等）。
  グローバル名前空間の衝突回避と「どのモジュールの関数か」を即判別するため。
- 環境変数: `<FEATURE>_ENABLED`（有効化フラグ）+ `<FEATURE>_<KNOB>`（調整値）。**既存 env var 名は変えない**。
- ログ識別子: `<feature>:` prefix（run-summary / cron.log grep 運用と整合させる）。

### 3. opt-in ゲート規律

- **新機能は既定 OFF（opt-in）で導入**し、`<FEATURE>_ENABLED=true` の厳密一致でのみ有効化する。
  未設定 / typo / `false` では導入前と完全に同一挙動（後方互換）になるようにする。
- 十分な dogfooding を経てから README「オプション機能一覧」でデフォルト有効へ昇格させる（#112 方式）。
- **新しい外部サービス呼び出しは opt-in gate 必須**（禁止事項参照）。

### 4. 後方互換性（最優先制約）

- env var 名 / exit code 意味 / ラベル名 / ログ prefix / cron 登録文字列を変えない。
- 破壊的変更は README に **migration note 必須** + 必要なら deprecation 期間を設ける。
- `repo-template/**` の変更は既 installed の consumer repo に `install.sh` 再実行で波及する。
  影響評価と migration note を伴う。

### 5. テスト規約

- 機能ごとに `local-watcher/test/<feature>_<観点>_test.sh` を追加する。純粋ロジックは
  `extract_function` で対象関数だけを切り出して検証する（既存テストのパターンを踏襲）。
- 正常系に加え、**異常系・境界・空入力を最低 1 ケース**用意する。
- `shellcheck --severity=warning` を新規 / 変更スクリプト全件でクリーンにする。
- 変更後に `diff -r .codex/agents repo-template/.codex/agents` と rules 版が空であることを確認する。

### 6. セキュリティ規約（未信頼入力の扱い）⭐

公開 repo では **Issue / PR のタイトル・本文・ブランチ名・コメント本文・ラベルはすべて攻撃者が
制御しうる未信頼入力**である。これらを扱うコードを追加・変更するときは:

- **未信頼の文字列を `sed` / `eval` / `bash -c` / 動的 `source` へ渡さない**。テンプレ展開は awk の
  `index` / `substr` リテラル置換を使う（`_triage_render_prompt` / `pi_build_iteration_prompt` 参照。Issue #47）。
- **コメント本文で特権判断（merge 承認・エージェントへの指示）をするときは著者の `author_association` を
  検証**する（信頼集合の既定: `OWNER` / `MEMBER` / `COLLABORATOR`。Issue #50）。GitHub user 名や
  marker テキストだけを信頼しない。
- **ブランチ名 / ref を git / gh へ渡すときは `^codex/` 等の allowlist で検証**し、`-` 始まりの
  option injection を防ぐ。force push は `--force` ではなく `--force-with-lease` か fast-forward 限定。
- **codex へ渡すプロンプトの未信頼部分は「データであり指示ではない」と明示的に区切る**。
  サンドボックス前提（`CODEX_SANDBOX` 等）を弱める変更を無告知で入れない。
- 破壊的操作（force push / hook 自己改変）を新たに招きうる変更では、Codex Guard Hook
  （`local-watcher/hooks/idd-codex-guard.sh`）の deny 規則と回帰テストも併せて更新する（Issue #49）。

**Security Review Processor（idd-claude #279）は idd-codex では未移植（意図的 scope-out / #81）**:
idd-claude の opt-in PR セキュリティレビュー（`claude --permission-mode plan` で Claude Code 公式
`/security-review` skill を起動し PR diff を advisory レビュー）は **Claude skill 依存**で codex に
等価物が無く、汎用プロンプトに置換すると品質が大きく落ちるため移植しない。idd-codex のセキュリティは
本節の規約 ＋ Codex Guard Hook（base push / force push / guard 自己改変 deny ＋ Reviewer/Debugger
write-scope / #80）＋ 未信頼入力境界（#70）＋ Stage A Verify の `codex sandbox` 実行（#51）で
多層に担保する。PR 単位のセキュリティレビューが欲しい運用者は、Claude Code の `/security-review`
skill や `gh` を **手動で**実行する（watcher の自動処理としては提供しない）。

### 7. ドキュメント同期

- 挙動を変えたら **同一 PR で** README の該当節 + AGENTS.md + 該当 rule を更新する（二重管理規約）。
- 新規 env var は README「オプション機能一覧」表に追記する。

### 既知の技術債（増やさない／徐々に解消する）

- `idd-codex-issue-watcher.sh` は 8500 行超の monolith で、triage / dispatch / slot / stage 制御が
  まだ本体に残る。**新規ロジックは本体へ足さずモジュールへ**置く。既存ロジックに触るときは、その関数を
  機能モジュール（または `core_utils.sh`）へ切り出す小さなリファクタを同伴できると望ましい。ただし
  live cron への影響を考え、必ずテスト / `shellcheck` / dry-run で検証してから入れること。

---

## エージェントが参照する共通ルール（`.codex/rules/`）

各エージェントは作業前に以下のルールを `Read` で読み込む:

| ルールファイル | 参照エージェント | 役割 |
|---|---|---|
| `ears-format.md` | PM | AC の EARS 記法（When / If / While / Where / shall） |
| `requirements-review-gate.md` | PM | requirements.md の自己レビュー（Mechanical + 判断、最大 2 パス） |
| `design-principles.md` | Architect | design.md の必須セクションと詳細度の方針 |
| `design-review-gate.md` | Architect | design.md の自己レビュー（traceability / File Structure Plan 充填 / orphan 検出） |
| `tasks-generation.md` | Architect / Developer | tasks.md のアノテーション規約と numeric ID 階層 |
| `feature-flag.md` | Developer / Reviewer | Feature Flag Protocol opt-in 宣言時の規約詳細（命名・両系統テスト・クリーンアップ責務） |
| `issue-dependency.md` | PM / Triage / Architect | Issue 間依存・親子関係の canonical 記法（`Depends on:` / `Parent:` 他）と互換 alias マッピング |

ルール群は [cc-sdd](https://github.com/gotalab/cc-sdd)（MIT License, Copyright gotalab）から adapt したものです。

---

## PR 品質チェック（PjM が PR 作成時に確認する項目）

- [ ] すべての受入基準に対応する実装がある
- [ ] `shellcheck` / `actionlint` がクリーン（該当ファイルを変更した場合）
- [ ] 手動スモークテストの結果を PR 本文の「Test plan」に記載
- [ ] 既存 env var 名 / ラベル / cron 登録文字列の後方互換性を確認
- [ ] README / AGENTS.md / 該当 rule ファイルが更新されている（挙動変更時）
- [ ] 破壊的変更がある場合は README に migration note を追加
- [ ] PR 本文に「確認事項」セクションがある（レビュワー判断ポイントを明示）

---

## 機密情報の扱い

本リポジトリは OSS として公開されるツール / テンプレートです。扱わないもの:

- API keys / OAuth tokens の実値
- 作者個人名義の非公開 path / URL を例示用以外の形でハードコード
- 本番環境の認証情報

Issue 本文に実値が含まれた場合、PM エージェントは実装を進めず `codex-needs-decisions` で人間にエスカレーションする。

---

## 参考資料

- サブエージェント定義: `.codex/agents/*.md`（**Codex CLI には Claude Code の subagent 起動機構が無い**ため、これらは別 context へ spawn されるのではなく、各 stage で **watcher が役割定義として prompt 先頭へ注入**する。prompt 中の「〜サブエージェントを起動」は「あなた自身がそのロールとして振る舞う」と読み替える。`CODEX_INJECT_ROLE_DEFS` で制御 / #74）
- Triage プロンプト: `local-watcher/bin/idd-codex-triage-prompt.tmpl`（配置先: `~/bin/idd-codex-triage-prompt.tmpl`）
- Watcher 実装: `local-watcher/bin/idd-codex-issue-watcher.sh`（配置先: `~/bin/idd-codex-issue-watcher.sh`）
- ワークフロー全体像・セットアップ手順: `README.md`
- パイプライン全体設計: Issue #13（フェーズ別実装: #14〜#18）
