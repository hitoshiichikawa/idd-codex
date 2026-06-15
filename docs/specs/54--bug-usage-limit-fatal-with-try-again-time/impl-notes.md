# Issue #54 実装ノート

## 実装概要

- Codex CLI の usage-limit fatal が `usage_limit_fatal` として検出された後、自然言語 parser が reset epoch を抽出できない場合でも、message に `try again at ...` の reset hint があれば quota wait に分類するようにした。
- fallback reset epoch は `now + QUOTA_USAGE_LIMIT_FALLBACK_WAIT_SEC` とし、既定値は 18000 秒にした。
- reset hint が無い usage-limit fatal は、既存 #12 Option B の決定どおり通常 failure path へ透過する。
- feedman-ios #32 で観測された `try again at 8:11 PM` 形式の fixture と、parser が取りこぼす reset hint 形式の fixture を追加した。
- README の Quota-Aware Watcher 説明と環境変数表に fallback 動作を追記した。

## 変更ファイル

- `local-watcher/bin/idd-codex-issue-watcher.sh`
- `local-watcher/bin/idd-codex-modules/quota-aware.sh`
- `local-watcher/test/qa_run_codex_stage_test.sh`
- `local-watcher/test/fixtures/qa_detect_rate_limit/usage-limit-feedman32-time-only-reset.jsonl`
- `local-watcher/test/fixtures/qa_detect_rate_limit/usage-limit-unparsed-reset-hint.jsonl`
- `README.md`

## 検証

- `bash local-watcher/test/qa_detect_rate_limit_test.sh`
  - 成功。
- `bash local-watcher/test/qa_run_codex_stage_test.sh`
  - 成功。98 tests passed。
- `bash -n local-watcher/bin/idd-codex-issue-watcher.sh local-watcher/bin/idd-codex-modules/quota-aware.sh local-watcher/test/qa_run_codex_stage_test.sh local-watcher/test/qa_detect_rate_limit_test.sh`
  - 成功。
- `$HOME/bin` の installed copy に watcher 本体と `quota-aware.sh` を同期し、source と byte 一致することを確認した。
- `$HOME/bin/idd-codex-modules/quota-aware.sh` 側で unparsed reset hint の usage-limit fatal が `qa_run_codex_stage` rc=99 になることを確認した。

## 未実施

- `shellcheck`
  - この環境では `shellcheck` が PATH に無いため未実施。
