# Review Notes

<!-- idd-codex:review round=1 model=gpt-5.5 timestamp=2026-06-08T23:03:49Z -->

## Reviewed Scope

- Branch: codex/issue-21-impl--bug-architect-task-per-task-review
- HEAD commit: 7780cd34f247067ab840612a3b577305d4ad9521
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `.codex/rules/tasks-generation.md:62` と `.codex/agents/architect.md:231` で Task Boundary Contract を追加し、各 task の `_Requirements:_` がその task 完了時点で実装・テスト・レビュー可能な AC だけを表すことを明示している。
- 1.2 — `.codex/agents/developer.md:43` で Task Boundary Contract の実装責務を追加し、対象 task の `_Requirements:_` に含まれる AC の必要 test は同 task 作業と明示している。
- 1.3 — `.codex/agents/reviewer.md:307` で per-task review の判定対象 AC と `missing test` 判定対象を当該 task の `_Requirements:_` のみに限定している。
- 1.4 — `.codex/rules/tasks-generation.md:62` を正準 contract とし、`.codex/agents/architect.md:233`、`.codex/agents/developer.md:45`、`.codex/agents/reviewer.md:317` から同じ contract に接続している。
- 2.1 — `.codex/rules/tasks-generation.md:69` と `.codex/agents/architect.md:237` で regression coverage AC を含む task に同 task の regression test work を明記させ、`contract-driver.sh:289` で same-task fixture を検証している。
- 2.2 — `.codex/rules/tasks-generation.md:69` と `.codex/agents/architect.md:237` で failure path AC を含む task に同 task の failure path test work を明記させ、`contract-driver.sh:289` で same-task fixture を検証している。
- 2.3 — `.codex/rules/tasks-generation.md:69` と `.codex/agents/architect.md:237` で safety fallback AC を含む task に同 task の safety fallback test work を明記させ、`contract-driver.sh:289` で same-task fixture を検証している。
- 2.4 — `.codex/rules/tasks-generation.md:72` と `.codex/agents/architect.md:239` で runtime behavior change task に最低限の regression test または shell-level test を含めるよう明示している。
- 2.5 — `.codex/rules/tasks-generation.md:74`、`.codex/agents/architect.md:241`、`contract-driver.sh:297` で、test work を後続 task に defer する場合は先行 task の `_Requirements:_` から coverage AC を外す契約と invalid fixture 検出を固定している。
- 3.1 — `.codex/rules/tasks-generation.md:74` と `contract-driver.sh:293` で deferred test の先行 task が未実施 coverage AC を `_Requirements:_` に含めない valid case を検証している。
- 3.2 — `.codex/rules/tasks-generation.md:76` と `.codex/agents/architect.md:243` で partial な先行 task と coverage task の関係を `_Boundary:_` または `_Depends:_` で明示させている。
- 3.3 — `.codex/agents/architect.md:245` で dedicated regression test task の `_Requirements:_` を後続 task 完了時点で検証する AC に限定している。
- 3.4 — `.codex/agents/reviewer.md:312` で後続 deferred test task の未実施を、当該 task の `_Requirements:_` に含まれない限り `missing test` として reject しない契約にしている。
- 3.5 — `.codex/rules/tasks-generation.md:79`、`.codex/agents/developer.md:51`、`README.md:4569` で `- [ ]*` を既存 optional / deferrable 規約として維持している。
- 4.1 — `contract-driver.sh:257` の `diff -r` と実行結果で root `.codex/agents/` と `repo-template/.codex/agents/` の byte-identical sync を検証している。
- 4.2 — `contract-driver.sh:258` の `diff -r` と実行結果で root `.codex/rules/` と `repo-template/.codex/rules/` の byte-identical sync を検証している。
- 4.3 — `docs/specs/21--bug-architect-task-per-task-review/tasks.md:48` と `contract-driver.sh:257` に agent files の `diff -r .codex/agents repo-template/.codex/agents` 検証が含まれている。
- 4.4 — `docs/specs/21--bug-architect-task-per-task-review/tasks.md:50` と `contract-driver.sh:258` に rule files の `diff -r .codex/rules repo-template/.codex/rules` 検証が含まれている。
- 4.5 — `README.md:3340`、`README.md:4524`、`README.md:4569` で per-task review semantics、same-task test work、deferred task 表記を agent prompt / shared rule と同じ意味で説明している。
- 5.1 — `tests/local-watcher/task-boundary-contract/fixtures/tasks-same-task-coverage.md:5` と `contract-driver.sh:116` / `contract-driver.sh:289` で、coverage AC を持つ task が same-task test work guidance を含むことを検証している。
- 5.2 — `tests/local-watcher/task-boundary-contract/fixtures/tasks-deferred-coverage.md:3` と `contract-driver.sh:127` / `contract-driver.sh:293` で、deferred regression test guidance が先行 task に deferred coverage AC を要求しないことを検証している。
- 5.3 — `contract-driver.sh:257` と `contract-driver.sh:258` で root / repo-template agent / rule files の drift を regression として検出している。
- 5.4 — `contract-driver.sh:260` 以降の prompt / rule / README key phrase assertions と `impl-notes.md:25` で、prompt-only assertion は shell-level driver で検証済みで未自動化項目なしと記録している。

## Findings

なし

## Summary

AC 1.1 から 5.4 まで、shared rule、Architect / Developer / Reviewer prompt、README、fixture driver、root / repo-template sync verification でカバーされている。差分は tasks.md の `_Boundary:_` に記載された範囲内で、既存実装コードや dispatcher の実行時挙動変更は含まれていない。

Verification: `shellcheck tests/local-watcher/task-boundary-contract/contract-driver.sh && diff -r .codex/agents repo-template/.codex/agents && diff -r .codex/rules repo-template/.codex/rules && bash tests/local-watcher/task-boundary-contract/contract-driver.sh` は成功した。

RESULT: approve
