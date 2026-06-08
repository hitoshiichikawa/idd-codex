# Implementation Plan

- [x] 1. PR Reviewer の approve verdict と formal review fallback を実装する
  - `pr_detect_approval_keyword` と `pr_resolve_review_verdict` を追加し、`VERDICT: approve` / `VERDICT: codex-needs-iteration` / 混在 / none を区別する
  - approve verdict のときだけ `pr_try_post_formal_approval` で `gh pr review --approve` を試行する
  - formal review 投稿失敗は WARN として扱い、既存 review comment + marker 投稿を継続する
  - `kind=review` の `(sha, kind)` 重複抑止と current head SHA 更新時の再レビュー挙動を維持する
  - 既存 env var / label / cron / exit code 契約と GitHub API failure 時の安全側挙動を維持する
  - _Requirements:_ 1.1, 1.2, 1.3, 2.1, 2.2, 2.3, 2.4, 4.3, 4.4, 6.5
  - _Boundary:_ PR Reviewer Verdict Parser, Formal Review Submitter, PR Reviewer Marker Writer

- [x] 2. Merge Queue の approval resolver を追加する
  - `reviewDecision == "APPROVED"` を従来どおり approved とする helper を作る
  - current head SHA の PR Reviewer comment marker と `VERDICT: approve` を parse して marker approval として扱う
  - old-SHA approve marker、current-SHA iteration / reject marker、malformed marker、comments API failure は approved にしない
  - helper stdout は `approved|github` / `approved|idd-codex-marker` / `rejected|...` / `unknown|...` のような機械可読 record にする
  - GitHub API failure 時は WARN + not-approved とし、merge しない
  - _Requirements:_ 1.4, 3.1, 3.2, 3.3, 4.1, 4.2, 4.4, 5.1, 6.1, 6.2, 6.3, 6.4
  - _Boundary:_ Merge Queue Approval Resolver
  - _Depends:_ 1

- [x] 3. Merge Queue main / recheck の candidate selection を approval resolver に接続する
  - `gh pr list` の取得 fields に `headRefOid` を追加し、`review:approved` だけに依存しない候補集合へ変更する
  - draft、`codex-needs-rebase`、`codex-failed`、head pattern、fork 除外を client-side filter として維持する
  - `process_merge_queue` と `process_merge_queue_recheck` が同じ approval resolver semantics を使うようにする
  - approval source をサイクルログまたは PR ごとのログに出す
  - 既存 env var / label / cron / exit code 契約と opt-out 挙動を維持する
  - _Requirements:_ 3.1, 3.2, 3.4, 3.5, 5.1
  - _Boundary:_ Merge Queue Candidate Fetcher, Merge Queue Approval Resolver
  - _Depends:_ 2

- [x] 4. regression tests を追加する
  - `local-watcher/test/pr_reviewer_approval_signal_test.sh` を追加し、approve / iteration / mixed verdict と formal review success / failure fallback を mock で検証する
  - `local-watcher/test/merge_queue_approval_signal_test.sh` を追加し、formal review approval、current-SHA approve marker、old-SHA approve marker、current-SHA iteration / reject marker、comments API failure を検証する
  - 既存 `pr_reviewer_quota_marker_test.sh` の関数抽出 pattern を踏襲し、実 GitHub API には接続しない
  - API failure safe-side も regression として固定する
  - _Requirements:_ 1.1, 1.2, 1.3, 2.3, 2.4, 3.1, 3.2, 3.3, 4.1, 4.2, 6.1, 6.2, 6.3, 6.4, 6.5
  - _Boundary:_ Regression Tests
  - _Depends:_ 1, 2, 3

- [x] 5. README の PR Reviewer / Merge Queue 連携説明を更新する
  - PR Reviewer approve は formal review 投稿を試みることを説明する
  - formal review が使えない場合は current-SHA idd-codex approve marker を Merge Queue が承認 signal として扱うことを説明する
  - stale SHA approve、iteration / reject marker、API failure は merge 対象外であることを説明する
  - 既存 opt-in / opt-out env、label 名、cron 契約が変わらないことを明記する
  - _Requirements:_ 5.2, 5.3, 5.4
  - _Boundary:_ README Updates
  - _Depends:_ 1, 2, 3

## Verify

本 spec の実装後、watcher が再実行すべき verify コマンドを以下の構造化ブロックで宣言する。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/idd-codex-modules/pr-reviewer.sh local-watcher/bin/idd-codex-modules/merge-queue.sh install.sh setup.sh .github/scripts/*.sh &&
  diff -r .codex/agents repo-template/.codex/agents &&
  diff -r .codex/rules repo-template/.codex/rules &&
  bash local-watcher/test/pr_reviewer_approval_signal_test.sh &&
  bash local-watcher/test/merge_queue_approval_signal_test.sh
```
