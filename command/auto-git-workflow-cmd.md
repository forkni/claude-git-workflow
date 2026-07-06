---
description: Interactive git-operations menu (commit, push, sync, merge, PR, undo, release, and more) plus a one-click full commit → push → merge → push promotion — the sole entry point for CGW git actions
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
`/auto-git-workflow-cmd rebase onto main`), skip the menu entirely — treat the text as
the git intent and route it directly through SKILL.md (find the matching operation section,
run its command). Only show the menu below when invoked bare.

---

## Step 1: Top-level menu

Present these 6 options as a plain numbered/bulleted list in your reply (not
`AskUserQuestion` — it caps at 4 options and this needs 6), then wait for the user's pick:

```
What would you like to do?

  1. ⭐ Full promotion  — commit → push → merge/PR → push (the full pipeline)
  2. Commit & Stash     — commit changes, stash/pop work in progress
  3. Push, Pull & Sync  — push, sync branches with remote
  4. Branch, Merge & PR — merge, create/checkout a PR, cherry-pick, rebase, worktrees, branch cleanup/diff
  5. Undo & Recover     — undo last commit, rollback a merge, recover lost commits
  6. Release & Maintain — tag a release, generate changelog, repo health, clean build artifacts, bisect, setup

Reply with a number, or describe what you want directly.
```

If the user replies with free-text instead of a number, treat it like Step 0 (route directly
via SKILL.md) rather than forcing them through the menu.

---

## Step 2: Full promotion (option 1)

Run the preserved pipeline below. This is the only option that executes a multi-step
sequence unprompted — all other menu options (2-6) route to a single operation chosen
via `AskUserQuestion` in Step 3.

### Environment Detection

```bash
echo $OSTYPE
# Git Bash / WSL: "msys" or "linux-gnu"
# macOS: "darwin"
# If variable empty: Windows cmd.exe
```

- Git Bash / Linux / macOS → Section A below (`.sh` scripts directly)
- Windows cmd.exe → Section B below (invoke wrappers via `bash`)

Git Bash cannot execute `.sh` files' Windows-only equivalents, and cmd.exe cannot run
`.sh` files at all — always go through `bash scripts/git/<name>.sh` on cmd.exe.

### ⚠️ Bash Tool Compatibility

Execute each numbered step as a **separate** Bash call. Do not combine steps with `&&`
or `;`. Check exit codes between steps.

### Section A: Git Bash / Linux / macOS

**Phase 1 — Pre-commit validation**

1. `git checkout "${CGW_SOURCE_BRANCH:-development}" >/dev/null 2>&1`
2. `git diff --quiet && git diff --cached --quiet`
   — exit 0: no changes, report "No changes to commit", stop. exit 1: continue.
3. `./scripts/git/check_lint.sh >/dev/null 2>&1`
   — exit 0: skip to Phase 2. exit ≠0: continue.
4. `./scripts/git/fix_lint.sh`
5. `./scripts/git/check_lint.sh`
   — local-only files (CLAUDE.md, MEMORY.md, etc.) failing lint is safe to ignore
     (SKILL.md Rule 3). Still fails otherwise: stop. Passes: continue to Phase 2.

**Phase 2 — Commit to source branch**

Stage per SKILL.md Rule 5 (staging intent), then:

```bash
./scripts/git/commit_enhanced.sh --non-interactive "type: descriptive commit message"
```

(or with `--only <path>` per file for a selective commit — see SKILL.md Rule 5). Replace
`type:` with the correct conventional-commit prefix. Then capture:

```bash
git log -1 --format="%h %s"
```

**Phase 3 — Push source branch**

```bash
./scripts/git/push_validated.sh --non-interactive --skip-lint >/dev/null 2>&1
```

exit 0: continue. exit ≠0: rerun without suppression to show the error, stop.

**Phase 4 — Merge or PR**

```bash
echo "${CGW_MERGE_MODE:-direct}"
```

- `direct` (default) → **4A**: `./scripts/git/merge_with_validation.sh --non-interactive`
  — exit 0: continue to Phase 5. exit ≠0: inspect conflict type, stop, see
  `references/error-recovery.md`.
- `pr` → **4B**: `./scripts/git/create_pr.sh --non-interactive`, then
  `git checkout "${CGW_SOURCE_BRANCH:-development}" >/dev/null 2>&1`. Report:
  ```
  Workflow complete (PR mode)
  Source branch: [hash] "[message]" pushed
  PR: [url] — awaiting Charlie CI review
  ```
  and stop — CI takes over from here, do not proceed to Phase 5.

**Phase 5 — Push target branch (direct mode only)**

```bash
./scripts/git/push_validated.sh --non-interactive --skip-lint >/dev/null 2>&1
git checkout "${CGW_SOURCE_BRANCH:-development}" >/dev/null 2>&1
```

exit ≠0 on the push: rerun without suppression, stop.

**Final report (direct mode)**

```bash
git log "${CGW_SOURCE_BRANCH:-development}" -1 --format="%h %s"
git log "${CGW_TARGET_BRANCH:-main}" -1 --format="%h"
```

```
Workflow complete

Source branch: [hash] "[message]"
Target branch: [hash] merged & pushed
```

### Section B: Windows cmd.exe (Bash-mediated)

```batch
bash scripts/git/commit_enhanced.sh --non-interactive "feat: descriptive commit message"
bash scripts/git/push_validated.sh --non-interactive --skip-lint
bash scripts/git/merge_with_validation.sh --non-interactive
bash scripts/git/push_validated.sh --non-interactive --skip-lint
```

If `bash.exe` is unavailable (rare), STOP and ask the user to run from Git Bash instead
of bypassing the wrappers — SKILL.md's Core Rules are mandatory regardless of shell.

---

## Step 3: Single-operation categories (options 2-6)

For any of options 2-6, present that category's specific actions via `AskUserQuestion`
(≤4 options, the built-in "Other" free-text catches anything not listed), then execute
the chosen action using the **exact command** from the matching SKILL.md section (do not
improvise flags — look them up). After the action completes, report its result in 1-3 lines.

### 2. Commit & Stash

| Action | SKILL.md section | Primary script |
|---|---|---|
| Commit changes | "Committing code" / Quick Decision Tree | `commit_enhanced.sh` |
| Stash work in progress | "Stashing work in progress" | `stash_work.sh push` |
| Restore stashed work | "Stashing work in progress" | `stash_work.sh pop` / `list` |
| Undo last commit | "Undoing something" | `undo_last.sh commit` |

### 3. Push, Pull & Sync

| Action | SKILL.md section | Primary script |
|---|---|---|
| Push to remote | "Pushing to remote" | `push_validated.sh` |
| Sync current branch with remote | "Syncing with remote" | `sync_branches.sh` |
| Sync both source + target branches | "Syncing with remote" | `sync_branches.sh --all` |
| Preview sync (fetch only) | "Syncing with remote" | `sync_branches.sh --dry-run` |

### 4. Branch, Merge & PR

| Action | SKILL.md section | Primary script |
|---|---|---|
| Merge to target branch | "Merging to target branch" | `merge_with_validation.sh` |
| Create a PR | "Creating a PR" | `create_pr.sh` |
| Check out a PR locally | "Reviewing a PR locally" | `pr_checkout.sh` |
| Cherry-pick a commit | "Cherry-picking a commit" | `cherry_pick_commits.sh` |

Longer tail reachable via "Other": rebase (`rebase_safe.sh`), merge docs only
(`merge_docs.sh`), branch cleanup (`branch_cleanup.sh`), worktree management
(`worktree_manage.sh`), check branch diff (`branch_diff.sh`).

### 5. Undo & Recover

| Action | SKILL.md section | Primary script |
|---|---|---|
| Undo last commit | "Undoing something" | `undo_last.sh commit` |
| Amend last commit message | "Undoing something" | `undo_last.sh amend-message` |
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

- All successful commands: `>/dev/null 2>&1`
- Only show errors: remove suppression on retry
- Keep the final summary to a few lines
