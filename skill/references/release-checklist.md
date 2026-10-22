# Release checklist

Run this around `create_release.sh`. The script only creates and pushes the annotated tag; it does
not check CI, bump a version or write the changelog. This list covers what the script leaves to you.
Shape adapted from Anthropic's `engineering/deploy-checklist` (pre-deploy, deploy, verify, rollback),
cut down to what a tag-driven release needs.

A release is cheap to make and awkward to take back: a pushed tag may already have triggered
`release.yml`, and users may have downloaded the assets. Write the rollback plan **before** tagging.

## Before the release

- [ ] **On the release branch, up to date, tree clean.** Run from `CGW_TARGET_BRANCH` (default
  `main`); `create_release.sh` refuses any other branch. It does not check the tree, so confirm
  `git status` is clean yourself.
- [ ] **CI is green on the release commit.** Not "green on `development` last week": check the exact
  commit that will be tagged.

  ```bash
  ./scripts/git/verify_ci.sh --branch main      # exit 0 required; the commit tagged is this branch head
  ```

  Exit `2` (unverified) or `1` (red) means no tag. See [ci-verification.md](ci-verification.md).
- [ ] **Version bumped everywhere it lives.** Package metadata, `__version__`, plugin manifests, docs
  that quote it. The tag name and these must agree. Grep for the previous version string.
- [ ] **Changelog generated and reviewed.** Draft it from the commits, then edit by hand: group by
  user-visible effect, call out breaking changes first.

  ```bash
  ./scripts/git/changelog_generate.sh --from v1.2.2 --version v1.2.3 --output CHANGELOG.md --prepend
  ```

  Commit the changelog and version bump (through `commit_enhanced.sh`) and push them before tagging,
  so the tagged commit contains them. Re-run the CI check above on the new head.
- [ ] **Rollback plan written down, with triggers.** One short block in the PR, the release notes
  draft or the session log, naming:
  - **Trigger**: the observable that means "roll back" (a failing smoke check, an error report in the
    first N hours, a broken install path).
  - **Action**: yank the release and tag (see below), or ship `vX.Y.(Z+1)` forward. Pick one now.
  - **Owner and window**: who decides, and how long the release is watched.
- [ ] **Dry run.** `./scripts/git/create_release.sh vX.Y.Z --dry-run` shows the tag and target commit.

## Release

```bash
./scripts/git/create_release.sh vX.Y.Z --push        # add --sign if CGW_SIGN_TAGS is not set
```

`--push` triggers `release.yml`. The release is not done at this point.

## After the release

- [ ] **The tag's CI passes.** This is the Rule 6 gate for the tag push:

  ```bash
  ./scripts/git/verify_ci.sh --branch vX.Y.Z           # exit 0 required
  ```

  The default timeout can exceed the Bash tool's cap: run it in the background or pass `--timeout`.
- [ ] **Release assets smoke-checked.** Confirm the GitHub Release exists and the assets are the
  expected ones, then exercise one of them the way a user would:

  ```bash
  gh release view vX.Y.Z --json tagName,isDraft,assets --jq '{tagName, isDraft, assets: [.assets[].name]}'
  ```

  - The release is published (`isDraft` false) and lists the source archives (and any built assets).
  - Download one asset and run the smallest real use: install it into a scratch directory, import it,
    or run `--version`. A release nobody opened is not verified.
- [ ] **Changelog and docs match the tag.** The release notes read correctly; the README install
  line points at the new version if it pins one.
- [ ] **Watch window observed.** Check against the rollback triggers at the end of the window named
  above, then record the outcome ("v1.2.3 shipped, no rollback triggers hit").

## If a rollback trigger fires

Prefer rolling **forward** (a patch release) when the fix is small and understood. Yank only when the
release is harmful to keep available.

```bash
gh release delete vX.Y.Z --yes                  # unpublish the Release (assets disappear)
git push origin --delete vX.Y.Z                 # remove the remote tag
git tag -d vX.Y.Z                               # remove the local tag
```

Deleting a pushed tag is destructive and outward-facing: do it only on the owner's explicit say-so,
and say what was removed. Anyone who already fetched the tag keeps it, so a yanked version number is
never reused: the fix ships as the next patch version.

## Common rationalizations

| Rationalization | Reality |
|---|---|
| "CI was green on development" | The tagged commit is on the release branch, after a merge. Check that commit. |
| "I'll write the rollback plan if it breaks" | Under pressure you decide worse. The triggers cost five minutes now. |
| "The tag push passed, so the release is fine" | A workflow can succeed and publish the wrong or empty assets. Open one. |
| "Reuse the version, nobody downloaded it yet" | Caches and mirrors already did. Ship a new patch number. |

## Verification

- [ ] `verify_ci.sh --branch <release branch>` exited 0 on the commit being tagged.
- [ ] Version, changelog and tag name agree.
- [ ] A rollback plan with triggers existed before `create_release.sh --push` ran.
- [ ] `verify_ci.sh --branch vX.Y.Z` exited 0 after the push.
- [ ] One release asset was downloaded and used.
