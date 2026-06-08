# Issue #7 実装ノート

## 実装内容

- `local-watcher/bin/modules/quota-aware.sh`
  - `qa_run_codex_stage` で Codex stream を一時ファイルにも tee し、`collab spawn failed: no thread with id` を検出するようにした。
  - 検出時に `collab-spawn degraded event` / `collab-spawn fallback start` / `collab-spawn fallback result` / `collab-spawn repeated warning` を Issue log に残すようにした。
  - stage label と stream 行から agent role を推定し、Stage A PM / Developer、Reviewer、Stage C / Project Manager を operator-observable にした。
  - Codex rc=0 の場合は既存の継続挙動を維持しつつ degraded success として記録する。
  - Codex rc!=0 かつ collab spawn failure が検出された場合のみ、同一 wrapper 内で bounded retry を最大 1 回実施する。retry 後も失敗する場合は既存の通常失敗処理へ rc を透過する。
- `local-watcher/bin/modules/run-summary.sh`
  - `rs_record_degraded_event` を追加し、`run-summary:` に `degraded-events=` と `warnings=` を追加した。
  - `collab_spawn_failed(stage=...,role=...,reason=no_thread_with_id,fallback=...,degraded=yes,repeated=...)` を複数件 `;` 区切りで保持する。
  - 同一 run 内の repeated failure は `warnings=collab_spawn_repeated` として残す。
- `local-watcher/test/qa_run_codex_stage_test.sh`
  - collab spawn failure の degraded success、repeated warning、bounded retry の回帰テストを追加した。
  - 同一 run 内で別 role にまたがって複数回発生した場合も `collab_spawn_repeated` が残る回帰テストを追加した。
- `README.md`
  - `run-summary:` の新 key、grep 例、`collab_spawn_failed` の読み方、Issue log prefix を追記した。

## 後方互換性

- 既存 env var 名、ラベル名、exit code の意味は変更していない。
- quota 検出時の `99` sentinel と reset file の契約は維持した。
- `QUOTA_AWARE_ENABLED != true` の opt-out 時は従来どおり素通しで、collab 検出・tee・summary 更新は行わない。
- 新しい外部サービス呼び出しは追加していない。

## 検証結果

```bash
bash local-watcher/test/qa_run_codex_stage_test.sh
```

結果: PASS 73 / FAIL 0

追加補正後: PASS 78 / FAIL 0

```bash
shellcheck local-watcher/bin/*.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh
```

結果: exit 0

```bash
for t in local-watcher/test/*.sh; do echo "== $t =="; bash "$t"; done
```

結果: 全テスト exit 0

## 確認事項

- `collab spawn failed: no thread with id` の根本原因は Codex CLI / collab router upstream 側の可能性として扱い、idd-codex 側では診断・fallback 可視化・bounded retry までに留めた。
- Stage A の raw line に agent role 名が含まれない場合は `StageA-PM-Developer` として記録する。role 名が含まれる通常ログでは `ProductManager` または `Developer` として記録される。
