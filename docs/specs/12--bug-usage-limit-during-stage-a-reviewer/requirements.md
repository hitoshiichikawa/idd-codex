# Issue #12 要件定義

## 1. 通常 impl pipeline の usage-limit fatal 退避

通常 impl pipeline は、reset 時刻を含む usage-limit / quota 系 fatal error を通常失敗ではなく quota wait として扱う。

### Acceptance Criteria

- When Codex CLI が Stage A 中に reset 時刻を含む usage-limit fatal message を返して非 0 終了したとき, the watcher shall 対象 Issue に `codex-needs-quota-wait` を付与し、`codex-failed` を付与しない。
- When Codex CLI が Reviewer stage 中に reset 時刻を含む usage-limit fatal message を返して非 0 終了したとき, the watcher shall 対象 Issue または PR を `codex-needs-quota-wait` の待機状態へ遷移させ、`codex-failed` を付与しない。
- When Codex CLI が Debugger 後 Reviewer round で reset 時刻を含む usage-limit fatal message を返して非 0 終了したとき, the watcher shall Reviewer stage と同じ quota wait 分類を適用する。
- When Codex CLI が Stage C、per-task loop、または PR Reviewer の Codex 呼び出し中に reset 時刻を含む usage-limit fatal message を返して非 0 終了したとき, the watcher shall 通常失敗ではなく quota wait として分類する。

## 2. Triage stage の usage-limit fatal 退避

Triage stage は、通常 impl pipeline と同じ usage-limit / quota wait 契約に従う。

### Acceptance Criteria

- When Codex CLI が Triage stage 中に reset 時刻を含む usage-limit fatal message を返して非 0 終了したとき, the watcher shall 対象 Issue に `codex-needs-quota-wait` を付与し、`codex-failed` を付与しない。
- When Triage stage の usage-limit fatal message から reset 時刻を抽出できるとき, the watcher shall 対象 Issue を reset 時刻後の resume 対象として扱う。
- When Triage stage が quota wait に退避するとき, the watcher shall Triage の失敗を通常失敗として扱わず、運用者が quota 待機状態を判別できる状態を残す。

## 3. reset 時刻の保存と resume

quota wait に退避した Issue / PR は、既存の quota resume 運用に乗り、reset 時刻後に破壊的な復旧を要求しない。

### Acceptance Criteria

- When usage-limit fatal message から reset 時刻を抽出できるとき, the watcher shall reset 時刻を既存の quota resume 管理に保存する。
- When reset 時刻と grace period が経過したとき, the watcher shall 対象 Issue または PR を正しい checkpoint から自動 resume 対象として扱う。
- When quota wait から resume するとき, the watcher shall 既存 branch commit、spec 成果物、または PR を破壊しない復帰経路を維持する。

## 4. reset 時刻なし usage-limit 風 fatal の扱い

reset 時刻を抽出できない usage-limit 風 fatal は、人間コメントの決定事項に従い、待機扱いにせず従来どおり失敗扱いにする。

### Acceptance Criteria

- If Codex CLI が usage-limit 風 fatal message を返したが reset 時刻を抽出できないとき, the watcher shall `codex-needs-quota-wait` を付与せず、`codex-failed` に遷移させる。
- If reset 時刻なし usage-limit 風 fatal により `codex-failed` へ遷移するとき, the watcher shall 手動復旧が必要な失敗として運用者が判別できる状態を残す。

## 5. non-quota fatal の既存挙動維持

usage-limit / quota と判定できない Codex CLI の異常終了は、既存の通常失敗として扱う。

### Acceptance Criteria

- When Codex CLI が non-quota crash または reset 時刻を含まない非 usage-limit fatal error で非 0 終了したとき, the watcher shall 既存の `codex-failed` 挙動を維持する。
- When fatal error を quota wait として分類しないとき, the watcher shall 既存の失敗ログとラベル遷移の契約を維持する。

## 6. 回帰検証

usage-limit fatal の分類と resume 対象化が、観測済みの Stage A / Reviewer / Triage 再現と既存 529 overloaded の双方で検証される。

### Acceptance Criteria

- When regression test が `You've hit your usage limit ... try again at ...` message を入力するとき, the test suite shall reset 時刻ありの usage-limit fatal が quota wait として分類されることを検証する。
- When regression test が既存の 529 overloaded message を入力するとき, the test suite shall reset 時刻なしの 529 overloaded が usage-limit quota wait に誤分類されず、既存の 529 overloaded 可視化として検出されることを検証する。
- When regression test が Stage A の usage-limit fatal を再現するとき, the test suite shall `codex-needs-quota-wait` が付与され、`codex-failed` が付与されないことを検証する。
- When regression test が Reviewer stage または Debugger 後 Reviewer round の usage-limit fatal を再現するとき, the test suite shall `codex-needs-quota-wait` が付与され、`codex-failed` が付与されないことを検証する。
- When regression test が Triage stage の usage-limit fatal を再現するとき, the test suite shall `codex-needs-quota-wait` が付与され、`codex-failed` が付与されないことを検証する。
- When regression test が reset 時刻なし usage-limit 風 fatal を再現するとき, the test suite shall Option B の決定どおり `codex-failed` に遷移することを検証する。

## Scope

- 対象: `local-watcher/` 配下の通常 impl pipeline、Triage stage、Reviewer / Debugger 後 Reviewer、Stage C、per-task loop、PR Reviewer、quota wait / resume に関わる watcher 挙動。
- 対象: operator-observable な挙動変更を説明する `README.md` の必要箇所。
- 対象外: Codex CLI 本体の usage limit 表示変更、account quota / billing system の変更、PR Iteration 専用処理だけの修正。

## Decisions

- 人間コメント「Bで」により、reset 時刻を抽出できない usage-limit 風 fatal は Option B として `codex-failed` に倒す。
- 追加コメントの Triage stage 再現を受入範囲に含める。

## Related

- Related: #4
- Related: #7
