# Review Notes

<!-- idd-codex:review round=1 model=gpt-5.5 timestamp=2026-06-18T06:41:24Z -->

## Reviewed Scope

- Branch: codex/issue-48-impl--security-high-codex-danger-full-access
- HEAD commit: 06ed9da713c1b8819ad61abf1573f1099e10d7f6
- Compared to: main..HEAD

## Verified Requirements

- 1.1 - `local-watcher/bin/idd-codex-issue-watcher.sh:490`-`492` で既存 env var 名と default override 形式を維持している。
- 1.2 - `local-watcher/bin/idd-codex-issue-watcher.sh:492` と `:675`-`:677` で未設定時は `CODEX_UNSAFE_BYPASS=true` となり、従来どおり bypass 引数を付与する。
- 1.3 - `local-watcher/bin/idd-codex-issue-watcher.sh:678`-`:680` で `CODEX_UNSAFE_BYPASS=false` 時に `CODEX_SANDBOX` / `CODEX_APPROVAL_POLICY` を使う非 bypass 経路を維持している。
- 2.1 - `local-watcher/bin/idd-codex-issue-watcher.sh:5899`-`:5903` と `local-watcher/bin/idd-codex-triage-prompt.tmpl:12`-`:14` で Issue title/body を未信頼データとして扱う警告を prompt 内に追加している。
- 2.2 - `local-watcher/bin/idd-codex-issue-watcher.sh:5916`-`:5920` で Issue body を start/end marker で囲んでいる。
- 2.3 - `local-watcher/bin/idd-codex-issue-watcher.sh:5901`-`:5903`、`:5916`-`:5920` と `local-watcher/test/prompt_untrusted_boundary_test.sh:73`-`:84` で命令文・コードフェンス風本文を Issue 由来データとして prompt に保持する挙動を確認している。
- 3.1 - `local-watcher/bin/idd-codex-iteration-prompt.tmpl:44`-`:52` と `local-watcher/bin/idd-codex-iteration-prompt-design.tmpl:49`-`:57` で line コメント JSON を未信頼データとして明示している。
- 3.2 - `local-watcher/bin/idd-codex-iteration-prompt.tmpl:65`-`:72` と `local-watcher/bin/idd-codex-iteration-prompt-design.tmpl:70`-`:77` で一般コメント本文から実行権限・承認・制約緩和の指示を受け取らないことを明示している。
- 4.1 - `README.md:1312`-`:1316` と `README.md:1363`-`:1365` で Guard Hook 既定 OFF と公開 repo での `IDD_CODEX_HOOKS_ENABLED=true` 推奨を確認できる。
- 4.2 - `README.md:1387`-`:1400` で `CODEX_UNSAFE_BYPASS` / `CODEX_SANDBOX` / `CODEX_APPROVAL_POLICY` の関係と既定値を反転しない理由を説明している。
- 4.3 - `README.md:1402`-`:1409` で `CODEX_UNSAFE_BYPASS=false`、sandbox、approval policy、Guard Hook の安全側設定例を提示している。
- 5.1 - `local-watcher/test/prompt_untrusted_boundary_test.sh:73`-`:84` と再実行結果で Issue title/body の未信頼データ警告と body marker を確認した。
- 5.2 - `local-watcher/test/pr_iteration_prompt_untrusted_boundary_test.sh:61`-`:72` と再実行結果で PR コメント JSON と未信頼データ警告を確認した。
- 5.3 - `shellcheck --severity=warning local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/test/context_map_prompt_test.sh local-watcher/test/triage_prompt_render_safety_test.sh local-watcher/test/prompt_untrusted_boundary_test.sh local-watcher/test/pr_iteration_prompt_untrusted_boundary_test.sh` が警告なしで完了した。

## Test Coverage

- `bash local-watcher/test/prompt_untrusted_boundary_test.sh` - PASS
- `bash local-watcher/test/pr_iteration_prompt_untrusted_boundary_test.sh` - PASS
- `bash local-watcher/test/triage_prompt_render_safety_test.sh` - PASS
- `bash local-watcher/test/context_map_prompt_test.sh` - PASS
- `shellcheck --severity=warning local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/test/context_map_prompt_test.sh local-watcher/test/triage_prompt_render_safety_test.sh local-watcher/test/prompt_untrusted_boundary_test.sh local-watcher/test/pr_iteration_prompt_untrusted_boundary_test.sh` - PASS

## Findings

なし

## Summary

`git diff --stat main..HEAD` と `git log --oneline main..HEAD` は取得済みで、差分は空ではない。指定された `tasks.md` は存在しなかったため、boundary は requirements の Scope と変更ファイル範囲に照らして確認した。AC 未カバー、missing test、boundary 逸脱はいずれも検出しなかった。

RESULT: approve
