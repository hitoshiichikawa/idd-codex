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

### Task 2

- 採用方針: redo context block を optional prompt 引数として実装し、通常 per-task Implementer prompt は空引数時に従来どおり維持した。
- 重要な判断:
  - `pt_build_redo_context_block` は Reviewer / Debugger context の抽出失敗時も diagnostic block を返し、通常の同一 task 再実行と区別できるようにした。
  - round 1 reject 後は `review-notes.md`、round 2 reject + Debugger 後は `review-notes.md` と `debugger-notes.md` の `## Task <id>` セクションを inline 注入する。
  - Finding Closure Matrix の詳細 contract と repeated reject guard は後続 task の境界に残した。
- 残存課題: task 3 で Finding Closure Matrix の必須列と Developer agent 同期、task 4 で連続 reject warning guard を実装する必要がある。

### Task 3

- 採用方針: Finding Closure Matrix の contract を redo prompt と Developer agent の per-task 指示へ同期し、shell fixture では prompt-only assertion として検証した。
- 重要な判断:
  - Matrix の必須列は `Target requirement` / `Category` / `Required Action` / `Fix commit` / `Test/assertion` / `Verification result` / `Notes / no-change reason` に固定した。
  - 実 LLM に `impl-notes.md` を生成させる assertion は shell fixture の責務外のため、prompt が rejected target requirement、fix commit、test/assertion、verification result を要求していることを確認する方針にした。
  - 手動確認範囲は prompt 文面、Developer agent 文面、root / repo-template agents の byte-identical 同期に限定した。
- 残存課題: task 4 で連続 reject warning guard、task 5 で #23 shape の回帰 fixture を完成させる必要がある。

### Task 4

- 採用方針: 連続 reject guard は fail-fast ではなく warning-only とし、Reviewer prompt と watcher log の両方に残す形で実装した。
- 重要な判断:
  - fingerprint は `review-notes.md` の Findings から `category + target` TSV として抽出し、warning 対象は `missing test` / `AC 未カバー` に限定した。
  - test 差分は `local-watcher/test/*` / `tests/*` / `*/test/*` / `*_test.sh` / `*test*.sh` の path heuristic で判定し、新規 dependency は追加しなかった。
  - round 2 前は round 1 reject target の test 差分なし risk、round 3 前は round 1 / 2 の overlap かつ test 差分なしの場合だけ warning を注入する。
- 残存課題: task 5 で #23 shape の Req 5.2 / 5.3 regression fixture を完成させる必要がある。
