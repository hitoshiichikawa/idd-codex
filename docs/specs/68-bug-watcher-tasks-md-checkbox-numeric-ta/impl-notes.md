# Issue #68 実装ノート

## 実装概要

- per-task の task marker 判定を、親 task は `- [ ] N. <title>` / `- [x] N. <title>`、子 task は `- [ ] N.M[.K...] <title>` / `- [x] N.M[.K...] <title>` のみ認識するように厳密化した。
- `pt_extract_pending_tasks` と `pt_check_task_completed` の task ID 解釈を同じ契約に揃え、`- [ ] 1 PR ...` のような通常 checkbox を task `1` と扱わないようにした。
- `tasks.md` が存在するにもかかわらず watcher-compatible numeric checkbox task marker が 0 件の場合、per-task startup で `per-task-no-compatible-tasks` として停止し、修正すべき marker 契約と対象 `tasks.md` を診断に出すようにした。
- impl-resume の checkpoint 判定でも marker 0 件の `tasks.md` を Stage B へ silent skip せず、Stage A に戻して per-task startup の診断 failure へ到達させるようにした。
- tasks 生成・レビュー規約の checkbox 判定を、親 `N.` / 子 `N.M[.K...]` の watcher-compatible marker 契約に更新した。

## 変更ファイル

- `local-watcher/bin/idd-codex-issue-watcher.sh`
- `local-watcher/test/per_task_task_marker_parsing_test.sh`
- `.codex/rules/tasks-generation.md`
- `.codex/rules/design-review-gate.md`
- `repo-template/.codex/rules/tasks-generation.md`
- `repo-template/.codex/rules/design-review-gate.md`
- `docs/specs/68-bug-watcher-tasks-md-checkbox-numeric-ta/impl-notes.md`

## テスト結果

- `bash local-watcher/test/per_task_task_marker_parsing_test.sh` 成功
- `bash local-watcher/test/stage_checkpoint_pending_tasks_test.sh` 成功
- `bash local-watcher/test/context_map_prompt_test.sh` 成功
- `shellcheck --severity=warning local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/test/per_task_task_marker_parsing_test.sh` 成功
- `diff -r .codex/rules repo-template/.codex/rules` 成功
- `git diff --check` 成功

## 確認事項

- なし。

## Reviewer reject 是正

- `local-watcher/test/stage_checkpoint_pending_tasks_test.sh` に impl-resume checkpoint の直接 regression を追加した。
- heading-only / prose checkbox のみで watcher-compatible marker が 0 件の `tasks.md` fixture を使い、`stage_checkpoint_resolve_resume_point` が `START_STAGE=A` を選ぶことを確認した。
- 同 fixture で `reason=tasks-md-no-compatible-task-markers` が記録され、Stage B silent skip 側へ進まないことを固定した。
