# Issue #52 Implementation Notes

## Implementation Notes

### Task 1

- 前提だった人間判断は **#52 owner により確定済み**（詳細は `tasks.md` の task 1 を参照）:
  - 既定 pinned reference = **commit SHA**（mutable `main` ではない）。初期値は実装時点の
    `origin/main` HEAD の commit SHA を採用し、`setup.sh` / docs に「release ごとに本 SHA を bump する」
    maintainer note を併記する。`IDD_CODEX_BRANCH` / `IDD_CODEX_REPO_URL` override は名称・挙動を変えず温存。
  - checksum artifacts は本 PR では生成・提供しない（別 release 運用）。AC 1.5 は検証 path の docs 記載で満たす。
- 次アクション: 上記確定方針に従って `setup.sh` / README / QUICK-HOWTO / `security_medium_bootstrap_docs_test.sh` を実装する。

- 採用方針: `setup.sh` の既定参照を `origin/main` 由来の commit SHA
  `9f8e9cea7df960f5be14849edcbac03dea55162e` に固定し、docs の推奨 raw URL と同じ値へ同期した。
- 重要な判断:
  - raw commit SHA は既存の `git clone --branch` / `origin/<branch>` reset では扱えないため、
    clone 後に `git fetch --depth 1 origin <ref>` + detached checkout する方式へ変更した。
  - `IDD_CODEX_BRANCH` / `IDD_CODEX_REPO_URL` / `IDD_CODEX_DIR` の env var 名は維持し、
    mutable branch 指定は pinned default の明示 override として README / QUICK-HOWTO に記載した。
  - checksum artifact は本 PR では生成せず、release で `SHA256SUMS` 等が提供される場合の
    manual verification path のみ docs に記載した。
- 残存課題: なし（release ごとの SHA bump は maintainer note として docs / `setup.sh` に記載済み）。

#### Finding Closure Matrix

| Target requirement | Category | Required Action | Fix commit | Test/assertion | Verification result | Notes / no-change reason |
|--------------------|----------|-----------------|------------|----------------|---------------------|--------------------------|
| boundary:Task 1 implementation range | boundary 逸脱 | `AGENTS.md`、`local-watcher/bin/idd-codex-issue-watcher.sh`、`local-watcher/test/per_task_needs_decision_test.sh` の endpoint 差分を task 1 range から除外する | `5ef9183 fix(codex): restore task 1 review boundary` | `bash local-watcher/test/per_task_needs_decision_test.sh`; `git diff --name-status main..HEAD` | pass; endpoint diff は `setup.sh` / docs / task 1 test / impl-notes / marker のみに限定 | 復元対象は task 1 実装ではなく、前回 range 混入の打ち消し。`shellcheck` を復元 test まで広げると main baseline の SC2034 が出るため、機能 regression は bash test で確認した。 |
| boundary:docs/specs/52--security-medium/tasks.md | boundary 逸脱 | 非 marker commit で混入した task 本文変更を戻し、endpoint 差分を task 1 checkbox のみに限定する | `5ef9183 fix(codex): restore task 1 review boundary` + final `docs(tasks): mark 1 as done` marker | `git diff main -- docs/specs/52--security-medium/tasks.md` | pass; task 1 の `- [ ]` → `- [x]` 以外の endpoint 差分なし | history rewrite は禁止のため corrective commit で本文差分を打ち消し、attempt 末尾に canonical marker を置き直す。 |

### Task 2

- 採用方針: `install.sh --local` のうちユーザー編集対象である watcher 本体と macOS launchd plist だけに `.bak` once-only の safe overwrite helper を適用した。
- 重要な判断:
  - `copy_template_file` の既存挙動は repo-template / module / prompt 配布向けに維持し、local runtime 専用 helper を分けて後方互換性の影響範囲を限定した。
  - 既存 `.bak` がある場合は無断で recovery file を上書きせず、`--force` 時も `.bak` を温存したまま target だけ明示上書きする。
  - Darwin 依存の launchd plist 経路は fake `uname` を使う shell test で production branch 経由の動作を検証した。
- 残存課題: なし（task 3 の Guard profile renderer は本 task scope 外）。

### Task 3

- 採用方針: Guard profile 生成を `sed` 置換から `render_guard_profile_config` の literal replacement に切り替え、hook path を data として扱うようにした。
- 重要な判断:
  - `#` / `\` / `&` / spaces を含む path で delimiter や replacement syntax の影響を受けないよう、bash の置換ではなく `awk` の `index` / `substr` で placeholder を置換した。
  - Guard config template は TOML literal string (`'...'`) に変更し、backslash を escape sequence として解釈させず exact path を保持する形式にした。
  - placeholder 不在や TOML literal string で安全に表現できない path は malformed profile を書かず、operator-visible error で fail closed する。
- 残存課題: なし（single quote / newline を含む hook path は fail closed。通常の `$HOME/.idd-codex/hooks` 系 path には影響なし）。

#### Reviewer Round 1 Closure

- 採用方針: `render_guard_profile_config` の hook path は `awk -v` assignment を通さず、process environment から読み込ませることで `\n` / `\t` などの literal backslash sequence を path data として保持した。
- 重要な判断:
  - `placeholder` は固定 ASCII sentinel のため `awk -v` のまま維持し、未信頼 data である hook path だけを `ENVIRON` 経由に分離した。
  - TOML single-line literal string で表現できない real newline / carriage return / single quote は生成前に拒否し、malformed profile を stdout / dest に出さない regression を追加した。
- 残存課題: なし。

#### Finding Closure Matrix

| Target requirement | Category | Required Action | Fix commit | Test/assertion | Verification result | Notes / no-change reason |
|--------------------|----------|-----------------|------------|----------------|---------------------|--------------------------|
| 3.2, 3.3 | AC 未カバー | hook path を `awk -v replacement=...` で渡さず、literal backslash sequence の exact preservation と real newline の fail-closed regression を追加する | `18d2f24 fix(install): preserve guard path backslashes literally` | `security_medium_install_test.sh`: guard profile keeps literal backslash n/t sequences in hook path; guard renderer fails closed before writing real newline paths | `bash local-watcher/test/security_medium_install_test.sh` pass; `shellcheck install.sh local-watcher/test/security_medium_install_test.sh` pass | Reviewer 指摘どおり hook path は `ENVIRON` 経由で読み、`awk -v` の escape 解釈対象から外した。 |

### Task 4

- 採用方針: `core_utils.sh` に `idd_secure_mktemp` を追加し、watcher 本体と core utility の prompt / JSON / stderr / quota reset handoff 用一時ファイルを `LOG_DIR/tmp` 配下の owner-only private root へ集約した。
- 重要な判断:
  - `mktemp` が失敗した場合は `/tmp/...-$$` や timestamp 由来 path に fallback せず、operator-visible error を出して current operation を fail closed する。
  - `LOCK_FILE` の既定 `/tmp` は design の Non-Goals どおり機密 payload ではないため変更せず、task 4 の対象を triage JSON、quota reset handoff、stderr / diagnostic temp に限定した。
  - `IDD_CODEX_TMP_DIR` は既存 env var を壊さない追加 override として扱い、指定先も 0700 にできない場合は使用しない。
- 残存課題: processor modules 側の temp file 統一は task 5 scope。

## 確認事項

（task 1 の人間判断は確定済み。残存する確認事項なし）

## AC Coverage Matrix

| Requirement / AC | Implementation path | Production entrypoint / owning flow | Test / assertion | Verification result | Notes |
|------------------|---------------------|-------------------------------------|------------------|---------------------|-------|
| 1.1 | `README.md`, `QUICK-HOWTO.md`, `setup.sh` raw setup URL | Operator が quick install command を読む / 実行する flow | `security_medium_bootstrap_docs_test.sh`: raw setup URLs use the same pinned ref / avoids mutable main | `bash local-watcher/test/security_medium_bootstrap_docs_test.sh` pass | 正常系と unwanted mutable `main` URL 不在を検証 |
| 1.2 | `setup.sh`: `IDD_CODEX_PINNED_REF`, `checkout_idd_codex_ref` | `setup.sh` default clone/update flow | `security_medium_bootstrap_docs_test.sh`: default resolves to pinned ref / explicit commit SHA checkout | `bash local-watcher/test/security_medium_bootstrap_docs_test.sh` pass; GitHub remote fetch of `9f8e9...` pass | commit SHA は detached checkout で扱う |
| 1.3 | `setup.sh`: env default expansion and checkout helper | `IDD_CODEX_BRANCH` / `IDD_CODEX_REPO_URL` override flow | `security_medium_bootstrap_docs_test.sh`: override names maintained / mutable branch override checkout | `bash local-watcher/test/security_medium_bootstrap_docs_test.sh` pass | env var 名は変更なし |
| 1.4 | `README.md`, `QUICK-HOWTO.md` override note | Operator が mutable branch override を選ぶ docs flow | `security_medium_bootstrap_docs_test.sh`: README documents `IDD_CODEX_BRANCH=main` override | `bash local-watcher/test/security_medium_bootstrap_docs_test.sh` pass | mutable branch は明示 override として許容 |
| 1.5 | `README.md`, `QUICK-HOWTO.md` checksum verification note | Operator が release artifact を手動検証する docs flow | `security_medium_bootstrap_docs_test.sh`: checksum verification path in README / QUICK-HOWTO | `bash local-watcher/test/security_medium_bootstrap_docs_test.sh` pass | checksum artifact 生成は本 task scope 外 |
| 2.1 | `install.sh`: `copy_local_runtime_file`, `copy_local_watcher_scripts` | `install.sh --local` / `--all` が `$HOME/bin/idd-codex-issue-watcher.sh` を配置する flow | `security_medium_install_test.sh`: changed watcher is backed up before overwrite / target refreshed / existing recovery skip-force cases | `bash local-watcher/test/security_medium_install_test.sh` pass | 差分あり watcher の silent discard を防ぎ、recovery file を残す |
| 2.2 | `install.sh`: `copy_local_runtime_file` in Darwin launchd branch | macOS の `install.sh --local` / `--all` が LaunchAgents plist を配置する flow | `security_medium_install_test.sh`: fake `uname=Darwin` launchd plist backup / overwrite assertions | `bash local-watcher/test/security_medium_install_test.sh` pass | Linux 上でも Darwin branch を production path として実行 |
| 2.3 | `install.sh`: `log_action BACKUP`, `.bak` recovery path | Operator が install log を確認して previous contents を復元する flow | `security_medium_install_test.sh`: watcher / plist backup path is operator-visible | `bash local-watcher/test/security_medium_install_test.sh` pass | recovery は `<target>.bak` |
| 2.4 | `install.sh`: existing `.bak` branch in `copy_local_runtime_file` | Reinstall 時に既存 recovery file がある local runtime overwrite flow | `security_medium_install_test.sh`: existing recovery prevents overwrite without force / force preserves `.bak` | `bash local-watcher/test/security_medium_install_test.sh` pass | `--force` は target overwrite の opt-in。既存 `.bak` は温存 |
| 2.5 | `install.sh`: dry-run-aware `copy_local_runtime_file` logging | `install.sh --dry-run --local` / `--dry-run --all` の action preview flow | `security_medium_install_test.sh`: dry-run reports BACKUP and OVERWRITE without modifying files | `bash local-watcher/test/security_medium_install_test.sh` pass | `--local` 経路で検証。`--all` でも同じ `INSTALL_LOCAL` branch を通る |
| 3.1 | `install.sh`: `render_guard_profile_config`; `local-watcher/hooks/idd-codex-guard.config.toml` | `install.sh --local` が `${CODEX_HOME:-$HOME/.codex}/idd-codex-guard.config.toml` を生成する flow | `security_medium_install_test.sh`: guard profile normal install preserves exact hook path / removes placeholder | `bash local-watcher/test/security_medium_install_test.sh` pass | 通常 path の production install 経路で検証 |
| 3.2 | `install.sh`: `render_guard_profile_config` literal replacement; Guard template TOML literal string | Operator が `IDD_CODEX_HOOKS_INSTALL_DIR` に特殊文字を含む path を指定して `install.sh --local` を実行する flow | `security_medium_install_test.sh`: guard profile keeps `#`, `&`, backslash, and spaces / guard profile keeps literal backslash n/t sequences / leaves no placeholder | `bash local-watcher/test/security_medium_install_test.sh` pass | `sed` delimiter / replacement syntax と `awk -v` escape 解釈を通さない regression |
| 3.3 | `install.sh`: guard renderer validation before write | Guard profile template または hook path が single-line TOML literal string として安全に生成できない場合の local install failure path | `security_medium_install_test.sh`: renderer fails closed when template lacks placeholder / emits no malformed profile content / fails closed before writing real newline paths / error is visible | `bash local-watcher/test/security_medium_install_test.sh` pass | malformed template と real newline path は helper 単位で検証。install path は helper failure で `exit 1` |
| 3.4 | `install.sh`: dry-run guard profile branch | `install.sh --dry-run --local` の Guard profile action preview flow | `security_medium_install_test.sh`: dry-run reports generated profile action and does not create profile | `bash local-watcher/test/security_medium_install_test.sh` pass | dry-run でも action は表示、dest は未作成 |
| NFR 1.1 | `setup.sh`, `README.md` env var table | Existing bootstrap env override flow | `security_medium_bootstrap_docs_test.sh`: env var names maintained | `bash local-watcher/test/security_medium_bootstrap_docs_test.sh` pass | `IDD_CODEX_BRANCH` default 値のみ変更 |
| NFR 1.3 | `install.sh`: watcher target path and launchd target path unchanged | Existing cron / launchd command path flow | `security_medium_install_test.sh`: watcher installed at `$HOME/bin/idd-codex-issue-watcher.sh`; plist installed at `$HOME/Library/LaunchAgents/com.local.idd-codex-issue-watcher.plist` | `bash local-watcher/test/security_medium_install_test.sh` pass | command path は変更なし |
| NFR 1.4 | `install.sh`: safe overwrite idempotency branches | Repeated `install.sh --local` / `--all` reinstall flow | `security_medium_install_test.sh`: identical skip, existing recovery skip, force overwrite with recovery preserved; `install_local_namespace_test.sh`: repeated install regression | both tests pass | repo install path は変更なし |
| NFR 2.1 | `README.md`, `QUICK-HOWTO.md`, `setup.sh` comments | Operator-visible bootstrap docs | `security_medium_bootstrap_docs_test.sh`: pinned URL / override / checksum docs assertions | `bash local-watcher/test/security_medium_bootstrap_docs_test.sh` pass | 変更した operator-visible behavior を docs に記載 |
| NFR 2.2 | `install.sh`: Guard renderer failure messages | Guard profile hardening check が input / template を reject する flow | `security_medium_install_test.sh`: guard renderer failure is operator-visible | `bash local-watcher/test/security_medium_install_test.sh` pass | affected feature と reason category を stderr に出す |
| NFR 2.3 | `local-watcher/test/security_medium_install_test.sh` | install hardening regression suite | Normal create / unwanted existing recovery / Guard malformed template / boundary dry-run and Darwin plist assertions | `bash local-watcher/test/security_medium_install_test.sh` pass | task 2 / task 3 とも正常系・異常系・境界値を含む |
| 5.1 | `core_utils.sh`: `idd_secure_mktemp`; `idd-codex-issue-watcher.sh` secure temp call-sites | Triage / Stage A / Reviewer / Debugger / Stage C / resume push / failed recovery / worktree reset / slot hook stderr flows | `security_medium_tempfiles_test.sh`: helper creates distinct mktemp paths; watcher regression rejects `/tmp/triage-`, `/tmp/qa-reset-`, and old `mktemp ... || echo ""` fallbacks | `bash local-watcher/test/security_medium_tempfiles_test.sh` pass | processor modules beyond core utility remain task 5 scope |
| 5.2 | `core_utils.sh`: `idd_secure_mktemp` private root creation and `umask 077` file creation | Any watcher flow requesting prompt / JSON / stderr / reset-state tempfile | `security_medium_tempfiles_test.sh`: private tmp directory is `700`; temporary file mode is owner-only | `bash local-watcher/test/security_medium_tempfiles_test.sh` pass | default root is `$LOG_DIR/tmp`; `IDD_CODEX_TMP_DIR` override must also be owner-only |
| 5.3 | `core_utils.sh`: fail-closed branches in `idd_secure_mktemp`; watcher call-sites using `|| return` or explicit mark-failed path | Secure tempfile creation failure in current watcher operation | `security_medium_tempfiles_test.sh`: uncreatable tmp root returns non-zero and emits `secure-tempfile: ERROR:`; no predictable fallback path is created | `bash local-watcher/test/security_medium_tempfiles_test.sh` pass | push verify / resume push call-sites additionally route through existing failure paths |
| 5.4 | `core_utils.sh`: symlink / mode validation for temp root | Tempfile root setup before writing operational diagnostics | `security_medium_tempfiles_test.sh`: helper uses private `$LOG_DIR/tmp` root and rejects uncreatable override | `bash local-watcher/test/security_medium_tempfiles_test.sh` pass | `$TMPDIR` is only used as parent when `LOG_DIR` is unavailable; file creation itself is through private root + `mktemp` |
| 5.5 | `idd-codex-issue-watcher.sh`, `core_utils.sh`: existing `rm -f` cleanup retained after secure path creation | Completion / failure cleanup for triage reset file, stage reset file, stderr temp, worktree reset, slot hook | `security_medium_tempfiles_test.sh`: call-site regression verifies old predictable paths removed while existing cleanup branches remain in production code | `bash local-watcher/test/security_medium_tempfiles_test.sh` pass | diagnostic artifacts intentionally retained by later PR Reviewer task are task 6 scope |
| NFR 2.2 | `core_utils.sh`: `secure-tempfile: ERROR:` messages; watcher explicit failure paths | Tempfile hardening check rejects unsafe / unavailable temp root | `security_medium_tempfiles_test.sh`: failure is operator-visible | `bash local-watcher/test/security_medium_tempfiles_test.sh` pass | reason category is emitted locally; public PR comment behavior is task 6 scope |
| NFR 2.3 | `local-watcher/test/security_medium_tempfiles_test.sh` | secure tempfile regression suite | helper normal / unwanted failure / boundary label and watcher call-site string regression | `bash local-watcher/test/security_medium_tempfiles_test.sh` pass; `shellcheck local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/idd-codex-modules/core_utils.sh local-watcher/test/security_medium_tempfiles_test.sh` pass | task 4 の正常系・異常系・境界値を含む |

## Verification

- `bash local-watcher/test/security_medium_bootstrap_docs_test.sh` — pass
- `bash local-watcher/test/per_task_needs_decision_test.sh` — pass
- `bash local-watcher/test/security_medium_install_test.sh` — pass
- `bash local-watcher/test/install_local_namespace_test.sh` — pass
- `shellcheck setup.sh local-watcher/test/security_medium_bootstrap_docs_test.sh` — pass
- `shellcheck install.sh local-watcher/test/security_medium_install_test.sh local-watcher/test/install_local_namespace_test.sh` — pass
- `shellcheck install.sh local-watcher/test/security_medium_install_test.sh` — pass
- `bash local-watcher/test/security_medium_install_test.sh` — pass (Reviewer Round 1 closure: literal `\n` / `\t` path preservation and real newline fail-closed regression)
- `shellcheck install.sh local-watcher/test/security_medium_install_test.sh` — pass (Reviewer Round 1 closure)
- `git fetch --depth 1 origin 9f8e9cea7df960f5be14849edcbac03dea55162e` against `https://github.com/hitoshiichikawa/idd-codex.git` — pass
- `bash local-watcher/test/security_medium_tempfiles_test.sh` — pass
- `shellcheck local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/idd-codex-modules/core_utils.sh local-watcher/test/security_medium_tempfiles_test.sh` — pass
- `git diff --check` — pass

STATUS: complete
