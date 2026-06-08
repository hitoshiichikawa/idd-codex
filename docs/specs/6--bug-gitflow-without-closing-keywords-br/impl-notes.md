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
