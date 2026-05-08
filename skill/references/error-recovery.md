# Error Recovery

## PreToolUse Guardrail

If Claude Code blocks a command with `BLOCKED: ...`, the CGW harness guardrail is active. The block message includes a redirect to the correct CGW wrapper script.

**Block message format:**
```
BLOCKED: Command matched dangerous pattern "<pattern>".
<redirect — the CGW wrapper to use instead>
The user has prevented you from doing this.
```

**Normal response:** follow the redirect. For example, replace `git commit -m "..."` with `./scripts/git/commit_enhanced.sh "..."`.

**Temporary disable** (current shell session only):
```bash
export SKIP_CGW_GUARDRAIL=1
# Run your command
unset SKIP_CGW_GUARDRAIL
```

**Permanent uninstall:**
1. Remove the PreToolUse entry from `.claude/settings.json` (delete the object whose `command` contains `cc-block-dangerous-git`)
2. Delete `.claude/hooks/cc-block-dangerous-git.sh`

**Reinstall:** re-run `./scripts/git/configure.sh` and answer yes to the guardrail prompt.

---

## Lint Failures

**Auto-fix and retry:**
```bash
./scripts/git/fix_lint.sh       # Auto-fix
./scripts/git/check_lint.sh     # Verify fixed
./scripts/git/commit_enhanced.sh "feat: your message"  # Retry commit
```

**If no linter is configured** (`CGW_LINT_CMD=""`): lint steps are skipped automatically.

**Markdown lint on local-only files**: ignore — `CLAUDE.md`, `MEMORY.md`, etc. are never committed.

---

## Push Failures

**Use `push_validated.sh` for all pushes** — it provides better error context:
```bash
./scripts/git/push_validated.sh
```

Common failures and fixes:
1. **Remote has diverged**: `./scripts/git/sync_branches.sh` then retry push
2. **Auth failure**: check SSH key or token configuration
3. **Branch protection**: resolve via PR workflow
4. **Behind remote**: `./scripts/git/sync_branches.sh` to pull --rebase before pushing

**Raw fallback** (if push_validated.sh unavailable):
```bash
git pull --rebase origin <branch>
git push origin <branch>
```

---

## Merge Rollback

When you need to undo a merge to the target branch:

```bash
# Interactive (shows options):
./scripts/git/rollback_merge.sh

# Non-interactive (auto-selects latest backup tag):
./scripts/git/rollback_merge.sh --non-interactive

# Dry-run (shows target without resetting):
./scripts/git/rollback_merge.sh --dry-run

# Specific target:
./scripts/git/rollback_merge.sh --non-interactive --target pre-merge-20260101_120000-12345
```

Interactive mode prompts for rollback target:
1. Latest `pre-merge-*` tag (recommended)
2. `HEAD~1` (commit before merge)
3. Specific commit hash

Requires typing `ROLLBACK` to confirm (interactive mode). Force-push warning shown afterward.

**Safe revert (preserves history — preferred for shared/already-pushed branches):**
```bash
# Creates a new revert commit instead of resetting — no force-push needed:
./scripts/git/rollback_merge.sh --revert

# Revert a specific merge commit (requires merge commit hash):
./scripts/git/rollback_merge.sh --revert --target <merge-commit-hash>
```

**Manual rollback** (if script unavailable):
```bash
git checkout main
git reset --hard pre-merge-<timestamp>-<pid>
git checkout development
```

---

## Branch Sync Issues

If local and remote have diverged:
```bash
./scripts/git/sync_branches.sh           # sync current branch
./scripts/git/sync_branches.sh --all     # sync both source and target branches
```

If rebase fails (conflicting local commits):
```bash
git rebase --abort      # abort the failed rebase
git status              # check current state
# Resolve conflicts manually, then:
git rebase --continue
```

---

## Rebase Issues (rebase_safe.sh)

If `rebase_safe.sh` hits conflicts mid-rebase:
```bash
# Resolve conflicting files, then:
git add <resolved-files>
./scripts/git/rebase_safe.sh --continue

# To abandon the rebase entirely:
./scripts/git/rebase_safe.sh --abort

# To skip the conflicting commit:
./scripts/git/rebase_safe.sh --skip
```

Restore from backup tag if needed:
```bash
git checkout pre-rebase-<timestamp>-<pid>
```

---

## Bisect Stuck Session

If a `bisect_helper.sh` session gets interrupted or abandoned:
```bash
./scripts/git/bisect_helper.sh --abort   # resets bisect and returns to original branch
```

Restore from backup tag if needed:
```bash
git checkout pre-bisect-<timestamp>-<pid>
```

---

## Undo Operations

Use `undo_last.sh` to recover from common commit mistakes:
```bash
# Undo most recent commit (changes remain staged):
./scripts/git/undo_last.sh commit

# Remove a file from the staging area:
./scripts/git/undo_last.sh unstage src/file.py

# Fix a commit message (local only — don't use after pushing):
./scripts/git/undo_last.sh amend-message "fix: correct description"
```

Each operation creates a backup tag (`pre-undo-commit-*`) before acting.

---

## No Changes to Commit

`commit_enhanced.sh` checks for changes before committing. If no changes exist, it exits cleanly — not an error. Check with:
```bash
git diff --quiet && git diff --cached --quiet && echo "No changes"
```

---

## Lock File Auto-Recovery

CGW scripts automatically detect and remove stale `.git/index.lock` files left by crashed git processes. When auto-recovery fires you will see `[cgw-lock] Removing stale index.lock (age Xs)` in the script's output.

### How auto-recovery decides

| Step | Logic |
|---|---|
| 1. No lock file | Returns 0 immediately (common path). |
| 2. Op-state guard | Refuses if `.git/rebase-merge/`, `.git/rebase-apply/`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, or `BISECT_LOG` exists — an interactive git operation is in progress, removing the lock would corrupt it. |
| 3. Age check | Computes mtime. If `age >= CGW_INDEX_LOCK_MAX_AGE_SECONDS` (default 30s) → stale. |
| 4. Wait window | If fresh, polls for up to `CGW_INDEX_LOCK_WAIT_SECONDS` (default 10s). If lock clears → done. If lock ages past threshold during wait → remove. If still fresh → refuse (exit 1). |
| 5. Remove or refuse | If `CGW_AUTO_REMOVE_INDEX_LOCK=1` (default) → remove and log. If `0` → warn and exit 1. |

### Config variables

| Variable | Default | Purpose |
|---|---|---|
| `CGW_AUTO_REMOVE_INDEX_LOCK` | `1` | `0` = warn-only; `1` = auto-remove stale locks |
| `CGW_INDEX_LOCK_MAX_AGE_SECONDS` | `30` | Seconds after which a lock is considered stale |
| `CGW_INDEX_LOCK_WAIT_SECONDS` | `10` | Max seconds to poll for a fresh lock to clear |

### Known edge case: long-paused interactive rebase

If you run `git rebase -i` in a separate terminal and leave the editor open for more than `CGW_INDEX_LOCK_MAX_AGE_SECONDS` seconds **before** git has written the rebase-merge state directory (i.e. before the editor even appears), the lock might age past the threshold. To prevent any risk of interruption for long editing sessions:

```bash
# In .cgw.conf or environment — give up to 5 minutes
CGW_INDEX_LOCK_MAX_AGE_SECONDS=300
```

### Manual removal (when auto-recovery refuses)

Use the worktree-aware path — `.git/index.lock` is not always the correct path in git worktrees:

```bash
rm -f "$(git rev-parse --git-dir)/index.lock"
```

If the script still reports "lock held by another process", find and stop the other git session or wait for it to complete.

---

## Log Files

All scripts write to `logs/` directory (excluded from commits):

| Script | Log Pattern |
|--------|-------------|
| `commit_enhanced.sh` | `logs/commit_enhanced_YYYYMMDD_HHMMSS.log` |
| `check_lint.sh` | `logs/check_lint_YYYYMMDD_HHMMSS.log` |
| `fix_lint.sh` | `logs/fix_lint_YYYYMMDD_HHMMSS.log` |
| `merge_with_validation.sh` | `logs/merge_with_validation_YYYYMMDD_HHMMSS.log` |
| `rollback_merge.sh` | `logs/rollback_merge_YYYYMMDD_HHMMSS.log` |
| `cherry_pick_commits.sh` | `logs/cherry_pick_commits_YYYYMMDD_HHMMSS.log` |
| `merge_docs.sh` | `logs/merge_docs_YYYYMMDD_HHMMSS.log` |
| `validate_branches.sh` | `logs/validate_branches_YYYYMMDD_HHMMSS.log` |
| `push_validated.sh` | `logs/push_validated_YYYYMMDD_HHMMSS.log` |
| `sync_branches.sh` | `logs/sync_branches_YYYYMMDD_HHMMSS.log` |
| `create_pr.sh` | `logs/create_pr_YYYYMMDD_HHMMSS.log` |
| `install_hooks.sh` | `logs/install_hooks_YYYYMMDD_HHMMSS.log` |
| `bisect_helper.sh` | `logs/bisect_helper_YYYYMMDD_HHMMSS.log` |
| `rebase_safe.sh` | `logs/rebase_safe_YYYYMMDD_HHMMSS.log` |
| `undo_last.sh` | `logs/undo_last_YYYYMMDD_HHMMSS.log` |
