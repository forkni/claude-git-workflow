# Branch and Merge Rules

## Contents

- Branch Configuration
- Branch Policies
  - Naming and Lifecycle for Short-Lived Work Branches
- Conflict Resolution
- Merge Workflow Detail
- Rollback Policy

## Branch Configuration

`CGW_TARGET_BRANCH` (the stable/production branch) is **auto-detected at runtime** by
`_config.sh` — resolution order: `${CGW_REMOTE}/HEAD` symbolic ref → local `main` → local
`master` → `main`. It is never written to `.cgw.conf`; override with the `CGW_TARGET_BRANCH`
env var if the auto-detected value is wrong for your repo.

`CGW_SOURCE_BRANCH` (where development happens) has **no default** — it's an inherently
per-operation choice, not a repo-wide fact. `configure.sh` writes it to `.cgw.conf` only when a
canonical dev-family branch (`development`/`develop`/`dev`/`staging`, local or
remote-tracking) is confidently detected; otherwise no `CGW_SOURCE_BRANCH` line is written at
all, and every merge/cherry-pick/docs-merge invocation needs an explicit `--source <branch>`
flag. Scripts fail fast with a clear error ("No source branch configured...") rather than
guessing at "the most recently committed branch" or silently falling back to
`CGW_SOURCE_BRANCH == CGW_TARGET_BRANCH`.

```bash
CGW_SOURCE_BRANCH="development"   # only written when confidently auto-detected; may be absent
CGW_REMOTE="origin"               # remote name (set to "upstream" for forks)
# CGW_TARGET_BRANCH is never written to .cgw.conf -- auto-detected at runtime, see above
```

Override at runtime: `CGW_SOURCE_BRANCH=dev ./scripts/git/validate_branches.sh`

### Per-invocation branch overrides

`merge_with_validation.sh`, `cherry_pick_commits.sh`, `merge_docs.sh`, and `create_pr.sh` all accept `--source <branch>` and `--target <branch>` flags to override the configured pair for a single run without modifying config:

```bash
./scripts/git/merge_with_validation.sh --source feature/hotfix --target release/1.2 --non-interactive
```

The overrides are validated (branch must exist locally, names must be valid, source ≠ target) and propagated to child `validate_branches.sh` subprocesses automatically.

---

## Branch Policies

### Target Branch (auto-detected at runtime)

Receives merges from the source branch. Typically contains production-ready code. Resolved via
`${CGW_REMOTE}/HEAD` → local `main` → local `master` → `main`; override with the
`CGW_TARGET_BRANCH` env var if the auto-detected value is wrong for your repo.

`commit_enhanced.sh` auto-unstages local-only files (configured via `CGW_LOCAL_FILES`) before any commit. The pre-commit and pre-push hooks read `CGW_LOCAL_FILES` from `.cgw.conf` at run time — editing the config takes effect on the next invocation, no `configure.sh` re-run required.

### Source Branch (no default — per-invocation or confidently auto-detected)

Where active development occurs. All changes are committed here first, then merged to target.
`configure.sh` writes `CGW_SOURCE_BRANCH` to `.cgw.conf` only when a canonical dev-family
branch name is found; otherwise pass `--source <branch>` on every merge/cherry-pick/docs-merge
invocation.

### Naming and Lifecycle for Short-Lived Work Branches

CGW's two-branch model (`development` → `main`) doesn't dictate naming for the
short-lived feature/fix branches you create off `development`. Adopt a
consistent convention and document it (Git for Teams): `[ticket-id]-[terse-title]`,
e.g. `1234-fixing-broken-link`. The point is that the branch name alone tells
the next reader what it's for and where to find the ticket — not any
particular separator style.

**Update cadence — rebase early and often:** pull `development` into your work
branch (or rebase onto it) at least daily, not just right before merging. The
earlier you integrate a conflicting upstream change, the smaller the conflict
— resolving a same-day rename is trivial; resolving one after two weeks of
divergence is not. `sync_branches.sh` already implements fetch+rebase; this is
about cadence, not new behavior.

**Merge vs. rebase, the practical test:** *if you started your work right now,
would the change you're about to incorporate already be in place?* If yes,
rebase onto it — you're just replaying your commits on top of what would have
been the starting point anyway. If no (the other side's work is genuinely
concurrent, not something you'd have started from), merge, and prefer a
CGW-driven merge (`merge_with_validation.sh`) so it gets a backup tag. The
same branch name existing on a different remote (e.g. your fork vs.
upstream) is also a rebase case, not a merge case.

**Keep interactive rebase (`rebase_safe.sh` without `--continue`/`--abort`,
i.e. `--squash-last`) scoped to branches nobody else has fetched.** Once a
branch is shared, rewriting its history forces every other holder to
re-sync — the same caveat as SKILL.md's force-push rule.

**First push and cleanup:** `git push --set-upstream ${CGW_REMOTE} <branch>`
on a new branch's first push sets up tracking so subsequent
`push_validated.sh` runs need no arguments. After the branch is merged,
`branch_cleanup.sh` prunes the *local* merged branch and stale
remote-tracking refs; deleting the branch on the remote itself is
`git push ${CGW_REMOTE} --delete <branch>` (or the "Delete branch" button in
a merged PR).

### Standard Workflow (CGW_MERGE_MODE="direct", default)

1. Work and commit on source branch
2. Test and validate on source branch
3. Preview merge: `./scripts/git/merge_with_validation.sh --dry-run`
4. Merge to target: `./scripts/git/merge_with_validation.sh --non-interactive`
   - **Local-only file guard:** if the source branch carries a `CGW_LOCAL_FILES`
     entry (`CLAUDE.md`, `MEMORY.md`, `.claude/`, `logs/`, …), the merge aborts in
     non-interactive mode (cherry-pick too). Remove the file from the incoming
     change, or override with `CGW_ALLOW_LOCAL_FILES_IN_MERGE=1`.
5. Push both branches:

   ```bash
   ./scripts/git/push_validated.sh                                           # push target
   git checkout "${CGW_SOURCE_BRANCH}" && ./scripts/git/push_validated.sh    # push source
   ```

### PR Workflow (CGW_MERGE_MODE="pr")

Set `CGW_MERGE_MODE="pr"` in `.cgw.conf` to use GitHub PRs instead of direct local merges.

1. Work and commit on source branch
2. Push to remote: `./scripts/git/push_validated.sh`
3. Create PR: `./scripts/git/create_pr.sh`
4. Review PR on GitHub (Charlie CI auto-reviews on open)
5. Merge via GitHub UI after CI passes
6. Sync local branches: `./scripts/git/sync_branches.sh --all`

---

## Conflict Resolution

### Modify/Delete Conflicts (EXPECTED — Auto-Resolved)

**Status code:** `DU` (deleted by us, modified by them)

**When:** Merging source → target when files exist on source but not on target (e.g., dev-only files).

**Action:** `merge_with_validation.sh` auto-resolves by removing the source-only files. These are expected — do not treat as errors.

### Both-Deleted Conflicts (EXPECTED — Auto-Resolved)

**Status code:** `DD` (both deleted)

**When:** A file was deleted on both branches independently.

**Action:** `merge_with_validation.sh` auto-resolves by accepting the deletion.

### Content Conflicts (UNEXPECTED — Manual Required)

**Status code:** `UU` (both modified)

**When:** Same file modified differently on both branches.

**Action:** STOP workflow, require manual resolution. Follow the full procedure
in [resolving-merge-conflicts.md](resolving-merge-conflicts.md) — investigate each
side's intent, preserve both where compatible, re-run lint/tests, then conclude:

```bash
# Resolve each hunk (see resolving-merge-conflicts.md), then:
git add <resolved-files>
./scripts/git/commit_enhanced.sh "fix: resolve merge conflict in <file>"

# Or abort the merge (only to deliberately abandon it):
git merge --abort
git checkout "${CGW_SOURCE_BRANCH}"
```

> Conclude with `commit_enhanced.sh`, not raw `git commit`: the PreToolUse
> guardrail blocks `git commit`, and the wrapper still finalizes the merge
> (`MERGE_HEAD` is set) while keeping lint and local-file protection. Do not pass
> `--only` when concluding a merge — it resets the index and breaks merge state.

Never auto-resolve content conflicts — they require human review.

### Add/Add or Add/Unmerged Conflicts (UNEXPECTED — Manual Required)

**Status codes:** `AA` (both added), `AU` (added by us, unmerged)

**When:** Same filename added on both branches with different content.

**Action:** STOP workflow, require manual resolution. Same process as UU conflicts.

### Deleted/Add-Delete Conflicts (UNEXPECTED — Manual Required)

**Status codes:** `UD` (updated by us, deleted by them), `AD` (added by us, deleted by them), `DA` (deleted by us, added by them)

**When:** One side modified or added a file while the other side deleted it. Unlike `DU`/`DD`, the intent is ambiguous and requires a human decision.

**Action:** STOP workflow, require manual resolution:

```bash
# Accept deletion:
git rm <file>
# If <file> is git-ignored / local-only and you want to keep the on-disk copy,
# use `git rm --cached <file>` (or `git reset HEAD -- <file>`) instead — plain
# `git rm` (and especially `git rm -f`) deletes the working-tree copy, which is
# unrecoverable for anything git-ignored.

# Keep our version:
git checkout --ours <file> && git add <file>

# Keep their version:
git checkout --theirs <file> && git add <file>

# Then complete or abort the merge:
git commit    # if resolved
git merge --abort  # if abandoning
```

---

## Merge Workflow Detail

`merge_with_validation.sh --non-interactive` steps:

1. Run `validate_branches.sh` (checks branch state, warns on untracked files)
2. Checkout target branch
3. Create backup tag `pre-merge-<timestamp>-<pid>` via `cgw_create_backup_tag merge` (PID suffix prevents collision on fast CI)
4. Perform `git merge ${CGW_SOURCE_BRANCH} --no-ff`
5. Auto-resolve `DU` (modify/delete) conflicts
6. Stop on `AU`/`AA` conflicts — requires manual resolution
7. Auto-resolve `DD` (both deleted) conflicts
8. Stop on `UU` (content), `UD`/`AD`/`DA` (delete/add-delete) conflicts — requires manual resolution
9. Validate `docs/` files against CI policy (if `CGW_DOCS_PATTERN` is set)
10. Clean up `tests/` if `CGW_CLEANUP_TESTS=1` and tests/ is gitignored on target
11. Complete merge commit

After merge: review with `git log --oneline -5`, then push via `push_validated.sh`.

---

## Rollback Policy

If a merge introduces problems:

1. **Immediate rollback** (before pushing): `./scripts/git/rollback_merge.sh`
2. **After pushing to remote**: use `rollback_merge.sh` locally, then force-push with `push_validated.sh --force`
3. **Force-push confirmation**: always requires explicit typing `FORCE` when pushing to protected branches
