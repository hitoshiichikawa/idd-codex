# Review Notes

<!-- idd-codex:review round=2 model=gpt-5.5 timestamp=2026-06-08T18:49:14Z -->

## Reviewed Scope

- Branch: codex/issue-7-impl--bug-collab-subagent-spawn-intermittentl
- HEAD commit: 24cfa3f9f62850d3fb0437e4fff9fe53fbe7b5e1
- Compared to: main..HEAD

## Verified Requirements

- 1.1 - `local-watcher/bin/modules/quota-aware.sh:322` と `local-watcher/bin/modules/run-summary.sh:224` で `collab spawn failed: no thread with id` を structured degraded event として記録。
- 1.2 - `local-watcher/bin/modules/quota-aware.sh:322` / `run-summary.sh:234` で stage、agent role、reason、fallback、degraded、repeated を operator-observable に保持。
- 1.3 - `local-watcher/bin/modules/run-summary.sh:235` 以降で複数 event を `;` 区切りで蓄積し、`local-watcher/test/qa_run_codex_stage_test.sh:326` の repeated case で個別追跡を検証。
- 1.4 - `local-watcher/bin/modules/quota-aware.sh:333` と `local-watcher/test/qa_run_codex_stage_test.sh:305` で rc=0 継続時も degraded success として summary/log に残すことを検証。
- 2.1 - `local-watcher/bin/modules/quota-aware.sh:409` で bounded retry fallback start を明示ログ化し、`qa_run_codex_stage_test.sh:373` / `:421` で Reviewer と StageC の開始ログを検証。
- 2.2 - `local-watcher/bin/modules/quota-aware.sh:409` の fallback start log は stage と roles を含み、`qa_run_codex_stage_test.sh:392` / `:440` で検証。
- 2.3 - `local-watcher/bin/modules/quota-aware.sh:333`、`:418`、`:420` で degraded-success、success、failed の fallback result をログ化し、対応テストは `qa_run_codex_stage_test.sh:305`、`:373`、`:396`。
- 2.4 - `local-watcher/bin/modules/quota-aware.sh:420` / `:474` で retry 後失敗を通常非 0 rc として透過し、round 2 追加の `qa_run_codex_stage_test.sh:396` で failed log、rc 透過、3 回目未実行を検証。
- 3.1 - `local-watcher/bin/modules/quota-aware.sh:376` と `:407` で同一 wrapper 内の spawn retry を最大 1 回に制限し、`qa_run_codex_stage_test.sh:417` で 2 attempts 上限を検証。
- 3.2 - `local-watcher/bin/modules/quota-aware.sh:395` 以降で retry 後失敗を fallback failed として扱い、`qa_run_codex_stage_test.sh:414` / `:415` で非 0 rc と failed event を検証。
- 3.3 - `local-watcher/bin/modules/quota-aware.sh:254` と `run-summary.sh:242` で repeated warning を記録し、`qa_run_codex_stage_test.sh:326` / `:347` で単一 run 内の複数 failure を検証。
- 3.4 - `local-watcher/bin/modules/quota-aware.sh:322` / `:324` で repeated failure を warning 付きで可視化し、`qa_run_codex_stage_test.sh:342` / `:368` で warning を検証。
- 4.1 - Stage A PM は `local-watcher/bin/idd-codex-issue-watcher.sh:5730` の StageA wrapper と `qa_run_codex_stage_test.sh:326` の ProductManager fixture で degraded event / fallback log / bounded retry 対象に入る。
- 4.2 - Stage A Developer は `local-watcher/bin/idd-codex-issue-watcher.sh:5730` の StageA wrapper と `qa_run_codex_stage_test.sh:305` の Developer fixture で degraded event / log を検証。
- 4.3 - Reviewer は `local-watcher/bin/idd-codex-issue-watcher.sh:4922` の Reviewer wrapper と `qa_run_codex_stage_test.sh:373` / `:396` で retry success / retry failed の両方を検証。
- 4.4 - Stage C / Project Manager は `local-watcher/bin/idd-codex-issue-watcher.sh:6289` の StageC wrapper、`quota-aware.sh:211` の role 推定、round 2 追加の `qa_run_codex_stage_test.sh:421` で degraded event、fallback start、retry success log を検証。
- 5.1 - `local-watcher/bin/modules/quota-aware.sh:322` の `upstream=codex-cli-or-collab-router` と README `README.md:732` 以降で upstream 起因疑いを run summary / log の診断として残す。
- 5.2 - `local-watcher/bin/modules/quota-aware.sh:322`、`:333`、`:418`、`:420` と README `README.md:732` 以降で upstream 可能性、fallback 有無、degraded 影響を判別可能にしている。
- 5.3 - 差分は idd-codex 側の watcher wrapper、run summary、README、テスト fixture に限定され、Codex CLI upstream 実装変更を前提にしていない。
- 6.1 - `local-watcher/bin/modules/quota-aware.sh:362` 以降で opt-out 素通し、`:396` 以降で既存 rc=0 継続、`:474` で非 0 rc 透過を維持している。
- 6.2 - 既存 env var、ラベル名、exit code 意味、ログ出力先の変更は差分内に見当たらず、`QUOTA_AWARE_ENABLED=false` の既存 opt-out 経路も維持。
- 6.3 - README `README.md:695` 以降で `run-summary:` の新 key、grep 例、`collab_spawn_failed` と fallback 診断の読み方を更新。

## Findings

なし

## Summary

round 1 の missing test 2件は、bounded retry failure case と StageC/ProjectManager case の追加で解消済み。`tasks.md` と `design.md` は指定 spec ディレクトリに存在しなかったため、tasks の `_Boundary:_` アノテーションによる境界照合は実施不能だったが、requirements の Scope 外変更は検出しなかった。

検証: `bash local-watcher/test/qa_run_codex_stage_test.sh` は PASS 87 / FAIL 0、`shellcheck local-watcher/bin/*.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh` は exit 0、`for t in local-watcher/test/*.sh; do bash "$t"; done` は全件 PASS。

RESULT: approve
