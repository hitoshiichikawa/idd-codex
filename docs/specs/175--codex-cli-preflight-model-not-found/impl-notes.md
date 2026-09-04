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

## 確認事項

- `tasks.md` の task 1 は `_Requirements:_` に 4.3（model preflight が共有 semver helper を使うこと）を含むが、`model-preflight.sh` の作成と接続は task 2/3 に明示されている。本 task では共有 helper の提供と guard hook 接続までを実装し、model preflight 側の利用は後続 task に残した。
