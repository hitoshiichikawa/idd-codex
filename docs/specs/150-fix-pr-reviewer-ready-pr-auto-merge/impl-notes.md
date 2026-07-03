# Implementation Notes

## Summary

- `AGENTS.md` に `Feature Flag Protocol` の opt-in 宣言は無かったため、通常フローで実装した。
- `pr-reviewer` は ready PR の `reviewDecision` / reviews / status rollup が空でも候補から除外しない既存方針を維持しつつ、候補総数と除外理由のログを追加した。
- `auto-merge` は `codex-ready-for-review` だけでは arm せず、current head SHA の review approval evidence と `codex-review` / `claude-review` の successful status evidence が揃った場合だけ `gh pr merge --auto` を呼ぶようにした。

## Implementation Notes

### Task all

- 採用方針: `merge-queue.sh` の current-SHA marker approval 解析方針を `auto-merge.sh` に合わせて踏襲し、status gate を追加した。
- 重要な判断: `statusCheckRollup` が空・pending・failure・取得不能・review status 不在の場合はすべて skip とし、branch protection だけを review gate の代替にしない。`codex-needs-iteration` / `codex-needs-rebase` 付き ready PR も auto-merge 対象外に追加した。
- 残存課題: なし。

## AC Coverage Matrix

| Requirement / AC | Implementation path | Production entrypoint / owning flow | Test / assertion | Verification result | Notes |
|------------------|---------------------|-------------------------------------|------------------|---------------------|-------|
| 1.1 | `local-watcher/bin/idd-codex-modules/pr-reviewer.sh:pr_fetch_candidate_prs` | `process_pr_reviewer` の候補 PR 列挙 | `pr_reviewer_ready_candidate_test.sh` ready open managed PR を候補に含める | `bash local-watcher/test/pr_reviewer_ready_candidate_test.sh` PASS | PR label ready の managed PR を保持 |
| 1.2 | `pr_fetch_candidate_prs` | `process_pr_reviewer` | `pr_reviewer_ready_candidate_test.sh` ready PR を PR label 起点で保持 | PASS | Issue label の有無には依存しない |
| 1.3 | `pr_fetch_candidate_prs` | `process_pr_reviewer` | `reviewDecision/statusCheckRollup 空でも候補から除外しない` | PASS | 空 review/status は未レビュー候補として扱う |
| 1.4 | `pr_fetch_candidate_prs` | `process_pr_reviewer` | same-owner managed head の手動相当 PR を候補化 | PASS | watcher-created 判定は使わない |
| 1.5 | `pr_run_review_for_pr` 既存 marker skip | `process_pr_reviewer` | 既存 `pr_reviewer_approval_signal_test.sh` / marker skip は既存挙動維持 | `bash local-watcher/test/pr_reviewer_approval_signal_test.sh` PASS | 今回は候補抽出のみ変更 |
| 2.1 | `auto-merge.sh:am_resolve_review_gate_for_pr` | `process_auto_merge` | `ready PR 証跡なし -> gh pr merge 0 回` | `bash local-watcher/test/auto_merge_test.sh` PASS | review/status evidence 不在で skip |
| 2.2 | `am_resolve_review_approval_signal` | `process_auto_merge` | `current SHA approve marker + status success` / `reviewDecision APPROVED + status success` | PASS | non-approved は marker approve が無ければ skip |
| 2.3 | `am_resolve_status_gate_signal` | `process_auto_merge` | empty status は merge 0、success status は merge 1 | PASS | pending/failure/malformed は同関数で rejected/unknown |
| 2.4 | `am_resolve_review_approval_signal`, `am_resolve_status_gate_signal` | `process_auto_merge` | `comments API failure -> WARN + merge 0 回` | PASS | status parse failure も WARN + skip |
| 2.5 | `am_should_enable_for_pr` | `process_auto_merge` | `needs-iteration 付き -> skip`, `needs-rebase 付き -> skip` | PASS | failed / needs-decisions 既存 gate も維持 |
| 3.1 | `am_resolve_review_gate_for_pr` | same watcher cycle の `process_auto_merge` | `ready PR 証跡なし -> gh pr merge 0 回` | PASS | 同一 cycle でも evidence が観測できなければ arm しない |
| 3.2 | `am_resolve_review_gate_for_pr` | `process_auto_merge` | `current SHA approve marker + status success -> merge 1 回` | PASS | approval と review status の両方を要求 |
| 3.3 | `am_resolve_marker_approval_signal` | `process_auto_merge` | blocking verdict marker は rejected path | `auto_merge_test.sh` status/marker resolver 経由 PASS | iteration marker は `iteration-marker` で skip |
| 3.4 | `am_resolve_review_approval_signal` | `process_auto_merge` | comments API failure skip | PASS | reviewer unavailable evidence は approved にならない |
| 3.5 | `am_resolve_status_gate_signal` | `process_auto_merge` | review status 不在は skip | PASS | GitHub auto-merge 可否だけでは許可しない |
| 4.1 | `pr_fetch_candidate_prs` | `process_pr_reviewer` | candidate totals / draft / fork / excluded-by-head-pattern ログ | `pr_reviewer_ready_candidate_test.sh` PASS | already-reviewed は既存 per-PR skip ログと summary skip count で判別 |
| 4.2 | `process_auto_merge` | `process_auto_merge` | `review gate missing reason=...` ログ | `auto_merge_test.sh` PASS | PR 番号・head・sha をログに含める |
| 4.3 | `am_enable_auto_merge_for_pr` | `process_auto_merge` | `review_gate=<source>` ログ | PASS | enable 時に accepted source を出力 |
| 4.4 | `README.md` full-auto / env 表 | ドキュメント | README 更新確認 | shellcheck 対象外、diff 確認 | current-head evidence 必須を明記 |
| 4.5 | `README.md` PR Reviewer 対象 PR 節 | ドキュメント | README 更新確認 | diff 確認 | 手動・外部作成 managed PR も同一 gate と明記 |
| 5.1 | `pr_reviewer_ready_candidate_test.sh` | test | ready open managed PR + empty review/status | PASS | 回帰テスト追加 |
| 5.2 | `auto_merge_test.sh` | test | ready PR without current-head evidence -> no merge | PASS | `gh pr merge` 呼び出し 0 |
| 5.3 | `auto_merge_test.sh` | test | current-head approve marker + status success -> merge 1 | PASS | reviewDecision APPROVED case も追加 |
| 5.4 | `auto_merge_test.sh` | test | stale old-SHA marker -> no merge | PASS | `reason=stale-marker` |
| 5.5 | `auto_merge_test.sh` | test | comments API failure -> warning + no merge | PASS | metadata failure safe skip |
| NFR 1.1 | env / label / exit code 変更なし | watcher processor | shellcheck / diff review | PASS | 新規 env var なし |
| NFR 1.2 | `process_pr_reviewer` gate 既存維持 | `process_pr_reviewer` | `security_medium_pr_reviewer_test.sh` disabled no-op | PASS | gate OFF は列挙しない |
| NFR 1.3 | `process_auto_merge` gate 既存維持 | `process_auto_merge` | full-auto OFF / AUTO_MERGE OFF -> gh 0 回 | PASS | no-op 維持 |
| NFR 1.4 | labels constants 既存名維持 | watcher processors | diff review | PASS | ラベル名変更なし |
| NFR 2.1 | `am_resolve_review_gate_for_pr` | `process_auto_merge` | ambiguous / stale / missing / API failure skip | PASS | 安全側 skip |
| NFR 2.2 | `am_enable_auto_merge_for_pr` | `process_auto_merge` | `gh pr merge --auto` のみ | PASS | direct merge は追加なし |
| NFR 2.3 | GitHub CLI のみ | watcher processors | diff review | PASS | 新規外部サービスなし |
| NFR 3.1 | fork owner filter 維持 | `process_pr_reviewer`, `process_auto_merge` | `security_medium_pr_reviewer_test.sh`, ready candidate fork count | PASS | fork 除外維持 |
| NFR 3.2 | jq / grep によるデータ判定のみ | watcher processors | shellcheck PASS | PASS | Issue/PR 文字列を watcher 指示として扱わない |
| NFR 3.3 | head pattern filter 維持 | `process_pr_reviewer`, `am_should_enable_for_pr` | unmanaged head 除外 / design head skip | PASS | unmanaged PR 除外維持 |

## Verification

- `bash local-watcher/test/auto_merge_test.sh` -> PASS: 37, FAIL: 0
- `bash local-watcher/test/pr_reviewer_ready_candidate_test.sh` -> PASS: 6, FAIL: 0
- `bash local-watcher/test/pr_reviewer_approval_signal_test.sh` -> PASS: 20, FAIL: 0
- `bash local-watcher/test/security_medium_pr_reviewer_test.sh` -> PASS=29 FAIL=0
- `bash local-watcher/test/pr_publish_commit_status_test.sh` -> PASS: 24, FAIL: 0
- `shellcheck --severity=warning local-watcher/bin/idd-codex-modules/auto-merge.sh local-watcher/bin/idd-codex-modules/pr-reviewer.sh local-watcher/test/auto_merge_test.sh local-watcher/test/pr_reviewer_ready_candidate_test.sh` -> PASS

## 確認事項

- なし。

STATUS: complete
