# Implementation Plan

- [x] 1. Developer / Reviewer agent 定義に marker classification contract を同期追加する
  - `.codex/agents/developer.md` と `repo-template/.codex/agents/developer.md` に、canonical marker commit の subject が `docs(tasks): mark <id> as done` の単一 task ID 完全一致であることを byte-identical に追記する。
  - Developer guidance で、marker commit に含めてよい `tasks.md` 変更は対象 task checkbox の `[ ]` -> `[x]` のみであり、task 本文 / `_Requirements:_` / `_Boundary:_` / `_Depends:_` / 順序 / 無関係 checkbox は書き換え禁止であることを明記する。
  - `.codex/agents/reviewer.md` と `repo-template/.codex/agents/reviewer.md` に、per-task review range には marker commit が含まれ得ることを byte-identical に追記する。
  - Reviewer guidance で、正規 marker commit の対象 checkbox flip だけを allowed orchestration artifact と扱い、それだけを理由に `boundary 逸脱` reject しないことを明記する。
  - Reviewer guidance で、非 canonical subject、task 本文、`_Requirements:_`、`_Boundary:_`、`_Depends:_`、順序、無関係 checkbox、その他 spec artifact 更新は allowed artifact ではなく、既存 3 カテゴリ判定対象として維持することを明記する。
  - _Requirements:_ 1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 3.1, 3.3, 3.4, 3.5, 4.1
  - _Boundary:_ Developer Agent Guidance, Reviewer Agent Guidance, Agent Prompt Synchronization

- [x] 2. watcher の per-task Implementer / Reviewer prompt に同じ marker contract を注入する
  - `local-watcher/bin/idd-codex-issue-watcher.sh` の `build_per_task_implementer_prompt` で、canonical marker commit が Reviewer の allowed orchestration artifact 分類と同じ subject / checkbox-only 契約に従うことを明記する。
  - `build_per_task_reviewer_prompt` で、`range_end_sha` が marker commit であり得ることと、Reviewer が `git log -1 --format=%s <range_end_sha>` で subject を確認することを明記する。
  - `build_per_task_reviewer_prompt` で、subject が `docs(tasks): mark ${task_id} as done` に完全一致し、marker commit の `tasks.md` diff が対象 checkbox `[ ]` -> `[x]` のみである場合だけ allowed orchestration artifact と扱うことを明記する。
  - `build_per_task_reviewer_prompt` で、task 本文 / `_Requirements:_` / `_Boundary:_` / `_Depends:_` / 順序 / 無関係 checkbox / marker commit 以外の spec artifact 更新は reject 候補として維持することを明記する。
  - `pt_resolve_diff_range` の既存互換アルゴリズム、Reviewer 3 カテゴリ、env var、label、exit code は変更しない。
  - _Requirements:_ 1.1, 1.2, 1.3, 1.4, 3.1, 3.2, 3.3, 3.4, 3.5
  - _Boundary:_ Per-task Implementer Prompt, Per-task Reviewer Prompt, Diff Range Resolver
  - _Depends:_ 1

- [ ] 3. regression-test-only commit + marker commit の shell fixture を追加する
  - `local-watcher/test/per_task_marker_checkbox_contract_test.sh` を追加し、既存 `local-watcher/test/` pattern に合わせて watcher から必要関数だけを `awk` 抽出して eval する。
  - temporary git repo で base commit、regression-test-only commit、正規 `docs(tasks): mark 1.1 as done` marker commit を作成する。
  - `pt_resolve_diff_range 1.1` が regression-test-only commit と marker commit を含む range を返し、`range_end_sha` が marker commit であることを検証する。
  - marker commit の `tasks.md` 差分が対象 task checkbox の `[ ]` -> `[x]` のみであることを検証する。
  - `build_per_task_implementer_prompt` と `build_per_task_reviewer_prompt` の出力に、canonical subject、target checkbox-only allowed artifact、非 canonical / non-marker `tasks.md` 変更の reject-eligible 契約が含まれることを検証する。
  - 実 LLM の approve / reject を shell test で実行しない理由と、prompt-only assertion で代替した範囲を `impl-notes.md` に記録する。
  - _Requirements:_ 1.1, 1.2, 1.3, 1.4, 3.1, 3.2, 3.3, 3.4, 3.5, 5.1, 5.2, 5.3, 5.4
  - _Boundary:_ Marker Classification Regression Test, Per-task Implementer Prompt, Per-task Reviewer Prompt, Diff Range Resolver
  - _Depends:_ 2

- [ ] 4. 静的検証と root / repo-template 同期を確認する
  - `shellcheck local-watcher/bin/*.sh install.sh setup.sh .github/scripts/*.sh` を実行し、既存 shell scripts と watcher の警告が増えていないことを確認する。
  - `shellcheck local-watcher/test/per_task_marker_checkbox_contract_test.sh` を実行する。
  - `bash local-watcher/test/per_task_marker_checkbox_contract_test.sh` を実行する。
  - `diff -r .codex/agents repo-template/.codex/agents` が空であることを確認する。
  - `diff -r .codex/rules repo-template/.codex/rules` が空であることを確認する。
  - 実行結果と、prompt-only assertion に留めた箇所の理由を `impl-notes.md` に記録する。
  - _Requirements:_ 4.1, 4.2, 4.3, 4.4, 5.1, 5.2, 5.3, 5.4
  - _Boundary:_ Marker Classification Regression Test, Agent Prompt Synchronization, Rule Sync Verification
  - _Depends:_ 1, 2, 3

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを以下に宣言する。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/*.sh install.sh setup.sh .github/scripts/*.sh &&
shellcheck local-watcher/test/per_task_marker_checkbox_contract_test.sh &&
bash local-watcher/test/per_task_marker_checkbox_contract_test.sh &&
diff -r .codex/agents repo-template/.codex/agents &&
diff -r .codex/rules repo-template/.codex/rules
```
