# Requirements: PR Iteration no-progress round の ready 遷移防止

## 1. no-progress round のラベル遷移

### 1.1
When PR Iteration round が正常終了したが head branch に新規 commit が存在しないとき, the PR Iteration Processor shall `codex-needs-iteration` を `codex-ready-for-review` または `codex-awaiting-design-review` に遷移しない。

### 1.2
When PR Iteration round が正常終了し head branch に新規 commit が存在しないとき, the PR Iteration Processor shall `codex-needs-iteration` を残置して次 cycle に持ち越す。

### 1.3
When PR Iteration round が正常終了し head branch に新規 commit が存在しないとき, the PR Iteration Processor shall round marker の `no-progress-streak` を加算して保存する。

### 1.4
When PR Iteration round が正常終了し head branch に新規 commit が存在しないとき, the PR Iteration Processor shall 同じ round 内で no-progress streak の記録後に success label transition を実行しない。

## 2. 入力コメントが空の round

### 2.1
When PR Iteration の一般コメント収集結果が `final=0` のとき, the PR Iteration Processor shall 当該 round を ready-for-review へ戻す根拠として扱わない。

### 2.2
When PR Iteration の一般コメント収集結果が `final=0` かつ head branch に新規 commit が存在しないとき, the PR Iteration Processor shall `codex-needs-iteration` を残置して hold する。

## 3. no-progress streak による hold と escalation

### 3.1
When no-progress round の加算後 streak が `PR_ITERATION_NO_PROGRESS_LIMIT` 未満のとき, the PR Iteration Processor shall `codex-needs-iteration` を残置して次 cycle に持ち越す。

### 3.2
When no-progress round の加算後 streak が `PR_ITERATION_NO_PROGRESS_LIMIT` 以上のとき, the PR Iteration Processor shall `codex-needs-iteration` を除去して `codex-failed` に遷移する。

### 3.3
When no-progress round の加算後 streak が `PR_ITERATION_NO_PROGRESS_LIMIT` 以上のとき, the PR Iteration Processor shall no-progress 上限到達のエスカレーションコメントを投稿する。

## 4. reply-only success contract

### 4.1
While explicit reply-only success contract が定義されていない状態で PR Iteration round が head branch に新規 commit を作らなかったとき, the PR Iteration Processor shall reply-only success として扱わない。

### 4.2
Where explicit reply-only success contract が将来定義される場合, the PR Iteration Processor shall その contract を満たすことを観測できる場合に限り no-commit round の success label transition を許可する。

## 5. 回帰テスト

### 5.1
The PR Iteration Processor shall no-progress round が `codex-ready-for-review` または `codex-awaiting-design-review` に遷移しないことを検証する回帰テストを持つ。

### 5.2
The PR Iteration Processor shall no-progress streak が閾値未満のときに hold され、閾値到達時に `codex-failed` へ escalation されることを検証する回帰テストを持つ。

## Scope

- 対象: `local-watcher/bin/modules/pr-iteration.sh` の no-progress round 後処理、関連テスト、README の挙動説明。
- 対象外: Codex prompt の改善、PR reviewer の指摘品質改善、`PR_ITERATION_NO_PROGRESS_LIMIT` の既定値変更。

## Issue コメント反映

- `gh issue view 3 --comments` では Triage edit_paths と処理開始通知のみ確認。追加の人間回答・決定事項は無し。

## 確認事項

- 現時点で追加確認が必要な事項は無し。

## PM 自己レビュー

- Mechanical Checks: numeric ID 見出し、各要件の EARS 形式 AC、実装詳細の過剰混入なしを確認。
- 判断レビュー: Issue の受入基準、入力コメント空、no-progress streak、reply-only success contract、回帰テスト、スコープ外を網羅していることを確認。
