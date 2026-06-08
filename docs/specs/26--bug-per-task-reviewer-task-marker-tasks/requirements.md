# Requirements Document

## Introduction

per-task ループでは、Implementer が task 完了時に `tasks.md` の対象 checkbox を `[ ]` から `[x]` へ更新し、`docs(tasks): mark <id> as done` の専用 commit を積む。この marker commit は per-task Reviewer の review range 終端として使われるため、対象 task の checkbox 差分は通常 range 内に含まれる。

現状の Reviewer は、この必須 marker commit による `tasks.md` checkbox 更新を、task の `_Boundary:_` 外変更として扱い `boundary 逸脱` で reject することがある。本件は marker commit 自体を廃止するものではなく、正規 marker の対象 checkbox 更新だけを orchestration artifact として分類し、task 本文や境界定義などの不正な `tasks.md` 変更は従来どおり reject 可能にするための bug fix である。

Issue コメントでは追加の人間決定事項はなく、Triage edit_paths は `.codex/`、`repo-template/`、`local-watcher/` である。

## Related

- Related: #13 #21 #23

## Requirements

### Requirement 1: 正規 task marker checkbox 差分の分類

**Objective:** As a per-task reviewer, I want 正規 marker commit による対象 task checkbox 更新を orchestration artifact として扱うこと, so that 必須の進捗 marker が false positive の `boundary 逸脱` reject を起こさない。

#### Acceptance Criteria

1. When per-task Reviewer が `docs(tasks): mark <id> as done` commit を含む range を review するとき, the per-task Reviewer shall 当該 `<id>` の `tasks.md` checkbox 更新を allowed orchestration artifact として分類する。
2. When per-task Reviewer が `_Boundary:_` を評価するとき, the per-task Reviewer shall 正規 marker commit が review 対象 task の checkbox を `[ ]` から `[x]` へ更新したことだけを理由に reject しない。
3. While per-task Reviewer が正規 marker commit を含む range を review しているとき, the per-task Reviewer shall marker commit 以外の task-scope 変更を既存の 3 カテゴリ判定対象として扱う。
4. If marker commit の subject が `docs(tasks): mark <id> as done` の単一 task ID 契約から外れているとき, the per-task Reviewer shall その marker を allowed orchestration artifact として自動分類しない。

### Requirement 2: tasks.md 変更の reject 可能範囲維持

**Objective:** As a workflow maintainer, I want allowed artifact の範囲を対象 checkbox 更新だけに限定すること, so that tasks.md の仕様改変や無関係 task 更新を boundary 逸脱として検出し続けられる。

#### Acceptance Criteria

1. When `tasks.md` changes include task body edits, the per-task Reviewer shall その変更を `boundary 逸脱` の候補として扱える。
2. When `tasks.md` changes include `_Requirements:_` edits, the per-task Reviewer shall その変更を `boundary 逸脱` の候補として扱える。
3. When `tasks.md` changes include `_Boundary:_` edits, the per-task Reviewer shall その変更を `boundary 逸脱` の候補として扱える。
4. When `tasks.md` changes include `_Depends:_` edits, the per-task Reviewer shall その変更を `boundary 逸脱` の候補として扱える。
5. When `tasks.md` changes include task ordering edits, the per-task Reviewer shall その変更を `boundary 逸脱` の候補として扱える。
6. When `tasks.md` changes include unrelated task checkbox updates, the per-task Reviewer shall その変更を `boundary 逸脱` の候補として扱える。
7. When range changes include spec artifact updates outside the canonical marker checkbox update, the per-task Reviewer shall その変更を既存の boundary 判定対象として扱える。

### Requirement 3: per-task prompt 契約の明確化

**Objective:** As an implementer and reviewer, I want task marker commit の作成側と分類側が同じ契約を共有すること, so that per-task range に含まれる marker commit の扱いを誤読しない。

#### Acceptance Criteria

1. When per-task Implementer prompt explains task completion, the prompt shall `docs(tasks): mark <id> as done` commit と対象 task checkbox 更新の契約を説明する。
2. When per-task Reviewer prompt explains reviewed range, the prompt shall marker commit が range に含まれ得ることを明示する。
3. When per-task Reviewer prompt explains marker commit classification, the prompt shall 対象 task checkbox 更新だけを allowed orchestration artifact として扱うことを明示する。
4. When per-task Reviewer prompt explains marker commit classification, the prompt shall task 本文、`_Requirements:_`、`_Boundary:_`、`_Depends:_`、順序、無関係 checkbox、その他 spec artifact 更新は allowed orchestration artifact ではないことを明示する。
5. When per-task Implementer prompt and per-task Reviewer prompt mention marker commit, the prompts shall 同じ marker commit subject と checkbox 更新契約を共有する。

### Requirement 4: root と repo-template の契約同期

**Objective:** As a template maintainer, I want self-hosting 用 prompt と配布テンプレート用 prompt が同じ marker classification contract を持つこと, so that idd-codex 自身と consumer repo が同じ per-task Reviewer 挙動で動作する。

#### Acceptance Criteria

1. When marker classification contract を agent prompt に追加または変更するとき, the repository shall root `.codex/agents/` と `repo-template/.codex/agents/` の対応ファイルを byte-identical に保つ。
2. When marker classification contract を shared rule に追加または変更するとき, the repository shall root `.codex/rules/` と `repo-template/.codex/rules/` の対応ファイルを byte-identical に保つ。
3. When implementation changes agent files, the verification shall include `diff -r .codex/agents repo-template/.codex/agents` が差分なしであること。
4. When implementation changes rule files, the verification shall include `diff -r .codex/rules repo-template/.codex/rules` が差分なしであること。

### Requirement 5: regression coverage

**Objective:** As a maintainer, I want false positive を再現する commit range を検証できること, so that regression-test-only task と marker commit の組み合わせで boundary reject が再発しない。

#### Acceptance Criteria

1. When regression coverage reproduces a range containing a regression-test-only commit followed by `docs(tasks): mark <id> as done`, the test suite shall verify that the canonical marker checkbox update does not cause `boundary 逸脱` reject.
2. When regression coverage includes the canonical marker checkbox update, the test suite shall verify that the reviewed task checkbox changes from `[ ]` to `[x]`.
3. When regression coverage includes non-canonical `tasks.md` changes, the test suite shall verify that task body、`_Requirements:_`、`_Boundary:_`、`_Depends:_`、ordering、or unrelated checkbox changes remain reject-eligible.
4. If shell-level fixture coverage is not practical for a prompt-only assertion, the implementation notes shall state the reason and identify the manual verification used instead.

## Non-Functional Requirements

### NFR 1: Backward compatibility

1. The system shall preserve the existing per-task Reviewer categories of `AC 未カバー`, `missing test`, and `boundary 逸脱`.
2. When `PER_TASK_LOOP_ENABLED` is not `true`, the system shall preserve the existing single Developer plus single Reviewer workflow semantics.
3. The system shall preserve existing env var names, label names, cron invocation contracts, branch naming contracts, and exit code meanings.
4. The system shall not introduce new external services or new runtime dependencies.

### NFR 2: Operator observability

1. When per-task Reviewer classifies a marker checkbox update as an allowed orchestration artifact, the review output shall leave enough information for an operator to distinguish that classification from ordinary `_Boundary:_` approval.
2. When per-task Reviewer rejects `tasks.md` changes despite a marker commit being present, the review output shall identify which non-marker `tasks.md` change caused the reject.

## Out of Scope

- #13 の実装修正そのもの。
- #21 の task 分割 / missing test 問題。
- #23 の retry 後 marker range 漏れ問題。
- Reviewer の 3 カテゴリ体系変更。
- `docs(tasks): mark <id> as done` commit の廃止。
- per-task loop 全体設計の刷新。
- 新しい外部サービス呼び出しや runtime dependency の追加。

## Open Questions

- なし。

## PM Self Review

- Mechanical Checks: numeric requirement ID、全 requirement の EARS 形式 AC、Out of Scope、Open Questions を確認した。
- 判断レビュー: Issue 本文の受入基準、既存 per-task marker 契約、#23 との差分、root / repo-template byte-identical 規約、回帰検証要求を網羅し、実装方針・関数設計・ファイル分割に踏み込んでいないことを確認した。
