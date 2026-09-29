# Decouple template source from target repository root and prune legacy staging directories

**Status**: accepted

## Context

Historically, the Windows installers (`cgw-install.cmd` and `cgw-batch-install.cmd`) staged template directories (`hooks/`, `skill/`, `command/`, `templates/`) directly into the root directory of consumer repositories before invoking `scripts/git/configure.sh`. This was required because `configure.sh` hardcoded a relative lookup (`${SCRIPT_DIR}/../../hooks`, etc.) against its own location.

To prevent destructive deletion of a consumer repository's own legitimate files (e.g., a web project carrying its own `templates/` or `hooks/` directory), PR #12 introduced a pre-existence probe (`HOOKS_PREEXISTED=1`) that skipped post-install cleanup and emitted a `[WARN]` whenever a staging directory was already present before staging began.

However, because this check was a simple existence test, it created a permanent failure latch:

1. If an installation was ever interrupted, or if post-install cleanup was declined, the staging folders remained on disk.
2. On every subsequent run of `cgw-batch-install.cmd`, the directories were detected as pre-existing *before* staging started.
3. The cleanup routine refused to delete them and emitted `[WARN] ... pre-existed -- left in place, not deleted`.
4. The directories remained on disk, causing the exact same warnings to recur indefinitely across all future batch update runs (as observed in `claude-dotfiles`).

## Decision

CGW completely decouples template sourcing from the consumer repository's root directory:

1. **`configure.sh` template source resolution**:
   `configure.sh` accepts an explicit `--template-dir <path>` argument and respects the `CGW_TEMPLATE_DIR` environment variable. Template discovery follows a deterministic priority chain:
   - `--template-dir <path>` CLI argument.
   - `CGW_TEMPLATE_DIR` environment variable.
   - Sibling/parent source check (`${SCRIPT_DIR}/../../hooks`, etc. — active when running inside the CGW source repository itself).
   - Already-installed asset fallback (retaining or validating existing target configurations when no template source is provided).

2. **Elimination of in-repo staging in `.cmd` installers**:
   Both `cgw-batch-install.cmd` and `cgw-install.cmd` pass `--template-dir "!CGW_DIR!"` directly to `configure.sh`. The temporary staging copies of `hooks\`, `skill\`, `command\`, and `templates\` into the target project root are eliminated entirely. The pre-existence probes, `[WARN]` outputs, and the interactive "Remove temporary install files?" prompt in `cgw-install.cmd` are removed. Only the runtime scripts in `scripts/git/*.sh` are placed into the target project.

3. **Safe automated pruning of legacy staging artifacts**:
   To self-heal existing consumer repositories that already carry stale staging directories, `_cleanup_legacy_artifacts()` in `configure.sh` safely detects and removes root-level `hooks/`, `skill/`, `command/`, and `templates/` if and only if:
   - The current project is not the CGW source repository itself (`PROJECT_ROOT != CGW source repo`).
   - The directories contain recognized CGW template signatures (e.g. `skill/SKILL.md` with `name: auto-git-workflow`, `command/auto-git-workflow-cmd.md` with `name: auto-git-workflow-cmd`, `templates/markdownlint.json`, `hooks/pre-commit` containing `Part of claude-git-workflow`) and contain no foreign project files.

## Considered and rejected: surgical manifest-based in-repo staging cleanup

The alternative of retaining in-repo staging while tracking copied files via a manifest and deleting only those files was rejected. Copying transient files into a consumer project's working tree is fundamentally polluting: it creates untracked file noise, risks accidental commits, and can trigger false positives in consumer build tools, linters, or file watchers before cleanup finishes.

## Considered and rejected: stage into an OS temporary directory

Staging into `%TEMP%\cgw-stage-<pid>\` and pointing `configure.sh` there was rejected. The canonical template files already exist in `CGW_DIR` (`F:\RD_PROJECTS\COMPONENTS\claude-git-workflow`); creating, copying, and tearing down intermediate folders in `%TEMP%` introduces unnecessary filesystem I/O, process complexity, and potential file-locking issues on Windows with zero added benefit over reading `CGW_DIR` directly.

## Consequences

- Consumer repositories remain completely free of transient staging directories in their root working tree.
- Batch updates across consumer repositories are faster, non-polluting, and cannot latch into recursive `[WARN]` states.
- Existing consumer projects carrying orphan staging files (such as `claude-dotfiles`) are automatically cleaned up on their next configuration run without manual developer intervention.
- Standalone invocations of `configure.sh` within consumer repositories continue to function cleanly by falling back to already-installed assets when reconfiguring settings, or accepting `--template-dir` when refreshing from an external toolkit source.
