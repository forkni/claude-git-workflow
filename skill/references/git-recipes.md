# Git Recipes

Non-obvious git techniques distilled from a broader git/GitHub cheat-sheet
(stas00/git-tools' `git.txt`). Each entry is framed **Goal → CGW wrapper (if
one exists) → raw-git recipe**. Always reach for the CGW wrapper first — it
adds logging, backup tags, and safety guards the raw recipe does not. Use the
raw recipe only for read-only inspection or when no wrapper covers the case.

---

## What changed on this branch?

**Wrapper:** `./scripts/git/branch_diff.sh` (full patch, `--files`, `--stat`, `--base <ref>`).

Raw equivalent (triple-dot = merge-base relative, excludes changes already on
the default branch):

```bash
git diff origin/main...HEAD
git diff --name-only origin/main...HEAD
```

---

## Fetch or check out a GitHub PR locally

**Wrapper:** `./scripts/git/pr_checkout.sh <PR-number>` (wraps `gh pr checkout`).

Raw equivalent, when `gh` is unavailable — add a fetch refspec once per remote,
then fetch any PR as a local branch:

```bash
git config --add remote.origin.fetch '+refs/pull/*/head:refs/remotes/origin/pr/*'
git fetch origin
git checkout origin/pr/42 -b review/pr-42
```

---

## Search history for when a string was added or removed (pickaxe)

No wrapper — read-only inspection, always safe to run directly.

```bash
git log -S'someFunctionName' --oneline          # commits that changed the string's occurrence count
git log -G'someFunc\(' --oneline                # commits whose diff matches a regex
git log -p -S'someFunctionName' -- src/         # show the actual diffs, scoped to a path
git log --oneline --all -- ":(exclude)vendor/*" # exclude a path from the search
```

---

## Squashing commits before a PR

**Wrapper:** `./scripts/git/rebase_safe.sh --squash-last <N>` (interactive editor)
or `--squash-last <N> --autosquash` (non-interactive, uses `fixup!`/`squash!`
commit-message prefixes). Creates a `pre-rebase-*` backup tag first.

Raw equivalent (soft-reset method — only use if the wrapper genuinely can't
cover your case):

```bash
git reset --soft HEAD~3 && git commit -m "feat: squashed change"
```

---

## Finding the branching point (merge-base) between two branches

No wrapper — read-only inspection.

```bash
git merge-base main feature/x                       # SHA where feature/x diverged
git log --oneline "$(git merge-base main feature/x)"..feature/x   # commits unique to feature/x
```

Useful before a `backport-check`-style audit: find commits on a release
branch not yet on main, excluding version/changelog churn:

```bash
git log --oneline "$(git merge-base main release/1.2)"..origin/release/1.2 \
  -- ":(exclude)CHANGELOG.md" ":(exclude)version.py"
```

---

## Back-dating an annotated tag to preserve a past commit's date

No wrapper (`create_release.sh` always tags at the current time by design).

```bash
GIT_COMMITTER_DATE="$(git show --format=%aD --no-patch abc1234)" \
  git tag -a v1.0.0 abc1234 -m "Release 1.0.0"
```

---

## Reverting / undoing (choosing the right tool)

**Wrappers, by scenario:**

- Undo the last local commit, keep changes staged → `./scripts/git/undo_last.sh commit`
- Unstage a file → `./scripts/git/undo_last.sh unstage <file>`
- Fix the last commit message (before push) → `./scripts/git/undo_last.sh amend-message "..."`
- Roll back a merge already on the target branch → `./scripts/git/rollback_merge.sh --revert`
  (safe, no force-push) or without `--revert` (hard reset + requires typing `ROLLBACK`)
- Recover a commit no longer reachable from any branch → `./scripts/git/recover.sh dangling`
  then `./scripts/git/recover.sh restore <sha> --branch <name>`

Raw equivalent for a published range revert (when no wrapper fits — e.g.
reverting several already-pushed commits at once without rewriting history).
`--no-commit` stages the reverts of the whole range without creating one
commit per original commit; `--continue` is only needed if a hunk in the
range conflicts:

```bash
git revert --no-commit A..HEAD
git revert --continue   # only if a conflict stopped the range mid-way
git commit -m "revert: undo A..HEAD"
```

**Undoing a merge/pull that just happened, before you've done anything else**
— no wrapper (the backup-tag wrappers assume you're rolling back a merge that
was already committed and possibly pushed; this is for the "I just ran
`git pull` and it created a merge commit / brought in the wrong branch"
moment, seconds after it happened):

```bash
git reset --merge ORIG_HEAD
```

`ORIG_HEAD` is git's own "before the last drastic operation" pointer — it
survives exactly one merge/pull/rebase, so this only works immediately
after. If you have uncommitted work you don't want to lose, preserve it
first:

```bash
git branch preservation_branch     # safety net, costs nothing, delete later
git reset --merge ORIG_HEAD
```

**Which branches already contain a given commit** (e.g. confirming a hotfix
made it onto both `development` and `main` before deleting the hotfix
branch):

```bash
git branch --contains <sha>        # local branches
git branch -a --contains <sha>     # local + remote-tracking
```

---

## Inspecting a stash without popping it

No wrapper beyond `./scripts/git/stash_work.sh show [ref]` (single stash). For
comparing two stashes directly:

```bash
git diff stash@{0} stash@{1}
```

---

## Viewing a PR or commit as a raw diff/patch (no local checkout)

No wrapper — this is a GitHub URL trick, not a git operation.

```text
https://github.com/<owner>/<repo>/pull/<N>.diff
https://github.com/<owner>/<repo>/pull/<N>.patch
https://github.com/<owner>/<repo>/commit/<sha>.patch
```

---

## Repo-wide search-and-replace (never touching `.git/`)

No wrapper — this is a one-off text operation, not a git operation. Prefer
`git grep -l` to scope the file list before editing:

```bash
git grep -l 'OLD_NAME' | xargs sed -i 's/OLD_NAME/NEW_NAME/g'
```

---

## Was a commit a true merge or a fast-forward?

No wrapper — read-only inspection. Useful when history looks odd and you need
to know whether a merge commit actually combined two histories or just moved
a pointer:

```bash
git log --oneline --graph -20              # visual shape of recent history
git show --no-patch <sha>                  # "Merge: <parent1> <parent2>" line = true merge
```

A commit with only one `Merge:` parent listed (or no `Merge:` line at all)
is not a two-parent merge commit — `--no-ff` in `merge_with_validation.sh`
means every CGW-driven merge produces a true merge commit, so a fast-forward
here means something merged outside the wrapper.

---

## Staging part of a file (hunk-level)

No wrapper — `commit_enhanced.sh`'s `--only <path>` (see SKILL.md Rule 5)
stages whole files by intent; use `git add --patch` when a single file mixes
a change you want to commit now with one you don't:

```bash
git add --patch <file>     # y/n/s/e per hunk; 's' to split a hunk further
```

Then continue with `commit_enhanced.sh` as usual. It never silently widens
a partial stage: an auto-fix re-stage skips any file whose staged blob was
already deliberately different from disk, and the staged-blob congruence
guard fails the commit closed if a lint-eligible (or linted `.md`) file
still diverges from what CGW validated. If that's genuinely what you want —
commit exactly the hunk you staged, unvalidated content and all — opt in
explicitly with `CGW_ALLOW_STAGED_DIVERGENCE=1`, or bypass validation
entirely with `--skip-lint`. See `cgw.conf.example`'s "STAGED-BLOB CONGRUENCE
GUARD" section for the full contract.

---

## Cherry-picking with provenance, or from a merge commit

`./scripts/git/cherry_pick_commits.sh` handles the CGW-managed cherry-pick
flow (branch validation, backup tag). Two raw-git flags worth knowing when
you need them directly:

```bash
git cherry-pick -x <sha>            # appends "(cherry picked from commit <sha>)"
git cherry-pick --mainline 1 <sha>  # required when <sha> is itself a merge commit
```

`-x` is pure upside for traceability (costs nothing, makes the origin of the
change discoverable later via `git log --grep`) — prefer it whenever the
cherry-picked commit will live in a shared/long-lived branch.
`--mainline 1` picks the diff relative to the merge's first parent; omit it
and git refuses to cherry-pick a merge commit at all.

---

## Triaging a suspicious line: blame → log/show/diff

No wrapper — read-only inspection. `git blame` only tells you which commit
last touched a *surviving* line; if the line was deleted and re-added by a
different commit, blame points at the wrong one — fall back to the pickaxe
search above (`git log -S`) in that case.

```bash
git blame -L 40,60 -- <file>   # which commit last touched each line in range
git log <sha>                  # why: commit message / ticket reference
git show <sha>                 # what: the actual diff introduced by <sha>
git diff <sha> -- <file>       # since: everything that changed in <file> after <sha>
```

---

## Comparing a working ref against a broken one

No wrapper — read-only inspection. Once you've narrowed down a "this used to
work" regression to two refs (a known-good tag/commit vs. the current
broken state), the commit range itself tells you the candidate set before
reaching for `bisect_helper.sh`:

```bash
git log --oneline working..broken     # commits present on broken but not working
git log --oneline HEAD^..HEAD         # just the last commit
git log --oneline HEAD~3..HEAD        # last 3 commits
git fetch origin && git log --oneline HEAD..origin/main   # what main has that you don't
```

---

## Recovering from a corrupted index (not a stale lock)

If `ensure_no_stale_index_lock` (Rule 4 in SKILL.md) doesn't apply — this is a
different failure mode (a genuinely corrupt `.git/index`, not an abandoned
lock file):

```bash
rm "$(git rev-parse --git-dir)/index"
git reset
```

For lock-file issues specifically, see SKILL.md Rule 4 instead — do not use
this recipe for a stuck `index.lock`.
