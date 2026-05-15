# idd-codex Development Guide

This repository contains the Codex port of the issue-driven development workflow.
The implementation must coexist with idd-claude in the same consumer repository.

## Namespace Contract

- Codex issue trigger: `codex-auto-dev`
- Claude issue trigger: `auto-dev`
- Codex state labels use the `codex-*` namespace.
- Codex branches use `codex/issue-<number>-...`.
- Codex repository instructions are installed as `AGENTS.md` and `.codex/`.
- Codex local watcher is installed as `~/bin/idd-codex-issue-watcher.sh`.
- Codex local state is stored under `$HOME/.idd-codex/issue-watcher/`.

Do not make Codex read or mutate idd-claude labels, branches, workflows, or files except for the explicit namespace-conflict guard that stops Codex when both triggers are on the same Issue.

## Key Files

- `local-watcher/bin/idd-codex-issue-watcher.sh`: local polling watcher and state machine.
- `local-watcher/bin/idd-codex-*.tmpl`: prompt templates installed to `~/bin`.
- `repo-template/AGENTS.md`: consumer repository instruction template.
- `repo-template/.codex/agents/*.md`: role instructions used by watcher prompts.
- `repo-template/.codex/rules/*.md`: role-specific rules.
- `.github/scripts/idd-codex-labels.sh`: label bootstrap script.
- `.github/ISSUE_TEMPLATE/idd-codex-feature.yml`: Codex-specific issue template.

## Implementation Rules

- Prefer small, targeted shell changes. This codebase is bash-heavy; keep dependencies to `gh`, `jq`, `git`, `flock`, `timeout`, and `codex`.
- Preserve existing label transition semantics unless intentionally namespacing them for Codex.
- When editing watcher behavior, update the corresponding tests under `local-watcher/test`.
- Keep GitHub Actions out of the installed template until an official, verified Codex Actions path is added.
- For Codex CLI execution, use `codex exec` through the watcher wrapper rather than direct ad hoc calls.

## Verification

Run these before handing off watcher changes:

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

