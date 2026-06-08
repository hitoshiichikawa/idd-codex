# Requirements Document

## Introduction

per-task Reviewer は、各 task の `_Requirements:_` に列挙された AC をその task 完了時点の判定対象にする。現状の Architect task 分割では、regression coverage / failure path / safety fallback の AC を先行 task に含めたまま、対応テストを後続 task に分離できてしまい、#6 と #13 で `missing test` reject が繰り返された。

本件では、idd-codex 固有の port drift ではなく、Architect / Developer / Reviewer が共有する task-boundary contract の曖昧さを解消する。`tasks.md` の `_Requirements:_`、テスト追加タイミング、partial / deferred boundary の関係を明示し、per-task review が先行 task を不当に fail しない状態にする。

## Requirements

### Requirement 1: task-boundary contract の明確化

**Objective:** As a workflow maintainer, I want Architect / Developer / Reviewer が同じ task-boundary contract を参照すること, so that per-task review の期待値が task 分割と一致する。

#### Acceptance Criteria

1. When Architect が `tasks.md` を生成するとき, the task-boundary contract shall 各 task の `_Requirements:_` がその task 完了時点で実装・テスト・レビュー可能な AC だけを表すことを明示する。
2. When Developer が per-task loop で task を実装するとき, the task-boundary contract shall 当該 task の `_Requirements:_` に含まれる AC の必要テストを同 task の作業として扱うことを明示する。
3. When Reviewer が per-task review を実行するとき, the task-boundary contract shall 当該 task の `_Requirements:_` に含まれる AC のみを `missing test` 判定対象にすることを明示する。
4. The task-boundary contract shall Architect / Developer / Reviewer が参照する agent prompt または shared rule から同一の意味で辿れる。

### Requirement 2: test coverage AC と task 内テスト作業の整合

**Objective:** As a per-task reviewer, I want test coverage を要求する AC が同じ task 内のテスト作業と結び付くこと, so that 実装 task 完了時点で `missing test` を正しく判定できる。

#### Acceptance Criteria

1. When a task の `_Requirements:_` に regression coverage の AC が含まれるとき, the Architect guidance shall 対応する regression test 追加を同 task に明記させる。
2. When a task の `_Requirements:_` に failure path の AC が含まれるとき, the Architect guidance shall 対応する failure path test 追加を同 task に明記させる。
3. When a task の `_Requirements:_` に safety fallback の AC が含まれるとき, the Architect guidance shall 対応する safety fallback test 追加を同 task に明記させる。
4. When a task が実行時挙動を変更するとき, the Architect guidance shall 原則として同 task に最低限の regression test または shell-level test を含めさせる。
5. If 対応テストを同 task に追加しない判断をするとき, the Architect guidance shall 先行 task の `_Requirements:_` から該当 test coverage AC を外すことを要求する。

### Requirement 3: deferred tests と partial boundary の明示

**Objective:** As an architect, I want 後続テスト task に回す範囲を明示できること, so that 先行 task の per-task review が未実施テストを理由に reject しない。

#### Acceptance Criteria

1. When Architect がテスト追加を後続 task に defer するとき, the Architect guidance shall 先行 task の `_Requirements:_` が未実施 test coverage AC を含まないよう要求する。
2. When Architect が partial な先行 task と coverage task の関係を設計するとき, the Architect guidance shall `_Boundary:_` または `_Depends:_` で partial 範囲と coverage task の依存関係を明示させる。
3. When a dedicated regression test task is created, the Architect guidance shall その task の `_Requirements:_` を後続 task 完了時点で検証する AC に限定させる。
4. While deferred test task が存在するとき, the task-boundary contract shall 先行 task の per-task review が後続 task の未実施テストを `missing test` と判定しない境界を維持する。
5. Where deferrable test task notation is used, the task-boundary contract shall `- [ ]*` の意味を既存の optional / deferrable 規約と矛盾しない形で扱う。

### Requirement 4: prompt / rule 配布の整合

**Objective:** As a template maintainer, I want root と repo-template の agent / rule 契約が一致すること, so that idd-codex 自身と consumer repo が同じ task-boundary contract で動作する。

#### Acceptance Criteria

1. When task-boundary contract を agent prompt に追加または変更するとき, the repository shall root `.codex/agents/` と `repo-template/.codex/agents/` の対応ファイルを byte-identical に保つ。
2. When task-boundary contract を shared rule に追加または変更するとき, the repository shall root `.codex/rules/` と `repo-template/.codex/rules/` の対応ファイルを byte-identical に保つ。
3. When implementation changes agent or rule files, the verification shall include `diff -r .codex/agents repo-template/.codex/agents` が差分なしであること。
4. When implementation changes agent or rule files, the verification shall include `diff -r .codex/rules repo-template/.codex/rules` が差分なしであること。
5. When README or docs mention per-task review semantics, the documentation shall reflect the same task-boundary contract as the agent prompts and shared rules.

### Requirement 5: regression coverage for task-boundary guidance

**Objective:** As a maintainer, I want prompt / rule regression を検証できること, so that future changes do not reintroduce ambiguous task splits.

#### Acceptance Criteria

1. When shell-level fixture coverage is practical, the test suite shall verify that a task containing regression coverage AC also contains same-task test work guidance.
2. When shell-level fixture coverage is practical, the test suite shall verify that deferred regression test guidance does not require earlier tasks to list deferred test AC in `_Requirements:_`.
3. When shell-level fixture coverage is practical, the test suite shall verify that root and repo-template agent / rule files remain byte-identical after the contract update.
4. If shell-level fixture coverage is not practical for a specific prompt-only assertion, the implementation notes shall state the reason and identify the manual verification used instead.

## Non-Functional Requirements

### NFR 1: Backward compatibility

1. The system shall preserve existing env var names, label names, cron invocation contracts, branch naming contracts, and exit code meanings.
2. When `PER_TASK_LOOP_ENABLED` is not `true`, the system shall preserve the existing single Developer plus single Reviewer workflow semantics.
3. When `PER_TASK_LOOP_ENABLED` is `true`, the system shall preserve the existing per-task Reviewer categories of `AC 未カバー`, `missing test`, and `boundary 逸脱`.
4. The system shall not relax the rule that new behavior changes require corresponding tests.

### NFR 2: Scope control

1. The implementation shall not change Issue #6 or Issue #13 recovery state.
2. The implementation shall not introduce new external services or new runtime dependencies.
3. The implementation shall keep this change limited to agent prompts, shared rules, documentation, and practical fixture coverage.

## Out of Scope

- #6 / #13 の復旧作業。
- Reviewer の reject category 変更。
- `missing test` 判定の緩和、または test 不要扱いの追加。
- 個別 Issue の仕様変更や既存 AC の再定義。
- per-task loop dispatcher の実行時挙動変更。
- 新しい外部サービス呼び出しや runtime dependency の追加。

## Open Questions

- なし。

## Issue コメント反映

- `gh issue view 21 --comments` により、#6 / #13 の原因は idd-claude との差分ではなく共有 prompt の曖昧さであり、Architect / Developer / Reviewer が共有する task-boundary contract を明示する方針であることを確認した。
- Triage edit_paths の自動コメントにより、編集見込み top-level path は `.codex/agents/`, `.codex/rules/`, `repo-template/.codex/agents/`, `repo-template/.codex/rules/`, `docs/` とする。

## PM Self Review

- Mechanical Checks: numeric requirement ID、全 requirement の EARS 形式 AC、Out of Scope、Open Questions を確認した。
- 判断レビュー: Issue 本文の受入基準、コメント決定事項、per-task Reviewer の `_Requirements:_` 限定判定、root / repo-template byte-identical 規約、実用的な shell-level fixture coverage 要求を網羅していることを確認した。
