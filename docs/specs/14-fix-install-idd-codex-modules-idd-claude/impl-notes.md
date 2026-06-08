# Implementation Notes

### Task 1

- 採用方針: `local-watcher/bin/modules` を `local-watcher/bin/idd-codex-modules` へ `git mv` し、module 本体の挙動は変更しない。
- 重要な判断: ヘッダコメントの配置先だけを新 namespace に揃え、関数名・ファイル名・source 順に影響する記述は触らない。
- 残存課題: watcher loader、installer、tests、README、rules の参照更新は後続 task の境界として残す。

### Recovery learning

- #14 の自動 retry では task 1 marker の後ろに installer / loader / README / tests の修正が積まれ、Reviewer の diff range から漏れた。復旧では実変更と `docs(tasks): mark <id> as done` を task ごとに分け直した。
- `install.sh --local`、watcher loader、tests、README、rules の変更は module namespace 追従として分離し、task marker が各変更範囲の後ろに来るようにした。
