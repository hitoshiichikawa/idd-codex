# Review Notes

<!-- idd-codex:review round=2 model=gpt-5.5 timestamp=2026-06-09T21:10:13Z -->

## Reviewed Scope

- Branch: codex/issue-40-impl--bug-14-module-namespace-migration-insta
- HEAD commit: d087c5ed4e091b439ccd71c22b87b19d401ef4d4
- Compared to: main..HEAD

## Verified Requirements

- 1.1 - `install.sh:1231` と `local-watcher/test/install_local_namespace_test.sh:84` で `$HOME/bin/idd-codex-issue-watcher.sh` の配置・上書きを検証。
- 1.2 - `install.sh:1238`〜`install.sh:1240` と `local-watcher/test/install_local_namespace_test.sh:90` / `local-watcher/test/install_local_namespace_test.sh:103` で `$HOME/bin/idd-codex-modules/*.sh` 配置を検証。
- 1.3 - `local-watcher/test/install_local_namespace_test.sh:86` / `local-watcher/test/install_local_namespace_test.sh:90` で installed watcher と `core_utils.sh` の namespaced 配置を検証。
- 1.4 - `local-watcher/test/install_local_namespace_test.sh:88` / `local-watcher/test/install_local_namespace_test.sh:92` / `local-watcher/test/install_local_namespace_test.sh:105` で shared `$HOME/bin/modules/` 非使用・非上書きを検証。
- 2.1 - `local-watcher/bin/idd-codex-issue-watcher.sh:689`〜`local-watcher/bin/idd-codex-issue-watcher.sh:704` と `local-watcher/test/install_local_namespace_test.sh:86` で `idd-codex-modules/` source を確認。
- 2.2 - `local-watcher/test/install_local_namespace_test.sh:88` と `local-watcher/test/module_loader_missing_test.sh:181` で shared `modules/` を source しないことを検証。
- 2.3 - `local-watcher/bin/idd-codex-issue-watcher.sh:695`〜`local-watcher/bin/idd-codex-issue-watcher.sh:704` により `core_utils.sh` を `idd-codex-modules/` から読み込む構成を確認。
- 2.4 - `local-watcher/test/module_loader_missing_test.sh:169`〜`local-watcher/test/module_loader_missing_test.sh:184` で `core_utils.sh` 欠落時に `_slot_run_issue` 到達前に失敗することを検証。
- 3.1 - `tests/local-watcher/stage-a-verify/extract-driver.sh:23` と `docs/specs/40--bug-14-module-namespace-migration-insta/tasks.md:23` で stage-a verify の module path が `local-watcher/bin/idd-codex-modules/*.sh` に固定されていることを確認。
- 3.2 - `README.md:538`〜`README.md:543` で README の repo / installed module path 例示が `idd-codex-modules/` を使うことを確認。
- 3.3 - `README.md:547`〜`README.md:549` で post-merge runtime refresh として `install.sh --local` 再実行を案内していることを確認。
- 3.4 - `README.md:549`〜`README.md:551` で legacy `$HOME/bin/modules/` を runtime module source として使わない旨が明記され、round=1 finding の是正を確認。
- 4.1 - `local-watcher/test/install_local_namespace_test.sh:84` / `local-watcher/test/install_local_namespace_test.sh:90` で installed runtime fixture が watcher と `core_utils.sh` を含むことを検証。
- 4.2 - `local-watcher/test/module_loader_missing_test.sh:163`〜`local-watcher/test/module_loader_missing_test.sh:184` で non-codex shared module fixture から codex 関数を解決しないことを検証。
- 4.3 - `local-watcher/test/module_loader_missing_test.sh:169`〜`local-watcher/test/module_loader_missing_test.sh:184` で `core_utils.sh` 欠落時の起動前 failure を検証。
- 4.4 - `local-watcher/test/install_local_namespace_test.sh:103` / `local-watcher/test/install_local_namespace_test.sh:105` と stage-a verify の shellcheck 対象で shared layout 回帰を検出する構成を確認。
- NFR 1.1 - `install.sh:1231` と README の `$HOME/bin/idd-codex-issue-watcher.sh` 案内により cron / launchd command path 維持を確認。
- NFR 1.2 - 差分は spec / README / regression test / stage-a verify path に閉じ、env var・label・exit code の意味変更は確認されない。
- NFR 1.3 - `local-watcher/test/install_local_namespace_test.sh:108`〜`local-watcher/test/install_local_namespace_test.sh:112` で repeated `install.sh --local` の冪等性を検証。
- NFR 2.1 - `local-watcher/test/install_local_namespace_test.sh:92` / `local-watcher/test/install_local_namespace_test.sh:111` で idd-claude 側 shared modules 非依存・非変更を検証。

## Findings

なし

## Summary

round=1 の README 未カバー指摘は `README.md:549`〜`README.md:551` の追記で解消されています。指定 verify ブロックも成功しており、AC 未カバー / missing test / boundary 逸脱は見つかりませんでした。

RESULT: approve
