# Implementation Notes

### Task 1

- `po_load_edit_paths` は `author_association` が `OWNER` / `MEMBER` / `COLLABORATOR` のコメントだけを信頼し、その後に jq 内で `edit-paths-json` marker を抽出する方針にした。
- 未信頼コメント本文を `sed` / `eval` / `bash -c` に渡さないため、marker 抽出と JSON 検証を jq に寄せた。複数 marker は信頼済みコメント内でのみ最後勝ちを維持し、array 内の非文字列要素は除外する。
- API failure、marker 不在、jq failure、JSON 不正、array 以外は従来どおり stdout `[]` / return 0 に倒す。新規 env var や gate 条件は追加していない。
- 残存課題はなし。4-A / 4-B の production code と README は本 task の所有範囲外のため変更していない。
