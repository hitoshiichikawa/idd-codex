# Implementation Notes

## Implementation Notes

### Task 1

- 採用方針: `tasks-generation.md` を正準 contract とし、Architect prompt は同 contract への参照と tasks 生成時の自己チェック観点だけを追加した。root と `repo-template/` は同一内容で更新した。
- 重要な判断: task 1 の範囲外である Developer / Reviewer prompt と README は触らず、fixture driver も shared rule / Architect prompt / valid-invalid fixture の初版検証に限定した。
- 残存課題: Developer / Reviewer prompt の接続、README key phrase assertion、完成版 fixture coverage は後続 task 2〜4 で扱う。

### Task 2

- 採用方針: Developer / Reviewer prompt を Task Boundary Contract に接続し、同じ contract を `contract-driver.sh` の key phrase assertion で検証した。
- 重要な判断: Developer には対象 task の `_Requirements:_` に含まれる AC の必要 test を同 task 作業として扱う責務を明記し、Reviewer には per-task の `missing test` 判定対象を当該 task の `_Requirements:_` に限定する責務を明記した。
- 残存課題: README の運用説明と完成版 fixture coverage は後続 task 3〜4 で扱う。

### Task 3

- 採用方針: README の Reviewer Gate / Per-task TDD Implementation Loop 説明に、prompt と同じ task-boundary contract を運用者向けに要約した。
- 重要な判断: `missing test` の scope 限定、same-task test work、deferred coverage AC の除外、`- [ ]*` の optional / deferrable 表記維持を README key phrase assertion で固定した。
- 残存課題: 完成版 fixture coverage と root / repo-template sync verification の最終整理は task 4 で扱う。

### Task 4

- 採用方針: fixture を canonical な annotation 表記へ寄せ、driver で same-task / deferred / invalid deferred AC の境界を明示的に検証した。
- 重要な判断: prompt / rule / README の主要 assertion と root / repo-template sync は shell-level driver で検証可能と判断し、prompt-only の未自動化項目は残していない。
- 残存課題: なし。
