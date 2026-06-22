# Issue #52 Implementation Notes

## Implementation Notes

### Task 1

- 前提だった人間判断は **#52 owner により確定済み**（詳細は `tasks.md` の task 1 を参照）:
  - 既定 pinned reference = **commit SHA**（mutable `main` ではない）。初期値は実装時点の
    `origin/main` HEAD の commit SHA を採用し、`setup.sh` / docs に「release ごとに本 SHA を bump する」
    maintainer note を併記する。`IDD_CODEX_BRANCH` / `IDD_CODEX_REPO_URL` override は名称・挙動を変えず温存。
  - checksum artifacts は本 PR では生成・提供しない（別 release 運用）。AC 1.5 は検証 path の docs 記載で満たす。
- 次アクション: 上記確定方針に従って `setup.sh` / README / QUICK-HOWTO / `security_medium_bootstrap_docs_test.sh` を実装する。

## 確認事項

（task 1 の人間判断は確定済み。残存する確認事項なし）
