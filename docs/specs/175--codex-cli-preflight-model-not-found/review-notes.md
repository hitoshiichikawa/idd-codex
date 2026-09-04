# Review Notes

<!-- idd-codex:review round=1 model=gpt-5.5 timestamp=2026-09-04T02:58:57Z -->

## Reviewed Scope

- Branch: codex/issue-175-impl--codex-cli-preflight-model-not-found
- HEAD commit: 61eeda1c9c6b897973f28c02e4548ba7658a10bc
- Compared to: main..HEAD

## Verified Requirements

- 1.1 - `local-watcher/bin/idd-codex-issue-watcher.sh:1335` が codex 起動前に `mp_preflight_model` を呼び、`local-watcher/test/model_preflight_exec_prompt_test.sh:134` が rc=78 で exec 未起動を検証している。
- 1.2 - `local-watcher/bin/idd-codex-modules/model-preflight.sh:225` が stage/model/current/required と `codex update` guidance を log 出力し、`local-watcher/test/model_preflight_test.sh:137` 以降が検証している。
- 1.3 - `local-watcher/bin/idd-codex-issue-watcher.sh:7848` と `:9389` が escalation comment に model 設定エラー summary を追加し、PR/failed-recovery 側も `pi_usage_limit_fatal_test.sh:193`、`pr_reviewer_quota_marker_test.sh:298`、`failed_recovery_test.sh:244` で検証している。
- 1.4 - `model-preflight.sh:249` が unknown model を pass-through し、`model_preflight_exec_prompt_test.sh:142` と `model_preflight_test.sh:147` が検証している。
- 1.5 - `model-preflight.sh:259` 以降が `codex --version` 不可/抽出不能を rc=78 とし、`model_preflight_test.sh:153`、`:159`、`:166` が検証している。
- 2.1 - `model-preflight.sh:294` と `:320` が `model not found` 系を検出し、`qa_run_codex_stage_test.sh:687` が標準 stage 経路を検証している。
- 2.2 - `model-preflight.sh:294` が `unsupported model` 系を検出し、`qa_run_codex_stage_test.sh:691` と `pi_usage_limit_fatal_test.sh:187` が検証している。
- 2.3 - `quota-aware.sh:665`、`pr-iteration.sh:1032`、`pr-reviewer.sh:1670`、`failed-recovery.sh:849` が stage/model/reason/artifact を operator-visible log に残す。
- 2.4 - `model-preflight.sh:416` の summary builder と各 adapter comment path が「モデル設定エラーの可能性」を公開コメントへ反映している。
- 2.5 - `quota-aware.sh:605`、`:632`、`:655` が quota を優先し、`qa_run_codex_stage_test.sh:695`、`pi_usage_limit_fatal_test.sh:213`、`pr_reviewer_quota_marker_test.sh:266`、`failed_recovery_test.sh:228` が検証している。
- 3.1 - `model-preflight.sh:74` が既定対応表を提供している。
- 3.2 - `model-preflight.sh:96` が `MODEL_PREFLIGHT_MIN_VERSIONS` override を既定表の代替として扱い、`model_preflight_test.sh:122` が検証している。
- 3.3 - `model-preflight.sh:106` と `:128` 以降が malformed entry を WARN して skip し、`model_preflight_test.sh:130` が検証している。
- 3.4 - `model-preflight.sh:75` が `gpt-5.6-*` に `0.144.0` を要求し、`model_preflight_test.sh:118` が検証している。
- 3.5 - unknown model pass-through は `model-preflight.sh:249` と `model_preflight_test.sh:147` で確認でき、post-run classifier は `model_preflight_test.sh:194` 以降で検証されている。
- 4.1 - `core_utils.sh:229` と `:302` が共有 semver helper を提供している。
- 4.2 - `guard-hook.sh:64` と `:91` が guard hook preflight を共有 helper に接続している。
- 4.3 - `model-preflight.sh:284` が model preflight の比較に `idd_compare_semver` を使っている。
- 4.4 - `core_utils.sh:229` と `guard_hook_test.sh:180` が prerelease/build 相当 suffix の数値 prefix 比較を検証している。
- 4.5 - `core_utils.sh:302` と `guard_hook_test.sh:181` が比較不能入力を非 0 で返すことを検証している。
- 5.1 - 主要ロジックは新規 `local-watcher/bin/idd-codex-modules/model-preflight.sh:1` に配置されている。
- 5.2 - main watcher 側の接続は `REQUIRED_MODULES` 追加と `codex_exec_prompt` preflight 呼び出し（`idd-codex-issue-watcher.sh:1335`, `:1410`）に限定されている。
- 5.3 - 既存 labels/env/default model は変更されず、quota/failed 経路は `qa_run_codex_stage_test.sh:379` と `failed_recovery_test.sh:240` で互換を検証している。
- 5.4 - 差分は既存 bash/runtime 内に収まり、新 runtime dependency や外部 service 呼び出しは追加されていない。
- 5.5 - `model-preflight.sh:71` が default ON / `=false` escape hatch を実装し、`README.md:1442` と `model_preflight_test.sh:177` が検証している。
- 6.1 - `model_preflight_exec_prompt_test.sh:134` が known model の insufficient version で codex command 未起動を検証している。
- 6.2 - `model_preflight_exec_prompt_test.sh:142` が unknown model では codex exec に進むことを検証している。
- 6.3 - `model_preflight_test.sh:194`、`:201`、`:207` と adapter tests が stderr/stream の model error 分類を検証している。
- 6.4 - `model_preflight_test.sh:130` が malformed override map の WARN と skip を検証している。
- 6.5 - Reviewer が `IDD_HOOK_ROLE` を外した通常条件で tasks.md の shellcheck/test verify block と `model_preflight_exec_prompt_test.sh`、`module_loader_missing_test.sh` を再実行し全件 PASS を確認した。
- 6.6 - `README.md:1442`、`:4032`、`:4055`、`:4079`、`:6236` が optional features、env override、classification、recovery guidance を説明している。
- NFR 1.1 - 既存 `codex-failed` / `codex-needs-quota-wait` label は維持され、README でも `README.md:4045` に明記されている。
- NFR 1.2 - quota wait 優先は `quota-aware.sh:605`、`:632`、`:655` と関連 regression で維持されている。
- NFR 1.3 - `TRIAGE_MODEL` / `DEV_MODEL` / `REVIEWER_MODEL` / `DEBUGGER_MODEL` / `PR_ITERATION_DEV_MODEL` / `FAILED_RECOVERY_DEV_MODEL` の既定値変更は diff に含まれていない。

## Findings

なし

## Summary

`main..HEAD` の差分は tasks.md の `_Boundary:_` に収まっており、AC 未カバー / missing test / boundary 逸脱は検出していない。Reviewer 環境の `IDD_HOOK_ROLE=reviewer` を外した通常検証条件で、対象 shellcheck と regression tests は全件 PASS。

RESULT: approve
