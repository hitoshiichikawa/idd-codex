# Implementation Notes

## Summary

PR Reviewer のレビュー実行を、メイン repo の local branch checkout から detached な一時 review worktree へ変更した。
これにより、実装用 slot worktree が同じ PR head branch を checkout 済みでも Git の worktree 制約と衝突せず、current head SHA をレビューできる。

workspace 準備失敗は `workspace-fail:<classification>` として統括側へ返し、operator-visible log に PR 番号・head branch・SHA・分類を残す。
継続不能な場合は `workspace-prepare-failed` marker 付きの PR コメントを同一 SHA へ 1 回だけ投稿し、raw stdout / stderr や長い未信頼入力は公開しない。

## 実装上の判断

- 一時 review worktree は `git worktree add --detach <tmp>/review origin/<head>` で作成し、`EXIT` trap で `git worktree remove --force` と temp dir cleanup を行う。
- 既存の `PR_REVIEWER_*` env var、tool 解決、対象 PR 判定、review marker、VERDICT、PR Iteration 連携は変更していない。
- workspace 準備失敗は review marker ではなく failure marker として扱うため、同一 SHA のレビュー済み扱いにはしない。head SHA が更新されれば再評価される。
- README の PR Reviewer Processor 節を detached review worktree と `workspace-prepare-failed` marker に同期した。

## 確認事項

なし。

## AC Coverage Matrix

| Requirement / AC | Implementation path | Production entrypoint / owning flow | Test / assertion | Verification result | Notes |
|------------------|---------------------|-------------------------------------|------------------|---------------------|-------|
| 1.1 | `local-watcher/bin/idd-codex-modules/pr-reviewer.sh` `pr_execute_review_command` | `process_pr_reviewer` → `pr_run_review_for_pr` → review command execution | `pr_reviewer_worktree_workspace_test.sh`: branch checkout 済み別 worktree があってもレビュー実行へ進む / current head SHA をレビューする | `bash local-watcher/test/pr_reviewer_worktree_workspace_test.sh`: PASS | detached review worktree で `origin/<head>` を checkoutする |
| 1.2 | `pr_execute_review_command` | PR Reviewer workspace preparation | `pr_reviewer_worktree_workspace_test.sh`: review workspace は detached HEAD で動く | `bash local-watcher/test/pr_reviewer_worktree_workspace_test.sh`: PASS | 実装用 slot の checkout 状態に依存しない |
| 1.3 | `pr_execute_review_command`, `pr_cleanup_review_workspace` | PR Reviewer workspace preparation / cleanup | `pr_reviewer_worktree_workspace_test.sh`: 実装用 slot は head branch のまま / 未保存 untracked を破棄しない | `bash local-watcher/test/pr_reviewer_worktree_workspace_test.sh`: PASS | 一時 worktree のみ cleanup 対象 |
| 1.4 | `pr_execute_review_command`, `pr_cleanup_review_workspace` | 1 cycle の複数 PR review loop | `pr_reviewer_worktree_workspace_test.sh`: main repo の checkout 状態を別 PR 用に汚さない / 一時 review worktree は cleanup される | `bash local-watcher/test/pr_reviewer_worktree_workspace_test.sh`: PASS | PR ごとに別 temp dir を作る |
| 1.5 | 既存 `pr_fetch_candidate_prs` | `process_pr_reviewer` candidate filtering | `security_medium_pr_reviewer_test.sh`: candidate filtering keeps head pattern and fork exclusion | `bash local-watcher/test/security_medium_pr_reviewer_test.sh`: PASS | 対象 PR 判定ロジックは変更なし |
| 2.1 | `pr_execute_review_command`, `pr_run_review_for_pr` | workspace preparation failure handling | `pr_reviewer_worktree_workspace_test.sh`: operator log に PR 番号 / head branch / checkout 衝突分類を残す | `bash local-watcher/test/pr_reviewer_worktree_workspace_test.sh`: PASS | SHA と tool も error log に含める |
| 2.2 | `pr_classify_review_workspace_failure`, `pr_run_review_for_pr` | workspace preparation failure handling | `pr_reviewer_worktree_workspace_test.sh`: operator log に checkout 衝突分類を残す | `bash local-watcher/test/pr_reviewer_worktree_workspace_test.sh`: PASS | `checkout-conflict` 分類を明示 |
| 2.3 | `pr_run_review_for_pr`, `pr_post_error_comment` | workspace preparation failure handling | `pr_reviewer_worktree_workspace_test.sh`: workspace 準備失敗は errored / 人間可視の失敗 marker kind を投稿する | `bash local-watcher/test/pr_reviewer_worktree_workspace_test.sh`: PASS | `workspace-prepare-failed` marker |
| 2.4 | `pr_run_review_for_pr`, `pr_post_error_comment` | workspace preparation failure handling | `pr_reviewer_worktree_workspace_test.sh`: workspace 準備失敗は errored として扱う | `bash local-watcher/test/pr_reviewer_worktree_workspace_test.sh`: PASS | review marker は付けない |
| 2.5 | `pr_git_error_excerpt`, `pr_run_review_for_pr` | public error comment generation | `pr_reviewer_worktree_workspace_test.sh`: public comment は分類だけを含む / `security_medium_pr_reviewer_test.sh`: exec-failed public comment is redacted | `bash local-watcher/test/pr_reviewer_worktree_workspace_test.sh`: PASS; `bash local-watcher/test/security_medium_pr_reviewer_test.sh`: PASS | raw stderr は operator log の短い要約のみ |
| 3.1 | 既存 `pr_post_review_comment`, `pr_build_marker` | successful review comment posting | `pr_reviewer_approval_signal_test.sh`: approve comment marker を残す | `bash local-watcher/test/pr_reviewer_approval_signal_test.sh`: PASS | review marker 契約は変更なし |
| 3.2 | `pr_post_error_comment`, `pr_run_review_for_pr` | workspace failure comment posting | `pr_reviewer_worktree_workspace_test.sh`: 人間可視の失敗 marker kind を投稿する | `bash local-watcher/test/pr_reviewer_worktree_workspace_test.sh`: PASS | 重複抑止は既存 `(sha, kind)` 判定を利用 |
| 3.3 | `pr_already_processed`, `pr_post_error_comment` | marker lookup before review / error comment | `pr_reviewer_worktree_workspace_test.sh`: workspace failure marker kind; `pr_reviewer_approval_signal_test.sh`: marker fallback | `bash local-watcher/test/pr_reviewer_worktree_workspace_test.sh`: PASS; `bash local-watcher/test/pr_reviewer_approval_signal_test.sh`: PASS | SHA が変われば marker は一致しない |
| 3.4 | 既存 `pr_already_processed` | review duplicate skip | `pr_reviewer_approval_signal_test.sh`: review marker flow | `bash local-watcher/test/pr_reviewer_approval_signal_test.sh`: PASS | 同一 SHA の review marker skip は変更なし |
| 4.1 | 既存 `process_pr_reviewer` opt-in gate | watcher cycle entrypoint | `pr_reviewer_worktree_workspace_test.sh`: `PR_REVIEWER_ENABLED!=true` では PR を列挙しない / `security_medium_pr_reviewer_test.sh`: disabled processor remains no-op | `bash local-watcher/test/pr_reviewer_worktree_workspace_test.sh`: PASS; `bash local-watcher/test/security_medium_pr_reviewer_test.sh`: PASS | opt-in gate は変更なし |
| 4.2 | 既存 `pr_resolve_review_verdict`, `pr_add_iteration_label` | review output handling | `pr_reviewer_approval_signal_test.sh`: iteration label を付ける | `bash local-watcher/test/pr_reviewer_approval_signal_test.sh`: PASS | VERDICT 連携は変更なし |
| 4.3 | 既存 `pr_try_post_formal_approval`, `pr_post_review_comment` | review output handling | `pr_reviewer_approval_signal_test.sh`: approve は formal approval / marker comment を残す | `bash local-watcher/test/pr_reviewer_approval_signal_test.sh`: PASS | approve signal 連携は変更なし |
| 4.4 | `pr_execute_review_command`, README | PR Reviewer runtime contract | `shellcheck local-watcher/bin/*.sh install.sh setup.sh .github/scripts/*.sh` / `git diff --check` | PASS | env var / label / cron 契約は変更なし |
| 4.5 | N/A | Scope control | Review of diff | N/A | tool installation / auth / review quality は変更なし |
| 5.1 | `pr_execute_review_command` | PR Reviewer review command execution | `pr_reviewer_worktree_workspace_test.sh`: branch checkout 済み別 worktree があってもレビュー実行へ進む | `bash local-watcher/test/pr_reviewer_worktree_workspace_test.sh`: PASS | 実 git worktree で回帰検証 |
| 5.2 | `pr_execute_review_command`, `pr_cleanup_review_workspace` | PR Reviewer workspace preparation | `pr_reviewer_worktree_workspace_test.sh`: 実装用 slot は head branch のまま / 未保存 untracked を破棄しない | `bash local-watcher/test/pr_reviewer_worktree_workspace_test.sh`: PASS | slot worktree を変更しない |
| 5.3 | `pr_run_review_for_pr`, `pr_post_error_comment` | workspace preparation failure handling | `pr_reviewer_worktree_workspace_test.sh`: workspace 準備失敗は errored / marker kind を投稿する | `bash local-watcher/test/pr_reviewer_worktree_workspace_test.sh`: PASS | operator log と PR comment の両方を確認 |
| 5.4 | `process_pr_reviewer` | watcher cycle entrypoint | `pr_reviewer_worktree_workspace_test.sh`: opt-out では PR を列挙しない | `bash local-watcher/test/pr_reviewer_worktree_workspace_test.sh`: PASS | opt-out no-op |
| 5.5 | `README.md` | Documentation | README diff review | `git diff --check`: PASS | PR Reviewer Processor 節を更新 |

## Verification

- `bash local-watcher/test/pr_reviewer_worktree_workspace_test.sh` — PASS
- `bash local-watcher/test/pr_reviewer_approval_signal_test.sh` — PASS
- `bash local-watcher/test/pr_reviewer_exec_fail_streak_test.sh` — PASS
- `bash local-watcher/test/pr_reviewer_quota_marker_test.sh` — PASS
- `bash local-watcher/test/pr_reviewer_second_gate_test.sh` — PASS
- `bash local-watcher/test/security_medium_pr_reviewer_test.sh` — PASS
- `shellcheck --severity=warning local-watcher/bin/idd-codex-modules/pr-reviewer.sh local-watcher/test/pr_reviewer_worktree_workspace_test.sh` — PASS
- `shellcheck local-watcher/bin/*.sh install.sh setup.sh .github/scripts/*.sh` — PASS
- `git diff --check` — PASS

STATUS: complete
