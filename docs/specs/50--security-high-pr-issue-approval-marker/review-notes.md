# Review Notes

<!-- idd-codex:review round=1 model=gpt-5.5 timestamp=2026-06-17T09:47:57Z -->

## Reviewed Scope

- Branch: codex/issue-50-impl--security-high-pr-issue-approval-marker
- HEAD commit: 88ea8fe55f99529b2c45f1bafb118aa1703d2a98
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `local-watcher/bin/idd-codex-modules/promote-pipeline.sh:182` の jq filter が信頼済み `author_association` に先に絞り、`po_load_edit_paths_trusted_authors_test.sh` の OWNER / MEMBER / COLLABORATOR 採用ケースで確認。
- 1.2 — `local-watcher/test/po_load_edit_paths_trusted_authors_test.sh:161` の mixed comments ケースで未信頼 marker が採用されないことを確認。
- 1.3 — `local-watcher/test/po_load_edit_paths_trusted_authors_test.sh:168` の未信頼最後勝ち防止ケースで確認。
- 1.4 — `local-watcher/test/po_load_edit_paths_trusted_authors_test.sh:174` の信頼済み marker 不在ケースで `[]` を確認。
- 1.5 — `PATH_OVERLAP_CHECK=true` gate は既存箇所のままで、差分は `po_load_edit_paths` 内の loader に限定。
- 2.1 — `promote-pipeline.sh:187` の trusted association 集合が `OWNER` / `MEMBER` / `COLLABORATOR` に限定され、信頼済み comment のみ marker 入力になることを確認。
- 2.2 — `promote-pipeline.sh:195` 以降で `select(trusted_author)` 後に body を読む構造になっており、未信頼 comment 本文を特権判断に使わない。
- 2.3 — `po_load_edit_paths_trusted_authors_test.sh:161` / `:168` の forged marker ケースで、正規形式の未信頼 marker を無視することを確認。
- 2.4 — marker 採否は `.author_association` に基づき、本文形式だけで trusted signal にしない実装とテストを確認。
- 3.1 — `merge_queue_approval_signal_test.sh:170` 以降で未信頼 approve / iteration / reject marker が approval / control signal にならないことを確認。
- 3.2 — `pi_general_filter_untrusted_authors_test.sh:84` 以降で未信頼一般コメントが filter されることを確認。
- 3.3 — `merge_queue_approval_signal_test.sh:171` / `:177` の未信頼 `VERDICT: approve` ケースで approved 扱いにならないことを確認。
- 3.4 — `pi_general_filter_untrusted_authors_test.sh:80` / `:81` の prompt injection 風コメントが prompt 入力候補から除外されることを確認。
- 3.5 — 4-A / 4-B regression tests を verify block で実行し、`merge_queue_approval_signal_test.sh` は PASS: 16 / FAIL: 0、`pi_general_filter_untrusted_authors_test.sh` は PASS: 8 / FAIL: 0。
- 4.1 — `po_load_edit_paths_trusted_authors_test.sh:151` / `:156` の信頼済み marker 採用ケースで従来どおり path array を返すことを確認。
- 4.2 — Merge Queue production code は変更されず、信頼済み marker semantics は既存 regression で維持確認。
- 4.3 — PR Iteration production code は変更されず、信頼済み一般コメント semantics は既存 regression で維持確認。
- 4.4 — 差分に env var 名、ラベル名、cron / launchd 前提、exit code 意味の変更はなく、README は `PATH_OVERLAP_CHECK` の off semantics 不変を明記。
- NFR 1.1 — `promote-pipeline.sh:195` 以降の jq-only 抽出で、コメント本文を信頼情報から切り離して扱うことを確認。
- NFR 1.2 — 未信頼 `edit-paths-json` / MQ marker / PR Iteration comment が各 regression で採用されないことを確認。
- NFR 2.1 — trusted / untrusted を区別する 4-C / 4-A / 4-B regression tests を確認。
- NFR 2.2 — `po_load_edit_paths_trusted_authors_test.sh:168` の未信頼最後勝ち注入テストを確認。
- NFR 3.1 — `PATH_OVERLAP_CHECK` gate は未変更で、README も未設定 / `off` / 不正値の no-op 維持を記載。
- NFR 3.2 — 4-A / 4-B production code は変更せず、既存修正を regression で固定していることを確認。

## Findings

なし。

## Summary

`main..HEAD` の差分は 4-C loader、4-C/4-A/4-B regression、README、spec 記録に収まっていた。指定 verify block は成功し、AC 未カバー、missing test、boundary 逸脱はいずれも検出しなかった。

RESULT: approve
