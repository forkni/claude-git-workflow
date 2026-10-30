# Git Recipes for Conflict Investigation

Non-obvious git techniques that help you understand *why* two branches diverged, distilled from a
broader git/GitHub cheat-sheet (stas00/git-tools' `git.txt`). Most are read-only inspection and
always safe to run. The few that change history say so; confirm with the user before running
those on a shared branch.

---

## What changed on this branch?

Triple-dot is merge-base relative, so it excludes changes already on the default branch:

```bash
git diff origin/main...HEAD
git diff --name-only origin/main...HEAD
```

---

## Search history for when a string was added or removed (pickaxe)

```bash
git log -S'someFunctionName' --oneline          # commits that changed the string's occurrence count
git log -G'someFunc\(' --oneline                # commits whose diff matches a regex
git log -p -S'someFunctionName' -- src/         # show the actual diffs, scoped to a path
git log --oneline --all -- ":(exclude)vendor/*" # exclude a path from the search
```

---

## Finding the branching point (merge-base) between two branches

```bash
git merge-base main feature/x                       # SHA where feature/x diverged
git log --oneline "$(git merge-base main feature/x)"..feature/x   # commits unique to feature/x
```

Find commits on a release branch not yet on main, excluding version/changelog churn:

```bash
git log --oneline "$(git merge-base main release/1.2)"..origin/release/1.2 \
  -- ":(exclude)CHANGELOG.md" ":(exclude)version.py"
```

---

## Triaging a suspicious line: blame, then log/show/diff

`git blame` only tells you which commit last touched a *surviving* line. If the line was deleted
and re-added by a different commit, blame points at the wrong one; fall back to the pickaxe search
above (`git log -S`) in that case.

```bash
git blame -L 40,60 -- <file>   # which commit last touched each line in range
git log -1 <sha>               # why: commit message / ticket reference
git show <sha>                 # what: the actual diff introduced by <sha>
git diff <sha> -- <file>       # since: everything that changed in <file> after <sha>
```

---

## Comparing a working ref against a broken one

Once a "this used to work" regression is narrowed to two refs, the commit range is the candidate
set (before reaching for `git bisect`):

```bash
git log --oneline working..broken     # commits present on broken but not working
git log --oneline HEAD~3..HEAD        # last 3 commits
git fetch origin && git log --oneline HEAD..origin/main   # what main has that you don't
```

---

## Was a commit a true merge or a fast-forward?

```bash
git log --oneline --graph -20              # visual shape of recent history
git show --no-patch <sha>                  # a "Merge: <parent1> <parent2>" line = true merge
```

A commit with no `Merge:` line is not a two-parent merge commit.

---

## Which branches already contain a given commit

Useful for confirming a hotfix reached both long-lived branches before deleting its branch:

```bash
git branch --contains <sha>        # local branches
git branch -a --contains <sha>     # local + remote-tracking
```

---

## Undoing a merge or pull that just happened

Changes history. For the "I just ran `git pull` and it brought in the wrong branch" moment,
seconds after it happened and before anything else:

```bash
git branch preservation_branch     # safety net, costs nothing, delete later
git reset --merge ORIG_HEAD
```

`ORIG_HEAD` is git's own "before the last drastic operation" pointer. It survives exactly one
merge, pull or rebase, so this only works immediately after. `--merge` keeps uncommitted changes
that the merge did not touch.

---

## Re-merging a branch whose merge was reverted

A revert leaves the branch recorded as already merged, so a second merge brings in only commits
made after the first one. Revert the revert on the target branch first, then merge again (or merge
a fresh branch holding the work as new commits):

```bash
git revert <revert-sha>
git merge feature/x
```

Revert a published range without rewriting history (`--no-commit` stages the whole range as one
change):

```bash
git revert --no-commit A..HEAD
git revert --continue   # only if a conflict stopped the range mid-way
git commit -m "revert: undo A..HEAD"
```

---

## Cherry-picking with provenance, or from a merge commit

```bash
git cherry-pick -x <sha>            # appends "(cherry picked from commit <sha>)"
git cherry-pick --mainline 1 <sha>  # required when <sha> is itself a merge commit
```

`-x` makes the origin of the change discoverable later via `git log --grep`; prefer it whenever
the commit will live on a shared branch. `--mainline 1` picks the diff relative to the merge's
first parent; without it git refuses to cherry-pick a merge commit.

---

## Viewing a PR or commit as a raw diff (no local checkout)

A GitHub URL trick, not a git operation:

```text
https://github.com/<owner>/<repo>/pull/<N>.diff
https://github.com/<owner>/<repo>/commit/<sha>.patch
```

---

## Inspecting stashes without popping them

```bash
git stash show -p stash@{0}
git diff stash@{0} stash@{1}
```
