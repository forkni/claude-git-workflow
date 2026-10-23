# Wrapper Recipes

Exact commands, flags and caveats for each wrapper operation. [SKILL.md](../SKILL.md) keeps the
rules and a one-line index; read the matching section here before running an operation, and do not
improvise flags. Every rule in SKILL.md still applies to these recipes.

## Committing code

```text
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
├─ Yes → Code lint: run ./scripts/git/fix_lint.sh then retry commit
│         Markdown lint: commit_enhanced.sh offers auto-fix inline (interactive prompt,
│         or automatic when non-interactive) via CGW_MARKDOWNLINT_CMD (auto-detected)
└─ No  → Commit proceeds

Optional flags: --skip-lint (skip all lint), --skip-md-lint (skip markdown lint only),
                --sign (GPG/SSH-sign the commit), --no-sign (override CGW_SIGN_COMMITS),
                --strict-untracked (refuse when untracked files are left out),
                --no-untracked-check (silence the untracked-file warning)

Typecheck: advisory in the pre-commit hook (when CGW_TYPECHECK_CMD is set), BLOCKING in
           check_lint.sh/push_validated.sh. A failing typecheck blocks a push; --skip-typecheck
           (or CGW_SKIP_TYPECHECK=1) bypasses it. Not run under --md-only/--modified-only, and
           not run by commit_enhanced.sh — see script-reference.md.
           If the push gate fails ONLY because of uncommitted work in the tree, re-run with
           --pushed-only (or CGW_PUSH_LINT_SCOPE=pushed) -- do NOT reach for --skip-typecheck /
           --skip-lint, which also stop checking the commits actually being pushed.
           If --pushed-only reports "Could not check the pushed snapshot" (check_lint.sh exit 3),
           the checks did NOT run: read the log for the cause (bad ref, temp dir, extract) --
           it is not a lint error and there is no "push anyway" override. A committed file that
           imports an uncommitted module now fails the snapshot typecheck (exit 2): `git add` it.

After commit: verify with git log --oneline -1
(that single check is enough — skip any git status/diff scan beforehand; commit_enhanced.sh
already validates lint and protects local-only files internally, regardless of how the request
is phrased)
```

## Merging to target branch

Direct merge (`CGW_MERGE_MODE="direct"`):

```bash
# Preview first (no changes):
./scripts/git/merge_with_validation.sh --dry-run

# Execute merge:
./scripts/git/merge_with_validation.sh --non-interactive

# Override branch pair for this invocation (doesn't mutate config):
./scripts/git/merge_with_validation.sh --source feature/hotfix --target release/1.2 --non-interactive
```

Handles: pre-merge validation, backup tag, both-deleted conflict auto-resolution, modify/delete (DU) and content conflict detection (stop for manual review; `CGW_AUTO_RESOLVE_MODIFY_DELETE=1` opts text-file DU into auto-resolve).

**After manual conflict resolution:** when the script pauses for a content conflict (`UU`/`AA`/`AU`), resolve the markers, run `git add <file>`, then conclude the merge with `commit_enhanced.sh` — Rule 1 applies to merge-conclusion commits too. Do NOT re-run `merge_with_validation.sh`; there is no `--continue` flag. This conclude-with-the-wrapper rule is **merge-specific**: with `MERGE_HEAD` set, `commit_enhanced.sh` needs no message argument — it uses git's own prepared merge message (`# Conflicts:` comments stripped) and is exempt from the conventional-format check and the subject-length hard cap, the same way `hooks/pre-push` already exempts merge commits by parent count. Pass a message explicitly only if you want to override git's prepared one. A paused **cherry-pick** is the opposite case — it already carries the original commit's message — and concludes with `git cherry-pick --continue` instead (see *When a cherry-pick hits a conflict*, below).

Set `CGW_MERGE_MODE="pr"` in `.cgw.conf` to use the PR workflow instead (see Creating a PR below).

## Pushing to remote

```bash
./scripts/git/push_validated.sh                       # with lint check
./scripts/git/push_validated.sh --no-venv             # no .venv (forwards to check_lint.sh)
./scripts/git/push_validated.sh --dry-run             # preview
./scripts/git/push_validated.sh --pushed-only         # gate only the committed branch (ignores uncommitted work)
./scripts/git/push_validated.sh --skip-lint           # skip lint check entirely
./scripts/git/push_validated.sh --no-venv --skip-lint # both
# One call is enough on its own -- no pre-check needed, regardless of urgency or stakes in
# the request; an explicit --force-with-lease=<ref>:<sha> (resolved from a freshly-fetched
# tracking ref, not the bare form) + the protected-branch guard already cover what an extra
# git status/log would verify. A post-check IS required, though: Rule 6 — run
# verify_ci.sh --branch <the branch just pushed> and wait for exit 0, see ci-verification.md.
```

## Creating a PR

For `CGW_MERGE_MODE="pr"`:

```bash
./scripts/git/create_pr.sh                          # interactive
./scripts/git/create_pr.sh --non-interactive        # skip prompts
./scripts/git/create_pr.sh --dry-run                # preview only
./scripts/git/create_pr.sh --title "feat: my PR"   # override title
./scripts/git/create_pr.sh --task TZ-123           # title ends " [TZ-123]" (tracker link)
./scripts/git/create_pr.sh --draft                  # open as draft
./scripts/git/create_pr.sh --body-file pr-body.md   # written body instead of the commit list
./scripts/git/create_pr.sh --source feature/hotfix --target release/1.2
```

Creates a GitHub PR from source → target via `gh` CLI. Requires `gh auth login`. Reviewers and workflows see the PR as soon as it opens, so pass a written body at creation with `--body-file` (or `--body`) rather than following up with `gh pr edit`: the PR would otherwise open with the generated commit list. It prints `PR number: N` and `Head SHA: <sha>` — Rule 6 applies here too.
Run `./scripts/git/verify_ci.sh --pr N --sha <sha>` with those two values. The script waits for the PR's head to equal that SHA before judging its checks (`gh pr checks` has no SHA and would otherwise report the previous head), per ci-verification.md → *PR mode*.

Always passes `gh` an explicit `--repo <owner>/<repo>` resolved from `CGW_REMOTE`'s own URL — bare `gh pr create` resolves its own target repo and, when `CGW_REMOTE` is a fork, defaults to the fork's parent/upstream repo instead. If `CGW_REMOTE`'s URL can't be resolved to a `github.com` owner/repo, the script aborts rather than falling back to gh's own resolution. If this script ever fails or is unavailable, do not drop to raw `gh pr create` without `--repo`: it silently targets the wrong repo on a fork remote.

## Merging a PR

Only when the user asks (`CGW_MERGE_MODE="pr"`):

```bash
./scripts/git/merge_pr.sh 42                          # merge commit (default)
./scripts/git/merge_pr.sh 42 --dry-run                # validate + preview, no merge
./scripts/git/merge_pr.sh 42 --retarget 43            # then retarget stacked PR #43 onto 42's base
./scripts/git/merge_pr.sh 42 --squash --allow-non-merge   # flattens the PR; needs the explicit ack
```

Merges with `--merge` so the feature stays one revertable unit (`rollback_merge.sh --revert --target <merge-sha>`, printed on success). `--squash`/`--rebase` are refused non-interactively without `--allow-non-merge`. Refuses a PR that isn't OPEN. For stacked PRs, `--retarget <M>` (repeatable) is validated before anything is merged (M's base must be this PR's head), then run after the merge and before any `--delete-branch`; the head branch is never deleted by default. Passes the same explicit `--repo` as `create_pr.sh`. Do not merge a PR without the user's go.

## Syncing with remote

```bash
./scripts/git/sync_branches.sh              # sync current branch
./scripts/git/sync_branches.sh --all        # sync both source and target branches
./scripts/git/sync_branches.sh --branch main  # sync a specific branch
./scripts/git/sync_branches.sh --dry-run    # preview (fetch only, no merge)
./scripts/git/sync_branches.sh --prune      # also remove stale remote-tracking refs
```

Sync pulls **protected** branches (`CGW_PROTECTED_BRANCHES`) with `--ff-only` and everything else
with `--rebase=merges`. A protected branch that has diverged from the remote is **refused** (exit 1)
with the reconcile options printed -- never rebased, so local merge commits on `main` survive.

`sync_branches.sh` also protects any git **skip-worktree** local file (see `CGW_LOCAL_FILES`)
across a sync. That bit hides local disk edits from `git status`/`diff-index`, but does **not**
stop `git pull --rebase` from refusing when the incoming commit also touches the file ("local
changes would be overwritten by merge") -- previously this could abort an entire sync with `[1/4]`
misreporting the tree as "clean". The script now: (1) surfaces skip-worktree divergence at `[1/4]`
instead of hiding it, (2) before the pull, backs up and resets any diverged skip-worktree file to
HEAD so the pull can proceed, and (3) after the pull, restores the local bytes, re-applies the bit,
and **prints the upstream diff** for that file so you can reconcile new shared content -- never
silently discarding local edits. No-op when no skip-worktree file has diverged (the common case).

## Rollback a merge

```bash
./scripts/git/rollback_merge.sh                          # interactive (hard reset)
./scripts/git/rollback_merge.sh --revert                 # safe revert (preserves history, no force-push)
./scripts/git/rollback_merge.sh --dry-run
./scripts/git/rollback_merge.sh --non-interactive --target pre-merge-20260101_120000-12345
```

Guards: `--revert` only ever reverts `HEAD` (when it is a merge) or an explicit `--target` merge
-- never `HEAD~1` or a backup tag. Hard mode auto-picks the latest `pre-merge` tag only when it is
`HEAD^1`; otherwise `--non-interactive` refuses and wants an explicit `--target`. **After a
revert, revert the revert** (`git revert <revert-sha>`, printed by the script) before merging the
same branch again, or the original work silently stays out -- see `error-recovery.md`.

## Cherry-picking a commit

```bash
./scripts/git/cherry_pick_commits.sh                       # interactive
./scripts/git/cherry_pick_commits.sh --commit abc1234      # non-interactive
./scripts/git/cherry_pick_commits.sh --dry-run --commit abc1234
./scripts/git/cherry_pick_commits.sh --source feature/hotfix --target release/1.2 --commit abc1234
./scripts/git/cherry_pick_commits.sh --commit abc1234 --only src/a.py --only docs/  # partial pick
```

Picks record their origin with `(cherry picked from commit <sha>)` (`git cherry-pick -x`); pass
`--no-x` to omit it.

**When a cherry-pick hits a conflict:** `cherry_pick_commits.sh` exiting 1 with conflict
markers in the tree is a **hand-over, not a crash** — the pick is paused mid-flight
(`.git/CHERRY_PICK_HEAD` exists) and git is waiting for you. Finish it in place:

1. Inspect both sides before editing — `git status` for the conflicted paths, then
   `git log --merge -p <file>` (and/or `git diff`) to see the competing changes in context.
2. Resolve the markers, then `git add <file>` for each resolved path.
3. Conclude with **`git cherry-pick --continue`**. This is the one commit the wrappers do
   NOT make for you: the paused pick already carries the original commit's message and
   authorship, and `--continue` commits with them preserved. Do **not** conclude via
   `commit_enhanced.sh` (that abandons the pick's metadata and authors a brand-new commit —
   the merge-conclusion rule above does not apply here) and do **not** re-run
   `cherry_pick_commits.sh` (it would start a second pick on top of the paused one).
4. `git cherry-pick --abort` exists only for genuinely abandoning the pick — never use it
   just to dodge a resolvable conflict and retry.

## Cherry-picking only some files from a commit

Split or partial cherry-pick.

`cherry_pick_commits.sh` supports this natively with `--only <pathspec>` (repeatable, one
pathspec per flag — same convention as `commit_enhanced.sh --only`):

```bash
./scripts/git/cherry_pick_commits.sh --commit <hash> --only src/a.py --only docs/
```

It applies the commit with `--no-commit`, drops the unselected paths from index and working
tree, and commits the selected subset under the original message plus a
`(partial cherry-pick of <hash> -- only: ...)` note. Two behavioral differences from a full
pick: `--only` matching **no** files in the commit is an error (exit 1, nothing applied), and
a **conflict aborts the partial pick entirely** — there is no paused hand-over in partial
mode. When a partial pick conflicts, fall back to the manual recipe:

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

## Merging docs only

```bash
./scripts/git/merge_docs.sh
./scripts/git/merge_docs.sh --non-interactive
./scripts/git/merge_docs.sh --source feature/hotfix --target release/1.2 --non-interactive
```

This copies `docs/` into a normal one-parent commit; git records no merge ancestry, so a later full
merge of the branch re-applies those docs changes.

## Undoing something

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

**Colliding local modification vs. incoming commit — keep or drop?** Decide on the result of
`git merge-file -p <local> <base = old HEAD> <upstream>` written to the scratchpad: if local contains
every upstream hunk, keep local. Blob hashes and memory of which side is newer decide nothing, and
`discard` has no `--yes` (non-interactive runs abort by design).

## Branch cleanup

```bash
# Dry-run preview (safe default — shows what would be deleted):
./scripts/git/branch_cleanup.sh

# Execute: delete merged local branches:
./scripts/git/branch_cleanup.sh --execute

# Also prune stale remote-tracking refs:
./scripts/git/branch_cleanup.sh --execute --remote

# Also clean up old backup tags:
./scripts/git/branch_cleanup.sh --tags --execute
```

## Safe rebase

```bash
# Rebase current branch onto target:
./scripts/git/rebase_safe.sh --onto main

# Rebase with auto-stash (stash dirty tree before, restore after):
./scripts/git/rebase_safe.sh --onto main --autostash

# Move only this branch's own commits (everything after 'server') onto main
# (git rebase --onto main server):
./scripts/git/rebase_safe.sh --onto main --upstream server

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

## Bisecting a bug

```bash
# Automated: provide a test command
./scripts/git/bisect_helper.sh --good v1.0.0 --run "bash tests/smoke_test.sh"

# Manual: mark commits good/bad interactively
./scripts/git/bisect_helper.sh --good v1.0.0

# Abort stuck session:
./scripts/git/bisect_helper.sh --abort
```

## Generating a changelog

```bash
./scripts/git/changelog_generate.sh --from v1.0.0           # since tag → stdout
./scripts/git/changelog_generate.sh --from v1.0.0 --output CHANGELOG.md

# At release time, before the new tag exists: --version supplies the heading, and
# --prepend stacks the new section above CHANGELOG.md's existing content (cumulative).
./scripts/git/changelog_generate.sh --from v1.0.0 --version v1.1.0 \
  --output CHANGELOG.md --prepend
```

## Stashing work in progress

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

## Creating a release

```bash
./scripts/git/create_release.sh v1.2.3 --push             # tag + push (triggers GitHub Release)
./scripts/git/create_release.sh v1.2.3 --push --sign      # GPG/SSH-signed annotated tag
./scripts/git/create_release.sh v1.2.3 --dry-run
./scripts/git/create_release.sh archive/pre-rewrite --allow-non-semver   # non-semver archive tag (no GitHub Release)
```

`--push` triggers `release.yml` (tag push matching `v*`) — Rule 6 applies: run
`./scripts/git/verify_ci.sh --branch v1.2.3` with the tag name (the script resolves `refs/tags/<name>`
when no branch matches) and wait for exit 0 before considering the release done.

Before tagging (CI green on the release commit, version bumped, changelog generated, rollback plan
and triggers written down) and after it (tag CI green, release assets smoke-checked), follow
[release-checklist.md](release-checklist.md).

## Recovering lost commits

Reflog and fsck:

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

## Worktree management

Parallel branch checkouts:

```bash
./scripts/git/worktree_manage.sh list                          # show all worktrees
./scripts/git/worktree_manage.sh add ../hotfix hotfix/urgent   # add linked worktree
./scripts/git/worktree_manage.sh link                          # give this worktree CGW script shims
./scripts/git/worktree_manage.sh remove --execute --non-interactive ../hotfix  # remove worktree
./scripts/git/worktree_manage.sh prune                         # dry-run: show stale admin files
./scripts/git/worktree_manage.sh prune --execute               # remove stale admin files
```

**Never remove a worktree with raw `git worktree remove`** (the guardrail blocks it) — always use
`worktree_manage.sh remove --execute` (add `--non-interactive` from an agent: without a
confirmation answer it prints `Cancelled` and removes nothing). On Windows, worktrees linked by older CGW versions hold NTFS
junctions into the main checkout, and git's recursive delete follows them and empties the main
checkout's gitignored `scripts/git` and `.githooks`.

If a hook reports `CGW not found` inside a linked worktree, run `link` — see
[error-recovery.md](error-recovery.md#cgw-not-found-linked-worktree).

## Project setup & hygiene

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
./scripts/git/repo_state.sh                   # read-only state snapshot + suggested next step (--json for JSON)
```

There is no `setup_gitignore.sh` — unlike `.gitattributes`, `.gitignore` is hand-composed.
Only `configure.sh` touches it, and only two ways: a fresh install appends three entries
(`logs/`, `.cgw.conf`, `.cgw.conf.bak`); `--reconfigure` appends just `.cgw.conf.bak` when it
backs up an existing config. Neither path rewrites or reorders your existing rules. See
[gitignore-templates.md](gitignore-templates.md) for stack templates,
`Global` OS/editor rules, and the CGW baseline block to compose one.

## Checking what changed on your branch

```bash
./scripts/git/branch_diff.sh                 # full patch vs the auto-detected default branch
./scripts/git/branch_diff.sh --files         # changed file names only
./scripts/git/branch_diff.sh --stat --no-ws  # diffstat, ignoring whitespace
```

Read-only; safe with a dirty working tree. Auto-detects `main` vs `master` vs a custom default via `${CGW_REMOTE}/HEAD`, falling back to `CGW_TARGET_BRANCH`.

## Reviewing a PR locally

```bash
./scripts/git/pr_checkout.sh 42                          # check out PR #42
./scripts/git/pr_checkout.sh --pr 42 --branch review/pr-42
```

Wraps `gh pr checkout`. Requires `gh auth login`. Refuses to switch branches over uncommitted tracked changes unless `--force` is passed — stash first with `stash_work.sh push`.

## Generating or updating a Markdown Table of Contents

```bash
./scripts/git/md_toc.sh docs/usage.md --insert   # insert/update TOC in place
./scripts/git/md_toc.sh docs/usage.md --check    # CI: fail if the TOC is stale
./scripts/git/md_toc.sh --all                    # update every tracked *.md with a <!--ts--> marker
```

Computes GitHub-compatible anchor slugs offline — no network access or auth token needed.
