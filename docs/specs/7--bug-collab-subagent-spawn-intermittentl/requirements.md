# Issue #7 要件定義

## 1. collab subagent spawn 失敗の degraded 記録

collab subagent spawn が `no thread with id` で失敗しても処理継続できる場合、idd-codex はその run を成功のみとして扱わず、運用者が後から degraded / fallback の発生を判別できる状態を残す。

### Acceptance Criteria

- When collab subagent spawn が `no thread with id` で失敗したとき, the idd-codex watcher shall run summary に structured degraded event を記録する。
- When structured degraded event が記録されるとき, the idd-codex watcher shall 対象 stage、agent role、failure reason、fallback 実施有無、final output の degraded 判定を運用者が判別できる情報として残す。
- When 同一 run 内で複数の collab subagent spawn 失敗が発生したとき, the idd-codex watcher shall 各失敗を run summary 上で個別に追跡可能な degraded event として残す。
- If collab subagent spawn 失敗後に fallback が成功したとき, the idd-codex watcher shall run 全体を通常成功のみとして要約せず、fallback 済みの degraded run として要約する。

## 2. fallback 経路の明示ログ

fallback が発生した場合、Issue log だけを見た運用者が、どの agent role が fallback し、最終成果物が degraded 扱いかを判断できる。

### Acceptance Criteria

- When collab subagent spawn 失敗により fallback 経路へ切り替わるとき, the idd-codex watcher shall fallback 開始を明示するログを出力する。
- When fallback 開始ログを出力するとき, the idd-codex watcher shall 対象 stage と agent role をログに含める。
- When fallback 経路が完了したとき, the idd-codex watcher shall fallback の結果が成功、失敗、または degraded success のいずれであるかをログに残す。
- If fallback 経路が利用できない、または fallback も失敗したとき, the idd-codex watcher shall silent proceed せず、通常の失敗処理として運用者に見える状態を残す。

## 3. bounded retry と再発抑止

同じ `no thread with id` 失敗が run 内で繰り返されても、idd-codex は無制限に spawn を試みず、fallback / warning / failure のいずれかに収束させる。

### Acceptance Criteria

- When collab subagent spawn が `no thread with id` で失敗したとき, the idd-codex watcher shall 同一 stage と agent role の spawn 試行を初回失敗後に最大 1 回までの retry に制限する。
- If bounded retry 後も collab subagent spawn が失敗するとき, the idd-codex watcher shall fallback 経路へ切り替えるか、fallback 不能な場合は失敗として扱う。
- When 同一 run 内で `no thread with id` 失敗が複数回発生したとき, the idd-codex watcher shall run summary に repeated failure warning を残す。
- While repeated `no thread with id` failure が発生している間, the idd-codex watcher shall 失敗を warning なしで成功ログへ埋没させない。

## 4. 対象 stage / agent role の範囲

本 Issue は Stage A を主対象としつつ、追加再発ログで確認された Reviewer、Stage C、Project Manager を含む collab subagent spawn 利用箇所の operator-observable な fallback / degraded 診断を対象にする。

### Acceptance Criteria

- When Stage A の PM subagent spawn が `no thread with id` で失敗したとき, the idd-codex watcher shall degraded event、明示 fallback log、bounded retry の要件を適用する。
- When Stage A の Developer subagent spawn が `no thread with id` で失敗したとき, the idd-codex watcher shall degraded event、明示 fallback log、bounded retry の要件を適用する。
- When Reviewer subagent spawn が `no thread with id` で失敗したとき, the idd-codex watcher shall degraded event、明示 fallback log、bounded retry の要件を適用する。
- When Stage C または Project Manager subagent spawn が `no thread with id` で失敗したとき, the idd-codex watcher shall degraded event、明示 fallback log、bounded retry の要件を適用する。

## 5. upstream 起因時の idd-codex 側診断

原因が Codex CLI / collab router 側にある場合でも、idd-codex は upstream 修正待ちだけにせず、運用者が idd-codex run の影響を判断できる診断を提供する。

### Acceptance Criteria

- If `no thread with id` が upstream Codex CLI または tool 側の問題であると判定される場合, the idd-codex watcher shall idd-codex 側の run summary とログに actionable diagnostics を残す。
- When actionable diagnostics を残すとき, the idd-codex watcher shall upstream 起因の可能性、fallback の有無、運用品質への影響を運用者が判断できる情報として残す。
- The idd-codex watcher shall Codex CLI upstream 実装変更を前提にせず、idd-codex 側の診断と fallback 可視化で本 Issue の受入基準を満たす。

## 6. 後方互換性と既存運用維持

fallback を削除せず、既存の cron / launchd 運用、ラベル遷移、手動復旧の契約を破らずに、可観測性と retry 境界だけを改善する。

### Acceptance Criteria

- The idd-codex watcher shall collab subagent spawn 失敗時の既存 fallback 継続挙動を削除しない。
- The idd-codex watcher shall 既存 env var 名、既存ラベル名、既存 exit code の意味、既存ログ出力先の後方互換性を維持する。
- When 本 Issue の挙動変更が operator-observable な run summary またはログ仕様に影響するとき, the idd-codex watcher shall README の該当説明で運用者が degraded / fallback 診断を理解できる状態にする。

## Scope

- 対象: `local-watcher/` 配下の collab subagent spawn 失敗時の run summary、fallback log、bounded retry、degraded warning。
- 対象: Issue 本文と追加コメントで確認された Stage A PM / Developer、Reviewer、Stage C、Project Manager の subagent 起動失敗。
- 対象: operator-observable な挙動変更を説明する `README.md` の必要箇所。
- 対象外: Codex CLI upstream 実装変更、Codex collab router の内部修正、agent prompt redesign、fallback 挙動の削除、新しい外部サービス呼び出しの追加。

## Decisions

- 人間コメント `B` により、upstream 追跡のみではなく、idd-codex 側で structured degraded event、明示的 fallback ログ、bounded retry を実装する方針を採用する。
- 追加再発ログにより、Stage A の PM / Developer だけでなく Reviewer、Stage C、Project Manager の subagent 起動失敗も受入範囲に含める。

## 確認事項

- bounded retry の上限は、要件上は「同一 stage と agent role の spawn 試行について初回失敗後に最大 1 回まで」と定義する。これを変更したい場合は Architect / Developer 着手前に人間判断が必要。

## PM 自己レビュー

- Mechanical Checks: numeric ID 見出し、各要件の EARS 形式 AC、実装詳細の過剰混入なしを確認。
- 判断レビュー: Issue 本文の受入基準、人間回答 `B`、追加再発ログ、スコープ外、後方互換性、operator-observable な診断を網羅していることを確認。
