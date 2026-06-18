# Implementation Plan

- [x] 1. context-map module を切り出し、Indexer opt-in gate を追加する
  - 既存 `cm_*` helper を `local-watcher/bin/idd-codex-modules/context-map.sh` へ移し、公開関数名は維持する。
  - `local-watcher/bin/idd-codex-issue-watcher.sh` の `REQUIRED_MODULES` に `context-map.sh` を追加する。
  - `CONTEXT_INDEXER_ENABLED=false`、`CONTEXT_INDEXER_MODEL="${CONTEXT_INDEXER_MODEL:-$DEV_MODEL}"`、`CONTEXT_INDEXER_MAX_TURNS="${CONTEXT_INDEXER_MAX_TURNS:-10}"` の env default を追加する。
  - `CONTEXT_MAP_ENABLED=false` または `CONTEXT_INDEXER_ENABLED!=true` で既存 deterministic map / prompt 注入契約が変わらない regression を更新する。
  - _Requirements:_ 1.1, 1.2, 1.3, 1.4, NFR 1.1, NFR 1.2, NFR 1.3, NFR 3.1

- [x] 2. deterministic context の十分性判定と最大 1 回 state を実装する
  - `ci_context_needs_indexer` を追加し、task block / requirements / boundary / candidates / tests / docs / anchors / diff range から `needed|skip` と reason を返す。
  - `context-map.md` の hidden marker で task / stage / range / result を記録し、success と fallback の両方を同一処理局面の完了済みとして扱う。
  - sufficient deterministic context では Indexer を起動しない shell test を追加する。
  - insufficient / ambiguous deterministic context では Indexer 起動が最大 1 回だけ許可される shell test を追加する。
  - _Requirements:_ 2.1, 2.2, 2.4, NFR 2.1, NFR 2.2, NFR 3.2, NFR 3.3

- [x] 3. read-only Indexer runner と metadata sanitizer を実装する
  - Indexer prompt に実装・レビュー・commit・push・PR 作成禁止、metadata 限定、未信頼入力境界を明示する。
  - 通常 Stage A の writable sandbox を継承しない read-only runner を追加し、実行前後の `git status --porcelain` dirty guard を入れる。
  - Indexer output から候補ファイル、候補テスト、候補 docs、anchors だけを正規化・上限制限して抽出する。
  - runner failure / invalid output / dirty guard failure を fallback として扱い、Issue を `codex-failed` にしない shell test を追加する。
  - _Requirements:_ 3.2, 3.3, 5.1, 5.2, 5.3, 5.4, 6.1, 6.2, 6.3, NFR 2.1, NFR 2.3, NFR 3.4

- [x] 4. context-map.md 保存形式と prompt 注入を Indexer metadata 対応に更新する
  - `context-map.md` に deterministic section、Indexer Status、Indexer Metadata を分離して保存する。
  - Indexer 成功時も fallback 時も保存先を `docs/specs/番号-slug/context-map.md` に固定し、`context-map.json` を要求しない。
  - Implementer prompt では candidate files / anchors / candidate tests を repo-wide 探索より先に参照する案内を追加する。
  - Reviewer prompt では diff range / candidate files / anchors / candidate tests を先に参照し、最終判断は `tasks.md`、要件、実際の diff とする案内を追加する。
  - prompt に注入する `context-map.md` は bounded slice に制限し、不足時の targeted search 余地を残す。
  - _Requirements:_ 2.3, 3.1, 3.2, 3.3, 3.4, 3.5, 4.1, 4.2, 4.3, 4.4, 6.4, NFR 3.5

- [x] 5. Indexer regression test を完成させる
  - `local-watcher/test/context_indexer_test.sh` を追加し、Codex runner を stub して opt-in disabled、sufficient skip、insufficient run once、failure fallback、prompt slice を検証する。
  - `local-watcher/test/context_map_prompt_test.sh` を module 化後の deterministic contract regression として維持する。
  - `shellcheck --severity=warning` で新規 module / 変更 watcher / 関連 tests を clean にする。
  - _Requirements:_ NFR 3.1, NFR 3.2, NFR 3.3, NFR 3.4, NFR 3.5

- [ ] 6. README に Indexer の運用条件を追記する
  - 環境変数表へ `CONTEXT_INDEXER_ENABLED`、`CONTEXT_INDEXER_MODEL`、`CONTEXT_INDEXER_MAX_TURNS` を追記する。
  - deterministic map が第一手段で、不足または曖昧な場合だけ Indexer が補助することを説明する。
  - 保存形式は `context-map.md`、失敗時は deterministic fallback、prompt は短い slice 注入であることを説明する。
  - token 消費増の可能性と探索 read 削減の狙い、Indexer の read-only 権限境界を説明する。
  - _Requirements:_ 7.1, 7.2, 7.3, 7.4

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを以下で宣言する。

<!-- stage-a-verify -->
```sh
shellcheck --severity=warning local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/idd-codex-modules/*.sh local-watcher/test/context_map_prompt_test.sh local-watcher/test/context_indexer_test.sh &&
  bash local-watcher/test/context_map_prompt_test.sh &&
  bash local-watcher/test/context_indexer_test.sh
```
