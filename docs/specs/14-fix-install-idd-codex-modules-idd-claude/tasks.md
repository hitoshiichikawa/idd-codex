# Implementation Plan

- [ ] 1. Module source directory を idd-codex 専用名へ rename する
  - `git mv local-watcher/bin/modules local-watcher/bin/idd-codex-modules` を使い、履歴を保ったまま source directory を rename する。
  - `local-watcher/bin/idd-codex-modules/*.sh` のヘッダコメントにある `$HOME/bin/modules/*.sh` / `local-watcher/bin/modules/` 参照を `$HOME/bin/idd-codex-modules/*.sh` / `local-watcher/bin/idd-codex-modules/` へ更新する。
  - module ファイル名、関数名、`REQUIRED_MODULES` の構成、processor 挙動は変更しない。
  - _Requirements: 1.3, 2.3, 3.3, 3.5, 4.1, 4.2_

- [ ] 2. `install.sh --local` の module 配置先を `$HOME/bin/idd-codex-modules/` へ変更する
  - source directory 判定を `"$LOCAL_WATCHER_DIR/bin/idd-codex-modules"` に変更する。
  - destination を `"$HOME/bin/idd-codex-modules"` に変更し、idd-codex module 配置のために `"$HOME/bin/modules"` を作成・更新しない。
  - 既存の `ensure_dir` / `copy_glob_to_homebin` による冪等コピーを維持し、`install.sh --repo` の挙動は変更しない。
  - 旧 `$HOME/bin/modules/` の削除や idd-claude module 復旧は実装しない。
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 3.1, 3.4, 4.3, 4.4_

- [ ] 3. watcher の module loader を `idd-codex-modules/` 解決へ変更する
  - `IDD_MODULE_DIR` を watcher 本体同階層の `idd-codex-modules` に変更し、repo 直実行と `$HOME/bin` インストール後の双方で `BASH_SOURCE` 基準の同一ロジックを維持する。
  - loader 周辺コメントを新 directory 名へ更新する。
  - missing module エラーと復旧案内を `idd-codex-modules/` に合わせる。
  - `$HOME/bin/modules/` への fallback や旧 directory 要求は追加しない。
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 3.2, 3.3, 3.4, 3.5_

- [ ] 4. local watcher tests を新 module directory へ追従する
  - `local-watcher/test/*.sh` の `../bin/modules/` 参照を `../bin/idd-codex-modules/` へ更新する。
  - `module_loader_missing_test.sh` の `MODULES_DIR` と一時コピー先を `idd-codex-modules` に変更する。
  - missing module ケースで stderr が欠落ファイル名と新 directory を識別できることを確認する assertion を必要に応じて追加する。
  - `install.sh --local` の一時 `HOME` smoke で、新配置に module が存在し旧 `$HOME/bin/modules/` に idd-codex module が置かれないことを確認できるようにする。
  - _Requirements: 2.3, 2.4, 4.3, 4.4, 4.5_

- [ ] 5. README の構成図、手動コピー例、migration note を新配置へ更新する
  - 構成図の `local-watcher/bin/modules/` を `local-watcher/bin/idd-codex-modules/` に変更する。
  - 手動コピー例を `~/bin/idd-codex-modules` 作成と `idd-codex-modules/*.sh` コピーへ更新する。
  - migration note で、既存利用者は `git pull && ./install.sh --local` により新配置へ移行できることを明記する。
  - 旧 `$HOME/bin/modules/` を idd-codex の配置先として説明する記述を残さず、必要な場合は「idd-codex は旧 directory の削除・idd-claude 復旧を代行しない」として扱う。
  - _Requirements: 1.5, 3.1, 3.2, 3.5, 4.1, 4.2_

- [ ] 6. root / repo-template rules の module path 例示を byte 一致で同期する
  - `.codex/rules/tasks-generation.md` と `repo-template/.codex/rules/tasks-generation.md` の verify 例を `local-watcher/bin/idd-codex-modules/*.sh` へ更新する。
  - `.codex/rules/design-review-gate.md` と `repo-template/.codex/rules/design-review-gate.md` の `stage-a-verify.sh` 参照を `local-watcher/bin/idd-codex-modules/stage-a-verify.sh` へ更新する。
  - 更新後に `diff -r .codex/rules repo-template/.codex/rules` が空であることを確認する。
  - _Requirements: 4.1, 4.2_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを以下に宣言する。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/idd-codex-modules/*.sh install.sh setup.sh .github/scripts/*.sh &&
bash local-watcher/test/module_loader_missing_test.sh &&
tmp_home="$(mktemp -d)" &&
trap 'rm -rf "$tmp_home"' EXIT &&
HOME="$tmp_home" ./install.sh --local >/tmp/idd-codex-install-local-test.log &&
test -f "$tmp_home/bin/idd-codex-modules/core_utils.sh" &&
test ! -e "$tmp_home/bin/modules/core_utils.sh" &&
diff -r .codex/rules repo-template/.codex/rules
```
