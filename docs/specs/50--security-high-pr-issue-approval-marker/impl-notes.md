# Implementation Notes

## Implementation Notes

### Task 1

- `po_load_edit_paths` は `author_association` が `OWNER` / `MEMBER` / `COLLABORATOR` のコメントだけを信頼し、その後に jq 内で `edit-paths-json` marker を抽出する方針にした。
- 未信頼コメント本文を `sed` / `eval` / `bash -c` に渡さないため、marker 抽出と JSON 検証を jq に寄せた。複数 marker は信頼済みコメント内でのみ最後勝ちを維持し、array 内の非文字列要素は除外する。
- API failure、marker 不在、jq failure、JSON 不正、array 以外は従来どおり stdout `[]` / return 0 に倒す。新規 env var や gate 条件は追加していない。
- 残存課題はなし。4-A / 4-B の production code と README は本 task の所有範囲外のため変更していない。

### Task 1.1

- 採用方針: `po_load_edit_paths` は信頼済み `author_association` のコメントだけを jq 内で抽出対象にし、`edit-paths-json` marker の最後勝ちは信頼済みコメント集合内に限定する。
- 重要な判断: GitHub comments API 呼び出しは 1 回のまま維持し、未信頼コメント body を `sed` などの shell text filter に渡さない実装を確認した。
- 重要な判断: jq filter は `safe_comments` / `trusted_author` / `comment_body` に分け、信頼集合判定と未信頼 body 非参照を range 内で再確認できる形にした。
- 重要な判断: 回帰テストは trusted / untrusted 混在、未信頼最後勝ち防止、marker 不在、JSON 不正、array 以外、非文字列要素除外、API / jq failure、大小文字正規化、非文字列 body、comments 非配列を task 1.1 の範囲で固定している。
- Finding Closure Matrix:
  - Finding 1 / AC 未カバー / Target: 1.1-1.5, 2.1-2.4, 4.1, 4.4, NFR 1.1, NFR 1.2, NFR 3.1 / 変更: `local-watcher/bin/idd-codex-modules/promote-pipeline.sh` / テスト: verify block 全体 / status: closed
  - Finding 2 / missing test / Target: NFR 2.2 / 変更: `local-watcher/test/po_load_edit_paths_trusted_authors_test.sh` / テスト: `bash local-watcher/test/po_load_edit_paths_trusted_authors_test.sh` / status: closed
- 残存課題: なし。

### Task 2

- 採用方針: 4-A / 4-B の production code は変更せず、既存 regression test に未信頼 marker / prompt injection 風コメントの明示ケースを追加して固定した。
- 重要な判断: 4-A regression は `merge_queue_approval_signal_test.sh` に未信頼 `approve` 偽造が既にあったため、未信頼 `codex-needs-iteration` と `reject` marker の単独ケースを追加し、approval signal だけでなく control signal にもならないことを固定した。
- 重要な判断: 4-B regression は `pi_general_filter_untrusted_authors_test.sh` に prompt injection 風の未信頼一般コメントを追加し、PR Iteration prompt 入力候補から除外されることを明示した。
- 重要な判断: 既存 env var、ラベル、exit code、cron / launchd 前提は変更していない。
- 検証結果: `shellcheck --severity=warning local-watcher/bin/idd-codex-modules/merge-queue.sh local-watcher/bin/idd-codex-modules/pr-iteration.sh local-watcher/test/merge_queue_approval_signal_test.sh local-watcher/test/pi_general_filter_untrusted_authors_test.sh`、`bash local-watcher/test/merge_queue_approval_signal_test.sh`、`bash local-watcher/test/pi_general_filter_untrusted_authors_test.sh` はすべて成功した。
- 残存課題: なし。
