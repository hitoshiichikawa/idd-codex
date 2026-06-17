# Issue #58 実装メモ

## 実装結果

過去 PR #59 相当の実装は概ね main 側に取り込み済みだったが、確認中に以下の不足を見つけたため最小修正した。

- `local-watcher/bin/idd-codex-issue-watcher.sh`
  - checkout 失敗時の worktree 使用中判定に、Git が返す `is already checked out at` 形式を追加した。
  - origin branch が無い fresh 起点の branch 作成前にも `_failed_recovery_prepare_branch_checkout` を通し、同名 local-only branch を stale slot が checkout している場合に `git checkout -B` で branch ref を上書きしないようにした。
  - stderr 一時ファイル削除を shellcheck clean な `if` 形式へ整理した。
- `local-watcher/test/failed_recovery_worktree_test.sh`
  - 既存 origin branch resume、clean stale detach、dirty / local-only stale の `codex-needs-decisions` 退避、reset-corruption 復旧に加え、fresh no-origin 正常系、fresh no-origin local stale 停止、checkout busy 検出、checkout busy 時の 1 回限り retry を検証するケースを追加した。

README.md は既に `codex-failed` 復旧手順で、既存 origin branch resume、inactive clean stale worktree の自動 detach、unsafe worktree の `codex-needs-decisions` 退避、origin branch が無い fresh Issue の既定挙動維持を説明していたため変更なし。

## 要件対応

- Requirement 1: Dispatcher の `check_existing_impl_pr` が OPEN / MERGED impl PR を claim 前に skip し、origin branch がある `impl` は `failed-recovery-mode=existing-branch` として記録することを確認した。
- Requirement 2: 既存 origin branch ありの resume は `origin/$BRANCH` 起点、origin branch なしの unsafe stale は `codex-needs-decisions` へ退避するよう補強した。
- Requirement 3: inactive clean stale slot worktree は detach され、current slot が checkout できることをテストで確認した。
- Requirement 4: dirty / local-only commit / origin branch なし local stale は自動破棄せず `codex-needs-decisions` へ退避することをテストで確認した。
- Requirement 5: `_worktree_reset` が reset 前に `checkout --detach --force origin/$BASE_BRANCH` を行い、旧 Issue branch ref を base へ動かさないことを確認した。
- Requirement 6: `already used by worktree` と `is already checked out at` を worktree 使用中として扱い、recovery が 1 回だけ呼ばれることをテストで確認した。
- Requirement 7: 既存 env var、ラベル名、cron / launchd 起動契約、exit code 意味は変更していない。README の説明も実装と矛盾しないことを確認した。
- Requirement 8: `failed_recovery_worktree_test.sh` に主要分岐の回帰検証を追加した。

## 検証結果

- `bash local-watcher/test/failed_recovery_worktree_test.sh` 成功（PASS: 29, FAIL: 0）
- `shellcheck local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/idd-codex-modules/core_utils.sh local-watcher/test/failed_recovery_worktree_test.sh` 成功

## 確認事項

なし。

## Reviewer round=1 reject 是正

Reviewer 指摘に基づき、実装変更ではなく回帰テストと境界 artifact を補強した。

- `local-watcher/test/failed_recovery_worktree_test.sh`
  - stale slot 側の tracked file (`feature.txt`) を変更するケースを追加し、`_failed_recovery_prepare_branch_checkout "$BRANCH" "true"` が `rc=20`、`codex-needs-decisions` 1 回、stale slot は branch checkout のまま、current slot は detached のままであることを検証した。
  - checkout busy 後の recovery が `rc=20` で失敗するケースを追加し、recovery 呼び出しが 1 回だけ、checkout 再試行なし、`codex-needs-decisions` 1 回、`codex-failed` へは進まないことを検証した。
- `docs/specs/58-feat-watcher-codex-failed-branch-resume/tasks.md`
  - 履歴上に既存 `tasks.md` / `design.md` が存在しなかったため、Reviewer が境界判定できる最小の `tasks.md` を追加した。

検証結果:

- `bash local-watcher/test/failed_recovery_worktree_test.sh` 成功
- `shellcheck local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/idd-codex-modules/core_utils.sh local-watcher/test/failed_recovery_worktree_test.sh` 成功
