# Issue #11 要件定義

## 1. スコープ

1.1 対象範囲

`local-watcher/` 配下、特に `local-watcher/bin/idd-codex-issue-watcher.sh` における、parallel dispatcher の slot 割当と、関連する machine-readable な戻り値出力の扱いを対象とする。

1.2 対象事象

slot 割当処理中に、別 worker の completion log などの human-readable log が stdout の戻り値へ混入し、slot id、worktree path、log path、Issue コメント上の slot 表示が壊れる問題を対象とする。

1.3 追加対象

既存コメントで報告された promote-pipeline の issue 番号表示における stdout/log 混入も、同じ stdout discipline の問題として対象に含める。

## 2. 非スコープ

2.1 dispatcher 全体の大規模 rewrite は行わない。

2.2 Gitflow dependency resolver の仕様変更は行わない。

2.3 collab subagent spawn failure の改善は行わない。

2.4 slot 管理モデル、ラベル遷移、cron 実行契約、既存 env var 名の意味変更は行わない。

## 3. 受入基準

3.1 slot id の完全性

3.1.1 When parallel dispatcher が worker に割り当てる slot id を取得する, the system shall return a clean slot id that is either an integer or an explicitly defined valid token.

3.1.2 When another worker completes while slot allocation is in progress, the system shall not include that worker's completion log in the slot id value.

3.1.3 If a slot id contains human-readable log text, newline contamination, timestamp text, or any value outside the valid slot id domain, the system shall fail closed before dispatching the worker.

3.1.4 When slot id validation fails, the system shall not create or use a corrupted worktree path, log path, or Issue comment slot label derived from that invalid slot id.

3.2 stdout discipline

3.2.1 When a function or pipeline returns a machine-readable value, the system shall emit only that machine-readable value to stdout.

3.2.2 When user-facing logs are emitted during dispatcher or processor execution, the system shall keep those logs out of stdout used as a return-value channel.

3.2.3 When promote-pipeline or related processor logic returns an issue number, the system shall not mix human-readable logs into that issue number value.

3.3 concurrent completion regression

3.3.1 While a short-lived worker completes during another worker's slot allocation, the system shall still assign a clean slot id to the next worker.

3.3.2 When concurrent completion logging occurs around slot allocation, the system shall preserve valid dispatcher behavior without arithmetic evaluation errors caused by contaminated slot id values.

3.4 observable output and comments

3.4.1 When dispatcher writes Issue comments or logs that reference a slot, the system shall not record corrupted slot names such as values containing embedded completion logs or newlines.

3.4.2 If dispatch is blocked because a slot id is invalid, the system shall make the failure observable through an error path rather than continuing with corrupted derived state.

3.5 regression coverage

3.5.1 When contaminated stdout is simulated for a machine-readable return path, regression coverage shall verify that contamination is rejected or isolated before the value is consumed.

3.5.2 When concurrent completion logging is simulated around slot allocation, regression coverage shall verify that the allocated slot id remains clean.

3.5.3 Where dispatcher-adjacent processors return machine-readable values such as issue numbers, regression coverage shall verify the same stdout discipline outside the dispatcher-specific slot path.

## 4. 確認事項

4.1 「定義済み token」として許容する slot id の具体的な一覧は、既存実装上は確認できなかったため、本修正では既存の slot 管理モデルに合わせて正の整数のみを有効な slot id として扱う。

4.2 promote-pipeline の issue 番号混入は、本 Issue の同一修正範囲に含める。
