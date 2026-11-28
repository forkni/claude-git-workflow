# Resolving Merge & Rebase Conflicts

When a merge, rebase, pull or cherry-pick stops on a conflict, the index is mid-operation and it is
your job to resolve the conflicting hunks *correctly* before completing. Finishing the operation is
not enough: a bad resolution silently ships wrong code. Follow this procedure.

## 1. See the current state

Don't edit blind. Establish what is in progress and what conflicts:

```bash
git status                       # merge vs rebase in progress; conflicted paths
git status -sb                   # same info, one line per file (XY code + path)
git diff --name-only --diff-filter=U   # just the unmerged files
```

`git status` tells you whether you are in a merge (`MERGE_HEAD` exists), a rebase
(`rebase-merge/`/`rebase-apply/` exists) or a cherry-pick (`CHERRY_PICK_HEAD` exists). Each is
completed differently (step 6). The two-letter `XY` code per file (`UU`, `AA`, `DU`, ...) is the
conflict taxonomy in SKILL.md.

## 2. Find each side's intent before you touch a hunk

This is the step that turns a guess into a resolution. For every conflicted hunk, understand
**why both sides changed it**. Never pick `--ours`/`--theirs` blind:

```bash
git log --merge -p -- <file>     # commits on each side that touch this file
git log --oneline --left-right --merge   # which side each conflicting commit came from
```

Read the commit messages (and the PR or issue they reference) for the conflicting commits. The
goal is to know the *purpose* of each change, not just its text.

## 3. Read the three-way view, not just ours/theirs

By default git's conflict markers only show two sides (`<<<<<<< HEAD` / `=======` /
`>>>>>>> branch`). That tells you *what* differs but not *which side actually changed it* relative
to the common history. Re-materialize the conflict with the common ancestor included:

```bash
git -c merge.conflictStyle=zdiff3 checkout --merge -- <file>   # per-file, one-off
# or for every future conflict in this repo: git config merge.conflictStyle zdiff3
```

This produces a third section:

```text
<<<<<<< HEAD
(your side)
||||||| <base-sha>
(the common ancestor -- what both sides started from)
=======
(their side)
>>>>>>> branch
```

Compare each side against the `|||||||` base, not against each other. That tells you which side
actually changed the line and which side just carried it forward unchanged; the changed one is
usually the one to keep.

For `AU`/`UA`/`AA` paths, the individual stages are readable directly:
`git show :1:<file>` (base, when one exists), `git show :2:<file>` (ours), `git show :3:<file>`
(theirs).

## 4. Resolve each hunk

- **Preserve both intents where they are compatible.** Most conflicts are two independent edits
  to nearby lines: keep both. Reach for `--ours`/`--theirs` only when the changes are genuinely
  mutually exclusive.
- **When incompatible, pick the side that matches the merge's stated goal** and tell the user
  what was dropped.
- **Do not invent new behaviour** to bridge the two sides. Resolve to what one or both sides
  actually intended.
- Remove every conflict marker (`<<<<<<<`, `|||||||`, `=======`, `>>>>>>>`).

`git checkout --ours <file>` / `--theirs <file>` (then `git add <file>`) are available for
whole-file decisions, but a per-hunk edit is usually the right resolution. During a rebase the
sides are swapped: `--ours` is the branch being rebased onto, `--theirs` is your commit being
replayed.

**Delete-versus-modify (`DU`, `UD`):** one side deleted the file, the other changed it. Accepting
the deletion silently drops the other side's work, so ask the user unless the answer is obvious
(for example a dev-only file that should never reach the target branch):

```bash
git add <file>          # keep the modified version
git rm <file>           # accept the deletion
git rm --cached <file>  # accept the deletion but keep the on-disk copy (ignored/local files)
```

**Escape hatch for whole-side, no-judgment-needed conflicts:** when you know *before* merging that
one side should win for every conflicting hunk (a generated file, a lockfile, vendored code), use
`git merge --strategy-option=ours` / `--strategy-option=theirs`. This decides the *whole merge* by
side, not per path, so only use it when every conflicted path genuinely belongs in that bucket.

## 5. Re-run the project's checks before completing

A resolved-but-broken merge is worse than a stopped one. Before concluding, search for leftover
markers and run the project's own lint and tests for the touched area:

```bash
git diff --check                 # flags leftover conflict markers and whitespace errors
# then the project's lint / test commands (see its README, Makefile or CI config)
```

## 6. Complete the operation

Stage the resolved files, then conclude the operation that is in progress.

**Merge in progress:** commit with no message. Git uses its prepared merge message and produces a
proper two-parent merge commit:

```bash
git add <resolved-files>
git commit --no-edit
```

Pass `-m "..."` instead of `--no-edit` if you want the message to note what the resolution did.
If the project wraps commits in its own script or hook, use that instead of raw `git commit`.

**Rebase in progress:** continue, once per conflicting commit:

```bash
git add <resolved-files>
git rebase --continue
```

**Cherry-pick in progress:**

```bash
git add <resolved-files>
git cherry-pick --continue
```

## When to stop instead of finishing

Resolve by default. Don't reach for `--abort` to dodge a hard conflict. Abort **only** to
deliberately abandon the operation (for example the user decides not to merge after all):
`git merge --abort`, `git rebase --abort` or `git cherry-pick --abort`. If you are unsure which
intent should win and the choice is consequential, stop and ask the user rather than guessing.
