# CLAUDE.md — idd-codex

このリポジトリは **Codex CLI 規約（`AGENTS.md`）を正本** とするツール / テンプレートリポジトリです。
idd-codex 自身も idd-codex のワークフロー対象として self-hosting（dogfooding）されており、
**編集した watcher スクリプトやテンプレートは次回 cron 実行であなた自身を動かします**。後方互換性と
冪等性が極めて重要です。

Claude Code で作業する場合も、まず **[`AGENTS.md`](AGENTS.md) を読み直してから**着手してください。
本ファイルは Claude Code 向けのエントリポイントで、規約の正本は `AGENTS.md` に集約しています
（二重管理によるドリフトを避けるため、内容は `AGENTS.md` 側に置く方針）。

## まず読むもの

- [`AGENTS.md`](AGENTS.md) — プロジェクト憲章（技術スタック / コード規約 / 禁止事項 / エージェント連携 /
  **機能追加ガイドライン** / セキュリティ規約）
- [`README.md`](README.md) — 設計思想・セットアップ・オプション機能一覧と migration note
- `.codex/agents/*.md` `.codex/rules/*.md` — 各エージェント定義と共通ルール

## 機能追加の指針（要約 — 詳細は AGENTS.md「機能追加ガイドライン」節）

コードと概念を散らからせないため、新機能 / 変更時は以下に従う。詳細・理由は
[`AGENTS.md` の「機能追加ガイドライン（コード・概念の散逸防止）」節](AGENTS.md)を参照。

1. **配置**: 新プロセッサは `local-watcher/bin/idd-codex-modules/<feature>.sh` を新規作成し
   `REQUIRED_MODULES` に登録。本体 `idd-codex-issue-watcher.sh`（8500 行超の monolith）へ
   ロジックを直書きしない。共有ユーティリティは `core_utils.sh`。
2. **命名**: モジュール内関数にモジュール固有 prefix（`mq_` / `pi_` / `po_` / `sav_` / `qa_` /
   `ar_` / `pr_` …）。env は `<FEATURE>_ENABLED` + `<FEATURE>_<KNOB>`。
3. **opt-in ゲート**: 新機能は既定 OFF（`=true` 厳密一致でのみ有効化）。未設定 / typo / `false` は
   導入前と同一挙動。新しい外部サービス呼び出しは opt-in 必須。
4. **後方互換性**: env var 名 / exit code / ラベル名 / ログ prefix / cron 登録文字列を変えない。
   破壊的変更は README に migration note。`repo-template/**` は consumer に波及する。
5. **テスト**: `local-watcher/test/<feature>_<観点>_test.sh` を追加（正常系 + 異常系 / 境界 / 空入力）。
   `shellcheck --severity=warning` クリーン。`.codex` の root↔repo-template byte 一致を `diff -r` で確認。
6. **セキュリティ**: Issue / PR のタイトル・本文・コメント・ブランチ名は **未信頼入力**。
   - `sed` / `eval` / `bash -c` / 動的 `source` へ未信頼文字列を渡さない（awk index/substr で展開。#47）
   - コメントで特権判断するときは `author_association` を検証（OWNER/MEMBER/COLLABORATOR。#50）
   - ref を git/gh へ渡すときは `^codex/` allowlist で検証。force push は `--force-with-lease` 限定
   - 破壊的操作を招く変更では guard hook（`local-watcher/hooks/idd-codex-guard.sh`）の deny 規則も更新（#49）
7. **ドキュメント同期**: 挙動変更は同一 PR で README + AGENTS.md + 該当 rule を更新。
8. **stage prompt の安定 prefix**: codex へ渡す prompt は「role preamble → 静的指示 → Issue 単位の値 →
   実行ごとに変わる値（SHA / round / timestamp / notes 本文）」の順に組む。可変値を静的部分より前に
   置かない（#177。順序は `local-watcher/test/prompt_stable_prefix_test.sh` で固定）。

## 検証コマンド（変更後に必ず）

```bash
# 静的解析（警告ゼロを目指す）
shellcheck --severity=warning local-watcher/bin/*.sh local-watcher/bin/idd-codex-modules/*.sh \
  install.sh setup.sh .github/scripts/*.sh local-watcher/hooks/*.sh

# テストスイート
for t in local-watcher/test/*_test.sh; do bash "$t" || echo "FAIL: $t"; done

# 二重管理ドリフト検出（空であること）
diff -r .codex/agents repo-template/.codex/agents
diff -r .codex/rules  repo-template/.codex/rules
```
