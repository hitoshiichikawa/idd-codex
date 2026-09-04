# Implementation Notes

## Implementation Notes

### Task 1
- 採用方針: `core_utils.sh` に `idd_extract_semver` / `idd_compare_semver` を追加し、`guard_compare_semver` は後方互換の wrapper として共有 helper へ委譲した。
- 重要な判断: `guard_preflight` の `codex --version` 抽出も `idd_extract_semver` に寄せ、missing patch は `0`、prerelease / build metadata 相当の suffix は数値 prefix で比較する挙動を固定した。
- 重要な判断: 既存の `guard_compare_semver` 関数名は既存呼び出し互換のため削除せず、内部実装だけを共有化した。
- 残存課題: model preflight module からの `idd_compare_semver` 利用は task 2/3 の範囲。

#### AC Coverage Matrix

| Requirement / AC | Implementation path | Production entrypoint / owning flow | Test / assertion | Verification result | Notes |
|------------------|---------------------|-------------------------------------|------------------|---------------------|-------|
| 4.1 | `local-watcher/bin/idd-codex-modules/core_utils.sh` / `idd_extract_semver`, `idd_compare_semver` | N/A (pure logic) | `guard_hook_test.sh`: extract / equal / greater / lesser / missing patch / suffix / invalid input assertions | `bash local-watcher/test/guard_hook_test.sh`: PASS, `shellcheck --severity=warning ...`: PASS | 共有 utility として実装済み |
| 4.2 | `local-watcher/bin/idd-codex-modules/guard-hook.sh` / `guard_compare_semver`, `guard_preflight` | `guard_preflight` when `IDD_CODEX_HOOKS_ENABLED=true` | `guard_hook_test.sh`: `guard semver wrapper delegates shared helper`, `guard preflight rejects older codex version`, `guard preflight accepts equal version with suffix` | `bash local-watcher/test/guard_hook_test.sh`: PASS, `shellcheck --severity=warning ...`: PASS | 既存関数名は wrapper として保持 |
| 4.3 | `local-watcher/bin/idd-codex-modules/core_utils.sh` / `idd_compare_semver` | task 2/3 の model preflight 接続で使用予定 | `guard_hook_test.sh`: shared helper の比較仕様を固定 | `bash local-watcher/test/guard_hook_test.sh`: PASS | `tasks.md` は task 1 に 4.3 を含めているが、model preflight module 実装は task 2/3 の範囲のため、本 task では共有 helper 提供までに限定 |
| 4.4 | `local-watcher/bin/idd-codex-modules/core_utils.sh` / `_idd_semver_segment_prefix`, `_idd_semver_normalize_for_compare` | N/A (pure logic) | `guard_hook_test.sh`: `semver suffix uses numeric prefix`, `guard preflight accepts equal version with suffix` | `bash local-watcher/test/guard_hook_test.sh`: PASS | prerelease suffix を数値 prefix 比較に正規化 |
| 4.5 | `local-watcher/bin/idd-codex-modules/core_utils.sh` / `_idd_semver_normalize_for_compare` | N/A (pure logic) | `guard_hook_test.sh`: `semver invalid actual is comparison error` | `bash local-watcher/test/guard_hook_test.sh`: PASS | 比較不能は rc=2 |
| 6.5 | changed shell scripts and `local-watcher/test/guard_hook_test.sh` | shell-level verification | `shellcheck --severity=warning local-watcher/bin/idd-codex-modules/core_utils.sh local-watcher/bin/idd-codex-modules/guard-hook.sh local-watcher/test/guard_hook_test.sh` | PASS | task 1 で変更した shell script に限定して実行 |

#### Finding Closure Matrix

| Finding | Target | Category | 対応 | テスト | status |
|---|---|---|---|---|---|
| なし | Task 1 | - | 前回 `review-notes.md` / `debugger-notes.md` は存在しない | `bash local-watcher/test/guard_hook_test.sh`; `shellcheck --severity=warning local-watcher/bin/idd-codex-modules/core_utils.sh local-watcher/bin/idd-codex-modules/guard-hook.sh local-watcher/test/guard_hook_test.sh` | closed |

### Task 2
- 採用方針: `local-watcher/bin/idd-codex-modules/model-preflight.sh` に `mp_` prefix の version map / override / preflight gate を追加し、`idd_compare_semver` / `idd_extract_semver` を利用した。
- 重要な判断: `MODEL_PREFLIGHT_ENABLED=false` の完全一致のみを escape hatch とし、それ以外は default ON として扱う。`MODEL_PREFLIGHT_MIN_VERSIONS` が設定されている場合は既定 map を置換し、malformed entry は WARN して skip する。
- 重要な判断: 未知 model は `codex --version` も呼ばずに pass-through し、既知 model の version 不足 / version 抽出不能のみ rc=78 で fail-fast する。
- 残存課題: watcher 本体の `REQUIRED_MODULES` / `codex_exec_prompt` 接続、model-not-found post-run classifier、Issue / PR escalation comment 連携は task 3 以降の範囲。

#### AC Coverage Matrix

| Requirement / AC | Implementation path | Production entrypoint / owning flow | Test / assertion | Verification result | Notes |
|------------------|---------------------|-------------------------------------|------------------|---------------------|-------|
| 1.1 | `model-preflight.sh` / `mp_preflight_model` | task 3 の `codex_exec_prompt` 接続前の module API | `model_preflight_test.sh`: `known model insufficient version returns rc 78`, `insufficient preflight only calls codex --version` | `bash local-watcher/test/model_preflight_test.sh`: PASS | 本 task では fail-fast gate の戻り値と stage command 未起動相当を module 境界で検証。production 接続は task 3 |
| 1.2 | `model-preflight.sh` / `mp_log_fail_fast` | operator-visible stderr log | `model_preflight_test.sh`: insufficient log includes model / current / required / update guidance | `bash local-watcher/test/model_preflight_test.sh`: PASS | `codex update` は案内のみで実行しない |
| 1.4 | `model-preflight.sh` / `mp_required_version_for_model`, `mp_preflight_model` | module API pass-through | `model_preflight_test.sh`: `unknown model passes preflight`, `unknown model does not call codex --version` | `bash local-watcher/test/model_preflight_test.sh`: PASS | 未知 model は前方互換のため拒否しない |
| 1.5 | `model-preflight.sh` / `mp_extract_codex_version`, `mp_preflight_model` | module API fail-fast | `model_preflight_test.sh`: `known model unparsable codex version returns rc 78`, `known model codex version command failure returns rc 78`, `known model missing codex command returns rc 78`, 各 reason log assertion | `bash local-watcher/test/model_preflight_test.sh`: PASS (24 assertions), `shellcheck --severity=warning ...`: PASS | version 抽出不能 / command failure / command not found を同じ rc=78 fail-fast 経路として検証 |
| 3.1 | `model-preflight.sh` / `mp_default_min_versions` | module map lookup | `model_preflight_test.sh`: `default map requires gpt-5.6 at 0.144.0` | `bash local-watcher/test/model_preflight_test.sh`: PASS | 既定対応表を module 内に保持 |
| 3.2 | `model-preflight.sh` / `mp_min_versions_spec` | `MODEL_PREFLIGHT_MIN_VERSIONS` env override | `model_preflight_test.sh`: `override map replaces default map`, `override map matches configured model` | `bash local-watcher/test/model_preflight_test.sh`: PASS | override 指定時は既定 map を使わない |
| 3.3 | `model-preflight.sh` / `mp_entry_required_version_for_model`, `mp_warn_malformed_entry` | override parser WARN log | `model_preflight_test.sh`: malformed override WARN / skipped entry assertions | `bash local-watcher/test/model_preflight_test.sh`: PASS | malformed entry は silent fail せず WARN して skip |
| 3.4 | `model-preflight.sh` / `mp_default_min_versions` | default map lookup | `model_preflight_test.sh`: `default map requires gpt-5.6 at 0.144.0` | `bash local-watcher/test/model_preflight_test.sh`: PASS | `gpt-5.6-*` は `0.144.0` 以上を要求 |
| 3.5 | `model-preflight.sh` / `mp_required_version_for_model`, `mp_preflight_model` | unknown model pass-through | `model_preflight_test.sh`: unknown model pass-through assertions | `bash local-watcher/test/model_preflight_test.sh`: PASS | typo / retired model は post-run classifier（task 3 以降）へ委譲 |
| 5.1 | `model-preflight.sh` 全体 | module boundary | `test -f local-watcher/bin/idd-codex-modules/model-preflight.sh`, `model_preflight_test.sh` | `bash local-watcher/test/model_preflight_test.sh`: PASS | 主要ロジックは新規 module に配置 |
| 5.5 | `model-preflight.sh` / `mp_is_enabled` | `MODEL_PREFLIGHT_ENABLED=false` escape hatch | `model_preflight_test.sh`: `disabled preflight passes without codex version call`, `disabled preflight does not call codex` | `bash local-watcher/test/model_preflight_test.sh`: PASS | default ON、完全一致 `false` のみ無効化 |
| 6.1 | `model-preflight.sh` / `mp_preflight_model` | module API fail-fast | `model_preflight_test.sh`: `insufficient preflight only calls codex --version` | `bash local-watcher/test/model_preflight_test.sh`: PASS | 本体の実 codex command 抑止は task 3 の接続テストで補完予定 |
| 6.2 | `model-preflight.sh` / `mp_preflight_model` | module API pass-through | `model_preflight_test.sh`: unknown model pass-through assertions | `bash local-watcher/test/model_preflight_test.sh`: PASS | unknown model で `CODEX_BIN --version` を呼ばない |
| 6.4 | `model-preflight.sh` / override parser | override parser WARN log | `model_preflight_test.sh`: malformed override WARN / skip assertions | `bash local-watcher/test/model_preflight_test.sh`: PASS | valid entry と malformed entry が混在しても valid entry は有効 |
| 6.5 | changed shell scripts and new test | shell-level verification | `shellcheck --severity=warning local-watcher/bin/idd-codex-modules/model-preflight.sh local-watcher/test/model_preflight_test.sh` | PASS | task 2 retry で `bash local-watcher/test/model_preflight_test.sh` も PASS (24 assertions) |
| NFR 2.1 | `model-preflight.sh` / `mp_log`, `mp_warn`, `mp_error` | operator-visible log prefix | `model_preflight_test.sh`: WARN / fail-fast log assertions | `bash local-watcher/test/model_preflight_test.sh`: PASS | stable prefix `model-preflight:` を使用 |

#### Finding Closure Matrix

| Target requirement | Category | Required Action | Fix commit | Test/assertion | Verification result | Notes / no-change reason |
|--------------------|----------|-----------------|------------|----------------|---------------------|--------------------------|
| 1.5 | missing test | known model かつ preflight enabled の状態で `codex --version` command failure または command-not-found を rc=78 / operator-visible reason として検証する regression を追加する | `3178429 test(watcher): model preflight command failureを検証する` | `model_preflight_test.sh`: `known model codex version command failure returns rc 78`, `command failure log includes reason`, `known model missing codex command returns rc 78`, `command-not-found log includes reason` | `bash local-watcher/test/model_preflight_test.sh`: PASS (24 assertions); `shellcheck --severity=warning local-watcher/bin/idd-codex-modules/model-preflight.sh local-watcher/test/model_preflight_test.sh`: PASS | Reviewer round 1 の missing test を追加 regression で close |

### Task 3
- 採用方針: `codex_exec_prompt` の Codex CLI 起動直前に `mp_preflight_model` を接続し、`qa_run_codex_stage` の non-quota failure 後に `mp_detect_model_error` を接続した。
- 重要な判断: `model-preflight.sh` に model config error の state / sanitized comment summary helper を持たせ、`mark_issue_failed` / `_slot_mark_failed` は既存 `codex-failed` 遷移を保ったまま「設定エラーの可能性」補足だけを追加する構成にした。
- 重要な判断: quota 判定は従来どおり最優先とし、quota stream と model-not-found 文字列が同居する場合は rc=99 / `codex-needs-quota-wait` 側を維持して model config summary を残さない regression で固定した。
- 残存課題: PR iteration / PR reviewer / failed-recovery 固有の comment / state 連携は task 4 の範囲。

#### AC Coverage Matrix

| Requirement / AC | Implementation path | Production entrypoint / owning flow | Test / assertion | Verification result | Notes |
|------------------|---------------------|-------------------------------------|------------------|---------------------|-------|
| 1.1 | `idd-codex-issue-watcher.sh` / `codex_exec_prompt` -> `mp_preflight_model` | all watcher Codex stages using `codex_exec_prompt` | `model_preflight_exec_prompt_test.sh`: known model insufficient version returns rc 78 before exec / only calls `--version` | `bash local-watcher/test/model_preflight_exec_prompt_test.sh`: PASS (9 assertions) | Codex exec command is not invoked on fail-fast |
| 1.3 | `model-preflight.sh` / `mp_record_config_error`, `mp_build_last_config_error_summary`; `mark_issue_failed`, `_slot_mark_failed` | Issue failure escalation comments for standard / slot flows | `model_preflight_test.sh`: config summary states setting error possibility / includes model / guidance; `qa_run_codex_stage_test.sh`: summary says setting error possibility | `bash local-watcher/test/model_preflight_test.sh`: PASS (33 assertions); `bash local-watcher/test/qa_run_codex_stage_test.sh`: PASS (125 assertions) | Existing `codex-failed` label is preserved; comment body gets supplemental section only |
| 2.1 | `model-preflight.sh` / `mp_detect_model_error_line`, `mp_detect_model_error` | `qa_run_codex_stage` non-quota failure artifact classification | `model_preflight_test.sh`: classifier detects model not found reason; `qa_run_codex_stage_test.sh`: StageA model-not-found classification | PASS as above | Plain stderr / stream-json-like line are both line-scanned |
| 2.2 | `model-preflight.sh` / `mp_detect_model_error_line` | `qa_run_codex_stage` non-quota failure artifact classification | `model_preflight_test.sh`: classifier detects unsupported model from stream-json line; `qa_run_codex_stage_test.sh`: StageA unsupported-model classification | PASS as above | Case-insensitive matching |
| 2.3 | `quota-aware.sh` / `qa_run_codex_stage`; `model-preflight.sh` / `mp_classify_stage_model_error` | standard stage wrapper logs after non-quota Codex rc | `qa_run_codex_stage_test.sh`: log records model config error / includes reason | `bash local-watcher/test/qa_run_codex_stage_test.sh`: PASS (125 assertions) | Logs use stable `model-preflight:` prefix and include stage/model/reason/artifact |
| 2.5 | `quota-aware.sh` / quota branches before model classifier | `qa_run_codex_stage` quota-aware owning flow | `qa_run_codex_stage_test.sh`: quota priority with model text rc/reset/no model summary | `bash local-watcher/test/qa_run_codex_stage_test.sh`: PASS (125 assertions) | quota rc=99 remains higher priority |
| 5.2 | `idd-codex-issue-watcher.sh` / `REQUIRED_MODULES`, `codex_exec_prompt`; `quota-aware.sh` hook | watcher bootstrap and shared Codex launch helper | `module_loader_missing_test.sh`: all modules present no loader error; `model_preflight_exec_prompt_test.sh`: production entrypoint preflight | `bash local-watcher/test/module_loader_missing_test.sh`: PASS (13 assertions); `bash local-watcher/test/model_preflight_exec_prompt_test.sh`: PASS | Main watcher change is module load + call-site connection |
| 5.3 | `idd-codex-issue-watcher.sh`; `quota-aware.sh` | labels / env / rc contracts around existing failure handling | `qa_run_codex_stage_test.sh`: rc transparent for model config errors; quota priority preserves rc=99 | `bash local-watcher/test/qa_run_codex_stage_test.sh`: PASS | No label names, default model env vars, or existing rc meanings changed; rc=78 is introduced by task 2 and propagated |
| 5.4 | `model-preflight.sh`, `quota-aware.sh`, `idd-codex-issue-watcher.sh` | local bash watcher only | `shellcheck --severity=warning ...`: PASS | `shellcheck --severity=warning local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/idd-codex-modules/model-preflight.sh local-watcher/bin/idd-codex-modules/quota-aware.sh local-watcher/test/model_preflight_test.sh local-watcher/test/model_preflight_exec_prompt_test.sh local-watcher/test/qa_run_codex_stage_test.sh local-watcher/test/module_loader_missing_test.sh`: PASS | No new runtime dependency or external service call |
| 6.1 | `codex_exec_prompt` -> `mp_preflight_model` | production Codex launch helper | `model_preflight_exec_prompt_test.sh`: insufficient version only calls `--version` and does not run `exec -C` | `bash local-watcher/test/model_preflight_exec_prompt_test.sh`: PASS | Complements task 2 module-level test |
| 6.2 | `codex_exec_prompt` -> `mp_preflight_model` | production Codex launch helper | `model_preflight_exec_prompt_test.sh`: unknown model reaches codex exec / does not call `--version` | `bash local-watcher/test/model_preflight_exec_prompt_test.sh`: PASS | Unknown models remain forward-compatible |
| 6.3 | `mp_detect_model_error`; `qa_run_codex_stage` classifier hook | standard stage wrapper after Codex non-zero rc | `model_preflight_test.sh`: model-not-found / unsupported / account availability / normal error / unreadable artifact cases; `qa_run_codex_stage_test.sh`: StageA model-not-found and unsupported-model classification | `bash local-watcher/test/model_preflight_test.sh`: PASS; `bash local-watcher/test/qa_run_codex_stage_test.sh`: PASS | classifier fail-open behavior is covered by normal/unreadable cases |
| NFR 1.1 | `mark_issue_failed`, `_slot_mark_failed`, `qa_run_codex_stage` | existing terminal labels and quota labels | `qa_run_codex_stage_test.sh`: quota label, no failed; model config rc transparent | `bash local-watcher/test/qa_run_codex_stage_test.sh`: PASS | No new label added |
| NFR 1.2 | `qa_run_codex_stage` quota branches before model classifier | quota-aware owning flow | `qa_run_codex_stage_test.sh`: usage-limit callsite adds quota wait; quota priority with model text | `bash local-watcher/test/qa_run_codex_stage_test.sh`: PASS | Existing quota semantics preserved |
| NFR 2.1 | `mp_log`, `mp_error`, `mp_classify_stage_model_error` | operator-visible logs | `qa_run_codex_stage_test.sh`: log records `model-config-error` and reason | PASS as above | Stable processor prefix `model-preflight:` |
| NFR 2.2 | `mp_build_config_error_summary` | Issue escalation comment supplement | `model_preflight_test.sh`: summary includes failing model and `codex update` guidance | PASS as above | Public comment omits raw artifact content |

#### Finding Closure Matrix

| Target requirement | Category | Required Action | Fix commit | Test/assertion | Verification result | Notes / no-change reason |
|--------------------|----------|-----------------|------------|----------------|---------------------|--------------------------|
| なし | Task 3 | - | `e2670bb feat(watcher): model preflightをcodex起動経路へ接続する` | `model_preflight_test.sh`; `model_preflight_exec_prompt_test.sh`; `qa_run_codex_stage_test.sh`; `module_loader_missing_test.sh`; related guard / PR / failed-recovery regressions | all PASS | 既存 `review-notes.md` は task 2 round 2 approve で、本 task に対する reject Finding は存在しない |

### Task 4
- 採用方針: `mp_classify_codex_failure` を共通 helper として追加し、PR iteration / PR reviewer / failed-recovery の non-quota failure 経路から既存 model error summary を再利用する構成にした。
- 重要な判断: PR iteration は usage-limit fatal と 529 detected を優先して model config comment を skip し、通常の non-zero / rc=78 のみ設定エラー候補として PR comment に残す。
- 重要な判断: PR reviewer は stdout / stderr を classifier に渡すが、public comment には raw output ではなく diagnostic correlation token と sanitized reason だけを載せる。
- 重要な判断: failed-recovery は rc=78 または attempt artifact の model-not-found 分類時に `last_status=model-config-error` として terminal 扱いし、attempt budget / no-progress baseline を前回値へ巻き戻す。
- 残存課題: README 更新と最終 regression verification の文書化は task 5 の範囲。

#### AC Coverage Matrix

| Requirement / AC | Implementation path | Production entrypoint / owning flow | Test / assertion | Verification result | Notes |
|------------------|---------------------|-------------------------------------|------------------|---------------------|-------|
| 1.3 | `model-preflight.sh` / `mp_classify_codex_failure`; `pr-iteration.sh` / `pi_maybe_handle_model_config_error`; `pr-reviewer.sh` / `pr_run_review_for_pr`; `failed-recovery.sh` / `fr_run_recovery_attempt` | PR iteration failure comment / PR reviewer exec-failed comment / failed-recovery attempt comment | `pi_usage_limit_fatal_test.sh`: model / preflight rc comment assertions; `pr_reviewer_quota_marker_test.sh`: setting-error comment assertions; `failed_recovery_test.sh`: setting-error comment assertions | stage-a-verify block: PASS | 標準 Issue failure comment は task 3 で接続済み。本 task は PR / failed-recovery 固有経路を補完 |
| 2.1 | `mp_classify_codex_failure`, `mp_detect_model_error` call sites | PR iteration log artifact, PR reviewer stdout/stderr artifact, failed-recovery attempt artifact | `failed_recovery_test.sh`: model-not-found artifact; existing `model_preflight_test.sh`: classifier model-not-found | stage-a-verify block: PASS | PR iteration / reviewer は 2.2 の unsupported-model fixture で同じ classifier path を検証 |
| 2.2 | `pi_maybe_handle_model_config_error`; `pr_run_review_for_pr` model summary branch | PR iteration non-zero Codex log, PR reviewer exec-failed stdout/stderr | `pi_usage_limit_fatal_test.sh`: unsupported-model PR iteration comment; `pr_reviewer_quota_marker_test.sh`: unsupported-model reviewer comment | stage-a-verify block: PASS | Case-insensitive classifier 本体は task 3 の `model_preflight_test.sh` で固定済み |
| 2.3 | `mp_error` logs from PR iteration / PR reviewer / failed-recovery adapters | operator-visible module logs for non-quota failures | `pi_usage_limit_fatal_test.sh`, `pr_reviewer_quota_marker_test.sh`, `failed_recovery_test.sh` plus `shellcheck --severity=warning ...` | stage-a-verify block: PASS | logs include stable `model-preflight:` prefix and stage / model / reason / artifact or correlation |
| 2.4 | `mp_build_last_config_error_summary` appended by PR iteration / PR reviewer / failed-recovery | PR / recovery escalation comments | `pi_usage_limit_fatal_test.sh`: comment contains `モデル設定エラーの可能性`; `pr_reviewer_quota_marker_test.sh`: sanitized reason/model/correlation; `failed_recovery_test.sh`: comment contains reason | stage-a-verify block: PASS | raw stderr line is not included in PR reviewer public comment |
| 2.5 | PR iteration usage-limit/529 skip; PR reviewer quota branch; failed-recovery quota branch | quota wait owning flows before model classification | `pi_usage_limit_fatal_test.sh`: usage-limit and 529 skip model comment; `pr_reviewer_quota_marker_test.sh`: quota wait label/comment and no exec-failed; `failed_recovery_test.sh`: quota budget preserved | stage-a-verify block: PASS | quota rc=99 and existing quota wait labels remain higher priority |
| 5.3 | changed adapters preserve existing labels / rc meanings | existing PR iteration, PR reviewer, failed-recovery processors | related tests above; `qa_run_codex_stage_test.sh` existing quota rc assertions | stage-a-verify block: PASS | new `model-config-error` is failed-recovery state reason only; no label/env/default model change |
| 5.4 | changed bash modules only | local watcher runtime | `shellcheck --severity=warning ...` | PASS | no new runtime dependency or external service call |
| 6.3 | PR iteration / reviewer / failed-recovery model error regressions | owning shell-level flows | `pi_usage_limit_fatal_test.sh`, `pr_reviewer_quota_marker_test.sh`, `failed_recovery_test.sh` | PASS | complements task 3 standard stage classifier regression |
| NFR 1.1 | labels unchanged; comments/states only | PR iteration / reviewer / failed-recovery labels | `pr_reviewer_quota_marker_test.sh`: no quota label for model error; existing tests confirm existing label paths | stage-a-verify block: PASS | no new label introduced |
| NFR 1.2 | quota wait priority before model classification | PR iteration usage-limit, PR reviewer quota, failed-recovery quota | `pi_usage_limit_fatal_test.sh`, `pr_reviewer_quota_marker_test.sh`, `failed_recovery_test.sh`, `qa_run_codex_stage_test.sh` | PASS | `QUOTA_AWARE_ENABLED` semantics untouched |
| NFR 2.1 | `model-preflight:` logs from adapters | operator-visible stderr/log | tests exercise adapter log-producing paths; shellcheck clean | stage-a-verify block: PASS | stable prefix reused |
| NFR 2.2 | summary builder reused with model / action guidance | PR / failed-recovery comments | `pi_usage_limit_fatal_test.sh`, `pr_reviewer_quota_marker_test.sh`, `failed_recovery_test.sh` | PASS | recommended action remains `codex update` / model env check |

#### Finding Closure Matrix

| Target requirement | Category | Required Action | Fix commit | Test/assertion | Verification result | Notes / no-change reason |
|--------------------|----------|-----------------|------------|----------------|---------------------|--------------------------|
| なし | Task 4 | - | `feat(watcher): PR系のmodel config分類を接続する` | `pi_usage_limit_fatal_test.sh`; `pr_reviewer_quota_marker_test.sh`; `failed_recovery_test.sh`; `fr_terminate_idempotent_test.sh` | all PASS | 既存 `review-notes.md` は task 3 approve で、本 task に対する reject Finding は存在しない |

### Task 5
- 採用方針: README の default ON 一覧、詳細節、Troubleshooting に model preflight / model-not-found 分類の運用手順を追加し、既存 regression verification を再実行して最終証跡を固定した。
- 重要な判断: `MODEL_PREFLIGHT_ENABLED=false` は一時的な escape hatch として説明しつつ、通常復旧は `codex update` と各 `*_MODEL` / `MODEL_PREFLIGHT_MIN_VERSIONS` の確認へ誘導した。
- 重要な判断: quota wait 優先、新 label 追加なし、failed-recovery の budget 非消費という後方互換境界を README に明記し、NFR 1.x の運用影響をドキュメント上でも追跡可能にした。
- 残存課題: なし。

#### AC Coverage Matrix

| Requirement / AC | Implementation path | Production entrypoint / owning flow | Test / assertion | Verification result | Notes |
|------------------|---------------------|-------------------------------------|------------------|---------------------|-------|
| 5.3 | `README.md` / default ON 一覧と Model Preflight 詳細節 | watcher operator が env / label / model defaults の互換性を確認する運用導線 | `qa_run_codex_stage_test.sh`, `pr_reviewer_quota_marker_test.sh`, `failed_recovery_test.sh` の既存 label / rc / quota 優先 assertions | stage-a-verify block: PASS; 追加で `bash local-watcher/test/module_loader_missing_test.sh`: PASS | env var 名、label 名、cron invocation、branch naming、既存 exit code 意味は変更なし |
| 5.4 | `README.md` / Model Preflight 詳細節、変更済み shell scripts | local watcher runtime | `shellcheck --severity=warning ...` | PASS | README 変更のみ。新しい runtime dependency / 外部 service 呼び出しは追加なし |
| 5.5 | `README.md` / default ON 一覧、環境変数表、Troubleshooting | operator が `MODEL_PREFLIGHT_ENABLED=false` または map override を設定する運用導線 | `model_preflight_test.sh`: disabled preflight / default map / override assertions | `bash local-watcher/test/model_preflight_test.sh`: PASS (33 assertions) | default ON、`=false` 厳密一致のみ無効化を明記 |
| 6.1 | `codex_exec_prompt` -> `mp_preflight_model`; `README.md` 復旧手順 | all watcher Codex stages using `codex_exec_prompt` | `model_preflight_exec_prompt_test.sh`: known model insufficient version returns rc 78 before exec / does not run codex exec | `bash local-watcher/test/model_preflight_exec_prompt_test.sh`: PASS (9 assertions) | README に fail-fast と `codex update` guidance を追記 |
| 6.2 | `codex_exec_prompt` -> `mp_preflight_model`; `README.md` 詳細節 | unknown model pass-through to Codex CLI | `model_preflight_exec_prompt_test.sh`: unknown model reaches codex exec / does not call `--version`; `model_preflight_test.sh`: unknown model pass-through | PASS | 未知 model は preflight で拒否しない前方互換を README に明記 |
| 6.3 | `model-preflight.sh` classifier adapters; `README.md` Model Preflight 詳細節 | standard stage / PR iteration / PR reviewer / failed-recovery non-quota failure flows | `model_preflight_test.sh`, `qa_run_codex_stage_test.sh`, `pi_usage_limit_fatal_test.sh`, `pr_reviewer_quota_marker_test.sh`, `failed_recovery_test.sh` | all PASS | `model not found` / `unsupported model` / account availability 系の分類と sanitized comment を記載 |
| 6.4 | `model-preflight.sh` override parser; `README.md` 環境変数表 | operator-provided `MODEL_PREFLIGHT_MIN_VERSIONS` | `model_preflight_test.sh`: malformed override WARN / skip assertions | `bash local-watcher/test/model_preflight_test.sh`: PASS (33 assertions) | comma 区切り `pattern:version` と malformed entry WARN / skip を README に明記 |
| 6.5 | changed shell scripts and regression tests | shell-level verification | `shellcheck --severity=warning local-watcher/bin/idd-codex-issue-watcher.sh ... local-watcher/test/failed_recovery_test.sh` | PASS | `tasks.md` の stage-a-verify block と同じ shellcheck 対象を実行 |
| 6.6 | `README.md` / default ON 一覧、Model Preflight 詳細節、Troubleshooting | operator docs | documentation diff in `0d50d8c docs(readme): model preflight運用手順を追加する` | `git diff --check -- README.md`: PASS | model preflight / model-not-found classification behavior、env overrides、recovery guidance を追加 |
| NFR 1.1 | `README.md`; existing label handlers | existing `codex-failed` / `codex-needs-quota-wait` label flows | `qa_run_codex_stage_test.sh`, `pr_reviewer_quota_marker_test.sh`, `failed_recovery_test.sh` | all PASS | 新 label 追加なし、quota label 優先を README に明記 |
| NFR 1.2 | `README.md`; quota-aware / PR / failed-recovery adapters | quota wait owning flows | `qa_run_codex_stage_test.sh`: quota priority with model text; `pi_usage_limit_fatal_test.sh`; `pr_reviewer_quota_marker_test.sh`; `failed_recovery_test.sh` | all PASS | `QUOTA_AWARE_ENABLED` semantics は変更なし |
| NFR 1.3 | `README.md` / 復旧手順と対象 model env var 一覧 | operator model env configuration | repository diff review | `git diff --stat main..HEAD`: default model files unchanged outside documented feature work | `TRIAGE_MODEL`, `DEV_MODEL`, `REVIEWER_MODEL`, `DEBUGGER_MODEL`, `PR_ITERATION_DEV_MODEL`, `FAILED_RECOVERY_DEV_MODEL` の既定値は変更していない |

#### Finding Closure Matrix

| Target requirement | Category | Required Action | Fix commit | Test/assertion | Verification result | Notes / no-change reason |
|--------------------|----------|-----------------|------------|----------------|---------------------|--------------------------|
| なし | Task 5 | - | `0d50d8c docs(readme): model preflight運用手順を追加する` | README diff check and stage-a-verify block | all PASS | 既存 `review-notes.md` は task 4 approve で、本 task に対する reject Finding は存在しない。`debugger-notes.md` は存在しない |

## 確認事項

- `tasks.md` の task 1 は `_Requirements:_` に 4.3（model preflight が共有 semver helper を使うこと）を含むが、`model-preflight.sh` の作成と接続は task 2/3 に明示されている。本 task では共有 helper の提供と guard hook 接続までを実装し、model preflight 側の利用は後続 task に残した。

STATUS: complete
