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

`sync_branches.sh` protects any `skip-worktree` local file (see `CGW_LOCAL_FILES`) that has
genuinely diverged from `HEAD` on disk: it surfaces the divergence instead of a false "clean",
backs up and resets the file to `HEAD` so `pull --rebase` can proceed, then restores the local
bytes, re-applies the bit, and prints the upstream diff so new shared content can be reconciled
by hand. No-op when nothing has diverged.

### Rollback a merge

```bash
./scripts/git/rollback_merge.sh                           # interactive (hard reset)
./scripts/git/rollback_merge.sh --revert                  # safe revert (preserves history, no force-push)
./scripts/git/rollback_merge.sh --non-interactive         # auto-select latest backup
./scripts/git/rollback_merge.sh --target pre-merge-20260101_120000-12345
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
./scripts/git/create_release.sh v1.2.3            # annotated tag only
./scripts/git/create_release.sh v1.2.3 --push     # tag + push (triggers release.yml)
./scripts/git/create_release.sh v1.2.3 --sign --push  # GPG/SSH-signed tag + push
./scripts/git/create_release.sh v1.2.3 --dry-run  # preview
```

Enable signing globally in `.cgw.conf`: `CGW_SIGN_TAGS=1`. Requires a GPG or SSH signing key configured in git (`gpg.signingKey` / `gpg.format=ssh`). Verify a tag with: `git tag -v v1.2.3`.

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

Creates a backup tag (`pre-rebase-<timestamp>-<pid>`) before rebasing. The installed `pre-rebase` hook also enforces this at the git level — if commits are already pushed, the rebase is refused unless `CGW_ALLOW_REBASE_PUBLISHED=1` is set (for controlled force-push workflows).

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

# Cutting a release before the tag exists: --version supplies the heading
# (git describe can't find the tag yet, so it would otherwise fall back to a hash).
./scripts/git/changelog_generate.sh --from v1.0.0 --version v1.1.0 --output CHANGELOG.md

# --prepend stacks the new section above CHANGELOG.md's existing content instead of
# overwriting it, building a cumulative history. Refuses if that heading is already present.
./scripts/git/changelog_generate.sh --from v1.0.0 --version v1.1.0 \
  --output CHANGELOG.md --prepend
```

### Recover lost commits

Git's reflog records every time a ref moves; `git fsck` surfaces unreachable objects when the reflog is gone. `recover.sh` wraps both:

```bash
./scripts/git/recover.sh reflog                              # show HEAD reflog with restore hints
./scripts/git/recover.sh reflog --limit 50 --ref main       # different ref
./scripts/git/recover.sh show HEAD@{3}                      # inspect a specific entry or SHA
./scripts/git/recover.sh dangling                           # git fsck --full: find unreachable commits
./scripts/git/recover.sh restore abc1234 --branch recovered/lost-work  # restore as a new branch
```

`restore` creates a `pre-recover-<timestamp>-<pid>` backup tag before touching any ref. All other subcommands are read-only.

### Manage linked worktrees

Linked worktrees let you check out multiple branches simultaneously in separate directories — useful for hot-fixes without stashing:

```bash
./scripts/git/worktree_manage.sh list                            # show all worktrees
./scripts/git/worktree_manage.sh add ../hotfix hotfix/urgent     # add linked worktree (creates branch)
./scripts/git/worktree_manage.sh add ../review existing-branch   # check out existing branch
./scripts/git/worktree_manage.sh remove --execute ../hotfix      # remove worktree link
./scripts/git/worktree_manage.sh prune                           # dry-run: show stale admin files
./scripts/git/worktree_manage.sh prune --execute                 # remove stale admin files
```

`remove` and `prune` default to dry-run; pass `--execute` to apply.

### Diff your branch against the default branch

`branch_diff.sh` auto-detects the repository's default branch (`main`, `master`, or a custom name) via `${CGW_REMOTE}/HEAD`, falling back to `CGW_TARGET_BRANCH` when that ref is unset:

```bash
./scripts/git/branch_diff.sh                 # full patch vs default branch
./scripts/git/branch_diff.sh --files         # changed file names only
./scripts/git/branch_diff.sh --stat --no-ws  # diffstat, ignoring whitespace
./scripts/git/branch_diff.sh --base release/1.2  # compare against an explicit ref
```

Read-only — safe to run with a dirty working tree. Uses triple-dot diff (`<base>...HEAD`), so only changes made on the current branch are shown.

### Review a PR locally

```bash
./scripts/git/pr_checkout.sh 42                            # check out PR #42
./scripts/git/pr_checkout.sh --pr 42 --branch review/pr-42  # into a named local branch
./scripts/git/pr_checkout.sh 42 --dry-run                  # preview the gh command only
```

Wraps `gh pr checkout`; requires `gh auth login`. Refuses to switch branches over uncommitted tracked changes unless `--force` is passed.

### Generate or update a Markdown Table of Contents

```bash
./scripts/git/md_toc.sh docs/usage.md              # print TOC to stdout
./scripts/git/md_toc.sh docs/usage.md --insert      # insert/update the <!--ts-->...<!--te--> block in place
./scripts/git/md_toc.sh docs/usage.md --check       # CI: exit 1 if the TOC is stale
./scripts/git/md_toc.sh --all                       # update every tracked *.md file with a <!--ts--> marker
```

Computes GitHub-compatible anchor slugs offline (no network access or auth token needed).

---

### Fix lint issues (code + Markdown)

```bash
./scripts/git/fix_lint.sh                    # auto-fix code lint + markdown, full repo
./scripts/git/fix_lint.sh --modified-only     # only files changed vs HEAD
./scripts/git/fix_lint.sh --md-only           # markdown auto-fix only, skip code lint
./scripts/git/fix_lint.sh --skip-md-lint      # code lint auto-fix only, skip markdown
```

Markdown auto-fix uses `CGW_MARKDOWNLINT_CMD` (auto-detected at runtime — see
[Configuration](configuration.md)) with `CGW_MARKDOWNLINT_FIX_ARGS` (default `--fix`).
Only auto-fixable rules are corrected in place; manual-only violations (e.g. `MD013`,
`MD041`) still require a hand fix and are reported by `check_lint.sh`.

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

---

## Updating local-only file protection

`CGW_LOCAL_FILES` (and `CGW_LOCAL_FILES_EXEMPT`) is read from `.cgw.conf` by the
git hooks at run time, so editing the config takes effect immediately:

```bash
# Add a new local-only entry — no re-render needed
sed -i 's/^CGW_LOCAL_FILES=.*/CGW_LOCAL_FILES="CLAUDE.md MEMORY.md notes.md .claude\/ logs\/"/' .cgw.conf
git add notes.md && git commit -m "test"   # → blocked by pre-commit on next try
```

Match contract:

- A bare name (`CLAUDE.md`) matches the path **exactly** — `CLAUDE.md.bak` does NOT match.
- A trailing-slash entry (`logs/`) matches the directory itself or anything inside it.
- `CGW_LOCAL_FILES_EXEMPT` accepts exact paths that override a match.
- No globs, no substring matches.

> **Migration note:** if you upgraded from a CGW version older than the
> single-source-of-truth matcher, your `.git/hooks/pre-commit` and
> `.git/hooks/pre-push` may still contain compiled-in patterns from the old
> `configure.sh`. Re-run `./scripts/git/install_hooks.sh` once to refresh
> them — afterwards `.cgw.conf` edits will be picked up at run time.
