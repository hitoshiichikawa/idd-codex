# Requirements Document

## Introduction

PR Reviewer Processor は `VERDICT: approve` を含むレビューコメントを投稿しているが、そのコメントは GitHub の formal review ではないため、`reviewDecision` が `APPROVED` にならない。Merge Queue Processor は現在 GitHub 側の approved review を候補抽出条件にしているため、PR Reviewer が approve した PR が自動処理へ進まず、運用者の手動 merge 待ちで停止する。

本件では、PR Reviewer の approve 判定を Merge Queue が消費できる承認 signal として露出し、PR head が更新された場合は stale approve を無効化する。formal review を投稿できる環境では GitHub の reviewDecision 経路に乗せ、投稿できない環境では既存の idd-codex marker を first-class signal として扱う。

## Requirements

### Requirement 1: Approve signal exposure

**Objective:** As a watcher operator, I want PR Reviewer の approve 判定が後段 processor へ伝播されること, so that approved PR が手動操作なしで Merge Queue の候補に入る。

#### Acceptance Criteria

1. When PR Reviewer Processor が対象 PR の最新 head SHA に対して `VERDICT: approve` を検出したとき, the PR Reviewer Processor shall Merge Queue Processor が消費できる approve signal を公開する。
2. When PR Reviewer Processor が対象 PR の最新 head SHA に対して `VERDICT: codex-needs-iteration` を検出したとき, the PR Reviewer Processor shall approve signal を公開しない。
3. When PR Reviewer Processor のレビュー出力に approve と reject 相当の signal が混在するとき, the PR Reviewer Processor shall 安全側で approve signal を公開せず、再作業が必要な状態として扱う。
4. While PR Reviewer Processor が同一 head SHA の既存 review marker を検出して skip するとき, the system shall 既存 marker から同一 SHA の approve signal を再利用できる。

### Requirement 2: GitHub formal review path

**Objective:** As a repository maintainer, I want 利用可能な場合は GitHub の formal review として approve が投稿されること, so that GitHub 標準の `reviewDecision` と branch protection に接続できる。

#### Acceptance Criteria

1. When GitHub formal review posting is available and PR Reviewer Processor returns approve, the system shall create an `APPROVE` review for the reviewed PR head SHA.
2. When GitHub formal review posting succeeds, the system shall leave the PR Reviewer review comment marker contract usable for idempotency and audit.
3. If GitHub formal review posting is rejected by permissions, self-review restriction, validation, or API failure, the system shall record an operator-visible WARN or status comment explaining why formal review was not used.
4. If GitHub formal review posting is unavailable, the system shall continue with the idd-codex approve marker path without failing the whole watcher cycle.

### Requirement 3: Merge Queue approval consumption

**Objective:** As a watcher operator, I want Merge Queue が GitHub reviewDecision と idd-codex approve marker の両方を承認 signal として扱うこと, so that formal review を作れない環境でも approved PR が停滞しない。

#### Acceptance Criteria

1. When Merge Queue Processor evaluates open non-draft managed PRs, the Merge Queue Processor shall include PRs approved by GitHub formal review.
2. When Merge Queue Processor evaluates open non-draft managed PRs and formal review approval is absent, the Merge Queue Processor shall include PRs with an idd-codex approve marker for the current head SHA.
3. If a PR has an idd-codex reject or iteration marker for the current head SHA, the Merge Queue Processor shall not treat that PR as approved by idd-codex marker.
4. While Merge Queue Processor consumes an idd-codex approve marker, the Merge Queue Processor shall preserve existing exclusions for draft PRs, failed PRs, rebase-needed PRs, fork PRs, and unmanaged head branches.
5. When Merge Queue Re-check Processor evaluates `codex-needs-rebase` PRs, the Merge Queue Re-check Processor shall use the same approval signal semantics as the main Merge Queue Processor.

### Requirement 4: Stale SHA safety

**Objective:** As a reviewer, I want old approve decisions to be invalidated when PR head changes, so that unreviewed commits are not merged.

#### Acceptance Criteria

1. When a reviewer marker exists for an old head SHA and the PR head SHA changes, the system shall require re-review before treating the PR as approved.
2. When Merge Queue Processor sees only old-SHA approve markers, the Merge Queue Processor shall not include the PR as approved by idd-codex marker.
3. When PR Reviewer Processor sees an old-SHA marker but no marker for the current head SHA, the PR Reviewer Processor shall run review for the current head SHA.
4. The system shall keep the current marker format backward compatible enough to parse existing `idd-codex:pr-reviewer sha=<sha> kind=review tool=<tool>` comments.

### Requirement 5: Observability and documentation

**Objective:** As an operator, I want approval source and fallback behavior to be visible in logs and documentation, so that stalled PRs can be diagnosed.

#### Acceptance Criteria

1. When Merge Queue Processor counts candidate PRs, the Merge Queue Processor shall make approval source observable as GitHub formal review or idd-codex marker.
2. When PR Reviewer Processor cannot post a formal review and falls back to marker approval, the system shall make the fallback observable.
3. When README documents PR Reviewer and Merge Queue integration, the README shall explain formal review and marker fallback behavior.
4. When README documents stale SHA behavior, the README shall state that approvals are tied to the current PR head SHA.

### Requirement 6: Regression coverage

**Objective:** As a maintainer, I want regression tests for approve marker semantics, so that future changes do not reintroduce merge queue stalls or stale approvals.

#### Acceptance Criteria

1. When regression tests cover a current-SHA approve marker, the test suite shall verify that Merge Queue treats the PR as approved without relying on `reviewDecision`.
2. When regression tests cover an old-SHA approve marker, the test suite shall verify that Merge Queue does not treat the PR as approved.
3. When regression tests cover a current-SHA reject or iteration marker, the test suite shall verify that Merge Queue does not treat the PR as approved.
4. When regression tests cover GitHub formal review approval, the test suite shall verify that existing `reviewDecision == APPROVED` behavior remains supported.
5. When regression tests cover PR Reviewer approve output, the test suite shall verify that approve and iteration verdicts produce distinct approval signals.

## Non-Functional Requirements

### NFR 1: Backward compatibility

1. The system shall preserve existing env var names, label names, cron invocation contracts, and exit code meanings.
2. When `PR_REVIEWER_ENABLED` is not `true`, the system shall preserve existing PR Reviewer opt-in behavior.
3. When `MERGE_QUEUE_ENABLED` is not `true`, the system shall preserve existing Merge Queue opt-out behavior.

### NFR 2: Operational safety

1. If GitHub API calls for comments, reviews, or PR listing fail, the system shall log WARN and skip the affected approval path rather than merging on incomplete evidence.
2. The system shall not require new external services beyond existing `gh`, `jq`, `git`, `flock`, and configured PR reviewer tool commands.

## Out of Scope

- PR Reviewer のレビュー品質改善全般。
- PR Iteration の指摘反映ロジック変更。
- Gitflow の closing keyword / `codex-staged-for-release` 判定変更。
- feedman-ios 固有の PR や Issue の修正。
- GitHub branch protection 設定の変更。

## Open Questions

- なし。

## Issue コメント反映

- `gh issue view 13 --repo hitoshiichikawa/idd-codex --comments` では、Triage edit_paths と design モード開始通知のみを確認した。人間による追加決定事項はなかった。
- Triage edit_paths の自動コメントにより、編集見込み top-level path は `local-watcher/` と `README.md` とする。

## PM Self Review

- Mechanical Checks: numeric requirement ID、全 requirement の EARS 形式 AC、Out of Scope、Open Questions を確認した。
- 判断レビュー: Issue 本文の受入基準、formal review / marker fallback、stale SHA、reject marker、README 更新、回帰テスト要求を網羅していることを確認した。
