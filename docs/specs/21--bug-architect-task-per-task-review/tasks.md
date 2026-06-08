# Implementation Plan

- [x] 1. Shared rule と Architect prompt に task-boundary contract を追加する
  - `.codex/rules/tasks-generation.md` と `repo-template/.codex/rules/tasks-generation.md` に `Task Boundary Contract` 節を byte-identical で追加する。
  - `_Requirements:_` がその task 完了時点で実装・テスト・レビュー可能な AC のみを表すことを明記する。
  - regression coverage / failure path / safety fallback / runtime behavior change の AC を含む task には、同 task の詳細項目に対応 test work を明記するよう規定する。
  - test work を後続 task に defer する場合は、先行 task の `_Requirements:_` から未実施 coverage AC を外し、coverage task 側に `_Depends:_` と partial boundary を明記するよう規定する。
  - `.codex/agents/architect.md` と `repo-template/.codex/agents/architect.md` に同 contract への参照と tasks 生成時の自己チェック観点を byte-identical で追加する。
  - `tests/local-watcher/task-boundary-contract/contract-driver.sh` と valid / invalid fixture の初版を同 task で追加し、same-task coverage と deferred coverage の境界を検証する。
  - _Requirements:_ 1.1, 1.4, 2.1, 2.2, 2.3, 2.4, 2.5, 3.1, 3.2, 3.3, 3.5, 4.1, 4.2, 5.1, 5.2, 5.4
  - _Boundary:_ Shared Task Rule, Architect Guidance, Task Boundary Fixture Driver

- [x] 2. Developer / Reviewer prompt を同じ contract に接続する
  - `.codex/agents/developer.md` と `repo-template/.codex/agents/developer.md` に、対象 task の `_Requirements:_` に含まれる AC の必要 test は同 task 作業として扱うことを byte-identical で追加する。
  - Developer guidance で、`- [ ]*` または後続 task に defer された coverage AC を対象 task の完了条件へ混ぜないことを明記する。
  - `.codex/agents/reviewer.md` と `repo-template/.codex/agents/reviewer.md` に、per-task review の `missing test` 判定対象は当該 task の `_Requirements:_` のみであることを byte-identical で追加する。
  - Reviewer guidance で、範囲外 AC や後続 deferred test task の未実施を reject 理由にしない一方、`_Boundary:_` 違反は既存どおり reject することを明記する。
  - `contract-driver.sh` に Developer / Reviewer prompt の key phrase assertion を同 task で追加する。
  - _Requirements:_ 1.2, 1.3, 1.4, 3.4, 3.5, 4.1, 5.4
  - _Boundary:_ Developer Guidance, Reviewer Guidance, Task Boundary Fixture Driver
  - _Depends:_ 1

- [x] 3. README に per-task review semantics を追記する
  - `Reviewer Gate (#20 Phase 1)` の判定カテゴリ説明に、per-task review では `missing test` の scope が当該 task の `_Requirements:_` に限定されることを追記する。
  - `Per-task TDD Implementation Loop (#21)` の新挙動説明に、coverage / failure / safety AC は同 task test work と結び付けること、defer 時は先行 task の `_Requirements:_` から未実施 coverage AC を外すことを追記する。
  - `- [ ]*` は既存 optional / deferrable 規約として維持され、deferred test task の表記として使えることを既存説明と矛盾しない形で補足する。
  - `contract-driver.sh` に README key phrase assertion を同 task で追加する。
  - _Requirements:_ 4.5, 5.4
  - _Boundary:_ README Contract Documentation, Task Boundary Fixture Driver
  - _Depends:_ 1, 2

- [ ] 4. Regression fixture coverage と sync verification を完成させる
  - `tests/local-watcher/task-boundary-contract/fixtures/tasks-same-task-coverage.md` で、coverage AC を持つ task が同 task detail に regression / failure / safety test work を含む valid case を固定する。
  - `tests/local-watcher/task-boundary-contract/fixtures/tasks-deferred-coverage.md` で、先行 partial task が deferred coverage AC を `_Requirements:_` に含めず、後続 coverage task が `_Depends:_` で依存する valid case を固定する。
  - `tests/local-watcher/task-boundary-contract/fixtures/tasks-invalid-deferred-ac.md` で、先行 task が coverage AC を含むのに test work を後続へ defer する invalid case を検出する。
  - driver 内で `diff -r .codex/agents repo-template/.codex/agents` と `diff -r .codex/rules repo-template/.codex/rules` を実行し、root / repo-template drift を regression として検出する。
  - prompt-only assertion のうち shell-level で検証しないものが残る場合は、理由と手動確認内容を `impl-notes.md` に記録する。
  - _Requirements:_ 4.1, 4.2, 4.3, 4.4, 5.1, 5.2, 5.3, 5.4
  - _Boundary:_ Task Boundary Fixture Driver, Agent Prompt Synchronization
  - _Depends:_ 1, 2, 3

## Verify

本 spec の実装後、watcher が再実行すべき verify コマンドを以下の構造化ブロックで宣言する。

<!-- stage-a-verify -->
```sh
shellcheck tests/local-watcher/task-boundary-contract/contract-driver.sh &&
  diff -r .codex/agents repo-template/.codex/agents &&
  diff -r .codex/rules repo-template/.codex/rules &&
  bash tests/local-watcher/task-boundary-contract/contract-driver.sh
```
