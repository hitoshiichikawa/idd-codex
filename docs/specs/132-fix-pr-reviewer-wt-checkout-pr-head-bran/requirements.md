# Requirements Document

## Introduction

PR Reviewer Processor は `PR_REVIEWER_ENABLED=true` の opt-in 環境で open PR の head をレビューし、結果を PR コメントと `VERDICT:` による後段処理へ接続する。
現在はレビュー準備時に head branch をメイン repo 側で checkout する前提があり、同じ branch が実装用 wt slot で checkout 済みの場合に Git の worktree 制約と衝突して `checkout-fail` で skip される。
idd-codex の通常運用では実装 slot worktree と PR Reviewer が同時に同じ head branch を扱うため、PR Reviewer は wt 運用と衝突しない review workspace を使って current head SHA をレビューできる必要がある。
本件では既存の PR Reviewer の opt-in、対象 PR 判定、marker、VERDICT、PR Iteration 連携を維持しつつ、checkout 衝突時のレビュー継続と失敗時の可視化を要件化する。

## Requirements

### Requirement 1: wt-compatible review workspace

**Objective:** As a watcher operator, I want PR Reviewer が実装用 wt slot と衝突せず PR head をレビューできること, so that 通常運用中の PR が `checkout-fail` で自動レビュー待ちに停滞しない。

#### Acceptance Criteria

1. When PR Reviewer Processor が対象 PR の current head branch を処理し、その branch が別 worktree で checkout 済みのとき, the PR Reviewer Processor shall `checkout-fail` で skip せず current head SHA のレビュー実行へ進める。
2. When PR Reviewer Processor がレビュー用 workspace を準備するとき, the PR Reviewer Processor shall 実装用 wt slot の checkout 状態を変更することを前提にしない。
3. While PR Reviewer Processor がレビュー用 workspace を準備または使用している間, the PR Reviewer Processor shall 既存の実装用 wt slot にある未保存変更や branch checkout 状態を破棄しない。
4. When PR Reviewer Processor が 1 サイクルで複数 PR を処理するとき, the PR Reviewer Processor shall ある PR の workspace 状態が別 PR の workspace 準備を阻害しないように扱う。
5. The PR Reviewer Processor shall 既存の対象 PR 判定である open、非 draft、managed head pattern、非 fork の条件を維持する。

### Requirement 2: workspace preparation failure visibility

**Objective:** As an operator, I want review workspace 準備に失敗した理由が人間に見えること, so that 自動レビューが止まった原因を local log だけに依存せず判断できる。

#### Acceptance Criteria

1. If PR Reviewer Processor が review workspace 準備に失敗するとき, the PR Reviewer Processor shall PR 番号、head branch、head SHA、失敗分類、原因概要を operator-visible log に記録する。
2. If PR Reviewer Processor が worktree 制約により review workspace を準備できないとき, the PR Reviewer Processor shall その制約が checkout 衝突であることを operator-visible log で判別できるようにする。
3. If PR Reviewer Processor がサポート対象の workspace 準備経路を使っても current head SHA の自動レビューを継続できないとき, the PR Reviewer Processor shall 対象 PR または関連 Issue に人間が認識できる失敗状態を残す。
4. If review workspace 準備失敗が一時的な取得失敗またはリモート API 失敗であるとき, the PR Reviewer Processor shall current head SHA をレビュー済みとして扱わない。
5. The PR Reviewer Processor shall public comment に raw stdout、raw stderr、secret 値、または未信頼入力の長い抜粋をそのまま公開しない。

### Requirement 3: reviewer marker and idempotency preservation

**Objective:** As a maintainer, I want workspace 準備の変更後も PR Reviewer の marker 契約と冪等性が維持されること, so that 同一 SHA の二重レビューやエラーコメント連投が起きない。

#### Acceptance Criteria

1. When PR Reviewer Processor が current head SHA のレビューを正常に完了するとき, the PR Reviewer Processor shall 既存の `idd-codex:pr-reviewer` review marker 契約を維持する。
2. When PR Reviewer Processor が current head SHA に対して人間可視の workspace 準備失敗を残すとき, the PR Reviewer Processor shall 同一 SHA の同種失敗を次サイクルで重複投稿しない。
3. When PR head SHA が更新されるとき, the PR Reviewer Processor shall old SHA の review marker または failure marker だけを理由に current head SHA のレビューを skip しない。
4. While current head SHA の review marker が既に存在するとき, the PR Reviewer Processor shall 既存どおり同一 SHA のレビュー実行を skip する。

### Requirement 4: existing PR Reviewer behavior preservation

**Objective:** As a repository maintainer, I want checkout 衝突修正が PR Reviewer の既存連携を変えないこと, so that 既存運用のラベル遷移や review verdict が意図せず変わらない。

#### Acceptance Criteria

1. When `PR_REVIEWER_ENABLED` is not `true`, the PR Reviewer Processor shall 既存どおり PR を列挙せず副作用なしで終了する。
2. When PR Reviewer Processor がレビュー出力から `VERDICT: codex-needs-iteration` を検出するとき, the PR Reviewer Processor shall 既存どおり `codex-needs-iteration` 連携を維持する。
3. When PR Reviewer Processor がレビュー出力から `VERDICT: approve` を検出するとき, the PR Reviewer Processor shall 既存どおり approve signal 連携を維持する。
4. The PR Reviewer Processor shall 既存の env var 名、ラベル名、コメント marker、cron または launchd 起動契約を変更しない。
5. The PR Reviewer Processor shall 本件の必須挙動として reviewer tool のインストール、認証、レビュー品質改善を追加しない。

### Requirement 5: regression coverage and documentation

**Objective:** As a reviewer, I want wt checkout 衝突と失敗可視化が回帰検証とドキュメントに残ること, so that 同じ停止が再発してもレビュー時に検出できる。

#### Acceptance Criteria

1. When regression verification covers a PR head branch already checked out in another worktree, the verification shall PR Reviewer が `checkout-fail` で skip せずレビュー実行へ進めることを確認する。
2. When regression verification covers review workspace preparation, the verification shall 既存 wt slot の branch checkout 状態が変更されないことを確認する。
3. If regression verification covers an unrecoverable workspace preparation failure, the verification shall operator-visible log と人間可視の失敗状態が残ることを確認する。
4. When regression verification covers `PR_REVIEWER_ENABLED` not being `true`, the verification shall PR Reviewer の opt-out 挙動が従来どおり副作用なしであることを確認する。
5. When README documents PR Reviewer Processor, the documentation shall wt slot 運用と衝突しない review workspace の期待動作と workspace 準備失敗時の確認先を説明する。

## Non-Functional Requirements

### NFR 1: Backward compatibility

1. The system shall preserve existing PR Reviewer env var names, label names, marker format compatibility, cron or launchd invocation contracts, and exit code meanings.
2. When PR Reviewer Processor is disabled, the system shall preserve behavior equivalent to the state before this change with no new PR comments, labels, or git workspace changes.
3. The system shall not require migration for repositories that do not enable PR Reviewer Processor.

### NFR 2: Operational safety

1. The system shall not automatically discard or rewrite existing implementation slot worktree contents as part of PR Reviewer workspace preparation.
2. If PR Reviewer workspace preparation cannot be completed safely, the system shall fail visibly rather than silently skipping the same PR indefinitely.
3. The system shall keep review execution bounded by existing PR Reviewer timeout and max-PR controls.

### NFR 3: Security and trust boundaries

1. The system shall continue to treat PR head branch names, PR titles, PR bodies, and comments as untrusted input.
2. The system shall validate PR head references before passing them to git, gh, or reviewer tool commands.
3. The system shall not introduce a new external service call beyond the existing configured reviewer tool and GitHub CLI interactions.

## Out of Scope

- PR Reviewer のレビュー品質、prompt、または `VERDICT:` 判定ルールの改善。
- PR Iteration Processor の反復実装ロジック変更。
- Merge Queue、auto-merge、branch protection、または status check policy の変更。
- `codex` / `agy` のインストール、認証、セットアップ自動化。
- GraphQL / REST quota 消費や quota wait 処理の変更。
- failed recovery や Issue dispatch 用 slot worktree cleanup 全般の再設計。
- fork PR や unmanaged head branch を PR Reviewer 対象へ広げる変更。

## Open Questions

- なし。

## Issue コメント反映

- `gh issue view 132 --comments` では、Triage edit_paths と処理開始通知のみを確認した。人間による追加決定事項はなかった。
- Triage edit_paths の自動コメントにより、編集見込み top-level path は `local-watcher/` とする。

## PM Self Review

- Mechanical Checks: numeric requirement ID、全 requirement の EARS 形式 AC、Out of Scope、Open Questions を確認した。
- 判断レビュー: Issue 本文の受入基準、既存 README の PR Reviewer Processor 仕様、既存 `pr-reviewer.sh` の checkout-fail 挙動、wt slot 運用との衝突、失敗可視化、既存 opt-in・marker・VERDICT 契約の維持、回帰検証と README 更新要求を網羅していることを確認した。
