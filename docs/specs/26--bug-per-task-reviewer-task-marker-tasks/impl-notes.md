# Impl Notes

## Implementation Notes

### Task 1

- 採用方針: agent 定義の per-task 節へ marker commit の作成契約と分類契約を追記し、root と repo-template を同一内容に同期した。
- 重要な判断: watcher prompt への注入と shell fixture は task 2/3 の境界であるため、本 task では永続 agent guidance のみ更新した。
- 重要な判断: allowed artifact は canonical subject、`tasks.md` only、対象 checkbox `[ ]` -> `[x]` の 3 条件に限定し、その他 spec artifact 更新は既存 3 カテゴリ判定対象として維持した。
- 残存課題: task 2 で watcher の per-task Implementer / Reviewer prompt に同じ契約を注入する必要がある。

### Task 2

- 採用方針: watcher の per-task Implementer / Reviewer prompt に、agent 定義と同じ marker commit 分類契約を注入した。
- 重要な判断: allowed artifact は `range_end_sha` の subject 完全一致、`tasks.md` only、対象 checkbox `[ ]` -> `[x]` の 3 条件に限定し、Reviewer prompt で `git log -1 --format=%s` による subject 確認を明示した。
- 重要な判断: task 本文、`_Requirements:_`、`_Boundary:_`、`_Depends:_`、順序、無関係 checkbox、marker commit 以外の spec artifact 更新は引き続き `boundary 逸脱` 候補として列挙した。
- 残存課題: task 3 で regression-test-only commit と marker commit を含む shell fixture により prompt 文言と diff range を固定する必要がある。

### Task 3

- 採用方針: temporary git repo で regression-test-only commit と canonical marker commit を作成し、range 解決・marker 差分・prompt 文言を shell fixture で固定した。
- 重要な判断: 実 LLM の approve / reject は shell test で決定的に検証できないため、Reviewer prompt が canonical checkbox update を allowed orchestration artifact とし、非 canonical / non-marker `tasks.md` 変更を reject 候補として列挙することを prompt-only assertion で代替した。
- 重要な判断: marker commit の差分は `git diff-tree` と `git diff` で `tasks.md` only かつ対象 task checkbox `[ ]` -> `[x]` のみに限定されることを検証した。
- 残存課題: task 4 で shellcheck / fixture 実行 / root・repo-template diff の統合 verify を実施する必要がある。

### Task 4

- 採用方針: task 3 で追加された fixture と root / repo-template 同期を統合 verify で確認し、検証結果を実装ノートに記録した。
- 重要な判断: `shellcheck`、fixture 実行、agent / rules の `diff -r` はすべて成功し、marker checkbox contract の回帰検証と同期状態に差分はなかった。
- 重要な判断: 実 LLM の `boundary 逸脱` approve / reject 判定は shell test で決定的に再現できないため、Reviewer prompt の allowed artifact / reject-eligible 文言 assertion を自動検証範囲として維持した。
- 残存課題: なし。
