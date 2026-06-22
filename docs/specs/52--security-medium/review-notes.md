# Review Notes

<!-- idd-codex:review round=1 model=gpt-5.5 timestamp=2026-06-22T08:50:16Z -->

## Reviewed Scope

- Branch: codex/issue-52-impl--security-medium
- HEAD commit: f54cf87e08b522b110413e1cc90f807ab1557185
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `README.md:143-164`、`QUICK-HOWTO.md:35-36`、`setup.sh:86-90` の推奨 setup URL が commit SHA 固定で、`security_medium_bootstrap_docs_test.sh` が mutable `main` URL 不在を検証。
- 1.2 — `setup.sh:41-44` の `IDD_CODEX_PINNED_REF` 既定化と `setup.sh:107-122` の commit SHA checkout 実装を確認。bootstrap docs test の explicit commit checkout ケースも pass。
- 1.3 — `setup.sh:41-45` が `IDD_CODEX_REPO_URL` / `IDD_CODEX_BRANCH` / `IDD_CODEX_DIR` を維持し、bootstrap docs test の mutable branch override ケースが pass。
- 1.4 — `README.md:268-283`、`QUICK-HOWTO.md:41-44` が mutable branch 指定を pinned default の明示 override と説明。
- 1.5 — `README.md:273-276`、`QUICK-HOWTO.md:57-63` が checksum artifact 提供時の manual verification path を記載。
- 2.1 — `install.sh:248-319` の local runtime safe copy が差分あり watcher を `.bak` 退避後に更新し、`security_medium_install_test.sh` の changed watcher ケースが pass。
- 2.2 — `install.sh:248-319` と macOS launchd branch の `copy_local_runtime_file` 適用を確認し、Darwin fixture の plist backup / overwrite test が pass。
- 2.3 — `install.sh:291-306` の `BACKUP` / recovery preservation ログ、`README.md:386-403`、`QUICK-HOWTO.md:66-71` の recovery docs を確認。
- 2.4 — `install.sh:303-315` が既存 `.bak` を無断上書きせず、`--force` 時も `.bak` を温存する test が pass。
- 2.5 — `install.sh:273-318` の dry-run-aware logging と install test の dry-run backup / overwrite assertion が pass。
- 3.1 — `install.sh:321-365`、`install.sh:1418-1444` の literal renderer と generated profile write path を確認し、normal guard profile test が pass。
- 3.2 — `install.sh:352-364` が `awk` literal replacement で hook path を扱い、`#` / `&` / `\` / spaces / literal `\n` `\t` の regression test が pass。
- 3.3 — `install.sh:329-349` が template missing / unsupported path を fail closed し、malformed output を書かない regression test が pass。
- 3.4 — `install.sh:1436-1444` が dry-run では profile action のみ表示し、guard dry-run test が pass。
- 4.1 — `pr-reviewer.sh:1103-1123` が non-quota exec failure の public detail を generic 化し、PR Reviewer redaction test が raw stdout / stderr 非公開を確認。
- 4.2 — `pr-reviewer.sh:493-525` が local diagnostic artifact に stdout / stderr を保持し、redaction test が artifact 内容と local log を確認。
- 4.3 — `pr-reviewer.sh:1112-1122` の public comment detail が raw diagnostics を含まず、token-like stderr / local path / stdout sentinel 非公開 test が pass。
- 4.4 — `pr-reviewer.sh:1118-1122` が PR number / sha / tool / exit / correlation token を public detail に含める test が pass。
- 4.5 — `pr-reviewer.sh:1223-1226` の `PR_REVIEWER_ENABLED=true` 厳密 gate と disabled no-op test を確認。
- 5.1 — `core_utils.sh:148-207` の `idd_secure_mktemp` と watcher / processor call-site 置換を確認し、tempfiles test が predictable `/tmp` fallback 除去を検証。
- 5.2 — `core_utils.sh:171-205` が private tmp root `700` と tempfile owner-only mode を設定し、mode regression test が pass。
- 5.3 — `core_utils.sh:163-203` が symlink / directory / chmod / mktemp failure を operator-visible error で fail closed し、failure test が pass。
- 5.4 — `core_utils.sh:150-160` が `$LOG_DIR/tmp` または `IDD_CODEX_TMP_DIR` 配下の private root を使い、world-writable predictable path 依存の regression が除去されていることを確認。
- 5.5 — `idd-codex-issue-watcher.sh` の triage cleanup trap / normal cleanup と PR Reviewer cleanup trap、processor cleanup assertions が `security_medium_tempfiles_test.sh` で pass。
- 6.1 — `pr-reviewer.sh:471-489` が `{BASE}` / `{HEAD}` / `{PR}` 置換前に field 別 validation を通し、normal substitution / unsafe skip test が pass。
- 6.2 — `pr-reviewer.sh:397-423` が newline、redirection、glob、command substitution、separator、leading option、non-numeric PR を拒否し、reason category test が pass。
- 6.3 — `pr_fetch_candidate_prs` の head pattern regression test が same-owner `codex/` PR のみを残すことを確認。
- 6.4 — `pr_fetch_candidate_prs` の fork exclusion regression test が fork owner PR を除外することを確認。
- 6.5 — `pr-reviewer.sh:438-452` が rejected placeholder の warning から raw value を除外し、unsafe placeholder が public comment を作らない test が pass。
- NFR 1.1 — `setup.sh:41-45`、`README.md:281-283`、PR Reviewer tests で既存 env var 名維持を確認。
- NFR 1.2 — `git diff --exit-code main..HEAD -- .github/scripts/idd-codex-labels.sh .github/ISSUE_TEMPLATE repo-template/.github/ISSUE_TEMPLATE` が pass。
- NFR 1.3 — local runtime install docs と smoke / install tests で `$HOME/bin/idd-codex-issue-watcher.sh` と launchd path 維持を確認。
- NFR 1.4 — safe copy / dry-run / existing `.bak` tests と full verify pass により installer idempotency regression を確認。
- NFR 2.1 — README / QUICK-HOWTO の hardening behavior docs と `security_medium_bootstrap_docs_test.sh` の key phrase regression を確認。
- NFR 2.2 — Guard renderer、secure tempfile、placeholder rejection、exec diagnostic の operator-visible failure tests が pass。
- NFR 2.3 — 宣言済み verify block を再実行し、`shellcheck` と security_medium 系 4 test が全て pass。
- boundary — `git diff --name-status main..HEAD` は `setup.sh`、`install.sh`、README / QUICK-HOWTO、対象 watcher modules、対象 tests、spec notes / task markers に限定され、tasks.md の `_Boundary:_` からの逸脱は検出していない。

## Findings

なし

## Summary

`main..HEAD` の差分は Issue #52 の 6-2〜6-7 hardening と docs / test 同期に対応しており、各 AC に実装または regression test の紐付けが確認できた。宣言済み verify block も再実行して pass したため、AC 未カバー、missing test、boundary 逸脱はいずれも検出していない。

RESULT: approve
