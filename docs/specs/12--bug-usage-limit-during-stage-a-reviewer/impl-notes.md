# Issue #12 実装ノート

## 実装概要

- `qa_detect_rate_limit` に `usage_limit_fatal` 検出を追加し、Codex CLI の `You've hit your usage limit ... try again at ...` message を quota-aware wrapper で扱えるようにした。
- `qa_run_codex_stage` で usage-limit fatal の reset 時刻を epoch 化できた場合のみ exit `99` sentinel に変換し、既存の `qa_handle_quota_exceeded` 経路へ接続した。
- reset 時刻を抽出できない usage-limit 風 fatal は、人間決定 Option B に従い codex rc を透過して既存の `codex-failed` 経路へ委譲する。
- `qa_run_codex_stage` を通る Triage / Stage A / Reviewer / Debugger 後 Reviewer / Stage C / per-task loop は、個別 call site を増やさず同じ分類を受ける。
- PR Reviewer Processor には専用の usage-limit reset 検出、`pr-reviewer-<PR番号>` state key、`idd-codex:pr-reviewer-quota-wait` marker、専用 resume を追加した。
- PR Iteration Processor は PR Reviewer quota marker 付き PR を自身の quota resume では処理しないため、PR Reviewer 由来の wait が誤って `codex-needs-iteration` に戻らない。
- README に usage-limit fatal の検出条件、reset 時刻なしの扱い、PR Reviewer quota wait / resume の挙動を追記した。

## 検証

- `bash local-watcher/test/qa_detect_rate_limit_test.sh`
- `bash local-watcher/test/qa_run_codex_stage_test.sh`
- `bash local-watcher/test/pr_reviewer_quota_marker_test.sh`
- `shellcheck local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/modules/quota-aware.sh local-watcher/bin/modules/pr-reviewer.sh local-watcher/bin/modules/pr-iteration.sh local-watcher/test/qa_detect_rate_limit_test.sh local-watcher/test/qa_run_codex_stage_test.sh local-watcher/test/pr_reviewer_quota_marker_test.sh`

## Reviewer round=1 指摘対応

- Finding 1 対応として、`qa_run_codex_stage_test.sh` に Stage A / Reviewer round=1 / Debugger 後 Reviewer round=3 / Triage の usage-limit fatal を `qa_handle_quota_exceeded` へ接続する結合テストを追加した。各ケースで `codex-needs-quota-wait` 付与、`codex-failed` 不付与、`mark_issue_failed` 未呼び出し、reset epoch 永続化を検証する。
- Finding 2 対応として、`pr_reviewer_quota_marker_test.sh` に `pr_run_review_for_pr` の PR Reviewer command 非ゼロ終了 fixture を追加し、stderr の usage-limit fatal から reset epoch を抽出して `codex-needs-quota-wait` に退避すること、`pr-reviewer-<PR番号>` key へ reset epoch を保存すること、`exec-failed` コメントを投稿しないことを検証する。

## 確認事項

- reset 時刻なし usage-limit 風 fatal は Issue コメントの人間回答「Bで」に従い、quota wait ではなく既存失敗扱いにしている。
- reset 時刻なしの 529 Overloaded は既存の可視化 detector を維持し、usage-limit quota wait へは誤分類しない。
