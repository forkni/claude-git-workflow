---
name: safe-git-workflow
description: Runs commits, pushes, merges, rebases, cherry-picks, stashes, undo, rollback and lost-commit recovery through defensive bash wrappers that lint staged files, keep local-only files out of commits, tag a backup before every history change and push only with --force-with-lease. Use for any git operation that changes a repository (commit, push, pull, sync, merge, rebase, cherry-pick, stash, undo, amend, rollback, recover, branch cleanup, bisect), or when asked what to do next in a repo.
---

# Safe Git Workflow

Route every git operation that changes the repository through the wrapper scripts in this skill
instead of raw `git`. The wrappers add lint validation, local-only file protection, backup tags,
lease-guarded pushes and a log of every run. Read-only commands (`git status`, `git log`,
`git diff`, `git show`) can be run directly.

## How to run the scripts

- The scripts live in this skill's `scripts/` folder. Commands below write that folder as
  `<skill-dir>/scripts/`: replace `<skill-dir>` with the absolute path of the folder holding this
  SKILL.md.
- Always run them **from inside the repository** (the working directory decides which repo they
  act on). If a script has lost its executable bit, run it as `bash <skill-dir>/scripts/<name>.sh`.
- Every script accepts `--help`. Never guess a flag: unknown flags are rejected, and
  `commit_enhanced.sh` treats an unknown token as the commit message.
- Their hint lines show `scripts/git/<name>.sh`, the path in a vendored install. Here, read that
  as `<skill-dir>/scripts/<name>.sh`.
- Requirements: bash 4.2+ (macOS needs a newer bash than the system one) and git 2.18+. Lint
  tools (ruff, eslint, markdownlint and so on) are optional and skipped when absent.
- Each run writes a log under `logs/` in the repository. It is never committed (see Rule 3);
  suggest adding `logs/` to `.gitignore`.
- No setup is required. Optional per-repo settings go in a `.cgw.conf` file at the repository root;
  [assets/cgw.conf.example](assets/cgw.conf.example) documents every setting. Environment variables
  with the same names override it for one run.

Reference files, loaded when needed:

- [references/wrapper-recipes.md](references/wrapper-recipes.md): exact commands, flags and caveats
  per operation. Read the matching section **before** the first run of an operation.
- [references/script-reference.md](references/script-reference.md): every flag and environment
  variable.
- [references/branch-and-merge-rules.md](references/branch-and-merge-rules.md): source/target
  branches, merge modes, conflict types, rollback policy.
- [references/error-recovery.md](references/error-recovery.md): lint, push, rebase, bisect and lock
  failures.
- [references/resolving-merge-conflicts.md](references/resolving-merge-conflicts.md): the step-by-step
  conflict procedure.

---

## Core rules

### Rule 1: Never use raw `git commit`

```bash
<skill-dir>/scripts/commit_enhanced.sh [flags] "feat: commit message"
```

`commit_enhanced.sh` lints the staged files, unstages local-only files, checks the message format
and branch, and logs the run. This also applies to concluding a merge after resolving conflicts:
run it with no message and it uses git's prepared merge message.

### Rule 2: Use `--no-venv` when the project has no `.venv`

`commit_enhanced.sh`, `check_lint.sh` and `fix_lint.sh` look for lint tools in `.venv` first. In a
repo without one, add `--no-venv` (or set `CGW_NO_VENV=1`) to use the system tools directly.

### Rule 3: Never commit local-only files

Paths listed in `CGW_LOCAL_FILES` are unstaged automatically before every commit, and a merge or
cherry-pick that would bring one in stops instead of completing. The default list is `CLAUDE.md MEMORY.md .claude/ logs/`. Change it in `.cgw.conf`, and use
`CGW_LOCAL_FILES_EXEMPT` to allow a specific file inside a protected folder (for example a shared
`.claude/settings.json`).

The protection is commit-scoped only. Never run `git rm -f` or `git clean -f` on a local-only or
git-ignored path: for an ignored file that loss is unrecoverable. If a secret was already
committed, tell the user it must be rotated at its source, and do not rewrite shared history
without their explicit go-ahead.

### Rule 4: Stale index locks are handled for you

The scripts remove a stale `index.lock` left by a crashed git process (older than 30 seconds by
default) and refuse to when a rebase, merge, cherry-pick, revert or bisect is in progress. Tune
with `CGW_AUTO_REMOVE_INDEX_LOCK` and `CGW_INDEX_LOCK_MAX_AGE_SECONDS`. Only if auto-recovery
refuses and no git process is running, remove it by hand with the worktree-aware path:
`rm -f "$(git rev-parse --git-dir)/index.lock"`.

### Rule 5: Staging intent is respected

| Pre-staged files? | Unstaged changes? | What `commit_enhanced.sh` does (non-interactive) |
|:-:|:-:|---|
| No | No | Exits: nothing to commit |
| No | Yes | Stages all tracked changes (`git add -u`) |
| Yes | No | Commits the staged files as they are |
| **Yes** | **Yes** | **Commits the pre-staged files only**, and warns about the rest |

For the clearest intent, name the files:

```bash
<skill-dir>/scripts/commit_enhanced.sh --only src/foo.py --only src/bar.py "feat: selective change"
```

`--all` commits every tracked change regardless of the index. New, untracked files are never
picked up implicitly: the script lists them in a warning, and `--strict-untracked` turns that
into a refusal.

### Rule 6: A push isn't done until CI is green

After any push, check the CI runs it triggered (for example `gh run list --branch <branch>`, or
the project's own CI tooling) and fix failures on the source branch before calling the push done.
Report a push whose CI you couldn't check as "pushed, CI unverified", never as green.

### Rule 7: Confirm before anything irreversible

Ask the user first before a hard rollback (`rollback_merge.sh` without `--revert`), discarding
changes (`undo_last.sh discard`), dropping or clearing stashes, deleting branches
(`branch_cleanup.sh --execute`), or force-pushing. The scripts ask too, but an agent running them
non-interactively must get the user's word before passing the confirming flag or token.

---

## Commit message format

Conventional Commits, enforced by `commit_enhanced.sh`: `feat:`, `fix:`, `docs:`, `chore:`,
`test:`, `refactor:`, `style:`, `perf:`. Scopes and the breaking-change marker are accepted:
`fix(parser): ...`, `feat!: ...`, `feat(api)!: ...`. Keep them intact, and put breaking-change
detail in a `BREAKING CHANGE:` paragraph in the body. Extra prefix words for a project go in
`CGW_EXTRA_PREFIXES`.

- Keep the subject after the prefix to about 50 characters. Past 72 the commit is blocked.
- The whole message is the one positional argument (there is no `-m`). For a body, build it with
  `"$(cat <<'EOF' ... EOF)"` and explain **why**, the approach, and side effects.
- One commit, one concern: no unrelated fixes bundled in.

---

## Flag reference (the most used scripts)

| Script | Accepted flags |
|---|---|
| `commit_enhanced.sh` | `--non-interactive`, `--interactive`, `--staged-only`, `--all`, `--only <path>` (repeatable), `--skip-lint`, `--skip-md-lint`, `--no-venv`, `--sign`, `--no-sign`, `--strict-untracked`, `--no-untracked-check` |
| `check_lint.sh` | `--no-venv`, `--modified-only`, `--skip-lint`, `--skip-md-lint`, `--skip-typecheck`, `--md-only`, `--ref <rev>`, `--base <rev>`, `--unpushed` |
| `fix_lint.sh` | `--non-interactive`, `--no-venv`, `--modified-only`, `--skip-md-lint`, `--md-only` (no `--skip-lint`) |
| `push_validated.sh` | `--non-interactive`, `--dry-run`, `--skip-lint`, `--skip-md-lint`, `--skip-typecheck`, `--pushed-only`, `--worktree`, `--no-venv`, `--force`, `--branch <name>` |
| `cherry_pick_commits.sh` | `--non-interactive`, `--commit <hash>`, `--only <pathspec>` (repeatable), `--no-x`, `--dry-run`, `--source <branch>`, `--target <branch>` |

`check_lint.sh` is read-only and has no `--non-interactive`. `commit_enhanced.sh` lints staged files
only. Typecheck runs in `check_lint.sh` and `push_validated.sh`, never in the commit.

## Which script for which operation

| Operation | Script | Do not miss |
|---|---|---|
| [Commit](references/wrapper-recipes.md#committing-code) | `commit_enhanced.sh` | `--only <path>` for specific files |
| [Merge to the target branch](references/wrapper-recipes.md#merging-to-target-branch) | `merge_with_validation.sh` | A conflicted merge concludes with `commit_enhanced.sh`, not a re-run |
| [Push](references/wrapper-recipes.md#pushing-to-remote) | `push_validated.sh` | Rule 6 afterwards |
| [Sync with the remote](references/wrapper-recipes.md#syncing-with-remote) | `sync_branches.sh` | Fetch and rebase; stashes a dirty tree for you |
| [Roll back a merge](references/wrapper-recipes.md#rollback-a-merge) | `rollback_merge.sh` | `--revert` keeps history; revert the revert before merging again |
| [Cherry-pick](references/wrapper-recipes.md#cherry-picking-a-commit) | `cherry_pick_commits.sh` | A paused pick concludes with `git cherry-pick --continue` |
| [Cherry-pick some files](references/wrapper-recipes.md#cherry-picking-only-some-files-from-a-commit) | `cherry_pick_commits.sh --only` | Never strip paths with `git rm -f` |
| [Undo](references/wrapper-recipes.md#undoing-something) | `undo_last.sh` | `discard` is irreversible; `amend-message` is for unpushed commits |
| [Rebase](references/wrapper-recipes.md#safe-rebase) | `rebase_safe.sh` | Tags a backup first; stops when commits are already pushed (rewriting them needs a force-push, so ask first) |
| [Stash](references/wrapper-recipes.md#stashing-work-in-progress) | `stash_work.sh` | `drop` and `clear` need `--yes` (Rule 7) |
| [Recover lost commits](references/wrapper-recipes.md#recovering-lost-commits) | `recover.sh` | Read-only except `restore`, which tags a backup first |
| [Branch cleanup](references/wrapper-recipes.md#branch-cleanup) | `branch_cleanup.sh` | Dry run by default; `--execute` deletes |
| [Bisect](references/wrapper-recipes.md#bisecting-a-bug) | `bisect_helper.sh` | `--run "<cmd>"` automates; `--abort` ends a stuck session |
| [What changed on this branch](references/wrapper-recipes.md#checking-what-changed-on-your-branch) | `branch_diff.sh` | Read-only |
| Check for tracked local-only files | `check_local_files.sh` | Read-only; exit 1 when one is tracked |

When a merge or rebase stops on a conflict that needs a decision (`UU`, `AA`, `AU`, `UA`, `DU`,
`UD`), follow [references/resolving-merge-conflicts.md](references/resolving-merge-conflicts.md):
find each side's intent with `git log --merge -p -- <file>` before touching a hunk, never pick
`--ours`/`--theirs` blind, and abort only to abandon the operation on purpose.

---

## When asked "what should I do next?"

Scan first, then suggest one step:

```bash
git fetch --quiet 2>/dev/null || true
<skill-dir>/scripts/repo_state.sh
```

`repo_state.sh` is read-only and prints `key=value` lines (`--json` for one object): branch,
ahead/behind, staged/unstaged/untracked counts, conflicts, any operation in progress, stashes, and
a `suggestion_label`. Act on the label:

| `suggestion_label` | Suggest |
|---|---|
| `finish-in-progress` | Finish the merge, rebase, cherry-pick or bisect in progress (resolve, then continue or abort through the matching script) |
| `detached-head` | Create a branch so the work stays reachable |
| `reconcile-upstream` | The remote changed the same paths: show `git diff HEAD @{u} -- <paths>` and decide before committing |
| `commit` | Commit the uncommitted work (or stash it if they're switching tasks) |
| `push` / `publish-branch` | Push with `push_validated.sh` |
| `pull` / `sync-diverged` | Sync with `sync_branches.sh`, then push |
| `merge-or-pr` | Merge to the target branch, or open a PR |
| `restore-stash` | Restore stashed work with `stash_work.sh pop` |
| `clean` | Nothing pending |

Give a one-line state summary with only the non-zero facts, the suggestion, and wait for the user
to pick before running anything that changes the repo.

Source, tests, the git hooks and the agent-harness integrations (a command guardrail and a slash
command): <https://github.com/forkni/claude-git-workflow> (MIT).
