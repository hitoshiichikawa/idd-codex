# Issue #11 実装ノート

## 実装概要

- `local-watcher/bin/idd-codex-issue-watcher.sh` の `_dispatcher_find_free_slot` で、slot 番号を stdout の return channel として返す間は `_dispatcher_reap_finished_slots` の completion log を stderr へ分離した。
- dispatch 直前に `_dispatcher_validate_slot_id` を追加し、既存の slot domain である `1..PARALLEL_SLOTS` の正整数だけを許可するようにした。
- invalid slot id を検出した場合は、worktree path / slot log path / Issue コメントへ展開する前に dispatcher サイクルを fail closed で中止する。
- `local-watcher/bin/modules/promote-pipeline.sh` の `pp_collect_merged_issues` で、issue number 一覧を返す stdout に `pp_log` が混入しないよう auto-label ログを stderr へ分離した。
- `local-watcher/test/stdout_discipline_test.sh` を追加し、dispatcher slot allocation の stdout 汚染再現と promote-pipeline の issue number return channel を検証した。

## 変更ファイル

- `local-watcher/bin/idd-codex-issue-watcher.sh`
- `local-watcher/bin/modules/promote-pipeline.sh`
- `local-watcher/test/stdout_discipline_test.sh`
- `docs/specs/11--bug-dispatcher-slot-id-is-corrupted-by/requirements.md`
- `docs/specs/11--bug-dispatcher-slot-id-is-corrupted-by/impl-notes.md`

## 検証

```bash
bash local-watcher/test/stdout_discipline_test.sh
```

結果: PASS 10 / FAIL 0

```bash
bash local-watcher/test/dispatch_hotfix_jq_test.sh
```

結果: PASS 3 / FAIL 0

```bash
shellcheck local-watcher/bin/*.sh local-watcher/bin/modules/*.sh local-watcher/test/stdout_discipline_test.sh install.sh setup.sh .github/scripts/*.sh
```

結果: 警告なし

```bash
for t in local-watcher/test/*.sh; do echo "--- $t"; bash "$t"; done
```

結果: 全テスト PASS

## 確認事項

- 既存実装上、slot id の有効 domain は `1..PARALLEL_SLOTS` の正整数として扱われており、追加の定義済み token は確認できなかった。
- developer 補助サブエージェントの起動を試みたが、collab spawn failure により起動できなかった。本 Issue のスコープ外であるため、ローカル Developer 作業として実装・検証を完了した。
- 本 Stage では Reviewer / Project Manager サブエージェントの起動および PR 作成は行っていない。
