# Requirements Document

## Introduction

per-task ループでは、task 完了 marker commit がその task の review range 終端として扱われる。#14 では Reviewer reject 後に Implementer / Debugger 経由 Implementer が修正 commit を追加したが、既存 marker が修正前に残ったため、後続 Reviewer が古い range だけを再判定した。

本件は #21 の task 分割と `missing test` 境界の問題ではなく、retry 後の修正 commit と task marker / review range contract の不整合を解消するための bug fix である。per-task Implementer、Reviewer、watcher が同じ marker 終端契約を共有し、未レビュー commit を silent に除外しない状態にする。

Issue コメントにより、同系統の per-task prompt / marker contract を持つ可能性がある `hitoshiichikawa/idd-claude#304` が feedback 先として記録されている。また Triage edit_paths は `local-watcher/`、`.codex/`、`repo-template/` である。

## Related

- Related: #14 #21
- Related: hitoshiichikawa/idd-claude#304

## Requirements

### Requirement 1: task marker 終端契約の明確化

**Objective:** As a workflow maintainer, I want per-task の task marker が当該 attempt の終端を表すこと, so that Reviewer が修正前の古い range だけを再判定しない。

#### Acceptance Criteria

1. When per-task Implementer が task を完了扱いにするとき, the per-task workflow shall task-scope implementation、validation、learning update がすべて完了した後にだけ task done marker を終端として扱う。
2. When Reviewer reject 後に per-task Implementer が同じ task を再実行するとき, the per-task workflow shall 古い task done marker の後ろに新しい task-scope 修正 commit を残したまま Reviewer へ進まない。
3. When Debugger guidance 後に per-task Implementer が同じ task を再実行するとき, the per-task workflow shall 古い task done marker の後ろに新しい task-scope 修正 commit を残したまま Reviewer へ進まない。
4. If 既存 marker 後に同じ task の修正 commit が存在するとき, the per-task workflow shall review range と実際の task-scope 変更が一致する状態へ補正するか、Reviewer 起動前に明示的に停止する。

### Requirement 2: review range の未レビュー commit 除外防止

**Objective:** As a per-task reviewer, I want retry 後の修正 commit が review range から漏れないこと, so that 修正済みの task が古い差分だけで reject されない。

#### Acceptance Criteria

1. When per-task workflow が task の review range を決定するとき, the per-task workflow shall Reviewer 起動前に選択済み marker より後ろの commit が review 対象から silent に除外されないことを保証する。
2. When 選択済み marker より後ろに Reviewer 起動前の未レビュー commit が存在するとき, the per-task workflow shall それらの commit を Reviewer range に含めるか、明確な診断と復旧指示を出して停止する。
3. If marker 後の未レビュー commit を安全に review range へ含められないとき, the per-task workflow shall `codex-failed` 相当の人間復旧可能な失敗として扱い、成功扱いで後続 task または最終 review へ進まない。
4. While per-task retry が同一 task に対して進行中であるとき, the per-task workflow shall 現在の attempt の task-scope 修正が Reviewer 判定対象から外れない状態を維持する。

### Requirement 3: Reviewer への range 明示と誤読防止

**Objective:** As a reviewer, I want 判定対象 SHA range と範囲外 commit の扱いが明示されること, so that per-task review の判断対象を誤読しない。

#### Acceptance Criteria

1. When per-task Reviewer が起動されるとき, the Reviewer prompt shall 判定対象の start SHA と end SHA を明示する。
2. When per-task Reviewer が起動されるとき, the Reviewer prompt shall 判定対象外の commit は当該 per-task review では判断しないことを明示する。
3. When per-task Reviewer が起動されるとき, the per-task workflow shall 運用者がログから task ID、round、review range を確認できる情報を残す。
4. If review range の補正または停止が発生するとき, the per-task workflow shall 運用者が原因と次の復旧操作を判断できる診断情報を残す。

### Requirement 4: prompt / rule 配布の整合

**Objective:** As a template maintainer, I want root と repo-template の per-task 契約が一致すること, so that idd-codex 自身と consumer repo が同じ marker / range contract で動作する。

#### Acceptance Criteria

1. When per-task marker / range contract を agent prompt に追加または変更するとき, the repository shall root `.codex/agents/` と `repo-template/.codex/agents/` の対応ファイルを byte-identical に保つ。
2. When per-task marker / range contract を shared rule に追加または変更するとき, the repository shall root `.codex/rules/` と `repo-template/.codex/rules/` の対応ファイルを byte-identical に保つ。
3. When implementation changes agent or rule files, the verification shall include `diff -r .codex/agents repo-template/.codex/agents` が差分なしであること。
4. When implementation changes agent or rule files, the verification shall include `diff -r .codex/rules repo-template/.codex/rules` が差分なしであること。
5. When README or docs mention per-task marker / review range semantics, the documentation shall reflect the same contract as the runtime behavior and agent prompts.

### Requirement 5: regression coverage

**Objective:** As a maintainer, I want #14 と同じ commit 形状を検証できること, so that marker 後の修正 commit 漏れが再発しない。

#### Acceptance Criteria

1. When regression coverage reproduces a task done marker followed by corrective commit, the test suite shall verify that the corrective commit is included in the Reviewer range or the workflow stops before Reviewer invocation.
2. When regression coverage exercises Reviewer reject followed by Implementer retry, the test suite shall verify that retry 修正 commit が古い marker によって review range から除外されない。
3. When regression coverage exercises Debugger guidance followed by Implementer retry, the test suite shall verify that Debugger 後の修正 commit が古い marker によって review range から除外されない。
4. If shell-level fixture coverage is not practical for a specific prompt-only assertion, the implementation notes shall state the reason and identify the manual verification used instead.

## Non-Functional Requirements

### NFR 1: Backward compatibility

1. The system shall preserve existing env var names, label names, cron invocation contracts, branch naming contracts, and exit code meanings.
2. When `PER_TASK_LOOP_ENABLED` is not `true`, the system shall preserve the existing single Developer plus single Reviewer workflow semantics.
3. When `PER_TASK_LOOP_ENABLED` is `true`, the system shall preserve the existing per-task Reviewer categories of `AC 未カバー`, `missing test`, and `boundary 逸脱`.
4. The system shall not introduce new external services or new runtime dependencies.

### NFR 2: Observability

1. When marker 後の未レビュー commit が検出されるとき, the system shall expose the condition through operator-visible log output or issue failure diagnostics.
2. When the workflow stops before Reviewer invocation due to marker / range inconsistency, the system shall provide enough information for a human operator to identify the task ID and affected range.

## Out of Scope

- #14 の実装修正そのものの再実行。
- #6 / #13 / #21 の task 分割と `missing test` 問題の修正。
- Reviewer の判定カテゴリ変更。
- per-task loop の全体設計刷新。
- `idd-claude` 側の修正実装。
- 新しい外部サービス呼び出しや runtime dependency の追加。

## Open Questions

- なし。

## PM Self Review

- Mechanical Checks: numeric requirement ID、全 requirement の EARS 形式 AC、Out of Scope、Open Questions を確認した。
- 判断レビュー: Issue 本文の受入基準、#14 再現形状、#21 との差分、idd-claude feedback issue、Triage edit_paths、root / repo-template byte-identical 規約、回帰検証要求を網羅し、実装方針・関数設計・ファイル分割に踏み込んでいないことを確認した。
