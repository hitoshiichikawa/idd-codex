# Review Notes

<!-- idd-codex:review round=1 model=gpt-5.5 timestamp=2026-06-08T18:31:47Z -->

## Reviewed Scope

- Branch: codex/issue-11-impl--bug-dispatcher-slot-id-is-corrupted-by
- HEAD commit: 5820a9a3fd4b87d25045ff62453492dd787786ae
- Compared to: main..HEAD

## Verified Requirements

- 3.1.1 — `local-watcher/bin/idd-codex-issue-watcher.sh:8317` の `_dispatcher_find_free_slot` が slot 番号のみを stdout に返し、`local-watcher/test/stdout_discipline_test.sh:123` で `1` のみを検証。
- 3.1.2 — `local-watcher/bin/idd-codex-issue-watcher.sh:8320` で `_dispatcher_reap_finished_slots` の completion log を stderr に分離し、`local-watcher/test/stdout_discipline_test.sh:125` で slot 値への混入なしを検証。
- 3.1.3 — `local-watcher/bin/idd-codex-issue-watcher.sh:6724` の `_dispatcher_validate_slot_id` が正整数かつ `PARALLEL_SLOTS` 範囲内だけを許可し、`local-watcher/test/stdout_discipline_test.sh:130` で汚染値 reject を検証。
- 3.1.4 — `local-watcher/bin/idd-codex-issue-watcher.sh:8506` で dispatch 前に invalid slot id を fail closed し、claim / worktree / log path / comment 派生処理の前で停止する配置を確認。
- 3.2.1 — dispatcher の return channel は `local-watcher/bin/idd-codex-issue-watcher.sh:8320`、promote の issue number channel は `local-watcher/bin/modules/promote-pipeline.sh:1132` で machine-readable 値に限定されていることを確認。
- 3.2.2 — dispatcher completion log は `local-watcher/bin/idd-codex-issue-watcher.sh:8320`、promote auto-label log は `local-watcher/bin/modules/promote-pipeline.sh:1120` / `1128` で stderr に分離。
- 3.2.3 — `local-watcher/bin/modules/promote-pipeline.sh:1120` / `1128` の `pp_log` stderr 化と `local-watcher/test/stdout_discipline_test.sh:198` の実関数 fake `gh` テストで issue number stdout の汚染なしを検証。
- 3.3.1 — `local-watcher/test/stdout_discipline_test.sh:84` で completion log 発生を模擬し、`local-watcher/test/stdout_discipline_test.sh:123` で次 slot が clean に割り当てられることを検証。
- 3.3.2 — `local-watcher/test/stdout_discipline_test.sh:128` で clean slot id の検証成功、`local-watcher/test/stdout_discipline_test.sh:130` で newline / timestamp 汚染値の reject を確認。
- 3.4.1 — `local-watcher/bin/idd-codex-issue-watcher.sh:8506` の検証が `dispatcher_log "dispatched #... -> slot-${slot}"` と `_slot_run_issue "$slot"` より前にあり、壊れた slot 表示を記録しない構造を確認。
- 3.4.2 — `local-watcher/bin/idd-codex-issue-watcher.sh:6727` と `8506` で invalid slot id を stderr error にしてサイクルを `return 1` し、`local-watcher/test/stdout_discipline_test.sh:138` で error path の可観測性を検証。
- 3.5.1 — `local-watcher/test/stdout_discipline_test.sh:130` で contaminated stdout 相当の slot 値が消費前に reject される回帰テストを追加。
- 3.5.2 — `local-watcher/test/stdout_discipline_test.sh:84` / `123` で concurrent completion logging 相当の状況でも割当 slot id が clean であることを検証。
- 3.5.3 — `local-watcher/test/stdout_discipline_test.sh:198` 以降で dispatcher-adjacent な `pp_collect_merged_issues` の issue number stdout discipline を検証。

## Findings

なし

## Summary

`tasks.md` と `design.md` は存在しないため、tasks の `_Boundary:_` アノテーションに基づく境界確認は適用できませんでした。差分は requirements の対象範囲内に収まり、追加テストと再実行した `bash local-watcher/test/stdout_discipline_test.sh`、`bash local-watcher/test/dispatch_hotfix_jq_test.sh`、`shellcheck local-watcher/bin/*.sh local-watcher/bin/modules/*.sh local-watcher/test/stdout_discipline_test.sh install.sh setup.sh .github/scripts/*.sh` はすべて成功しました。

RESULT: approve
