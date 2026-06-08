# Issue #2 実装ノート

## 変更概要

- `pi_general_filter_self` の自己投稿判定を `idd-codex:` marker 全般から `idd-codex:pr-iteration` 系 marker に限定した。
- `idd-codex:pr-reviewer` marker 付きの reviewer verdict コメントは PR Iteration の一般コメント入力として残る。
- PR Iteration 自身の `idd-codex:pr-iteration-processing` / `idd-codex:pr-iteration` / `idd-codex:pr-iteration-529-warning` 系 marker は引き続き除外される。
- `local-watcher/test/pi_general_filter_self_test.sh` を追加し、reviewer marker と PR Iteration self marker の回帰 fixture を検証した。

## 要件対応

- Requirement 1: reviewer の `VERDICT: codex-needs-iteration` コメントと `idd-codex:pr-reviewer` marker 付きコメントを自己投稿として除外しない。
- Requirement 2: PR Iteration 処理 marker は自己投稿として除外する。
- Requirement 3: shell-level regression test を追加した。

## 検証

```bash
bash local-watcher/test/pi_general_filter_self_test.sh
bash local-watcher/test/pi_max_rounds_kind_test.sh
shellcheck local-watcher/bin/modules/pr-iteration.sh local-watcher/test/pi_general_filter_self_test.sh
for test_file in local-watcher/test/*_test.sh; do bash "$test_file"; done
```

結果: すべて成功。

## 確認事項

- なし。
