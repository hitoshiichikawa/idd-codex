# Review Notes

<!-- idd-codex:review round=2 model=gpt-5.5 timestamp=2026-07-02T12:57:46Z -->

## Reviewed Scope

- Branch: codex/issue-130-impl-stage-a-verify-sandbox-ios-simulator
- HEAD commit: 8c7385ca4b53310f202da79af58bf7b4fb4417e3
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:101` の `_sav_repo_execution_boundary` と `stage_a_verify_run` の境界選択で operator 設定による実行環境調整を確認。
- 1.2 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:145` の host 実行経路と `local-watcher/test/stage_a_verify_ios_boundary_test.sh:123` の host opt-in case で確認。
- 1.3 — `local-watcher/test/stage_a_verify_ios_boundary_test.sh:157` の iOS Simulator destination 失敗 sample と host opt-in 経路で sandbox 境界だけに依存しない設定経路を確認。
- 1.4 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:101` の既定 `codex-sandbox` と `local-watcher/test/stage_a_verify_ios_boundary_test.sh:112` の未設定 case で確認。
- 1.5 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:1055` の repository 由来 verify 境界切替と README `README.md:4382` の gate opt-out との分離説明で確認。
- 2.1 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:168` / `:192` と `local-watcher/test/stage_a_verify_ios_boundary_test.sh:173` で CoreSimulator 接続失敗診断を確認。
- 2.2 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:172` / `:196` と `local-watcher/test/stage_a_verify_ios_boundary_test.sh:174` で CoreSimulator log の `Operation not permitted` 診断を確認。
- 2.3 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:178` / `:200` と `local-watcher/test/stage_a_verify_ios_boundary_test.sh:175` で destination 検出失敗 hint を確認。
- 2.4 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:204` と `local-watcher/test/stage_a_verify_ios_boundary_test.sh:176` で recovery hint を確認。
- 2.5 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:1074` / `:1077` と `local-watcher/test/stage_a_verify_ios_boundary_test.sh:172` で verify exit code と境界診断の分離を確認。
- 3.1 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:101` / `:1055` と `local-watcher/test/stage_a_verify_ios_boundary_test.sh:112` / `:145` で未設定時の既定 sandbox と typo fallback を確認。
- 3.2 — `STAGE_A_VERIFY_ENABLED=false` の既存 disabled gate 経路は差分で変更されていないことを確認。
- 3.3 — `local-watcher/test/stage_a_verify_sandbox_boundary_test.sh` の operator override case と Developer 記載の成功結果で `STAGE_A_VERIFY_COMMAND` semantics 維持を確認。
- 3.4 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:1055` / `:1064` と sandbox boundary tests で repository 由来 verify が未設定時に host へ暗黙 fallback しないことを確認。
- 3.5 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:1081` 以降の既存 result branch と `local-watcher/test/stage_a_verify_round1_defer_test.sh` 成功で round / run-summary 既存契約を確認。
- 4.1 — README `README.md:4371` で iOS Simulator / Xcode の sandbox 境界起因失敗の説明を確認。
- 4.2 — README `README.md:4320` の環境変数表で `STAGE_A_VERIFY_EXECUTION_BOUNDARY` と既定値を確認。
- 4.3 — README `README.md:4382` で gate opt-out と verify 実行境界調整の違いを確認。
- 4.4 — README `README.md:4382` で未設定時の安全側 default 維持を確認。
- 5.1 — `local-watcher/test/stage_a_verify_ios_boundary_test.sh:112` / `:145` で未設定・typo 時の既定 sandbox を確認。
- 5.2 — `local-watcher/test/stage_a_verify_ios_boundary_test.sh:162` / `:173` で CoreSimulatorService sample の診断を確認。
- 5.3 — `local-watcher/test/stage_a_verify_ios_boundary_test.sh:164` / `:174` で permission failure sample の診断を確認。
- 5.4 — `local-watcher/test/stage_a_verify_sandbox_boundary_test.sh`、`local-watcher/test/stage_a_verify_round1_defer_test.sh`、`local-watcher/test/stage_a_verify_ios_boundary_test.sh:178` で command resolution / sandbox boundary / round 1 defer / xcodebuild heuristic を確認。
- 5.5 — reviewer が `bash -n`、主要 Stage A Verify テスト、round 1 defer テスト、warning-level `shellcheck` を再実行して成功を確認。

## Findings

なし

## Summary

round 1 の reject 理由だった `tasks.md` 欠落は解消され、今回の production code / test / README 差分は追加された `_Boundary:_` の範囲内に収まっている。AC 対応と regression test も確認できたため approve とする。

RESULT: approve
