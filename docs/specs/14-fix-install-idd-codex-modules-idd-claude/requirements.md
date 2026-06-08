# Issue #14 要件定義

## 背景

idd-codex と idd-claude を同一ホストに併設すると、両者の local watcher 用モジュールが同じ `$HOME/bin/modules/` に配置され、後からインストールした側が相手の同名ファイルを上書きする。
idd-codex は本体スクリプトや prompt template では `idd-codex-` prefix により namespace されているが、モジュール配置ディレクトリだけが namespace されていない。
実運用では idd-codex の `install.sh --local` 後に idd-claude の `core_utils.sh` が idd-codex 側内容へ置き換わり、idd-claude worker が `_worktree_inject_claude: command not found` で Triage 前に停止した。
追加再現として、2026-06-09 03:39 JST に `hitoshiichikawa/feedman#164` で同じ衝突が発生し、Issue が `claude-claimed` のまま残ったため、人間が `auto-dev` / `claude-claimed` を外して停止解除した。
本 Issue は idd-codex 側のモジュール配置先と解決先を `idd-codex-modules/` へ分離し、idd-claude の既存 `$HOME/bin/modules/` を破壊しない状態に戻すことを目的とする。

## スコープ

1.1 idd-codex の local watcher 用モジュール配置先を `$HOME/bin/idd-codex-modules/` として扱う。

1.2 idd-codex watcher 起動時のモジュール解決先を watcher 本体と同階層の `idd-codex-modules/` として扱う。

1.3 repo 直実行時は `local-watcher/bin/idd-codex-modules/` を解決対象として扱う。

1.4 README や検証手順など、利用者が参照するモジュール配置先の説明を新しい配置先と矛盾しない状態にする。

1.5 既存利用者は idd-codex の再インストールにより移行を完結できる。

## スコープ外

2.1 idd-claude 側の watcher、installer、モジュール配置先、関数名、ラベル運用は変更しない。

2.2 local watcher の機能挙動、Triage / PM / Architect / Developer / Reviewer / PjM のワークフロー、ラベル遷移、exit code の意味は変更しない。

2.3 既存 env var 名、cron / launchd の起動文字列、本体スクリプト名、prompt template 名は変更しない。

2.4 `$HOME/bin/modules/` に残る idd-claude 側ファイルの復旧手順を idd-codex が代行する要件は置かない。

2.5 idd-codex のモジュール本体ロジックの機能追加・削除は行わない。

## Requirements

### Requirement 1: idd-codex local install の配置先分離

idd-codex の local install は、同一ホスト上の idd-claude と衝突しない namespace 済みディレクトリへモジュールを配置できる。

#### Acceptance Criteria

1.1 When `install.sh --local` が idd-codex の local watcher 用モジュールを配置するとき, the installer shall `$HOME/bin/idd-codex-modules/` へ配置する。

1.2 When `install.sh --local` が idd-codex の local watcher 用モジュールを配置するとき, the installer shall `$HOME/bin/modules/` へ idd-codex モジュールを配置しない。

1.3 When idd-codex と idd-claude が同一ホストへ併設インストールされるとき, the installers shall 互いのモジュールファイルを上書きしない配置先を使用する。

1.4 While idd-claude が `$HOME/bin/modules/` を使用しているとき, the idd-codex local install shall idd-claude 側の `$HOME/bin/modules/` を idd-codex の配置先として扱わない。

### Requirement 2: watcher 起動時のモジュール解決

idd-codex watcher は、インストール後と repo 直実行の双方で、watcher 本体の配置場所を基準に idd-codex 専用モジュールを解決できる。

#### Acceptance Criteria

2.1 When `$HOME/bin/idd-codex-issue-watcher.sh` が起動するとき, the watcher shall `$(dirname BASH_SOURCE)/idd-codex-modules` を idd-codex モジュール解決先として扱う。

2.2 When `$HOME/bin/idd-codex-issue-watcher.sh` が起動するとき, the watcher shall `$HOME/bin/modules/` を idd-codex モジュール解決先として扱わない。

2.3 When `local-watcher/bin/idd-codex-issue-watcher.sh` を repo 直下で直接実行するとき, the watcher shall `local-watcher/bin/idd-codex-modules/` を idd-codex モジュール解決先として扱う。

2.4 If idd-codex の必須モジュールが `idd-codex-modules/` に存在しないとき, the watcher shall 起動失敗を利用者が識別できるエラーとして示す。

### Requirement 3: 移行と後方互換

既存利用者は idd-codex の再インストールだけで新しい配置先へ移行でき、既存の watcher 運用契約を変えずに利用を継続できる。

#### Acceptance Criteria

3.1 When 既存利用者が idd-codex を再インストールするとき, the installer shall idd-codex watcher が必要とするモジュールを新しい `$HOME/bin/idd-codex-modules/` 配置で利用可能にする。

3.2 When 既存の cron または launchd が `$HOME/bin/idd-codex-issue-watcher.sh` を起動するとき, the watcher shall 起動文字列の変更なしに新しいモジュール配置先を使用できる。

3.3 When モジュール配置先変更が適用されるとき, the idd-codex workflow shall Triage 以降の機能挙動を変更しない。

3.4 When モジュール配置先変更が適用されるとき, the idd-codex workflow shall 既存 env var 名、ラベル名、exit code 意味を変更しない。

3.5 While `$HOME/bin/modules/` に旧 idd-codex モジュールが残っているとき, the watcher shall その旧配置を idd-codex の実行時モジュールとして要求しない。

### Requirement 4: ドキュメントと検証可能性

利用者とレビュワーは、idd-codex 専用モジュール配置先、repo 直実行時の解決先、併設時の衝突回避をドキュメントと検証結果から確認できる。

#### Acceptance Criteria

4.1 When README または関連する運用ドキュメントが local watcher モジュール配置先を説明するとき, the documentation shall `$HOME/bin/idd-codex-modules/` と watcher 同階層の `idd-codex-modules/` を示す。

4.2 When README または関連する運用ドキュメントが旧 `$HOME/bin/modules/` を idd-codex の配置先として説明しているとき, the documentation shall その説明を残さない。

4.3 When regression verification が `install.sh --local` の配置結果を確認するとき, the verification shall idd-codex モジュールが `$HOME/bin/idd-codex-modules/` に配置されることを確認する。

4.4 When regression verification が `install.sh --local` の配置結果を確認するとき, the verification shall idd-codex モジュールが `$HOME/bin/modules/` に配置されないことを確認する。

4.5 When regression verification が repo 直実行を確認するとき, the verification shall watcher が `local-watcher/bin/idd-codex-modules/` を解決して起動できることを確認する。

## Non-Functional Requirements

### NFR 1: 併設安全性

1.1 When idd-codex と idd-claude が同一 `$HOME/bin` 配下に併設されるとき, the idd-codex install and watcher shall idd-claude の `$HOME/bin/modules/` を変更前提または実行前提にしない。

1.2 When feedman の 2026-06-09 03:39 JST 再現条件と同等の併設状態で idd-codex を再インストールするとき, the idd-codex install shall idd-claude の `core_utils.sh` を idd-codex 側内容で上書きしない。

### NFR 2: 冪等性

2.1 When `install.sh --local` を複数回実行するとき, the installer shall `$HOME/bin/idd-codex-modules/` を再利用して idd-codex の local watcher 用モジュール配置を完了する。

2.2 When `install.sh --local` を複数回実行するとき, the installer shall 既存の idd-codex local watcher 起動契約を変えない。

### NFR 3: 観測可能性

3.1 If idd-codex モジュール配置または読み込みに失敗するとき, the installer or watcher shall 利用者が不足している配置先を識別できるエラーを出す。

## Open Questions

- なし。

## Issue コメント反映

- 2026-06-09 03:39 JST に `hitoshiichikawa/feedman#164` で発生した idd-claude worker 停止を背景と NFR 1.2 に反映した。
- `core_utils.sh` が idd-codex 側内容へ上書きされ、idd-claude の `_worktree_inject_claude` が欠落した観測を、idd-claude 側 `$HOME/bin/modules/` を変更前提にしない要件へ反映した。
- feedman 側の順次 `auto-dev` は #14 の修正を install 済みにして idd-claude の `$HOME/bin/modules/` を復旧するまで進めない、という人間判断を、再インストールで idd-codex 側移行が完結する要件へ反映した。
- Triage edit_paths の自動コメントにより、編集見込み top-level path は `local-watcher/`、`install.sh`、`README.md`、`.codex/rules/`、`repo-template/` と認識した。

## PM 自己レビュー

- Mechanical Checks: numeric ID 見出し、各 Requirement / NFR の EARS 形式 AC、Out of Scope の存在を確認した。
- 判断レビュー: Issue 本文の受入基準候補、idd-claude 併設時の衝突回避、`install.sh --local` の配置先、watcher の `BASH_SOURCE` 基準解決、repo 直実行、再インストール移行、機能挙動不変、idd-claude 側変更なし、人間コメントの feedman 再現を網羅していることを確認した。
- 実装方針レビュー: 要件は observable な配置先・解決先・移行結果に限定し、具体的な実装手順や設計分割は記載していないことを確認した。
