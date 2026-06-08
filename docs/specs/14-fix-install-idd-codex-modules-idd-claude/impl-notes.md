# Implementation Notes

### Task 1

- 採用方針: `local-watcher/bin/modules` を `local-watcher/bin/idd-codex-modules` へ rename し、task 1 の `_Requirements:_` に必要な installer / loader / README / test 参照も同じ namespace に揃える。
- 重要な判断: module 本体ロジック、関数名、ファイル名、`REQUIRED_MODULES` の構成は変更せず、配置先と解決先の契約だけを更新した。
- 残存課題: rules の verify 例と README の migration note 詳細は後続 task の対象として残る。
