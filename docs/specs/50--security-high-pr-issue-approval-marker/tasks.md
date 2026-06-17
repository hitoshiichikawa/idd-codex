# Implementation Plan

- [x] 1. 4-C Path Overlap marker loader を信頼済み著者コメント限定にする
- [x] 1.1 `po_load_edit_paths` の抽出順序を author filter → marker extraction → JSON validation に変更し、同じタスク内で 4-C regression test を追加する
  - `gh issue view "$issue_number" --repo "$REPO" --json comments` の 1 回呼び出し契約を維持する
  - `.comments[]` を `author_association` の信頼集合で先に filter する
  - marker 抽出は jq 内で完結させ、コメント本文を `sed` に渡さない
  - 信頼済みコメント内の複数 marker は従来どおり最後勝ちにする
  - API failure / marker 不在 / jq failure / JSON 不正時は `[]` を返し、return code 0 を維持する
  - `local-watcher/test/po_load_edit_paths_trusted_authors_test.sh` を追加し、信頼済み marker 採用、未信頼 marker 無視、未信頼最後勝ち防止、信頼済み marker 不在時 `[]`、不正 JSON / array 以外 / 非文字列要素の fail-safe を検証する
  - `PATH_OVERLAP_CHECK=true` gate 自体は変更しないことを確認する
  - 新規 env var、ラベル、exit code、cron / launchd 前提を追加・変更しない
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 2.1, 2.2, 2.3, 2.4, 4.1, 4.4, NFR 1.1, NFR 1.2, NFR 2.2, NFR 3.1_

- [x] 2. 4-A / 4-B の既存修正を regression として固定する (P)
  - `local-watcher/test/merge_queue_approval_signal_test.sh` を実行対象に含め、未信頼 approve / iteration / reject marker が approval / control signal にならないことを確認する
  - `local-watcher/test/pi_general_filter_untrusted_authors_test.sh` を実行対象に含め、未信頼一般コメントが PR Iteration prompt 入力候補から除外されることを確認する
  - 必要な場合のみ、既存テストに `VERDICT: approve` 偽造または prompt injection 風コメントの明示ケースを追加する
  - 4-A / 4-B の production code は原則変更しない
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 4.2, 4.3, 4.4, NFR 2.1, NFR 3.2_
  - _Boundary: MergeQueueApprovalResolver, PRIterationGeneralCommentFilter, SecurityRegressionTests_

- [x] 3. README に #50 4-C のセキュリティ修正範囲を追記する (P)
  - 既存 #50 migration note または Path Overlap Checker (Phase E) の説明へ、`edit-paths-json` marker が信頼済み `author_association` のコメントからのみ採用されることを追記する
  - 新規 env var は追加しない前提のため、オプション機能一覧には新項目を追加しない
  - `PATH_OVERLAP_CHECK` の opt-in / off semantics が変わらないことを明記する
  - _Requirements: 4.4_
  - _Boundary: SecurityDocumentation_
  - _Depends: 1.1_

- [ ] 4. 静的解析と関連 shell tests を通す
  - `shellcheck --severity=warning` を変更対象 shell script と関連 test に対して実行する
  - 4-C 新規 test、4-A 既存 regression test、4-B 既存 regression test を実行する
  - 失敗があれば production code または test fixture を修正し、未信頼 marker が採用されない性質を保つ
  - _Requirements: 3.5, 4.4, NFR 2.1, NFR 2.2_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを以下の構造化ブロックで宣言する。

<!-- stage-a-verify -->
```sh
shellcheck --severity=warning local-watcher/bin/idd-codex-modules/promote-pipeline.sh local-watcher/bin/idd-codex-modules/merge-queue.sh local-watcher/bin/idd-codex-modules/pr-iteration.sh local-watcher/test/po_load_edit_paths_trusted_authors_test.sh local-watcher/test/merge_queue_approval_signal_test.sh local-watcher/test/pi_general_filter_untrusted_authors_test.sh &&
  bash local-watcher/test/po_load_edit_paths_trusted_authors_test.sh &&
  bash local-watcher/test/merge_queue_approval_signal_test.sh &&
  bash local-watcher/test/pi_general_filter_untrusted_authors_test.sh
```
