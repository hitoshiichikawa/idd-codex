# Implementation Plan

- [ ] 1. Reviewer / Debugger redo context 抽出 helper を watcher に追加する
  - `local-watcher/bin/idd-codex-issue-watcher.sh` に `pt_extract_review_reject_context` を追加し、`review-notes.md` の `## Findings` から `Target` / `Category` / `Detail` / `Required Action` を抽出する。
  - `pt_extract_review_reject_context` は task ID、Reviewer round、category、target requirement を prompt に残せる markdown fragment を返す。
  - 抽出不能時は return 1 とし、task ID、round、notes path、reason を含む diagnostic を呼び出し側がログ / prompt に残せるようにする。
  - `pt_extract_debugger_task_section` を追加し、`debugger-notes.md` の `## Task <task_id>` から次 task section または EOF までを抽出する。
  - Debugger section に `### 根本原因` / `### 修正手順` / `### 検証方法` / `### 関連参考資料` が欠ける場合は diagnostic を返す。
  - helper 単体の shell fixture を `local-watcher/test/per_task_redo_context_test.sh` に追加する。
  - _Requirements:_ 1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 2.3, 2.4, 5.1, 5.2

- [ ] 2. per-task Implementer prompt と loop redo 経路に context を注入する
  - `pt_build_redo_context_block` を追加し、Reviewer 由来 block と Debugger 由来 block を別見出しで組み立てる。
  - `build_per_task_implementer_prompt <task_id> [redo_context_block]` に拡張し、第 2 引数が空の通常実行では既存 prompt と learnings 注入を維持する。
  - `run_per_task_implementer <task_id> [redo_context_block]` に拡張し、既存呼び出しはそのまま動くよう任意引数にする。
  - `run_per_task_loop` の round 1 reject 後の再実行で Reviewer Findings / Required Action context を渡す。
  - `run_per_task_loop` の round 2 reject + Debugger 後の再実行で Reviewer context と Debugger `## Task <id>` context の両方を渡す。
  - redo context 注入時は `pt_log` に task ID、redo kind、Reviewer round を残す。
  - `per_task_redo_context_test.sh` で round 1 redo prompt と Debugger 後 redo prompt の prompt-only assertion を追加する。
  - _Requirements:_ 1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 2.3, 2.4, 5.1, 5.2, 5.6
  - _Depends:_ 1

- [ ] 3. Finding Closure Matrix contract を watcher prompt と Developer agent に同期追加する
  - `build_per_task_implementer_prompt` の redo context block に Finding Closure Matrix の必須列を追加する。
  - Matrix の列は `Target requirement`、`Category`、`Required Action`、`Fix commit`、`Test/assertion`、`Verification result`、`Notes / no-change reason` とする。
  - `.codex/agents/developer.md` の per-task 節に、Reviewer reject 後 / Debugger guidance 後は `impl-notes.md` の Finding Closure Matrix を作成または更新する責務を追記する。
  - `repo-template/.codex/agents/developer.md` に同一内容を反映し、root と repo-template の agents を byte-identical に保つ。
  - `per_task_redo_context_test.sh` で matrix schema と rejected target / fix commit / test/assertion / verification result の文言が prompt に含まれることを検証する。
  - prompt-only assertion に留める理由と手動確認範囲を `impl-notes.md` に記録する実装メモを残す。
  - _Requirements:_ 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 5.3, 5.4, 5.6
  - _Depends:_ 2

- [ ] 4. 連続 reject の warning-only guard を追加する
  - `pt_collect_reject_fingerprints` を追加し、`review-notes.md` から `category + target` fingerprint を抽出する。
  - `pt_collect_changed_test_paths <from_sha> <to_sha>` を追加し、前回 reject 直後から次 Reviewer 起動前までの test path 差分を収集する。
  - test path heuristic は `local-watcher/test/*`、`tests/*`、`*/test/*`、`*_test.sh`、`*test*.sh` を対象にし、新 dependency は追加しない。
  - `pt_build_repeated_reject_warning` を追加し、task ID、category、target requirement、未検出だった関連 test 差分を operator-visible な 1 行ログと prompt warning block に残す。
  - round 2 Reviewer 起動前は、round 1 reject target に対して test 差分が無い risk warning を出す。
  - round 3 Reviewer 起動前は、round 1 / round 2 の同一 fingerprint overlap と test 差分なしを確認し、連続 reject warning を出す。
  - `local-watcher/test/per_task_repeated_reject_guard_test.sh` を追加し、test 差分なしで warning が出るケースと、test 差分ありで warning が出ないケースを検証する。
  - _Requirements:_ 4.1, 4.2, 4.4
  - _Depends:_ 1, 2

- [ ] 5. per-task retry context の #23 shape 回帰 fixture を完成させる
  - `per_task_redo_context_test.sh` で Req 5.2 / 5.3 の `missing test` が round 1 / round 2 に残る review-notes fixture を作る。
  - round 1 reject 後の redo prompt に actionable Reviewer context が含まれることを検証する。
  - round 2 reject 後の Debugger fixture に `## Task <id>` と h3 4 セクションを作り、Debugger context が redo prompt に含まれることを検証する。
  - Finding Closure Matrix の prompt contract が rejected target requirement、fix commit、test/assertion、verification result の対応を要求していることを検証する。
  - 実 LLM に `impl-notes.md` を生成させる assertion は shell fixture では実行せず、prompt-only assertion と実装メモで代替する。
  - _Requirements:_ 5.1, 5.2, 5.3, 5.6
  - _Depends:_ 1, 2, 3

- [ ] 6. 静的検証と root / repo-template 同期を確認する
  - `shellcheck local-watcher/bin/*.sh install.sh setup.sh .github/scripts/*.sh` を実行し、watcher 変更で警告が増えていないことを確認する。
  - `shellcheck local-watcher/test/per_task_redo_context_test.sh local-watcher/test/per_task_repeated_reject_guard_test.sh` を実行する。
  - `bash local-watcher/test/per_task_redo_context_test.sh` を実行する。
  - `bash local-watcher/test/per_task_repeated_reject_guard_test.sh` を実行する。
  - 既存 #23 range fixture として `bash local-watcher/test/per_task_marker_review_range_test.sh` を実行する。
  - `diff -r .codex/agents repo-template/.codex/agents` が空であることを確認する。
  - `diff -r .codex/rules repo-template/.codex/rules` が空であることを確認する。
  - 実行結果と prompt-only assertion に留めた箇所の理由を `impl-notes.md` に記録する。
  - _Requirements:_ 5.1, 5.2, 5.3, 5.4, 5.5, 5.6
  - _Depends:_ 1, 2, 3, 4, 5

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを以下に宣言する。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/*.sh install.sh setup.sh .github/scripts/*.sh &&
shellcheck local-watcher/test/per_task_redo_context_test.sh local-watcher/test/per_task_repeated_reject_guard_test.sh &&
bash local-watcher/test/per_task_redo_context_test.sh &&
bash local-watcher/test/per_task_repeated_reject_guard_test.sh &&
bash local-watcher/test/per_task_marker_review_range_test.sh &&
diff -r .codex/agents repo-template/.codex/agents &&
diff -r .codex/rules repo-template/.codex/rules
```
