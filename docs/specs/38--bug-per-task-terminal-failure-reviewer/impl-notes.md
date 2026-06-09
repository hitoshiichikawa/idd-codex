# Implementation Notes

## Summary

- per-task terminal failure 用の診断保全ヘルパーを `local-watcher/bin/idd-codex-issue-watcher.sh` に追加した。
- `mark_issue_failed` の `per-task-*` stage と `pt_mark_diff_range_resolve_failed` に `Terminal failure diagnostics` を追加し、`review-notes.md` / `debugger-notes.md` の状態と push-state を Issue コメントへ出すようにした。
- Reviewer / Debugger artifact が untracked / uncommitted の場合、watcher が diagnostic commit を作成して `git push origin <branch>` を 1 回試みる。commit / push に失敗した場合は Issue コメントに artifact content fallback を出す。
- artifact が commit 済みだが未 push の場合も、terminal failure diagnostics 内で branch push を 1 回試み、remote branch に復旧起点を残す。
- README の failure recovery / Reviewer Gate / per-task loop 説明に terminal failure diagnostics の見方を追記した。

## Requirement Trace

- Req 1 / 2: `review-notes.md` / `debugger-notes.md` を diagnostic commit または Issue コメント fallback で保全する。
- Req 3: current branch、local HEAD SHA、origin branch HEAD SHA または理由、ahead count または理由、worktree path、artifact tracked state を診断ブロックに出す。
- Req 4: Reviewer / Debugger の `git add` / `git commit` / `git push` / `gh` 禁止は変更せず、保全は watcher 側で実施する。
- Req 5: `per-task-*` の `mark_issue_failed` 経路と `pt_mark_diff_range_resolve_failed` 専用経路の両方へ診断を追加した。
- Req 6: fake origin / fake gh の shell-level fixture を追加し、`per-task-reviewer-reject3`、untracked `review-notes.md` / `debugger-notes.md`、commit 済み未 push artifact、diagnostic commit 成功、commit 失敗 fallback、push-state fields を検証した。

## Verification

- `bash local-watcher/test/per_task_terminal_failure_diagnostics_test.sh` PASS
- `bash local-watcher/test/verify_pushed_or_retry_test.sh` PASS
- `shellcheck local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/test/per_task_terminal_failure_diagnostics_test.sh local-watcher/test/verify_pushed_or_retry_test.sh` PASS

## Notes

- 新しい env var、label、外部サービス、runtime dependency は追加していない。
- `git reset` / `git rebase` / force push は追加していない。
- 未決事項なし。

## Reviewer round=1 reject 是正

- `run_debugger_stage` が `task_id` 付きで `debugger-failed` / `debugger-notes-invalid` に遷移する場合も、failure comment 生成前に `pt_build_terminal_failure_diagnostics` を実行するよう修正した。
- Issue comment の失敗 stage は既存契約どおり `debugger-failed` / `debugger-notes-invalid` のまま維持し、診断ブロック内の stage は `per-task-debugger-failed` / `per-task-debugger-notes-invalid` として per-task terminal failure であることを識別できるようにした。
- `local-watcher/test/per_task_terminal_failure_diagnostics_test.sh` に `run_debugger_stage "round2-reject" "1.2"` の codex 非 0 経路と `run_debugger_stage "blocked" "1.2"` の invalid `debugger-notes.md` 経路を追加し、diagnostic block、artifact state、diagnostic commit push を Issue comment と fake origin で検証した。
