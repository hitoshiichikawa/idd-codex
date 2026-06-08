# Issue #6 実装メモ

## Implementation Notes

### Task 1

- 採用方針: Dependency Resolver のみで multi-branch 時の `codex-staged-for-release` / base merged managed PR を development-resolved として扱う。
- 重要な判断: `dr_resolve_one` は理由付き record を返すが、`dr_check_dependencies` は旧形式も受け付ける後方互換パーサにした。
- 重要な判断: base merged managed PR 検出は task 1 の境界に合わせ、`codex/issue-<N>-impl-*` head branch の同一 repo PR に限定した。
- 残存課題: Promote Pipeline 側の plain reference / title resolver と merge SHA 解決は task 2 で扱う。
