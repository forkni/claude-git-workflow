---
name: auto-git-workflow
description: "Use whenever the user asks for a git operation in this project — commit, push, pull, fetch, merge, rebase, cherry-pick, rollback, revert, sync, stash, tag, release, changelog, worktree, recover/restore lost commits, branch (create/rename/delete/cleanup), bisect, undo, amend, or conflict resolution. Routes work through scripts/git/*.sh wrappers (commit_enhanced.sh, push_validated.sh, merge_with_validation.sh, rollback_merge.sh, cherry_pick_commits.sh, rebase_safe.sh, stash_work.sh, branch_cleanup.sh, bisect_helper.sh, changelog_generate.sh, create_release.sh, create_pr.sh, sync_branches.sh, undo_last.sh, recover.sh, worktree_manage.sh, merge_docs.sh, validate_branches.sh) instead of raw git, so lint validation, local-only file protection, backup tags, and force-push guards are never bypassed."
allowed-tools: "Bash, Read, Grep, Edit"
user-invocable: false
---

# Auto Git Workflow

Ensures all git operations follow established patterns:

- Use `scripts/git/*.sh` scripts instead of raw git commands
- Protect local-only files from accidental commits
- Handle merge conflicts correctly (auto-resolve safe cases, stop for manual review)
- Follow conventional commit message format

For script flags and environment variables, see [references/script-reference.md](references/script-reference.md).
For error recovery procedures, see [references/error-recovery.md](references/error-recovery.md).
For branch rules and merge workflow, see [references/branch-and-merge-rules.md](references/branch-and-merge-rules.md).
For the exact commands, flags and caveats of each wrapper operation (the Quick Decision Tree at the end links into it), see [references/wrapper-recipes.md](references/wrapper-recipes.md).
For non-obvious git techniques not covered by a wrapper (pickaxe search, merge-base discovery, back-dated tags, PR diff URLs), see [references/git-recipes.md](references/git-recipes.md).
For choosing or composing a `.gitignore` — stack templates, OS/editor `Global` rules, pattern precedence and negation, and the trap where ignoring an already-tracked path does nothing — see [references/gitignore-templates.md](references/gitignore-templates.md).
For the full promotion pipeline (commit → push → merge/PR → push, run by `/auto-git-workflow-cmd` option 1), see [references/full-promotion.md](references/full-promotion.md).
For the mandatory post-push CI verification gate (`verify_ci.sh` after every push, fix-until-green), see [references/ci-verification.md](references/ci-verification.md).
For what to check before and after tagging a release (CI on the release commit, version, changelog, rollback plan, asset smoke check), see [references/release-checklist.md](references/release-checklist.md).
For keeping secrets and machine-local config out of git in the first place (sample-file pattern, what `CGW_LOCAL_FILES` does and does not catch, the untracked-file warning), see [references/secrets-and-local-config.md](references/secrets-and-local-config.md).
For removing a secret or local-only file that was **already committed** (rotate, diagnose, strip from history if pushed), see [references/removing-sensitive-data.md](references/removing-sensitive-data.md).
When a merge or rebase **stops on a conflict that needs manual resolution** (`UU`, `AA`, `AU`, `UD`, `AD`, `DA`), follow the step-by-step procedure in [references/resolving-merge-conflicts.md](references/resolving-merge-conflicts.md) — investigate both sides' intent, preserve both where compatible, re-run checks, then conclude through the wrapper. **Before touching a hunk:** run `git log --merge -p -- <file>` and `git log --oneline --left-right --merge` to understand which commits on each side caused the conflict. Never blindly `git checkout --ours/--theirs`; resolve by default — abort only to deliberately abandon the operation, not to dodge a difficult conflict.

## When to use this skill

Invoke this skill **before** running any git command in this project. If the answer to *"am I about to run `git <verb>`?"* is yes — even for `git commit -m`, `git push`, `git merge`, `git rebase`, `git cherry-pick`, `git stash`, `git tag`, `git revert`, `git reset`, or any branch/remote mutation — load these rules first and reach for the matching `scripts/git/*.sh` wrapper. Read-only operations (`git status`, `git log`, `git diff`, `git show`) do not require the skill, but using it does no harm.

**Tool-use note.** When using `AskUserQuestion` to clarify a git operation, emit the tool call promptly — keep the prose preamble to one short sentence. Long narrative lead-ins before a structured tool call have, in past sessions, correlated with empty `input: {}` emissions that the harness rejects as "Invalid tool parameters". If you see that error, simply re-issue the same question.

---

## Core Rules (MANDATORY)

### Rule 1: NEVER Use Raw `git commit`

**Always use:**

```bash
./scripts/git/commit_enhanced.sh [flags] "commit message"
```

**NEVER use:**

```bash
git commit -m "message"  # WRONG — bypasses lint, protection, logging
```

`commit_enhanced.sh` provides: lint validation, local-only file protection, branch verification, commit message format checking, and comprehensive logging.

Updating the vendored CGW scripts in a project: `./scripts/git/sync_cgw_tooling.sh --from <claude-git-workflow checkout>` (one commit; never hand-copy). `./scripts/git/sync_cgw_tooling.sh --check` is a read-only drift check over the project's tracked skill/command copies (no CGW checkout needed; exit 1 on drift).

> **Optional defense-in-depth:** If the CGW PreToolUse guardrail was installed (offered during `configure.sh`), this rule is also enforced at the Claude Code harness layer — even if asked to run `git commit` directly, the hook blocks it before it reaches the shell. See `references/error-recovery.md` → *PreToolUse Guardrail* for disable instructions.

### Rule 2: Use `--no-venv` When No Virtual Environment

```bash
# If .venv exists — use normally:
./scripts/git/commit_enhanced.sh "feat: add feature"

# If .venv is missing — add --no-venv (uses system lint tool directly):
./scripts/git/commit_enhanced.sh --no-venv "feat: add feature"
```

Works on `commit_enhanced.sh`, `check_lint.sh`, and `fix_lint.sh`. Also supported via `CGW_NO_VENV=1`.

### Rule 3: NEVER Commit Local-Only Files

Files configured in `.cgw.conf` as `CGW_LOCAL_FILES` must never be committed.
Default protected files: `CLAUDE.md`, `MEMORY.md`, `.claude/`, `logs/`

Use `CGW_LOCAL_FILES_EXEMPT` in `.cgw.conf` to allow specific files inside a blocked directory (e.g., `.claude/settings.json` is a shared project config inside the blocked `.claude/` dir).

Before any commit, verify:

```bash
git diff --cached --name-only | grep -E "(CLAUDE\.md|MEMORY\.md|\.claude/|logs/)"
```

`commit_enhanced.sh` automatically unstages all configured local-only files before committing. The pre-commit and pre-push hooks read `CGW_LOCAL_FILES` from `.cgw.conf` at run time, so editing the config takes effect immediately — no need to re-run `configure.sh`.

This protection is **commit-scoped only** — CGW unstages local-only files before a commit, but nothing stops you from *deleting* them from disk. Never run `git rm -f` or `git clean -f` on a local-only or git-ignored path; for git-ignored files this is unrecoverable. See the [split cherry-pick recipe](references/wrapper-recipes.md#cherry-picking-only-some-files-from-a-commit) for the safe way to strip unwanted paths.

If a local-only file or a secret has **already been committed** (this rule failed to catch it, or it predates CGW), see [removing-sensitive-data.md](references/removing-sensitive-data.md) — the fix differs depending on whether it was pushed yet. For the preventive side (sample files, rotation, what `CGW_LOCAL_FILES` does not scan), see [secrets-and-local-config.md](references/secrets-and-local-config.md).

### Rule 4: Stale Lock Auto-Recovery

CGW scripts automatically detect and remove stale `.git/index.lock` files left by crashed or killed git processes (the most common Claude Code failure mode). When this happens you will see:

```text
[cgw-lock] Removing stale index.lock (age 47s): /path/to/.git/index.lock
```

**Safety guards — the helper refuses to remove the lock when:**

- A `rebase`, `merge`, `cherry-pick`, `revert`, or `bisect` is in progress (detected by state dirs/sentinels in `.git/`). This protects you if a `git rebase -i` editor is open in another terminal.
- `CGW_AUTO_REMOVE_INDEX_LOCK=0` is set (warn-only mode).

**Manual removal** is only needed if the auto-recovery refuses. Use the worktree-aware path (not always literally `.git/index.lock`):

```bash
rm -f "$(git rev-parse --git-dir)/index.lock"
```

**Tuning** (via env or `.cgw.conf`):

| Variable | Default | Purpose |
|---|---|---|
| `CGW_AUTO_REMOVE_INDEX_LOCK` | `1` | `0` = warn-only, `1` = auto-remove |
| `CGW_INDEX_LOCK_MAX_AGE_SECONDS` | `30` | Locks older than this are stale |
| `CGW_INDEX_LOCK_WAIT_SECONDS` | `10` | Poll window for fresh locks |

If you regularly run `git rebase -i` and pause in the editor for minutes, set `CGW_INDEX_LOCK_MAX_AGE_SECONDS=300` to avoid interruption.

### Rule 5: Selective Commits — Staging Intent Is Respected

**The script's staging behavior depends on what is already staged when it runs:**

| Pre-staged files? | Unstaged changes? | Non-interactive action |
|:-:|:-:|---|
| No | No | Exit — nothing to commit |
| No | Yes | Auto-stage all tracked changes (`git add -u`) |
| Yes | No | Commit staged files as-is |
| **Yes** | **Yes** | **Commit pre-staged files ONLY** — warns loudly about excluded changes |

**Use `--only` for the clearest intent (preferred in Claude Code):**

```bash
# Commit exactly two files — any prior index state is reset first
./scripts/git/commit_enhanced.sh --no-venv \
  --only src/foo.py \
  --only src/bar.py \
  "feat: selective change"
```

**Or pre-stage + commit (safe default respects your selection):**

```bash
git add src/foo.py src/bar.py && \
  ./scripts/git/commit_enhanced.sh --no-venv "feat: selective change"
```

**To include all tracked changes regardless of index state:**

```bash
./scripts/git/commit_enhanced.sh --all --no-venv "chore: bulk update"
# Equivalent env var: CGW_ALL=1
```

**Never do this when you have pre-existing tracked modifications and only want to commit some of them:**

```bash
# DANGEROUS (old pattern) — auto-stages EVERYTHING in non-interactive mode if nothing pre-staged
git reset HEAD && git add src/foo.py && ./scripts/git/commit_enhanced.sh "feat: ..."
# SAFE (new pattern) — use --only instead
./scripts/git/commit_enhanced.sh --only src/foo.py "feat: ..."
```

### Rule 6: Every Push Must End Green

A push is not "done" the moment git accepts it. Every push CGW performs — `push_validated.sh`,
a merge's target push, `create_pr.sh`, `create_release.sh --push` — must be followed by the
CI gate, which is one command:

```bash
./scripts/git/verify_ci.sh --branch development   # the branch just pushed, never HEAD
./scripts/git/verify_ci.sh --pr 42 --sha <sha>    # a PR, bound to create_pr.sh's printed Head SHA
```

It resolves the pushed SHA from the remote, waits for the runs to register, watches them to a
terminal state and prints one `CI:` line on stdout. Act on its exit code:

| Exit | stdout | Meaning / action |
|---|---|---|
| `0` | `CI: green <sha>` | Done |
| `1` | `CI: red <workflow> <url>` | Fix loop: diagnose, fix on the source branch, re-push through the wrappers, re-run; bounded by `CGW_CI_MAX_FIX_ROUNDS` |
| `2` | `CI: unverified -- <reason>` | Report it as unverified, never as green (registration lag, timeout, PR head lagging or moved) |
| `3` | `CI: not applicable (...)` / `CI: no workflow triggered` | Done (no gate for this push) |

Its default timeout is 900s, longer than the Bash tool's 600s cap, so run it with
`run_in_background: true` (or pass `--timeout`). Never report a push/merge/promotion
"complete" while the gate is pending, red or unverified. The fix loop, hard prohibitions and
the manual fallback procedure are in [references/ci-verification.md](references/ci-verification.md).

---

## Commit Message Format

Conventional commit format (enforced by `commit_enhanced.sh`):

| Prefix | Use Case |
|--------|----------|
| `feat:` | New feature |
| `fix:` | Bug fix |
| `docs:` | Documentation |
| `chore:` | Maintenance |
| `test:` | Test changes |
| `refactor:` | Code refactoring |
| `style:` | Code style |
| `perf:` | Performance |

Additional project-specific prefixes can be configured via `CGW_EXTRA_PREFIXES` in `.cgw.conf`.

**Freeform-message branches.** Branches matching `CGW_FREEFORM_MESSAGE_BRANCHES` in `.cgw.conf`
(e.g. an `up/*` branch targeting another project's PR conventions) skip the conventional-format
check and the hard length cap below — but `commit_enhanced.sh` is still the only sanctioned way
to commit on them. Local-only-file, lint, and protected-branch guards stay fully enforced, and
`--no-verify` / raw `git commit` remain forbidden, same as on every other branch. The source,
target, and any `CGW_PROTECTED_BRANCHES` entry can never be exempted this way — a glob as broad
as `"*"` still has no effect on them, so the escape hatch cannot be used to silently disable the
format check on the branches the policy protects. Optionally set `CGW_FREEFORM_MESSAGE_CHECK` to
the target project's own message-validation command (e.g. its `commit-msg` hook) so that
project's rules are enforced instead of skipping validation outright.

**Scopes and the breaking-change marker are accepted natively.** For every prefix in the table
above, the format check accepts the full Conventional Commits subject shape — `type: ...`,
`type(scope): ...`, `type!: ...`, and `type(scope)!: ...` — e.g. `fix(parser): handle empty
input`, `feat!: drop legacy export API`, `feat(api)!: drop legacy export API`. Commit with the
scope and the `!` breaking-change marker **intact**: do not strip them, do not demote the
breaking note into subject prose as a workaround, and do not reach for `CGW_EXTRA_PREFIXES`
for a scoped or `!`-marked standard type — that setting adds *extra prefix words*, it is not
needed for scoping or `!`. Put any breaking-change detail in a `BREAKING CHANGE:` paragraph in
the commit body.

**Subject length (Pro Git recommendation):** keep the summary after the prefix to **≤50 chars**
— draft it that way up front rather than relying on the script to catch it. `commit_enhanced.sh`
prints an advisory tip between 50–72 chars and **blocks the commit** past 72 chars (the point
`git log --oneline`/GitHub truncate at), requiring explicit confirmation to proceed. Put any
extra detail in the commit body, not a long subject line. Tune via `CGW_COMMIT_SUBJECT_SOFT_LEN`
/ `CGW_COMMIT_SUBJECT_HARD_LEN` / `CGW_ENFORCE_SUBJECT_LENGTH` in `.cgw.conf`.

**Commit body (Git for Teams — "Constructing the Perfect Commit"):** `commit_enhanced.sh`
takes the full multi-line message as its one positional argument (there is no `-m` flag); only
the first line is length-checked (72 chars). Build it with `"$(cat <<'EOF' ... EOF)"`, and use
the body for anything the subject can't carry. A good body covers, as needed:

- **Why** the current code is a problem — not a restatement of what the diff shows.
- The **rationale** for this approach and a high-level **how**.
- **Side effects** or who/what else is affected, and any docs that now need updating.
- A ticket/issue reference (`Resolves #321`) if one exists.

```text
fix: guard against nil response in retry loop

The retry loop assumed every failed request returned a response object,
but timeouts return nil. This crashed the whole batch job on any single
timeout instead of just failing that request.

Treat nil the same as a non-2xx response: log and continue the loop.

Resolves #482
```

**Scope discipline** applies regardless of body length: a commit contains only related code —
no scope creep, no "just fixing whitespace too" bundled into an unrelated fix. If a change turns
up something else worth fixing, make it a separate commit.

---

## Wrapper Flag Reference

Each wrapper accepts ONLY the flags listed below. Never guess a flag or transfer one from a
sibling script — the lint and push wrappers reject anything unrecognized with
`[ERROR] Unknown flag` and exit 1, and `commit_enhanced.sh` treats an unrecognized token as a
positional commit message. If a flag you expect isn't listed here, it does not exist; run the
script with `--help` to confirm rather than inventing it.

| Script | Accepted flags |
|---|---|
| `commit_enhanced.sh` | `--non-interactive`, `--interactive`, `--staged-only`, `--all`, `--only <path>` (repeatable), `--skip-lint`, `--skip-md-lint`, `--no-venv`, `--sign`, `--no-sign`, `--strict-untracked`, `--no-untracked-check` |
| `check_lint.sh` | `--no-venv`, `--modified-only`, `--skip-lint`, `--skip-md-lint`, `--skip-typecheck`, `--md-only`, `--ref <rev>`, `--base <rev>`, `--unpushed` |
| `fix_lint.sh` | `--non-interactive`, `--no-venv`, `--modified-only`, `--skip-md-lint`, `--md-only` — **no `--skip-lint`** |
| `push_validated.sh` | `--non-interactive`, `--dry-run`, `--skip-lint`, `--skip-md-lint`, `--skip-typecheck`, `--pushed-only`, `--worktree`, `--no-venv`, `--force`, `--branch <name>` |
| `cherry_pick_commits.sh` | `--non-interactive`, `--commit <hash>`, `--only <pathspec>` (repeatable; partial pick), `--no-x`, `--dry-run`, `--source <branch>`, `--target <branch>` |

Asymmetries that trip people up:

- **Markdown-only work:** `fix_lint.sh --md-only` auto-fixes markdown only, leaving code lint
  completely untouched, and forwards `--md-only` to its own final `check_lint.sh`
  verification. `check_lint.sh --md-only` checks markdown only (code lint + format skipped).
  `check_lint.sh --skip-lint` is a different thing — it skips *everything including markdown*
  and early-exits with a success-shaped `[OK] All lint checks skipped (--skip-lint)` line.
  `--md-only` and `--skip-md-lint` are mutually exclusive on both scripts; `--md-only` and
  `--modified-only` cannot be combined on `check_lint.sh` (`--modified-only` has no
  markdown-only path).
- **`--non-interactive` is not universal.** `commit_enhanced.sh`, `fix_lint.sh`,
  `push_validated.sh`, `merge_with_validation.sh`, and `create_pr.sh` accept it;
  `check_lint.sh` does **not** — it is read-only and never prompts, so a skip-prompts flag
  doesn't exist there and passing one error-exits.
- **`--unsafe-fixes` belongs to ruff, not to any wrapper.** No CGW script accepts it. Preview
  ruff's unsafe fixes read-only with `ruff check --unsafe-fixes --diff`; apply them by running
  ruff directly or via the `CGW_LINT_FIX_ARGS` env override — never by passing the flag to a
  wrapper.
- `commit_enhanced.sh` lints **staged files only** — a failing unstaged file elsewhere in the
  tree does not block an `--only`-scoped commit.
- **Typecheck does not run under `--md-only` or `--modified-only`** on `check_lint.sh` (it needs
  whole-project context, so it never runs scoped to a diff or a markdown-only pass), and it does
  not run at all in `commit_enhanced.sh` (see the Typecheck note in [Committing code](references/wrapper-recipes.md#committing-code)).

## Quick Decision Tree

Find the operation, run the wrapper it names, and read its section in
[references/wrapper-recipes.md](references/wrapper-recipes.md) **before** the first run: the recipe
holds the exact flags and the caveats this table only flags. The Wrapper Flag Reference above still
decides which flags exist.

| Operation | Wrapper | Do not miss |
|-----------|---------|-------------|
| [Committing code](references/wrapper-recipes.md#committing-code) | `commit_enhanced.sh` | `--only <path>` for specific files; typecheck is blocking in `check_lint.sh`/`push_validated.sh`, not in the commit |
| [Merging to target branch](references/wrapper-recipes.md#merging-to-target-branch) | `merge_with_validation.sh` | A conflicted merge concludes with `commit_enhanced.sh`; there is no `--continue`, and the wrapper is not re-run |
| [Pushing to remote](references/wrapper-recipes.md#pushing-to-remote) | `push_validated.sh` | Rule 6: finish with a green `verify_ci.sh` verdict |
| [Creating a PR](references/wrapper-recipes.md#creating-a-pr) | `create_pr.sh` | Pass `--body-file` at creation; never raw `gh pr create` on a fork remote; Rule 6 with `--pr N --sha` |
| [Merging a PR](references/wrapper-recipes.md#merging-a-pr) | `merge_pr.sh` | Only when the user asks |
| [Syncing with remote](references/wrapper-recipes.md#syncing-with-remote) | `sync_branches.sh` | Fetch + rebase; it auto-stashes a dirty tree |
| [Rollback a merge](references/wrapper-recipes.md#rollback-a-merge) | `rollback_merge.sh` | After a `--revert` rollback, revert the revert before re-merging |
| [Cherry-picking a commit](references/wrapper-recipes.md#cherry-picking-a-commit) | `cherry_pick_commits.sh` | A paused cherry-pick concludes with `git cherry-pick --continue`, not the wrapper |
| [Cherry-picking only some files](references/wrapper-recipes.md#cherry-picking-only-some-files-from-a-commit) | `cherry_pick_commits.sh` | Strip unwanted paths with the recipe, never `git rm -f` (Rule 3) |
| [Merging docs only](references/wrapper-recipes.md#merging-docs-only) | `merge_docs.sh` | Copies `docs/` into a one-parent commit; a later full merge re-applies those changes |
| [Undoing something](references/wrapper-recipes.md#undoing-something) | `undo_last.sh` | `discard` is irreversible and interactive-only; `amend-message` is for unpushed commits |
| [Branch cleanup](references/wrapper-recipes.md#branch-cleanup) | `branch_cleanup.sh` | Dry-run by default; `--execute` deletes |
| [Safe rebase](references/wrapper-recipes.md#safe-rebase) | `rebase_safe.sh` | The `pre-rebase` hook blocks a branch already pushed; override only with `CGW_ALLOW_REBASE_PUBLISHED=1` when sure |
| [Bisecting a bug](references/wrapper-recipes.md#bisecting-a-bug) | `bisect_helper.sh` | `--run "<cmd>"` automates; `--abort` ends a stuck session |
| [Generating a changelog](references/wrapper-recipes.md#generating-a-changelog) | `changelog_generate.sh` | At release time use `--version` with `--prepend` |
| [Stashing work in progress](references/wrapper-recipes.md#stashing-work-in-progress) | `stash_work.sh` | `drop` and `clear` need `--yes`; the raw-git fallback needs explicit user authorization |
| [Creating a release](references/wrapper-recipes.md#creating-a-release) | `create_release.sh` | Run `verify_ci.sh` after the tag push |
| [Recovering lost commits](references/wrapper-recipes.md#recovering-lost-commits) | `recover.sh` | Everything is read-only except `restore`, which tags a backup first |
| [Worktree management](references/wrapper-recipes.md#worktree-management) | `worktree_manage.sh` | Never raw `git worktree remove` |
| [Project setup & hygiene](references/wrapper-recipes.md#project-setup--hygiene) | `configure.sh`, `repo_health.sh`, `clean_build.sh` | `clean_build.sh` is dry-run by default and skips tracked paths |
| [Checking what changed](references/wrapper-recipes.md#checking-what-changed-on-your-branch) | `branch_diff.sh` | Read-only |
| [Reviewing a PR locally](references/wrapper-recipes.md#reviewing-a-pr-locally) | `pr_checkout.sh` | Refuses over uncommitted tracked changes unless `--force`; stash first |
| [Markdown TOC](references/wrapper-recipes.md#generating-or-updating-a-markdown-table-of-contents) | `md_toc.sh` | `--insert` edits in place; `--check` is the CI form |
