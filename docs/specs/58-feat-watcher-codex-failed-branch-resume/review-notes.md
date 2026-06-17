# Review Notes

<!-- idd-codex:review round=2 model=gpt-5.5 timestamp=2026-06-17T08:11:25Z -->

## Reviewed Scope

- Branch: codex/issue-58-impl-feat-watcher-codex-failed-branch-resume
- HEAD commit: d61d25b28f6894a39362d627c346ec39415bbe4e
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `local-watcher/bin/idd-codex-issue-watcher.sh:10617` で通常 `impl` でも既存 origin branch を検出した場合に failed recovery resume 経路へ入り、`local-watcher/test/failed_recovery_worktree_test.sh:221` から既存 branch checkout を検証している。
- 1.2 — `check_existing_impl_pr` の OPEN / MERGED 既存 PR ガードは差分で変更されておらず、resume 分岐は既存 PR ガード通過後の `_slot_run_issue` 内に限定されている。
- 1.3 — `local-watcher/bin/idd-codex-issue-watcher.sh:10630` 以降で origin branch が無い通常 `impl` は base 起点作成に進み、`local-watcher/test/failed_recovery_worktree_test.sh:281` から fresh no-origin 正常系を検証している。
- 1.4 — `local-watcher/bin/idd-codex-issue-watcher.sh:10624` から `failed-recovery-mode=existing-branch` と origin SHA を slot log に記録する。
- 2.1 — `local-watcher/bin/idd-codex-issue-watcher.sh:10621` で `origin/$BRANCH` を checkout 起点にする。
- 2.2 — 既存 branch resume 経路では `origin/${BASE_BRANCH}` ではなく `origin/$BRANCH` が渡され、fresh no-origin は別分岐に分離されている。
- 2.3 — `local-watcher/bin/idd-codex-issue-watcher.sh:8855` から origin branch 不在かつ local stale branch がある場合に `codex-needs-decisions` へ退避し、`local-watcher/test/failed_recovery_worktree_test.sh:246` と `293` で検証している。
- 2.4 — `local-watcher/bin/idd-codex-issue-watcher.sh:8864` から管理外 worktree を退避し、local branch safety 判定も `_failed_recovery_prepare_branch_checkout` の前段で維持されている。
- 3.1 — `local-watcher/bin/idd-codex-issue-watcher.sh:8906` から inactive clean stale slot を detached HEAD へ戻す。
- 3.2 — `local-watcher/test/failed_recovery_worktree_test.sh:221` から detach 後に current slot が branch checkout できることを検証している。
- 3.3 — `local-watcher/bin/idd-codex-issue-watcher.sh:8916` で stale worktree detach の branch / slot / worktree を slot log に記録する。
- 3.4 — `local-watcher/bin/idd-codex-issue-watcher.sh:8879` から active slot lock 取得失敗時に `codex-needs-decisions` へ退避する。
- 4.1 — `local-watcher/test/failed_recovery_worktree_test.sh:237` から tracked dirty stale worktree を自動破棄せず退避することを検証している。
- 4.2 — `local-watcher/test/failed_recovery_worktree_test.sh:229` から untracked stale worktree を自動破棄せず退避することを検証している。
- 4.3 — `local-watcher/test/failed_recovery_worktree_test.sh:267` から local-only commit を自動破棄しないことを検証している。
- 4.4 — `local-watcher/bin/idd-codex-issue-watcher.sh:8864` から管理外 worktree を自動 detach しない。
- 4.5 — `_failed_recovery_escalate_needs_decisions` 経路に branch、worktree、阻害理由、次アクションが含まれ、各 unsafe ケースで `DECISION_COUNT=1` を検証している。
- 5.1 — `local-watcher/bin/idd-codex-modules/core_utils.sh:317` から reset 前に detached HEAD へ移動する。
- 5.2 — `local-watcher/bin/idd-codex-modules/core_utils.sh:322` の `checkout --detach --force origin/${BASE_BRANCH}` により旧 Issue branch ref を checkout したまま reset しない。
- 5.3 — `local-watcher/test/failed_recovery_worktree_test.sh:255` から reset-corruption 復旧後に origin branch HEAD を復元できることを検証している。
- 6.1 — `local-watcher/bin/idd-codex-issue-watcher.sh:8953` から worktree busy checkout 失敗時だけ recovery を試行し、`local-watcher/test/failed_recovery_worktree_test.sh:310` から 1 回試行を検証している。
- 6.2 — `local-watcher/bin/idd-codex-issue-watcher.sh:8957` から recovery 成功時に checkout を再試行し、`local-watcher/test/failed_recovery_worktree_test.sh:317` から成功系を検証している。
- 6.3 — `local-watcher/bin/idd-codex-issue-watcher.sh:8970` から recovery 失敗時は再試行せず返り、`local-watcher/test/failed_recovery_worktree_test.sh:325` から checkout 再試行なしを検証している。
- 6.4 — `local-watcher/bin/idd-codex-issue-watcher.sh:8922` の matcher 成功時だけ `8953` の recovery 分岐に入るため、busy 相当でない checkout 失敗には stale worktree recovery を適用しない。
- 7.1 — 差分は env var、ラベル名、cron / launchd 起動契約、exit code 意味を変更していない。
- 7.2 — README の failed recovery 説明は既存記述で維持され、実装差分と矛盾していない。
- 7.3 — `README.md:1004` から既存 origin branch resume、clean stale detach、unsafe worktree の `codex-needs-decisions` 退避を説明している。
- 7.4 — `README.md:3631` と `README.md:3697` から origin branch が無い fresh Issue の既定挙動維持を説明している。
- 8.1 — `local-watcher/test/failed_recovery_worktree_test.sh:221` から既存 origin branch から current slot が初期化できることを検証している。
- 8.2 — `local-watcher/test/failed_recovery_worktree_test.sh:221` から inactive clean stale worktree の detach と resume を検証している。
- 8.3 — `local-watcher/test/failed_recovery_worktree_test.sh:229` と `237` で untracked / tracked dirty、`267` で local-only commit の退避を検証している。
- 8.4 — `local-watcher/test/failed_recovery_worktree_test.sh:255` から reset-corruption 復旧で旧 branch ref が base に固定されないことを検証している。
- 8.5 — `local-watcher/test/failed_recovery_worktree_test.sh:310` と `325` で checkout busy recovery の成功 / 失敗が 1 回だけで止まることを検証している。
- 8.6 — `local-watcher/test/failed_recovery_worktree_test.sh:281` から fresh Issue no-origin の既定挙動維持を検証している。

## Findings

なし

## Summary

round=1 の missing test 指摘だった tracked dirty stale worktree と recovery 失敗時の 1 回限り制御は、追加テストで検証されている。差分は tasks.md の `_Boundary:_` 内に収まり、AC 未カバー / missing test / boundary 逸脱は確認しなかった。

検証実行: `bash local-watcher/test/failed_recovery_worktree_test.sh` 成功（PASS: 38, FAIL: 0）。`shellcheck local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/idd-codex-modules/core_utils.sh local-watcher/test/failed_recovery_worktree_test.sh` 成功。

RESULT: approve
