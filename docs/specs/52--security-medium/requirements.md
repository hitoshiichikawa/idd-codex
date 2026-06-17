# Requirements Document

## Introduction

Issue #52 は、インストーラ、bootstrap 導線、local watcher、PR Reviewer Processor に残る中〜低リスクのセキュリティ・ハードニング項目をまとめて扱う。
既存コメントにより 6-1 は PR #53 で対応済みのため、本要件では 6-2〜6-7 のみを対象にする。
本変更は公開 OSS としての安全な導入、再インストール時の利用者設定保護、未信頼入力の shell 解釈抑制、公開 PR コメントへの情報漏洩防止を目的とする。
既存の env var 名、ラベル遷移、cron / launchd の基本運用は維持し、既存利用者に破壊的な移行を要求しない。

## Requirements

### Requirement 1: bootstrap 導入経路の固定化

**Objective:** As an idd-codex installer user, I want the recommended bootstrap path to use an auditable pinned release reference, so that a mutable default branch update cannot immediately change code executed by `curl | bash`.

#### Acceptance Criteria

1. When README, QUICK-HOWTO, or setup script help shows the recommended `curl | bash` install command, the documentation shall use a version-pinned release tag or commit reference instead of mutable `main`.
2. When `setup.sh` runs without `IDD_CODEX_BRANCH` override, the bootstrap shall use the documented pinned default reference for clone or update.
3. If an operator sets `IDD_CODEX_BRANCH` or `IDD_CODEX_REPO_URL`, the bootstrap shall honor the override without changing the env var names.
4. If an operator sets `IDD_CODEX_BRANCH` to a mutable branch, the documentation shall identify that choice as an explicit override of the pinned default.
5. Where checksum artifacts are provided for a pinned release, the install documentation shall describe a manual verification path before executing the downloaded script.

### Requirement 2: 再インストール時の利用者設定保護

**Objective:** As a local watcher operator, I want repeated installs to preserve user-edited local runtime files, so that repository settings and model choices are not silently lost.

#### Acceptance Criteria

1. When `install.sh --local` or `install.sh --all` encounters an existing `$HOME/bin/idd-codex-issue-watcher.sh` that differs from the bundled template, the installer shall not silently discard the existing file contents.
2. When `install.sh --local` or `install.sh --all` encounters an existing macOS launchd plist that differs from the bundled template, the installer shall not silently discard the existing file contents.
3. When the installer preserves a changed local runtime file, the installer shall provide an operator-visible recovery path for the previous contents.
4. If a recovery file for the same local runtime target already exists, the installer shall not overwrite that recovery file without an explicit operator opt-in.
5. When `install.sh --dry-run --local` or `install.sh --dry-run --all` is run, the installer shall report whether each local runtime target would be created, skipped, backed up, or overwritten.

### Requirement 3: guard profile path expansion robustness

**Objective:** As an operator enabling Codex Guard Hook, I want generated guard profile configuration to preserve the hook path exactly, so that valid local paths do not disable the guard accidentally.

#### Acceptance Criteria

1. When `install.sh --local` generates the Codex Guard Hook profile, the generated profile shall contain the exact hook script path selected by the operator or default configuration.
2. When the hook script path contains `#`, `\`, `&`, spaces, or other path characters valid on the target platform, the generated profile shall remain valid and shall not truncate or corrupt the path.
3. If the guard profile cannot be generated with the exact hook script path, the installer shall fail the guard profile generation with an operator-visible error instead of writing a malformed profile.
4. When `install.sh --dry-run --local` is run with Codex Guard Hook files present, the installer shall report the guard profile action without writing or modifying the generated profile.

### Requirement 4: PR Reviewer エラーコメントの情報漏洩防止

**Objective:** As a repository maintainer, I want PR Reviewer execution failures to be visible without exposing local stderr details publicly, so that tokens, local paths, or environment details are not leaked into PR comments.

#### Acceptance Criteria

1. When PR Reviewer execution exits non-zero for a non-quota reason, the PR Reviewer Processor shall post a generic public PR error comment that does not include raw stdout or stderr excerpts.
2. When PR Reviewer execution exits non-zero for a non-quota reason, the PR Reviewer Processor shall keep diagnostic details available to the local operator through local logs or local artifacts.
3. If review tool stderr contains a local filesystem path, token-like text, or environment-specific diagnostic text, the PR Reviewer Processor shall not copy that text into a public PR comment.
4. When PR Reviewer reports an execution failure publicly, the public comment shall include enough stable context for the operator to correlate the failure with local logs.
5. While `PR_REVIEWER_ENABLED` is not exactly `true`, the PR Reviewer Processor shall retain the existing no-op behavior and shall not add comments or labels.

### Requirement 5: 予測可能な一時ファイル名の排除

**Objective:** As a local watcher operator on a multi-user host, I want temporary files that may contain prompts, JSON, stderr, or reset state to be non-predictable and owner-restricted, so that another local user cannot pre-create or read them.

#### Acceptance Criteria

1. When the local watcher or its processors create temporary files for triage results, quota reset state, auto-rebase results, command stderr, or PR Reviewer artifacts, the files shall be created with non-predictable names.
2. When the local watcher or its processors create temporary files that may contain operational diagnostics or prompt data, the files shall be readable only by the watcher user by default.
3. If secure temporary file creation fails, the local watcher shall fail the current operation with an operator-visible error instead of falling back to a predictable `/tmp` path based on PID, timestamp, issue number, or repo slug alone.
4. While the local watcher is running, temporary files containing prompts, JSON, stderr, or reset state shall not rely on pre-existing world-writable paths for correctness.
5. When the operation using a temporary file completes or fails, the local watcher shall clean up the temporary file unless it is intentionally retained as an operator-visible diagnostic artifact.

### Requirement 6: PR Reviewer の未信頼 ref 値の shell 解釈抑制

**Objective:** As a maintainer using PR Reviewer, I want PR-derived refs and placeholders to be accepted only when they are safe as data, so that branch names cannot alter the review command.

#### Acceptance Criteria

1. When PR Reviewer substitutes `{BASE}`, `{HEAD}`, or `{PR}` into a configured review command, the PR Reviewer Processor shall prevent PR-derived values from being interpreted as shell syntax.
2. If a base ref, head ref, or PR number contains newline, redirection characters, glob metacharacters, command substitution syntax, shell separators, or a leading option-like form, the PR Reviewer Processor shall skip that PR with an operator-visible warning.
3. When a PR has a head branch outside `PR_REVIEWER_HEAD_PATTERN`, the PR Reviewer Processor shall continue to exclude it from review.
4. When a PR originates from a fork repository, the PR Reviewer Processor shall continue to exclude it from review.
5. While PR Reviewer is enabled, rejected placeholder values shall not create PR comments that expose the rejected value beyond the minimum diagnostic context needed by the operator.

## Non-Functional Requirements

### NFR 1: 後方互換性

1. When this hardening is applied, the system shall keep existing env var names, including `IDD_CODEX_BRANCH`, `IDD_CODEX_REPO_URL`, `IDD_CODEX_DIR`, `REPO`, `REPO_DIR`, `TRIAGE_MODEL`, `DEV_MODEL`, `PR_REVIEWER_ENABLED`, and `AUTO_REBASE_MODE`.
2. When this hardening is applied, the system shall keep existing label names and label transition meanings.
3. When this hardening is applied, the system shall keep existing cron and launchd command paths for the local watcher.
4. When this hardening is applied, the system shall preserve installer idempotency for repeated `install.sh --repo`, `install.sh --local`, and `install.sh --all` runs.

### NFR 2: Documentation and operator observability

1. When a recommended install command, env var default, local runtime overwrite policy, PR Reviewer failure behavior, or temporary file policy changes, the documentation shall describe the changed operator-visible behavior.
2. When a hardening check rejects input or fails closed, the system shall emit an operator-visible log or install message identifying the affected feature and reason category.
3. When this hardening is implemented, regression coverage shall include at least one normal case, one unwanted input case, and one boundary case for the changed security-sensitive behavior.

## Out of Scope

- 6-1（feature テンプレートの `codex-auto-dev` 自動付与除去）。PR #53 で対応済みのため本 spec では扱わない。
- `codex-auto-dev` ラベル名、Issue テンプレート体系、既存ラベル遷移契約の変更。
- `codex` / `agy` など外部 AI レビューツール本体のインストール、認証、sandbox 実装の変更。
- 既存 operator が明示的に指定した `IDD_CODEX_REPO_URL` / `IDD_CODEX_BRANCH` override の禁止。
- OS 全体の `/tmp` 権限設定、cron / launchd の登録方式、または watcher 実行ユーザーの変更。
- 過去に公開済みの PR コメントや既存ローカルログからの情報削除。

## Open Questions

- 既定の pinned reference として採用する release tag または commit SHA はどれか。
- checksum artifacts を同一 PR で提供するか、release 運用手順として別途扱うか。

## PM Self Review

- Mechanical Checks: numeric ID 見出し、各 Requirement / NFR の EARS 形式 AC、Out of Scope の存在を確認した。
- Coverage Review: Issue #52 の 6-2〜6-7、既存コメントによる 6-1 除外、README / QUICK-HOWTO / install.sh / setup.sh / PR Reviewer / Auto Rebase / watcher の現状仕様を反映した。
- Scope Review: 実装方針、モジュール分割、公開インターフェース設計、外部ツール本体の変更、過去ログ削除を除外した。
