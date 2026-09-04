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

## 確認事項

- `tasks.md` の task 1 は `_Requirements:_` に 4.3（model preflight が共有 semver helper を使うこと）を含むが、`model-preflight.sh` の作成と接続は task 2/3 に明示されている。本 task では共有 helper の提供と guard hook 接続までを実装し、model preflight 側の利用は後続 task に残した。

STATUS: complete
