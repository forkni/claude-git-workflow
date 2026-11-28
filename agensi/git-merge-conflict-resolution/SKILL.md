---
name: git-merge-conflict-resolution
description: Resolves git merge, rebase and cherry-pick conflicts by working out what each side intended, using the three-way view, preserving compatible changes and re-running checks before concluding. Use when a merge, rebase, pull or cherry-pick stops on conflicts (UU, AA, AU, UA, UD, DU or DD in git status), or when you need to investigate history to understand why two branches diverged.
---

# Git Merge Conflict Resolution

A conflict stop means the repository is mid-operation and git is waiting for a human-quality
decision. A careless resolution silently ships wrong code, so resolve by intent, not by picking a
side.

Full procedure: [references/resolving-merge-conflicts.md](references/resolving-merge-conflicts.md).
History-investigation techniques (pickaxe, merge-base, blame triage, revert-the-revert):
[references/git-recipes.md](references/git-recipes.md).

## Core rules

1. **Look before you edit.** Run `git status` to see whether a merge or a rebase is in progress
   and which paths conflict. The two are concluded differently.
2. **Find each side's intent first.** For every conflicted file run
   `git log --merge -p -- <file>` and `git log --oneline --left-right --merge`, and read the
   commit messages. Never run `git checkout --ours/--theirs` blind.
3. **Read the three-way view.** `git -c merge.conflictStyle=zdiff3 checkout --merge -- <file>`
   adds the common ancestor, so you can see which side actually changed a line.
4. **Preserve both intents where they are compatible.** Pick one side only when the changes are
   genuinely exclusive, and tell the user what was dropped. Never invent new behaviour to bridge
   the sides. Remove every conflict marker.
5. **Re-run the project's lint and tests before concluding.** A resolved-but-broken merge is worse
   than a stopped one.
6. **Conclude the operation the way it started:** `git add` the resolved files, then
   `git commit` (no message: git's prepared merge message is right) for a merge,
   `git rebase --continue` for a rebase, `git cherry-pick --continue` for a cherry-pick.
7. **Abort only to abandon the operation on purpose** (`git merge --abort`,
   `git rebase --abort`), never to dodge a hard conflict. If the right intent is unclear and the
   choice matters, stop and ask the user.

## Conflict codes at a glance

| Code | Meaning (git status) | Default action |
|------|---------|----------------|
| `UU` | both modified | resolve hunk by hunk |
| `AA` | both added | merge the two versions, or pick one deliberately |
| `AU` / `UA` | added by us / added by them | compare the stages with `git show :2:<file>` (ours) and `git show :3:<file>` (theirs), then resolve like `UU` |
| `DU` | deleted by us, modified by them | ask: keep their version (`git add`) or the deletion (`git rm`) |
| `UD` | modified by us, deleted by them | ask: keep our version (`git add`) or the deletion (`git rm`) |
| `DD` | both deleted | safe: `git rm <file>` |

If the path is git-ignored or meant to stay local, use `git rm --cached <file>` instead of
`git rm`: plain `git rm` also deletes the working copy.

Source and full toolkit: <https://github.com/forkni/claude-git-workflow> (MIT).
