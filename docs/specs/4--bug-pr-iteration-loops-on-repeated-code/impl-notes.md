# Implementation Notes

## 実装内容

- PR Iteration の Codex 非 0 終了ログから usage-limit 風 fatal error を検出する処理を追加した。
- reset 時刻を抽出できた場合は PR に `codex-needs-quota-wait` を付与し、`codex-needs-iteration` を除去する。
- reset 時刻を `quota-reset-times.json` の `pr-<PR番号>` key に永続化し、PR Iteration サイクル冒頭で reset + grace 経過済み PR を `codex-needs-iteration` に戻す resume 処理を追加した。
- reset 時刻を抽出できない usage-limit 風 fatal error は `PR_ITERATION_USAGE_FATAL_RETRY_LIMIT`（既定 1）で有界化し、上限到達時に `codex-needs-decisions` へ退避する。
- 同一 PR・同一 round の `idd-codex:pr-iteration-processing round=N` marker が既存コメントにある場合、round 開始コメントを再投稿しないようにした。
- PR Iteration 候補検索から `codex-needs-quota-wait` / `codex-needs-decisions` 付き PR を除外した。
- `codex-needs-quota-wait` のラベル説明と README を Issue/PR 共用の意味に更新した。

## テスト

```bash
bash local-watcher/test/pi_usage_limit_fatal_test.sh
bash local-watcher/test/pi_detect_quota_soft_fail_test.sh
bash local-watcher/test/pi_no_progress_transition_test.sh
bash local-watcher/test/pi_general_filter_self_test.sh
shellcheck local-watcher/bin/*.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh
bash -n local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/modules/pr-iteration.sh .github/scripts/idd-codex-labels.sh local-watcher/test/pi_usage_limit_fatal_test.sh
```

結果: すべて成功。

## 確認事項

- 追加の人間判断待ちはなし。
- reset メッセージの timezone は Codex CLI 表示に timezone が含まれないため、watcher 実行環境のローカル timezone として `date` で解釈する。
