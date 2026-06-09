# Requirements Document

## Introduction

#14 の module namespace migration により repo 側の watcher と installer は `idd-codex-modules/` を使う形へ移行した。
しかし installed runtime の `$HOME/bin/idd-codex-issue-watcher.sh` が古いままだと、同一ホスト上の idd-claude が管理する `$HOME/bin/modules/` を source し、Triage 前に `_worktree_inject_codex` 未定義で停止する。
本 Issue は repo 側変更を installed runtime へ確実に反映し、stage-a verify と README の運用手順でも stale/shared `modules/` layout を検出できるようにする。

## Requirements

### Requirement 1: local install による installed runtime 反映

**Objective:** As a local watcher operator, I want `install.sh --local` to refresh the installed watcher and namespaced modules, so that cron / launchd continues to use the current idd-codex runtime without manual file-by-file copying.

#### Acceptance Criteria

1. When `install.sh --local` is run after the #14 namespace migration, the installer shall place `idd-codex-issue-watcher.sh` under `$HOME/bin/`.
2. When `install.sh --local` is run after the #14 namespace migration, the installer shall place all required idd-codex watcher modules under `$HOME/bin/idd-codex-modules/`.
3. When `install.sh --local` is run after the #14 namespace migration, the installer shall make `$HOME/bin/idd-codex-modules/core_utils.sh` available before the installed watcher is expected to run.
4. When `install.sh --local` is run after the #14 namespace migration, the installer shall not place idd-codex watcher modules under `$HOME/bin/modules/`.

### Requirement 2: installed watcher の module source 先分離

**Objective:** As an idd-codex watcher process, I want to source modules only from my namespaced module directory, so that idd-claude's `$HOME/bin/modules/` cannot change idd-codex runtime behavior.

#### Acceptance Criteria

1. When the installed `$HOME/bin/idd-codex-issue-watcher.sh` starts, the watcher shall source modules from `$HOME/bin/idd-codex-modules/`.
2. When the installed `$HOME/bin/idd-codex-issue-watcher.sh` starts, the watcher shall not source modules from `$HOME/bin/modules/`.
3. When idd-claude updates `$HOME/bin/modules/`, the installed idd-codex watcher shall continue to resolve `_worktree_inject_codex` from `$HOME/bin/idd-codex-modules/core_utils.sh`.
4. If `$HOME/bin/idd-codex-modules/core_utils.sh` is missing when the installed watcher starts, the watcher shall fail before runtime reaches `_slot_run_issue`.

### Requirement 3: stage-a verify と運用ドキュメントの path 表記

**Objective:** As a maintainer, I want verify commands and README examples to reference idd-codex module paths explicitly, so that automated and manual checks do not mask a stale shared `modules/` layout.

#### Acceptance Criteria

1. When stage-a verify commands mention idd-codex watcher modules, the commands shall use `local-watcher/bin/idd-codex-modules/*.sh`.
2. When README examples mention idd-codex watcher modules, the examples shall use `local-watcher/bin/idd-codex-modules/*.sh` or `$HOME/bin/idd-codex-modules/` as appropriate for the context.
3. When README describes post-merge runtime refresh for watcher changes, the documentation shall instruct operators to run `install.sh --local` or an equivalent copy that refreshes both `$HOME/bin/idd-codex-issue-watcher.sh` and `$HOME/bin/idd-codex-modules/`.
4. When documentation mentions legacy `$HOME/bin/modules/`, the documentation shall state that idd-codex does not use it as a runtime module source.

### Requirement 4: regression coverage for stale/shared module layout

**Objective:** As a reviewer, I want regression coverage to fail on stale installed runtime or shared module layout, so that the #37 / #38 failure mode is caught before worker execution.

#### Acceptance Criteria

1. When regression coverage prepares an installed-runtime fixture, the coverage shall install or copy `idd-codex-issue-watcher.sh` together with `idd-codex-modules/core_utils.sh`.
2. When regression coverage prepares a shared `$HOME/bin/modules/` fixture containing non-codex module functions, the installed idd-codex watcher shall not resolve its required codex functions from that shared fixture.
3. If regression coverage removes `idd-codex-modules/core_utils.sh` from the installed-runtime fixture, the coverage shall observe watcher startup failure before `_slot_run_issue`.
4. If regression coverage observes the installed watcher sourcing `$HOME/bin/modules/`, the coverage shall fail.

## Non-Functional Requirements

### NFR 1: 後方互換性

1. When this fix is applied, the idd-codex watcher shall keep the existing cron / launchd command path `$HOME/bin/idd-codex-issue-watcher.sh`.
2. When this fix is applied, the idd-codex watcher shall keep existing env var names, label names, and exit-code meanings.
3. When this fix is applied, the installer shall remain idempotent for repeated `install.sh --local` runs.

### NFR 2: 併設安全性

1. While idd-codex and idd-claude are installed on the same host, the idd-codex watcher shall not require idd-claude's `$HOME/bin/modules/` contents to be present, absent, or modified.

## Out of Scope

- Dispatcher の slot 番号取得に通常ログが混入する stdout 汚染の修正。
- idd-claude 側 watcher / installer の変更。
- crontab / launchd の watcher 実行パス変更。
- `$HOME/bin/modules/` に残る idd-claude 側ファイルの削除または復旧代行。

## Related

- Related: #14
- Related: #37
- Related: #38

## Open Questions

- なし。

## PM Self Review

- Mechanical Checks: numeric ID 見出し、各 Requirement / NFR の EARS 形式 AC、Out of Scope の存在を確認した。
- Coverage Review: Issue 本文の受入基準、コメントの stage-a-verify 失敗履歴、installed runtime 反映漏れ、idd-claude 併設、README / verify path 表記、起動前 failure 検出を反映した。
- Scope Review: idd-claude 側変更、cron / launchd 実行パス変更、stdout 汚染修正を明示的に除外した。
