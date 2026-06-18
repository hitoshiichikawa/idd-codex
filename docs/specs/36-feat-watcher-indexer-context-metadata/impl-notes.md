# Implementation Notes

## Implementation Notes

### Task 1
- 採用方針: 既存 `cm_*` helper を公開名維持のまま `context-map.sh` へ移し、本体は env default と module registration に限定した。
- 重要な判断: `CONTEXT_INDEXER_MODEL` は `DEV_MODEL` 確定後に defaulting し、`set -u` 環境で未定義参照しない配置にした。
- 重要な判断: task 1 では Indexer runner を接続せず、`ci_context_indexer_enabled` の厳密 `=true` gate と deterministic regression の固定に留めた。
- 残存課題: Indexer 起動要否判定、最大 1 回 state、runner / sanitizer / fallback、prompt slice の Indexer metadata 対応は後続 task で実装する。

#### Finding Closure Matrix

| Finding | Target | Category | 対応 | テスト | status |
|---|---|---|---|---|---|
| なし | Task 1 | - | 前回 reject notes なし | - | closed |
