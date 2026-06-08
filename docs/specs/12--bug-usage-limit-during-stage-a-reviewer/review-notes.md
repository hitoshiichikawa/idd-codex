# Review Notes

<!-- idd-codex:review round=2 model=gpt-5.5 timestamp=2026-06-08T17:04:31Z -->

## Reviewed Scope

- Branch: codex/issue-12-impl--bug-usage-limit-during-stage-a-reviewer
- HEAD commit: ed8e53a0319a0143e5578e08bf41a8706fae0e0c
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `local-watcher/bin/modules/quota-aware.sh:265` 以降で reset 付き usage-limit fatal を exit 99 に変換し、`local-watcher/bin/idd-codex-issue-watcher.sh:5730` / `:5768` で Stage A の quota wait 経路へ接続している。`qa_run_codex_stage_test.sh:300` / `:315` で exit 99 とラベル遷移を検証。
- 1.2 — `local-watcher/bin/idd-codex-issue-watcher.sh:4922` / `:4932` で Reviewer stage の exit 99 を `qa_handle_quota_exceeded` に接続している。`qa_run_codex_stage_test.sh:303` / `:318` で検証。
- 1.3 — `local-watcher/bin/idd-codex-issue-watcher.sh:4288` / `:4300` と `:6143` 周辺で Debugger 後 Reviewer round の quota wait 経路が維持され、`qa_run_codex_stage_test.sh:306` / `:321` で検証。
- 1.4 — Stage C は `local-watcher/bin/idd-codex-issue-watcher.sh:6289` / `:6336`、per-task loop は `:3141` / `:3154` と `:3243` / `:3254`、PR Reviewer は `local-watcher/bin/modules/pr-reviewer.sh:880` / `:884` で quota wait に分類している。PR Reviewer 専用経路は `pr_reviewer_quota_marker_test.sh:231` 以降で検証。
- 2.1 — Triage は `local-watcher/bin/idd-codex-issue-watcher.sh:7899` / `:7911` で quota wait 経路へ接続し、`qa_run_codex_stage_test.sh:309` / `:324` で検証。
- 2.2 — `qa_extract_usage_limit_reset_epoch` が `local-watcher/bin/modules/quota-aware.sh:165` 以降で reset 時刻を epoch 化し、Issue 経路は `qa_handle_quota_exceeded` が `:589` で保存する。
- 2.3 — Triage の quota wait は `local-watcher/bin/idd-codex-issue-watcher.sh:7906` 以降で `_slot_mark_failed` を踏まず return 0 する。
- 3.1 — Issue 経路は `local-watcher/bin/modules/quota-aware.sh:589`、PR Reviewer 経路は `local-watcher/bin/modules/pr-reviewer.sh:617` で reset epoch を保存する。
- 3.2 — Issue resume は `local-watcher/bin/modules/quota-aware.sh:623` 以降、PR Reviewer resume は `local-watcher/bin/modules/pr-reviewer.sh:689` 以降で reset + grace 経過後に待機解除する。
- 3.3 — Issue 経路は quota wait 時に failure 経路へ進まず、PR Reviewer 経路は `local-watcher/bin/modules/pr-reviewer.sh:720` 以降で quota label だけを外して次サイクルの再レビュー候補へ戻す。
- 4.1 — reset 時刻なし usage-limit 風 fatal は `local-watcher/bin/modules/quota-aware.sh:274` 以降で epoch 抽出不能時に codex rc を透過し、`qa_run_codex_stage_test.sh:327` で検証。
- 4.2 — reset 時刻なし usage-limit 風 fatal は quota wait ラベルを付けず既存 failure call site に戻る構造を維持している。
- 5.1 — non-quota fatal は `local-watcher/bin/modules/quota-aware.sh:285` 以降で rc 透過され、`qa_run_codex_stage_test.sh:330` で検証。
- 5.2 — quota wait と分類しない場合は `mark_issue_failed` / `_slot_mark_failed` など既存失敗経路へ戻るため、既存の失敗ログとラベル遷移契約を維持している。
- 6.1 — `qa_detect_rate_limit_test.sh:161` 以降と `qa_run_codex_stage_test.sh:293` 以降で reset あり usage-limit fatal の検出と epoch 化を検証。
- 6.2 — `qa_run_codex_stage_test.sh:333` 以降で 529 overloaded が usage-limit quota wait に誤分類されず、既存 529 detector で検出されることを検証。
- 6.3 — `qa_run_codex_stage_test.sh:315` 以降で Stage A の `codex-needs-quota-wait` 付与、`codex-failed` 不付与、`mark_issue_failed` 未呼び出し、reset 永続化を検証。
- 6.4 — `qa_run_codex_stage_test.sh:318` / `:321` 以降で Reviewer stage と Debugger 後 Reviewer round の quota label 遷移と `codex-failed` 不付与を検証。
- 6.5 — `qa_run_codex_stage_test.sh:324` 以降で Triage の quota label 遷移と `codex-failed` 不付与を検証。
- 6.6 — `qa_run_codex_stage_test.sh:327` 以降で reset 時刻なし usage-limit 風 fatal が Option B どおり rc 透過されることを検証。

## Findings

なし

## Summary

round=1 の missing test 2 件は、Stage A / Reviewer / Debugger 後 Reviewer / Triage のラベル遷移テストと PR Reviewer command 非ゼロ経路テストで解消されている。`tasks.md` と `design.md` は指定 spec dir に存在しないため、境界照合は requirements の Scope と差分パスで確認した。

RESULT: approve
