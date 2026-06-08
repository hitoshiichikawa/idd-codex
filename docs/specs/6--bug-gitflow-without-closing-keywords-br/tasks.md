# Issue #6 実装タスク

- [x] 1. Dependency Resolver を multi-branch development-resolved 判定に拡張する
  - `dr_resolve_one` で `BASE_BRANCH != PROMOTION_TARGET_BRANCH` のとき `codex-staged-for-release` label を resolved として扱う
  - `BASE_BRANCH` merged managed PR を検出する helper を追加し、open Issue でも development-resolved として扱う
  - `dr_check_dependencies` のログに `staged-for-release` / `base-merged` / `closing-pr` の reason を出す
  - 未解決依存コメントの Issue 番号表記を、対象 Issue と仕様 Issue 番号が連結して見えない形に直す
  - API / parse 失敗は `dr_warn` + 安全側 unresolved を維持する
  - _Requirements:_ 1, 4, 5
  - _Boundary:_ Dependency Resolver Gate
  - _Depends:_ なし

- [ ] 2. Promote Pipeline の managed PR issue resolver と auto-label 経路を拡張する
  - `pp_collect_merged_issues` の PR 取得 fields を body/title/headRefName/baseRefName/mergeCommit 等へ拡張する
  - branch naming、PR title、managed PR body plain reference、既存 closing refs から Issue 番号を抽出する helper を追加する
  - unmanaged PR の body plain reference は `codex-staged-for-release` 自動付与対象にしない
  - fork PR 除外、既ラベル重複付与抑止、`PROMOTE_PIPELINE_ENABLED=true` gate を維持する
  - `pp_resolve_merge_sha` を no-closing-keyword managed PR でも merge commit 解決できるようにする
  - _Requirements:_ 2, 3, 4, 5
  - _Boundary:_ Promote Pipeline, Managed PR Issue Resolver, Promote Pipeline Merge SHA Resolver
  - _Depends:_ 1

- [ ] 3. Project Manager guidance と README を Gitflow/no-closing-keyword 方針に更新する
  - `.codex/agents/project-manager.md` と `repo-template/.codex/agents/project-manager.md` の implementation PR body guidance を更新する
  - `BASE_BRANCH != PROMOTION_TARGET_BRANCH` では final / design-less を含め `Refs #N` を採用し、design-review mode の `Refs #N` 固定は維持する
  - 両 agent 定義を byte 一致に保つ
  - README の Gitflow、Dependency Resolver、Promote Pipeline、release close、staged-for-release 説明を更新する
  - _Requirements:_ 3, 5, 6
  - _Boundary:_ Project Manager Guidance, README Updates
  - _Depends:_ 1, 2

- [ ] 4. shell-level regression test を追加して single / multi branch の挙動を固定する
  - `local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh` を追加し、`gh` / `jq` 入出力を mock する
  - single-branch closing-keyword workflow で Dependency Resolver と Promote Pipeline の既存挙動を検証する
  - multi-branch no-closing-keyword workflow で auto-label と development-resolved を検証する
  - staged label 付き open Issue、unmanaged PR plain reference、fork PR、既ラベル skip を検証する
  - PjM guidance の multi-branch `Refs #N` 方針と root / repo-template byte 一致を static check する
  - _Requirements:_ 1, 2, 3, 4, 5, 6
  - _Boundary:_ Regression Tests
  - _Depends:_ 1, 2, 3

## Verify

本 spec の実装後、watcher が再実行すべき verify コマンドを以下の構造化ブロックで宣言する。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/modules/promote-pipeline.sh install.sh setup.sh .github/scripts/*.sh &&
  diff -r .codex/agents repo-template/.codex/agents &&
  diff -r .codex/rules repo-template/.codex/rules &&
  bash local-watcher/test/issue6_gitflow_no_closing_keyword_test.sh
```
