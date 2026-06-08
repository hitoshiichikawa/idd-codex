# Review Notes

<!-- idd-codex:review round=1 model=gpt-5.5 timestamp=2026-06-08T12:40:05Z -->

## Reviewed Scope

- Branch: codex/issue-2-impl--bug-pr-iteration-filters-pr-reviewer-co
- HEAD commit: a04cc1f423a3fe585c4b3ecf2fe99e43f82e8a61
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `local-watcher/test/pi_general_filter_self_test.sh:73` / `VERDICT: codex-needs-iteration` を含む reviewer comment が fixture 入力に含まれ、`local-watcher/test/pi_general_filter_self_test.sh:99` で保持を検証している。
- 1.2 — `local-watcher/bin/modules/pr-iteration.sh:239` / 自己コメント除外条件が `idd-codex:pr-iteration` 系 marker に限定され、`idd-codex:pr-reviewer` marker は除外条件に一致しない。
- 2.1 — `local-watcher/test/pi_general_filter_self_test.sh:77` と `local-watcher/test/pi_general_filter_self_test.sh:103` / `idd-codex:pr-iteration-processing` marker 付きコメントの除外を検証している。
- 2.2 — `local-watcher/test/pi_general_filter_self_test.sh:85`、`local-watcher/test/pi_general_filter_self_test.sh:89`、`local-watcher/test/pi_general_filter_self_test.sh:107` / `idd-codex:pr-iteration` 本体 marker と `pr-iteration-529-warning` 系 marker の除外を検証している。
- 3.1 — `local-watcher/test/pi_general_filter_self_test.sh:70` から `local-watcher/test/pi_general_filter_self_test.sh:109` / reviewer marker と PR Iteration self marker を同一 shell-level fixture に投入し、残存・除外を確認している。

## Findings

なし

## Summary

AC に対応する実装と shell-level regression test は確認できた。`tasks.md` は指定パスに存在しなかったため `_Boundary:_` アノテーションとの照合はできなかったが、差分は `pr-iteration.sh` の対象関数と追加 fixture、spec ノートに限定されている。

Reviewer 再実行: `bash local-watcher/test/pi_general_filter_self_test.sh`、`bash local-watcher/test/pi_max_rounds_kind_test.sh`、`shellcheck local-watcher/bin/modules/pr-iteration.sh local-watcher/test/pi_general_filter_self_test.sh`、`for test_file in local-watcher/test/*_test.sh; do bash "$test_file"; done` はすべて成功。

RESULT: approve
