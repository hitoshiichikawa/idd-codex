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

### Task 2
- 採用方針: deterministic collector の既存抽出結果を再利用し、`ci_context_needs_indexer` が `skip|needed` と reason token を返す純粋判定に寄せた。
- 重要な判断: `context-map.md` の hidden marker は `success` と `fallback` を同一処理局面の完了済みとして扱い、map 再生成時にも既存 marker を保持する。
- 重要な判断: docs-only task は `_Boundary:_` が明示 docs のみで候補 docs が spec 外にある場合、anchors / tests 欠落を不足扱いにしない。
- 残存課題: Task 2 では runner 起動・metadata sanitizer・prompt slice の Indexer section 対応は接続していないため、後続 task で `ci_context_needs_indexer` / `ci_record_indexer_marker` を呼び出す必要がある。

#### Finding Closure Matrix

| Finding | Target | Category | 対応 | テスト | status |
|---|---|---|---|---|---|
| なし | Task 2 | - | 前回 reject notes は Task 1 approve のため対応不要 | - | closed |
