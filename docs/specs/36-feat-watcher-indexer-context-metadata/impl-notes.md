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
- 重要な判断: Implementer stage の空 range では branch 上の prior-task diff を十分性判定の証拠にせず、対象 task block / boundary / anchors / anchor-derived tests に限定する。
- 残存課題: Task 2 では runner 起動・metadata sanitizer・prompt slice の Indexer section 対応は接続していないため、後続 task で `ci_context_needs_indexer` / `ci_record_indexer_marker` を呼び出す必要がある。

#### Finding Closure Matrix

| Finding | Target | Category | 対応 | テスト | status |
|---|---|---|---|---|---|
| Finding 1 | 2.2, NFR 2.2, NFR 3.3 | AC 未カバー | `ci_context_needs_indexer` の十分性判定から空 range の `BASE_BRANCH..HEAD` changed files を除外し、prior-task diff だけで `skip:sufficient` にならないよう修正 | `shellcheck --severity=warning local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/idd-codex-modules/*.sh local-watcher/test/context_map_prompt_test.sh local-watcher/test/context_indexer_test.sh`; `bash local-watcher/test/context_map_prompt_test.sh`; `bash local-watcher/test/context_indexer_test.sh` | closed |

### Task 3
- 採用方針: `ci_context_needs_indexer` の `needed:*` 判定後だけ read-only Indexer runner を起動し、sanitizer が採用できない出力は fallback marker に倒す構成にした。
- 重要な判断: Indexer は `codex exec --sandbox read-only` を直接使い、通常 Stage A の `CODEX_SANDBOX` / `CODEX_UNSAFE_BYPASS` 経路を継承しない。
- 重要な判断: `CONTEXT_INDEXER_MAX_TURNS` は現行 Codex CLI の実引数に存在しないため、prompt 内の探索上限指示として扱い、実行失敗を避けた。
- 重要な判断: success marker だけで metadata が消えないよう、task 3 では最小限の sanitized metadata block を hidden boundary 付きで保存・再生成時に保持する。
- 残存課題: prompt 注入時の Indexer metadata 専用 guidance と `context-map.md` の見出し構成整理は task 4 の範囲として残る。

#### Finding Closure Matrix

| Finding | Target | Category | 対応 | テスト | status |
|---|---|---|---|---|---|
| なし | Task 3 | - | 前回 reject notes なし | `shellcheck --severity=warning local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/idd-codex-modules/*.sh local-watcher/test/context_map_prompt_test.sh local-watcher/test/context_indexer_test.sh`; `bash local-watcher/test/context_map_prompt_test.sh`; `bash local-watcher/test/context_indexer_test.sh` | closed |

### Task 4
- 採用方針: `context-map.md` を deterministic / Indexer Status / Indexer Metadata の見出しで分離し、prompt 側は stage 別 guidance と bounded slice 明記に寄せた。
- 重要な判断: 初回 Indexer 実行時は実行前の `pending` status を map に残さず、runner 後の `success` / `fallback` status と metadata だけを後続 prompt に見せる構成にした。
- 重要な判断: Reviewer prompt では diff range / candidate files / anchors / candidate tests を先に確認し、最終判断は `tasks.md`、要件、実際の diff に戻すことを明示した。
- 残存課題: Task 5 の包括 regression 整理と Task 6 の README 運用条件追記は未着手。

#### Finding Closure Matrix

| Finding | Target | Category | 対応 | テスト | status |
|---|---|---|---|---|---|
| なし | Task 4 | - | 前回 reject notes なし | `shellcheck --severity=warning local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/idd-codex-modules/*.sh local-watcher/test/context_map_prompt_test.sh local-watcher/test/context_indexer_test.sh`; `bash local-watcher/test/context_map_prompt_test.sh`; `bash local-watcher/test/context_indexer_test.sh` | closed |

### Task 5
- 採用方針: 既存 `context_indexer_test.sh` を包括 regression として拡張し、writer 経由の opt-in disabled と prompt slice 注入を直接検証する assertion を追加した。
- 重要な判断: 実装本体は既に task 3 / 4 で対象機能を満たしていたため、task 5 では production code を変更せず NFR 3.1〜3.5 のテスト証跡強化に限定した。
- 重要な判断: `context_map_prompt_test.sh` は deterministic contract regression として維持し、Indexer runner stub を伴う検証は `context_indexer_test.sh` に集約した。
- 残存課題: Task 6 の README 運用条件追記は未着手。

#### Finding Closure Matrix

| Finding | Target | Category | 対応 | テスト | status |
|---|---|---|---|---|---|
| なし | Task 5 | - | 前回 reject notes は Task 4 approve で Finding なし。Task 5 の reject Finding は存在しない | `shellcheck --severity=warning local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/idd-codex-modules/*.sh local-watcher/test/context_map_prompt_test.sh local-watcher/test/context_indexer_test.sh`; `bash local-watcher/test/context_map_prompt_test.sh`; `bash local-watcher/test/context_indexer_test.sh` | closed |
