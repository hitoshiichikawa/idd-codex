# Requirements

## 1. Stage A Verify の実行境界

### 1.1
When Stage A Verify Gate が `tasks.md` の `stage-a-verify` 構造化ブロック由来コマンドを実行するとき, the Stage A Verify Gate shall Codex 実行と同等の sandbox 境界内でそのコマンドを実行する。

### 1.2
When Stage A Verify Gate がリポジトリ由来の自動 verify コマンドを実行するとき, the Stage A Verify Gate shall watcher / cron 実行ユーザーの非 sandbox 権限でそのコマンドを直接実行しない。

### 1.3
If Codex 実行と同等の sandbox 境界を確立できないとき, the Stage A Verify Gate shall リポジトリ由来の verify コマンドを非 sandbox 権限へフォールバックして実行しない。

### 1.4
When リポジトリ由来 verify コマンドの sandbox 実行が拒否または失敗したとき, the Stage A Verify Gate shall operator が原因を確認できるログまたは verify 結果を残す。

## 2. 既存自動 verify の維持

### 2.1
When `tasks.md` に有効な `stage-a-verify` 構造化ブロックが存在するとき, the Stage A Verify Gate shall そのブロックを自動 verify コマンド候補として引き続き扱う。

### 2.2
When Stage A Verify Gate がリポジトリ由来 verify コマンドを解決するとき, the Stage A Verify Gate shall 既存のコマンド解決順と自動 verify 有効化条件を維持する。

### 2.3
When `STAGE_A_VERIFY_COMMAND` が operator により明示されているとき, the Stage A Verify Gate shall 既存の operator override としてその設定を引き続き扱う。

### 2.4
While Stage A Verify Gate がリポジトリ由来 verify を sandbox 内で実行しているとき, the Stage A Verify Gate shall 正当な複合 verify コマンドをメタ文字の存在のみで一律拒否しない。

## 3. 未信頼 `tasks.md` 入力への安全性

### 3.1
If `tasks.md` 由来の verify コマンドが外部送信、権限確認、または複合 shell 実行を含むとき, the Stage A Verify Gate shall そのコマンドを watcher / cron 実行ユーザーの非 sandbox 権限で実行しない。

### 3.2
When `tasks.md` 由来の verify コマンドが keyword gate を通過または免除されるとき, the Stage A Verify Gate shall keyword gate の結果だけを安全境界として扱わない。

### 3.3
If Issue / PR 由来の prompt injection により `tasks.md` に verify コマンドが混入したとき, the Stage A Verify Gate shall そのコマンドに watcher の非 sandbox 権限または operator token 前提の権限を与えない。

## 4. 運用者向けの信頼境界表示

### 4.1
When operator が README の Stage A Verify またはオプション機能説明を読むとき, the documentation shall リポジトリ由来 verify コマンドが Codex 実行と同等の sandbox 境界内で実行されることを確認できる。

### 4.2
When operator が `STAGE_A_VERIFY_COMMAND` の説明を読むとき, the documentation shall operator 明示設定とリポジトリ由来自動 verify の信頼境界の違いを確認できる。

### 4.3
When operator が既存 repo の `stage-a-verify` 構造化ブロックを利用しているとき, the documentation shall 自動 verify が廃止されず sandbox 実行へ移行する方針であることを確認できる。

## 5. 回帰検証

### 5.1
When regression checks run for Stage A Verify structured-block execution, the test suite shall verify that `tasks.md` 由来コマンドが非 sandbox 権限で直接実行されないことを検証する。

### 5.2
When regression checks run for malicious `tasks.md` verify content, the test suite shall verify that 外部送信を含む構造化ブロックが watcher / cron 実行ユーザーの非 sandbox 権限で実行されないことを検証する。

### 5.3
When regression checks run for existing automatic verify, the test suite shall verify that 有効な `stage-a-verify` 構造化ブロックは sandbox 境界内の自動 verify として引き続き利用されることを検証する。

### 5.4
When regression checks run for operator override, the test suite shall verify that `STAGE_A_VERIFY_COMMAND` の既存 override semantics が維持されることを検証する。

### 5.5
When shellcheck is run for changed shell scripts, the verification shall complete without warning-level findings introduced by this change.

## Scope

- 人間コメント `A` に従い、リポジトリ由来 verify は Codex と同等の sandbox 内で実行し、既存の自動 verify を維持する。
- `tasks.md` の `stage-a-verify` 構造化ブロック、既存のリポジトリ由来自動 verify、`STAGE_A_VERIFY_COMMAND` の互換性を対象にする。
- README の Stage A Verify / オプション機能説明に、更新後の信頼境界を反映する。
- 既存 env var 名、ラベル名、cron / launchd 運用前提、exit code 意味は変更しない。

## Out of Scope

- リポジトリ由来 verify を廃止し、`STAGE_A_VERIFY_COMMAND` のみに限定する Option B。
- `stage-a-verify` 構造化ブロックの廃止。
- shell メタ文字や複合コマンドの一律拒否。
- 新しい外部サービス呼び出しの追加。
- GitHub token 権限、repository permission、branch protection の変更。
- 具体的な sandbox 実装方式、モジュール分割、関数名、コマンド組み立て方式の指定。

## Open Questions

- なし。
