# Removing a Secret or Local-Only File That Was Already Committed

SKILL.md Rule 3 and the pre-commit/pre-push hooks (`cgw_is_local_file` in
`_common.sh`) are **preventive** — they stop a configured `CGW_LOCAL_FILES`
path from being committed *going forward*. Neither one helps once a secret
or local-only file is already sitting in history: that happens when the file
predates CGW, when `CGW_LOCAL_FILES`/`.gitignore` didn't cover it yet, or
when someone bypassed the guard. This doc is the procedure for that
already-happened case. Work through it in order — don't skip to step 4.

## 1. Rotate first, always

If the committed content is a real credential (API key, token, password) and
it has been **pushed** to any remote, treat it as compromised the moment it
leaves your machine — "Published History Is Public History" (Git for
Teams). Rotate/revoke the credential at its source *before* spending any
time on history surgery. Rewriting history does not un-expose a secret that
was ever pushed; anyone who fetched, forked, or has repo access before the
rewrite may already have a copy, and GitHub/GitLab caches can retain
"deleted" commits for a period. History cleanup below is about hygiene and
future-proofing the repo, not about undoing the exposure — rotation is what
actually neutralizes it.

If it was only ever committed **locally** and never pushed, rotation is
optional but still cheap insurance — do it if the credential is easy to
rotate.

## 2. Diagnose what's actually tracked

```bash
git status --ignored              # shows ignored files too, not just tracked/modified
git ls-files -- <path>             # is this path actually tracked by git?
git log --all --oneline -- <path>  # which commits touched it, and is it still current
```

**Mental model:** `.gitignore` only filters paths that are *not already in
the index*. Adding a path to `.gitignore` after it's been committed does
nothing on its own — the file stays tracked and continues showing as clean
in `git status` (which is the trap: it looks handled, but isn't). You must
explicitly untrack it (step 3) in addition to ignoring it.

## 3. Not yet pushed, or pushed but you just need it untracked going forward

If the file is still tracked and you want git to stop tracking it (whether
or not old commits still contain it — see step 6 if those need to be
purged):

```bash
git rm --cached <path>            # untrack, keep the file on disk
echo '<path>' >> .gitignore
```

This is the same mechanism CGW's own local-file deletion path uses — see
`commit_enhanced.sh` and the pre-push local-file guard, both of which call
`cgw_is_local_file`. Commit this through `commit_enhanced.sh` as normal; it
is not itself a rewrite of existing history, so no backup tag or
force-push is needed for this step alone.

## 4. Hiding further local edits to a file git must keep tracking

Sometimes the tracked file itself (e.g. a config template with a
locally-filled-in value) must stay tracked for other collaborators, but your
local edits to it should never be committed:

- `git update-index --assume-unchanged <path>` — tells git to assume the
  worktree copy is unchanged and skip diffing it; **fragile**, git will
  silently drop the bit on some operations (a checkout of a commit that
  touches the file, for instance) without warning.
- `git update-index --skip-worktree <path>` — the intended replacement;
  survives more operations and is what CGW itself uses. `sync_branches.sh`
  already detects and reconciles skip-worktree files that diverge from
  `HEAD` during a pull — see script-reference.md's Push & Sync section for
  the exact mechanics. Prefer this over `--assume-unchanged`.

Neither flag removes the file from history — they only affect your local
working copy going forward. If the tracked content itself is the secret,
you still need step 3 (or step 6, if it must come out of history too).

## 5. Why interactive rebase is *not* the tool for this

It's tempting to reach for `rebase_safe.sh` / interactive rebase to "just
edit out" the commit that introduced the file. Don't. Advanced Git's
warning applies directly here: rebasing replays every commit *after* the
target one on top of a changed ancestor. If the sensitive file was touched,
renamed, or referenced by anything in the commits that follow, replaying
creates a cascade of unrelated conflicts that have nothing to do with the
actual goal (removing one path) — for anything beyond "it was the very last
commit," rebase is the wrong lever.

## 6. Last resort: purging the path from all of history

Only do this when the path must be gone from every historical commit (a
real secret that needs full remediation, or a large binary that must not
exist in any clone). This **rewrites every commit SHA** from that point
forward and requires every collaborator to re-clone or hard-reset onto the
new history — coordinate before doing this on a shared branch.

Preferred modern tools — **not** built into CGW, install separately:

- [`git filter-repo`](https://github.com/newren/git-filter-repo) (the tool
  git's own docs now recommend over `filter-branch`)
- [BFG Repo-Cleaner](https://rtyley.github.io/bfg-repo-cleaner/) (simpler
  for "delete this file/pattern everywhere" cases)

Raw `git filter-branch` fallback if neither is available (native git, but
slow and its own docs call it "the way NOT to use it" for anything beyond
one-off scripts):

```bash
# Manual backup tag first -- this raw recipe isn't run through a CGW wrapper,
# so cgw_create_backup_tag (whose op list doesn't include a history-rewrite
# case) doesn't apply here; follow its naming convention by hand instead.
git tag "pre-rewrite-$(date +%Y%m%d_%H%M%S)"
git filter-branch -f --index-filter \
  'git rm --cached --ignore-unmatch -- <path>' \
  --prune-empty HEAD
```

After the rewrite:

```bash
git for-each-ref --format='delete %(refname)' refs/original | git update-ref --stdin  # drop filter-branch's backup refs
git reflog expire --expire=now --all
git gc --prune=now --aggressive
```

Then push through `push_validated.sh`'s force-with-lease path (never a bare
`git push --force`) — see SKILL.md Rule 6 and
[error-recovery.md](error-recovery.md) → *Push Failures* — and notify
collaborators to re-clone or hard-reset rather than pull/merge, since a
pull/merge on top of rewritten history recreates the very commits you just
removed.
