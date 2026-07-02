# Review Notes

<!-- idd-codex:review round=1 model=gpt-5.5 timestamp=2026-07-02T09:25:29Z -->

## Reviewed Scope

- Branch: codex/issue-128-impl-bug-promote-pipeline-design-pr-merge-lin
- HEAD commit: 58effdd1fdf21826a614fcf0aec1b50733fa5418
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `pp_pr_issue_candidate_rows` excludes `codex/issue-<N>-design-*` heads, and `pp_collect_merged_issues` skips them before label candidate collection (`local-watcher/bin/idd-codex-modules/promote-pipeline.sh:1114`, `local-watcher/bin/idd-codex-modules/promote-pipeline.sh:1191`); regression assertions confirm Issue 5 is not auto-labeled (`local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh:356`, `local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh:374`).
- 1.2 — The design PR fixture includes head, title, body, and closing reference paths for Issue 5, and the candidate resolver returns no rows (`local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh:356`).
- 1.3 — Existing implementation PR candidate paths remain covered by managed head/body assertions and auto-label edit assertions (`local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh:322`, `local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh:371`).
- 1.4 — The merged PR fixture mixes design and implementation PRs; collection skips the design PR and still labels implementation-derived issues 18, 20, 24, and 25 (`local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh:190`, `local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh:371`).
- 1.5 — Design PR skip only avoids candidate generation and does not call label removal paths; existing already-labeled behavior remains unchanged (`local-watcher/bin/idd-codex-modules/promote-pipeline.sh:1191`, `local-watcher/bin/idd-codex-modules/promote-pipeline.sh:1240`).
- 2.1 — Design PR merges are excluded from release staging auto-labeling, leaving the design review release flow outside this change (`local-watcher/bin/idd-codex-modules/promote-pipeline.sh:1191`).
- 2.2 — The dispatcher-blocking `codex-staged-for-release` mislabel is prevented by the same design PR skip, with no changes to Design Review Release Processor behavior (`local-watcher/bin/idd-codex-modules/promote-pipeline.sh:1191`).
- 2.3 — Promote Pipeline enabled multi-branch test setup continues to process staged issues while excluding the design PR (`local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh:258`, `local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh:371`).
- 2.4 — Repeated candidate collection over the same design PR remains non-labeling because the resolver and collection loop always skip the design head (`local-watcher/bin/idd-codex-modules/promote-pipeline.sh:1118`, `local-watcher/bin/idd-codex-modules/promote-pipeline.sh:1191`).
- 3.1 — Regression validation asserts a merged design PR referencing Issue 5 does not add `codex-staged-for-release` (`local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh:374`).
- 3.2 — Regression validation still verifies implementation PR auto-labeling through managed PR candidates and edit log checks (`local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh:331`, `local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh:373`).
- 3.3 — The design PR regression fixture covers branch, title, body, and closing reference inputs (`local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh:356`).
- 3.4 — README states design PR merges are excluded from `codex-staged-for-release` auto-labeling (`README.md:1242`, `README.md:1916`), with a test assertion for the documentation text (`local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh:411`).
- NFR 1.1 — Env var names, label names, log destinations, and exit code meanings were not changed in the diff; shellcheck passed for the modified scripts.
- NFR 1.2 — `PROMOTE_PIPELINE_ENABLED` gate behavior is outside the changed hunk and remains unchanged.
- NFR 1.3 — `BASE_BRANCH == PROMOTION_TARGET_BRANCH` no-op behavior is outside the changed hunk and remains covered by the existing compatibility assertion (`local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh:312`).
- NFR 2.1 — Design PR skip emits an operator-observable promote-pipeline log identifying PR, Issue, head ref, and skip reason (`local-watcher/bin/idd-codex-modules/promote-pipeline.sh:1193`, `local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh:380`).

## Findings

なし

## Summary

AC 対応の実装・回帰テスト・README 同期を確認し、`bash local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh` と `shellcheck --severity=warning local-watcher/bin/idd-codex-modules/promote-pipeline.sh local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh` は通過した。指定された `tasks.md` / `design.md` は存在しないため、boundary は差分ファイルと利用可能な要件・実装メモに基づいて確認した。

RESULT: approve
