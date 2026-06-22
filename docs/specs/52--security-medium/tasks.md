# Implementation Plan

- [x] 1. pinned bootstrap reference と checksum 方針を人間決定後に setup / docs へ反映する
  - 着手前に、既定の pinned release tag または commit SHA と、checksum artifacts を同一 PR で提供するかどうかの人間決定を確認する。未決なら実装せず PR の「確認事項」に戻す。
  - `setup.sh` の推奨 command コメント、no-args guidance、`IDD_CODEX_BRANCH` default を同じ pinned reference に更新する。
  - README と QUICK-HOWTO の quick install URL、env var table、mutable branch override note、checksum verification path を同じ pinned reference に同期する。
  - `security_medium_bootstrap_docs_test.sh` を追加し、`setup.sh` default と README / QUICK-HOWTO の推奨 URL が同じ pinned reference を参照し、`IDD_CODEX_BRANCH` / `IDD_CODEX_REPO_URL` override 名が維持されることを検証する。
  - _Requirements:_ 1.1, 1.2, 1.3, 1.4, 1.5, NFR 1.1, NFR 2.1

- [x] 2. `install.sh --local` の local runtime safe overwrite を実装する (P)
  - `$HOME/bin/idd-codex-issue-watcher.sh` と macOS launchd plist にだけ適用する local runtime copy helper を追加し、差分あり既存ファイルを silent overwrite しない。
  - recovery file を operator-visible に作成し、既存 recovery file を無断で上書きしない。`--force` 時も recovery file 保護をログに出す。
  - `--dry-run --local` / `--dry-run --all` で create / skip / backup / overwrite の予定 action を表示する。
  - `security_medium_install_test.sh` に watcher target の normal / changed existing / existing recovery / dry-run ケースを追加する。macOS plist は fixture path を使って Darwin 依存なしに helper を検証する。
  - _Requirements:_ 2.1, 2.2, 2.3, 2.4, 2.5, NFR 1.3, NFR 1.4, NFR 2.3
  - _Boundary:_ Local Runtime Safe Copy

- [x] 3. Guard Hook profile の literal rendering と dry-run reporting を実装する
  - `install.sh` の Guard profile 生成を `sed` delimiter replacement から literal replacement helper に置き換える。
  - hook path に `#`, `\`, `&`, spaces を含むケースで rendered profile が exact path を保持し、placeholder が残らないことを検証する。
  - generation failure 時は malformed profile を書かず、operator-visible error を出す。
  - dry-run では profile action を表示するだけで dest profile を作らない。
  - `security_medium_install_test.sh` に Guard profile normal / special path / malformed template or render failure / dry-run ケースを追加する。
  - _Requirements:_ 3.1, 3.2, 3.3, 3.4, NFR 2.2, NFR 2.3
  - _Depends:_ 2

- [x] 4. secure tempfile helper を `core_utils.sh` に追加し watcher 本体の predictable temp path を置換する (P)
  - `core_utils.sh` に owner-only temp directory と non-predictable file を作る `idd_secure_mktemp` helper を追加する。
  - `idd-codex-issue-watcher.sh` の triage JSON、quota reset handoff、command stderr temp、diagnostic temp の predictable `/tmp` path / fallback を helper に置き換える。
  - helper failure は current operation を fail-visible にし、timestamp / PID / issue number / repo slug だけの fallback を使わない。
  - cleanup trap / `rm -f` を call-site ごとに確認し、意図的に残す diagnostic artifact は local log に path と reason を出す。
  - `security_medium_tempfiles_test.sh` に helper normal / unwanted fallback failure / boundary path permission ケースと watcher call-site 文字列 regression を追加する。
  - _Requirements:_ 5.1, 5.2, 5.3, 5.4, 5.5, NFR 2.2, NFR 2.3
  - _Boundary:_ Secure Tempfile Helper, Watcher Core Tempfile Call Sites

- [x] 5. processor modules の temp file 作成を secure tempfile helper に統一する
  - `auto-rebase.sh` の result file / dismissal stderr temp から predictable fallback を除去する。
  - `pr-reviewer.sh` の prompt / stdout / stderr / result / approval body / approval stderr temp を helper に置き換える。
  - `pr-iteration.sh` の usage-limit / soft-fail / recovery handoff temp と、`quota-aware.sh` の quota reset state atomic update temp を owner-only creation に合わせる。
  - 各 processor の cleanup と local diagnostic retention の境界を確認し、fail-closed warning を processor prefix 付きで出す。
  - `security_medium_tempfiles_test.sh` に auto-rebase / pr-reviewer / pr-iteration / quota-aware の normal / unwanted fallback / boundary cleanup ケースを追加する。
  - _Requirements:_ 5.1, 5.2, 5.3, 5.4, 5.5, NFR 2.2, NFR 2.3
  - _Depends:_ 4

- [x] 6. PR Reviewer の placeholder validation と public error redaction を実装する
  - `{BASE}`, `{HEAD}`, `{PR}` に入る PR-derived value を field ごとに検証し、newline、redirection、glob、command substitution、shell separator、leading option-like form、非 numeric PR number を拒否する。
  - unsafe value は当該 PR を skip し、operator-visible warning には PR number / field / reason category を出す。raw value は public comment に出さない。
  - non-quota execution failure の public `exec-failed` comment から raw stdout / stderr excerpt を除去し、PR number、head SHA、tool、exit code、local log correlation token だけを含める。
  - local `$LOG` または secure diagnostic artifact に詳細診断を残し、quota reset path、`PR_REVIEWER_ENABLED!=true` no-op、`PR_REVIEWER_HEAD_PATTERN`、fork exclusion を維持する。
  - `security_medium_pr_reviewer_test.sh` に placeholder normal / unwanted value / boundary leading dash、public redaction、local diagnostics、disabled no-op、head pattern / fork exclusion regression を追加する。
  - _Requirements:_ 4.1, 4.2, 4.3, 4.4, 4.5, 6.1, 6.2, 6.3, 6.4, 6.5, NFR 1.1, NFR 1.2, NFR 2.2, NFR 2.3

- [ ] 7. README / QUICK-HOWTO の operator-visible behavior を実装結果に同期する
  - local runtime overwrite policy、recovery file、`--dry-run` action、Guard profile exact path handling、secure tempfile policy を README に追記する。
  - PR Reviewer non-quota failure comment が generic になり、詳細は local logs / artifacts で見ることを README の PR Reviewer 節に反映する。
  - mutable branch override と checksum artifacts の扱いを QUICK-HOWTO にも同期する。
  - 既存 env var 名、label 名、cron / launchd command path を変えないことを migration note として明記する。
  - `security_medium_bootstrap_docs_test.sh` または `security_medium_install_test.sh` に README / QUICK-HOWTO key phrase regression を追加する。
  - _Requirements:_ 1.4, 1.5, 2.3, 4.2, 4.4, 5.3, NFR 1.1, NFR 1.2, NFR 1.3, NFR 1.4, NFR 2.1, NFR 2.2
  - _Depends:_ 1, 2, 3, 4, 5, 6

- [ ] 8. hardening 全体の静的検証と smoke を実行する
  - 変更した shell scripts と追加 test に `shellcheck` を実行する。
  - 追加した security_medium 系 test をすべて実行する。
  - `install.sh --local --dry-run` の出力に local runtime / Guard profile action が含まれることを確認する。
  - cron / launchd command path、existing env var names、label names が変更されていないことを差分レビューで確認する。
  - 実行結果と未決だった pinned reference / checksum artifact の人間決定内容を `impl-notes.md` に記録する。
  - _Requirements:_ NFR 1.1, NFR 1.2, NFR 1.3, NFR 1.4, NFR 2.1, NFR 2.2, NFR 2.3
  - _Depends:_ 1, 2, 3, 4, 5, 6, 7

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを以下に宣言する。

<!-- stage-a-verify -->
```sh
shellcheck setup.sh install.sh local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/idd-codex-modules/core_utils.sh local-watcher/bin/idd-codex-modules/auto-rebase.sh local-watcher/bin/idd-codex-modules/pr-reviewer.sh local-watcher/bin/idd-codex-modules/pr-iteration.sh local-watcher/bin/idd-codex-modules/quota-aware.sh local-watcher/test/security_medium_bootstrap_docs_test.sh local-watcher/test/security_medium_install_test.sh local-watcher/test/security_medium_tempfiles_test.sh local-watcher/test/security_medium_pr_reviewer_test.sh &&
bash local-watcher/test/security_medium_bootstrap_docs_test.sh &&
bash local-watcher/test/security_medium_install_test.sh &&
bash local-watcher/test/security_medium_tempfiles_test.sh &&
bash local-watcher/test/security_medium_pr_reviewer_test.sh
```
