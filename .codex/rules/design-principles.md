<!-- SPDX-License-Identifier: MIT -->
<!-- Adapted from cc-sdd (https://github.com/gotalab/cc-sdd), MIT License, Copyright (c) gotalab -->

# design.md 記述原則

Architect が `design.md` を書く際の全体方針と必須セクションの設計思想。

## 目的

異なる実装者の間で**実装の一貫性**を担保するのに十分な詳細を提供し、解釈のズレを防ぐこと。

## アプローチ

- 実装判断に直接影響する必須セクションを含める
- 実装ミスの防止に不可欠でない optional セクションは省略する
- 詳細度は機能の複雑度に合わせる
- 散文より **図・表** を優先する

## 外部仕様の不確実性を Web 検索で解消する

外部ツール・ライブラリ・API・CLI コマンドの仕様に依拠した設計判断は、モデル知識のカットオフや
細部仕様の曖昧さによって推測ベースで確定しやすく、Developer フェーズで仕様乖離が判明する
事故の温床になります。設計品質の取りこぼしを減らすため、Architect は不確実な外部仕様について
Web 検索で一次情報（公式ドキュメント・公式 GitHub README / issue・公式 changelog 等）を確認
してから設計判断を行ってください。

### 検索対象のスコープ

- **対象**: 外部ツール・ライブラリ・API・CLI コマンドの仕様（オプションフラグ・返り値・互換性・
  既知の制約等）
- **対象外**: idd-codex 内部の既存仕様・既存実装（既存ドキュメント・既存コード・既存テストの
  参照を優先）、些末な書式・命名選択など外部仕様に直接依拠しない判断

### 適用の最小化

「不明な場合・新規ツール導入時に限定」して必要最小限に留めます。既に確信が持てる仕様や、
内部完結する判断のためだけに Web 検索を起動しないでください。

### 検索結果のリンク記録（推奨止め）

検索結果のリンクを `design.md` の該当セクション本文または `## Supporting References` 等の
optional セクションに残すことを **推奨**します。記録時は短縮表記（例: `<https://example.com/docs/foo>`）
で十分です。ただし **義務化はしません**。リンクを記録するか否かは Architect の裁量に委ねます
（記録の有無を理由に design-review-gate で reject しません）。

## 警告: 1000 行を超えたら複雑すぎる

1000 行を超える design.md は、機能の複雑度が高すぎる可能性があります。設計の単純化、
もしくは複数 spec への分割（複数 Issue に切り直し）を検討してください。

## セクション順序の柔軟性

標準順序（Overview → Architecture → File Structure Plan → …）から逸脱して、
`Requirements Traceability` を前に配置したり、`Data Models` を `Architecture` の近くに
置いたりしても構いません。読みやすさのため調整してください。

各セクション内では **Summary → Scope → Decisions → Impacts/Risks** の流れを保ち、
レビュワーが一貫してスキャンできるようにします。

## 必須セクション

| セクション | 目的 | 備考 |
|---|---|---|
| Overview | 機能の狙い・ユーザー・インパクト | 2-3 段落で簡潔に |
| Goals / Non-Goals | 明示的な対象と除外 | スコープ境界を誤読されない |
| Architecture Pattern & Boundary Map | 採用パターンと境界 | 複雑機能では Mermaid 図必須 |
| Technology Stack | レイヤごとの技術選定 | 表形式 |
| File Structure Plan | ディレクトリと責務 | **tasks.md の `_Boundary:_` を駆動する** |
| Requirements Traceability | req ID → 設計要素 | 複雑機能のみ（単純 1:1 なら Components で代替可） |
| Components and Interfaces | コンポーネント詳細 / 契約 | Service / API / Event / Batch / State の契約を明示 |
| Data Models | ドメイン / 論理 / 物理モデル | 該当する範囲のみ |
| Error Handling | エラー戦略・カテゴリ・監視 | 具体的な例を含める |
| Testing Strategy | 単体／結合／E2E／性能 | 各 3-5 項目 |

## Optional セクション（必要時のみ）

- **Security Considerations**: 認証・機密情報を扱う機能、外部連携、ユーザー権限が絡む機能
- **Performance & Scalability**: 性能目標・高負荷・スケール懸念がある機能
- **Migration Strategy**: スキーマ・データ移動を伴う場合。Mermaid flowchart で段階を可視化
- **Supporting References**: 長大な型定義・ベンダー比較表など、本文で読みにくい付随情報

## File Structure Plan の書き方

- **小機能**: 個別ファイル単位で責務を列挙
- **大機能**: ディレクトリレベル + per-domain パターンを記述、非自明なファイルのみ個別列挙

例:

```
src/
├── domain-a/              # Domain A responsibility
│   ├── controller.ts      # Endpoint handlers
│   ├── service.ts         # Business logic
│   └── types.ts           # Domain types
├── domain-b/              # Domain B (same pattern as domain-a)
└── shared/
    └── cross-cutting.ts   # Non-obvious: why this exists
```

- 繰り返し構造の場合は、パターンを 1 回だけ記述（"domain-b follows same pattern as domain-a"）
- 個別ファイルはその責務がパスから自明でない場合のみ個別列挙

## bootstrap 一極集中の回避（self-register パターン）

> 本節は **推奨（指針）であり必須ではありません**。採否は Architect の判断に委ねます。
> ここで示す回避策を採らないことを理由に design-review-gate で reject することはありません。

### 課題: 単一 bootstrap が merge conflict ホットスポットになる

単一の bootstrap ファイル（`cmd/api/main.go` の DI 配線スロット、ルータの Mount 列挙、
プラグイン登録テーブル等）へ、各ドメイン／機能が **一極集中で配線を追記する**設計を採ると、
並行して進む複数の Issue が同じ bootstrap ファイルの同じ近傍を編集することになり、
**merge conflict が構造的に発生し続ける** ホットスポットになります。idd-codex のように
複数 Issue が並行で PR を出すワークフローでは、この衝突が auto-rebase / merge-queue の停滞や
人手介入の増加に直結します。

衝突の中身は多くの場合「import の和集合」「各ドメインの Mount 行の併記」で機械的に解消できる
**加算的（追加のみ）**なものですが、加算的であっても衝突自体は毎回発生するため、設計段階で
配線の集中そのものを分散できるならその方が望ましい場面があります。

### 回避指針: ドメインごとに self-register（registry）する

bootstrap が各ドメインを **能動的に列挙して配線する**（pull 型）のではなく、各ドメインが
**自分自身を共有 registry / router へ登録する**（push 型 / self-register）構成にすると、
配線の追記がドメイン側のファイルに分散し、bootstrap ファイルの編集が不要になります:

- 各ドメインは init（パッケージ初期化 / モジュールロード時の副作用 / 明示的な登録呼び出し）で
  共有 registry へ自分のハンドラ・ルート・依存を登録する
- bootstrap は registry を 1 度走査して全登録分を一括配線するだけになり、**ドメイン追加で
  bootstrap を編集しなくて済む**
- 結果として、並行 Issue は各自のドメインファイルだけを触り、共通 bootstrap での衝突が原理的に
  起きにくくなる

### 適用条件: 加算的追記の集中が見えたら評価対象にする

複数のドメインが **同一 bootstrap の同じ配線スロットへ加算的に追記する**設計（import 列・
Mount 列・登録テーブルへ各ドメインが行を足し続ける形）を検討している場合、self-register
パターンを **評価対象**として俎上に乗せてください。配線が 1 ドメインに閉じる小規模な設計や、
登録順序に強い依存があり明示的な列挙の方が読みやすい場合などは、無理に self-register 化せず
従来の集中配線を選んで構いません（採否は Architect の判断）。

### Out of Scope

- 本節は **設計判断の材料を増やす指針**であり、特定言語／フレームワークの registry 実装
  テンプレート（Go の `init()` 登録、DI コンテナ設定等）は提供しません。実装手段は対象
  リポジトリの言語・慣習に合わせて Architect / Developer が選択します。
- self-register を idd-codex が生成する設計へ自動適用・強制する仕組みは持ちません。

## 参考

- [cc-sdd `design.md` テンプレート](https://github.com/gotalab/cc-sdd/blob/main/.kiro/settings/templates/specs/design.md)
