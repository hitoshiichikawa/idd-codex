# Review Notes

## Summary

- round=1 独立レビューとして、`requirements.md`、`impl-notes.md`、差分、既存実装、追加テストを確認した。
- `tasks.md` は存在しないため、AC カバレッジは `requirements.md` と `main..HEAD` の差分・既存コードの突き合わせで判定した。
- `design.md` は存在しない。
- HEAD は指定コミット `46dba68315f5c7686dd52997559831c1dcd4597f` と一致している。

## Findings

なし。

AC 未カバー / missing test / boundary 逸脱のいずれにも該当する reject 要因は確認されなかった。

## AC Coverage

- Req 1: PR Iteration 中の usage-limit 風 fatal error は `pi_detect_usage_limit_fatal` で検出され、reset 時刻ありでは `codex-needs-quota-wait` 付与と `codex-needs-iteration` 除去、reset 時刻なしでは `PR_ITERATION_USAGE_FATAL_RETRY_LIMIT` による有界化後に `codex-needs-decisions` へ退避する実装がある。PR 専用 quota wait ラベルは追加されず、既存 `codex-needs-quota-wait` が再利用されている。
- Req 2: 同一 PR・同一 round の `idd-codex:pr-iteration-processing round=N` marker 既存確認が追加され、fatal error で round marker が更新されない場合も processing コメント再投稿が抑止される。
- Req 3: quota wait / decisions 退避時の PR コメントと WARN ログが追加され、`codex-failed` へ分類しない経路になっている。ラベル変更またはコメント投稿失敗時も WARN ログを残す。
- Req 4: 追加テスト `pi_usage_limit_fatal_test.sh` が reset あり / reset なし / 通常 fatal の検出と、同一 round processing コメント重複防止をカバーしている。

## Verification

```bash
git diff --stat main..HEAD
git log --oneline main..HEAD
bash local-watcher/test/pi_usage_limit_fatal_test.sh
bash local-watcher/test/pi_detect_quota_soft_fail_test.sh
bash local-watcher/test/pi_no_progress_transition_test.sh
bash local-watcher/test/pi_general_filter_self_test.sh
bash -n local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/modules/pr-iteration.sh .github/scripts/idd-codex-labels.sh local-watcher/test/pi_usage_limit_fatal_test.sh
shellcheck local-watcher/bin/*.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh
```

すべて成功。

RESULT: approve
