# Requirements Document

## Introduction

feedman-ios の Issue #55 / #56 で、Triage 通過後に Stage A へ進む直前の fallback 経路が `set -u` による unbound variable で異常終了し、Issue が `codex-picked-up` のまま stale になる事象が確認された。
原因候補は、Stage A の mode ログ出力で shell 変数名の直後に全角閉じ括弧が続き、bash が意図しない変数名として解釈する境界不備である。
本件では Stage A fallback ログの安全性を回復し、PM / Developer 分離を含む impl 経路がログ出力だけで停止しないことを要件化する。
Issue コメントでは Triage edit paths と処理開始通知以外の追加決定事項はなかった。

## Requirements

### Requirement 1: Stage A fallback ログの安全性

**Objective:** As a watcher operator, I want Stage A fallback が mode をログ出力しても nounset で停止しないこと, so that Triage 通過後の Issue が `codex-picked-up` のまま stale にならない。

#### Acceptance Criteria

1. When Stage A fallback logs the current mode with a multibyte delimiter immediately after the mode value, the idd-codex watcher shall complete the log output without triggering an unbound variable error.
2. While the watcher runs with nounset semantics enabled, the idd-codex watcher shall treat the mode value as the intended mode variable rather than a variable name extended by the adjacent multibyte delimiter.
3. If the current mode is `impl` when Stage A fallback logging runs, the idd-codex watcher shall preserve the `impl` value in the Stage A log line.
4. If the current mode is `impl-resume` when Stage A fallback logging runs, the idd-codex watcher shall preserve the `impl-resume` value in the Stage A log line.

### Requirement 2: Stage A 進行状態の維持

**Objective:** As a repository maintainer, I want Stage A fallback logging failure が pipeline 停止や stale label を作らないこと, so that 自動開発フローが次 stage へ進むか既存の失敗処理へ到達できる。

#### Acceptance Criteria

1. When Triage has handed an Issue to the impl pipeline and Stage A fallback logging runs successfully, the idd-codex watcher shall continue to the existing Stage A execution flow.
2. When Stage A PM split is enabled and the fallback Stage A path is selected for an impl Issue, the idd-codex watcher shall reach the PM requirements-definition step after writing the Stage A mode log.
3. If Stage A later fails for a reason unrelated to mode log expansion, the idd-codex watcher shall use the existing Stage A failure handling instead of failing at the mode log line.
4. The idd-codex watcher shall not leave an Issue stale solely because Stage A mode logging encountered a shell variable boundary with a multibyte delimiter.

### Requirement 3: 回帰検証

**Objective:** As a maintainer, I want the nounset regression to be covered by shell-level checks, so that unsafe mode logging does not re-enter the watcher.

#### Acceptance Criteria

1. When regression verification runs for Stage A fallback logging, the verification shall cover a nounset shell environment with a mode value followed by a multibyte delimiter.
2. When regression verification is evaluated against the historical unsafe mode-log expression, the verification shall detect the unbraced `$MODE）` form as unsafe without requiring runtime failure on every supported bash version.
3. When regression verification is evaluated against the corrected mode-log behavior, the verification shall pass and confirm that the expected Stage A mode text is emitted.
4. When regression verification covers Stage A PM split or fallback logging, the verification shall confirm that the PM requirements-definition path is still reachable after the mode log is written.
5. When regression verification scans watcher shell sources, the verification shall detect unsafe unbraced shell variable expansions immediately followed by multibyte text in Stage A logging-adjacent paths.
6. When implementation changes watcher shell scripts, the verification shall include shell-level static checks for changed shell files.

### Requirement 4: 既存運用契約の維持

**Objective:** As a current idd-codex operator, I want this bug fix to avoid broad behavior changes, so that existing cron / launchd and label-based operations continue unchanged.

#### Acceptance Criteria

1. The idd-codex watcher shall preserve existing env var names, label names, cron / launchd invocation contracts, and exit code meanings.
2. The idd-codex watcher shall preserve the existing `STAGE_A_PM_SPLIT_ENABLED` opt-out semantics.
3. The idd-codex watcher shall not add a new external service call for this bug fix.
4. When this bug fix changes operator-observable watcher behavior or documentation-relevant Stage A behavior, the repository documentation shall describe the updated behavior consistently with existing Stage A documentation.

## Non-Functional Requirements

### NFR 1: 可観測性

1. When Stage A fallback logs the current mode, the idd-codex watcher shall leave an operator-visible log line that includes the stage and current mode.
2. If Stage A fails after the fallback mode log succeeds, the idd-codex watcher shall leave operator-visible evidence that the failure occurred after mode logging rather than because of mode variable expansion.

### NFR 2: 互換性

1. The idd-codex watcher shall keep the bug fix backward-compatible for existing consumer repos by avoiding required cron / launchd configuration changes.
2. The idd-codex watcher shall keep the bug fix backward-compatible for existing consumer repos by avoiding new required runtime dependencies.

## Out of Scope

- Stage A の PM / Developer 分離モデルそのものの変更。
- Triage 判定、Architect 要否判定、Reviewer 判定、Stage C PR 作成の仕様変更。
- `codex-picked-up`、`codex-claimed`、`codex-failed` など既存ラベル名や状態機械の再設計。
- Codex CLI 本体、bash 本体、または consumer repo 側の修正。
- 新しい外部サービス呼び出し、runtime dependency、または opt-in 機能の追加。

## Open Questions

- なし。
