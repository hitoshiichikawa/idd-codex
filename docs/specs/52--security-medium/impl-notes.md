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
| NFR 1.1 | `setup.sh`, `README.md` env var table | Existing bootstrap env override flow | `security_medium_bootstrap_docs_test.sh`: env var names maintained | `bash local-watcher/test/security_medium_bootstrap_docs_test.sh` pass | `IDD_CODEX_BRANCH` default 値のみ変更 |
| NFR 2.1 | `README.md`, `QUICK-HOWTO.md`, `setup.sh` comments | Operator-visible bootstrap docs | `security_medium_bootstrap_docs_test.sh`: pinned URL / override / checksum docs assertions | `bash local-watcher/test/security_medium_bootstrap_docs_test.sh` pass | 変更した operator-visible behavior を docs に記載 |

## Verification

- `bash local-watcher/test/security_medium_bootstrap_docs_test.sh` — pass
- `shellcheck setup.sh local-watcher/test/security_medium_bootstrap_docs_test.sh` — pass
- `git fetch --depth 1 origin 9f8e9cea7df960f5be14849edcbac03dea55162e` against `https://github.com/hitoshiichikawa/idd-codex.git` — pass

STATUS: complete
