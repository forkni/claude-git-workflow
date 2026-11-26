# No TTY means non-interactive, resolved once in config

**Status**: accepted (2026-11-26)

Each script once set `CGW_NON_INTERACTIVE=1` from its own `[[ ! -t 0 ]]` check. A script that skipped the check let `cgw_confirm` read EOF and deny every prompt silently, whatever policy the call site declared: `create_release.sh` printed "Cancelled", exited 0 and made no tag. `_config.sh` now resolves the flag once: a non-empty value in the environment wins, otherwise it is `1` when stdin is not a terminal. Scripts and `cgw_confirm` only read the flag. See [ADR-0007](0007-hermetic-non-interactive-git-env.md) for the git environment that the flag turns on.

## Considered Options

- Per-script checks (status quo): rejected, because a missed check fails silently and 13 scripts had missed it.
- A TTY test inside `cgw_confirm`: rejected, because scripts branch on the flag before any prompt (the `rollback_merge.sh` menus, the `non_interactive` derivations), and the ADR-0007 git exports would still not apply.
- Abort loudly on destructive `accept` prompts without a terminal: rejected, because agents (the main users) never have a terminal, so that would require the flag on every call. The per-site policy is already the declared non-interactive answer.

## Consequences

- With no terminal, `accept` prompts proceed, including destructive ones (`branch_cleanup.sh --execute`, `rollback_merge.sh`, `rebase_safe.sh`, auto-stash). Their other guards (`--execute`, a validated rollback target) still apply.
- `CGW_NON_INTERACTIVE=0` in the environment, or `commit_enhanced.sh --interactive`, forces prompts. A prompt that then reads EOF prints `[WARN]` and is treated as no.
- Git hooks never have a terminal on stdin, so they always run non-interactive. No hook prompts, so this is not visible.
