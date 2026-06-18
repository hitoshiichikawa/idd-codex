# Review Notes

<!-- idd-codex:review round=1 model=gpt-5.5 timestamp=2026-06-18T07:27:35Z -->

## Reviewed Scope

- Branch: codex/issue-36-impl-feat-watcher-indexer-context-metadata
- HEAD commit: 73d60269d7e1a6c71fc5778bbb18fc5ad1acfd8b
- Compared to: main..HEAD
- Diff summary: `README.md`, `local-watcher/bin/idd-codex-issue-watcher.sh`, `local-watcher/bin/idd-codex-modules/context-map.sh`, `local-watcher/test/context_indexer_test.sh`, `local-watcher/test/context_map_prompt_test.sh`, `docs/specs/36-feat-watcher-indexer-context-metadata/impl-notes.md`, `docs/specs/36-feat-watcher-indexer-context-metadata/tasks.md`
- Feature Flag Protocol: root `AGENTS.md` に `## Feature Flag Protocol` の opt-in 採否宣言節がないため、通常の 3 カテゴリ判定のみを適用した。
- Verification run by reviewer: `shellcheck --severity=warning local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/idd-codex-modules/*.sh local-watcher/test/context_map_prompt_test.sh local-watcher/test/context_indexer_test.sh && bash local-watcher/test/context_map_prompt_test.sh && bash local-watcher/test/context_indexer_test.sh` が成功した。

## Verified Requirements

- 1.1 — `ci_context_indexer_enabled` は `CONTEXT_INDEXER_ENABLED=true` の厳密一致のみを有効化し、disabled 時は `ci_context_needs_indexer` が `skip:disabled` を返す。`context_indexer_test.sh:230` 以降で runner 未呼び出しを検証している。
- 1.2 — `CONTEXT_MAP_ENABLED=false` では `cm_write_context_map` が no-op になり、prompt block も注入されない。`context_map_prompt_test.sh:198` 以降で既存 deterministic 契約を検証している。
- 1.3 — `CONTEXT_INDEXER_ENABLED=True` は無効、`true` だけ有効になることを `context_map_prompt_test.sh:214` と `context_map_prompt_test.sh:247` で検証している。
- 1.4 — watcher 本体の既存 env / label / exit code 契約は変更せず、追加は `CONTEXT_INDEXER_*` default と `context-map.sh` module registration に限定されている。
- 2.1 — `ci_context_needs_indexer` は sufficient deterministic context で `skip:sufficient` を返し、`context_indexer_test.sh:249` で検証している。
- 2.2 — insufficient / ambiguous context で `needed:*` を返し、`cm_write_context_map` が runner を最大 1 回起動する。`context_indexer_test.sh:259`、`:328`、`:393` で検証している。
- 2.3 — `run_per_task_implementer` / `run_per_task_reviewer` は prompt 構築前に `cm_write_context_map` を呼び、Indexer metadata を事前利用可能にしている。
- 2.4 — `ci_marker_seen` / `ci_record_indexer_marker` が task / stage / range の success と fallback marker を完了済みとして扱う。`context_indexer_test.sh:264` と `:278` で検証している。
- 3.1 — 保存先は `cm_context_map_path` により `docs/specs/<N>-<slug>/context-map.md` に固定されている。
- 3.2 — `context-map.md` は `## Deterministic Metadata`、`## Indexer Status`、`## Indexer Metadata` で由来を分離している。`context_indexer_test.sh:335` 以降で検証している。
- 3.3 — sanitizer は candidate files / tests / docs / anchors を抽出し、探索制約を固定文として保存する。`context-map.sh:545` と `context-map.sh:571` 以降に実装がある。
- 3.4 — `cm_build_prompt_block` は `context-map.md` の bounded first 180 lines を注入する。`context-map.sh:950` 以降と `context_indexer_test.sh:355` 以降で確認した。
- 3.5 — `context-map.json` は差分内に導入されておらず、README でも保存形式は `context-map.md` と説明されている。
- 4.1 — Implementer prompt は Candidate Files / Anchors / Candidate Tests を先に見るよう案内する。`context-map.sh:945` と `context_map_prompt_test.sh:240` で確認した。
- 4.2 — Reviewer prompt は diff range / Candidate Files / Anchors / Candidate Tests を先に見るよう案内する。`context-map.sh:941` と `context_map_prompt_test.sh:265` で確認した。
- 4.3 — prompt と metadata の探索制約は最終判断を `tasks.md`、要件、実際の diff に戻すよう明示している。
- 4.4 — prompt は Indexer metadata を補助情報とし、不足時は targeted search を追加できる余地を残している。
- 5.1 — Indexer prompt は実装、レビュー判定、commit、push、PR 作成、ファイル編集、`tasks.md` / `_Boundary:_` 変更を禁止している。
- 5.2 — sanitizer と append 処理は candidate metadata と固定探索制約だけを保存する。
- 5.3 — dirty / invalid / failure は後続 agent 向け fallback metadata として記録され、実装判断として扱われない。
- 5.4 — Indexer metadata は `tasks.md` や `_Boundary:_` を変更せず、dirty guard で repository 変更を fallback に倒す。
- 6.1 — runner failure / invalid output / dirty guard failure は fallback marker に記録される。
- 6.2 — `cm_write_context_map` は Indexer failure で非 0 終了せず、Issue を即 `codex-failed` にする経路を追加していない。
- 6.3 — `context-indexer:` log と marker/status に fallback reason が残る。
- 6.4 — fallback 後も deterministic section が `context-map.md` と prompt slice に残る。
- 7.1 — README は opt-in gate、起動条件、保存形式、fallback 方針を説明している。
- 7.2 — README は deterministic map が第一手段で、不足または曖昧な場合だけ Indexer が補助することを説明している。
- 7.3 — README は token 消費増加の可能性と探索 read 削減の狙いを説明している。
- 7.4 — README は Indexer が read-only で、実装、レビュー、commit、push、PR 作成を行わないことを説明している。
- NFR 1.1 — `CONTEXT_MAP_ENABLED=false` / Indexer disabled の regression で既存 per-task prompt 注入なし・runner 未起動を検証している。
- NFR 1.2 — `CONTEXT_MAP_ENABLED` は既存 no-op / prompt injection gate として維持され、Indexer は内側の追加 opt-in になっている。
- NFR 1.3 — Indexer の Codex CLI 呼び出しは `CONTEXT_INDEXER_ENABLED=true` かつ insufficient 判定時のみ実行される。
- NFR 2.1 — start/decision/result は `context-indexer:` log と marker に Issue / task / stage / reason として残る。
- NFR 2.2 — sufficient skip は `skip:sufficient` / `skip:sufficient-docs-only` として status/log に残る。
- NFR 2.3 — fallback は marker/status/log に reason 付きで残り、後続処理継続が regression で確認されている。
- NFR 3.1 — opt-in disabled behavior は `context_map_prompt_test.sh` と `context_indexer_test.sh` で検証されている。
- NFR 3.2 — sufficient deterministic context skip は `context_indexer_test.sh:249` 以降で検証されている。
- NFR 3.3 — insufficient / ambiguous context の run once と metadata 保存は `context_indexer_test.sh:259` 以降と `:328` 以降で検証されている。
- NFR 3.4 — invalid output、dirty guard、runner nonzero の fallback は `context_indexer_test.sh:400` 以降で検証されている。
- NFR 3.5 — prompt injection slice は `context_map_prompt_test.sh:240` 以降と `context_indexer_test.sh:355` 以降で検証されている。

## Findings

なし

## Summary

Requirements 1〜7 と NFR 1〜3 の実装・テスト・README 反映を確認した。差分は tasks.md の checkbox 更新を含むが、実装対象の成果物管理上の進捗反映であり、許可された `local-watcher/`、`README.md`、spec 成果物の範囲から外れる boundary 逸脱は見つからなかった。

RESULT: approve
