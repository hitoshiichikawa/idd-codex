# Issue #6 要件定義

## 1. multi-branch の開発依存解決

Gitflow 運用では、production release 前の Issue が open のままでも、base branch へ統合済みの作業は後続 Issue の開発依存として解決済みと扱う。

### Acceptance Criteria

- When `BASE_BRANCH != PROMOTION_TARGET_BRANCH` かつ依存先 Issue が `codex-staged-for-release` を持つとき, the Dependency Resolver shall 依存先 Issue を development-resolved として扱う。
- When `BASE_BRANCH != PROMOTION_TARGET_BRANCH` かつ依存先 Issue に紐づく managed PR が `BASE_BRANCH` に merged 済みであるとき, the Dependency Resolver shall 依存先 Issue を development-resolved として扱う。
- When `BASE_BRANCH != PROMOTION_TARGET_BRANCH` かつ依存先 Issue が open のままで `codex-staged-for-release` も base branch merged managed PR も持たないとき, the Dependency Resolver shall 依存先 Issue を unresolved として扱う。
- When `BASE_BRANCH == PROMOTION_TARGET_BRANCH` のとき, the Dependency Resolver shall 既存の single-branch closing-keyword 前提の依存解決挙動を維持する。

## 2. no-closing-keyword PR の staged-for-release 自動付与

Promote Pipeline は develop PR が closing keyword を使わない場合でも、managed PR から対象 Issue を識別し、release 待ち状態を自動化できる。

### Acceptance Criteria

- When `BASE_BRANCH != PROMOTION_TARGET_BRANCH` かつ `BASE_BRANCH` に merged された managed PR の本文が plain reference で対象 Issue を参照するとき, the Promote Pipeline shall 対象 Issue に `codex-staged-for-release` を自動付与できる。
- When `BASE_BRANCH != PROMOTION_TARGET_BRANCH` かつ merged managed PR が branch naming または PR title で対象 Issue 番号を表すとき, the Promote Pipeline shall closing keyword が無くても対象 Issue を識別できる。
- When merged PR が idd-codex 管理 PR と判定できないとき, the Promote Pipeline shall plain reference だけを根拠に任意の Issue へ `codex-staged-for-release` を付与しない。
- When merged PR が fork PR であるとき, the Promote Pipeline shall 既存どおり `codex-staged-for-release` 自動付与対象から除外する。
- When 対象 Issue が既に `codex-staged-for-release` を持つとき, the Promote Pipeline shall 重複付与を抑止する。

## 3. release close 運用の維持

develop merge と production release を別状態として扱い、Issue close は repository の release close 方針を壊さない。

### Acceptance Criteria

- When `BASE_BRANCH != PROMOTION_TARGET_BRANCH` の develop PR body を生成するとき, the Project Manager guidance shall Issue 参照に auto-close keyword を固定使用しない。
- When `BASE_BRANCH != PROMOTION_TARGET_BRANCH` で develop merge 後に `codex-staged-for-release` が付与されるとき, the watcher shall Issue を close しない。
- When production release が `PROMOTION_TARGET_BRANCH` へ到達するとき, the watcher shall repository が選んだ main/release merge 時 close policy を妨げない。
- When design-review PR を作成するとき, the Project Manager shall 既存どおり `Refs #N` を使用し、auto-close keyword を含めない。

## 4. 運用者可視性とエラー表示

Dependency Resolver と Promote Pipeline は、Gitflow/no-closing-keyword 判定をログやコメントで追跡可能にし、既存のエスカレーション表示の誤解を減らす。

### Acceptance Criteria

- When Dependency Resolver が `codex-staged-for-release` により依存解決したとき, the Dependency Resolver shall 構造化ログで staged-for-release 解決であることを識別可能にする。
- When Dependency Resolver が base branch merged managed PR により依存解決したとき, the Dependency Resolver shall 構造化ログで base-merged 解決であることを識別可能にする。
- When Dependency Resolver が依存未解決コメントを投稿するとき, the Dependency Resolver shall ブロック対象 Issue と仕様 Issue 番号を連結したように見える表記を出さない。
- If GitHub API 取得または解析に失敗するとき, the Dependency Resolver and Promote Pipeline shall silent fail せず WARN ログを残し、安全側の判定を行う。

## 5. 後方互換性

既存の single-branch workflow、closing keyword に依存する workflow、既存 env var / label / exit code 契約を維持する。

### Acceptance Criteria

- When `BASE_BRANCH == PROMOTION_TARGET_BRANCH` の single-branch repo で closing keyword 付き PR が merged されるとき, the Dependency Resolver shall 従来どおり closed Issue と merged closing PR を解決済みとして扱う。
- When `BASE_BRANCH == PROMOTION_TARGET_BRANCH` の single-branch repo で closing keyword 付き PR が merged されるとき, the Promote Pipeline shall 既存の closing keyword 経路を壊さない。
- When Gitflow/no-closing-keyword 対応を追加するとき, the implementation shall 既存の env var 名、label 名、cron 起動契約、exit code 意味を変更しない。
- When `PROMOTE_PIPELINE_ENABLED` が `true` 以外のとき, the Promote Pipeline shall 既存どおり staged-for-release 自動付与処理を実行しない。

## 6. 回帰検証

single-branch と multi-branch の両方で、依存解決・staged-for-release 自動付与・PR body link policy を検証する。

### Acceptance Criteria

- When regression test が single-branch closing-keyword workflow を再現するとき, the test suite shall Dependency Resolver と Promote Pipeline の既存挙動が維持されることを検証する。
- When regression test が multi-branch no-closing-keyword workflow を再現するとき, the test suite shall `codex-staged-for-release` が自動付与され、依存先 Issue が development-resolved になることを検証する。
- When regression test が staged-for-release 付き open Issue を依存先として入力するとき, the test suite shall Dependency Resolver が unresolved にしないことを検証する。
- When regression test が plain reference を含む unmanaged PR を入力するとき, the test suite shall Promote Pipeline が誤って `codex-staged-for-release` を自動付与しないことを検証する。
- When regression test が implementation PR body guidance を検証するとき, the test suite or static check shall multi-branch 運用で auto-close keyword 固定にならないことを検証する。

## Scope

- 対象: `local-watcher/bin/idd-codex-issue-watcher.sh` の Dependency Resolver Gate。
- 対象: `local-watcher/bin/modules/promote-pipeline.sh` の staged-for-release auto-label と関連 helper。
- 対象: `.codex/agents/project-manager.md` と `repo-template/.codex/agents/project-manager.md` の実装 PR 参照方針。
- 対象: `README.md` の Gitflow / release close / staged-for-release / dependency resolver 説明。
- 対象: `local-watcher/test/` または `tests/local-watcher/` の shell-level regression tests。
- 対象外: GitHub default branch の自動変更、release note 生成、feedman-ios 固有 README 変更。

## Issue コメント反映

- 追加ログにより、`develop` merge 済みかつ `codex-staged-for-release` 付きの open Issue が unresolved 扱いになる再現を受入範囲に含める。
- 依存未解決時のログ / コメントに `Issue #146` が対象 Issue 番号と連結して `#146` のように見える表示問題を可視性要件に含める。
- design-less impl PR が `Closes #N` を入れる例が観測されたため、multi-branch release close 運用では implementation PR body guidance の auto-close 固定を避ける要件を含める。
- Triage edit_paths の自動コメントにより、編集見込み top-level path は `local-watcher/` と `README.md` とする。

## 確認事項

- production release 時の Issue close は GitHub の branch close semantics と repo 運用に委ねる前提で、watcher が新規に close API を呼ぶ要件は置かない。
- managed PR の識別優先順位は design.md で定義し、requirements.md では「managed と判定できる PR」に限定する。

## PM 自己レビュー

- Mechanical Checks: numeric ID 見出し、各要件の EARS 形式 AC、過剰な実装詳細の混入なしを確認。
- 判断レビュー: Issue 本文の受入基準、追加コメントの再現ログ、release close 運用、後方互換、テスト要求、スコープ外を網羅していることを確認。
