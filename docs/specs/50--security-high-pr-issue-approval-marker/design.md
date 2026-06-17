# Design Document

## Overview

Issue #50 の残置スコープである 4-C promote-pipeline の `edit-paths-json` marker 注入を塞ぐ。現状の `po_load_edit_paths` は Issue 全コメント本文から marker を抽出し、最後に出現した marker を採用するため、未信頼著者のコメントが Path Overlap Checker の入力を上書きできる。

**Purpose**: この機能は未信頼 Issue コメントによる path overlap 判定の誤誘導を防ぎ、watcher operator に安全な Phase E 運用を提供する。  
**Users**: watcher operator / repository maintainer が `PATH_OVERLAP_CHECK=true` の並列 dispatch workflow で利用する。  
**Impact**: 現在の「全コメント本文から marker 抽出」状態を、「信頼済み著者コメントのみから marker 抽出」へ変更する。PR #53 で修正済みの 4-A / 4-B は再実装せず、回帰テストで維持を確認する。

### Goals

- `po_load_edit_paths` が `edit-paths-json` marker を信頼済み著者コメントからのみ採用する
- 未信頼 marker の最後勝ち上書きを防ぐ
- 4-A Merge Queue / 4-B PR Iteration の既存 author 検証を壊していないことを regression で確認する
- `PATH_OVERLAP_CHECK` 未有効時、既存 env var、ラベル、exit code、cron / launchd 前提を変更しない

### Non-Goals

- 4-A Merge Queue approval marker 著者検証の再実装
- 4-B PR Iteration 一般コメント著者検証の再実装
- GitHub branch protection / required review / repository permission 設定の変更
- `PATH_OVERLAP_CHECK` のデフォルト有効化
- 新規 runtime / 新規外部サービス呼び出しの追加
- 未信頼コメント本文の AI moderation や内容分類

## Architecture

### Existing Architecture Analysis

- `local-watcher/bin/idd-codex-modules/promote-pipeline.sh` は Promote Pipeline と Path Overlap Checker の `po_*` 関数を同居させる既存境界を持つ。
- `po_load_edit_paths` は 1 Issue につき `gh issue view --json comments` を 1 回呼び、sticky comment の hidden marker から edit paths JSON を読み出す。
- 4-A は `merge-queue.sh` の `mq_resolve_marker_approval_signal` で `MERGE_QUEUE_TRUSTED_ASSOCIATIONS` を使い `author_association` を検証済み。
- 4-B は `pr-iteration.sh` の `pi_general_filter_untrusted_authors` / `pi_collect_general_comments` で `PR_ITERATION_TRUSTED_ASSOCIATIONS` を使い `author_association` を検証済み。
- 4-C の残置 debt は、`po_load_edit_paths` が `.comments[].body` 全体を `sed` + `tail -1` へ流している点。未信頼入力を `sed` に渡す構造も避ける。

### Architecture Pattern & Boundary Map

**Architecture Integration**:

- 採用パターン: 既存モジュール内の局所修正 + shell-level regression test
- ドメイン／機能境界: Path Overlap の marker loading は `promote-pipeline.sh` に閉じる。Merge Queue / PR Iteration は既存関数を変更せず regression 対象に留める。
- 既存パターンの維持:
  - `po_load_edit_paths` は API failure / marker 不在 / JSON 不正時に `[]` を返す fail-safe を維持
  - `PATH_OVERLAP_CHECK=true` 厳密一致 gate の既存挙動を維持
  - 1 candidate あたり comments API 1 回の前提を維持
- 新規コンポーネントの根拠:
  - 大きな共通 helper は追加しない。4-A / 4-B は個別 env 名と個別関数で既に安定しているため、横断リファクタは本 Issue のリスクに見合わない。

### Technology Stack

| Layer | Choice / Version | Role in Feature | Notes |
|-------|------------------|-----------------|-------|
| Frontend / CLI | bash 4+ | watcher module / shell tests | 既存スタック |
| Backend / Services | GitHub CLI `gh` | Issue comments の取得 | 既存呼び出しを維持 |
| Data / Storage | GitHub Issue comments | `edit-paths-json` hidden marker 永続化 | schema 変更なし |
| Messaging / Events | なし | 対象外 | 新規イベントなし |
| Infrastructure / Runtime | jq | author filter / marker extraction / JSON validation | sed 抽出を jq 内へ移す |

## File Structure Plan

### Directory Structure

```text
local-watcher/
├── bin/
│   └── idd-codex-modules/
│       ├── promote-pipeline.sh      # 4-C: po_load_edit_paths の信頼済み著者 filter + jq marker 抽出
│       ├── merge-queue.sh           # 4-A: 変更せず regression 対象
│       └── pr-iteration.sh          # 4-B: 変更せず regression 対象
└── test/
    ├── po_load_edit_paths_trusted_authors_test.sh       # 新規: 4-C trusted/untrusted marker 検証
    ├── merge_queue_approval_signal_test.sh              # 既存: 4-A regression として実行
    └── pi_general_filter_untrusted_authors_test.sh      # 既存: 4-B regression として実行

README.md                         # #50 note または Phase E security 記述へ 4-C を追記
docs/specs/50--security-high-pr-issue-approval-marker/
├── requirements.md
├── design.md
└── tasks.md
```

### Modified Files

- `local-watcher/bin/idd-codex-modules/promote-pipeline.sh` — `po_load_edit_paths` を、信頼済み `author_association` を持つコメントだけに絞り込んでから `edit-paths-json` marker を抽出する実装へ変更する。marker 抽出は `jq` で完結させ、コメント本文を `sed` に渡さない。
- `local-watcher/test/po_load_edit_paths_trusted_authors_test.sh` — `gh` stub と fixture JSON で、信頼済み marker 採用、未信頼 marker 無視、未信頼最後勝ち上書き防止、信頼済み marker 不在時 `[]`、不正 JSON fail-safe を検証する。
- `README.md` — 既存 #50 migration note または Path Overlap Checker (Phase E) のセキュリティ説明に、4-C `edit-paths-json` marker も `author_association` 検証対象になったことを追記する。新規 env var は追加しない。

## Requirements Traceability

| Requirement | Summary | Components | Interfaces | Flows |
|-------------|---------|------------|------------|-------|
| 1 | 4-C edit-paths-json marker の信頼境界 | PathOverlapEditPathsLoader | `po_load_edit_paths(issue_number)` | Phase E load |
| 1.1 | `PATH_OVERLAP_CHECK=true` 時に信頼済み著者 marker のみ扱う | PathOverlapEditPathsLoader | GitHub comments JSON | trusted filter |
| 1.2 | 信頼済み / 未信頼 marker 混在時に未信頼を使わない | PathOverlapEditPathsLoader | jq extraction | mixed comments |
| 1.3 | 未信頼 marker の最後勝ち上書きを防ぐ | PathOverlapEditPathsLoader | jq extraction | last trusted wins only |
| 1.4 | 信頼済み marker 不在時に未信頼を代替しない | PathOverlapEditPathsLoader | fail-safe `[]` | no trusted marker |
| 1.5 | `PATH_OVERLAP_CHECK` 無効時の既存挙動維持 | PathOverlapDispatchGate | existing gate | disabled no-op |
| 2 | コメント著者信頼モデル | PathOverlapEditPathsLoader | `author_association` | marker trust decision |
| 2.1 | 信頼済み participant / automation のみ信頼 | PathOverlapEditPathsLoader | trusted association set | trusted comments |
| 2.2 | 未信頼著者本文を特権判断根拠にしない | PathOverlapEditPathsLoader | jq filter before body extraction | untrusted comments |
| 2.3 | marker 形式だけで信頼済み signal としない | PathOverlapEditPathsLoader | body-independent author check | forged marker |
| 2.4 | 本文とは独立した著者信頼情報で採否決定 | PathOverlapEditPathsLoader | `.author_association` | author metadata |
| 3 | 4-A / 4-B 回帰防止 | MergeQueueApprovalResolver, PRIterationGeneralCommentFilter | existing tests | regression |
| 3.1 | MQ が未信頼 approve / iteration / reject marker を扱わない | MergeQueueApprovalResolver | `mq_resolve_marker_approval_signal` | existing 4-A |
| 3.2 | PR Iteration が未信頼一般コメントを prompt に含めない | PRIterationGeneralCommentFilter | `pi_general_filter_untrusted_authors` | existing 4-B |
| 3.3 | 未信頼 `VERDICT: approve` で approved 扱いにしない | MergeQueueApprovalResolver | existing test | forged verdict |
| 3.4 | 未信頼 prompt injection 風コメントを根拠にしない | PRIterationGeneralCommentFilter | existing test | prompt filter |
| 3.5 | regression checks が 4-A / 4-B 無視を検証する | SecurityRegressionTests | shell tests | verify |
| 4 | 既存運用との互換性 | PathOverlapEditPathsLoader, Docs | env / labels / exit code | compatibility |
| 4.1 | 信頼済み `edit-paths-json` marker は従来どおり採用 | PathOverlapEditPathsLoader | marker JSON array | normal trusted marker |
| 4.2 | 信頼済み MQ marker semantics 維持 | MergeQueueApprovalResolver | existing test | no code change |
| 4.3 | 信頼済み PR Iteration comments semantics 維持 | PRIterationGeneralCommentFilter | existing test | no code change |
| 4.4 | env var / label / cron / exit code を変更しない | All Components | no new gate | compatibility |
| NFR 1.1 | コメント本文は未信頼入力として扱う | PathOverlapEditPathsLoader | jq-only extraction | security |
| NFR 1.2 | 未信頼コメントで特権判断を変更しない | PathOverlapEditPathsLoader, regression tests | shell tests | security |
| NFR 2.1 | trusted / untrusted を区別して検証 | SecurityRegressionTests | shell tests | verification |
| NFR 2.2 | 未信頼 marker の最後勝ち注入を検証 | SecurityRegressionTests | shell tests | verification |
| NFR 3.1 | `PATH_OVERLAP_CHECK` 未設定 / 非 true の無効化維持 | PathOverlapDispatchGate | existing gate | compatibility |
| NFR 3.2 | 4-A / 4-B 修正を緩めない | SecurityRegressionTests | existing tests | compatibility |

## Components and Interfaces

### Path Overlap

#### PathOverlapEditPathsLoader

| Field | Detail |
|-------|--------|
| Intent | Issue comment から信頼済み `edit-paths-json` marker だけを読み出す |
| Requirements | 1, 1.1, 1.2, 1.3, 1.4, 2, 2.1, 2.2, 2.3, 2.4, 4.1, 4.4, NFR 1.1, NFR 1.2, NFR 2.2, NFR 3.1 |

**Responsibilities & Constraints**

- `gh issue view "$issue_number" --repo "$REPO" --json comments` は従来どおり 1 回だけ呼ぶ。
- jq 内で `.comments[]` を `author_association` により先に filter し、その後に `.body` から marker を抽出する。
- 信頼集合は既存 #50 の既定と揃え、`OWNER MEMBER COLLABORATOR` とする。
- 新規 env var は追加しない。
- 未信頼コメントの body は marker 抽出対象にしない。
- marker 不在、API failure、jq failure、JSON 不正は `[]` を返す。

**Dependencies**

- Inbound: PathOverlapDispatchGate — candidate / holder Issue の edit paths 読み出し (Critical)
- Outbound: GitHub CLI `gh` — comments JSON 取得 (Critical)
- Outbound: `jq` — author filter / marker extraction / JSON validation (Critical)

**Contracts**: Service [x] / API [ ] / Event [ ] / Batch [ ] / State [ ]

##### Service Interface

```bash
po_load_edit_paths() {
  # Args: $1 = issue number
  # Stdout: compact JSON array string
  # Return: 0 always
}
```

- Preconditions:
  - `REPO` が設定済み
  - `gh` / `jq` が利用可能
- Postconditions:
  - stdout は常に JSON array 文字列
  - 未信頼著者コメント由来 marker は採用されない
  - 複数の信頼済み marker がある場合のみ、従来の「最後勝ち」を信頼済み集合内で維持する
- Invariants:
  - コメント本文の形式だけで trusted signal と判定しない
  - sed / eval / bash -c へ未信頼コメント本文を渡さない

#### PathOverlapDispatchGate

| Field | Detail |
|-------|--------|
| Intent | `PATH_OVERLAP_CHECK=true` のときだけ overlap 判定を実行する既存 gate |
| Requirements | 1.5, 4.4, NFR 3.1 |

**Responsibilities & Constraints**

- 本 Issue では gate 条件を変更しない。
- `PATH_OVERLAP_CHECK` 未設定 / `true` 以外では `po_load_edit_paths` 起因の挙動変化が表面化しない既存 no-op を維持する。

**Dependencies**

- Inbound: Dispatcher — dispatch 前 gate (Critical)
- Outbound: PathOverlapEditPathsLoader — edit paths 読み出し (Critical)

**Contracts**: Service [x] / API [ ] / Event [ ] / Batch [ ] / State [ ]

### Existing Security Boundaries

#### MergeQueueApprovalResolver

| Field | Detail |
|-------|--------|
| Intent | PR Reviewer marker / GitHub formal review から Merge Queue approval signal を解決する |
| Requirements | 3.1, 3.3, 4.2, 4.4, NFR 3.2 |

**Responsibilities & Constraints**

- 本 Issue では実装変更しない。
- `MERGE_QUEUE_TRUSTED_ASSOCIATIONS` による既存 author filter を regression test で維持確認する。

**Dependencies**

- Inbound: Merge Queue Processor — approved PR selection (Critical)
- Outbound: GitHub comments API — PR issue comments 取得 (Critical)
- Outbound: `jq` — marker 解析 (Critical)

**Contracts**: Service [x] / API [ ] / Event [ ] / Batch [ ] / State [ ]

#### PRIterationGeneralCommentFilter

| Field | Detail |
|-------|--------|
| Intent | PR Iteration の一般コメント入力から未信頼著者コメントを除外する |
| Requirements | 3.2, 3.4, 4.3, 4.4, NFR 3.2 |

**Responsibilities & Constraints**

- 本 Issue では実装変更しない。
- `PR_ITERATION_TRUSTED_ASSOCIATIONS` による既存 author filter を regression test で維持確認する。

**Dependencies**

- Inbound: PR Iteration Processor — prompt assembly (Critical)
- Outbound: `jq` — comments filter (Critical)

**Contracts**: Service [x] / API [ ] / Event [ ] / Batch [ ] / State [ ]

### Test Coverage

#### SecurityRegressionTests

| Field | Detail |
|-------|--------|
| Intent | 4-C の新規防御と 4-A / 4-B の既存防御が回帰していないことを shell-level で検証する |
| Requirements | 3.5, NFR 2.1, NFR 2.2, NFR 3.2 |

**Responsibilities & Constraints**

- 新規 `po_load_edit_paths_trusted_authors_test.sh` で 4-C の trusted / untrusted / last-wins / fail-safe ケースを検証する。
- 既存 `merge_queue_approval_signal_test.sh` と `pi_general_filter_untrusted_authors_test.sh` を verify 対象に含め、4-A / 4-B の既存防御を固定する。
- GitHub 実 API には依存せず、既存テストと同じ `gh` stub / fixture 方式を使う。

**Dependencies**

- Inbound: stage-a-verify gate — verify block の再実行対象 (Critical)
- Outbound: PathOverlapEditPathsLoader — 4-C loader behavior (Critical)
- Outbound: MergeQueueApprovalResolver / PRIterationGeneralCommentFilter — 既存 regression (Critical)

**Contracts**: Service [ ] / API [ ] / Event [ ] / Batch [x] / State [ ]

### Documentation

#### SecurityDocumentation

| Field | Detail |
|-------|--------|
| Intent | #50 のセキュリティ修正範囲に 4-C を反映する |
| Requirements | 4.4 |

**Responsibilities & Constraints**

- README の既存 #50 migration note または Phase E security 説明へ、`edit-paths-json` marker も信頼済み著者コメントのみ採用する旨を追記する。
- 新規 env var は追加しない。

**Contracts**: Service [ ] / API [ ] / Event [ ] / Batch [ ] / State [ ]

## Data Models

### GitHub Comment Model

`gh issue view --json comments` の comments 要素を以下の形として扱う。

```json
{
  "author_association": "OWNER",
  "body": "<comment body>"
}
```

- `author_association` は本文とは独立した信頼判断の入力。
- 欠落 / 空 / 不明値は未信頼として扱う。
- 比較は大文字化して行い、既定信頼集合は `OWNER`, `MEMBER`, `COLLABORATOR`。

### Marker Model

```text
<!-- idd-codex:edit-paths-json:["local-watcher/","README.md"] -->
```

- marker payload は JSON array として再検証する。
- array 以外は `[]`。
- array 内の非文字列要素は除外する。
- 複数 marker がある場合、信頼済みコメントから抽出した marker の中で最後の valid marker を採用する。

## Error Handling

### Error Strategy

- API failure / jq parse failure / marker 不在 / payload 不正はすべて `[]` を返す fail-safe。
- `po_load_edit_paths` の return code は従来どおり 0 固定。
- 未信頼コメントのみの場合も warning ではなく `[]`。通常の public repo では外部コメントが存在しうるため、ノイズを増やさない。
- shellcheck / tests で検出可能な構文・依存問題は verify gate で止める。

### Error Categories and Responses

- **User Errors**: 不正 marker JSON、array 以外、非文字列要素混入は `[]` または文字列要素のみへ正規化。
- **System Errors**: `gh issue view` 失敗、jq 失敗は `[]` を返して dispatch 側を安全側に倒す。
- **Business Logic Errors**: 信頼済み marker が無い場合、未信頼 marker を代替しない。

## Testing Strategy

- **Unit / Shell Tests**:
  - `po_load_edit_paths_trusted_authors_test.sh` で信頼済み marker が従来どおり採用されることを検証
  - 同テストで未信頼 marker が混在しても採用されないことを検証
  - 同テストで未信頼 marker が最後にある場合でも最後勝ち上書きされないことを検証
  - 同テストで信頼済み marker 不在時に `[]` を返すことを検証
  - 同テストで不正 JSON / array 以外 / 非文字列要素の fail-safe を検証
- **Regression Tests**:
  - `merge_queue_approval_signal_test.sh` を実行し、4-A の未信頼 approve / reject / iteration marker 無視を確認
  - `pi_general_filter_untrusted_authors_test.sh` を実行し、4-B の未信頼一般コメント除外を確認
  - `shellcheck --severity=warning` で変更対象スクリプトと関連テストを確認
- **Integration / E2E**:
  - GitHub 実 API を使う E2E は必須にしない。`gh` stub による shell-level regression で comments JSON 契約を検証する。
  - `PATH_OVERLAP_CHECK` 無効時の dispatch no-op は既存 gate を変更しないことで担保し、必要なら既存 Phase E テスト範囲で確認する。
- **Performance/Load**:
  - `po_load_edit_paths` の comments API 呼び出し回数は従来どおり 1 Issue 1 回。
  - jq filter は取得済み comments JSON 上で完結し、新規 network call を追加しない。

## Security Considerations

- Issue / PR コメント本文はすべて未信頼入力として扱う。
- `po_load_edit_paths` は body 抽出より前に `author_association` を検証する。
- 未信頼 body を `sed` に渡さない。marker 抽出は jq 内で完結させる。
- marker 本文の形式、GitHub user 名、コメント順序だけを信頼根拠にしない。
- 4-A / 4-B の既存 security boundary は変更せず regression で守る。

## Migration Strategy

スキーマ移行、ラベル移行、env var 変更は不要。既存 sticky comment の marker 形式は維持する。  
既存の信頼済み maintainer / automation 投稿コメントは引き続き採用され、未信頼コメントだけが採用対象から外れる。
