# Implementation Notes: PR Iteration no-progress round の ready 遷移防止

## 実装概要

- `local-watcher/bin/modules/pr-iteration.sh` に `pi_resolve_success_action` を追加し、Codex が正常終了した後の label transition を `success` / `hold` / `escalate` に分岐した。
- head branch に新規 commit が無い round は、`no-progress-streak` marker を更新した後、閾値未満なら `action=hold` として `codex-needs-iteration` を残置する。
- head branch に新規 commit が無い round で streak が `PR_ITERATION_NO_PROGRESS_LIMIT` 以上の場合は、既存の no-progress escalation 経路で `codex-failed` に遷移する。
- explicit reply-only success contract は現時点で未定義のため、no-commit round を success label transition の対象にしない。
- README の PR Iteration Processor 説明を、新規 commit がある場合のみ ready 系ラベルへ戻す挙動に更新した。

## 変更ファイル

- `local-watcher/bin/modules/pr-iteration.sh`
- `local-watcher/test/pi_no_progress_transition_test.sh`
- `README.md`
- `docs/specs/3--bug-pr-iteration-marks-no-progress-roun/requirements.md`
- `docs/specs/3--bug-pr-iteration-marks-no-progress-roun/impl-notes.md`

## テスト結果

```bash
bash local-watcher/test/pi_no_progress_transition_test.sh
# PASS: 5, FAIL: 0
```

```bash
bash local-watcher/test/pi_max_rounds_kind_test.sh
# PASS: 24, FAIL: 0
```

```bash
shellcheck local-watcher/bin/modules/pr-iteration.sh local-watcher/test/pi_no_progress_transition_test.sh
# 成功
```

```bash
shellcheck local-watcher/bin/modules/pr-iteration.sh local-watcher/test/pi_no_progress_transition_test.sh local-watcher/test/pi_max_rounds_kind_test.sh
# 失敗: local-watcher/test/pi_max_rounds_kind_test.sh の既存 SC2034 警告
```

## 後方互換性

- 既存 env var 名、ラベル名、`PR_ITERATION_NO_PROGRESS_LIMIT` の既定値は変更していない。
- `codex-needs-iteration` から ready 系ラベルへ戻る条件を、新規 commit が観測された場合に限定した。
- no-progress 上限到達時の `codex-failed` escalation コメントと marker 形式は既存のまま維持した。

## 確認事項

- 追加確認が必要な事項は無し。
