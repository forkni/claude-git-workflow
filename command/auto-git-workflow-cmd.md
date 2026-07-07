---
description: State-aware interactive git menu — scans the repo (uncommitted work, ahead/behind, in-progress merge/rebase, stashes) and suggests the likely next step, with categories for commit, push, sync, merge, PR, undo, release, plus a one-click full commit → push → merge → push promotion — the sole entry point for CGW git actions
---

# Auto Git Workflow

**Invocation**: `/auto-git-workflow-cmd [optional free-text intent]`

**Skill rules apply.** This command routes into the rules and per-operation command
snippets defined in
[`.claude/skills/auto-git-workflow/SKILL.md`](../skills/auto-git-workflow/SKILL.md)
(installed alongside this command). Read SKILL.md first if not already loaded —
its Core Rules (no raw `git commit`, no committing local-only files, lint-on-commit,
selective-staging intent) govern every action below. This file is the *router*,
not the rule book — do not duplicate SKILL.md's command snippets here; look them up
by section name when executing.

**Output policy**: Suppress command output except errors. Show a brief summary at the end
of whatever action was taken.

---

## Step 0: Argument shortcut

If the user invoked this command with free-text after it (e.g.
`/auto-git-workflow-cmd rebase onto main`), skip the scan and menu entirely — treat the
text as the git intent and route it directly through SKILL.md (find the matching operation
section, run its command). Only run Steps 1-2 when invoked bare.

---

## Step 1: Repo state scan (automatic — never a menu item)

Run this scan immediately on bare invocation, before showing the user anything — its
results become the menu's state-summary and suggestion lines. If SKILL.md still needs
loading, issue the Read and this Bash call in the same turn (parallel tool calls) so
the menu appears in one round-trip. Run as a **single** Bash call — every line is
read-only, safe to combine:

```bash
git fetch --quiet 2>/dev/null || true
git status --porcelain=v2 --branch
echo "--- stash ---"; git stash list | head -3
echo "--- in-progress ---"; ls "$(git rev-parse --git-dir)" 2>/dev/null | grep -E '^(MERGE_HEAD|CHERRY_PICK_HEAD|REVERT_HEAD|BISECT_LOG|rebase-merge|rebase-apply)$'
echo "--- recent ---"; git log --oneline -3
echo "--- unmerged-to-target ---"; tgt="$(git symbolic-ref -q --short refs/remotes/${CGW_REMOTE:-origin}/HEAD 2>/dev/null || echo "${CGW_TARGET_BRANCH:-main}")"; git log --oneline "$tgt..HEAD" 2>/dev/null | head -3
```

If the fetch fails (offline, no remote), continue — ahead/behind counts may just be
stale. If the whole scan errors, skip straight to the menu with no suggestion line.

### Suggestion rules — first match wins

Pick **one** suggestion from the first matching row. Do not execute anything yet.

| # | Signal in scan output | Suggested next step |
|---|---|---|
| 1 | unmerged `u` lines, or any `in-progress` marker (`MERGE_HEAD`, `rebase-merge`, …) | Finish the in-progress operation — resolve conflicts per SKILL.md's conflict procedure, or continue/abort via the matching wrapper (e.g. `rebase_safe.sh --continue`) |
| 2 | `branch.head (detached)` | Create a branch to keep the work before it becomes unreachable |
| 3 | uncommitted work — any `1`/`2`/`?` entries | Commit it — ⭐ option 1 if it should also be pushed & merged, option 2 to just commit. If they were about to switch branches, offer stash instead |
| 4 | `branch.ab +N -0` with N>0 — ahead only | Push to remote (option 3) |
| 5 | `branch.ab +0 -M` with M>0 — behind only | Pull / sync with remote (option 3) |
| 6 | ahead **and** behind — diverged | Sync first (`sync_branches.sh`), then push |
| 7 | no `branch.upstream` line | Publish the branch — push with upstream (option 3) |
| 8 | tree clean, `unmerged-to-target` non-empty (and not on the target branch) | Merge or PR to target (option 4) — or ⭐ option 1 next time work lands |
| 9 | tree clean, stash list non-empty | Restore stashed work (`stash_work.sh pop`) |
| 10 | everything clean and in sync | No suggestion — show the menu and note the tree is clean (start new work, or inspect history) |

---

## Step 2: Menu

Present a one-line state summary, the suggestion, and 6 categories as a plain
numbered list in your reply (not `AskUserQuestion` — it caps at 4 options and this
needs 6), then wait for the user's pick:

```
Repo state: on <branch> · <n> modified / <n> staged / <n> untracked · <ahead N / behind M | in sync> · <n stashes>

  ➤ Suggested: <suggestion from Step 1> — reply "y" to accept

What would you like to do?

  1. ⭐ Full promotion   — commit → push → merge/PR → push (the full pipeline)
  2. Commit & Stash      — commit, amend message, stash / restore work in progress
  3. Push, Pull & Sync   — push, publish branch, sync branches with remote
  4. Branch, Merge & PR  — merge, rebase, create/checkout a PR, cherry-pick
  5. Undo & Recover      — undo commit, unstage/discard, rollback merge, reflog rescue
  6. Release & Maintain  — tag a release, changelog, repo health, clean artifacts

Reply with a number, "y" for the suggestion, or describe what you want directly.
```

Omit the `➤ Suggested` line when rule 10 matched. Trim the state line to the facts
that are non-zero — don't print "0 stashes".

- "y" / "yes" → execute the suggested step through its category's rules below.
- Free-text → treat like Step 0 (route directly via SKILL.md) rather than forcing
  the menu.

---

## Step 3: Full promotion (option 1)

The only option that executes a multi-step sequence unprompted — all other menu
options (2-6) route to a single operation chosen via `AskUserQuestion` in Step 4.

Read
[`references/full-promotion.md`](../skills/auto-git-workflow/references/full-promotion.md)
and execute it: environment detection, then the phased pipeline (validate → commit →
push source → merge or PR → push target) with each phase as a separate Bash call.

---

## Step 4: Single-operation categories (options 2-6)

For any of options 2-6, present that category's specific actions via `AskUserQuestion`
(≤4 options, the built-in "Other" free-text catches anything not listed), then execute
the chosen action using the **exact command** from the matching SKILL.md section (do not
improvise flags — look them up). After the action completes, report its result in 1-3 lines.

When the Step 1 scan already answers a category's obvious question, use it — e.g. if
the user picks "Commit & Stash" with a dirty tree, default the conversation toward
committing those files rather than asking what they want from scratch.

### 2. Commit & Stash

| Action | SKILL.md section | Primary script |
|---|---|---|
| Commit changes | "Committing code" / Quick Decision Tree | `commit_enhanced.sh` |
| Amend last commit message (before push) | "Undoing something" | `undo_last.sh amend-message` |
| Stash work in progress | "Stashing work in progress" | `stash_work.sh push` |
| Restore stashed work | "Stashing work in progress" | `stash_work.sh pop` / `list` |

### 3. Push, Pull & Sync

| Action | SKILL.md section | Primary script |
|---|---|---|
| Push to remote (also publishes a new branch) | "Pushing to remote" | `push_validated.sh` |
| Sync current branch with remote | "Syncing with remote" | `sync_branches.sh` |
| Sync both source + target branches | "Syncing with remote" | `sync_branches.sh --all` |
| Preview sync (fetch only) | "Syncing with remote" | `sync_branches.sh --dry-run` |

### 4. Branch, Merge & PR

| Action | SKILL.md section | Primary script |
|---|---|---|
| Merge to target branch | "Merging to target branch" | `merge_with_validation.sh` |
| Create a PR | "Creating a PR" | `create_pr.sh` |
| Rebase onto a branch | "Safe rebase" | `rebase_safe.sh --onto <branch>` |
| Cherry-pick a commit | "Cherry-picking a commit" | `cherry_pick_commits.sh` |

Longer tail reachable via "Other": check out a PR locally (`pr_checkout.sh`), check
branch diff (`branch_diff.sh`), merge docs only (`merge_docs.sh`), branch cleanup
(`branch_cleanup.sh`), worktree management (`worktree_manage.sh`).

### 5. Undo & Recover

| Action | SKILL.md section | Primary script |
|---|---|---|
| Undo last commit (keep changes) | "Undoing something" | `undo_last.sh commit` |
| Unstage / discard a file | "Undoing something" | `undo_last.sh unstage` / `discard` |
| Rollback a merge | "Rollback a merge" | `rollback_merge.sh` |
| Recover lost commits | "Recovering lost commits" | `recover.sh reflog` / `restore` |

### 6. Release & Maintain

| Action | SKILL.md section | Primary script |
|---|---|---|
| Create a release (tag + push) | "Creating a release" | `create_release.sh` |
| Generate a changelog | "Generating a changelog" | `changelog_generate.sh` |
| Repo health check | "Project setup & hygiene" | `repo_health.sh` |
| Clean build artifacts | "Project setup & hygiene" | `clean_build.sh` |

Longer tail reachable via "Other": bisect a bug (`bisect_helper.sh`), regenerate
`.gitattributes` (`setup_attributes.sh`), Markdown TOC (`md_toc.sh`).

---

## Error Recovery

For lint failures, conflict types (modify/delete vs content), push errors, and
lock-file issues — see
[`references/error-recovery.md`](../skills/auto-git-workflow/references/error-recovery.md).

---

## Token Efficiency

- All successful commands: `>/dev/null 2>&1` (the Step 1 scan is the exception — its
  output is the input to the suggestion rules)
- Only show errors: remove suppression on retry
- Keep the final summary to a few lines
