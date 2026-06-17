# Issue #58 タスク

## 実装タスク

### 1. failed recovery preflight と既存 branch resume を確認する

`codex-failed` 復旧対象で既存 origin branch がある場合は fresh run ではなく既存 branch から resume し、OPEN / MERGED impl PR がある場合は既存ガードで skip されることを確認する。

_Requirements:_ 1.1, 1.2, 1.3, 1.4, 2.1, 2.2
_Boundary:_ `local-watcher/bin/idd-codex-issue-watcher.sh`, `local-watcher/test/failed_recovery_worktree_test.sh`
_Depends:_ requirements.md

### 2. unsafe stale worktree を人間判断へ退避する

inactive clean stale slot worktree の detach を維持しつつ、tracked dirty、untracked、local-only commit、origin branch 不在、管理外、active slot は自動破棄せず `codex-needs-decisions` へ移す。

_Requirements:_ 2.3, 2.4, 3.1, 3.2, 3.3, 3.4, 4.1, 4.2, 4.3, 4.4, 4.5
_Boundary:_ `local-watcher/bin/idd-codex-issue-watcher.sh`, `local-watcher/test/failed_recovery_worktree_test.sh`
_Depends:_ 1

### 3. slot reuse reset と checkout busy retry を検証する

slot reuse 時に旧 Issue branch ref を base reset で汚染しないこと、checkout busy 時の stale worktree recovery が成功時も失敗時も 1 回だけで止まることを確認する。

_Requirements:_ 5.1, 5.2, 5.3, 6.1, 6.2, 6.3, 6.4, 8.4, 8.5
_Boundary:_ `local-watcher/bin/idd-codex-modules/core_utils.sh`, `local-watcher/bin/idd-codex-issue-watcher.sh`, `local-watcher/test/failed_recovery_worktree_test.sh`
_Depends:_ 1, 2

### 4. ドキュメントと検証結果を同期する

README の failed recovery 説明と実装挙動が矛盾しないことを確認し、Developer の補足は `impl-notes.md` に記録する。

_Requirements:_ 7.1, 7.2, 7.3, 7.4, 8.1, 8.2, 8.3, 8.6
_Boundary:_ `README.md`, `docs/specs/58-feat-watcher-codex-failed-branch-resume/impl-notes.md`, `docs/specs/58-feat-watcher-codex-failed-branch-resume/tasks.md`
_Depends:_ 1, 2, 3
