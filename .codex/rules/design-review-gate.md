<!-- SPDX-License-Identifier: MIT -->
<!-- Adapted from cc-sdd (https://github.com/gotalab/cc-sdd), MIT License, Copyright (c) gotalab -->

# 設計書レビューゲート（Architect 自己レビュー）

Architect が `design.md` を書き終える前に、このゲートに従ってドラフトをレビューし、
問題があれば修正、問題なければ確定します。

## 要件カバレッジレビュー

- `requirements.md` の **すべての numeric requirement ID**（1, 1.1, 2, 2.1 ...）が design.md の
  Requirements Traceability マッピングに現れ、具体的なコンポーネント・契約・フロー・データモデル・
  運用判断のいずれかで裏打ちされているか
- 外部依存・連携点・ランタイム前提・マイグレーション・可観測性・セキュリティ・
  パフォーマンス目標が明示的に design.md に反映されているか
- カバー不足が draft 不完全さなら修正、**要件自体が曖昧なら requirements に戻す**
  （設計側で要件を勝手に発明しない）

## アーキテクチャ準備レビュー

- コンポーネント境界が、実装タスクの担当を推測せず割り当てられる程度に明示されているか
- Interfaces / Contracts / State transitions / 統合境界が、実装と検証のために十分具体的か
- build vs adopt の判断のうち、アーキテクチャに材料的に影響するものが design.md に記録されているか
- ランタイム前提・マイグレーション・ロールアウト制約・検証フック・障害モードのうち、
  実装順序やリスクに影響するものが可視化されているか

## 実行可能性レビュー

- 設計が、隠れた前提なしで**境界のあるタスク列**として実装可能か
- 並列実装を意図する箇所では parallel-safe な境界が見えているか
- 投機的抽象化（将来スコープのためだけに存在するコンポーネント／アダプタ／インターフェース）を排除しているか
- tasks.md で直接参照できない程に曖昧なセクションは、確定前に書き直す

## Mechanical Checks（自動確認項目）

判断レビューの前に、機械的に確認します:

- **Requirements traceability**: requirements.md から numeric ID を全抽出し、design.md のどこかに
  出現するか scan。未参照 ID を報告
- **File Structure Plan の充填**: File Structure Plan セクションに具体的なファイルパスが
  書かれているか（"TBD" やプレースホルダを検出）
- **orphan component なし**: design.md の Components セクションに挙がったコンポーネント名のうち、
  File Structure Plan に対応ファイルが無いものを検出

### `/goal` による自動ループ運用（Codex v2.1.139+）

Codex v2.1.139 以降では、上記 3 つの Mechanical Checks を `/goal` の完了条件として
宣言し、未達なら自動で次ターンを実行する運用が可能です。**v2.1.139 未満の環境では本節
全体をスキップし、後述の「レビュー・ループ」節の従来手順（Mechanical Checks → 判断レビュー
→ 最大 2 パス）をそのまま適用してください**（後方互換）。

#### 適用タイミング

Architect エージェントが `design.md` ドラフトを確定する直前、判断レビュー（要件カバレッジ
／アーキテクチャ準備／実行可能性）を通過した段階で `/goal` を発行します。順序は
「Mechanical Checks の `/goal` 自動ループ → 判断レビュー → 確定」を推奨します。

#### Architect 向け完了条件文字列テンプレ例

以下のいずれかを `/goal <条件>` の `<条件>` 部に貼り付けて発行します（自然言語の AND
結合で記述し、EARS トリガーキーワード `When` / `If` / `While` / `Where` / `shall` は混ぜない）:

```
requirements.md のすべての numeric requirement ID（1, 1.1, 2 等）が design.md のどこかに出現し、
かつ File Structure Plan セクションに具体的なファイルパスが書かれていて "TBD" やプレースホルダが残っておらず、
かつ Components セクションに挙がった全コンポーネント名が File Structure Plan に対応ファイルを持つ
```

短縮版:

```
design.md は全 numeric requirement ID を参照し、File Structure Plan に "TBD" が残置されず、全 Component に対応ファイルがある
```

#### ターン上限の併記

`/goal` 自動ループのターン上限は、後述「レビュー・ループ」節の **最大 2 パス**を流用します
（撤廃ではなく併記）。`/goal` が 2 ターン経過しても完了条件を満たさない場合は、自動ループ
を終了し、要件フェーズ戻し（requirements.md 側の不明点を PM に差し戻す）または人間
エスカレーション（Issue コメントで設計判断を仰ぐ）を選択します。

## レビュー・ループ

- Mechanical Checks → 判断レビューの順
- 問題が draft 内で閉じるなら修正して再レビュー
- **最大 2 パス**で確定するか、要件フェーズに戻す（無限ループを避ける）
  - Codex v2.1.139+ では上記「`/goal` による自動ループ運用」節の手順で Mechanical Checks 部分を自動収束させる
  - v2.1.139 未満では本節の手順をそのまま実行する（従来挙動と完全一致）
- ゲート通過後に `design.md` を確定させる

## 参考

- [cc-sdd `design-review-gate.md`](https://github.com/gotalab/cc-sdd/blob/main/.kiro/settings/rules/design-review-gate.md)
