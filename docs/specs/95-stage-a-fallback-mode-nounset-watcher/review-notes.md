# Review Notes

<!-- idd-codex:review round=2 model=gpt-5.5 timestamp=2026-06-22T12:03:09Z -->

## Reviewed Scope

- Branch: codex/issue-95-impl-stage-a-fallback-mode-nounset-watcher
- HEAD commit: 165be80abd826019aa435542ff8539ad09d8328a
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `local-watcher/bin/idd-codex-issue-watcher.sh:7571` が Stage A fallback log の mode 展開を `${MODE}` にしており、`local-watcher/test/stagea_mode_log_nounset_test.sh:76` で nounset 成功を検証。
- 1.2 — `local-watcher/bin/idd-codex-issue-watcher.sh:7571` の brace 境界と `local-watcher/test/stagea_mode_log_nounset_test.sh:86` の source scan が、multibyte delimiter 直前の意図しない変数名拡張を防止。
- 1.3 — `local-watcher/test/stagea_mode_log_nounset_test.sh:77` が `impl` の Stage A log 値保持を検証。
- 1.4 — `local-watcher/test/stagea_mode_log_nounset_test.sh:83` と `:84` が `impl-resume` の nounset 成功と log 値保持を検証。
- 2.1 — `main..HEAD` の watcher 実動作差分は Stage A mode log の `${MODE}` 化のみで、`bash local-watcher/test/stagea_pm_split_test.sh` が既存 Stage A flow 継続を PASS。
- 2.2 — `local-watcher/bin/idd-codex-issue-watcher.sh:7575` 以降の Stage A PM split 分岐は維持され、`local-watcher/test/stagea_mode_log_nounset_test.sh:92` と `stagea_pm_split_test.sh` が PM requirements-definition path 到達性を検証。
- 2.3 — mode log 行は nounset で停止しないことを `stagea_mode_log_nounset_test.sh` で確認し、既存 Stage A failure handling 本体は差分対象外。
- 2.4 — `local-watcher/test/stagea_mode_log_nounset_test.sh:86` の watcher source scan が Stage A mode logging 由来の unsafe source 再混入を検出。
- 3.1 — `local-watcher/test/stagea_mode_log_nounset_test.sh:72` から `:76` が nounset shell 環境で multibyte delimiter 直前の braced mode 展開を検証。
- 3.2 — `local-watcher/test/stagea_mode_log_nounset_test.sh:48` から `:66` が historical `$MODE）` 表現を unsafe として検出し、runtime failure は bash 差分に依存する情報として扱う。
- 3.3 — `local-watcher/test/stagea_mode_log_nounset_test.sh:77` と `:84` が corrected mode text emitted を検証。
- 3.4 — `local-watcher/test/stagea_mode_log_nounset_test.sh:92` が Stage A-PM requirements-definition path の到達性を確認。
- 3.5 — `local-watcher/test/stagea_mode_log_nounset_test.sh:86` が watcher shell source の Stage A logging-adjacent unsafe `$VAR）` 残存を検出対象化。
- 3.6 — `shellcheck local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/idd-codex-modules/pr-reviewer.sh local-watcher/test/stagea_mode_log_nounset_test.sh local-watcher/test/pr_publish_commit_status_test.sh` を再実行し PASS。
- 4.1 — round=1 Finding の `PR_REVIEWER_STATUS_CHECK_ENABLED` / status publish 契約削除は復元済みで、`rg` と `bash local-watcher/test/pr_publish_commit_status_test.sh` により既存 env var・関数・README 行・テストの維持を確認。
- 4.2 — `STAGE_A_PM_SPLIT_ENABLED` 条件は差分対象外で、`bash local-watcher/test/stagea_pm_split_test.sh` が split on/off と mode 別 prompt 経路を PASS。
- 4.3 — `main..HEAD` に新規外部サービス呼び出し追加はなく、PR reviewer status publish は既存 opt-in 機能として復元されている。
- 4.4 — operator documentation が必要な Stage A 挙動変更はなく、README の既存 PR reviewer status publish 行は復元済み。
- NFR 1.1 — `local-watcher/bin/idd-codex-issue-watcher.sh:7571` が stage と current mode を含む既存 operator-visible log line を維持。
- NFR 1.2 — mode log 後の PM path 到達性を `local-watcher/test/stagea_mode_log_nounset_test.sh:92` で確認。
- NFR 2.1 — cron / launchd 設定変更を要求する差分なし。
- NFR 2.2 — 新規 runtime dependency 追加なし。

## Findings

なし

## Summary

round=1 の AC 4.1 reject 理由だった PR reviewer status publish 契約削除は復元され、関連テストも PASS しました。指定された `tasks.md` / `design.md` は存在しないため `_Boundary:_` 注釈による照合はできませんでしたが、確認できる `main..HEAD` 差分に AC 未カバー、missing test、boundary 逸脱は見つかりませんでした。

RESULT: approve
