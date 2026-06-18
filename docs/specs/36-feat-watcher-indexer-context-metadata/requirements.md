# Requirements Document

## Introduction

#34 で導入された deterministic な `context-map.md` は、per-task Implementer / Reviewer が fresh context で広域探索を繰り返す回数を減らすための補助 metadata として機能している。
一方で、`tasks.md` の `_Boundary:_` や diff だけでは対象領域の当たりが不足または曖昧な Issue では、実装前に軽量な Indexer サブエージェントが短い context metadata を補完する余地がある。
本 Issue では、既存の deterministic map を第一手段として維持しつつ、必要な場合だけ Indexer を起動し、後続 agent が最初に参照できる `context-map.md` を生成する。
Indexer は実装・レビュー・commit・push を行わず、候補ファイル、候補テスト、候補 docs、anchors、探索制約などの短い metadata を残す補助役に限定する。

## Requirements

### Requirement 1: opt-in と既存挙動の維持

**Objective:** As an 運用者, I want Indexer context metadata generation to be opt-in, so that 既存 watcher の既定挙動と token 消費を維持できる

#### Acceptance Criteria

1. When Indexer 用 opt-in gate が未設定または `true` 以外の値であるとき, the watcher shall Indexer サブエージェントを起動しない。
2. When Indexer 用 opt-in gate が未設定または `true` 以外の値であるとき, the watcher shall deterministic な `context-map.md` 生成と prompt 注入の既存契約を変更しない。
3. Where Indexer 用 opt-in gate が含まれるとき, the watcher shall `=true` の厳密一致の場合だけ Indexer 起動を許可する。
4. When Indexer context metadata generation が追加されるとき, the watcher shall 既存 env var 名、ラベル名、cron / launchd 起動契約、exit code 意味を変更しない。

### Requirement 2: deterministic map 不足時の条件付き Indexer 起動

**Objective:** As a per-task agent 利用者, I want Indexer to run only when deterministic context is insufficient or ambiguous, so that 追加 token 消費を必要なケースに限定できる

#### Acceptance Criteria

1. When deterministic context map が対象 task の候補ファイル、候補テスト、候補 docs、anchors、探索制約を十分に示せるとき, the watcher shall Indexer サブエージェントを起動しない。
2. When deterministic context map が対象 task の候補ファイル、候補テスト、候補 docs、anchors、探索制約を不足または曖昧な状態でしか示せないとき, the watcher shall Indexer サブエージェントを最大 1 回だけ起動する。
3. When Indexer サブエージェントが対象 task のために起動されるとき, the watcher shall per-task Implementer が開始する前に Indexer の context metadata を利用可能にする。
4. While 同一 task の Indexer 実行が完了済みであるとき, the watcher shall 同一 task の同一処理局面で Indexer を繰り返し起動しない。

### Requirement 3: context-map.md への保存

**Objective:** As a Developer または Reviewer agent, I want Indexer metadata to be saved in `context-map.md`, so that 既存の context-map 参照導線と人間可読性を維持できる

#### Acceptance Criteria

1. When Indexer が context metadata を生成するとき, the watcher shall 保存先を `docs/specs/<N>-<slug>/context-map.md` とする。
2. When `context-map.md` が Indexer metadata を含むとき, the watcher shall 後続 agent が deterministic 由来情報と Indexer 由来情報を区別できる形で保存する。
3. When `context-map.md` が生成または更新されるとき, the watcher shall 候補ファイル、候補テスト、候補 docs、anchors、探索制約を短く参照できる状態にする。
4. When `context-map.md` が後続 prompt に注入されるとき, the watcher shall prompt に保存済み metadata の短い slice だけを含める。
5. The watcher shall `context-map.json` を本 Issue の保存フォーマットとして要求しない。

### Requirement 4: 後続 agent の参照順序

**Objective:** As a Developer または Reviewer agent, I want saved context metadata to be presented before broad repository exploration, so that 初動の探索 read を減らせる

#### Acceptance Criteria

1. When Developer prompt が Indexer metadata を含む `context-map.md` を受け取るとき, the watcher shall Developer に候補ファイル、anchors、候補テストを repo-wide 探索より先に参照するよう示す。
2. When Reviewer prompt が Indexer metadata を含む `context-map.md` を受け取るとき, the watcher shall Reviewer に対象 task の diff range、候補ファイル、anchors、候補テストを広域探索より先に参照するよう示す。
3. While `context-map.md` が補助情報として提示されているとき, the watcher shall 後続 agent に最終判断は `tasks.md`、要件、実際の diff で検証する必要があることを示す。
4. When context metadata が不足しているとき, the watcher shall 後続 agent が必要に応じて targeted search を追加できる余地を残す。

### Requirement 5: Indexer の権限境界

**Objective:** As an 運用者, I want Indexer to be read-only, so that context metadata generation が実装作業や repository 状態を変更しない

#### Acceptance Criteria

1. When Indexer サブエージェントが起動されるとき, the watcher shall Indexer に実装、レビュー、commit、push、PR 作成を行わないよう明示する。
2. While Indexer サブエージェントが実行されているとき, the watcher shall Indexer の成果物を context metadata に限定する。
3. If Indexer サブエージェントが repository 変更を必要とする判断を出すとき, the watcher shall その判断を後続 agent への補助 metadata としてのみ扱う。
4. The Indexer context metadata shall `_Boundary:_` や `tasks.md` の内容を自動変更する根拠にならない。

### Requirement 6: Indexer 失敗時の deterministic fallback

**Objective:** As an 運用者, I want Indexer failure to fall back to deterministic context map, so that 補助機能の失敗で Issue 処理全体が停止しない

#### Acceptance Criteria

1. If Indexer サブエージェントが失敗するとき, the watcher shall deterministic な `context-map.md` へフォールバックして処理を継続する。
2. If Indexer サブエージェントが失敗するとき, the watcher shall Indexer 失敗だけを理由に Issue を即時 `codex-failed` にしない。
3. When Indexer fallback が発生するとき, the watcher shall 運用者が fallback 発生と理由を追跡できる形で記録する。
4. When fallback 後に後続 prompt が生成されるとき, the watcher shall deterministic map 由来の metadata を後続 agent に提示する。

### Requirement 7: ドキュメントと運用条件

**Objective:** As an 運用者, I want documentation to describe Indexer tradeoffs and operating conditions, so that opt-in 判断と運用監視ができる

#### Acceptance Criteria

1. When Indexer context metadata generation が利用可能になるとき, the documentation shall opt-in gate、起動条件、保存フォーマット、fallback 方針を説明する。
2. When documentation describes Indexer behavior, the documentation shall deterministic map が第一手段であり、不足または曖昧な場合だけ Indexer が補助することを説明する。
3. When documentation describes Indexer tradeoffs, the documentation shall token 消費増加の可能性と探索 read 削減の狙いを説明する。
4. When documentation describes Indexer boundaries, the documentation shall Indexer が実装、レビュー、commit、push、PR 作成を行わないことを説明する。

## Non-Functional Requirements

### NFR 1: 後方互換性

1. When Indexer context metadata generation が無効であるとき, the watcher shall 既存の per-task Implementer / Reviewer 起動順、`context-map.md` の deterministic 生成、Stage A 以降の挙動を変更しない。
2. When Indexer context metadata generation が有効であるとき, the watcher shall 既存の `CONTEXT_MAP_ENABLED` の意味を破壊しない。
3. The watcher shall 新しい外部サービス呼び出しを opt-in gate なしで有効化しない。

### NFR 2: 可観測性

1. When Indexer が起動されるとき, the watcher shall Issue 番号、対象 task、起動理由、結果を運用者が追跡できる形で記録する。
2. When Indexer が起動されないとき, the watcher shall deterministic map が十分だったため skip したことを運用者が追跡できる形で記録する。
3. When Indexer fallback が発生するとき, the watcher shall fallback 後も後続処理が継続したことを運用者が追跡できる形で記録する。

### NFR 3: 検証可能性

1. When regression verification covers opt-in disabled behavior, the verification shall Indexer が起動されず既存挙動が維持されることを確認する。
2. When regression verification covers sufficient deterministic context, the verification shall Indexer が起動されないことを確認する。
3. When regression verification covers insufficient or ambiguous deterministic context, the verification shall Indexer が最大 1 回だけ起動され `context-map.md` に metadata が保存されることを確認する。
4. When regression verification covers Indexer failure, the verification shall deterministic map への fallback と Issue 処理継続を確認する。
5. When regression verification covers prompt injection, the verification shall 後続 prompt に `context-map.md` の短い slice が含まれることを確認する。

## Out of Scope

- reasoning effort / model default の変更。
- 並列度 default の変更。
- repo-wide な恒久 index の完全自動メンテナンス。
- Indexer の判断だけで `_Boundary:_`、`tasks.md`、`requirements.md`、`design.md` を変更すること。
- `context-map.json` を保存フォーマットとして導入すること。
- Indexer サブエージェントに実装、レビュー、commit、push、PR 作成を許可すること。
- deterministic context map を廃止すること。

## Open Questions

- なし。

## Issue コメント反映

- Owner コメントの `1.A` により、Indexer 失敗時は deterministic map にフォールバックして処理を継続する方針として Requirement 6 に反映した。
- Owner コメントの `2.A` により、保存フォーマットは `context-map.md` として Requirement 3 に反映した。
- Owner コメントの `3.B` により、Indexer 起動条件は deterministic map が不足または曖昧な場合のみとして Requirement 2 に反映した。
- Triage edit_paths の自動コメントにより、編集見込み top-level path は `docs/`、`local-watcher/`、`README.md` と認識した。

## PM 自己レビュー

- Mechanical Checks: numeric ID 見出し、各 Requirement の EARS 形式 AC、Out of Scope、Open Questions の存在を確認した。
- 判断レビュー: Issue 本文、Owner 決定事項 `1.A 2.A 3.B`、既存 deterministic `context-map.md` 仕様、fallback、保存形式、条件付き起動、権限境界、ドキュメント、検証観点を網羅していることを確認した。
- 実装方針レビュー: 要件は operator-observable / agent-observable な挙動と境界に限定し、具体的な関数分割や内部実装手順は design に委ねていることを確認した。
