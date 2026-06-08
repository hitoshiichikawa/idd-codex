# Implementation Notes

### Task 1

- 採用方針: PR Reviewer 出力の `VERDICT` を構造化し、approve の場合だけ GitHub formal review を試行してから既存 marker comment を残す。
- 重要な判断: formal review 失敗は watcher cycle の失敗にせず、stderr 抜粋付き WARN として marker fallback を継続する。
- 重要な判断: approve と `codex-needs-iteration` が混在した場合は conflict として iteration label を優先し、approve signal は公開しない。
- 残存課題: Merge Queue 側はまだ marker approval を消費しないため、task 2 / 3 で current-SHA marker resolver と candidate selection へ接続する必要がある。

### Task 2

- 採用方針: Merge Queue 側に `mq_resolve_approval_signal` を追加し、GitHub `reviewDecision == "APPROVED"` と current-SHA PR Reviewer marker approval を同じ機械可読 record で返す。
- 重要な判断: current SHA の `VERDICT: codex-needs-iteration` / `VERDICT: reject` 系は approve より優先して `rejected|iteration-marker` とし、old-SHA approve は `rejected|stale-marker` に固定した。
- 重要な判断: comments API failure と marker JSON parse failure は WARN + `unknown|api-error` + rc=1 とし、後段が接続されても merge へ進まない契約にした。
- 残存課題: task 3 で main / recheck の candidate selection を resolver に接続し、task 4 で regression test を追加する必要がある。
