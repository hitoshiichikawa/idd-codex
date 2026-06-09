# Implementation Notes

### Task 1

- 採用方針: `pt_resolve_diff_range` で marker 後 commit を検出し、安全に解ける場合は `range_end=HEAD` に補正する。
- 重要な判断: `pt_resolve_diff_range` の stdout は既存 caller 互換の SHA pair のみに保ち、grep 可能な診断は stderr 経由で `$LOG` に残す。
- 重要な判断: `pt_should_skip_reviewer` も補正後 range を使うため、marker 後 corrective commit がある親 task を checkbox-only と誤判定しない。
- 重要な判断: task 1 の Req 5.1 は `pt_resolve_diff_range` 単体の #14 形状 fixture で検証し、retry / Debugger 経路の網羅は後続 task に残す。
- 残存課題: prompt、README、retry / Debugger 経路の追加 regression coverage は後続 task の範囲。

### Task 2

- 採用方針: retry / Debugger 経路は既存の `run_per_task_reviewer` 集約を維持し、guard 失敗時の operator 診断を強化する。
- 重要な判断: `pt_mark_diff_range_resolve_failed` に resolver 失敗時の HEAD、候補 marker、affected range、marker 後 commit の要約を埋め込み、post-marker 事故と marker 不在を同じ復旧入口で判別できるようにした。
- 重要な判断: `pt_build_diff_range_resolve_diagnostic` は resolver の stdout 契約を変えず、Issue コメント専用の markdown 診断として分離した。
- 重要な判断: `per_task_marker_review_range_test.sh` に診断出力の assertion を追加し、失敗時コメントの材料が欠けないことを検証した。
- 手動復旧追記: Reviewer reject 後 retry 相当の `round=2` と Debugger guidance 後 retry 相当の `round=3` を `run_per_task_reviewer` stub harness で検証し、どちらも marker 後 corrective commit の HEAD SHA が Reviewer prompt の `range_end` に渡ることを確認した。
- 検証結果: `bash local-watcher/test/per_task_marker_review_range_test.sh` は 16 PASS / 0 FAIL。`shellcheck local-watcher/test/per_task_marker_review_range_test.sh` と `shellcheck local-watcher/bin/idd-codex-issue-watcher.sh install.sh setup.sh .github/scripts/*.sh` は警告なし。
- 残存課題: prompt と README の marker / range contract 明文化は後続 task の範囲。

### Task 3

- 採用方針: watcher の per-task prompt builder と root/repo-template の Developer / Reviewer agent prompt に marker / range contract を同期して明文化した。
- 重要な判断: retry / Debugger 後は修正、検証、learning 追記の後に最新 marker を attempt 終端として置く契約を追加し、checkbox 済み retry では空 marker commit を許容した。
- 重要な判断: Reviewer には `range_start_sha..range_end_sha` を判定対象の正本とし、`range_end_sha` が marker 後 commit を含む補正後 SHA になり得ることと、range 外 commit を判断しないことを明示した。
- 重要な判断: shared rule は既存の agent prompt で契約を十分に表現できるため更新しない。
- 残存課題: README の説明更新と #14 形状の追加 regression coverage は後続 task の範囲。

### Task 4

- 採用方針: README の per-task loop / progress tracking 説明を、task marker 終端契約と include-or-fail range guard に合わせて更新した。
- 重要な判断: marker は実装・検証・learning 追記後の attempt 終端として説明し、retry / Debugger 後は最新 marker を末尾へ置く契約を明示した。
- 重要な判断: Reviewer range は prompt の `range_start_sha..range_end_sha` を正本とし、marker 後 commit は `HEAD` に補正して含めるか Reviewer 起動前に診断停止することを README に記録した。
- 重要な判断: 本 task は docs 同期のみで、新しい env var、label、exit code、外部サービス、runtime dependency は追加していないため migration note は追加しない。
- 残存課題: #14 形状の regression coverage と静的検証は後続 task の範囲。

### Task 5

- 採用方針: `per_task_marker_review_range_test.sh` の #14 形状 fixture を階層 task ID に寄せ、`docs(tasks): mark 1.1 as done` marker と marker 後 corrective commit の順序を `git log` assertion で明示した。
- 重要な判断: Reviewer reject 後 retry 相当の `round=2` と Debugger guidance 後 retry 相当の `round=3` は、`run_per_task_reviewer` stub harness で `task=1.1` の prompt と補正後 `range_end=HEAD` を検証する。
- 重要な判断: prompt-only assertion は発生せず、task 5 の対象 AC は shell fixture で検証した。
- 検証結果: `bash local-watcher/test/per_task_marker_review_range_test.sh` は 24 PASS / 0 FAIL。
- 残存課題: 静的検証と root / repo-template 同期確認は task 6 の範囲。

### Task 6

- 採用方針: task 6 は追加実装を行わず、指定 verify コマンドの成功結果と root / repo-template 同期確認を記録した。
- 重要な判断: `shellcheck local-watcher/bin/idd-codex-issue-watcher.sh install.sh setup.sh .github/scripts/*.sh` は警告なしで成功した。
- 重要な判断: `bash local-watcher/test/per_task_marker_review_range_test.sh` は 24 PASS / 0 FAIL で成功し、`diff -r .codex/agents repo-template/.codex/agents` と `diff -r .codex/rules repo-template/.codex/rules` は差分なしだった。
- 重要な判断: prompt-only assertion は発生せず、task 6 の確認は shell fixture と diff 検証で完結した。
- 残存課題: なし。

### Reviewer round 1 reject 対応

- 採用方針: Issue #23 の File Structure Plan 外に含まれていた差分を除外し、#23 の watcher、agent prompt、README、regression fixture、spec 成果物だけが `main..HEAD` に残る状態へ戻した。
- 重要な判断: `quota-aware.sh`、既存 test / fixture、`docs/specs/26--bug-per-task-reviewer-task-marker-tasks/` は Issue #23 の境界外だったため、削除や coverage 変更をこのブランチでは扱わない。
- 検証方針: 是正後に `git diff --name-status main..HEAD` で境界外パスが消えていることと、既存の shellcheck / per-task range regression / root-repo-template 同期 diff が通ることを確認する。
