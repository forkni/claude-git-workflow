# Modify/delete conflicts halt by default

**Status**: accepted

## Context

`cgw_resolve_safe_conflicts` auto-resolved `DU` conflicts (we deleted a file, they modified it) with
`git rm`. That keeps the deletion and discards the other side's modification without a word — for a
text file it can be recovered from history, for a binary asset edited on the other branch it is a
silent loss of work that nobody reviews. The auto-resolve was justified by one scenario: dev-only
files that exist on the source branch but were deliberately never promoted to the target. That is a
repo-specific workflow, not a property of every merge or cherry-pick.

## Decision

- `DU` halts by default in `merge_with_validation.sh` and `cherry_pick_commits.sh`. The message lists
  the paths and the two choices: `git rm <file>` (accept the deletion) or `git add <file>` (keep their
  version).
- `CGW_AUTO_RESOLVE_MODIFY_DELETE=1` opts back in to the old behaviour for **text** files only. A path
  is binary when gitattributes mark it `binary` or `-diff`, or when the first 8000 bytes of its
  stage-3 (theirs) blob contain a NUL. Binary `DU` paths always halt, even with the opt-in.
- `DD` (both sides deleted) stays auto-resolved: there is nothing to lose.

## Considered and rejected

- **Keep auto-resolving, halt for binaries only.** Cheaper for the dev-only-files case, but text edits
  would still be dropped unseen, and "text is recoverable from history" is only true if someone notices.
- **Always halt, no opt-in.** Forces a manual step on repos where dev-only files are the norm and
  every promotion would stop on them.
- **Opt-in that also covers binaries.** The opt-in is a statement about routine dev-only files; it
  cannot know that a particular binary is disposable.

## Consequences

Merges and cherry-picks that previously completed (or stopped only with `--continue`) now stop with
exit 1 on a `DU` conflict. Repos that relied on the auto-resolve set
`CGW_AUTO_RESOLVE_MODIFY_DELETE=1` in `.cgw.conf`. This is a behaviour change and is called out in the
changelog.
