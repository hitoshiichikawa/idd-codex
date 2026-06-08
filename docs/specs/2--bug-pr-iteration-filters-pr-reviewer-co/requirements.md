# Issue #2 要件定義

## 1. PR reviewer コメントの反復入力化

PR Iteration は、PR reviewer が反復要求として投稿した一般コメントを実装者向けの反復 prompt に含める。

### Acceptance Criteria

- When PR reviewer が `VERDICT: codex-needs-iteration` を含む一般コメントを投稿したとき, the PR Iteration Processor shall そのコメントを反復 prompt の入力コメントとして扱う。
- When PR reviewer の一般コメントに `idd-codex:pr-reviewer` marker が含まれるとき, the PR Iteration Processor shall そのコメントを自己投稿コメントとして除外しない。

## 2. PR Iteration 自己コメントの除外維持

PR Iteration は、自身が処理状態を示すために投稿したコメントを反復 prompt から除外し続ける。

### Acceptance Criteria

- When 一般コメントに `idd-codex:pr-iteration-processing` marker が含まれるとき, the PR Iteration Processor shall そのコメントを自己投稿コメントとして除外する。
- When 一般コメントに PR Iteration 処理用の `idd-codex:pr-iteration` 系 marker が含まれるとき, the PR Iteration Processor shall そのコメントを自己投稿コメントとして除外する。

## 3. 回帰検証

PR reviewer marker と PR Iteration self marker の扱いが再発しないように、shell-level の fixture で検証する。

### Acceptance Criteria

- When shell-level regression test が PR reviewer marker 付きコメントと PR Iteration self marker 付きコメントを入力するとき, the test shall reviewer marker 付きコメントが残り PR Iteration self marker 付きコメントが除外されることを検証する。

## スコープ外

- reviewer prompt の品質改善。
- GitHub review thread comments 全般の再設計。
- design PR iteration の仕様変更。

## 確認事項

- 追加コメントに人間回答済みの仕様決定はありません。
