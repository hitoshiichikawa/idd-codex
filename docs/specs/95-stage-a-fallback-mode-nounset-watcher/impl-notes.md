# Implementation Notes

## Summary

Stage A fallback の mode ログ出力で、全角閉じ括弧の直前にある `MODE` 展開を `${MODE}` 形式に修正した。
これにより `set -u` 下でも mode 変数境界が明示され、`impl` / `impl-resume` の値をログへ維持する。

## Test Cases

- `local-watcher/test/stagea_mode_log_nounset_test.sh`
  - 過去の `$MODE）` 表現を unsafe として検出する。
  - 過去の `$MODE）` 表現を `set -u` / `MODE=impl` で実評価し、runtime failure が再現する bash では記録し、再現しない bash では静的 unsafe 検出を authoritative として扱う。
  - `set -u` 下で `${MODE}）` が `impl` / `impl-resume` を保持して成功する。
  - watcher source に Stage A fallback の unsafe `$VAR）` が残っていないことを確認する。
  - Stage A-PM requirements-definition path がログ修正後も到達可能なまま残っていることを確認する。
- `local-watcher/test/stagea_pm_split_test.sh`
  - 既存の Stage A PM split on/off と mode 別 prompt 経路が壊れていないことを確認する。

## AC Coverage Matrix

| Requirement / AC | Implementation path | Production entrypoint / owning flow | Test / assertion | Verification result | Notes |
|------------------|---------------------|-------------------------------------|------------------|---------------------|-------|
| 1.1 | `local-watcher/bin/idd-codex-issue-watcher.sh` `run_impl_pipeline` Stage A fallback log | watcher `run_impl_pipeline` Stage A fallback | `watcher source braces Stage A mode expansion before multibyte delimiter`; `braced ${MODE}） expression succeeds under nounset` | `bash local-watcher/test/stagea_mode_log_nounset_test.sh` PASS | 全角閉じ括弧直前を `${MODE}` に修正。 |
| 1.2 | 同上 | 同上 | `braced ${MODE}） expression succeeds under nounset` | `bash local-watcher/test/stagea_mode_log_nounset_test.sh` PASS | 変数境界を brace で明示。 |
| 1.3 | 同上 | 同上 | `braced expression preserves impl mode` | `bash local-watcher/test/stagea_mode_log_nounset_test.sh` PASS | `impl` 値をログ文字列内に保持。 |
| 1.4 | 同上 | 同上 | `braced expression preserves impl-resume mode` | `bash local-watcher/test/stagea_mode_log_nounset_test.sh` PASS | `impl-resume` 値をログ文字列内に保持。 |
| 2.1 | 同上 | watcher `run_impl_pipeline` Stage A fallback から既存 Stage A 実行 flow | `Stage A-PM requirements-definition path remains reachable after mode log`; `stagea_pm_split_test.sh` 全 assertion | `bash local-watcher/test/stagea_mode_log_nounset_test.sh` PASS; `bash local-watcher/test/stagea_pm_split_test.sh` PASS | ログ行以外の Stage A flow は変更なし。 |
| 2.2 | 同上 | `STAGE_A_PM_SPLIT_ENABLED=true` の impl Stage A-PM flow | `Stage A-PM requirements-definition path remains reachable after mode log`; `StageA (impl, split on) → developer のみ`; `impl-pm: requirements.md を保存` | `bash local-watcher/test/stagea_mode_log_nounset_test.sh` PASS; `bash local-watcher/test/stagea_pm_split_test.sh` PASS | PM split の opt-out semantics は変更なし。 |
| 2.3 | 同上 | Stage A fallback log 後の既存 failure handling | `Stage A-PM requirements-definition path remains reachable after mode log` | `bash local-watcher/test/stagea_mode_log_nounset_test.sh` PASS | failure handling 本体は未変更。 |
| 2.4 | 同上 | watcher Stage A fallback | `watcher source braces Stage A mode expansion before multibyte delimiter` | `bash local-watcher/test/stagea_mode_log_nounset_test.sh` PASS | stale 原因だった mode log 境界のみ修正。 |
| 3.1 | `local-watcher/test/stagea_mode_log_nounset_test.sh` | shell-level regression test | `braced ${MODE}） expression succeeds under nounset` | `bash local-watcher/test/stagea_mode_log_nounset_test.sh` PASS | `set -u` shell で検証。 |
| 3.2 | 同上 | shell-level regression test | `historical $MODE） expression is detected as unsafe`; runtime probe is informational when this bash does not reproduce nounset failure | `bash local-watcher/test/stagea_mode_log_nounset_test.sh` PASS | 人間判断により、GNU bash 5.2 系で runtime failure が再現しない場合でも `$MODE）` の静的 unsafe 検出と `${MODE}）` の source 要求を portable な正本とした。 |
| 3.3 | 同上 | shell-level regression test | `braced expression preserves impl mode`; `braced expression preserves impl-resume mode` | `bash local-watcher/test/stagea_mode_log_nounset_test.sh` PASS | corrected behavior の出力値を確認。 |
| 3.4 | 同上 | Stage A PM split / fallback logging regression | `Stage A-PM requirements-definition path remains reachable after mode log` | `bash local-watcher/test/stagea_mode_log_nounset_test.sh` PASS | PM requirements-definition path の存在を確認。 |
| 3.5 | 同上 | watcher source scan | `watcher source braces Stage A mode expansion before multibyte delimiter` | `bash local-watcher/test/stagea_mode_log_nounset_test.sh` PASS | Stage A logging-adjacent の `$VAR）` を検出対象化。 |
| 3.6 | changed shell files | shellcheck static check | `shellcheck local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/test/stagea_mode_log_nounset_test.sh` | PASS | 変更 shell file の静的検査。 |
| 4.1 | `run_impl_pipeline` Stage A fallback log | watcher Stage A fallback | 差分確認 | `git diff --check` PASS | env var 名、label 名、exit code 意味、cron / launchd invocation は未変更。 |
| 4.2 | `run_impl_pipeline` Stage A PM split condition | watcher Stage A PM split | `stagea_pm_split_test.sh` 全 assertion | `bash local-watcher/test/stagea_pm_split_test.sh` PASS | `STAGE_A_PM_SPLIT_ENABLED` の既存条件は未変更。 |
| 4.3 | N/A | N/A | 差分確認 | `git diff --check` PASS | 新しい外部サービス呼び出しなし。 |
| 4.4 | N/A | N/A | 差分確認 | `git diff --check` PASS | operator documentation が必要な挙動変更ではなく、既存 Stage A ログの安全化のみ。 |
| NFR 1.1 | `run_impl_pipeline` Stage A fallback log | watcher Stage A fallback | `braced expression preserves impl mode`; `braced expression preserves impl-resume mode` | `bash local-watcher/test/stagea_mode_log_nounset_test.sh` PASS | stage と current mode を含む既存ログ形式を維持。 |
| NFR 1.2 | `run_impl_pipeline` Stage A fallback log | watcher Stage A fallback | `Stage A-PM requirements-definition path remains reachable after mode log` | `bash local-watcher/test/stagea_mode_log_nounset_test.sh` PASS | mode log 自体で停止しないため、以降の failure evidence へ到達可能。 |
| NFR 2.1 | `run_impl_pipeline` Stage A fallback log | watcher Stage A fallback | 差分確認 | `git diff --check` PASS | cron / launchd 設定変更なし。 |
| NFR 2.2 | `run_impl_pipeline` Stage A fallback log | watcher Stage A fallback | 差分確認 | `git diff --check` PASS | 新規 runtime dependency なし。 |

## Verification

- `bash local-watcher/test/stagea_mode_log_nounset_test.sh` → PASS
- `bash local-watcher/test/stagea_pm_split_test.sh` → PASS
- `shellcheck local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/test/stagea_mode_log_nounset_test.sh` → PASS
- `git diff --check` → PASS

## Reviewer Round 1 Corrective Rework

### Finding Closure Matrix

| Target requirement | Category | Required Action | Fix commit | Test/assertion | Verification result | Notes / no-change reason |
|--------------------|----------|-----------------|------------|----------------|---------------------|--------------------------|
| 4.1 | AC 未カバー | #95 と無関係に削除されていた `FULL_AUTO_ENABLED` / `full_auto_enabled` / startup log / README 行 / `local-watcher/test/full_auto_kill_switch_test.sh` を main と同等に復元する。 | `fix(watcher): Stage A mode log是正範囲を絞る` | `bash local-watcher/test/full_auto_kill_switch_test.sh` | PASS | base 比較で #95 の watcher 差分は Stage A mode log の `${MODE}` 化のみになった。 |
| 3.2 | missing test / requirement clarification | Issue 本文更新後の人間判断に合わせ、historical unsafe expression の runtime failure を全 bash で必須にせず、`$MODE）` の静的検出と `${MODE}）` source 要求で再導入を防ぐ。 | `docs(watcher): align #95 AC 3.2 with human decision` | `historical $MODE） expression is detected as unsafe`; `watcher source braces Stage A mode expansion before multibyte delimiter` | PASS: `bash local-watcher/test/stagea_mode_log_nounset_test.sh` | macOS bash 3.2.57 では runtime failure が再現する一方、GNU bash 5.2 系では再現しないため、portable requirement は source-level safety とする。 |

### Verification

- `bash local-watcher/test/full_auto_kill_switch_test.sh` → PASS
- `bash local-watcher/test/stagea_mode_log_nounset_test.sh` → PASS
- `shellcheck local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/test/stagea_mode_log_nounset_test.sh local-watcher/test/full_auto_kill_switch_test.sh` → PASS
- `git diff main -- local-watcher/bin/idd-codex-issue-watcher.sh` → Stage A fallback log の `${MODE}` 化のみ

## Human Decision Follow-up

Issue 本文の AC は、人間判断により「historical `$MODE）` が全 bash で runtime failure になる」前提を要求しない形へ更新済み。
macOS `/bin/bash` 3.2.57 + `LC_ALL=C.UTF-8` では runtime failure が再現するが、GNU bash 5.2 系では `$MODE）` が正常展開される環境差がある。
このため本 branch では `$MODE）` の静的 unsafe 検出と watcher source の `${MODE}）` 化を portable な完了条件とした。

STATUS: complete
