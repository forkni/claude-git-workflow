# Hermetic Non-Interactive Git Environment & Concurrency Controls

**Status**: accepted

## Context

Retrospective analysis over 11 historical agent sessions in `claude-git-workflow` revealed three repeating failure modes:

1. **Index lock collisions (`index.lock`)**: 26 recorded collision incidents caused by parallel test execution, background monitoring daemons, and IDE tasks contending for `.git/index.lock` during read-only status and diff queries.
2. **Non-interactive agent freezes**: Agent sessions freezing indefinitely when Git operations unexpectedly launched terminal prompts (`GIT_TERMINAL_PROMPT`), interactive pagers (`GIT_PAGER`), or text editors (`GIT_EDITOR`, `GIT_SEQUENCE_EDITOR`).
3. **Host environment contamination in test suites**: Bats test runs inheriting user `~/.gitconfig` or system `/etc/gitconfig` settings (e.g. commit GPG signing, custom hooks, diff drivers) or climbing directory hierarchies into outer workspaces.
4. **Reflog provenance ambiguity**: Native Git reflogs recording generic `commit` or `reset` actions, making automated CGW operations indistinguishable from manual user operations during disaster recovery.

## Decision

- **Optional Lock Suppression**: When running in non-interactive/agent mode (`CGW_NON_INTERACTIVE=1`), or within the test harness (`setup.bash`), export `GIT_OPTIONAL_LOCKS=0`. This instructs Git to skip stat-cache refresh and optional lock acquisition on read-only queries (`git status`, `git diff-index`, `git rev-parse`), eliminating index lock collisions without weakening mandatory locks for mutating commands (`git commit`, `git merge`, `git checkout`).
- **Non-Interactive Discipline**: When `CGW_NON_INTERACTIVE=1` is set, `_config.sh` exports `GIT_TERMINAL_PROMPT=0` (fails fast on credential requests), `GIT_PAGER=cat` (disables pagination blocks), `GIT_EDITOR=:` and `GIT_SEQUENCE_EDITOR=:` (allows automated merges/commits with explicit messages to complete while causing empty-message bare commits to abort cleanly).
- **Reflog Action Provenance**: All mutating wrapper scripts (`commit_enhanced.sh`, `merge_with_validation.sh`, `rebase_safe.sh`, `cherry_pick_commits.sh`, `rollback_merge.sh`, `undo_last.sh`) invoke `cgw_set_reflog_action "<script_basename>"`, prepending `cgw:` to Git's native reflog entries. `recover.sh reflog` adds `--cgw-only` filtering via `git reflog --grep-reflog="^cgw:"`, and `undo_last.sh` inspects the provenance tag when previewing undo operations.
- **Hermetic Test Isolation**: `tests/helpers/setup.bash` unconditionally exports `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CEILING_DIRECTORIES`, and deterministic `GIT_AUTHOR_*` / `GIT_COMMITTER_*` variables, ensuring tests run in complete isolation from the host machine's Git setup.
- **Windows Pathspec Consistency**: On Windows environments, `_config.sh` automatically exports `GIT_ICASE_PATHSPECS=1` to align Git pathspec evaluation with NTFS filesystem semantics, overridable via `CGW_ICASE_PATHSPECS=0`.

## Considered and rejected

- **Unconditional `GIT_OPTIONAL_LOCKS=0` for all Git executions**: Rejected because human developers running manual Git commands in standard terminal sessions expect `git status` to refresh the index stat cache.
- **Fail-closed `GIT_EDITOR=false`**: Rejected because commands like `git merge` invoke the editor to confirm auto-generated merge messages; setting `false` breaks legitimate automated merges that should accept standard messages. Setting `:` allows clean merge completions while still aborting empty commit messages.
- **Ad-hoc reflog parsing without `GIT_REFLOG_ACTION`**: Parsing unstructured commit subjects or backup tags fails when commits are rebased or tags are pruned. `GIT_REFLOG_ACTION` is Git's native, tamper-evident provenance mechanism.

## Consequences

- Read-only inspection commands no longer produce or collide on `.git/index.lock` in parallel test suites and background agent runs.
- Agent command invocations will never hang indefinitely on interactive prompts or pagers; unauthenticated operations fail immediately with actionable exit codes.
- Tests behave identically on CI and local development machines, immune to host Git configuration drift.
- Native reflogs now provide an unambiguous audit trail of every CGW wrapper mutation.
