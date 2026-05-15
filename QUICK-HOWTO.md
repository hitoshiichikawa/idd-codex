# Quick How-to

## 1. Install

```bash
./install.sh --repo /path/to/consumer-repo --local
```

This installs Codex-specific files only. It does not overwrite `CLAUDE.md`, `.claude/`, or idd-claude workflows.

## 2. Create Labels

```bash
bash /path/to/consumer-repo/.github/scripts/idd-codex-labels.sh
```

Created labels include `codex-auto-dev`, `codex-claimed`, `codex-picked-up`, `codex-ready-for-review`, `codex-failed`, and other `codex-*` state labels.

## 3. Configure Cron

```cron
*/2 * * * * PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin REPO=owner/repo REPO_DIR=$HOME/work/repo /usr/bin/env bash -lc '$HOME/bin/idd-codex-issue-watcher.sh' >> $HOME/.idd-codex/issue-watcher/cron.log 2>&1
```

If Codex is not on `PATH`, add `CODEX_BIN=/absolute/path/to/codex`.
The watcher requires Bash 4.3+; on macOS, make sure launchd/cron finds a newer Bash before `/bin/bash`.

## 4. Start an Issue

Use the `idd-codex-feature.yml` Issue template or manually add `codex-auto-dev`.

Do not add `auto-dev` to the same Issue unless you intentionally want idd-claude to handle it. If both triggers are present, Codex stops with `codex-failed` to prevent double execution.

## 5. Watch Progress

```bash
tail -f $HOME/.idd-codex/issue-watcher/cron.log
ls $HOME/.idd-codex/issue-watcher/logs/
```

Typical labels:

```text
codex-auto-dev
codex-claimed
codex-picked-up
codex-ready-for-review
```

Design-gated issues use `codex-awaiting-design-review` until the design PR is merged and the label is removed.
