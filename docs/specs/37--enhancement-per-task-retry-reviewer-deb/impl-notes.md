# Implementation Notes

## Implementation Notes

### Task 1

- 採用方針: per-task retry 用の Reviewer / Debugger context 抽出を watcher helper と shell fixture に限定して追加した。
- 重要な判断:
  - `pt_extract_review_reject_context` は `review-notes.md` の `## Findings` から `Target` / `Category` / `Detail` / `Required Action` を parse し、欠落時は stdout を空にして診断付き return 1 に倒す。
  - `pt_extract_debugger_task_section` は `## Task <id>` セクション単位で抽出し、Debugger contract の h3 4 セクション欠落を診断する。
  - task 1 の境界に従い、Implementer prompt / loop 経路への接続は未実施。
- 残存課題: task 2 で `pt_build_redo_context_block` と `run_per_task_loop` の retry 経路へ接続する必要がある。
- 検証:
  - `shellcheck local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/test/per_task_redo_context_test.sh`
  - `bash local-watcher/test/per_task_redo_context_test.sh`
  - `bash local-watcher/test/parse_review_result_test.sh`
