# Implementation Notes

## 実装概要

- `tests/local-watcher/stage-a-verify/extract-driver.sh` の抽出元を旧 `local-watcher/bin/modules/stage-a-verify.sh` から `local-watcher/bin/idd-codex-modules/stage-a-verify.sh` へ修正した。
- `local-watcher/test/module_loader_missing_test.sh` に、`idd-codex-modules/core_utils.sh` 欠落時に隣接 shared `modules/core_utils.sh` が存在しても source されず、`_slot_run_issue` 到達前に失敗するケースを追加した。
- `local-watcher/test/install_local_namespace_test.sh` を追加し、一時 HOME 上で stale installed watcher と idd-claude 風 shared `$HOME/bin/modules/core_utils.sh` を用意してから `install.sh --local` を実行し、installed watcher 上書き、`$HOME/bin/idd-codex-modules/*.sh` 配置、shared `$HOME/bin/modules/` 非上書き、再実行時の冪等性を検証した。
- `docs/specs/40--bug-14-module-namespace-migration-insta/tasks.md` に構造化 verify ブロックを追加し、旧 `STAGE_A_VERIFY_COMMAND` が残っていても `local-watcher/bin/idd-codex-modules/*.sh` を使う検証が優先されるようにした。
- `install.sh` 本体と watcher loader は既に `idd-codex-modules/` を使う実装だったため、今回は installed runtime 反映漏れを回帰テストで固定した。
- README は既に `local-watcher/bin/idd-codex-modules/*.sh` と `$HOME/bin/idd-codex-modules/` を案内し、`$HOME/bin/idd-codex-issue-watcher.sh` の実行パスを維持していたため変更していない。旧 `$HOME/bin/modules/` への言及は migration note 上の旧 layout としての説明のみ。

## 検証

```bash
bash tests/local-watcher/stage-a-verify/extract-driver.sh
bash local-watcher/test/module_loader_missing_test.sh
bash local-watcher/test/install_local_namespace_test.sh
shellcheck install.sh local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/idd-codex-modules/*.sh local-watcher/test/module_loader_missing_test.sh local-watcher/test/install_local_namespace_test.sh tests/local-watcher/stage-a-verify/extract-driver.sh
git diff --check
```

すべて成功。加えて、旧 `STAGE_A_VERIFY_COMMAND` が残っている状態でも本 spec の構造化 verify ブロックが `source=structured-block` として優先されることを確認した。

## 確認事項

- なし。
