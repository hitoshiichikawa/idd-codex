# Implementation Notes

## 実装概要

- `pp_pr_issue_candidate_rows` で `codex/issue-<N>-design-*` head の merged PR を auto-label 候補から除外した。
- `pp_collect_merged_issues` で design PR skip を operator-observable な `promote-pipeline:` ログとして出力するようにした。
- 既存の implementation PR / managed PR / body plain reference の auto-label 経路は維持した。
- README の Promote Pipeline 説明に、設計 PR merge は `codex-staged-for-release` 自動付与対象外であることを追記した。

## 確認事項

- なし。

## 検証

- `bash local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh` -> PASS: 26, FAIL: 0
- `shellcheck --severity=warning local-watcher/bin/idd-codex-modules/promote-pipeline.sh local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh` -> PASS

## AC Coverage Matrix

| Requirement / AC | Implementation path | Production entrypoint / owning flow | Test / assertion | Verification result | Notes |
|------------------|---------------------|-------------------------------------|------------------|---------------------|-------|
| 1.1 | `local-watcher/bin/idd-codex-modules/promote-pipeline.sh` / `pp_collect_merged_issues`, `pp_pr_issue_candidate_rows` | Promote Pipeline watcher cycle after `gh pr list --state merged --base "$BASE_BRANCH"` | `design PR references are excluded from auto-label candidates`, `design PR is not auto-labeled` | `bash local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh` PASS | `codex/issue-<N>-design-*` head を検出して skip |
| 1.2 | `pp_pr_issue_candidate_rows` | Merged PR candidate resolver for title/body/closing refs | `design PR references are excluded from auto-label candidates` | 同上 PASS | title/body/closing-ref が Issue を参照しても候補行を出さない |
| 1.3 | `pp_pr_issue_candidate_rows`, `pp_collect_merged_issues` | Promote Pipeline auto-label candidate collection | `managed branch extracts head issue`, `managed body plain reference is accepted`, `auto-label edits skip already-labeled issue` | 同上 PASS | implementation PR の既存経路は維持 |
| 1.4 | `pp_collect_merged_issues` | Same watcher cycle processing multiple merged PR objects | `design PR is not auto-labeled`, `auto-label edits skip already-labeled issue` | 同上 PASS | design PR を skip して後続 / 既存 implementation 候補処理を継続 |
| 1.5 | `pp_collect_merged_issues` | Promote Pipeline auto-label collection | `design PR is not auto-labeled` | 同上 PASS | design PR skip はラベル除去処理を呼ばない。既付与ラベルの自動除去は scope 外 |
| 2.1 | `pp_collect_merged_issues` | Design PR merged on `BASE_BRANCH` before implementation dispatch | `design PR is not auto-labeled` | 同上 PASS | release staging ラベルを付けないため通常 dispatcher 除外要因を作らない |
| 2.2 | `pp_collect_merged_issues` | Design Review Release 後の dispatcher 候補状態 | `design PR is not auto-labeled` | 同上 PASS | `codex-staged-for-release` 誤付与を防ぐ範囲で対応。Design Review Release Processor は変更なし |
| 2.3 | `pp_collect_merged_issues` | `PROMOTE_PIPELINE_ENABLED=true` multi-branch watcher cycle | `promote stdout lists staged issues only`, `design PR is not auto-labeled` | 同上 PASS | Promote Pipeline 有効時でも design PR 由来の auto-label は発生しない |
| 2.4 | `pp_collect_merged_issues`, `pp_pr_issue_candidate_rows` | Repeated watcher cycles over recent merged PR list | `design PR references are excluded from auto-label candidates`, `design PR is not auto-labeled` | 同上 PASS | design PR は毎回候補行を出さないため再付与されない |
| 3.1 | `local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh` | Regression shell test for merged design PR | `design PR is not auto-labeled` | 同上 PASS | Issue edit log に design Issue 番号が現れないことを検証 |
| 3.2 | `local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh` | Regression shell test for merged implementation PR | `auto-label edits skip already-labeled issue`, `managed branch extracts head issue` | 同上 PASS | implementation PR の自動付与継続を検証 |
| 3.3 | `local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh` | Candidate resolver regression test | `design PR references are excluded from auto-label candidates` | 同上 PASS | design PR の head/title/body/closing-ref 参照を fixture に含めた |
| 3.4 | `README.md`, `local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh` | README Promote Pipeline documentation | `README documents design PR auto-label exclusion` | 同上 PASS | README の対象条件・状態遷移・ログ識別語を更新 |
| NFR 1.1 | `promote-pipeline.sh` | Promote Pipeline runtime behavior | `shellcheck --severity=warning ...` | PASS | env var / label name / exit code / log destination は変更なし |
| NFR 1.2 | `promote-pipeline.sh` | `PROMOTE_PIPELINE_ENABLED` gate in `pp_run` | N/A (既存 gate 非変更) | `bash local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh` PASS | Promote Pipeline disabled path は未変更 |
| NFR 1.3 | `promote-pipeline.sh` | `BASE_BRANCH == PROMOTION_TARGET_BRANCH` no-op gate | N/A (既存 gate 非変更) | `bash local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh` PASS | single-branch no-op path は未変更 |
| NFR 2.1 | `pp_collect_merged_issues` / `pp_log` | Promote Pipeline operator logs | `auto-label log reports design PR skip` | `bash local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh` PASS | `pr=#... issue=#... headRefName=... design-pr auto-label skip` を出力 |

STATUS: complete
