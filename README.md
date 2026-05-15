# idd-codex

GitHub Issue を起点に Codex CLI で要件整理、設計、実装、レビュー、PR 作成を進めるローカル watcher です。

idd-codex は idd-claude と同じ consumer repository に併存できるよう、ラベル、branch、watcher、prompt、インストール先を分離しています。

## Coexistence Contract

| 項目 | idd-codex | idd-claude |
|---|---|---|
| Issue trigger | `codex-auto-dev` | `auto-dev` |
| 状態ラベル | `codex-*` | `claude-*` / shared legacy labels |
| branch | `codex/issue-<N>-...` | `claude/issue-<N>-...` |
| repo instructions | `AGENTS.md`, `.codex/` | `CLAUDE.md`, `.claude/` |
| watcher | `~/bin/idd-codex-issue-watcher.sh` | `~/bin/issue-watcher.sh` or Claude-specific watcher |
| local state | `$HOME/.idd-codex/issue-watcher/` | `$HOME/.issue-watcher/` |

Codex watcher は `auto-dev` を処理しません。同じ Issue に `auto-dev` と `codex-auto-dev` が両方付いた場合、二重実行を避けるため Codex 側だけ `codex-failed` で停止します。

## Installed Files

Consumer repo:

- `AGENTS.md`
- `.codex/agents/*.md`
- `.codex/rules/*.md`
- `.github/ISSUE_TEMPLATE/idd-codex-feature.yml`
- `.github/scripts/idd-codex-labels.sh`

Local machine:

- `~/bin/idd-codex-issue-watcher.sh`
- `~/bin/idd-codex-triage-prompt.tmpl`
- `~/bin/idd-codex-iteration-prompt.tmpl`
- `~/bin/idd-codex-iteration-prompt-design.tmpl`
- `~/Library/LaunchAgents/com.local.idd-codex-issue-watcher.plist` on macOS

GitHub Actions are intentionally not installed yet. The Codex port uses the local watcher path until an official Actions execution path is verified.

## Requirements

- `gh` authenticated for the target repository
- `jq`
- `git`
- `flock` and `timeout`
- Bash 4.3+ for the local watcher (`declare -A` and `wait -n` are used). macOS `/bin/bash` 3.2 is not sufficient; install a newer Bash and ensure cron/launchd resolves it first in `PATH`, or adjust the watcher shebang.
- `codex` CLI authenticated

If your `codex` binary is not on `PATH`, set `CODEX_BIN=/absolute/path/to/codex` in cron or launchd.

## Install

Clone or update this repository, then run:

```bash
./install.sh --repo /path/to/consumer-repo --local
```

Create labels:

```bash
bash /path/to/consumer-repo/.github/scripts/idd-codex-labels.sh
```

For cron:

```cron
*/2 * * * * PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin REPO=owner/repo REPO_DIR=$HOME/work/repo /usr/bin/env bash -lc '$HOME/bin/idd-codex-issue-watcher.sh' >> $HOME/.idd-codex/issue-watcher/cron.log 2>&1
```

For macOS launchd, edit:

```bash
$EDITOR ~/Library/LaunchAgents/com.local.idd-codex-issue-watcher.plist
launchctl load ~/Library/LaunchAgents/com.local.idd-codex-issue-watcher.plist
launchctl start com.local.idd-codex-issue-watcher
```

## Workflow

1. Create an Issue using `idd-codex-feature.yml`, or add `codex-auto-dev` manually.
2. Watcher claims it with `codex-claimed`.
3. Triage writes a JSON decision.
4. If human decisions are needed, watcher adds `codex-needs-decisions`.
5. If design is needed, Codex creates a design PR from `codex/issue-<N>-design-<slug>` and adds `codex-awaiting-design-review`.
6. Otherwise Codex implements on `codex/issue-<N>-impl-<slug>`, runs reviewer gate, then creates an implementation PR and adds `codex-ready-for-review`.

## Main Configuration

| Env var | Default | Purpose |
|---|---|---|
| `REPO` | `owner/your-repo` | GitHub repo |
| `REPO_DIR` | `$HOME/work/your-repo` | Local clone |
| `BASE_BRANCH` | `main` | PR base |
| `CODEX_BIN` | `codex` | Codex CLI path |
| `TRIAGE_MODEL` | `gpt-5.4-mini` | Triage model |
| `DEV_MODEL` | `gpt-5.5` | Development model |
| `REVIEWER_MODEL` | `gpt-5.5` | Reviewer model |
| `PR_ITERATION_ENABLED` | `false` | Process `codex-needs-iteration` PRs |
| `DESIGN_REVIEW_RELEASE_ENABLED` | `false` | Remove `codex-awaiting-design-review` after merged design PR |
| `MERGE_QUEUE_ENABLED` | `false` | Rebase approved Codex PRs |
| `PARALLEL_SLOTS` | `1` | Issue processing parallelism |

## Verification

```bash
bash -n local-watcher/bin/idd-codex-issue-watcher.sh
bash -n install.sh setup.sh .github/scripts/idd-codex-labels.sh
bash local-watcher/test/parse_review_result_test.sh
bash local-watcher/test/qa_detect_rate_limit_test.sh
bash local-watcher/test/qa_run_codex_stage_test.sh
bash local-watcher/test/stagec_pr_verify_test.sh
bash local-watcher/test/stagec_pr_verify_retry_test.sh
bash local-watcher/test/verify_pushed_or_retry_test.sh
```
