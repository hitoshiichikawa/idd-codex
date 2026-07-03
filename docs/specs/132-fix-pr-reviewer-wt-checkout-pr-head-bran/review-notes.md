# Review Notes

<!-- idd-codex:review round=1 model=gpt-5.5 timestamp=2026-07-03T01:18:43Z -->

## Reviewed Scope

- Branch: codex/issue-132-impl-fix-pr-reviewer-wt-checkout-pr-head-bran
- HEAD commit: 26a6cf13e2654fab2e78bce9d499420f7f08652c
- Compared to: main..HEAD

## Verified Requirements

- 1.1 - `pr_execute_review_command` は `origin/<head>` を detached review worktree に追加して実行し、別 worktree の head branch checkout と衝突しない。`local-watcher/test/pr_reviewer_worktree_workspace_test.sh:182`
- 1.2 - review workspace は detached HEAD で動き、実装用 slot の checkout 状態に依存しない。`local-watcher/test/pr_reviewer_worktree_workspace_test.sh:183`
- 1.3 - cleanup 対象は一時 review worktree / temp dir に限定され、slot branch と untracked file の保持を検証している。`local-watcher/test/pr_reviewer_worktree_workspace_test.sh:185`
- 1.4 - main repo の branch 状態と一時 worktree cleanup を検証しており、PR 間で workspace 状態を残さない。`local-watcher/test/pr_reviewer_worktree_workspace_test.sh:187`
- 1.5 - 候補 PR 判定は既存の open / non-draft / head pattern / non-fork filter を維持している。`local-watcher/bin/idd-codex-modules/pr-reviewer.sh:283`
- 2.1 - workspace 準備失敗時に分類・head・reason を log し、統括側で PR 番号・head SHA・分類を operator-visible log に残す。`local-watcher/bin/idd-codex-modules/pr-reviewer.sh:681`, `local-watcher/bin/idd-codex-modules/pr-reviewer.sh:1522`
- 2.2 - git stderr から worktree checkout conflict を `checkout-conflict` に分類する。`local-watcher/bin/idd-codex-modules/pr-reviewer.sh:580`
- 2.3 - workspace 準備失敗は `workspace-prepare-failed` marker の PR comment として人間可視化される。`local-watcher/bin/idd-codex-modules/pr-reviewer.sh:1526`
- 2.4 - workspace 準備失敗は `workspace-fail:*` として review marker を付けず `return 3` し、current SHA をレビュー済みにしない。`local-watcher/bin/idd-codex-modules/pr-reviewer.sh:1518`
- 2.5 - public comment は failure classification 等に限定され、raw stderr は operator log 用 excerpt に限定される。`local-watcher/bin/idd-codex-modules/pr-reviewer.sh:555`, `local-watcher/test/pr_reviewer_worktree_workspace_test.sh:241`
- 3.1 - 成功時の `kind=review` marker 投稿は既存経路で維持される。`local-watcher/bin/idd-codex-modules/pr-reviewer.sh:1605`, `local-watcher/test/pr_reviewer_approval_signal_test.sh:256`
- 3.2 - error comment 投稿は既存の `(sha, kind)` 重複判定に委譲され、workspace failure は `workspace-prepare-failed` kind を使う。`local-watcher/bin/idd-codex-modules/pr-reviewer.sh:247`, `local-watcher/bin/idd-codex-modules/pr-reviewer.sh:1526`
- 3.3 - marker 判定は current SHA と kind の一致のみを見るため、head SHA 更新時は old SHA marker だけで skip されない。`local-watcher/bin/idd-codex-modules/pr-reviewer.sh:259`
- 3.4 - current SHA の `kind=review` marker がある場合の skip は維持されている。`local-watcher/bin/idd-codex-modules/pr-reviewer.sh:1448`
- 4.1 - `PR_REVIEWER_ENABLED != true` では PR を列挙せず return する。`local-watcher/bin/idd-codex-modules/pr-reviewer.sh:1696`, `local-watcher/test/pr_reviewer_worktree_workspace_test.sh:249`
- 4.2 - `VERDICT: codex-needs-iteration` の label 連携は既存 approval signal test で維持されている。`local-watcher/bin/idd-codex-modules/pr-reviewer.sh:1611`, `local-watcher/test/pr_reviewer_approval_signal_test.sh:282`
- 4.3 - `VERDICT: approve` の formal approval / marker fallback 連携は既存 approval signal test で維持されている。`local-watcher/bin/idd-codex-modules/pr-reviewer.sh:1601`, `local-watcher/test/pr_reviewer_approval_signal_test.sh:248`
- 4.4 - 既存 env var / label / cron 契約は変更されず、差分は workspace 準備 token と README marker kind 追加に限定されている。`README.md:2582`
- 4.5 - reviewer tool のインストール、認証、レビュー品質改善の追加は差分に含まれない。`git diff --stat main..HEAD`
- 5.1 - head branch が別 worktree で checkout 済みの実 git worktree 回帰テストが追加されている。`local-watcher/test/pr_reviewer_worktree_workspace_test.sh:175`
- 5.2 - 実装用 slot の branch と untracked file が保持されることをテストしている。`local-watcher/test/pr_reviewer_worktree_workspace_test.sh:185`
- 5.3 - unrecoverable workspace failure の operator log と human-visible marker comment をテストしている。`local-watcher/test/pr_reviewer_worktree_workspace_test.sh:235`
- 5.4 - opt-out no-op を専用テストで確認している。`local-watcher/test/pr_reviewer_worktree_workspace_test.sh:249`
- 5.5 - README は detached review worktree と workspace 準備失敗時の確認先を説明している。`README.md:2540`, `README.md:2559`
- NFR 1.1 - 既存 marker 形式は compatible に `workspace-prepare-failed` kind を追加し、既存 env var / label 名は変更されていない。`README.md:2582`
- NFR 1.2 - disabled path は PR 列挙前に return し、副作用なしをテストしている。`local-watcher/bin/idd-codex-modules/pr-reviewer.sh:1697`, `local-watcher/test/pr_reviewer_worktree_workspace_test.sh:256`
- NFR 1.3 - PR Reviewer disabled repo に migration を要求する差分はない。`README.md:2478`
- NFR 2.1 - 実装用 slot worktree を checkout / reset / clean せず、一時 review worktree のみ cleanup する。`local-watcher/bin/idd-codex-modules/pr-reviewer.sh:605`
- NFR 2.2 - workspace 準備不能時は visible comment と error log に倒し、silent skip しない。`local-watcher/bin/idd-codex-modules/pr-reviewer.sh:1522`
- NFR 2.3 - git / reviewer execution は既存 timeout env を継続利用している。`local-watcher/bin/idd-codex-modules/pr-reviewer.sh:678`, `local-watcher/bin/idd-codex-modules/pr-reviewer.sh:700`
- NFR 3.1 - head branch 等は既存候補 filter と placeholder validation 経路を維持している。`local-watcher/bin/idd-codex-modules/pr-reviewer.sh:283`, `local-watcher/bin/idd-codex-modules/pr-reviewer.sh:1506`
- NFR 3.2 - PR head ref は既存 head pattern / same-owner filter 後に処理される。`local-watcher/bin/idd-codex-modules/pr-reviewer.sh:297`
- NFR 3.3 - 新しい外部サービス呼び出しは追加されておらず、既存 reviewer tool と GitHub CLI 経路内の workspace 準備変更に留まる。`git diff --stat main..HEAD`

## Findings

なし

## Summary

AC 対応の実装、回帰テスト、README 更新を確認した。`tasks.md` と `design.md` は存在しないため `_Boundary:_` アノテーション照合はできなかったが、差分は requirements / impl-notes の対象範囲内で、境界逸脱として扱う変更は検出しなかった。

Reviewer 実行確認: `bash local-watcher/test/pr_reviewer_worktree_workspace_test.sh` と `shellcheck --severity=warning local-watcher/bin/idd-codex-modules/pr-reviewer.sh local-watcher/test/pr_reviewer_worktree_workspace_test.sh` は PASS。

RESULT: approve
