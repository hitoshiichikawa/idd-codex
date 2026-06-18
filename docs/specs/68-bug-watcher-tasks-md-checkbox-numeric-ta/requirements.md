# Issue #68 要件定義

## 背景

consumer repo の `tasks.md` に含まれる通常の checklist 行 `- [ ] 1 PR ...` が、watcher の per-task task marker として誤検出され、実在しない task `1` の未完了として `per-task-implementer-no-progress` の false fail が発生した。

本 Issue は、watcher-compatible numeric checkbox task の判定契約を明確にし、抽出と完了確認の判定を一致させ、heading-based な `tasks.md` が task marker なしで流入した場合に silent success や prose checkbox 誤選択へ進まないようにする bug fix である。

Issue コメントでは、Triage edit_paths と処理開始通知以外の追加決定事項はなかった。

## スコープ境界

**対象**

- per-task が認識する numeric checkbox task marker の判定契約。
- pending task 抽出と task 完了確認の同一判定契約への整合。
- watcher-compatible numeric checkbox task が 0 件の `tasks.md` に対する impl-resume / per-task 開始前の actionable failure。
- tasks 生成物または検証における watcher-compatible parent checkbox task の必須化。
- 通常 checkbox 誤検出と marker なし `tasks.md` に対する regression coverage。

**対象外**

- per-task loop 全体の実行モデル変更。
- task ID の命名体系を numeric 階層 ID 以外へ拡張すること。
- `tasks.md` の見出しベース運用を watcher-compatible task marker として新規サポートすること。
- 既存 env var 名、ラベル名、cron / launchd 起動契約、exit code 意味の変更。
- 新しい外部サービス呼び出しや runtime dependency の追加。

## 要件

### 1

watcher-compatible numeric checkbox task marker は、通常の checklist 文と誤認されない明確な形式だけを task として扱える。

#### Acceptance Criteria

1.1 When `tasks.md` contains an unchecked parent task line in the form `- [ ] N. <title>`, the watcher shall classify that line as numeric task ID `N`.

1.2 When `tasks.md` contains a checked parent task line in the form `- [x] N. <title>`, the watcher shall classify that line as completed numeric task ID `N`.

1.3 When `tasks.md` contains an unchecked child task line in the form `- [ ] N.M[.K...] <title>`, the watcher shall classify that line as numeric task ID `N.M[.K...]`.

1.4 When `tasks.md` contains a checked child task line in the form `- [x] N.M[.K...] <title>`, the watcher shall classify that line as completed numeric task ID `N.M[.K...]`.

1.5 When `tasks.md` contains a normal checklist line that starts with an integer without the parent-task dot, such as `- [ ] 1 PR で大きすぎる場合は...`, the watcher shall not classify that line as numeric task ID `1`.

1.6 When `tasks.md` contains a checkbox line whose leading token is not a watcher-compatible numeric task marker, the watcher shall leave that line outside per-task task selection and completion checks.

### 2

pending task 抽出と task 完了確認は、同一の marker 契約で同じ task ID を解釈できる。

#### Acceptance Criteria

2.1 When pending task extraction reads `- [ ] 1. Baseline audit`, the watcher shall output pending task ID `1`.

2.2 When pending task extraction reads `- [ ] 1.1 子タスク`, the watcher shall output pending task ID `1.1`.

2.3 When pending task extraction reads `- [ ] 1 PR で大きすぎる場合は...`, the watcher shall not output task ID `1` for that line.

2.4 When task completion check evaluates task ID `1`, the watcher shall match `1` only against watcher-compatible parent task marker lines for task ID `1`.

2.5 When task completion check evaluates task ID `1.1`, the watcher shall match `1.1` only against watcher-compatible child task marker lines for task ID `1.1`.

2.6 When task completion check evaluates task ID `1` and `tasks.md` only contains `- [ ] 1 PR ...` for that leading number, the watcher shall not treat that prose checkbox as task `1`.

### 3

watcher-compatible numeric checkbox task が存在しない `tasks.md` は、per-task 開始前に運用者が修正可能な失敗として扱われる。

#### Acceptance Criteria

3.1 When impl-resume sees a `tasks.md` with numeric headings such as `## 1.` but zero watcher-compatible numeric checkbox tasks, the watcher shall fail before selecting a per-task task.

3.2 When per-task startup sees a `tasks.md` with zero watcher-compatible numeric checkbox tasks, the watcher shall not treat the Issue as complete solely because no pending task was extracted.

3.3 When per-task startup sees a `tasks.md` with zero watcher-compatible numeric checkbox tasks, the watcher shall not select a normal prose checkbox as a fallback task.

3.4 If the watcher fails because `tasks.md` has zero watcher-compatible numeric checkbox tasks, the watcher shall provide an actionable diagnostic that identifies the missing marker contract and the affected `tasks.md`.

3.5 If the watcher fails because `tasks.md` has zero watcher-compatible numeric checkbox tasks, the watcher shall leave enough operator-visible context to distinguish malformed task generation from normal task completion.

### 4

tasks 生成物または検証は、watcher-compatible parent checkbox task が存在しない `tasks.md` を早期に検出できる。

#### Acceptance Criteria

4.1 When task artifact validation evaluates a `tasks.md` intended for per-task execution, the validation shall require at least one watcher-compatible parent checkbox task line.

4.2 When task artifact validation sees numeric headings but no watcher-compatible parent checkbox task lines, the validation shall report the artifact as incompatible with per-task execution.

4.3 When task generation guidance describes parent tasks for per-task execution, the guidance shall require watcher-compatible parent checkbox task lines in the form `- [ ] N. <title>`.

4.4 When task generation guidance describes child tasks for per-task execution, the guidance shall require watcher-compatible child checkbox task lines in the form `- [ ] N.M[.K...] <title>`.

4.5 When task generation guidance or validation changes shared agent or rule artifacts, the repository shall keep root `.codex/` and `repo-template/.codex/` counterparts byte-identical for the changed artifact type.

### 5

本変更は既存 watcher 契約を壊さず、再発防止を検証可能にする。

#### Acceptance Criteria

5.1 When this bug fix is applied, the watcher shall preserve existing env var names, label names, cron / launchd invocation contracts, and exit code meanings.

5.2 When regression verification covers a normal checklist line `- [ ] 1 PR で大きすぎる場合は...`, the verification shall confirm that pending task extraction does not output `1`.

5.3 When regression verification covers parent task marker `- [ ] 1. Baseline audit`, the verification shall confirm that pending task extraction outputs `1`.

5.4 When regression verification covers child task marker `- [ ] 1.1 子タスク`, the verification shall confirm that pending task extraction outputs `1.1`.

5.5 When regression verification covers completion checking for task ID `1`, the verification shall confirm that `- [ ] 1 PR ...` is not treated as task `1`.

5.6 When regression verification covers heading-based `tasks.md` with zero watcher-compatible numeric checkbox tasks, the verification shall confirm that impl-resume or per-task startup fails with an actionable diagnostic.

5.7 When implementation changes watcher shell scripts, the verification shall include shell-level static checks for changed shell files.

5.8 When implementation changes root `.codex/agents/` or `.codex/rules/`, the verification shall include byte-identical comparison with the corresponding `repo-template/.codex/` path.

## 受入基準対応

- Issue AC 1: `- [ ] 1 PR ...` を task `1` として抽出しないことは 1.5、2.3、5.2 で扱う。
- Issue AC 2: `- [ ] 1. Baseline audit` を task `1` として抽出することは 1.1、2.1、5.3 で扱う。
- Issue AC 3: `- [ ] 1.1 子タスク` を task `1.1` として抽出することは 1.3、2.2、5.4 で扱う。
- Issue AC 4: task ID `1` の完了確認で `- [ ] 1 PR ...` を task `1` と扱わないことは 2.4、2.6、5.5 で扱う。
- Issue AC 5: heading-based かつ watcher-compatible numeric checkbox task が 0 件の `tasks.md` を actionable failure にすることは 3.1、3.2、3.3、3.4、3.5、5.6 で扱う。

## 確認事項

- なし。Issue 本文の期待修正と受入条件だけで PM 要件を確定できる。

## PM 自己レビュー

- Mechanical Checks: requirement 見出しが numeric ID であること、各 requirement に EARS 形式 AC が 1 件以上あること、AC が `When` / `If` / `While` / `Where` / `The ... shall` で始まることを確認した。
- スコープレビュー: 通常 checkbox 誤検出、親 task / 子 task の marker 契約、抽出と完了確認の整合、marker なし `tasks.md` の actionable failure、生成物検証、後方互換、回帰検証を網羅した。
- 実装方針レビュー: 正規表現や関数分割などの実装方式は指定せず、observable な判定契約と検証条件に限定した。
