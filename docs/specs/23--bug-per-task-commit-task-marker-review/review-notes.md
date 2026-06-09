# Review Notes

<!-- idd-codex:review round=1 model=gpt-5.5 timestamp=2026-06-09T14:00:23Z -->

## Reviewed Scope

- Branch: codex/issue-23-impl--bug-per-task-commit-task-marker-review
- HEAD commit: f2a47edaf70b6d33a36b368beb3e0d4e04dbdc5c
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `build_per_task_implementer_prompt` と `.codex/agents/developer.md` / `repo-template/.codex/agents/developer.md` が、実装・検証・learning 後に marker を置く契約を明示。
- 1.2 — `run_per_task_reviewer "$task_id" 2` が `pt_resolve_diff_range` を通り、retry 修正 commit を補正後 range に含めることを `per_task_marker_review_range_test.sh` の round=2 fixture で確認。
- 1.3 — `run_per_task_reviewer "$task_id" 3` が同じ range guard を通り、Debugger 後修正 commit を補正後 range に含めることを round=3 fixture で確認。
- 1.4 — `pt_resolve_diff_range` が marker 後 commit 検出時に `range_end=HEAD` へ補正し、安全に解けない場合は rc=1 で失敗する実装を確認。
- 2.1 — Reviewer 起動前の range 解決が `run_per_task_reviewer` の単一入口で実行され、marker 後 commit を silent に古い marker 終端へ丸めないことを確認。
- 2.2 — marker 後 commit は `range_end=HEAD` に含められ、stderr / `$LOG` に `post-marker-commits-included` 診断が残ることをテストで確認。
- 2.3 — range 解決失敗時は `run_per_task_reviewer` が rc=3 を返し、呼び出し側が `pt_mark_diff_range_resolve_failed` で `codex-failed` 相当へ停止する経路を確認。
- 2.4 — retry round=2 / Debugger round=3 の両 fixture が、現在 attempt の HEAD SHA を Reviewer prompt の `range_end` に渡すことを確認。
- 3.1 — `build_per_task_reviewer_prompt` が `range_start_sha` と `range_end_sha` を明示することを確認。
- 3.2 — Reviewer prompt と `.codex/agents/reviewer.md` が、渡された range 外 commit を当該 per-task review では判断しない契約を明示。
- 3.3 — `run_per_task_reviewer` が task ID、round、短縮 range を `$LOG` に出すことを確認。
- 3.4 — `pt_build_diff_range_resolve_diagnostic` と `pt_mark_diff_range_resolve_failed` が task ID、affected range、marker 後 commit、復旧操作を出すことを確認。
- 4.1 — `diff -r .codex/agents repo-template/.codex/agents` が差分なし。
- 4.2 — `.codex/rules/` は未変更で、`diff -r .codex/rules repo-template/.codex/rules` が差分なし。
- 4.3 — agent 同期 diff を実行し、差分なしを確認。
- 4.4 — rules 同期 diff を実行し、差分なしを確認。
- 4.5 — README の per-task marker / review range 説明が runtime と prompt の include-or-fail 契約に追従していることを確認。
- 5.1 — `bash local-watcher/test/per_task_marker_review_range_test.sh` が marker 後 corrective commit を再現し、resolved diff に `fix.txt` が含まれることを確認。
- 5.2 — 同テストの Reviewer reject retry 相当 fixture が round=2 の `range_end=HEAD` を確認。
- 5.3 — 同テストの Debugger guidance retry 相当 fixture が round=3 の `range_end=HEAD` を確認。
- 5.4 — prompt-only assertion は発生せず、対象 coverage は shell fixture で検証済みと `impl-notes.md` に記録されていることを確認。
- NFR 1.1 — 既存 env var、label、cron 文字列、branch 命名、exit code 意味の変更は確認されない。
- NFR 1.2 — `PER_TASK_LOOP_ENABLED=true` 経路の helper / prompt / tests 変更であり、単発 Developer + Reviewer 経路の挙動変更は確認されない。
- NFR 1.3 — Reviewer 判定カテゴリは既存 3 カテゴリのまま維持されている。
- NFR 1.4 — 新しい外部サービス呼び出し、runtime dependency の追加は確認されない。
- NFR 2.1 — marker 後 commit 検出時の operator-visible log を確認。
- NFR 2.2 — Reviewer 起動前停止時の診断に task ID と affected range が含まれることを確認。

## Findings

なし

## Summary

Issue #23 の AC は実装、prompt / README 同期、回帰テストでカバーされています。指定 verify の `shellcheck`、per-task range regression、root / repo-template 同期 diff は成功しました。

RESULT: approve
