# Requirements Document

## Introduction

Codex CLI のモデル指定が現在の CLI 版数で利用できない場合や、モデル ID の typo / retired model 指定で `model not found` 系エラーになる場合、現在の watcher は通常の実装失敗と同じ `codex-failed` に分類しやすい。その結果、設定ミスのような決定論的失敗が実装失敗や Reviewer reject と混ざり、failed-recovery が無駄な retry budget を消費する。

本件は、stage 起動前のモデル別 Codex CLI バージョン preflight と、codex stderr / stream に現れる model 不存在系エラーの分類を追加し、設定エラーとして観測可能にするための enhancement である。人間コメントによる追加決定事項はなく、Triage edit_paths は `local-watcher/` と `README.md` である。

## Requirements

### Requirement 1: モデル別 Codex CLI バージョン preflight

**Objective:** As a watcher operator, I want モデル ID と Codex CLI version の不整合を stage 起動前に検知できること, so that 決定論的な設定ミスで codex 実行や retry budget を消費しない。

#### Acceptance Criteria

1. If 指定モデルが要求する最低 Codex CLI version を現在の `codex --version` が満たさないとき, the watcher shall codex stage を起動せず fail-fast する。
2. If model version preflight が fail-fast するとき, the watcher shall モデル名、現在 version、要求 version、`codex update` 案内を operator-visible log に出力する。
3. If model version preflight が fail-fast するとき, the watcher shall 当該失敗を実装失敗ではなく設定エラーの可能性として Issue / PR の escalation comment で識別可能にする。
4. When 指定モデルが対応表に存在しないとき, the watcher shall 前方互換のため preflight で拒否せず既存の codex 実行経路へ進める。
5. If `codex --version` が実行不能または version 抽出不能のとき, the watcher shall 対応表に存在するモデルの preflight を安全側で失敗扱いにし、原因を operator-visible log に出力する。

### Requirement 2: model-not-found 系失敗の分類

**Objective:** As a watcher operator, I want codex 実行後に model 不存在系エラーを通常失敗と区別できること, so that 設定修正が必要な失敗を実装 retry から切り離せる。

#### Acceptance Criteria

1. If codex stderr または stream output に `model not found` 系の文言が含まれるとき, the watcher shall その失敗を model 設定エラーの可能性として分類する。
2. If codex stderr または stream output に `unsupported model` 系の文言が含まれるとき, the watcher shall その失敗を model 設定エラーの可能性として分類する。
3. When model 設定エラー分類が発生するとき, the watcher shall operator-visible log に stage、model、検出理由、参照 log artifact を出力する。
4. When model 設定エラー分類が発生するとき, the watcher shall escalation comment に「設定エラーの可能性」を明記する。
5. If model 設定エラー分類が発生するとき, the watcher shall quota wait と混同せず、quota 分類が成立する場合は既存の quota wait 経路を優先する。

### Requirement 3: モデル要件対応表と設定 override

**Objective:** As a maintainer, I want モデル別最低 version 要件を更新しやすいこと, so that 新モデル追加や vendor 側変更に watcher 更新なしで追従できる。

#### Acceptance Criteria

1. The watcher shall モデル別最低 Codex CLI version の既定対応表を持つ。
2. When operator が環境変数でモデル別最低 version 対応表を指定するとき, the watcher shall 既定対応表ではなく override 対応表を使う。
3. If override 対応表に malformed entry が含まれるとき, the watcher shall silent fail せず WARN log を出し、その entry を無視する。
4. When `gpt-5.6-*` model is specified, the watcher shall 既定対応表で Codex CLI `0.144.0` 以上を要求する。
5. The watcher shall モデル ID の typo を preflight 対応表の未知モデルとしては拒否せず、codex 実行後の model-not-found 分類で観測可能にする。

### Requirement 4: 共有 semver 比較

**Objective:** As a maintainer, I want semver 比較を重複実装せず共有できること, so that guard hook preflight と model preflight の version 判定が一貫する。

#### Acceptance Criteria

1. The watcher shall semver 比較 helper を watcher 共通 utility として提供する。
2. When guard hook preflight compares Codex CLI versions, the guard hook shall 共有 semver helper を使う。
3. When model preflight compares Codex CLI versions, the model preflight shall 共有 semver helper を使う。
4. If semver input に prerelease suffix または build metadata 相当の非数値 suffix が含まれるとき, the shared helper shall major / minor / patch の数値 prefix を使って比較する。
5. If semver input の major / minor / patch が数値として解釈できないとき, the shared helper shall 比較不能として非 0 を返す。

### Requirement 5: モジュール境界と後方互換

**Objective:** As a maintainer, I want 新規 preflight / classification ロジックを watcher monolith に直書きしないこと, so that local-watcher の肥大化と既存 cron 契約破壊を避けられる。

#### Acceptance Criteria

1. The watcher shall model preflight / model error classification の主要ロジックを新規 module に配置する。
2. The watcher shall main watcher script への変更を module load と既存 codex 起動経路への最小接続に限定する。
3. The watcher shall 既存 env var 名、label 名、cron invocation contract、branch naming contract、既存 exit code 意味を変更しない。
4. The watcher shall 新しい外部 service 呼び出しまたは runtime dependency を追加しない。
5. The watcher shall feature behavior を default ON の観測 / fail-fast policy として提供し、operator が環境変数で無効化できる escape hatch を持つ。

### Requirement 6: 回帰検証とドキュメント

**Objective:** As a maintainer, I want preflight / model-not-found 分類の regression coverage と運用説明があること, so that 将来の model / CLI 更新で設定エラー分類が失われない。

#### Acceptance Criteria

1. When regression coverage exercises a known model whose minimum version is greater than current CLI version, the test suite shall codex command が起動されないことを検証する。
2. When regression coverage exercises an unknown model, the test suite shall preflight が拒否せず codex command を起動することを検証する。
3. When regression coverage exercises model-not-found stderr / stream, the test suite shall model 設定エラー分類が返ることを検証する。
4. When regression coverage exercises malformed override map, the test suite shall WARN log と malformed entry skip を検証する。
5. When implementation changes shell scripts, the verification shall include `shellcheck --severity=warning` for changed watcher scripts and new tests.
6. When README describes optional features and troubleshooting, the documentation shall include model preflight / model-not-found classification behavior, env overrides, and recovery guidance.

## Non-Functional Requirements

### NFR 1: Backward compatibility

1. The system shall preserve existing labels including `codex-failed` and `codex-needs-quota-wait`.
2. The system shall preserve existing `QUOTA_AWARE_ENABLED` behavior and quota wait label transition semantics.
3. The system shall not change default `TRIAGE_MODEL`, `DEV_MODEL`, `REVIEWER_MODEL`, `DEBUGGER_MODEL`, `PR_ITERATION_DEV_MODEL`, or `FAILED_RECOVERY_DEV_MODEL` values in this spec.

### NFR 2: Operator observability

1. When preflight or model error classification occurs, the system shall leave grep-friendly logs with a stable processor prefix.
2. When model configuration error is escalated, the system shall include the failing model ID and recommended operator action.

## Out of Scope

- Codex CLI の model catalog を実行時に外部取得すること。
- 既存 default model ID の更新。
- 新しい label の追加。
- failed-recovery の attempt budget 全体の再設計。
- quota detection / reset parsing の仕様変更。
- Codex CLI 自体の install / update 実行。

## Open Questions

- なし。

## Issue コメント反映

- `gh issue view 175 --comments` により、既存コメントは Triage edit_paths と着手コメントのみで、人間の追加決定事項がないことを確認した。
- Triage edit_paths の自動コメントにより、編集見込み top-level path は `local-watcher/` と `README.md` とする。

## PM Self Review

- Mechanical Checks: numeric requirement ID、各 requirement の EARS 形式 AC、Out of Scope、Open Questions を確認した。
- 判断レビュー: Issue 本文の preflight、model-not-found 分類、未知モデル前方互換、env override、semver 共有化、新規 module 境界、回帰検証、README 更新要求を網羅し、関数名や実装詳細に過度に踏み込んでいないことを確認した。
