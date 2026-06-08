# Implementation Notes

### Task 1

- 採用方針: PR Reviewer 出力の `VERDICT` を構造化し、approve の場合だけ GitHub formal review を試行してから既存 marker comment を残す。
- 重要な判断: formal review 失敗は watcher cycle の失敗にせず、stderr 抜粋付き WARN として marker fallback を継続する。
- 重要な判断: approve と `codex-needs-iteration` が混在した場合は conflict として iteration label を優先し、approve signal は公開しない。
- 残存課題: Merge Queue 側はまだ marker approval を消費しないため、task 2 / 3 で current-SHA marker resolver と candidate selection へ接続する必要がある。
