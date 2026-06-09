# Impl Notes

## Implementation Notes

### Task 1

- 採用方針: agent 定義の per-task 節へ marker commit の作成契約と分類契約を追記し、root と repo-template を同一内容に同期した。
- 重要な判断: watcher prompt への注入と shell fixture は task 2/3 の境界であるため、本 task では永続 agent guidance のみ更新した。
- 重要な判断: allowed artifact は canonical subject、`tasks.md` only、対象 checkbox `[ ]` -> `[x]` の 3 条件に限定し、その他 spec artifact 更新は既存 3 カテゴリ判定対象として維持した。
- 残存課題: task 2 で watcher の per-task Implementer / Reviewer prompt に同じ契約を注入する必要がある。
