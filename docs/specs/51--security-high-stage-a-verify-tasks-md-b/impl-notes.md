# Implementation Notes

## 実装概要

- `tasks.md` 由来の Stage A Verify コマンド（`structured-block` / `heuristic`）を、watcher の非 sandbox `bash -c` ではなく `codex sandbox -P "$STAGE_A_VERIFY_SANDBOX_PROFILE" -C "$REPO_DIR" -- bash -c "$cmd"` で実行するよう変更した。
- 既定 profile は `:workspace` とし、`:danger-full-access` / `danger-full-access` は repository 由来 verify では実行前に拒否して fail-closed する。
- `STAGE_A_VERIFY_COMMAND` は operator が cron / launchd で明示する escape hatch として、既存の直接実行 semantics を維持した。
- `&&` / `|` / `;` / 改行などの shell メタ文字は watcher 側では解釈・拒否せず、sandbox 内の `bash -c` へそのまま渡す。
- README の Stage A Verify 詳細とオプション一覧に、repo 由来 verify と operator override の信頼境界差を追記した。

## テスト結果

- `bash local-watcher/test/stage_a_verify_sandbox_boundary_test.sh`
- `shellcheck --severity=warning local-watcher/bin/idd-codex-modules/stage-a-verify.sh local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/test/stage_a_verify_sandbox_boundary_test.sh`

## 確認事項

- この実行環境では `codex sandbox -P :workspace` が Linux sandbox helper の制約で失敗するため、実機の sandbox 成功確認は fake `CODEX_BIN` による境界回帰テストで担保した。実運用でも sandbox が確立できない場合は非 sandbox へ fallback せず Stage A Verify の失敗として扱う。

STATUS: complete
