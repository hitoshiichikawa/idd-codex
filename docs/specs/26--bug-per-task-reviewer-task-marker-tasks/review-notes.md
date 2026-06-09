# Review Notes

<!-- idd-codex:review round=1 model=gpt-5.5 timestamp=2026-06-09T12:12:04Z -->

## Reviewed Scope

- Branch: codex/issue-26-impl--bug-per-task-reviewer-task-marker-tasks
- HEAD commit: 55e6b8fe322e9b2e5be14551b37e8e3f4af552ad
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `local-watcher/bin/idd-codex-issue-watcher.sh:3108` で canonical marker checkbox diff を allowed orchestration artifact として分類する prompt 契約を追加。fixture は `local-watcher/test/per_task_marker_checkbox_contract_test.sh:166` 以降で regression-test-only commit + marker commit range を検証。
- 1.2 — `local-watcher/bin/idd-codex-issue-watcher.sh:3108` および `.codex/agents/reviewer.md:315` で canonical marker checkbox update だけを理由に `boundary 逸脱` reject しないことを明記。
- 1.3 — `.codex/agents/reviewer.md:315` と `local-watcher/bin/idd-codex-issue-watcher.sh:3121` で canonical marker 以外の変更を既存 3 カテゴリ判定対象として維持。
- 1.4 — `.codex/agents/reviewer.md:309` と `local-watcher/bin/idd-codex-issue-watcher.sh:3124` で subject 完全一致しない marker を allowed artifact にしない契約を明記。
- 2.1 — `.codex/agents/reviewer.md:317` と `local-watcher/bin/idd-codex-issue-watcher.sh:3126` で task 本文変更を reject 候補として維持。
- 2.2 — `.codex/agents/reviewer.md:317` と `local-watcher/bin/idd-codex-issue-watcher.sh:3126` で `_Requirements:_` 変更を reject 候補として維持。
- 2.3 — `.codex/agents/reviewer.md:317` と `local-watcher/bin/idd-codex-issue-watcher.sh:3126` で `_Boundary:_` 変更を reject 候補として維持。
- 2.4 — `.codex/agents/reviewer.md:317` と `local-watcher/bin/idd-codex-issue-watcher.sh:3126` で `_Depends:_` 変更を reject 候補として維持。
- 2.5 — `.codex/agents/reviewer.md:317` と `local-watcher/bin/idd-codex-issue-watcher.sh:3126` で task 順序変更を reject 候補として維持。
- 2.6 — `.codex/agents/reviewer.md:318` と `local-watcher/bin/idd-codex-issue-watcher.sh:3127` で review 対象外 checkbox 変更を reject 候補として維持。
- 2.7 — `.codex/agents/reviewer.md:318` と `local-watcher/bin/idd-codex-issue-watcher.sh:3125` で canonical marker checkbox update 以外の spec artifact 更新を reject 候補として維持。
- 3.1 — `.codex/agents/developer.md:405` と `local-watcher/bin/idd-codex-issue-watcher.sh:2972` で Implementer 側の marker subject / checkbox-only 契約を明記。
- 3.2 — `local-watcher/bin/idd-codex-issue-watcher.sh:3071` および `local-watcher/bin/idd-codex-issue-watcher.sh:3095` で range end が marker commit であり得ることと subject 確認手順を明記。
- 3.3 — `local-watcher/bin/idd-codex-issue-watcher.sh:3108` で対象 checkbox update だけを allowed artifact とする Reviewer prompt 契約を追加。
- 3.4 — `local-watcher/bin/idd-codex-issue-watcher.sh:3121` で task 本文、annotation、順序、無関係 checkbox、その他 spec artifact 更新を allowed artifact から除外。
- 3.5 — `.codex/agents/developer.md:405`、`.codex/agents/reviewer.md:309`、`local-watcher/bin/idd-codex-issue-watcher.sh:2974`、`local-watcher/bin/idd-codex-issue-watcher.sh:3112` で同じ marker subject / checkbox-only 契約を共有。
- 4.1 — `diff -r .codex/agents repo-template/.codex/agents` を実行し差分なし。agent ファイル差分も root / repo-template で byte-identical。
- 4.2 — `diff -r .codex/rules repo-template/.codex/rules` を実行し差分なし。rule ファイル変更はなし。
- 4.3 — `docs/specs/26--bug-per-task-reviewer-task-marker-tasks/tasks.md:53` の verify block に agents diff が含まれ、Reviewer 側でも実行済み。
- 4.4 — `docs/specs/26--bug-per-task-reviewer-task-marker-tasks/tasks.md:54` の verify block に rules diff が含まれ、Reviewer 側でも実行済み。
- 5.1 — `local-watcher/test/per_task_marker_checkbox_contract_test.sh:166` で regression-test-only commit と canonical marker commit を含む range 解決を検証。
- 5.2 — `local-watcher/test/per_task_marker_checkbox_contract_test.sh:174` で marker commit が対象 task checkbox `[ ]` から `[x]` への変更のみであることを検証。
- 5.3 — `local-watcher/test/per_task_marker_checkbox_contract_test.sh:195` 以降で canonical subject、allowed artifact、非 canonical / non-marker `tasks.md` 変更の reject-eligible 契約を prompt assertion で検証。
- 5.4 — `docs/specs/26--bug-per-task-reviewer-task-marker-tasks/impl-notes.md:22` と `docs/specs/26--bug-per-task-reviewer-task-marker-tasks/impl-notes.md:30` で実 LLM 判定を shell test で決定的に検証できない理由と prompt-only assertion の代替範囲を記録。
- NFR 1.1 — Reviewer prompt / agent guidance は既存 3 カテゴリを維持し、追加カテゴリは作っていない。
- NFR 1.2 — `PER_TASK_LOOP_ENABLED` 外の single Developer / single Reviewer workflow には差分なし。
- NFR 1.3 — env var、label、cron invocation、branch naming、exit code の契約変更は差分に含まれていない。
- NFR 1.4 — 新しい外部サービスや runtime dependency は追加されていない。fixture は既存依存の bash / awk / git / grep のみ。
- NFR 2.1 — `local-watcher/bin/idd-codex-issue-watcher.sh:3118` で allowed marker classification を review-notes の Summary / Verified Requirements に残すよう指示。
- NFR 2.2 — `local-watcher/bin/idd-codex-issue-watcher.sh:3121` 以降で marker があっても reject 対象になる非 marker `tasks.md` 変更を列挙。

## Findings

なし

## Summary

AC 未カバー、missing test、boundary 逸脱はいずれも検出しませんでした。Reviewer 側でも `shellcheck`、追加 fixture、agents / rules の同期 diff を再実行し、すべて成功しています。

RESULT: approve
