---
name: auto-git-workflow
description: "Use whenever the user asks for a git operation in this project — commit, push, pull, fetch, merge, rebase, cherry-pick, rollback, revert, sync, stash, tag, release, changelog, worktree, recover/restore lost commits, branch (create/rename/delete/cleanup), bisect, undo, amend, or conflict resolution. Routes work through scripts/git/*.sh wrappers (commit_enhanced.sh, push_validated.sh, merge_with_validation.sh, rollback_merge.sh, cherry_pick_commits.sh, rebase_safe.sh, stash_work.sh, branch_cleanup.sh, bisect_helper.sh, changelog_generate.sh, create_release.sh, create_pr.sh, sync_branches.sh, undo_last.sh, recover.sh, worktree_manage.sh, merge_docs.sh, validate_branches.sh) instead of raw git, so lint validation, local-only file protection, backup tags, and force-push guards are never bypassed."
allowed-tools: "Bash, Read, Grep"
user-invocable: false
---

# Auto Git Workflow

Ensures all git operations follow established patterns:
- Use `scripts/git/*.sh` scripts instead of raw git commands
- Protect local-only files from accidental commits
- Handle merge conflicts correctly (auto-resolve safe cases, stop for manual review)
- Follow conventional commit message format

For script flags and environment variables, see [references/script-reference.md](references/script-reference.md).
For error recovery procedures, see [references/error-recovery.md](references/error-recovery.md).
For branch rules and merge workflow, see [references/branch-and-merge-rules.md](references/branch-and-merge-rules.md).
For non-obvious git techniques not covered by a wrapper (pickaxe search, merge-base discovery, back-dated tags, PR diff URLs), see [references/git-recipes.md](references/git-recipes.md).
For the full promotion pipeline (commit → push → merge/PR → push, run by `/auto-git-workflow-cmd` option 1), see [references/full-promotion.md](references/full-promotion.md).
When a merge or rebase **stops on a conflict that needs manual resolution** (`UU`, `AA`, `AU`, `UD`, `AD`, `DA`), follow the step-by-step procedure in [references/resolving-merge-conflicts.md](references/resolving-merge-conflicts.md) — investigate both sides' intent, preserve both where compatible, re-run checks, then conclude through the wrapper. **Before touching a hunk:** run `git log --merge -p -- <file>` and `git log --oneline --left-right --merge` to understand which commits on each side caused the conflict. Never blindly `git checkout --ours/--theirs`; resolve by default — abort only to deliberately abandon the operation, not to dodge a difficult conflict.

## When to use this skill

Invoke this skill **before** running any git command in this project. If the answer to *"am I about to run `git <verb>`?"* is yes — even for `git commit -m`, `git push`, `git merge`, `git rebase`, `git cherry-pick`, `git stash`, `git tag`, `git revert`, `git reset`, or any branch/remote mutation — load these rules first and reach for the matching `scripts/git/*.sh` wrapper. Read-only operations (`git status`, `git log`, `git diff`, `git show`) do not require the skill, but using it does no harm.

**Tool-use note.** When using `AskUserQuestion` to clarify a git operation, emit the tool call promptly — keep the prose preamble to one short sentence. Long narrative lead-ins before a structured tool call have, in past sessions, correlated with empty `input: {}` emissions that the harness rejects as "Invalid tool parameters". If you see that error, simply re-issue the same question.

---

## Core Rules (MANDATORY)

### Rule 1: NEVER Use Raw `git commit`

**Always use:**
```bash
./scripts/git/commit_enhanced.sh [flags] "commit message"
```

**NEVER use:**
```bash
git commit -m "message"  # WRONG — bypasses lint, protection, logging
```

`commit_enhanced.sh` provides: lint validation, local-only file protection, branch verification, commit message format checking, and comprehensive logging.

> **Optional defense-in-depth:** If the CGW PreToolUse guardrail was installed (offered during `configure.sh`), this rule is also enforced at the Claude Code harness layer — even if asked to run `git commit` directly, the hook blocks it before it reaches the shell. See `references/error-recovery.md` → *PreToolUse Guardrail* for disable instructions.

### Rule 2: Use `--no-venv` When No Virtual Environment

```bash
# If .venv exists — use normally:
./scripts/git/commit_enhanced.sh "feat: add feature"

# If .venv is missing — add --no-venv (uses system lint tool directly):
./scripts/git/commit_enhanced.sh --no-venv "feat: add feature"
```

Works on `commit_enhanced.sh`, `check_lint.sh`, and `fix_lint.sh`. Also supported via `CGW_NO_VENV=1`.

### Rule 3: NEVER Commit Local-Only Files

Files configured in `.cgw.conf` as `CGW_LOCAL_FILES` must never be committed.
Default protected files: `CLAUDE.md`, `MEMORY.md`, `.claude/`, `logs/`

Use `CGW_LOCAL_FILES_EXEMPT` in `.cgw.conf` to allow specific files inside a blocked directory (e.g., `.claude/settings.json` is a shared project config inside the blocked `.claude/` dir).

Before any commit, verify:
```bash
git diff --cached --name-only | grep -E "(CLAUDE\.md|MEMORY\.md|\.claude/|logs/)"
```

`commit_enhanced.sh` automatically unstages all configured local-only files before committing. The pre-commit and pre-push hooks read `CGW_LOCAL_FILES` from `.cgw.conf` at run time, so editing the config takes effect immediately — no need to re-run `configure.sh`.

This protection is **commit-scoped only** — CGW unstages local-only files before a commit, but nothing stops you from *deleting* them from disk. Never run `git rm -f` or `git clean -f` on a local-only or git-ignored path; for git-ignored files this is unrecoverable. See the split cherry-pick recipe below for the safe way to strip unwanted paths.

### Rule 4: Stale Lock Auto-Recovery

CGW scripts automatically detect and remove stale `.git/index.lock` files left by crashed or killed git processes (the most common Claude Code failure mode). When this happens you will see:

```
[cgw-lock] Removing stale index.lock (age 47s): /path/to/.git/index.lock
```

**Safety guards — the helper refuses to remove the lock when:**
- A `rebase`, `merge`, `cherry-pick`, `revert`, or `bisect` is in progress (detected by state dirs/sentinels in `.git/`). This protects you if a `git rebase -i` editor is open in another terminal.
- `CGW_AUTO_REMOVE_INDEX_LOCK=0` is set (warn-only mode).

**Manual removal** is only needed if the auto-recovery refuses. Use the worktree-aware path (not always literally `.git/index.lock`):
```bash
rm -f "$(git rev-parse --git-dir)/index.lock"
```

**Tuning** (via env or `.cgw.conf`):

| Variable | Default | Purpose |
|---|---|---|
| `CGW_AUTO_REMOVE_INDEX_LOCK` | `1` | `0` = warn-only, `1` = auto-remove |
| `CGW_INDEX_LOCK_MAX_AGE_SECONDS` | `30` | Locks older than this are stale |
| `CGW_INDEX_LOCK_WAIT_SECONDS` | `10` | Poll window for fresh locks |

If you regularly run `git rebase -i` and pause in the editor for minutes, set `CGW_INDEX_LOCK_MAX_AGE_SECONDS=300` to avoid interruption.

### Rule 5: Selective Commits — Staging Intent Is Respected

**The script's staging behavior depends on what is already staged when it runs:**

| Pre-staged files? | Unstaged changes? | Non-interactive action |
|:-:|:-:|---|
| No | No | Exit — nothing to commit |
| No | Yes | Auto-stage all tracked changes (`git add -u`) |
| Yes | No | Commit staged files as-is |
| **Yes** | **Yes** | **Commit pre-staged files ONLY** — warns loudly about excluded changes |

**Use `--only` for the clearest intent (preferred in Claude Code):**
```bash
# Commit exactly two files — any prior index state is reset first
./scripts/git/commit_enhanced.sh --no-venv \
  --only src/foo.py \
  --only src/bar.py \
  "feat: selective change"
```

**Or pre-stage + commit (safe default respects your selection):**
```bash
git add src/foo.py src/bar.py && \
  ./scripts/git/commit_enhanced.sh --no-venv "feat: selective change"
```

**To include all tracked changes regardless of index state:**
```bash
./scripts/git/commit_enhanced.sh --all --no-venv "chore: bulk update"
# Equivalent env var: CGW_ALL=1
```

**Never do this when you have pre-existing tracked modifications and only want to commit some of them:**
```bash
# DANGEROUS (old pattern) — auto-stages EVERYTHING in non-interactive mode if nothing pre-staged
git reset HEAD && git add src/foo.py && ./scripts/git/commit_enhanced.sh "feat: ..."
# SAFE (new pattern) — use --only instead
./scripts/git/commit_enhanced.sh --only src/foo.py "feat: ..."
```

---

## Commit Message Format

Conventional commit format (enforced by `commit_enhanced.sh`):

| Prefix | Use Case |
|--------|----------|
| `feat:` | New feature |
| `fix:` | Bug fix |
| `docs:` | Documentation |
| `chore:` | Maintenance |
| `test:` | Test changes |
| `refactor:` | Code refactoring |
| `style:` | Code style |
| `perf:` | Performance |

Additional project-specific prefixes can be configured via `CGW_EXTRA_PREFIXES` in `.cgw.conf`.

**Subject length (Pro Git recommendation):** keep the summary after the prefix to **≤50 chars**
— draft it that way up front rather than relying on the script to catch it. `commit_enhanced.sh`
prints an advisory tip between 50–72 chars and **blocks the commit** past 72 chars (the point
`git log --oneline`/GitHub truncate at), requiring explicit confirmation to proceed. Put any
extra detail in the commit body, not a long subject line. Tune via `CGW_COMMIT_SUBJECT_SOFT_LEN`
/ `CGW_COMMIT_SUBJECT_HARD_LEN` / `CGW_ENFORCE_SUBJECT_LENGTH` in `.cgw.conf`.

---

## Quick Decision Tree

**Committing code:**
```
Is .venv directory present?
├─ Yes → ./scripts/git/commit_enhanced.sh "feat: message"
└─ No  → ./scripts/git/commit_enhanced.sh --no-venv "feat: message"

Committing specific files only?
├─ Yes → use --only <path> (repeatable); resets index, stages listed paths only
│         ./scripts/git/commit_enhanced.sh --only src/a.py --only src/b.py --no-venv "feat: ..."
└─ No  → Commit all tracked changes: ./scripts/git/commit_enhanced.sh --all --no-venv "feat: ..."
          OR pre-stage nothing, let script auto-stage everything (same as --all)

Did you pre-stage some files but have other unstaged changes?
├─ Yes → Script commits pre-staged ONLY (safe default). Run --all to include everything.
└─ No  → Proceed normally

Are local-only files staged?
├─ Yes → commit_enhanced.sh unstages them automatically
└─ No  → Proceed

Did lint checks fail?
├─ Yes → Run ./scripts/git/fix_lint.sh then retry commit
└─ No  → Commit proceeds

Optional flags: --skip-lint (skip all lint), --skip-md-lint (skip markdown lint only),
                --sign (GPG/SSH-sign the commit), --no-sign (override CGW_SIGN_COMMITS)

Typecheck: runs non-blocking in the pre-commit hook when CGW_TYPECHECK_CMD is set (pyrefly is the configured default for this project's Python code) — see script-reference.md.

After commit: verify with git log --oneline -1
(that single check is enough — skip any git status/diff scan beforehand; commit_enhanced.sh
already validates lint and protects local-only files internally, regardless of how the request
is phrased)
```

**Merging to target branch** (direct merge, `CGW_MERGE_MODE="direct"`):
```bash
# Preview first (no changes):
./scripts/git/merge_with_validation.sh --dry-run

# Execute merge:
./scripts/git/merge_with_validation.sh --non-interactive

# Override branch pair for this invocation (doesn't mutate config):
./scripts/git/merge_with_validation.sh --source feature/hotfix --target release/1.2 --non-interactive
```
Handles: pre-merge validation, backup tag, modify/delete/both-deleted conflict auto-resolution, content conflict detection (stops for manual review).

**After manual conflict resolution:** when the script pauses for a content conflict (`UU`/`AA`/`AU`), resolve the markers, run `git add <file>`, then conclude the merge with `commit_enhanced.sh` — Rule 1 applies to merge-conclusion commits too. Do NOT re-run `merge_with_validation.sh`; there is no `--continue` flag.

Set `CGW_MERGE_MODE="pr"` in `.cgw.conf` to use the PR workflow instead (see Creating a PR below).

**Pushing to remote:**
```bash
./scripts/git/push_validated.sh                       # with lint check
./scripts/git/push_validated.sh --no-venv             # no .venv (forwards to check_lint.sh)
./scripts/git/push_validated.sh --dry-run             # preview
./scripts/git/push_validated.sh --skip-lint           # skip lint check entirely
./scripts/git/push_validated.sh --no-venv --skip-lint # both
# One call is enough on its own -- no pre-check and no post-check needed, regardless of
# urgency or stakes in the request; --force-with-lease + the protected-branch guard already
# cover what an extra git status/log would verify.
```

**Creating a PR** (when `CGW_MERGE_MODE="pr"`):
```bash
./scripts/git/create_pr.sh                          # interactive
./scripts/git/create_pr.sh --non-interactive        # skip prompts
./scripts/git/create_pr.sh --dry-run                # preview only
./scripts/git/create_pr.sh --title "feat: my PR"   # override title
./scripts/git/create_pr.sh --draft                  # open as draft
./scripts/git/create_pr.sh --source feature/hotfix --target release/1.2
```
Creates a GitHub PR from source → target via `gh` CLI. Requires `gh auth login`. Charlie CI auto-reviews on PR open.

**Syncing with remote:**
```bash
./scripts/git/sync_branches.sh              # sync current branch
./scripts/git/sync_branches.sh --all        # sync both source and target branches
./scripts/git/sync_branches.sh --branch main  # sync a specific branch
./scripts/git/sync_branches.sh --dry-run    # preview (fetch only, no merge)
./scripts/git/sync_branches.sh --prune      # also remove stale remote-tracking refs
```

`sync_branches.sh` also protects any git **skip-worktree** local file (see `CGW_LOCAL_FILES`)
across a sync. That bit hides local disk edits from `git status`/`diff-index`, but does **not**
stop `git pull --rebase` from refusing when the incoming commit also touches the file ("local
changes would be overwritten by merge") -- previously this could abort an entire sync with `[1/4]`
misreporting the tree as "clean". The script now: (1) surfaces skip-worktree divergence at `[1/4]`
instead of hiding it, (2) before the pull, backs up and resets any diverged skip-worktree file to
HEAD so the pull can proceed, and (3) after the pull, restores the local bytes, re-applies the bit,
and **prints the upstream diff** for that file so you can reconcile new shared content -- never
silently discarding local edits. No-op when no skip-worktree file has diverged (the common case).

**Rollback a merge:**
```bash
./scripts/git/rollback_merge.sh                          # interactive (hard reset)
./scripts/git/rollback_merge.sh --revert                 # safe revert (preserves history, no force-push)
./scripts/git/rollback_merge.sh --dry-run
./scripts/git/rollback_merge.sh --non-interactive --target pre-merge-20260101_120000-12345
```

**Cherry-picking a commit:**
```bash
./scripts/git/cherry_pick_commits.sh                       # interactive
./scripts/git/cherry_pick_commits.sh --commit abc1234      # non-interactive
./scripts/git/cherry_pick_commits.sh --dry-run --commit abc1234
./scripts/git/cherry_pick_commits.sh --source feature/hotfix --target release/1.2 --commit abc1234
```

**Cherry-picking only some files from a commit (split/partial cherry-pick):**

There is no wrapper for this — `cherry_pick_commits.sh` picks the whole commit. To take only
a subset of files:
```bash
git cherry-pick -n <hash>      # stage the commit's changes without auto-committing
```
Then strip the paths you don't want, **without deleting anything from disk**:
```bash
git reset HEAD -- <unwanted-path>      # unstage, keep the working-tree copy
# or equivalently:
git rm --cached <unwanted-path>        # index-only untrack, keep the working-tree copy
```
Only use plain `git rm <path>` (no `-f`) for files you genuinely don't want and that are
recoverable (tracked in some other commit) — git itself will refuse if the file has staged
changes. **Never run `git rm -f` on a git-ignored or local-only path**: `-f` deletes the
working-tree copy too, which is unrecoverable for anything git-ignored (the PreToolUse
guardrail blocks `git rm -f`/`--force` unless `--cached` is present, precisely to catch this).
Once only the wanted paths remain staged, commit through the wrapper:
```bash
./scripts/git/commit_enhanced.sh --only <path> --only <path> "feat: split from <hash>"
```

**Merging docs only:**
```bash
./scripts/git/merge_docs.sh
./scripts/git/merge_docs.sh --non-interactive
./scripts/git/merge_docs.sh --source feature/hotfix --target release/1.2 --non-interactive
```

**Undoing something:**
```bash
# Undo last commit (keep changes staged, creates backup tag):
./scripts/git/undo_last.sh commit

# Remove a file from staging:
./scripts/git/undo_last.sh unstage <file>

# Fix last commit message (local only — before push):
./scripts/git/undo_last.sh amend-message "fix: correct message"

# Discard working-tree changes (irreversible — interactive only):
./scripts/git/undo_last.sh discard <file>
```

**Branch cleanup:**
```bash
# Dry-run preview (safe default — shows what would be deleted):
./scripts/git/branch_cleanup.sh

# Execute: delete merged branches + prune stale remote-tracking refs:
./scripts/git/branch_cleanup.sh --execute

# Also clean up old backup tags:
./scripts/git/branch_cleanup.sh --tags --execute
```

**Safe rebase:**
```bash
# Rebase current branch onto target:
./scripts/git/rebase_safe.sh --onto main

# Rebase with auto-stash (stash dirty tree before, restore after):
./scripts/git/rebase_safe.sh --onto main --autostash

# Squash last N commits (opens editor):
./scripts/git/rebase_safe.sh --squash-last 3

# Squash non-interactively using fixup!/squash! prefixes:
./scripts/git/rebase_safe.sh --squash-last 5 --autosquash

# Abort in-progress rebase:
./scripts/git/rebase_safe.sh --abort

# Continue after resolving conflicts:
./scripts/git/rebase_safe.sh --continue

# Skip the current conflicting commit:
./scripts/git/rebase_safe.sh --skip
```

**Published-branch guard:** if the branch was already pushed to a remote, the `pre-rebase` hook **blocks** the rebase to protect shared history (`rebase_safe.sh` warns; the hook hard-blocks). Override only when you are certain no one else has pulled the rewritten commits:
`CGW_ALLOW_REBASE_PUBLISHED=1 ./scripts/git/rebase_safe.sh --onto main`

**Bisecting a bug:**
```bash
# Automated: provide a test command
./scripts/git/bisect_helper.sh --good v1.0.0 --run "bash tests/smoke_test.sh"

# Manual: mark commits good/bad interactively
./scripts/git/bisect_helper.sh --good v1.0.0

# Abort stuck session:
./scripts/git/bisect_helper.sh --abort
```

**Generating a changelog:**
```bash
./scripts/git/changelog_generate.sh --from v1.0.0           # since tag → stdout
./scripts/git/changelog_generate.sh --from v1.0.0 --output CHANGELOG.md

# At release time, before the new tag exists: --version supplies the heading, and
# --prepend stacks the new section above CHANGELOG.md's existing content (cumulative).
./scripts/git/changelog_generate.sh --from v1.0.0 --version v1.1.0 \
  --output CHANGELOG.md --prepend
```

**Stashing work in progress:**
```bash
./scripts/git/stash_work.sh push "wip: description"
./scripts/git/stash_work.sh pop
./scripts/git/stash_work.sh list
./scripts/git/stash_work.sh drop stash@{0} --yes   # non-interactive drop; echoes SHA
./scripts/git/stash_work.sh clear --yes             # non-interactive remove-all
```

**Destructive-op fallback rule:** Prefer the wrapper. Fall back to raw `git stash drop`/`git stash
clear` only when (a) the wrapper genuinely cannot proceed **and** (b) the user has explicitly
authorized that specific destructive action. Justify the bypass by authorization + reflog-recoverability,
never by "no safety risk" — `stash_work.sh drop`/`clear`'s purpose *is* the destructive-action
confirmation. With the `--yes` flag and no-TTY auto-detection now in place, this fallback should never
be needed.

**Creating a release:**
```bash
./scripts/git/create_release.sh v1.2.3 --push             # tag + push (triggers GitHub Release)
./scripts/git/create_release.sh v1.2.3 --push --sign      # GPG/SSH-signed annotated tag
./scripts/git/create_release.sh v1.2.3 --dry-run
```

**Recovering lost commits (reflog + fsck):**
```bash
# Show reflog with restore hints (read-only):
./scripts/git/recover.sh reflog
./scripts/git/recover.sh reflog --limit 50
./scripts/git/recover.sh reflog --ref origin/main

# Inspect a commit by SHA or reflog entry:
./scripts/git/recover.sh show HEAD@{3}

# Find unreachable commits via git fsck (when reflog is gone):
./scripts/git/recover.sh dangling

# Restore a lost commit as a new branch (creates backup tag first):
./scripts/git/recover.sh restore abc1234 --branch recovered/lost-work
```

**Worktree management (parallel branch checkouts):**
```bash
./scripts/git/worktree_manage.sh list                          # show all worktrees
./scripts/git/worktree_manage.sh add ../hotfix hotfix/urgent   # add linked worktree
./scripts/git/worktree_manage.sh remove --execute ../hotfix    # remove worktree
./scripts/git/worktree_manage.sh prune                         # dry-run: show stale admin files
./scripts/git/worktree_manage.sh prune --execute               # remove stale admin files
```

**Project setup & hygiene:**
```bash
./scripts/git/setup_attributes.sh --dry-run   # preview .gitattributes changes
./scripts/git/setup_attributes.sh             # write .gitattributes
./scripts/git/setup_attributes.sh --force     # overwrite existing .gitattributes without prompting
./scripts/git/clean_build.sh                  # dry-run artifact cleanup
./scripts/git/clean_build.sh --execute        # actually delete artifacts
./scripts/git/clean_build.sh --python --execute   # Python artifacts only
./scripts/git/clean_build.sh --td --execute       # TouchDesigner artifacts only
./scripts/git/clean_build.sh --glsl --execute     # GLSL compiled shaders only
./scripts/git/clean_build.sh --all --execute      # all artifact types regardless of detection
./scripts/git/repo_health.sh                  # integrity check + size report
./scripts/git/repo_health.sh --gc             # also run garbage collection
```

**Checking what changed on your branch:**
```bash
./scripts/git/branch_diff.sh                 # full patch vs the auto-detected default branch
./scripts/git/branch_diff.sh --files         # changed file names only
./scripts/git/branch_diff.sh --stat --no-ws  # diffstat, ignoring whitespace
```
Read-only; safe with a dirty working tree. Auto-detects `main` vs `master` vs a custom default via `${CGW_REMOTE}/HEAD`, falling back to `CGW_TARGET_BRANCH`.

**Reviewing a PR locally:**
```bash
./scripts/git/pr_checkout.sh 42                          # check out PR #42
./scripts/git/pr_checkout.sh --pr 42 --branch review/pr-42
```
Wraps `gh pr checkout`. Requires `gh auth login`. Refuses to switch branches over uncommitted tracked changes unless `--force` is passed — stash first with `stash_work.sh push`.

**Generating/updating a Markdown Table of Contents:**
```bash
./scripts/git/md_toc.sh docs/usage.md --insert   # insert/update TOC in place
./scripts/git/md_toc.sh docs/usage.md --check    # CI: fail if the TOC is stale
./scripts/git/md_toc.sh --all                    # update every tracked *.md with a <!--ts--> marker
```
Computes GitHub-compatible anchor slugs offline — no network access or auth token needed.
