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
reverting several already-pushed commits at once without rewriting history):

```bash
git revert --no-commit A..HEAD && git commit -m "revert: undo A..HEAD"
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

```
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
