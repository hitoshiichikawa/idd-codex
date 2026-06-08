# idd-codex Guard Hook

`idd-codex-guard.sh` is an optional Codex CLI PreToolUse hook for local watcher runs.

It is installed by `install.sh --local` into `$HOME/.idd-codex/hooks/` and activated only when
`IDD_CODEX_HOOKS_ENABLED=true`. The watcher then loads the generated Codex profile
`${CODEX_HOME:-$HOME/.codex}/idd-codex-guard.config.toml`.

Initial deny guards:

- G0: mutation of the guard install directory or generated profile config
- G1: direct `git push` to `$BASE_BRANCH`
- G2: unconditional force push (`-f`, `--force`, or `+refspec`)

Known limits:

- Bash inspection is limited to the top-level command string. A wrapper script that performs `git push`
  internally is outside this guard's visibility.
- A bare `git push` with no literal refspec cannot be resolved to a destination branch from the command
  text alone.
