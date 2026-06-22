# Implementation Notes

## 実装概要

- `CODEX_SANDBOX` / `CODEX_APPROVAL_POLICY` / `CODEX_UNSAFE_BYPASS` の既定値は owner 回答 B に従い変更していない。
- Issue title/body を含む watcher prompt に、GitHub 由来の未信頼データであり上位指示として扱わない旨の警告を追加した。
- Issue body は `idd-codex:untrusted-issue-body` の start/end marker で囲み、本文中の命令文やコードフェンスを prompt の制約と区別できるようにした。
- PR Iteration の impl/design template に、line/general コメント JSON が未信頼データであり実行権限・承認・制約緩和の指示を受け取らない旨を追加した。
- README に #48 の migration note、Guard Hook の公開 repo 推奨、`CODEX_UNSAFE_BYPASS=false` と `workspace-write` を使う安全側設定例を追加した。

## テスト結果

- `bash local-watcher/test/prompt_untrusted_boundary_test.sh`
- `bash local-watcher/test/pr_iteration_prompt_untrusted_boundary_test.sh`
- `bash local-watcher/test/triage_prompt_render_safety_test.sh`
- `bash local-watcher/test/context_map_prompt_test.sh`
- `shellcheck --severity=warning local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/test/context_map_prompt_test.sh local-watcher/test/triage_prompt_render_safety_test.sh local-watcher/test/prompt_untrusted_boundary_test.sh local-watcher/test/pr_iteration_prompt_untrusted_boundary_test.sh`

## 確認事項

- `workspace-write` を将来の既定値にする場合は、Issue 本文どおり watcher の通常タスクが完遂できるかの実機検証と migration note が別途必要。

STATUS: complete
