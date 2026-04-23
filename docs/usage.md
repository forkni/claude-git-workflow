# Usage Guide

## Branch Setup (one-time)

CGW uses a two-branch model. Create `development` before starting work:

```bash
git checkout -b development
git push -u origin development
```

> **Note:** `git push -u origin development` above is a one-time bootstrap exception — CGW isn't configured yet at this point so the wrapper scripts aren't available. All subsequent pushes should use `./scripts/git/push_validated.sh`.

Keep `main` as the GitHub default branch. Charlie reads its config from the default branch.

---

## Commit Message Format

Conventional commit format (enforced by `commit_enhanced.sh`):

```
feat: add user authentication
fix: resolve memory leak in pipeline
docs: update API reference
chore: bump dependencies
test: add unit tests for parser
refactor: extract validation logic
style: fix formatting
perf: optimize image resizing
```

Add project-specific prefixes via `CGW_EXTRA_PREFIXES="cuda|tensorrt"` in `.cgw.conf`.

---

## Common Operations

### Commit with lint validation

```bash
# Auto-detect .venv
./scripts/git/commit_enhanced.sh "feat: add feature"

# Skip .venv (use system lint tool)
./scripts/git/commit_enhanced.sh --no-venv "feat: add feature"

# Non-interactive (CI/CD, Claude Code)
./scripts/git/commit_enhanced.sh --non-interactive "feat: add feature"

# Stage only specific paths, then commit
./scripts/git/commit_enhanced.sh --only src/foo.py --only src/bar.py "fix: narrow fix"

# Commit pre-staged files only (skip auto-staging)
./scripts/git/commit_enhanced.sh --staged-only "fix: pre-staged only"

# Force-stage all tracked changes (override pre-staged respect)
./scripts/git/commit_enhanced.sh --all "chore: bulk update"

# Skip lint checks (all)
./scripts/git/commit_enhanced.sh --skip-lint "feat: add feature"

# Skip markdown lint only
./scripts/git/commit_enhanced.sh --skip-md-lint "docs: update readme"

# Force interactive mode even without a TTY
./scripts/git/commit_enhanced.sh --interactive "feat: review before commit"
```

**Staging behaviour (non-interactive):**
- Pre-staged files exist + unstaged changes exist → commits pre-staged only (warns about skipped files). Use `--all` to override.
- Nothing pre-staged → auto-stages all tracked changes (legacy behaviour).
- `--only <path>` → resets index, stages listed paths only.

### Merge to target branch (direct)

```bash
./scripts/git/merge_with_validation.sh --dry-run          # preview
./scripts/git/merge_with_validation.sh --non-interactive  # execute
```

### Merge / cherry-pick / PR with custom branch pair

All four promotion scripts accept `--source`/`--target` to override the configured branch pair for a single invocation without modifying `.cgw.conf`:

```bash
# Merge hotfix → release branch (not the usual development → main)
./scripts/git/merge_with_validation.sh --source feature/hotfix --target release/1.2 --dry-run
./scripts/git/merge_with_validation.sh --source feature/hotfix --target release/1.2 --non-interactive

# Cherry-pick to a release branch
./scripts/git/cherry_pick_commits.sh --source feature/hotfix --target release/1.2 --commit abc1234

# Docs-only merge to a custom target
./scripts/git/merge_docs.sh --source feature/hotfix --target release/1.2 --non-interactive

# Open PR for a non-default pair
./scripts/git/create_pr.sh --source feature/hotfix --target release/1.2 --dry-run
```

The overrides are ephemeral — they do not mutate `CGW_SOURCE_BRANCH` / `CGW_TARGET_BRANCH` in config.

### Create PR (triggers Charlie CI + GitHub Actions)

```bash
./scripts/git/create_pr.sh --dry-run          # preview title + commits
./scripts/git/create_pr.sh                    # interactive — confirm title
./scripts/git/create_pr.sh --non-interactive  # accept auto-generated title
./scripts/git/create_pr.sh --draft            # open as draft (skip auto-review)
```

Requires: `gh` CLI installed and authenticated (`gh auth login`).
Set `CGW_MERGE_MODE="pr"` in `.cgw.conf` to use PRs by default.

### Push

```bash
./scripts/git/push_validated.sh               # with lint check
./scripts/git/push_validated.sh --skip-lint   # skip all lint
./scripts/git/push_validated.sh --skip-md-lint  # skip markdown lint only
./scripts/git/push_validated.sh --dry-run     # preview
./scripts/git/push_validated.sh --no-venv     # use system lint tool (no .venv)
./scripts/git/push_validated.sh --branch hotfix/1.2  # push a different branch
```

### Sync with remote

```bash
./scripts/git/sync_branches.sh              # sync current branch
./scripts/git/sync_branches.sh --all        # sync both source and target branches
./scripts/git/sync_branches.sh --branch main  # sync a specific branch
./scripts/git/sync_branches.sh --dry-run    # preview (fetch only, no merge)
./scripts/git/sync_branches.sh --prune      # also remove stale remote-tracking refs
```

### Rollback a merge

```bash
./scripts/git/rollback_merge.sh                           # interactive (hard reset)
./scripts/git/rollback_merge.sh --revert                  # safe revert (preserves history, no force-push)
./scripts/git/rollback_merge.sh --non-interactive         # auto-select latest backup
./scripts/git/rollback_merge.sh --target pre-merge-backup-20260101_120000-12345
```

### Cherry-pick

```bash
./scripts/git/cherry_pick_commits.sh                   # interactive
./scripts/git/cherry_pick_commits.sh --commit abc1234  # non-interactive
```

### Stash work in progress

```bash
./scripts/git/stash_work.sh push "wip: half-done refactor"
./scripts/git/stash_work.sh list
./scripts/git/stash_work.sh pop
./scripts/git/stash_work.sh apply stash@{1}   # apply without removing
```

### Create a release

```bash
./scripts/git/create_release.sh v1.2.3            # tag only
./scripts/git/create_release.sh v1.2.3 --push     # tag + push (triggers release.yml)
./scripts/git/create_release.sh v1.2.3 --dry-run  # preview
```

### Configure .gitattributes (Python, TouchDesigner, GLSL)

```bash
./scripts/git/setup_attributes.sh --dry-run   # preview
./scripts/git/setup_attributes.sh             # write .gitattributes
```

### Clean build artifacts

```bash
./scripts/git/clean_build.sh                  # dry-run (safe preview)
./scripts/git/clean_build.sh --execute        # actually delete
./scripts/git/clean_build.sh --td --execute   # TouchDesigner artifacts only
```

### Repository health check

```bash
./scripts/git/repo_health.sh                  # integrity, size, large files
./scripts/git/repo_health.sh --gc             # also run garbage collection
./scripts/git/repo_health.sh --large 5        # report files >5MB
```

### Undo last commit / unstage / amend

```bash
./scripts/git/undo_last.sh commit                            # undo last commit, keep changes staged
./scripts/git/undo_last.sh unstage src/file.py               # remove file from staging area
./scripts/git/undo_last.sh discard src/file.py               # discard working-tree changes (irreversible)
./scripts/git/undo_last.sh amend-message "fix: correct msg"  # rewrite last commit message
```

Creates a backup tag before any destructive operation.

### Branch cleanup

```bash
./scripts/git/branch_cleanup.sh                              # dry-run preview (safe default)
./scripts/git/branch_cleanup.sh --execute                    # delete merged branches + prune remote refs
./scripts/git/branch_cleanup.sh --tags --execute             # also remove old backup tags
./scripts/git/branch_cleanup.sh --older-than 30 --execute   # only branches older than 30 days
```

### Safe rebase

```bash
./scripts/git/rebase_safe.sh --onto main              # rebase current branch onto main
./scripts/git/rebase_safe.sh --squash-last 3          # interactive squash of last 3 commits
./scripts/git/rebase_safe.sh --squash-last 3 --autosquash  # auto-apply fixup!/squash! prefixes
./scripts/git/rebase_safe.sh --abort                  # abort in-progress rebase
./scripts/git/rebase_safe.sh --continue               # continue after resolving conflicts
```

Creates a backup tag (`pre-rebase-<timestamp>-<pid>`) before rebasing. Warns if commits already pushed.

### Bisect a bug

```bash
# Automated: find first-bad commit using a test script
./scripts/git/bisect_helper.sh --good v1.0.0 --run "bash tests/smoke_test.sh"

# Manual: guided interactive bisect
./scripts/git/bisect_helper.sh --good v1.0.0
# → git bisect good / git bisect bad after each checkout

./scripts/git/bisect_helper.sh --abort   # stop in-progress bisect session
```

### Generate changelog

```bash
./scripts/git/changelog_generate.sh                          # since latest semver tag → stdout
./scripts/git/changelog_generate.sh --from v1.0.0            # since specific tag
./scripts/git/changelog_generate.sh --from v1.0.0 --output CHANGELOG.md
./scripts/git/changelog_generate.sh --from v1.0.0 --format text  # plain text
```

---

## Environment Variables

All scripts support `CGW_*` environment variables to override config at runtime:

```bash
CGW_NON_INTERACTIVE=1 ./scripts/git/commit_enhanced.sh "feat: message"
CGW_SOURCE_BRANCH=dev ./scripts/git/merge_with_validation.sh --dry-run
CGW_LINT_CMD="" ./scripts/git/check_lint.sh   # skip lint for this run
CGW_NO_VENV=1 ./scripts/git/commit_enhanced.sh "feat: message"  # system lint
CGW_SKIP_LINT=1 ./scripts/git/commit_enhanced.sh "feat: message"  # skip all lint
CGW_SKIP_MD_LINT=1 ./scripts/git/commit_enhanced.sh "docs: update"  # skip md lint only
CGW_ALL=1 ./scripts/git/commit_enhanced.sh "chore: bulk stage"  # force-stage all
```

Legacy `CLAUDE_GIT_*` variables are still supported:
- `CLAUDE_GIT_NON_INTERACTIVE=1` → `CGW_NON_INTERACTIVE=1`
- `CLAUDE_GIT_NO_VENV=1` → `CGW_NO_VENV=1`
- `CLAUDE_GIT_STAGED_ONLY=1` → `CGW_STAGED_ONLY=1`
