# Review Notes

<!-- idd-codex:review round=2 model=gpt-5.5 timestamp=2026-06-22T05:54:09Z -->

## Reviewed Scope

- Branch: codex/issue-51-impl--security-high-stage-a-verify-tasks-md-b
- HEAD commit: 7843b5ff1ca3e7074c5814937b5198a941cc1e52
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:920` / `structured-block` と `heuristic` を `codex sandbox` 経由で実行する分岐を確認。
- 1.2 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:923` / repository 由来 verify は非 sandbox `bash -c` に直接渡さず sandbox runner に委譲する。
- 1.3 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:110`、`:860`、`:886` / no-sandbox profile と source sidecar 伝達失敗を fail-closed し、非 sandbox fallback が無いことを確認。
- 1.4 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:115`、`:801`、`:954` / sandbox 実行開始、sidecar fail-closed、失敗 exit がログと通常 round 処理に残る。
- 2.1 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:573` / 有効な `stage-a-verify` 構造化ブロックを第一候補として解決する。
- 2.2 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:573`、`:581`、`:590` / 構造化ブロック、env-command、heuristic、SKIPPED の既存解決順を維持している。
- 2.3 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:581`、`:924` / `STAGE_A_VERIFY_COMMAND` は operator override として直接実行 semantics を維持する。
- 2.4 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:117`、`local-watcher/test/stage_a_verify_sandbox_boundary_test.sh:134` / 複合 shell コマンドをメタ文字だけで拒否せず sandbox 内 `bash -c` へ渡す。
- 3.1 — `local-watcher/test/stage_a_verify_sandbox_boundary_test.sh:155` / 外部送信を含む structured-block が watcher 権限で marker を作らず sandbox runner に渡る。
- 3.2 — `local-watcher/bin/idd-codex-modules/stage-a-verify.sh:66`、`:920` / keyword gate ではなく source 判定で repository 由来 verify を sandbox 対象にしている。
- 3.3 — `local-watcher/test/stage_a_verify_sandbox_boundary_test.sh:155`、`:207`、`:228` / prompt injection 相当の malicious / sidecar 異常系で repository 由来コマンドが watcher 権限で直接実行されない。
- 4.1 — `README.md:4040` / repository 由来 verify が `codex sandbox` 境界内で実行される旨を確認。
- 4.2 — `README.md:4050` / operator 明示設定と repository 由来自動 verify の信頼境界差を確認。
- 4.3 — `README.md:4032`、`:4035` / 自動 verify の解決順を維持しつつ sandbox 実行へ移行する方針を確認。
- 5.1 — `local-watcher/test/stage_a_verify_sandbox_boundary_test.sh:127`、`:163`、`:199` / structured-block / heuristic / sidecar 失敗で非 sandbox 直接実行されないことを検証。
- 5.2 — `local-watcher/test/stage_a_verify_sandbox_boundary_test.sh:147` / 外部送信を含む malicious structured-block が watcher 権限で直接実行されないことを検証。
- 5.3 — `local-watcher/test/stage_a_verify_sandbox_boundary_test.sh:127` / 有効な構造化ブロックが sandbox 境界内の自動 verify として利用されることを検証。
- 5.4 — `local-watcher/test/stage_a_verify_sandbox_boundary_test.sh:175` / `STAGE_A_VERIFY_COMMAND` が sandbox を呼ばず従来どおり直接実行されることを検証。
- 5.5 — `shellcheck --severity=warning local-watcher/bin/idd-codex-modules/stage-a-verify.sh local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/test/stage_a_verify_sandbox_boundary_test.sh` を reviewer 側でも実行し成功。

## Findings

なし

## Summary

`git diff --stat main..HEAD` / `git log --oneline main..HEAD` / 変更ファイル別 diff を確認済み。指定された `tasks.md` と `design.md` は存在しなかったため、requirements と既存実装・テスト差分の突き合わせで AC 判定した。

round 1 の source sidecar 伝達失敗時 fail-open は、同一シェル resolver 呼び出し、sidecar の既知値検証、書き込み・読み取り・mismatch の fail-closed 処理、および回帰テストで解消されている。追加テストと shellcheck も再実行して成功した。

RESULT: approve
