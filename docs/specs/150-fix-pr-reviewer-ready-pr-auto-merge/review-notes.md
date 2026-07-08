# Review Notes

<!-- idd-codex:review round=1 model=gpt-5.5 timestamp=2026-07-03T05:29:18Z -->

## Reviewed Scope

- Branch: codex/issue-150-impl-fix-pr-reviewer-ready-pr-auto-merge
- HEAD commit: 6d4f9e48a2eb370d68a02a3cb4c8dfbf3acf1764
- Compared to: main..HEAD

## Verified Requirements

- 1.1 - `local-watcher/bin/idd-codex-modules/pr-reviewer.sh:287` の open/non-draft/same-owner/managed head 候補列挙と `local-watcher/test/pr_reviewer_ready_candidate_test.sh:143` の ready PR 候補化テストを確認。
- 1.2 - `local-watcher/bin/idd-codex-modules/pr-reviewer.sh:322` の PR JSON 起点 filtering は Issue label に依存せず、ready PR を候補から除外しないことを確認。
- 1.3 - `local-watcher/bin/idd-codex-modules/pr-reviewer.sh:290` で `reviewDecision` / `statusCheckRollup` を取得しつつ除外条件に使わず、`local-watcher/test/pr_reviewer_ready_candidate_test.sh:145` で空値候補を確認。
- 1.4 - `local-watcher/bin/idd-codex-modules/pr-reviewer.sh:325` は watcher-created 判定を使わず same-owner managed head を候補化するため、手動作成 PR も同じ gate 対象になることを確認。
- 1.5 - 既存 `pr_already_processed` による同一 SHA `kind=review` marker skip と `bash local-watcher/test/pr_reviewer_approval_signal_test.sh` PASS を確認。
- 2.1 - `local-watcher/bin/idd-codex-modules/auto-merge.sh:190` の review/status gate と `local-watcher/test/auto_merge_test.sh:153` の証跡なし merge 0 回テストを確認。
- 2.2 - `local-watcher/bin/idd-codex-modules/auto-merge.sh:116` の approval resolver が GitHub approval または current-SHA marker を要求し、non-approved は marker approve なしでは通らないことを確認。
- 2.3 - `local-watcher/bin/idd-codex-modules/auto-merge.sh:146` の status resolver が empty/pending/failure/unknown を reject/unknown に倒すことを確認。
- 2.4 - `local-watcher/bin/idd-codex-modules/auto-merge.sh:135` と `local-watcher/bin/idd-codex-modules/auto-merge.sh:173` の API/parse failure skip と warning、`local-watcher/test/auto_merge_test.sh:178` の comments API failure テストを確認。
- 2.5 - `local-watcher/bin/idd-codex-modules/auto-merge.sh:246` の blocking label gate が `codex-needs-iteration` / `codex-needs-rebase` も含めて skip することを確認。
- 3.1 - `local-watcher/bin/idd-codex-modules/auto-merge.sh:371` で auto-merge 有効化直前に gate を解決し、同 cycle でも証跡なし PR を skip することを確認。
- 3.2 - `local-watcher/bin/idd-codex-modules/auto-merge.sh:190` で approval と review status の両方を要求し、`local-watcher/test/auto_merge_test.sh:160` で current-SHA marker + status success の enable を確認。
- 3.3 - `local-watcher/bin/idd-codex-modules/auto-merge.sh:87` の current blocking marker 優先判定により iteration verdict は auto-merge を通さないことを確認。
- 3.4 - `local-watcher/bin/idd-codex-modules/auto-merge.sh:135` のコメント取得失敗時 unknown skip と `local-watcher/test/auto_merge_test.sh:178` の warning/no merge を確認。
- 3.5 - `local-watcher/bin/idd-codex-modules/auto-merge.sh:190` が GitHub native auto-merge 可否だけでなく local review/status gate を必須にすることを確認。
- 4.1 - `local-watcher/bin/idd-codex-modules/pr-reviewer.sh:297` の candidate totals / skip reason ログと `local-watcher/test/pr_reviewer_ready_candidate_test.sh:146` のログ検証を確認。
- 4.2 - `local-watcher/bin/idd-codex-modules/auto-merge.sh:377` の review gate missing reason ログを確認。
- 4.3 - `local-watcher/bin/idd-codex-modules/auto-merge.sh:296` の auto-merge enable ログに accepted review gate source が含まれることを確認。
- 4.4 - `README.md:1408` と `README.md:1450` で current-head review gate evidence 必須と branch protection 非代替が文書化されていることを確認。
- 4.5 - `README.md:2537` で手動・外部作成 managed PR も同じ review gate 対象と文書化されていることを確認。
- 5.1 - `local-watcher/test/pr_reviewer_ready_candidate_test.sh:76` と `local-watcher/test/pr_reviewer_ready_candidate_test.sh:143` で empty review/status の ready managed PR 候補化を確認。
- 5.2 - `local-watcher/test/auto_merge_test.sh:148` で current-head evidence なし ready PR が `gh pr merge` を呼ばないことを確認。
- 5.3 - `local-watcher/test/auto_merge_test.sh:160` と `local-watcher/test/auto_merge_test.sh:186` で approve evidence + review status success の enable を確認。
- 5.4 - `local-watcher/test/auto_merge_test.sh:169` で stale old-SHA marker が merge 0 回になることを確認。
- 5.5 - `local-watcher/test/auto_merge_test.sh:178` で metadata fetch failure が warning + no merge になることを確認。
- NFR 1.1 - env var / label / exit code の既存名変更なし。変更は既存 module と README/test に限定されていることを確認。
- NFR 1.2 - `process_pr_reviewer` の既存 gate と `bash local-watcher/test/security_medium_pr_reviewer_test.sh` PASS を確認。
- NFR 1.3 - `process_auto_merge` の `FULL_AUTO_ENABLED` / `AUTO_MERGE_ENABLED` gate と `local-watcher/test/auto_merge_test.sh:140` の no-op テストを確認。
- NFR 1.4 - `LABEL_READY` / failed / needs-decisions / needs-iteration / needs-rebase の既存ラベル名を維持していることを確認。
- NFR 2.1 - `local-watcher/bin/idd-codex-modules/auto-merge.sh:190` が ambiguous/stale/missing/unavailable evidence を skip 側に倒すことを確認。
- NFR 2.2 - `local-watcher/bin/idd-codex-modules/auto-merge.sh:274` は `gh pr merge --auto --squash --delete-branch` のみで direct merge を追加していないことを確認。
- NFR 2.3 - 新規外部サービス依存はなく、既存 GitHub CLI と PR reviewer evidence の利用に留まることを確認。
- NFR 3.1 - `local-watcher/bin/idd-codex-modules/pr-reviewer.sh:305` と `local-watcher/bin/idd-codex-modules/auto-merge.sh:340` で fork PR 除外を維持していることを確認。
- NFR 3.2 - PR title/body 等を watcher 指示として解釈する変更はなく、JSON field と label/head/status のデータ判定に限定されていることを確認。
- NFR 3.3 - `local-watcher/bin/idd-codex-modules/pr-reviewer.sh:307` と `local-watcher/bin/idd-codex-modules/auto-merge.sh:234` で managed head pattern 外を除外していることを確認。

## Findings

なし

## Summary

AC 対応の実装と回帰テストは確認できた。`tasks.md` / `design.md` は存在しないため `_Boundary:_` 注記による照合はできなかったが、差分は `local-watcher/` と `README.md` に限定され、3 カテゴリの reject 理由は検出しなかった。

Verification: `auto_merge_test.sh` PASS 37/0、`pr_reviewer_ready_candidate_test.sh` PASS 6/0、`pr_reviewer_approval_signal_test.sh` PASS 20/0、`security_medium_pr_reviewer_test.sh` PASS 29/0、対象 `shellcheck --severity=warning` PASS。

RESULT: approve
