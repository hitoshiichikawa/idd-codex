# Review Notes

<!-- idd-codex:review round=2 model=gpt-5.5 timestamp=2026-06-18T05:52:20Z -->

## Reviewed Scope

- Branch: codex/issue-68-impl-bug-watcher-tasks-md-checkbox-numeric-ta
- HEAD commit: 1a04ded363d4bbfba87b3be7595b73eac2860643
- Compared to: main..HEAD
- Note: `tasks.md` / `design.md` は存在しないため、requirements・実装差分・既存/追加テストで境界を確認。

## Verified Requirements

- 1.1 — `pt_extract_pending_tasks` が `- [ ] N. <title>` から親 task ID `N` を抽出する。`local-watcher/test/per_task_task_marker_parsing_test.sh` case2 で確認。
- 1.2 — `pt_check_task_completed` が `- [x] N. <title>` を完了済み親 task として扱う。`local-watcher/bin/idd-codex-issue-watcher.sh:2615` の親 marker suffix 判定で確認。
- 1.3 — `pt_extract_pending_tasks` が `- [ ] N.M[.K...] <title>` から子 task ID を抽出する。`local-watcher/test/per_task_task_marker_parsing_test.sh` case3 で確認。
- 1.4 — `pt_check_task_completed` が `- [x] N.M[.K...] <title>` を完了済み子 task として扱う。`local-watcher/bin/idd-codex-issue-watcher.sh:2615` の子 marker suffix 判定で確認。
- 1.5 — 通常 checklist `- [ ] 1 PR ...` を task `1` として抽出しない。`local-watcher/test/per_task_task_marker_parsing_test.sh` case1 で確認。
- 1.6 — 非互換 checkbox を selection / completion check から外す。`pt_extract_pending_tasks` と `pt_check_task_completed` の marker 契約、および case4 の prose checkbox 除外で確認。
- 2.1 — pending 抽出で `- [ ] 1. Baseline audit` が `1` になる。`per_task_task_marker_parsing_test.sh` case2 で確認。
- 2.2 — pending 抽出で `- [ ] 1.1 子タスク` が `1.1` になる。`per_task_task_marker_parsing_test.sh` case3 で確認。
- 2.3 — pending 抽出で `- [ ] 1 PR ...` が `1` にならない。`per_task_task_marker_parsing_test.sh` case1 で確認。
- 2.4 — task ID `1` の完了確認は親 marker `1. ` に限定される。`pt_check_task_completed` の parent suffix と case4 で確認。
- 2.5 — task ID `1.1` の完了確認は子 marker `1.1 ` に限定される。`pt_check_task_completed` の child suffix で確認。
- 2.6 — task ID `1` の完了確認で prose checkbox を task `1` と扱わない。`per_task_task_marker_parsing_test.sh` case4 で確認。
- 3.1 — impl-resume checkpoint は marker 0 件の `tasks.md` を Stage B に silent skip せず Stage A へ戻す。`stage_checkpoint_pending_tasks_test.sh` case4 で確認。
- 3.2 — per-task startup は marker 0 件を完了扱いしない。`run_per_task_loop` の startup guard と `per_task_task_marker_parsing_test.sh` case5 で確認。
- 3.3 — per-task startup は prose checkbox を fallback task として選ばない。`per_task_task_marker_parsing_test.sh` case5 と `pt_extract_pending_tasks` の空抽出で確認。
- 3.4 — marker 0 件 failure は missing marker contract と対象 `tasks.md` を診断に含める。`pt_fail_no_compatible_tasks` と case5 で確認。
- 3.5 — marker 0 件 failure は「全 task 完了」ではなく malformed task generation と区別できる文脈を残す。`pt_fail_no_compatible_tasks` の診断文と `stage_checkpoint_pending_tasks_test.sh` case4 の reason log で確認。
- 4.1 — `.codex/rules/design-review-gate.md` が per-task 実行対象に watcher-compatible parent checkbox task 1 件以上を要求する。
- 4.2 — `.codex/rules/design-review-gate.md` が numeric headings あり・parent checkbox task 0 件を per-task 非互換として扱う。
- 4.3 — `.codex/rules/tasks-generation.md` が parent task を `- [ ] N. <title>` 形式で要求する。
- 4.4 — `.codex/rules/tasks-generation.md` が child task を `- [ ] N.M[.K...] <title>` 形式で要求する。
- 4.5 — `diff -r .codex/rules repo-template/.codex/rules` が成功し、変更 rules は byte-identical。
- 5.1 — env var 名、ラベル名、cron / launchd invocation contract、exit code 意味の変更は差分上確認されない。
- 5.2 — prose checkbox `- [ ] 1 PR ...` を pending task `1` として抽出しない regression test がある。
- 5.3 — parent marker `- [ ] 1. Baseline audit` を pending task `1` として抽出する regression test がある。
- 5.4 — child marker `- [ ] 1.1 子タスク` を pending task `1.1` として抽出する regression test がある。
- 5.5 — task ID `1` の完了確認で prose checkbox を task `1` と扱わない regression test がある。
- 5.6 — heading-based / marker 0 件の per-task startup failure と impl-resume checkpoint failure path の regression test がある。
- 5.7 — `shellcheck --severity=warning local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/test/per_task_task_marker_parsing_test.sh local-watcher/test/stage_checkpoint_pending_tasks_test.sh` が成功。
- 5.8 — `diff -r .codex/rules repo-template/.codex/rules` が成功。

## Findings

なし。

## Summary

round=1 の reject 対象だった impl-resume checkpoint の marker 0 件 regression が追加され、Stage B silent skip を防ぐ挙動を直接確認できました。AC 未カバー、missing test、boundary 逸脱はいずれも検出していません。

RESULT: approve
