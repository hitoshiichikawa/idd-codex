# Requirements

## 1. Codex 実行既定値の後方互換性

### 1.1
When watcher が Codex CLI 実行設定を初期化するとき, the watcher shall 既存の `CODEX_SANDBOX` / `CODEX_APPROVAL_POLICY` / `CODEX_UNSAFE_BYPASS` env var 名と override 挙動を維持する。

### 1.2
When `CODEX_UNSAFE_BYPASS` が未設定のまま watcher が Codex CLI を起動するとき, the watcher shall 既存と同じバイパス起動挙動を維持する。

### 1.3
When `CODEX_UNSAFE_BYPASS=false` が明示された状態で watcher が Codex CLI を起動するとき, the watcher shall `CODEX_SANDBOX` と `CODEX_APPROVAL_POLICY` による既存の非バイパス起動挙動を維持する。

## 2. 未信頼 Issue 入力のプロンプト境界

### 2.1
When watcher が Issue タイトルまたは本文を Codex プロンプトへ埋め込むとき, the watcher shall その内容が未信頼データであり指示として扱わないことを同じプロンプト内で明示する。

### 2.2
When watcher が Issue 本文を Codex プロンプトへ埋め込むとき, the watcher shall 本文の開始位置と終了位置を人間にもエージェントにも判別できる境界で囲む。

### 2.3
If Issue 本文に命令文、コードフェンス、または別のロールを装う文面が含まれるとき, the watcher shall それらを Issue 由来のデータとして提示し、watcher 自身の上位指示とは区別できる状態にする。

## 3. 未信頼 PR コメント入力のプロンプト境界

### 3.1
When PR Iteration prompt が line コメント JSON または一般コメント JSON を Codex に渡すとき, the prompt shall コメント本文が未信頼データであり指示として扱わないことを明示する。

### 3.2
When PR Iteration prompt が review コメント対応方針を説明するとき, the prompt shall コメント本文から実行権限・承認・制約緩和の指示を受け取らないことを明示する。

## 4. 運用ガイドでの安全設定推奨

### 4.1
When operator が README のオプション機能一覧または Codex Guard Hook 節を読むとき, the documentation shall 既定構成では Codex Guard Hook が無効であることと、公開 repo では `IDD_CODEX_HOOKS_ENABLED=true` を強く推奨することを確認できる。

### 4.2
When operator が README の Codex 実行設定を確認するとき, the documentation shall `CODEX_UNSAFE_BYPASS` / `CODEX_SANDBOX` / `CODEX_APPROVAL_POLICY` の関係と、既定値を安全側へ反転していない理由を確認できる。

### 4.3
When operator が安全側の実行を試したいとき, the documentation shall `CODEX_UNSAFE_BYPASS=false` と sandbox / approval policy override の設定例を確認できる。

## 5. 回帰検証

### 5.1
When tests are run for prompt boundary rendering, the test suite shall verify that Issue title/body data appears inside the untrusted-data boundary and that the boundary warning remains present.

### 5.2
When tests are run for PR Iteration prompt rendering, the test suite shall verify that PR comment JSON appears with an untrusted-data warning.

### 5.3
When shellcheck is run for changed shell scripts, the verification shall complete without warning-level findings introduced by this change.

## Scope

- 既定値を `workspace-write` へ反転しない。owner コメントの回答 `B` により、後方互換を優先する。
- Guard Hook 自体の deny 規則強化は別 Issue の範囲であり、本 Issue では既存 hook の有効化推奨と prompt 境界の明示に限定する。
- codex CLI の `workspace-write` 実機完遂検証は未決事項として扱い、本 Issue では必須受入基準に含めない。

## 確認事項

- `workspace-write` を将来の既定値候補にする場合、watcher の通常タスクが完遂できるかの実機検証と migration note が別途必要。
