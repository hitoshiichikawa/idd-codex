# Requirements Document

## Introduction

per-task terminal failure 経路では、Reviewer / Debugger が失敗直前に `review-notes.md` や `debugger-notes.md` を作成しても、remote branch または Issue コメントに確実に保全されない場合がある。#23 の `per-task-reviewer-reject3` では、Issue コメントに実装 branch と artifact 参照が出た一方で、remote branch 上に reviewer artifacts が見つからず、復旧判断で混乱が発生した。

通常 Stage B の reject / approve 経路には push-state verify があるが、per-task terminal failure の一部経路では failure marking に直行し、失敗直前の push 状態や diagnostic artifact の保全が揃っていない。本件は、Reviewer / Debugger サブエージェントへ `git add` / `git commit` / `git push` / `gh` 権限を付与する問題ではなく、watcher / orchestrator が terminal failure 時に operator-visible な診断情報を保全するための bug fix である。

人間コメントにより、保全方式は Option C（watcher が diagnostic commit を試み、失敗時は Issue コメントへ fallback）を採用することが決定済みである。

## Related

- Related: #23

## Requirements

### Requirement 1: terminal failure artifact の保全

**Objective:** As an operator, I want per-task terminal failure 時の Reviewer / Debugger artifacts を unpushed worktree に依存せず確認できること, so that Issue コメントの参照先と実体のずれで復旧判断を誤らない。

#### Acceptance Criteria

1. When per-task terminal failure occurs after Reviewer or Debugger writes diagnostic artifacts, the watcher shall 人間が exact `review-notes.md` / `debugger-notes.md` content を確認できる情報を保全する。
2. When `review-notes.md` or `debugger-notes.md` exists only in an unpushed worktree at failure time, the watcher shall unpushed worktree だけを参照先にした failure comment で Issue を失敗扱いにしない。
3. If `review-notes.md` or `debugger-notes.md` is untracked or uncommitted at failure time, the watcher shall diagnostic artifact として operator-visible な保存先へ保全する。
4. When diagnostic artifacts are unavailable at failure time, the watcher shall artifact が存在しなかったことを failure diagnostic に明示する。

### Requirement 2: Option C による保全方式

**Objective:** As an operator, I want diagnostic commit が可能な場合は branch 履歴から artifacts を追跡でき、commit できない場合も Issue コメントから復旧できること, so that terminal failure 後の復旧起点を失わない。

#### Acceptance Criteria

1. When per-task terminal failure requires artifact preservation, the watcher shall まず watcher 責務の diagnostic commit による保全を試みる。
2. If watcher diagnostic commit preservation succeeds, the watcher shall failure diagnostic で保存済み commit を人間が識別できる情報を示す。
3. If watcher diagnostic commit preservation fails, the watcher shall Issue コメントへ artifact content または復旧判断に十分な要約を fallback として残す。
4. If watcher diagnostic commit preservation fails, the watcher shall diagnostic commit failure 自体を silent に扱わず、fallback したことを Issue コメントで明示する。
5. When fallback Issue comment is used, the watcher shall remote branch 上の artifact だけに依存しない復旧情報をコメント本文に含める。

### Requirement 3: failure comment の push-state 診断

**Objective:** As an operator, I want terminal failure 時点の branch と push 状態を Issue コメントだけで把握できること, so that local と remote のどちらを復旧起点にすべきか判断できる。

#### Acceptance Criteria

1. When per-task terminal failure occurs, the watcher shall failure comment に current branch を明記する。
2. When per-task terminal failure occurs, the watcher shall failure comment に local HEAD SHA を明記する。
3. When per-task terminal failure occurs, the watcher shall failure comment に origin branch HEAD SHA または未取得理由を明記する。
4. When per-task terminal failure occurs, the watcher shall failure comment に ahead count または算出不能理由を明記する。
5. When per-task terminal failure occurs, the watcher shall failure comment に worktree path を明記する。
6. When per-task terminal failure occurs, the watcher shall failure comment に relevant artifacts の tracked / untracked / uncommitted 状態を明記する。

### Requirement 4: subagent 権限境界の維持

**Objective:** As a workflow maintainer, I want Reviewer / Debugger の役割逸脱を防いだまま terminal failure artifacts を保全すること, so that 診断保全のために subagent へ破壊的な git 権限を戻さない。

#### Acceptance Criteria

1. The Reviewer subagent shall remain prohibited from running `git add`, `git commit`, `git push`, or `gh`.
2. The Debugger subagent shall remain prohibited from running `git add`, `git commit`, `git push`, or `gh`.
3. When preservation action is required after Reviewer or Debugger returns, the watcher shall preservation responsibility を subagent ではなく watcher / orchestrator 側の責務として扱う。
4. If artifact preservation fails, the watcher shall Reviewer / Debugger に git 権限を要求する復旧手順を failure diagnostic の前提にしない。

### Requirement 5: terminal failure 経路間の一貫性

**Objective:** As a maintainer, I want per-task terminal failure と非 per-task terminal failure の push-state 診断が実用上揃うこと, so that failure path によって operator-visible な復旧情報が欠落しない。

#### Acceptance Criteria

1. When per-task terminal failure path marks an Issue failed, the watcher shall push-state verification semantics を non-per-task terminal failure path と実用上同等にする。
2. When a terminal failure path cannot perform push-state verification, the watcher shall その理由を operator-visible な failure diagnostic に残す。
3. When per-task terminal failure occurs in reviewer reject terminal paths, the watcher shall artifact preservation and push-state diagnostics を failure marking 前に扱う。
4. When per-task terminal failure occurs in debugger terminal paths, the watcher shall artifact preservation and push-state diagnostics を failure marking 前に扱う。

### Requirement 6: 回帰検証

**Objective:** As a maintainer, I want #23 の混乱を再現する terminal failure 形状を検証できること, so that reviewer artifacts と push-state 診断の欠落が再発しない。

#### Acceptance Criteria

1. When regression coverage reproduces a per-task `per-task-reviewer-reject3` shape with untracked `review-notes.md`, the verification shall failure diagnostic が artifact content、artifact summary、または pushed diagnostic commit を示すことを確認する。
2. When regression coverage reproduces a per-task terminal failure with untracked `debugger-notes.md`, the verification shall failure diagnostic が artifact content、artifact summary、または pushed diagnostic commit を示すことを確認する。
3. When regression coverage exercises diagnostic commit failure, the verification shall Issue comment fallback が実行されることを確認する。
4. When regression coverage exercises terminal failure diagnostics, the verification shall current branch、local HEAD SHA、origin branch HEAD SHA または未取得理由、ahead count または算出不能理由、worktree path、artifact tracked state が露出することを確認する。
5. If shell-level fixture coverage is not practical for a specific terminal failure path, the implementation notes shall state the reason and identify the manual verification used instead.

## Non-Functional Requirements

### NFR 1: Backward compatibility

1. The system shall preserve existing env var names, label names, cron invocation contracts, branch naming contracts, and exit code meanings.
2. The system shall preserve existing Reviewer / Debugger git prohibition semantics.
3. The system shall not introduce new external services or new runtime dependencies.
4. The system shall not require `git reset`, `git rebase`, or force push for terminal failure preservation.

### NFR 2: Operator observability

1. When terminal failure preservation runs, the system shall leave operator-visible evidence showing whether diagnostic commit preservation or Issue comment fallback was used.
2. When artifact preservation cannot capture exact artifact content, the system shall leave operator-visible evidence explaining what was captured and why exact content was unavailable.

## Out of Scope

- Reviewer / Debugger サブエージェントへの `git add` / `git commit` / `git push` / `gh` 権限付与。
- terminal failure の retry policy 変更。
- fail コメントへのログ全文貼り付け。
- `git reset` / `git rebase` / force push の追加。
- #23 の復旧作業そのものの再実行。
- 新しい外部サービス呼び出しや runtime dependency の追加。

## Open Questions

- なし。

## Issue コメント反映

- `gh issue view 38 --comments` により、人間が保全方式として `C` と回答済みであることを確認した。
- Option C は「watcher diagnostic commit を試み、失敗時は Issue コメントへ fallback」として決定事項に反映した。
- Triage edit_paths の自動コメントにより、編集見込み top-level path は `local-watcher/` と `README.md` である。
- Path Overlap Checker による一時的な `local-watcher/` overlap は dispatch 制御情報であり、要件上の未決事項としては扱わない。

## PM Self Review

- Mechanical Checks: numeric requirement ID、全 requirement の EARS 形式 AC、Out of Scope、Open Questions を確認した。
- 判断レビュー: Issue 本文の受入基準、#23 の背景、Reviewer / Debugger の git 権限禁止、Option C の人間決定、failure comment に必要な push-state 診断、per-task / non-per-task terminal failure の一貫性、回帰検証要求を網羅し、関数設計やファイル分割には踏み込んでいないことを確認した。
