# Implementation Plan

- [ ] 1. 共有 semver / version 抽出 helper を `core_utils.sh` に移し guard hook を接続する
  - `local-watcher/bin/idd-codex-modules/core_utils.sh` に `idd_extract_semver` と `idd_compare_semver` を追加する。
  - `guard-hook.sh` の `guard_compare_semver` を shared helper 呼び出しへ置換または互換 wrapper 化する。
  - suffix / missing patch / invalid input / greater-equal-lesser の shell-level regression を追加する。
  - guard hook preflight の既存 version 判定が変わらないことを既存 test または追加 assertion で検証する。
  - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 6.5_
  - _Boundary: Core Version Utilities, Guard Hook Adapter, Model Preflight Regression Tests_

- [ ] 2. `model-preflight.sh` module の version map と preflight gate を実装する
  - `local-watcher/bin/idd-codex-modules/model-preflight.sh` を新規追加し、`mp_` prefix の log / map parse / required version lookup / preflight 関数を定義する。
  - 既定 map に `gpt-5.6-*:0.144.0` を入れ、`MODEL_PREFLIGHT_MIN_VERSIONS` override と malformed entry WARN を実装する。
  - `MODEL_PREFLIGHT_ENABLED=false` の完全一致のみ無効化し、未知 model は pass-through する。
  - stubbed `CODEX_BIN --version` で insufficient version は rc=78、unknown model は rc=0、version parse failure は known model で rc=78 になる regression test を追加する。
  - _Requirements: 1.1, 1.2, 1.4, 1.5, 3.1, 3.2, 3.3, 3.4, 3.5, 5.1, 5.5, 6.1, 6.2, 6.4, 6.5, NFR 2.1_
  - _Boundary: Model Preflight Module, Model Version Requirement Map, Model Preflight Gate, Model Preflight Regression Tests_
  - _Depends: 1_

- [ ] 3. codex 起動経路へ preflight と model error classifier を接続する
  - `REQUIRED_MODULES` に `model-preflight.sh` を追加し、module missing test の期待に新 module を反映する。
  - `codex_exec_prompt` の codex command 実行前に `mp_preflight_model "$stage_label" "$model"` を呼び、rc=78 では codex command を起動せず呼び出し側へ伝播する。
  - `mp_detect_model_error` を実装し、`model not found` / `unsupported model` / `unknown model` / account availability 系 pattern を sanitized reason として返す。
  - `qa_run_codex_stage` の non-quota rc 透過前に stream artifact を classifier に渡し、quota rc=99 が常に優先される regression を追加する。
  - _Requirements: 1.1, 1.3, 2.1, 2.2, 2.3, 2.5, 5.2, 5.3, 5.4, 6.1, 6.2, 6.3, NFR 1.1, NFR 1.2, NFR 2.1, NFR 2.2_
  - _Boundary: Watcher Bootstrap, Model Preflight Gate, Model Error Classifier, Quota Boundary Adapter, Model Config Error Escalation, Model Preflight Regression Tests_
  - _Depends: 2_

- [ ] 4. PR iteration / PR reviewer / failed-recovery の設定エラー観測を接続する
  - PR iteration の codex 非 0 exit 後、usage-limit / 529 と競合しない位置で log artifact を `mp_detect_model_error` に渡し、escalation comment に「設定エラーの可能性」を含める。
  - PR reviewer の non-quota exec failure で stdout / stderr artifact を classifier に渡し、public comment は sanitized reason と correlation token に限定する。
  - failed-recovery の codex attempt が rc=78 または model error 分類済みの場合、attempt budget を消費しない `model-config-error` reason として state / comment に残す。
  - それぞれ quota wait が成立する場合は既存 quota 経路を優先する regression test を追加する。
  - _Requirements: 1.3, 2.1, 2.2, 2.3, 2.4, 2.5, 5.3, 5.4, 6.3, NFR 1.1, NFR 1.2, NFR 2.1, NFR 2.2_
  - _Boundary: PR Iteration Adapter, PR Reviewer Adapter, Failed Recovery Adapter, Model Error Classifier, Model Config Error Escalation_
  - _Depends: 3_

- [ ] 5. README と regression verification を完成させる
  - README の Optional features / troubleshooting / model 設定周辺に `MODEL_PREFLIGHT_ENABLED`、`MODEL_PREFLIGHT_MIN_VERSIONS`、model-not-found 分類、`codex update` guidance を追加する。
  - `local-watcher/test/model_preflight_test.sh` で preflight / override / classifier の主要 case を固定する。
  - 変更 shell script と新規 tests を `shellcheck --severity=warning` で検証する。
  - `bash local-watcher/test/model_preflight_test.sh`、guard hook、quota-aware、PR iteration、PR reviewer、failed-recovery の関連 regression を実行する。
  - _Requirements: 5.3, 5.4, 5.5, 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, NFR 1.1, NFR 1.2, NFR 1.3_
  - _Boundary: Operator Docs, Model Preflight Regression Tests, Existing Flow Regression Tests_
  - _Depends: 1, 2, 3, 4_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを以下に宣言する。

<!-- stage-a-verify -->
```sh
set -euo pipefail
test -f local-watcher/bin/idd-codex-modules/model-preflight.sh
test -f local-watcher/test/model_preflight_test.sh
shellcheck --severity=warning \
  local-watcher/bin/idd-codex-issue-watcher.sh \
  local-watcher/bin/idd-codex-modules/core_utils.sh \
  local-watcher/bin/idd-codex-modules/guard-hook.sh \
  local-watcher/bin/idd-codex-modules/model-preflight.sh \
  local-watcher/bin/idd-codex-modules/quota-aware.sh \
  local-watcher/bin/idd-codex-modules/pr-iteration.sh \
  local-watcher/bin/idd-codex-modules/pr-reviewer.sh \
  local-watcher/bin/idd-codex-modules/failed-recovery.sh \
  local-watcher/test/model_preflight_test.sh \
  local-watcher/test/guard_hook_test.sh \
  local-watcher/test/qa_run_codex_stage_test.sh \
  local-watcher/test/pi_usage_limit_fatal_test.sh \
  local-watcher/test/pr_reviewer_quota_marker_test.sh \
  local-watcher/test/failed_recovery_test.sh
bash local-watcher/test/model_preflight_test.sh
bash local-watcher/test/guard_hook_test.sh
bash local-watcher/test/qa_run_codex_stage_test.sh
bash local-watcher/test/pi_usage_limit_fatal_test.sh
bash local-watcher/test/pr_reviewer_quota_marker_test.sh
bash local-watcher/test/failed_recovery_test.sh
```
