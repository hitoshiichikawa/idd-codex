# Implementation Notes

## Summary

Stage A fallback の mode ログ出力で、全角閉じ括弧の直前にある `MODE` 展開を `${MODE}` 形式に修正した。
これにより `set -u` 下でも mode 変数境界が明示され、`impl` / `impl-resume` の値をログへ維持する。

## Test Cases

- `local-watcher/test/stagea_mode_log_nounset_test.sh`
  - 過去の `$MODE）` 表現を unsafe として検出する。
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
| 3.2 | 同上 | shell-level regression test | `historical $MODE） expression is detected as unsafe` | `bash local-watcher/test/stagea_mode_log_nounset_test.sh` PASS | Linux bash では実行時再現に差があるため、過去表現の静的検出で regression を固定。 |
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

## Reviewer Round 1 Corrective Analysis

### Finding Closure Matrix

| Target requirement | Category | Required Action | Fix commit | Test/assertion | Verification result | Notes / no-change reason |
|--------------------|----------|-----------------|------------|----------------|---------------------|--------------------------|
| 3.2 | missing test / requirements contradiction | historical unsafe expression を nounset shell で実行し、unbound variable failure を非 0 exit / stderr で assert する。対象 bash で `$MODE）` が実際には failure にならない場合は AC 3.2 の前提を PM に差し戻す。 | N/A | N/A | `bash -c 'set -u; MODE=impl; echo "--- Stage A 実行（$MODE）---"'` は rc=0 / stdout `--- Stage A 実行（impl）---` / stderr empty。`LC_ALL=C` でも rc=0。比較として `$MODE_suffix` は rc=127 / `MODE_suffix: unbound variable`。 | GNU bash 5.2.21 では全角閉じ括弧 `）` は shell 変数名の一部として扱われず、`$MODE）` は `MODE` の正常展開になる。Reviewer Required Action の前提が実行環境と矛盾するため、失敗を assert する回帰テストを追加すると虚偽のテストになる。 |

## Partial Halt Reason

Reviewer Finding 1 の Required Action は、AC 3.2 が要求する「historical `$MODE）` expression が nounset で unbound variable failure になる」ことを実行時テストで立証する内容だが、対象環境の GNU bash 5.2.21 では `MODE=impl` 設定時の `$MODE）` は rc=0 で正常に `impl` を出力する。`LC_ALL=C` にしても同じ結果であり、全角閉じ括弧は変数名に含まれない。

一方、`$MODE_suffix` のように ASCII の変数名継続文字が隣接する場合は rc=127 で `MODE_suffix: unbound variable` が発生するため、nounset の境界問題そのものは確認できる。今回の AC 3.2 は「全角区切りの historical expression が unbound variable failure を起こす」という前提が bash の実挙動と矛盾しており、Developer が要件を変更せずに満たせない。PM に AC 3.2 の期待値を「静的検出」または「ASCII 隣接での nounset failure 検出」へ修正するか、実際に failure した shell / locale / expression を特定してもらう必要がある。

## Pending Tasks

- [ ] AC 3.2 の historical unsafe mode-log expression に対する期待結果を PM が再定義する。
- [ ] 再定義された AC 3.2 に対応する shell-level regression test を追加または更新する。

## 確認事項

- AC 3.2 の「historical `$MODE）` expression が nounset で unbound variable failure になる」という前提は、GNU bash 5.2.21 では再現しない。要件側で期待する shell / locale / expression の具体化が必要。

STATUS: partial_blocked
