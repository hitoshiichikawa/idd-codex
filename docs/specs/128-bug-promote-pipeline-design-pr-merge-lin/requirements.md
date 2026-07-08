# Requirements Document

## Introduction

multi-branch 運用では、実装 PR が `BASE_BRANCH` に merge された Issue は `PROMOTION_TARGET_BRANCH` 到達待ちとして `codex-staged-for-release` で管理される。
一方、設計 PR の merge は実装開始前のレビューゲート解除イベントであり、release staging の完了を意味しない。
現在の Promote Pipeline auto-label が設計 PR 由来の Issue 参照を release staging 対象として扱うと、実装前 Issue が dispatcher から除外される。
本要件は、設計 PR merge を release staging 対象から除外しつつ、実装 PR merge に対する既存の自動付与を維持する。

## Requirements

### Requirement 1: Promote Pipeline auto-label 対象の限定

**Objective:** As a multi-branch 運用者, I want Promote Pipeline が実装 PR merge のみを release staging として扱う, so that 設計 PR merge 後の Issue が誤って実装対象外にならない

#### Acceptance Criteria

1. When `PROMOTE_PIPELINE_ENABLED=true` かつ `BASE_BRANCH != PROMOTION_TARGET_BRANCH` のリポジトリで `codex/issue-<N>-design-*` 形式の head branch を持つ merged PR が検出されたとき, the Promote Pipeline shall linked Issue `<N>` に `codex-staged-for-release` を自動付与しない
2. When `codex/issue-<N>-design-*` 形式の merged PR の title または body が Issue `<N>` を参照しているとき, the Promote Pipeline shall その参照を `codex-staged-for-release` 自動付与の根拠として扱わない
3. When `codex/issue-<N>-impl-*` 形式または既存の managed implementation PR として扱われる merged PR が Issue `<N>` に linked されているとき, the Promote Pipeline shall 従来どおり `codex-staged-for-release` 自動付与候補として扱う
4. If a design PR と implementation PR が同一 watcher cycle の merged PR 候補に混在するとき, the Promote Pipeline shall design PR を除外したうえで implementation PR 由来の候補処理を継続する
5. If Issue `<N>` が既に `codex-staged-for-release` を持っているとき, the Promote Pipeline shall design PR の検出だけを理由に当該ラベルを除去しない

### Requirement 2: 設計 PR merge 後の実装 dispatch 継続

**Objective:** As a repository maintainer, I want 設計 PR merge 後の Issue が実装 stage に進める, so that design gate 通過後の自動開発フローが止まらない

#### Acceptance Criteria

1. When Issue `<N>` の `codex/issue-<N>-design-*` PR が `BASE_BRANCH` に merge されたとき, the watcher shall release staging 用の `codex-staged-for-release` ではなく設計レビュー完了後の通常フローで Issue `<N>` を扱う
2. When design review release flow が Issue `<N>` から `codex-awaiting-design-review` を除去したとき, the watcher shall `codex-staged-for-release` の誤付与によって Issue `<N>` を dispatcher 候補から除外しない
3. While `PROMOTE_PIPELINE_ENABLED=true` の multi-branch 運用が継続している, the watcher shall design PR merge 後の Issue を実装開始可能な状態に保つ
4. If a design PR が `BASE_BRANCH` へ merge された後に watcher cycle が複数回実行されるとき, the Promote Pipeline shall 同じ design PR を理由に `codex-staged-for-release` を再付与しない

### Requirement 3: 回帰検証とドキュメント同期

**Objective:** As a maintainer, I want design PR と implementation PR の auto-label 挙動を検証可能にする, so that 今後の Promote Pipeline 変更で同じ regression を検出できる

#### Acceptance Criteria

1. When regression validation runs for a merged `codex/issue-<N>-design-*` PR that references Issue `<N>`, the validation shall verify that `codex-staged-for-release` is not added to Issue `<N>`
2. When regression validation runs for a merged implementation PR linked to Issue `<N>` under Promote Pipeline enabled multi-branch conditions, the validation shall verify that `codex-staged-for-release` is still added to Issue `<N>`
3. When regression validation includes PR references from title, body, and head branch, the validation shall cover a design PR reference path that previously caused false auto-labeling
4. Where README describes Promote Pipeline auto-label semantics, the documentation shall state that design PR merges are excluded from `codex-staged-for-release` auto-labeling

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The watcher shall preserve existing env var names, label names, opt-in gate semantics, log destinations, and exit code meanings for Promote Pipeline behavior
2. While `PROMOTE_PIPELINE_ENABLED` is unset or not exactly `true`, the watcher shall preserve the existing no-op behavior of Promote Pipeline
3. While `BASE_BRANCH == PROMOTION_TARGET_BRANCH`, the watcher shall preserve the existing no-op behavior of Promote Pipeline

### NFR 2: 可観測性

1. When the Promote Pipeline skips a merged PR because it is a design PR, the watcher shall emit an operator-observable log entry that identifies the skip reason and the PR or Issue involved

## Out of Scope

- Design Review Release Processor の有効化条件、コメント形式、`codex-awaiting-design-review` 除去挙動の変更
- 既に誤付与済みの `codex-staged-for-release` を既存 Issue から自動除去する migration 処理
- `codex-staged-for-release` と `codex-st-failed` のラベル名、意味、色、手動運用契約の変更
- ST result polling、revert、fast-forward promote、`PROMOTE_MODE` の挙動変更
- `codex/issue-<N>-design-*` 以外の新しい設計 PR 命名規則の追加
- 新しい外部サービス呼び出し、GitHub Actions workflow、または sudo を必要とする手順の追加

## Open Questions

- なし
