# Implementation Notes

### Task 1

- 採用方針: `local-watcher/bin/modules` を `local-watcher/bin/idd-codex-modules` へ `git mv` し、module 本体の挙動は変更しない。
- 重要な判断: ヘッダコメントの配置先だけを新 namespace に揃え、関数名・ファイル名・source 順に影響する記述は触らない。
- 残存課題: watcher loader、installer、tests、README、rules の参照更新は後続 task の境界として残す。
