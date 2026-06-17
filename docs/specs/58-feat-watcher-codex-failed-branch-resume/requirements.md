# Issue #58 要件定義

## 背景

`codex-failed` から復旧した Issue が再度 pickup されるとき、過去 run で作成・push 済みの `codex/issue-<N>-impl-*` branch が存在していても、watcher が fresh run と同じ扱いで slot を初期化すると、既存作業を引き継げず復旧に失敗する。

特に、過去 run の slot worktree が同じ Issue branch を checkout したまま残っている場合、別 slot が同じ branch を checkout しようとして Git の worktree 制約により `already used by worktree` 相当の失敗になる。また、slot reuse 時に旧 Issue branch を checkout したまま base へ reset すると、旧 branch ref 自体を base 側へ動かしてしまうリスクがある。

本 Issue は、`codex-failed` 復旧時に既存 origin branch を安全に resume し、stale slot worktree の状態に応じて自動復旧または人間判断へ分岐し、fresh Issue の既定挙動は維持することを目的とする。

## スコープ

1.1 `codex-failed` 復旧対象 Issue の dispatch 前 preflight。

1.2 同一 Issue の既存 `origin/codex/issue-<N>-impl-*` branch を使った resume 初期化。

1.3 stale slot worktree が同じ branch を checkout 済みの場合の安全な扱い。

1.4 slot reuse 時に旧 Issue branch ref を base reset で汚染しないこと。

1.5 `already used by worktree` 相当の checkout 失敗時の 1 回限りの復旧試行。

1.6 README など運用者向けドキュメントへの failed recovery 挙動の説明。

## スコープ外

2.1 `codex-failed` 以外のラベル体系や既存ラベル名の変更。

2.2 fresh Issue で origin branch が存在しない場合の既存 dispatch 挙動の変更。

2.3 OPEN または MERGED の impl PR が存在する Issue の resume 判定変更。

2.4 人間判断が必要な dirty / untracked worktree の自動破棄。

2.5 既存 env var 名、cron / launchd 起動契約、exit code 意味の変更。

## Requirements

### Requirement 1: failed recovery preflight の分類

`codex-failed` 復旧対象 Issue は、fresh run として処理される前に、既存 branch resume の対象かどうかを判定できる。

#### Acceptance Criteria

1.1 When `codex-failed` から復旧した Issue が pickup され、同一 Issue の `origin/codex/issue-<N>-impl-*` branch が存在し、OPEN または MERGED の impl PR が存在しないとき, the watcher shall fresh run ではなく既存 branch resume 対象として slot 初期化へ進む。

1.2 When `codex-failed` から復旧した Issue が pickup され、同一 Issue の OPEN または MERGED の impl PR が存在するとき, the watcher shall 既存 branch resume 対象として扱わない。

1.3 When fresh Issue が pickup され、同一 Issue の origin branch が存在しないとき, the watcher shall 既存の fresh run 挙動を維持する。

1.4 When failed recovery preflight が Issue を既存 branch resume 対象として分類するとき, the watcher shall resume 対象 branch と分類理由を運用者が追跡できる形で記録する。

### Requirement 2: 既存 origin branch からの slot 初期化

既存 branch resume 対象の Issue は、base branch ではなく既存 origin branch の内容から作業を再開できる。

#### Acceptance Criteria

2.1 When 既存 branch resume 対象の Issue の slot が初期化されるとき, the watcher shall `origin/codex/issue-<N>-impl-*` の内容を作業開始点として使用する。

2.2 When 既存 branch resume 対象の Issue の slot が初期化されるとき, the watcher shall `origin/<BASE_BRANCH>` を作業開始点として既存作業を上書きしない。

2.3 If 既存 branch resume 対象の origin branch が初期化時点で確認できないとき, the watcher shall Issue を自動復旧せず `codex-needs-decisions` へ移し、必要な人間判断を説明するコメントを残す。

2.4 If 既存 branch resume 対象の branch が管理対象として安全に扱えない名前または状態であるとき, the watcher shall Issue を自動復旧せず `codex-needs-decisions` へ移し、必要な人間判断を説明するコメントを残す。

### Requirement 3: inactive clean stale worktree の自動復旧

同じ branch を checkout 済みの stale slot worktree が inactive かつ clean であれば、現在の slot で resume できるように安全に解放される。

#### Acceptance Criteria

3.1 When target branch が inactive clean slot worktree で checkout 済みのとき, the watcher shall その stale worktree を branch から detach する。

3.2 When stale worktree の detach が完了したとき, the watcher shall current slot で target branch の checkout を再試行できる状態にする。

3.3 When stale worktree の detach が完了したとき, the watcher shall stale worktree に未保存変更がなかったことを運用者が追跡できる形で記録する。

3.4 If stale worktree が inactive でないとき, the watcher shall その worktree を自動 detach せず `codex-needs-decisions` へ移し、必要な人間判断を説明するコメントを残す。

### Requirement 4: unsafe stale worktree の人間判断

同じ branch を checkout 済みの stale slot worktree が dirty、untracked、未 push、管理外、または active の場合、watcher は作業を破棄せず人間判断へ委ねる。

#### Acceptance Criteria

4.1 When target branch が inactive dirty slot worktree で checkout 済みのとき, the watcher shall その worktree を自動破棄せず Issue を `codex-needs-decisions` へ移す。

4.2 When target branch が inactive untracked slot worktree で checkout 済みのとき, the watcher shall その worktree を自動破棄せず Issue を `codex-needs-decisions` へ移す。

4.3 When target branch が未 push の作業を含む slot worktree で checkout 済みのとき, the watcher shall その worktree を自動破棄せず Issue を `codex-needs-decisions` へ移す。

4.4 When target branch が管理対象として安全に識別できない worktree で checkout 済みのとき, the watcher shall その worktree を自動破棄せず Issue を `codex-needs-decisions` へ移す。

4.5 When watcher が unsafe stale worktree により Issue を `codex-needs-decisions` へ移すとき, the watcher shall branch 名、該当 worktree、阻害理由、運用者が選べる次アクションを含む actionable comment を残す。

### Requirement 5: slot reuse reset の branch ref 保護

slot worktree を再利用するとき、旧 Issue branch を checkout したまま base へ reset して branch ref を汚染しない。

#### Acceptance Criteria

5.1 When slot worktree が reuse のために reset されるとき, the watcher shall 旧 Issue branch を checkout した状態のまま `origin/<BASE_BRANCH>` へ hard reset しない。

5.2 When slot worktree が旧 Issue branch を checkout した状態で reuse されるとき, the watcher shall 旧 Issue branch ref が base branch の内容へ移動しない状態を確保してから reset する。

5.3 When slot worktree reset が完了するとき, the watcher shall 次の Issue の branch checkout を旧 Issue branch ref に影響させず開始できる状態にする。

### Requirement 6: checkout 失敗時の 1 回限りの stale worktree recovery

branch checkout が worktree 使用中により失敗した場合、watcher は `codex-failed` へ進む前に stale worktree recovery を 1 回だけ試行する。

#### Acceptance Criteria

6.1 If target branch checkout が `already used by worktree` 相当の理由で失敗するとき, the watcher shall Issue を `codex-failed` にする前に stale worktree recovery を 1 回試行する。

6.2 When stale worktree recovery の 1 回目が成功するとき, the watcher shall target branch checkout を再試行して resume 処理を継続する。

6.3 If stale worktree recovery の 1 回目が失敗するとき, the watcher shall 同じ checkout 失敗に対して recovery を繰り返さず、Issue を安全な失敗状態または `codex-needs-decisions` へ移す。

6.4 When checkout 失敗理由が `already used by worktree` 相当ではないとき, the watcher shall stale worktree recovery を誤って適用しない。

### Requirement 7: 後方互換と運用可視性

本変更は既存 watcher 契約を壊さず、運用者が failed recovery の判断と結果を追跡できる。

#### Acceptance Criteria

7.1 When failed recovery support が適用されるとき, the watcher shall 既存 env var 名、ラベル名、cron / launchd 起動契約、exit code 意味を変更しない。

7.2 When failed recovery support が適用されるとき, the watcher shall `local-watcher/` と `README.md` に関連する運用者向け説明を実際の挙動と矛盾しない状態にする。

7.3 When README が `codex-failed` 復旧を説明するとき, the documentation shall 既存 origin branch resume、stale clean worktree の自動 detach、unsafe worktree の `codex-needs-decisions` 退避を説明する。

7.4 When README が fresh Issue の開始条件を説明するとき, the documentation shall origin branch がない fresh Issue の既定挙動が維持されることを説明する。

### Requirement 8: 回帰検証

レビュワーは、failed recovery と stale worktree の主要分岐が再発防止として検証されていることを確認できる。

#### Acceptance Criteria

8.1 When regression verification covers failed Issue retry with an existing origin branch and no OPEN or MERGED impl PR, the verification shall 既存 origin branch から slot が初期化されることを確認する。

8.2 When regression verification covers inactive clean stale worktree, the verification shall stale worktree が自動 detach され current slot で resume できることを確認する。

8.3 When regression verification covers inactive dirty or untracked stale worktree, the verification shall worktree が自動破棄されず Issue が `codex-needs-decisions` へ移ることを確認する。

8.4 When regression verification covers slot reuse reset with a previous Issue branch checked out, the verification shall 旧 Issue branch ref が base branch の内容へ移動しないことを確認する。

8.5 When regression verification covers checkout failure with `already used by worktree`, the verification shall stale worktree recovery が 1 回だけ試行されることを確認する。

8.6 When regression verification covers fresh Issue with no origin branch, the verification shall 既存の fresh run 挙動が維持されることを確認する。

## Open Questions

- なし。

## Issue コメント反映

- owner コメントの「実装 PR を作成しました: #59」は既存作業の存在として認識したが、PM 成果物では PR 作成や実装内容の評価は行わない。
- owner コメントの「既存 origin branch がある failed recovery は fresh run にせず既存 branch から resume」を Requirement 1 と Requirement 2 に反映した。
- owner コメントの「stale clean slot worktree は自動 detach」を Requirement 3 に反映した。
- owner コメントの「dirty / 未 push / origin branch 不在 / 管理外 / active slot は `codex-needs-decisions` に退避」を Requirement 2 と Requirement 4 に反映した。
- owner コメントの「slot reset 前に detached HEAD へ戻して旧 branch ref 汚染を防止」を Requirement 5 に反映した。
- Triage edit_paths の自動コメントにより、編集見込み top-level path は `local-watcher/` と `README.md` と認識した。

## PM 自己レビュー

- Mechanical Checks: numeric ID 見出し、各 Requirement の EARS 形式 AC、Open Questions の存在を確認した。
- 判断レビュー: Issue 本文の受入基準、failed recovery の既存 branch resume、stale clean worktree、unsafe worktree、人間判断、slot reuse reset、checkout 失敗時の 1 回限り recovery、fresh Issue の既定挙動維持、README 更新、回帰検証を網羅していることを確認した。
- 実装方針レビュー: 要件は operator-observable な挙動と境界に限定し、具体的な関数分割や内部実装手順は design に委ねていることを確認した。
