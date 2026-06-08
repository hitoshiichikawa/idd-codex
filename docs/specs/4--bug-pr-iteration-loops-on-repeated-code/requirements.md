# Requirements

## 1. PR Iteration の usage-limit 風 fatal error 退避

When Codex CLI が PR Iteration 中に usage-limit 風の fatal error を返して非 0 終了したとき, the PR Iteration Processor shall 同一 PR・同一 round を cron tick ごとに無制限再実行しない。

When usage-limit 風 fatal error から reset time を抽出できるとき, the PR Iteration Processor shall 既存の `codex-needs-quota-wait` ラベルを PR に付与し、`codex-needs-iteration` を除去して待機状態へ退避する。

If usage-limit 風 fatal error から reset time を抽出できないとき, the PR Iteration Processor shall 小さい有界回数以内に `codex-needs-decisions` へ退避し、人間判断を要求する。

The PR Iteration Processor shall PR 専用の新しい quota wait ラベルを導入せず、既存の `codex-needs-quota-wait` を PR にも再利用する。

## 2. 同一 round の processing コメント重複防止

When PR Iteration が round 開始コメントを投稿しようとするとき, the PR Iteration Processor shall 同一 PR・同一 round の `pr-iteration-processing` marker が既に存在する場合に新しい processing コメントを投稿しない。

If Codex CLI fatal error により round marker が更新されないとき, the PR Iteration Processor shall 次回実行でも同一 round の processing コメントを増殖させない。

## 3. ラベル遷移と運用者可視性

When usage-limit 風 fatal error を待機状態へ退避するとき, the PR Iteration Processor shall PR コメントで検出理由、reset time の有無、再開または人間判断に必要な状態を運用者へ明示する。

When usage-limit 風 fatal error を待機状態または判断待ちへ退避するとき, the PR Iteration Processor shall `codex-failed` を付与せず、quota 起因または quota 風の停止として分類する。

If ラベル変更またはコメント投稿が失敗したとき, the PR Iteration Processor shall 失敗をログに残し、silent fail を作らない。

## 4. 回帰テスト

When 同一 PR・同一 round で Codex CLI の usage-limit 風非 0 エラーが繰り返されるケースを検証するとき, the test suite shall processing コメントが重複投稿されないことを確認する。

When Codex CLI の usage-limit 風 fatal error 検出を検証するとき, the test suite shall reset time ありと reset time なしの両方をカバーする。

## Scope

- 対象: `local-watcher/` 配下の PR Iteration Processor、関連テスト、必要な README 記述。
- 対象外: Codex CLI 本体の quota 表示、ChatGPT/Codex account quota system、PR 実装修正そのもの。

## Decisions

- Issue コメントで人間回答済みの決定事項として、usage-limit 風 fatal error を受けた PR は既存の `codex-needs-quota-wait` を再利用する。
