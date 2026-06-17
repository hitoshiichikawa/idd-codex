# Requirements Document

## Introduction

Issue #50 では、PR / Issue コメント本文を著者検証なしで信頼することで、特権判断や Codex 入力が未信頼コメントに影響される問題が報告された。
既存コメントの決定により、4-A Merge Queue approval marker 偽造と 4-B PR Iteration 一般コメントの未信頼プロンプト流入は PR #53 で修正済みである。
本要件では、残置された 4-C promote-pipeline の `edit-paths-json` marker 注入防止を主対象とする。
同時に、4-A / 4-B の修正が回帰しないことを運用者が検証できる受入基準として明示する。

## Requirements

### Requirement 1: 4-C edit-paths-json marker の信頼境界

**Objective:** As a watcher operator, I want `edit-paths-json` marker が信頼済みコメントからのみ採用されること, so that 第三者コメントによる Path Overlap Checker の誤誘導や停滞 DoS を防止できる。

#### Acceptance Criteria

1. Where `PATH_OVERLAP_CHECK=true`, the Path Overlap Checker shall `edit-paths-json` marker を信頼済み著者のコメントからのみ有効な edit paths 入力として扱う。
2. When 同一 Issue に信頼済み著者の `edit-paths-json` marker と未信頼著者の `edit-paths-json` marker が混在するとき, the Path Overlap Checker shall 未信頼著者の marker を path overlap 判定に使用しない。
3. If 未信頼著者のコメントが最後に投稿された `edit-paths-json` marker を含むとき, the Path Overlap Checker shall その marker を最後勝ちの有効値として採用しない。
4. If 有効な信頼済み `edit-paths-json` marker が存在しないとき, the Path Overlap Checker shall 未信頼 marker を代替入力として使用しない。
5. While `PATH_OVERLAP_CHECK` が `true` ではないとき, the watcher shall Path Overlap Checker 無効時の既存挙動を維持する。

### Requirement 2: コメント著者信頼モデル

**Objective:** As a repository maintainer, I want コメント由来の制御 marker が信頼済み著者に限定されること, so that public repository の一般参加者コメントが watcher の特権判断に使われない。

#### Acceptance Criteria

1. When watcher が Issue / PR コメント由来の制御 marker を評価するとき, the watcher shall GitHub 上の信頼済み repository participant または watcher 管理の automation に由来するコメントのみを信頼対象にする。
2. If コメント著者が信頼済み repository participant または watcher 管理の automation と確認できないとき, the watcher shall そのコメント本文を特権判断の根拠にしない。
3. When 未信頼著者のコメントに正規形式に見える idd-codex marker が含まれるとき, the watcher shall marker 本文の形式だけで信頼済み signal と判定しない。
4. The watcher shall コメント本文そのものを信頼根拠にせず、本文とは独立した著者信頼情報に基づいて marker 採否を決定する。

### Requirement 3: 4-A / 4-B 修正の回帰防止

**Objective:** As a maintainer, I want PR #53 で修正済みの 4-A / 4-B が再発しないことを確認できること, so that 今回の 4-C 対応で既存のセキュリティ修正を壊さない。

#### Acceptance Criteria

1. When Merge Queue Processor が idd-codex approval marker を評価するとき, the Merge Queue Processor shall 未信頼著者の approve / iteration / reject marker を承認 signal または制御 signal として扱わない。
2. When PR Iteration Processor が一般 PR コメントを Codex 入力候補として収集するとき, the PR Iteration Processor shall 未信頼著者の一般コメントを Codex への prompt 入力に含めない。
3. If 未信頼著者の PR コメントが `VERDICT: approve` または idd-codex review marker 風の本文を含むとき, the Merge Queue Processor shall そのコメントによって PR を approved 扱いにしない。
4. If 未信頼著者の PR コメントが実装指示または prompt injection 風の本文を含むとき, the PR Iteration Processor shall そのコメントを反復実装 prompt の根拠にしない。
5. When regression checks run for Issue #50, the test suite shall 4-A / 4-B の未信頼著者コメントが無視されることを検証する。

### Requirement 4: 既存運用との互換性

**Objective:** As a watcher operator, I want 信頼済み maintainer / automation の既存 marker 運用が維持されること, so that セキュリティ修正後も通常の自動化 workflow が停滞しない。

#### Acceptance Criteria

1. When 信頼済み著者が有効な `edit-paths-json` marker を投稿しているとき, the Path Overlap Checker shall その marker を従来どおり path overlap 判定の入力として扱う。
2. When 信頼済み著者が Merge Queue approval marker を投稿しているとき, the Merge Queue Processor shall PR #53 後の承認 signal semantics を維持する。
3. When 信頼済み著者が PR Iteration 対象の一般コメントを投稿しているとき, the PR Iteration Processor shall PR #53 後のコメント収集 semantics を維持する。
4. The watcher shall 既存の env var 名、ラベル名、cron / launchd 運用前提、exit code 意味をこの Issue の対応で変更しない。

## Non-Functional Requirements

### NFR 1: Security

1. The watcher shall Issue / PR コメント本文を未信頼入力として扱い、特権判断前に著者信頼性を確認する。
2. The watcher shall 未信頼コメントによって auto-rebase、label transition、path overlap 判定、Codex prompt 入力が変更されない性質を維持する。

### NFR 2: Verification

1. When regression checks cover trusted and untrusted comment cases, the test suite shall 信頼済みコメントが通り未信頼コメントが無視されることを区別して検証する。
2. When regression checks run for 4-C, the test suite shall 未信頼 marker の最後勝ち注入が path overlap 入力を上書きしないことを検証する。

### NFR 3: Backward Compatibility

1. The watcher shall `PATH_OVERLAP_CHECK` 未設定または `true` 以外の環境で既存の無効化挙動を維持する。
2. The watcher shall 4-A / 4-B の PR #53 修正済み挙動を緩めない。

## Out of Scope

- 4-A Merge Queue approval marker 著者検証の再実装。
- 4-B PR Iteration 一般コメント著者検証の再実装。
- 本 requirements.md で具体的な実装コード変更箇所や実装方式を指定すること。
- GitHub branch protection、required review、repository permission 設定の変更。
- GitHub の正式 review / approval 機能そのものの代替実装。
- `PATH_OVERLAP_CHECK` のデフォルト有効化、env var 名変更、ラベル名変更。
- 未信頼コメント本文の内容分類や AI moderation の追加。
- 既存 Issue コメントの削除、書き換え、retrofit。

## Open Questions

- なし。
