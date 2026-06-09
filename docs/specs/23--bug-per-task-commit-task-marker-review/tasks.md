# Implementation Plan

- [x] 1. per-task review range の include-or-fail guard を watcher に実装する
  - `pt_resolve_diff_range` の既存 marker 選択ロジックを維持しつつ、選択済み marker から `HEAD` までの post-marker commit を検査する。
  - marker 後 commit が存在する場合は corrective commit を含む `range_end`（通常 `HEAD`）を返すか、安全に解けなければ Reviewer 起動前に `rc=3` 相当で失敗させる。
  - marker 後 commit 検出時は task ID、marker SHA、end SHA、commit count を grep 可能なログに残す。
  - `pt_should_skip_reviewer` が補正後 range を使い、corrective commit がある range を parent checkbox-only skip と誤判定しないことを確認する。
  - _Requirements: 1.4, 2.1, 2.2, 2.3, 2.4, 3.3, 3.4, 5.1_

- [x] 2. Reviewer reject / Debugger 後の再実行経路で range guard を必ず通す
  - Reviewer round=1 reject 後の `run_per_task_implementer` -> `run_per_task_reviewer "$task_id" 2` 経路が新しい `pt_resolve_diff_range` guard を bypass しないことを確認する。
  - Debugger BLOCKED 後の Implementer 再実行 -> round=1 Reviewer 合流経路が同じ guard を通ることを確認する。
  - round=2 reject Debugger 後の Implementer 再実行 -> `run_per_task_reviewer "$task_id" 3` 経路が同じ guard を通ることを確認する。
  - guard 失敗時の `mark_issue_failed` コメントに task ID、affected range、復旧操作を判断できる診断情報を含める。
  - _Requirements: 1.2, 1.3, 1.4, 2.3, 2.4, 3.4, 5.2, 5.3_

- [x] 3. per-task Implementer / Reviewer prompt の marker / range contract を同期更新する
  - `build_per_task_implementer_prompt` と `.codex/agents/developer.md` に、retry では修正 commit 後の末尾に最新 `docs(tasks): mark <id> as done` marker を残す契約を明記する。
  - `build_per_task_reviewer_prompt` と `.codex/agents/reviewer.md` に、`range_start_sha` / `range_end_sha` が判定対象の正本であり、`range_end_sha` は marker 後 commit を含む補正後 SHA になり得ることを明記する。
  - `repo-template/.codex/agents/developer.md` と `repo-template/.codex/agents/reviewer.md` に同じ変更を byte-identical で反映する。
  - shared rule に同じ契約を置く必要がある場合のみ `.codex/rules/tasks-generation.md` と `repo-template/.codex/rules/tasks-generation.md` を byte-identical に更新する。
  - _Requirements: 1.1, 1.2, 1.3, 3.1, 3.2, 4.1, 4.2_

- [x] 4. README / docs の per-task marker / review range 説明を runtime と揃える
  - README の per-task loop 説明で `docs(tasks): mark <id> as done` marker が task attempt の終端であることを説明する。
  - Reviewer range は start / end SHA で明示され、marker 後 commit が検出された場合は include-or-fail することを説明する。
  - 新しい env var、label、exit code、外部サービス、runtime dependency を追加しないことを確認し、migration note が必要な場合は README に限定して追記する。
  - _Requirements: 3.3, 3.4, 4.5_

- [x] 5. #14 形状の regression coverage を追加する
  - `local-watcher/test/per_task_marker_review_range_test.sh` を追加し、temporary git repo で base commit、task implementation commit、`docs(tasks): mark 1.1 as done` marker、marker 後 corrective commit を作る。
  - Reviewer reject -> Implementer retry 相当の case で、corrective commit が resolved range に含まれる、または Reviewer 起動前に明示失敗することを検証する。
  - Debugger guidance -> Implementer retry 相当の case で、Debugger 後 corrective commit が古い marker によって除外されないことを検証する。
  - prompt-only assertion を shell fixture で実現できない場合は、`docs/specs/23--bug-per-task-commit-task-marker-review/impl-notes.md` に理由と手動確認結果を書く。
  - _Requirements: 5.1, 5.2, 5.3, 5.4_

- [ ] 6. 静的検証と root↔repo-template 同期を確認する
  - `shellcheck local-watcher/bin/idd-codex-issue-watcher.sh install.sh setup.sh .github/scripts/*.sh` を実行し、警告ゼロを確認する。
  - `bash local-watcher/test/per_task_marker_review_range_test.sh` を実行する。
  - `diff -r .codex/agents repo-template/.codex/agents` と `diff -r .codex/rules repo-template/.codex/rules` が空であることを確認する。
  - 実行結果と、prompt-only assertion を manual にした場合の理由を `impl-notes.md` に記録する。
  - _Requirements: 4.3, 4.4, 5.1, 5.2, 5.3, 5.4_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを以下に宣言する。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/idd-codex-issue-watcher.sh install.sh setup.sh .github/scripts/*.sh &&
bash local-watcher/test/per_task_marker_review_range_test.sh &&
diff -r .codex/agents repo-template/.codex/agents &&
diff -r .codex/rules repo-template/.codex/rules
```
