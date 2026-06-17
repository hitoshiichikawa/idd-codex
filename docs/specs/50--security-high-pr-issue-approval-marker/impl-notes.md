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
- 重要な判断: 回帰テストは trusted / untrusted 混在、未信頼最後勝ち防止、marker 不在、JSON 不正、array 以外、非文字列要素除外、API / jq failure を task 1.1 の範囲で固定している。
- 残存課題: なし。
