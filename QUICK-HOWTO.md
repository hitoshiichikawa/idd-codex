# Quick HowTo: 既存リポジトリに idd-codex を導入する

**所要時間: 約 15 分**。
GitHub にある既存のリポジトリに idd-codex のワークフローを追加し、最初の自動開発 Issue が
動くまでの最短手順をまとめたドキュメントです。

> 包括的な仕様・複数 repo 運用・カスタマイズは [README.md](./README.md) を参照してください。
> 本ドキュメントは「ローカル watcher 方式 + 単一リポジトリ」に絞っています（最も推奨の構成）。

---

## 0. 前提

- GitHub リポジトリへの push 権限と、既にローカルクローン済みのワーキングコピーがあること
- macOS / Linux / WSL のいずれかで、常時稼働可能な PC がある（自動開発 watcher を動かすため）
- 以下のコマンドがインストール済み:
  - `gh`（GitHub CLI、`gh auth login` 済み）
  - `jq`
  - `flock`（Linux 標準。macOS は `brew install util-linux`）
  - Node.js 18 以上
  - `codex`（Codex CLI、`codex` コマンドが実行できる状態）
- Codex CLI が利用できる OpenAI アカウント

未インストールのものがあれば、先に揃えてから進めてください。

---

## 1. テンプレートを既存 repo に配置する（ワンライナー）

対象リポジトリのルートに `cd` してから、以下を実行します。

```bash
cd /path/to/your-existing-repo

curl -fsSL https://raw.githubusercontent.com/hitoshiichikawa/idd-codex/9f8e9cea7df960f5be14849edcbac03dea55162e/setup.sh \
  | bash -s -- --all
```

`--all` は **対象 repo へのテンプレート配置 + ローカル watcher のインストール**を一気に行います。
途中で対話プロンプトが出る場合は Enter で進めて構いません。
上記 URL は mutable `main` ではなく commit SHA 固定です。`IDD_CODEX_BRANCH=main` や任意ブランチを
指定する場合は、pinned default を明示的に上書きする運用として扱ってください。
release で `SHA256SUMS` 等が提供されている場合は、下記の手順で `setup.sh` を検証してから
実行できます。

実行後の状態:

| 配置先 | 内容 |
|---|---|
| 対象 repo | `AGENTS.md` / `.codex/agents/` / `.codex/rules/` / `.github/ISSUE_TEMPLATE/idd-codex-feature.yml` / `.github/scripts/idd-codex-labels.sh` |
| `$HOME/bin/` | `idd-codex-issue-watcher.sh` / `idd-codex-triage-prompt.tmpl` / `idd-codex-iteration-prompt.tmpl` |
| `$HOME/.idd-codex/` | upstream のクローン（更新時に再 pull する場所）|

> **既存の `AGENTS.md` がある場合**: 自動的に `AGENTS.md.bak` にバックアップされます。
> 後で必要な記述を統合してください（[Step 3](#3-codexmd-を自プロジェクト用にチューニング) 参照）。

> **`curl | bash` を信用したくない場合**: スクリプトを先に読んでから実行できます。
> ```bash
> curl -fsSL https://raw.githubusercontent.com/hitoshiichikawa/idd-codex/9f8e9cea7df960f5be14849edcbac03dea55162e/setup.sh -o /tmp/setup.sh
> less /tmp/setup.sh    # 内容確認
> # release の SHA256SUMS が提供されている場合:
> # sha256sum -c SHA256SUMS      # macOS: shasum -a 256 -c SHA256SUMS
> bash /tmp/setup.sh --all
> ```

> **local runtime file recovery policy**: `--all` / `--local` の再実行で
> `$HOME/bin/idd-codex-issue-watcher.sh` や macOS launchd plist にローカル編集がある場合、
> installer は `<target>.bak` を once-only で作成してから template を反映します。既に `.bak` が
> ある場合は無断で上書きせず、`--dry-run --all` で `BACKUP` / `OVERWRITE` / `SKIP` の予定 action を
> 確認できます。cron / launchd の watcher command path と既存 env var 名は変わりません。

---

## 2. GitHub ラベルを作成する

idd-codex が状態管理に使うラベルを repo に作成します。

```bash
cd /path/to/your-existing-repo
bash .github/scripts/idd-codex-labels.sh
```

冪等なので何度実行しても安全です（既存ラベルはスキップ）。
作成されるラベル: `codex-auto-dev` / `codex-needs-decisions` / `codex-awaiting-design-review` / `codex-claimed` /
`codex-picked-up` / `codex-ready-for-review` / `codex-failed` / `codex-skip-triage` / `codex-needs-rebase` / `codex-needs-iteration` /
`codex-needs-quota-wait` / `codex-staged-for-release` / `codex-st-failed` / `codex-blocked`

---

## 3. AGENTS.md を自プロジェクト用にチューニング

配置された `AGENTS.md` には汎用テンプレート（Node.js + TypeScript の例）が入っています。
**このファイルが全エージェントの行動指針**になるので、自プロジェクトに合わせて書き換えてください。

最低限編集すべき箇所:

- **「技術スタック」節**: 自プロジェクトの言語 / フレームワーク / テストランナー / lint に書き換え
- **「コード規約」節**: TypeScript 例ブロックを自言語の慣習に置換（Python / Go / Rust 等）
- **「テスト規約」節**: 末尾の TS 例を自プロジェクトのフレームワーク慣習に置換
- **「機密情報の扱い」節**: 自プロジェクト固有の禁止情報を列挙

書き換えたら commit して push:

```bash
git add AGENTS.md .codex .github
git commit -m "chore: introduce idd-codex workflow templates"
git push
```

> **既存 AGENTS.md があった場合**: `AGENTS.md.bak` を見ながら、必要な独自規約を追加します。
> 既存の規約と idd-codex の規約は基本的に共存可能です。

---

## 4. cron に watcher を登録する（Linux / WSL）

watcher を 2 分ごとに起動するように cron を登録します。

```bash
crontab -e
```

末尾に以下を追加（`owner/your-repo` と `$HOME/work/your-repo` を自分の値に）:

```cron
*/2 * * * * REPO=owner/your-repo REPO_DIR=$HOME/work/your-repo $HOME/bin/idd-codex-issue-watcher.sh >> $HOME/.idd-codex/issue-watcher/cron.log 2>&1
```

> **macOS の場合**: cron でも動きますが、再起動後の自動復帰のために launchd を推奨します。
> 設定方法は [README の launchd 節](./README.md#macos-launchd-に登録) を参照。

### 動作確認

cron が動いているかは以下で確認できます:

```bash
# 直近のログを追跡
tail -f $HOME/.idd-codex/issue-watcher/cron.log

# 手動で 1 サイクル実行（cron を待たずに動作確認できる）
REPO=owner/your-repo REPO_DIR=$HOME/work/your-repo $HOME/bin/idd-codex-issue-watcher.sh
```

`[<時刻>] 処理対象の Issue なし` と出れば正常です。

---

## 5. 最初の Issue で動かしてみる

ブラウザで対象 repo の Issues タブを開き、**「New issue」 → 「機能要望・改善（idd-codex 自動開発）」**
テンプレートを選択します（ステップ 1 で配置した `idd-codex-feature.yml` テンプレート）。

簡単なお題で試すのがおすすめです。例:

- `README.md` の typo 修正
- 既存スクリプトに 1 つコメントを追加
- 新規ファイルに「Hello」と書く

Issue 作成時に `codex-auto-dev` ラベルが自動で付きます。**最大 2 分後**（cron 起動後）に watcher が
Issue を検出し、以下の流れが自動進行します:

```
codex-auto-dev (起票)
   ↓
codex-claimed     ← Dispatcher が claim、Triage 実行中
   ↓
codex-picked-up   ← Triage 通過、実装フェーズ開始
   ↓
codex-ready-for-review   ← 実装 PR 作成完了 (10〜30 分)
```

進捗は Issue のラベル変化と `$HOME/.idd-codex/issue-watcher/cron.log` で観察できます。

PR が作成されたらレビューして merge してください。これで最初のサイクルが完了です 🎉

---

## 5.5 fork / mirror clone から導入するときの注意（履歴持ち込み警告）

GitHub の fork や `git push --mirror` で別 repo の履歴ごと持ち込んだリポジトリに
`install.sh --repo` を流すと、引き継がれた古い `docs/specs/<番号>-<slug>/` ディレクトリや
`codex/issue-<番号>-*` ブランチが **新しい Issue 番号と衝突して watcher が誤った spec を
resume 対象に選ぶ**事故が発生し得ます（Issue #115）。

これを未然に防ぐため、`install.sh` は配置完了直後に以下 3 種類の検出を行い、
該当があれば警告を表示します（**install 自体は止めません。exit 0 で完走します**）:

| カテゴリ | 検出対象 |
|---|---|
| `[docs-specs]` | `docs/specs/<数字>-*/` 形式のディレクトリが 1 件以上存在する |
| `[codex-branches]` | `origin` リモートに `codex/issue-<数字>-(design\|impl)-*` ブランチが 1 件以上存在する |
| `[orphan-branches]` | 上記ブランチの `<数字>` の **過半数**が対象 repo の現存 Issue 番号（open + closed）と一致しない（fork/mirror 由来の可能性が高い） |

### 警告が出たときの推奨対応

警告を見たら、idd-codex を本格的に動かす前に以下のクリーンアップを実施してください:

```bash
# 1. 古い docs/specs/ を一覧（先頭が数字 - のディレクトリ）
ls -d docs/specs/[0-9]*-*/

# 2. 不要なものを削除（自分のリポジトリの Issue とつながりがないことを確認してから）
rm -rf docs/specs/<番号>-<slug>/

# 3. 古い codex/issue-* ブランチを一覧
git ls-remote --heads origin 'codex/issue-*'

# 4. 不要な remote ブランチを削除（同上、自分の Issue と紐付くものは残す）
git push origin --delete codex/issue-<番号>-<slug>

# 5. ローカル追跡ブランチもまとめて掃除（任意）
git remote prune origin
```

> 1 件ずつ削除するのが安全です。一括削除する場合は必ず事前に `gh issue list --state all`
> で対応 Issue の有無を確認してください。

### 警告を無視して install を続行した場合

警告を無視しても install 自体は正常完了（exit 0）します。ただし watcher を動かすと
以下のリスクがあります:

- **watcher が古い `docs/specs/<番号>-*/` ディレクトリを resume 対象として誤検出**し、新規
  Issue に対して別 Issue 用の requirements/design を読みに行く可能性
- **watcher が古い `codex/issue-<番号>-*` ブランチに対して force push** や `--rebase` を
  かけて、fork 元で進行中だった作業を破壊する可能性

idd-codex 専用に新規 repo（fork ではなく `git init` から始めたもの）を使うのが最も
安全です。fork から始めざるを得ない場合は、本節のクリーンアップを実施してから cron / watcher を
有効化してください。

### `--dry-run` で事前確認する

`--dry-run` を付ければファイルシステムを変更せず、警告だけ事前に確認できます:

```bash
./install.sh --repo /path/to/your-project --dry-run
# あるいは curl 経由（setup.sh は --dry-run を install.sh に透過する）
curl -fsSL https://raw.githubusercontent.com/hitoshiichikawa/idd-codex/9f8e9cea7df960f5be14849edcbac03dea55162e/setup.sh \
  | bash -s -- --repo /path/to/your-project --dry-run
```

検出処理は `--dry-run` 下でも実施され、警告行は `[DRY-RUN] WARNING:` プレフィックスで
出力されます。

---

## 6. トラブルシューティング（最頻出 3 件）

### `codex が見つかりません` エラーが cron.log に出る

cron は対話シェルの profile を読まないため、`PATH` に `codex` のパスが入っていないことが
原因です。`$HOME/bin/idd-codex-issue-watcher.sh` 冒頭で `~/.local/bin` / `/usr/local/bin` /
`/opt/homebrew/bin` を PATH に追加していますが、それ以外の場所に `codex` がある場合は
`crontab -e` の先頭に明示的な PATH を書いてください:

```cron
PATH=/path/to/codex/bin:/usr/local/bin:/usr/bin:/bin
*/2 * * * * REPO=owner/your-repo ...
```

### Codex の OAuth が切れた

ローカルで再ログインします:

```bash
codex /login
```

1 年程度で切れることがあります。

### Issue に `codex-failed` ラベルが付いて止まった

watcher が連続失敗したことを示します。`$HOME/.idd-codex/issue-watcher/logs/<repo-slug>/issue-<番号>-*.log`
で原因を確認し、修正してから手動でラベルを外すと次回サイクルで再開されます:

```bash
gh issue edit <番号> --repo owner/your-repo --remove-label codex-failed
```

PR 作成前に失敗して `origin/codex/issue-<N>-impl-*` branch だけが残っている場合、watcher は
次回 pickup で既存 branch から resume します。古い slot worktree が同じ branch を checkout
していても、inactive かつ clean なら自動で detached に戻します。dirty / 未 push commit /
origin branch が無い local branch がある場合は破棄せず `codex-needs-decisions` に退避します。

---

## 7. 次に読むもの

- **[README.md](./README.md)** — 包括的な仕様、複数 repo 運用、サブエージェント詳細
- **`AGENTS.md`**（配置済み） — 自プロジェクト用に編集する全エージェント憲章
- **README の `## 使い方`「Issue の書き方（PM を誤解させないコツ）」節** — Issue 作成時に PM エージェントを誤解させないための 3 原則
- **README の `## Merge Queue Processor (Phase A)` 節** — approved PR の自動 rebase（opt-in 機能）
- **README の `## PR Iteration Processor (#26)` 節** — レビューコメント起点の反復開発（opt-in 機能）
