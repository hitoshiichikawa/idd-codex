# Requirements Document

## Introduction

Stage A Verify Gate は、`tasks.md` 由来の verify コマンドを Stage A 完了直前に独立再実行し、build/test/lint の自己申告漏れを防ぐために存在する。
一方で、現行の `codex sandbox` 境界では iOS Simulator / Xcode が参照するホスト側サービスやログ領域へ到達できず、通常シェルでは destination が見える `xcodebuild` が Stage A Verify 経由では exit 70 で失敗する事象が確認された。
本件では、Stage A Verify Gate 全体を無効化せずに iOS Simulator を必要とする verify を通せる運用上の調整点を提供し、sandbox 境界起因の失敗をコード不具合と誤認しにくくする。
既存の安全側デフォルト、コマンド解決順序、ラベル遷移、round 処理は維持する。

## Requirements

### Requirement 1: iOS Simulator verify 用の実行環境調整

**Objective:** As a watcher operator, I want Stage A Verify の実行環境を iOS Simulator が必要な repo 向けに明示調整できること, so that verify gate 全体を無効化せずに Xcode / CoreSimulator を使うテストを継続できる。

#### Acceptance Criteria

1. When Stage A Verify が `xcodebuild` の iOS Simulator destination を使う verify コマンドを実行するとき, the Stage A Verify Gate shall operator 設定により実行環境を調整できる。
2. Where iOS Simulator 対応の実行環境調整が有効である, the Stage A Verify Gate shall CoreSimulator destination 検出に必要なホストリソースへ到達できる実行境界で verify コマンドを実行できる。
3. When iOS Simulator 対応の実行環境調整が有効で `hitoshiichikawa/kuku_master` の `iPhone 17` simulator destination を指定した `xcodebuild` verify が実行されるとき, the Stage A Verify Gate shall sandbox 境界だけを理由に destination 検出で失敗しない。
4. If iOS Simulator 対応の実行環境調整が未設定である, the Stage A Verify Gate shall 既存の安全側デフォルト実行境界を維持する。
5. The Stage A Verify Gate shall gate 全体の無効化とは別に verify 実行境界だけを調整できる。

### Requirement 2: sandbox 境界起因失敗の診断

**Objective:** As a repository maintainer, I want CoreSimulator / Xcode の権限境界失敗が明確に診断されること, so that 実装コードの失敗と Stage A Verify 実行環境の失敗を切り分けられる。

#### Acceptance Criteria

1. When Stage A Verify の出力に `CoreSimulatorService connection became invalid` が含まれるとき, the Stage A Verify Gate shall operator-visible な診断に CoreSimulator 接続失敗として記録する。
2. When Stage A Verify の出力に CoreSimulator ログ領域への `Operation not permitted` が含まれるとき, the Stage A Verify Gate shall operator-visible な診断に sandbox または権限境界の可能性を記録する。
3. When Stage A Verify が iOS Simulator destination を見つけられず、同一 host の通常シェルでは destination が見えている前提が満たされるとき, the Stage A Verify Gate shall コード不具合と誤認しにくい診断メッセージを残す。
4. If sandbox 境界起因と推定される失敗が発生したとき, the Stage A Verify Gate shall 既存の round 処理に加えて、operator が実行環境調整を検討できる recovery hint を残す。
5. The Stage A Verify Gate shall verify コマンドの exit code と sandbox 境界診断を operator が区別して読める形でログに残す。

### Requirement 3: 既存 Stage A Verify 契約の維持

**Objective:** As an idd-codex operator, I want iOS Simulator 対応が既存 repo の安全側挙動を壊さないこと, so that self-hosting と consumer repo の cron / launchd 運用を継続できる。

#### Acceptance Criteria

1. If Stage A Verify の実行環境調整に関する設定が未設定である, the Stage A Verify Gate shall 既存の `codex sandbox` 実行境界、コマンド解決順序、round 処理を維持する。
2. When `STAGE_A_VERIFY_ENABLED=false` が設定されているとき, the Stage A Verify Gate shall 既存どおり gate 全体を無効化する。
3. When `STAGE_A_VERIFY_COMMAND` が operator により明示され、構造化 verify ブロックが存在しないとき, the Stage A Verify Gate shall 既存の operator 明示 command semantics を維持する。
4. When Stage A Verify が `tasks.md` 由来の verify コマンドを扱うとき, the Stage A Verify Gate shall 未設定時に watcher / cron 実行ユーザーの非 sandbox 権限へ暗黙 fallback しない。
5. The Stage A Verify Gate shall 既存ラベル名、Issue 遷移、run-summary の `stage-a-verify` 結果分類、exit code 意味を変更しない。

### Requirement 4: operator documentation

**Objective:** As a watcher operator, I want iOS / Xcode repo 向けの Stage A Verify 調整方法と注意点を documentation で確認できること, so that gate を丸ごと無効化する前に安全な選択肢を判断できる。

#### Acceptance Criteria

1. When operator が README の Stage A Verify Gate 節を読むとき, the documentation shall iOS Simulator / Xcode verify で sandbox 境界起因の失敗が起きうることを説明する。
2. When operator が README の Stage A Verify 環境変数表を読むとき, the documentation shall verify 実行境界を調整する設定と既定値を確認できる。
3. When operator が iOS Simulator / Xcode verify の recovery hint を読むとき, the documentation shall gate 全体の opt-out と verify 実行境界調整の違いを確認できる。
4. The documentation shall 調整未設定時の安全側デフォルトが維持されることを説明する。

### Requirement 5: 回帰検証

**Objective:** As a maintainer, I want iOS Simulator 境界診断と既存互換性が検証されること, so that Stage A Verify の安全境界と operator experience の退行を防げる。

#### Acceptance Criteria

1. When regression verification runs for Stage A Verify environment adjustment, the test suite shall 未設定時に既存の安全側デフォルト実行境界が選ばれることを検証する。
2. When regression verification runs for an iOS Simulator sandbox-boundary failure sample, the test suite shall `CoreSimulatorService connection became invalid` を sandbox 境界診断として検出する。
3. When regression verification runs for an iOS Simulator permission failure sample, the test suite shall CoreSimulator ログ領域の `Operation not permitted` を sandbox または権限境界診断として検出する。
4. When regression verification runs for existing Stage A Verify flows, the test suite shall コマンド解決順序、round 処理、ラベル遷移の既存契約が維持されることを検証する。
5. When shellcheck is run for changed shell scripts, the verification shall warning-level findings introduced by this change なしで完了する。

## Non-Functional Requirements

### NFR 1: 後方互換性

1. If new Stage A Verify environment adjustment settings are not configured, the Stage A Verify Gate shall produce behavior equivalent to the current default path for non-iOS repos.
2. The Stage A Verify Gate shall preserve existing environment variable names and meanings unless a new optional setting is added.
3. The Stage A Verify Gate shall preserve existing label names, issue-state transitions, run-summary key order, and documented exit code meanings.

### NFR 2: セキュリティ境界

1. When repository-derived verify commands are executed without an explicit iOS Simulator environment adjustment, the Stage A Verify Gate shall continue to execute them inside the existing sandbox boundary.
2. If an environment adjustment would broaden host access for repository-derived verify commands, the Stage A Verify Gate shall require explicit operator opt-in before using that broader boundary.
3. The Stage A Verify Gate shall not treat Issue body, PR body, comments, or `tasks.md` prose as authorization to weaken the verify execution boundary.

### NFR 3: 可観測性

1. When Stage A Verify runs with a non-default execution boundary, the Stage A Verify Gate shall log the selected boundary class in at least one `stage-a-verify:` line.
2. When Stage A Verify emits an iOS Simulator boundary diagnostic, the Stage A Verify Gate shall include enough operator-visible context to distinguish boundary failure from verify command exit failure.

## Out of Scope

- Xcode、iOS Simulator runtime、または simulator device のインストール・作成・選択ロジックの追加。
- `xcodebuild` コマンド自体の自動生成、destination 名の推測、または repo 固有 scheme の推測。
- Stage A Verify Gate の廃止、または既定での gate 全体 opt-out 化。
- 既存の `tasks.md` verify コマンド解決順序の変更。
- 既存ラベル名、Issue 遷移、round counter 永続化方式、run-summary key order の変更。
- Developer / Reviewer / Project Manager stage の責務変更。
- GitHub token、branch protection、repository permission の変更。

## Open Questions

- なし。
