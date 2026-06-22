# Resolving Merge & Rebase Conflicts

CGW's scripts auto-resolve the *safe* conflict classes (`DU`, `DD`) and **stop**
on the ones that need a human decision (`UU`, `AA`, `AU`, `UD`, `AD`, `DA` — see
[branch-and-merge-rules.md](branch-and-merge-rules.md#conflict-resolution)). When
the workflow stops, the index is mid-merge or mid-rebase and it is your job to
resolve the conflicting hunks *correctly* before completing. Routing to a wrapper
is not enough — a bad resolution silently ships wrong code. Follow this procedure.

## 1. See the current state

Don't edit blind. Establish what is in progress and what conflicts:

```bash
git status                       # merge vs rebase in progress; conflicted paths
git diff --name-only --diff-filter=U   # just the unmerged files
```

`git status` tells you whether you are in a merge (`MERGE_HEAD` exists) or a
rebase (`rebase-merge/`/`rebase-apply/` exists) — the two are completed
differently (step 5).

## 2. Find each side's intent before you touch a hunk

This is the step that turns a guess into a resolution. For every conflicted hunk,
understand **why both sides changed it** — never pick `--ours`/`--theirs` blind:

```bash
git log --merge -p -- <file>     # commits on each side that touch this file
git log --oneline --left-right --merge   # which side each conflicting commit came from
```

Read the commit messages (and the PR/issue they reference) for the conflicting
commits. The goal is to know the *purpose* of each change, not just its text.

## 3. Resolve each hunk

- **Preserve both intents where they are compatible.** Most conflicts are two
  independent edits to nearby lines — keep both. Reach for `--ours`/`--theirs`
  only when the changes are genuinely mutually exclusive.
- **When incompatible, pick the side that matches the merge's stated goal** and
  note the trade-off to the user.
- **Do not invent new behaviour** to bridge the two sides — resolve to what one
  or both sides actually intended.
- Remove every conflict marker (`<<<<<<<`, `=======`, `>>>>>>>`).

`git checkout --ours <file>` / `--theirs <file>` (then `git add <file>`) are
available for whole-file decisions, but a per-hunk edit is usually the right
resolution.

## 4. Re-run the project's checks before completing

A resolved-but-broken merge is worse than a stopped one. Verify:

```bash
./scripts/git/check_lint.sh        # add --no-venv if no .venv is present
./scripts/git/fix_lint.sh          # if lint failed, auto-fix then re-check
# plus the project's tests for the touched area, if any exist
```

The pre-commit hook also lints on the concluding commit, but run the check now so
you find problems before finalizing, not after.

## 5. Complete the operation (the CGW-correct way)

Stage the resolved files, then finish via the wrapper for the operation in
progress — **not** raw `git`:

**Merge in progress** — conclude through `commit_enhanced.sh`. With `MERGE_HEAD`
set, `git commit -m` produces a proper two-parent merge commit, and the wrapper
keeps lint, local-file protection, and logging in place:

```bash
git add <resolved-files>
./scripts/git/commit_enhanced.sh "fix: resolve merge conflict in <file>"
```

> **Why not raw `git commit`?** The CGW PreToolUse guardrail blocks every
> `git commit` (it cannot tell a merge-conclusion commit from a normal one).
> `commit_enhanced.sh` is the guardrail-safe path and still finalizes the merge.
> Do **not** pass `--only` here — that resets the index and breaks the merge
> state; let the default path stage the resolved tree.

**Rebase in progress** — continue through the safe wrapper:

```bash
git add <resolved-files>
./scripts/git/rebase_safe.sh --continue     # repeat per conflicting commit
```

## When to stop instead of finishing

Resolve by default — don't reach for `--abort` to dodge a hard conflict. Abort
**only** to deliberately abandon the operation (e.g. the user decides not to
merge): `git merge --abort` or `./scripts/git/rebase_safe.sh --abort`. If you are
unsure which intent should win and the choice is consequential, stop and ask the
user rather than guessing.
