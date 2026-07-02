# Implementation Notes

## 実装方針

Stage A Verify の既定境界は従来どおり `codex-sandbox` のまま維持し、新規 opt-in env
`STAGE_A_VERIFY_EXECUTION_BOUNDARY=host` を追加した。`host` 完全一致時のみ `tasks.md` 由来 verify
を watcher / cron ユーザー権限で直接実行する。未設定、空文字、typo、大文字違いはすべて
`codex-sandbox` に倒す。

iOS Simulator / Xcode の失敗診断は verify 出力を一時ファイルに捕捉して `$LOG` へ追記した後、
失敗時のみ CoreSimulator 代表エラーを検出して `DIAGNOSTIC` 行を出す方式にした。verify command
の exit code は既存の `FAILED exit=<code>` として残し、境界診断は別行で読めるようにした。

`xcodebuild ` を Stage A Verify の heuristic keyword に追加した。構造化 verify ブロックを持つ
repo は従来どおりブロック優先で、ブロックが無い場合のみ heuristic fallback として使われる。

## 変更ファイル

- `local-watcher/bin/idd-codex-modules/stage-a-verify.sh`
- `local-watcher/bin/idd-codex-issue-watcher.sh`
- `local-watcher/test/stage_a_verify_ios_boundary_test.sh`
- `local-watcher/test/stage_a_verify_sandbox_boundary_test.sh`
- `README.md`

## 検証結果

- `bash -n local-watcher/bin/idd-codex-modules/stage-a-verify.sh local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/test/stage_a_verify_ios_boundary_test.sh local-watcher/test/stage_a_verify_sandbox_boundary_test.sh` 成功
- `bash local-watcher/test/stage_a_verify_ios_boundary_test.sh` 成功（PASS=19 FAIL=0）
- `bash local-watcher/test/stage_a_verify_sandbox_boundary_test.sh` 成功（PASS=29 FAIL=0）
- `bash local-watcher/test/sav_timeout_pgkill_test.sh` 成功（PASS=4 FAIL=0）
- `bash local-watcher/test/stage_a_verify_round1_defer_test.sh` 成功（PASS=8 FAIL=0）
- `shellcheck --severity=warning local-watcher/bin/idd-codex-modules/stage-a-verify.sh local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/test/stage_a_verify_ios_boundary_test.sh local-watcher/test/stage_a_verify_sandbox_boundary_test.sh` 成功
- `shellcheck --severity=warning local-watcher/bin/*.sh local-watcher/bin/idd-codex-modules/*.sh install.sh setup.sh .github/scripts/*.sh` 成功
- `diff -r .codex/agents repo-template/.codex/agents` 差分なし
- `diff -r .codex/rules repo-template/.codex/rules` 差分なし

補足: `shellcheck local-watcher/bin/*.sh local-watcher/bin/idd-codex-modules/*.sh install.sh setup.sh .github/scripts/*.sh`
は既存 baseline の info（SC2329 / SC2016）で終了コード 1。warning 以上では成功。

## AC Coverage Matrix

| Requirement / AC | Implementation path | Production entrypoint / owning flow | Test / assertion | Verification result | Notes |
|------------------|---------------------|-------------------------------------|------------------|---------------------|-------|
| 1.1 | `stage-a-verify.sh` `_sav_repo_execution_boundary`, `stage_a_verify_run` | Stage A Verify の `tasks.md` 由来 verify 実行 | `stage_a_verify_ios_boundary_test.sh` case1/case2/case5 | `bash local-watcher/test/stage_a_verify_ios_boundary_test.sh` 成功 | `host` 完全一致で調整可能 |
| 1.2 | `stage-a-verify.sh` `_sav_run_repo_command_on_host` | `STAGE_A_VERIFY_EXECUTION_BOUNDARY=host` の Stage A Verify 実行 | case2 host marker / sandbox 未呼び出し | 同上 | host resource 到達は host 実行経路で担保 |
| 1.3 | `stage-a-verify.sh` `_sav_run_repo_command_on_host` | kuku_master 相当の `xcodebuild ... iPhone 17 test` verify | case2/case4/case5 | 同上 | 実機 Xcode E2E は scope 外。sandbox 境界を外す設定経路を検証 |
| 1.4 | `stage-a-verify.sh` `_sav_repo_execution_boundary`, `_sav_run_repo_command_in_codex_sandbox` | 未設定時の Stage A Verify | case1 default sandbox | 同上 | typo は case3 で sandbox fallback |
| 1.5 | `stage-a-verify.sh` `stage_a_verify_run` | `STAGE_A_VERIFY_ENABLED` とは別の verify 実行境界選択 | case2 / README | 同上 + README 更新 | gate opt-out と境界調整を分離 |
| 2.1 | `stage-a-verify.sh` `_sav_output_has_coresim_connection_failure`, `_sav_emit_ios_simulator_boundary_diagnostics` | Stage A Verify failure logging | case4 `DIAGNOSTIC kind=coresimulator-connection` | 同上 | exit code と別行で出力 |
| 2.2 | `stage-a-verify.sh` `_sav_output_has_coresim_permission_failure` | Stage A Verify failure logging | case4 `DIAGNOSTIC kind=coresimulator-permission` | 同上 | CoreSimulator + Operation not permitted を検出 |
| 2.3 | `stage-a-verify.sh` `_sav_cmd_uses_ios_simulator`, `_sav_output_has_ios_destination_failure` | iOS Simulator destination failure logging | case4 `DIAGNOSTIC kind=ios-simulator-destination` | 同上 | 通常シェルで見える前提は watcher では判定せず hint として出力 |
| 2.4 | `stage-a-verify.sh` `_sav_emit_ios_simulator_boundary_diagnostics` | round failure logging | case4 recovery hint | 同上 | `STAGE_A_VERIFY_EXECUTION_BOUNDARY=host` を提示 |
| 2.5 | `stage-a-verify.sh` result branch | Stage A Verify failure logging | case4 `FAILED exit=70` + `DIAGNOSTIC` | 同上 | exit と境界診断を分離 |
| 3.1 | `stage-a-verify.sh` `_sav_repo_execution_boundary` | 未設定 / typo 時の repository 由来 verify | case1/case3 | 同上 + `stage_a_verify_sandbox_boundary_test.sh` 成功 | 既存 sandbox / 解決順序 / round を維持 |
| 3.2 | `stage-a-verify.sh` Gate 1 | `STAGE_A_VERIFY_ENABLED=false` | 既存実装不変更 | shellcheck / 既存境界テスト成功 | 本変更では無効化経路に触れていない |
| 3.3 | `stage-a-verify.sh` `stage_a_verify_resolve_command` | `STAGE_A_VERIFY_COMMAND` operator override | `stage_a_verify_sandbox_boundary_test.sh` case4 | `bash local-watcher/test/stage_a_verify_sandbox_boundary_test.sh` 成功 | 直接実行 semantics を維持 |
| 3.4 | `stage-a-verify.sh` `_sav_repo_execution_boundary` | `tasks.md` 由来 verify 未設定時 | ios case1 / sandbox boundary case1,3 | 両テスト成功 | 非 sandbox 権限へ暗黙 fallback しない |
| 3.5 | `stage-a-verify.sh` failure return / `_SAV_LAST_OUTCOME` 不変更 | run-summary / label / exit code 契約 | round1 defer test / existing boundary tests | `bash local-watcher/test/stage_a_verify_round1_defer_test.sh` 成功 | run-summary key order 変更なし |
| 4.1 | `README.md` Stage A Verify 節 | operator documentation | README 差分 | shellcheck / docs review | iOS/Xcode の sandbox 境界失敗を説明 |
| 4.2 | `README.md` 環境変数表 | operator documentation | README 差分 | docs review | 新 env と既定値を記載 |
| 4.3 | `README.md` iOS Simulator / Xcode verify 節 | operator recovery hint | README 差分 | docs review | gate opt-out と boundary opt-in の違いを記載 |
| 4.4 | `README.md` Stage A Verify 節 | operator documentation | README 差分 | docs review | 未設定時の安全側 default を記載 |
| 5.1 | `stage_a_verify_ios_boundary_test.sh` case1/case3 | regression test suite | default sandbox / typo fallback | テスト成功 | 未設定時の既存境界を検証 |
| 5.2 | `stage_a_verify_ios_boundary_test.sh` case4 | regression test suite | CoreSimulatorService sample | テスト成功 | sandbox 境界診断を検証 |
| 5.3 | `stage_a_verify_ios_boundary_test.sh` case4 | regression test suite | Operation not permitted sample | テスト成功 | 権限境界診断を検証 |
| 5.4 | `stage_a_verify_sandbox_boundary_test.sh`, `stage_a_verify_round1_defer_test.sh`, `stage_a_verify_ios_boundary_test.sh` case5 | regression test suite | command resolution / round / sandbox flows | テスト成功 | `xcodebuild` heuristic 追加も検証 |
| 5.5 | changed shell scripts | shellcheck | warning-level shellcheck | `shellcheck --severity=warning ...` 成功 | 変更起因 warning なし |

## 確認事項

- なし。

STATUS: complete
