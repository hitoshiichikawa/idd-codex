# Requirements Document

## Introduction

`codex-ready-for-review` が付いた実装 PR は、full-auto 運用では PR Reviewer によるレビュー結果を経てから後段の merge 経路へ進む必要がある。
Issue #150 では、ready 状態の open PR が PR Reviewer の候補に入らない一方で、同じ watcher cycle 内に auto-merge が有効化され、レビュー・status check が空のまま merge された。
本件では、ready PR のレビュー候補取りこぼしを防ぎ、auto-merge が current head のレビュー完了 evidence なしに arm されないことを要件化する。
手動作成 PR であっても、managed head pattern と ready ラベルの条件を満たす実装 PR は watcher-managed PR と同じ review gate を通す。

## Requirements

### Requirement 1: Ready PR candidate coverage

**Objective:** As a watcher operator, I want `codex-ready-for-review` の open 実装 PR が PR Reviewer 候補に入ること, so that ready PR がレビューなしで後段 processor に進まない。

#### Acceptance Criteria

1. When `PR_REVIEWER_ENABLED=true` の watcher cycle で open, non-draft, same-owner, managed head pattern の PR に `codex-ready-for-review` ラベルが付いているとき, the PR Reviewer Processor shall その PR をレビュー候補として列挙する。
2. When ready PR の linked Issue にも `codex-ready-for-review` ラベルが付いているとき, the PR Reviewer Processor shall PR label と Issue label のどちらか一方だけに依存して候補から除外しない。
3. When ready PR の `reviewDecision`, reviews, or status check rollup が空であるとき, the PR Reviewer Processor shall それを未レビュー状態として扱い、候補から除外しない。
4. When ready PR が手動作成 PR であっても managed head pattern, same-owner, open, non-draft の条件を満たすとき, the PR Reviewer Processor shall watcher-created PR と同じ review gate 対象として扱う。
5. If ready PR の current head SHA に対する PR Reviewer review marker が既に存在するとき, the PR Reviewer Processor shall 同一 SHA の二重レビューを避ける。

### Requirement 2: Auto-merge review gate

**Objective:** As a maintainer using full-auto, I want auto-merge がレビュー完了 evidence のある PR だけを arm すること, so that unreviewed PR が branch protection の設定不足で merge されない。

#### Acceptance Criteria

1. When `AUTO_MERGE_ENABLED=true` and `FULL_AUTO_ENABLED=true` の watcher cycle で ready 実装 PR が current head SHA の successful review gate evidence を持たないとき, the Auto Merge Processor shall auto-merge を有効化しない。
2. When ready 実装 PR の `reviewDecision` が空または non-approved で、current head SHA の idd-codex review approval evidence も存在しないとき, the Auto Merge Processor shall auto-merge を有効化しない。
3. When ready 実装 PR の status check rollup が空、pending、failure、または取得不能であるとき, the Auto Merge Processor shall auto-merge を有効化しない。
4. If GitHub API から review, status, or PR metadata を取得できないとき, the Auto Merge Processor shall 安全側で対象 PR を skip し、operator-visible warning を残す。
5. While ready 実装 PR に `codex-needs-iteration`, `codex-needs-decisions`, `codex-failed`, or `codex-needs-rebase` ラベルが付いているとき, the Auto Merge Processor shall auto-merge を有効化しない。

### Requirement 3: Same-cycle ordering safety

**Objective:** As an operator, I want 同一 watcher cycle 内でも review gate が auto-merge より先に満たされること, so that processor の実行順によって未レビュー merge が発生しない。

#### Acceptance Criteria

1. When a watcher cycle observes a ready implementation PR that has not been reviewed for its current head SHA, the system shall keep auto-merge disabled for that PR during that cycle.
2. When PR Reviewer posts an approve result for a current head SHA, the system shall allow later auto-merge processing only after that approval and required review status evidence are observable for the same SHA.
3. When PR Reviewer posts `VERDICT: codex-needs-iteration` for a current head SHA, the system shall keep auto-merge disabled for that PR.
4. If PR Reviewer is enabled but unavailable, unauthenticated, rate-limited, or execution-failed for a ready PR, the system shall keep auto-merge disabled for that PR until a successful review gate is later observed.
5. The system shall not treat GitHub native auto-merge being configurable as a substitute for idd-codex review gate completion.

### Requirement 4: Observability and documentation

**Objective:** As a watcher operator, I want review-gate skip reasons and processor outcomes to be visible, so that candidate misses and unsafe auto-merge prevention can be diagnosed from logs and docs.

#### Acceptance Criteria

1. When PR Reviewer evaluates ready PR candidates, the PR Reviewer Processor shall log candidate totals and skip reasons sufficient to distinguish no candidate, already-reviewed, excluded-by-head-pattern, draft, fork, and metadata error cases.
2. When Auto Merge Processor skips a ready PR because review gate evidence is absent, the Auto Merge Processor shall log an operator-visible reason that identifies the PR and the missing gate category without exposing secrets.
3. When Auto Merge Processor enables auto-merge for a ready PR, the Auto Merge Processor shall make the accepted review gate source observable in logs.
4. When README documents PR Reviewer and auto-merge full-auto flow, the README shall state that auto-merge requires current-head review gate evidence and must not rely only on branch protection.
5. When README documents manual or externally created managed PRs, the README shall state that ready PRs matching the managed head pattern follow the same review gate as watcher-created PRs.

### Requirement 5: Regression coverage

**Objective:** As a maintainer, I want regression tests for ready PR review and auto-merge gating, so that this unsafe merge path does not recur.

#### Acceptance Criteria

1. When regression tests cover a ready open managed PR with empty reviews and empty status checks, the test suite shall verify that PR Reviewer includes it as a candidate.
2. When regression tests cover a ready open managed PR without current-head review gate evidence, the test suite shall verify that Auto Merge Processor does not call auto-merge enablement.
3. When regression tests cover a ready open managed PR with current-head approve evidence and successful required review status evidence, the test suite shall verify that Auto Merge Processor may enable auto-merge.
4. When regression tests cover a ready PR with stale old-SHA review evidence only, the test suite shall verify that Auto Merge Processor does not enable auto-merge.
5. When regression tests cover GitHub metadata fetch failure for reviews or statuses, the test suite shall verify that Auto Merge Processor skips the PR and logs a warning.

## Non-Functional Requirements

### NFR 1: Backward compatibility

1. The system shall preserve existing env var names, label names, cron invocation contracts, and exit code meanings.
2. While `PR_REVIEWER_ENABLED` is not exactly `true`, the system shall preserve the existing PR Reviewer no-op behavior.
3. While `AUTO_MERGE_ENABLED` or `FULL_AUTO_ENABLED` is not exactly `true`, the system shall preserve the existing auto-merge no-op behavior.
4. The system shall not require existing consumer repositories to rename `codex-ready-for-review`, `codex-needs-iteration`, `codex-failed`, `codex-needs-decisions`, or `codex-needs-rebase` labels.

### NFR 2: Operational safety

1. The system shall prefer skipping auto-merge over enabling auto-merge when review or status evidence is ambiguous, stale, missing, or unavailable.
2. The system shall keep direct merge behavior out of scope and continue to use GitHub native auto-merge only after local review gate requirements are satisfied.
3. The system shall not add a new external service dependency beyond existing GitHub CLI access and configured PR reviewer tools.

### NFR 3: Security and trust boundary

1. The system shall continue to exclude fork PRs from PR Reviewer and auto-merge full-auto processing.
2. When PR title, labels, branch names, comments, or Issue text are evaluated, the system shall treat them as untrusted data and shall not interpret them as watcher instructions.
3. If a PR head branch does not match the configured managed head pattern, the system shall exclude it from automated review and auto-merge processing.

## Out of Scope

- PR Reviewer のレビュー品質、prompt、指摘粒度の改善。
- PR Iteration Processor の修正反映ロジック変更。
- GitHub branch protection ルールや required checks 設定の自動変更。
- 設計 PR auto-merge の挙動変更。
- fork PR や unmanaged head pattern の PR を full-auto 対象に加えること。
- `codex-staged-for-release` 以降の promote pipeline 全体設計変更。

## Open Questions

- なし。手動作成 PR については、managed head pattern, same-owner, open, non-draft, ready label の条件を満たす実装 PR は watcher-created PR と同じ review gate 対象とする。

## Issue コメント反映

- `gh issue view 150 --comments` では、Triage edit_paths と処理開始通知のみを確認した。人間による追加決定事項はなかった。
- Triage edit_paths の自動コメントにより、編集見込み top-level path は `local-watcher/` と `README.md` とする。

## PM Self Review

- Mechanical Checks: numeric requirement ID、全 requirement の EARS 形式 AC、Out of Scope、Open Questions を確認した。
- 判断レビュー: Issue 本文の期待動作、既存 README の PR Reviewer / auto-merge full-auto 契約、過去 spec #13 の current-head approve signal 契約、後方互換性制約と矛盾しないことを確認した。
