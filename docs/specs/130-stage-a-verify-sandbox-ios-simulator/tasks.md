# Implementation Tasks

## Boundary Components

- `StageAVerifyModule`: `local-watcher/bin/idd-codex-modules/stage-a-verify.sh`
- `WatcherEnvConfig`: `local-watcher/bin/idd-codex-issue-watcher.sh`
- `StageAVerifyRegressionTests`: `local-watcher/test/stage_a_verify_ios_boundary_test.sh`, `local-watcher/test/stage_a_verify_sandbox_boundary_test.sh`
- `StageAVerifyOperatorDocs`: `README.md`

## Tasks

- [x] 1. Stage A Verify の verify 実行境界を operator opt-in で切り替える
  - `STAGE_A_VERIFY_EXECUTION_BOUNDARY=host` 完全一致時のみ host 実行へ切り替え、未設定・typo・大文字違いは既定の `codex-sandbox` に倒す。
  - 既存の `STAGE_A_VERIFY_ENABLED=false`、`STAGE_A_VERIFY_COMMAND`、構造化 verify ブロック、round 処理、run-summary 分類は維持する。
  - runtime behavior change と safety fallback のため、同タスク内で default sandbox / host opt-in / typo fallback / operator override の shell-level regression test を含める。
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 3.1, 3.2, 3.3, 3.4, 3.5_
  - _Boundary: StageAVerifyModule, WatcherEnvConfig, StageAVerifyRegressionTests_

- [x] 2. iOS Simulator / CoreSimulator の sandbox 境界失敗診断を追加する
  - verify 出力を保持し、CoreSimulator 接続失敗、CoreSimulator ログ領域の権限失敗、iOS Simulator destination 検出失敗を exit code とは別の `DIAGNOSTIC` 行で記録する。
  - failure path のため、代表的な `xcodebuild` exit 70 出力 sample を使った shell-level regression test を含める。
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5_
  - _Boundary: StageAVerifyModule, StageAVerifyRegressionTests_

- [x] 3. Stage A Verify の既存互換性と iOS 境界挙動を回帰検証する
  - 未設定時の安全側 default、`xcodebuild` heuristic、既存 sandbox boundary、round 1 defer の代表経路を検証する。
  - 変更 shell script は warning-level shellcheck と `bash -n` で検証する。
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5_
  - _Boundary: StageAVerifyModule, WatcherEnvConfig, StageAVerifyRegressionTests_

- [x] 4. operator documentation に iOS / Xcode 向けの境界調整を追記する
  - Stage A Verify Gate の環境変数表と iOS Simulator / Xcode verify の注意節に、安全側 default、gate opt-out と境界 opt-in の違い、recovery hint を記載する。
  - _Requirements: 4.1, 4.2, 4.3, 4.4_
  - _Boundary: StageAVerifyOperatorDocs_

## Verification

<!-- stage-a-verify -->
```bash
set -euo pipefail
bash -n local-watcher/bin/idd-codex-modules/stage-a-verify.sh local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/test/stage_a_verify_ios_boundary_test.sh local-watcher/test/stage_a_verify_sandbox_boundary_test.sh
bash local-watcher/test/stage_a_verify_ios_boundary_test.sh
bash local-watcher/test/stage_a_verify_sandbox_boundary_test.sh
bash local-watcher/test/stage_a_verify_round1_defer_test.sh
shellcheck --severity=warning local-watcher/bin/idd-codex-modules/stage-a-verify.sh local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/test/stage_a_verify_ios_boundary_test.sh local-watcher/test/stage_a_verify_sandbox_boundary_test.sh
```
