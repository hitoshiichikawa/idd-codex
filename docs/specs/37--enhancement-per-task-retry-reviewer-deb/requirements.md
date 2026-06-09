# Requirements Document

## Introduction

per-task retry 経路では、Reviewer reject や Debugger Fix Plan の内容が Developer 再実行 prompt に十分強く渡らず、同じ `missing test` や AC 未カバーが複数 round に残りやすい。#23 の復旧調査では、Req 5.2 / 5.3 の `missing test` が round 1 / 2 / 3 で繰り返し reject され、Debugger の Fix Plan が出ていても per-task Implementer が同じ task を単に再実行する文脈に戻っていた。

本件は、per-task retry 時に Reviewer Findings / Required Action と Debugger Fix Plan を task 固有の checklist として Developer に渡し、Developer が `impl-notes.md` で各 Finding の closure を明示するための enhancement である。さらに、同一 category / target の連続 reject で明らかな未対応が見える場合に、次 Reviewer round の消費前に fail-fast または明示警告できる状態を作る。

Issue コメントでは追加の人間決定事項はなく、Triage edit_paths は `local-watcher/`、`.codex/`、`repo-template/` である。

## Related

- Related: #23

## Requirements

### Requirement 1: Reviewer reject 後の redo prompt context 注入

**Objective:** As a per-task implementer, I want Reviewer reject の Findings / Required Action を再実行 prompt 内で直接受け取ること, so that 指摘 closure を task 再実行の主目的として扱える。

#### Acceptance Criteria

1. When per-task Reviewer round=1 rejects a task, the per-task workflow shall 次の per-task Implementer prompt に current task の `review-notes.md` Findings を inline で含める。
2. When per-task Reviewer round=1 rejects a task, the per-task workflow shall 次の per-task Implementer prompt に current task の `review-notes.md` Required Action を inline で含める。
3. When per-task Implementer prompt includes Reviewer reject context, the prompt shall 対象 task ID、Reviewer round、reject category、target requirement を Developer が識別できる形で示す。
4. If current task に対応する Reviewer reject context を取得できないとき, the per-task workflow shall 通常の同一 task 再実行として silent に進めず、運用者が原因を確認できる診断を残す。

### Requirement 2: Debugger 後の redo prompt context 注入

**Objective:** As a per-task implementer, I want Debugger 後の再実行で Reviewer 指摘と Debugger Fix Plan の両方を同時に受け取ること, so that round 2 reject の原因と修正計画を同じ checklist として閉じられる。

#### Acceptance Criteria

1. When per-task Debugger is invoked after round=2 reject, the per-task workflow shall 次の per-task Implementer prompt に relevant `review-notes.md` Findings を inline で含める。
2. When per-task Debugger is invoked after round=2 reject, the per-task workflow shall 次の per-task Implementer prompt に relevant `debugger-notes.md` Task section を inline で含める。
3. When per-task Implementer prompt includes Debugger context, the prompt shall Reviewer Findings と Debugger Fix Plan のどちらに由来する内容かを Developer が識別できる形で示す。
4. If relevant `debugger-notes.md` Task section を取得できないとき, the per-task workflow shall Debugger 後の再実行として silent に進めず、運用者が原因を確認できる診断を残す。

### Requirement 3: Finding Closure Matrix

**Objective:** As a workflow maintainer, I want Developer が reject target ごとの closure を `impl-notes.md` に残すこと, so that Reviewer と運用者が同じ Finding の未対応再発を機械的に追跡できる。

#### Acceptance Criteria

1. When per-task Implementer is re-run after a Reviewer reject, the Implementer shall `impl-notes.md` に Finding Closure Matrix を作成または更新する。
2. When Finding Closure Matrix is produced, the Implementer shall 各 rejected target requirement を matrix の行として記録する。
3. When Finding Closure Matrix is produced, the Implementer shall 各 rejected target requirement に対応する fix commit を記録する。
4. When Finding Closure Matrix is produced, the Implementer shall 各 rejected target requirement に対応する追加または更新 test/assertion を記録する。
5. When Finding Closure Matrix is produced, the Implementer shall 各 rejected target requirement に対応する verification result を記録する。
6. If a rejected target requirement に対する修正またはテスト更新が不要と判断されるとき, the Implementer shall Finding Closure Matrix にその理由と確認結果を明示する。

### Requirement 4: 連続 reject の未対応検出

**Objective:** As an operator, I want 同じ `missing test` / AC target が未対応のまま Reviewer round を消費し続けないこと, so that time、token、quota の浪費を避けられる。

#### Acceptance Criteria

1. When the same missing test target is rejected repeatedly and no relevant test file changed after the prior reject, the per-task workflow shall 次 Reviewer 起動前に明確な診断で fail fast するか、明示的な warning を残す。
2. When the same AC target is rejected repeatedly and no relevant test file changed after the prior reject, the per-task workflow shall 次 Reviewer 起動前に明確な診断で fail fast するか、明示的な warning を残す。
3. When fail-fast occurs before another Reviewer round, the per-task workflow shall task ID、reject category、target requirement、未検出だった関連 test 差分を運用者が確認できる情報として残す。
4. When warning-only behavior is used before another Reviewer round, the per-task workflow shall Reviewer round を消費する前に同じ未対応リスクを Developer と運用者に見える形で示す。

### Requirement 5: 回帰検証と prompt 配布整合

**Objective:** As a maintainer, I want #23 の再発形状と prompt 配布整合を検証できること, so that redo prompt の context 注入が将来の変更で失われない。

#### Acceptance Criteria

1. When regression coverage reproduces the #23 shape where Req 5.2 / 5.3 missing test survives round 1 and round 2, the verification shall actionable Reviewer context が redo prompt に含まれることを確認する。
2. When regression coverage reproduces the #23 shape where Debugger runs after round 2 reject, the verification shall actionable Debugger context が redo prompt に含まれることを確認する。
3. When regression coverage exercises Finding Closure Matrix generation, the verification shall rejected target requirement、fix commit、test/assertion、verification result の対応が `impl-notes.md` に残ることを確認する。
4. When implementation changes agent prompt files, the verification shall include `diff -r .codex/agents repo-template/.codex/agents` が差分なしであること。
5. When implementation changes shared rule files, the verification shall include `diff -r .codex/rules repo-template/.codex/rules` が差分なしであること。
6. If shell-level fixture coverage is not practical for a specific prompt-only assertion, the implementation notes shall state the reason and identify the manual verification used instead.

## Non-Functional Requirements

### NFR 1: Backward compatibility

1. The system shall preserve existing env var names, label names, cron invocation contracts, branch naming contracts, and exit code meanings.
2. When `PER_TASK_LOOP_ENABLED` is not `true`, the system shall preserve the existing single Developer plus single Reviewer workflow semantics.
3. When `PER_TASK_LOOP_ENABLED` is `true`, the system shall preserve the existing per-task Reviewer categories of `AC 未カバー`, `missing test`, and `boundary 逸脱`.
4. The system shall not introduce new external services or new runtime dependencies.

### NFR 2: Operator observability

1. When Reviewer or Debugger context is injected into a per-task redo prompt, the per-task workflow shall leave operator-visible evidence identifying the task ID and retry round.
2. When repeated reject fail-fast or warning behavior is triggered, the per-task workflow shall leave operator-visible evidence identifying the repeated category and target requirement.

## Out of Scope

- Reviewer の reject カテゴリ変更。
- Debugger のコード修正権限追加。
- per-task loop 全体の廃止。
- モデル変更や quota policy 変更。
- #23 の復旧作業そのものの再実行。
- 新しい外部サービス呼び出しや runtime dependency の追加。

## Open Questions

- なし。

## Issue コメント反映

- `gh issue view 37 --comments` により、既存コメントは Triage edit_paths と着手コメントのみで、人間の追加決定事項がないことを確認した。
- Triage edit_paths の自動コメントにより、編集見込み top-level path は `local-watcher/`、`.codex/`、`repo-template/` とする。

## PM Self Review

- Mechanical Checks: numeric requirement ID、全 requirement の EARS 形式 AC、Out of Scope、Open Questions を確認した。
- 判断レビュー: Issue 本文の受入基準、#23 の Req 5.2 / 5.3 再発形状、Reviewer / Debugger context 注入、Finding Closure Matrix、連続 reject の fail-fast または warning、root / repo-template byte-identical 規約を網羅し、実装方針・モジュール分割・API 設計に踏み込んでいないことを確認した。
