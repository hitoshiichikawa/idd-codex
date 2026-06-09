# Implementation Notes

### Task 1

- 採用方針: `pt_resolve_diff_range` で marker 後 commit を検出し、安全に解ける場合は `range_end=HEAD` に補正する。
- 重要な判断: `pt_resolve_diff_range` の stdout は既存 caller 互換の SHA pair のみに保ち、grep 可能な診断は stderr 経由で `$LOG` に残す。
- 重要な判断: `pt_should_skip_reviewer` も補正後 range を使うため、marker 後 corrective commit がある親 task を checkbox-only と誤判定しない。
- 重要な判断: task 1 の Req 5.1 は `pt_resolve_diff_range` 単体の #14 形状 fixture で検証し、retry / Debugger 経路の網羅は後続 task に残す。
- 残存課題: prompt、README、retry / Debugger 経路の追加 regression coverage は後続 task の範囲。
