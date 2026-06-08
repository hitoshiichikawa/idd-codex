# Issue #6 実装メモ

## Implementation Notes

### Task 1

- 採用方針: Dependency Resolver のみで multi-branch 時の `codex-staged-for-release` / base merged managed PR を development-resolved として扱う。
- 重要な判断: `dr_resolve_one` は理由付き record を返すが、`dr_check_dependencies` は旧形式も受け付ける後方互換パーサにした。
- 重要な判断: base merged managed PR 検出は task 1 の境界に合わせ、`codex/issue-<N>-impl-*` head branch の同一 repo PR に限定した。
- 残存課題: Promote Pipeline 側の plain reference / title resolver と merge SHA 解決は task 2 で扱う。

### Task 2

- 採用方針: Promote Pipeline 側に managed PR issue resolver を追加し、closing refs と no-closing-keyword managed PR の両方から staged-for-release 対象を解決する。
- 重要な判断: body plain reference は同一 repo の managed PR と判定できる場合だけ採用し、unmanaged PR と fork PR は auto-label 候補外に維持した。
- 重要な判断: merge SHA 解決は既存 closed-by 経路を先に試し、空の場合のみ BASE_BRANCH merged managed PR の `mergeCommit.oid` fallback を使う。
- 残存課題: task 4 で shell-level regression test と PjM guidance static check を追加する。

### Task 3

- 採用方針: Project Manager guidance は multi-branch 判定を tasks.md 完了状況より前に置き、final / design-less impl でも `Refs #N` を採用するようにした。
- 重要な判断: root と repo-template の `project-manager.md` は同一 patch で更新し、byte 一致を維持した。
- 重要な判断: README は partial/final PR の説明、multi-branch staged-for-release フロー、Promote Pipeline の managed PR resolver の説明を揃えて更新した。

### Task 4

- 採用方針: `issue6_gitflow_no_closing_keyword_test.sh` に Dependency Resolver、Promote Pipeline、PjM/README static policy をまとめて固定した。
- 重要な判断: Promote Pipeline は managed PR の branch/title/body plain reference、unmanaged PR 除外、fork PR 除外、既ラベル skip、merge SHA fallback を mock で検証した。
- 重要な判断: 大きい README 文字列の static check は `grep` here-string を使い、`set -o pipefail` と `grep -q` の SIGPIPE false negative を避けた。
