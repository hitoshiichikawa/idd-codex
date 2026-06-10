# Review Notes

<!-- idd-codex:review round=1 model=gpt-5.5 timestamp=2026-06-10T00:24:35Z -->

## Reviewed Scope

- Branch: codex/issue-37-impl--enhancement-per-task-retry-reviewer-deb
- HEAD commit: dbe6aea54916f8dd1b1748acada984daf5323190
- Compared to: main..HEAD
- Diff summary: `git diff --stat main..HEAD` / `git log --oneline main..HEAD` / changed-file `git diff main..HEAD -- <path>` を確認した。

## Verified Requirements

- 1.1 — `local-watcher/bin/idd-codex-issue-watcher.sh:2600` の `pt_extract_review_reject_context` と `run_per_task_loop` の round 1 reject 経路 `local-watcher/bin/idd-codex-issue-watcher.sh:5014` で Findings を redo prompt に注入している。`local-watcher/test/per_task_redo_context_test.sh:369` 以降で prompt 注入を検証済み。
- 1.2 — `pt_extract_review_reject_context` が Required Action を抽出し、raw Findings と parsed summary を出力する実装を `local-watcher/bin/idd-codex-issue-watcher.sh:2641` で確認した。`local-watcher/test/per_task_redo_context_test.sh:325` / `:377` / `:382` で inline 含有を検証済み。
- 1.3 — redo context block が task ID、Reviewer round、category、target を示す実装を `local-watcher/bin/idd-codex-issue-watcher.sh:2702` / `:2853` で確認した。`local-watcher/test/per_task_redo_context_test.sh:320` から `:324` で検証済み。
- 1.4 — 抽出不能時に diagnostic block と log を残す実装を `local-watcher/bin/idd-codex-issue-watcher.sh:2813` から `:2825` で確認した。`local-watcher/test/per_task_redo_context_test.sh:405` から `:410` で silent rerun ではないことを検証済み。
- 2.1 — Debugger 後 redo でも Reviewer context を同じ `pt_build_redo_context_block` に渡す実装を `local-watcher/bin/idd-codex-issue-watcher.sh:5124` から `:5135` で確認した。`local-watcher/test/per_task_redo_context_test.sh:390` から `:400` で検証済み。
- 2.2 — `pt_extract_debugger_task_section` が `debugger-notes.md` の `## Task <id>` を抽出する実装を `local-watcher/bin/idd-codex-issue-watcher.sh:2721` から `:2772` で確認した。`local-watcher/test/per_task_redo_context_test.sh:343` から `:351` で検証済み。
- 2.3 — Reviewer と Debugger の由来を別見出しで分ける実装を `local-watcher/bin/idd-codex-issue-watcher.sh:2702` / `:2881` で確認した。`local-watcher/test/per_task_redo_context_test.sh:394` / `:395` / `:402` で検証済み。
- 2.4 — Debugger section 抽出不能時に diagnostic block と log を残す実装を `local-watcher/bin/idd-codex-issue-watcher.sh:2831` から `:2848` で確認した。`local-watcher/test/per_task_redo_context_test.sh:353` から `:364` で検証済み。
- 3.1 — redo prompt と Developer agent に Finding Closure Matrix 作成 / 更新責務が入っていることを `local-watcher/bin/idd-codex-issue-watcher.sh:2863`、`.codex/agents/developer.md:432`、`repo-template/.codex/agents/developer.md:432` で確認した。
- 3.2 — rejected target requirement ごとの行を要求する contract を `local-watcher/bin/idd-codex-issue-watcher.sh:2866`、`.codex/agents/developer.md:443` で確認した。
- 3.3 — fix commit 記録を要求する contract を `local-watcher/bin/idd-codex-issue-watcher.sh:2873`、`.codex/agents/developer.md:444` で確認した。
- 3.4 — test/assertion 記録を要求する contract を `local-watcher/bin/idd-codex-issue-watcher.sh:2874`、`.codex/agents/developer.md:445` で確認した。
- 3.5 — verification result 記録を要求する contract を `local-watcher/bin/idd-codex-issue-watcher.sh:2875`、`.codex/agents/developer.md:446` で確認した。
- 3.6 — 修正 / test 更新不要時の理由と確認結果を要求する contract を `local-watcher/bin/idd-codex-issue-watcher.sh:2876`、`.codex/agents/developer.md:447` で確認した。
- 4.1 — `pt_build_repeated_reject_warning` が `missing test` target かつ test 差分なしで warning を生成する実装を `local-watcher/bin/idd-codex-issue-watcher.sh:2991` から `:3039` で確認した。`local-watcher/test/per_task_repeated_reject_guard_test.sh:190` から `:197` で検証済み。
- 4.2 — `AC 未カバー` target も warning 対象に含める実装を `local-watcher/bin/idd-codex-issue-watcher.sh:2983` から `:2987` で確認した。`local-watcher/test/per_task_repeated_reject_guard_test.sh:194` / `:195` で検証済み。
- 4.3 — 実装は fail-fast ではなく warning-only を選択しているため該当なし。fail-fast 用 AC は warning-only 選択時の必須実装ではない。
- 4.4 — warning-only block を Reviewer prompt、operator log、Developer-visible artifact、Reviewer 前の dedicated redo に渡す実装を `local-watcher/bin/idd-codex-issue-watcher.sh:3042` から `:3197`、`:5048` から `:5089`、`:5162` から `:5195` で確認した。`local-watcher/test/per_task_repeated_reject_guard_test.sh:199` から `:225`、`:259` から `:270` で検証済み。
- 5.1 — #23 shape の round 1 Reviewer context が redo prompt に入る fixture を `local-watcher/test/per_task_redo_context_test.sh:415` から `:424` で確認し、`bash local-watcher/test/per_task_redo_context_test.sh` PASS 77 / FAIL 0 を再実行確認した。
- 5.2 — Debugger 後 redo prompt に Reviewer context と Debugger Fix Plan が同時に入る fixture を `local-watcher/test/per_task_redo_context_test.sh:426` から `:436` で確認し、同テスト PASS を再実行確認した。
- 5.3 — Finding Closure Matrix contract の rejected target requirement / fix commit / test/assertion / verification result assertion を `local-watcher/test/per_task_redo_context_test.sh:437` から `:440` で確認し、`impl-notes.md:89` 以降にも closure 記録があることを確認した。
- 5.4 — `.codex/agents/developer.md` と `repo-template/.codex/agents/developer.md` の同一差分を確認し、`diff -r .codex/agents repo-template/.codex/agents` が出力なしで通ることを再実行確認した。
- 5.5 — shared rule file の変更はなく、`diff -r .codex/rules repo-template/.codex/rules` が出力なしで通ることを再実行確認した。
- 5.6 — prompt-only assertion に留めた理由と手動確認範囲が `docs/specs/37--enhancement-per-task-retry-reviewer-deb/impl-notes.md:95` から `:108` に記録されていることを確認した。

## Findings

なし

## Summary

AC 未カバー、missing test、boundary 逸脱はいずれも検出しなかった。再実行した verify はすべて PASS で、変更範囲も `local-watcher/`、`.codex/`、`repo-template/`、対象 spec 記録に収まっている。

RESULT: approve
