# Implementation Plan

- [x] 1. installed runtime と shared module layout の回帰カバレッジを追加する
  - `install.sh --local` が stale `$HOME/bin/idd-codex-issue-watcher.sh` を現行 watcher で上書きすることを検証する。
  - `$HOME/bin/idd-codex-modules/*.sh` が配置され、shared `$HOME/bin/modules/` が idd-codex install により上書きされないことを検証する。
  - `idd-codex-modules/core_utils.sh` 欠落時に shared `modules/core_utils.sh` へ fallback せず、`_slot_run_issue` 到達前に失敗することを検証する。
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 2.3, 2.4, 4.1, 4.2, 4.3, 4.4_

- [x] 2. stage-a verify の module path を idd-codex namespace へ固定する
  - `tests/local-watcher/stage-a-verify/extract-driver.sh` の抽出元を `local-watcher/bin/idd-codex-modules/stage-a-verify.sh` へ更新する。
  - 本 spec の構造化 verify ブロックで `local-watcher/bin/idd-codex-modules/*.sh` を使い、旧 `STAGE_A_VERIFY_COMMAND` より優先させる。
  - _Requirements: 3.1, 4.4_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを以下に宣言する。

<!-- stage-a-verify -->
```sh
bash tests/local-watcher/stage-a-verify/extract-driver.sh &&
bash local-watcher/test/module_loader_missing_test.sh &&
bash local-watcher/test/install_local_namespace_test.sh &&
shellcheck install.sh local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/idd-codex-modules/*.sh local-watcher/test/module_loader_missing_test.sh local-watcher/test/install_local_namespace_test.sh tests/local-watcher/stage-a-verify/extract-driver.sh
```
