---
name: auto-git-workflow
description: "Enforces project git workflow using scripts/git/*.sh instead of raw git commands. Protects local-only files from accidental commits. Triggers on any git commit, push, merge, sync, branch, or conflict resolution operation."
user-invocable: true
allowed-tools: "Bash, Read, Grep"
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

`commit_enhanced.sh` automatically unstages all configured local-only files before committing.

### Rule 4: Chain Git Commands to Prevent Lock Files

```bash
# Correct — single chained call
git add src/file.py && ./scripts/git/commit_enhanced.sh "feat: add feature"

# Wrong — separate calls risk .git/index.lock race conditions
```

If `.git/index.lock` exists, remove it first:
```bash
rm -f .git/index.lock && git add src/file.py && ./scripts/git/commit_enhanced.sh "feat: add feature"
```

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

---

## Quick Decision Tree

**Committing code:**
```
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
├─ Yes → Run ./scripts/git/fix_lint.sh then retry commit
└─ No  → Commit proceeds

Optional flags: --skip-lint (skip all lint), --skip-md-lint (skip markdown lint only)

After commit: verify with git log --oneline -1
```

**Merging to target branch** (direct merge, `CGW_MERGE_MODE="direct"`):
```bash
# Preview first (no changes):
./scripts/git/merge_with_validation.sh --dry-run

# Execute merge:
./scripts/git/merge_with_validation.sh --non-interactive

# Override branch pair for this invocation (doesn't mutate config):
./scripts/git/merge_with_validation.sh --source feature/hotfix --target release/1.2 --non-interactive
```
Handles: pre-merge validation, backup tag, modify/delete/both-deleted conflict auto-resolution, content conflict detection (stops for manual review).

Set `CGW_MERGE_MODE="pr"` in `.cgw.conf` to use the PR workflow instead (see Creating a PR below).

**Pushing to remote:**
```bash
./scripts/git/push_validated.sh                       # with lint check
./scripts/git/push_validated.sh --no-venv             # no .venv (forwards to check_lint.sh)
./scripts/git/push_validated.sh --dry-run             # preview
./scripts/git/push_validated.sh --skip-lint           # skip lint check entirely
./scripts/git/push_validated.sh --no-venv --skip-lint # both
```

**Creating a PR** (when `CGW_MERGE_MODE="pr"`):
```bash
./scripts/git/create_pr.sh                          # interactive
./scripts/git/create_pr.sh --non-interactive        # skip prompts
./scripts/git/create_pr.sh --dry-run                # preview only
./scripts/git/create_pr.sh --title "feat: my PR"   # override title
./scripts/git/create_pr.sh --draft                  # open as draft
./scripts/git/create_pr.sh --source feature/hotfix --target release/1.2
```
Creates a GitHub PR from source → target via `gh` CLI. Requires `gh auth login`. Charlie CI auto-reviews on PR open.

**Syncing with remote:**
```bash
./scripts/git/sync_branches.sh              # sync current branch
./scripts/git/sync_branches.sh --all        # sync both source and target branches
./scripts/git/sync_branches.sh --branch main  # sync a specific branch
./scripts/git/sync_branches.sh --dry-run    # preview (fetch only, no merge)
./scripts/git/sync_branches.sh --prune      # also remove stale remote-tracking refs
```

**Rollback a merge:**
```bash
./scripts/git/rollback_merge.sh                          # interactive (hard reset)
./scripts/git/rollback_merge.sh --revert                 # safe revert (preserves history, no force-push)
./scripts/git/rollback_merge.sh --dry-run
./scripts/git/rollback_merge.sh --non-interactive --target pre-merge-backup-20260101_120000-12345
```

**Cherry-picking a commit:**
```bash
./scripts/git/cherry_pick_commits.sh                       # interactive
./scripts/git/cherry_pick_commits.sh --commit abc1234      # non-interactive
./scripts/git/cherry_pick_commits.sh --dry-run --commit abc1234
./scripts/git/cherry_pick_commits.sh --source feature/hotfix --target release/1.2 --commit abc1234
```

**Merging docs only:**
```bash
./scripts/git/merge_docs.sh
./scripts/git/merge_docs.sh --non-interactive
./scripts/git/merge_docs.sh --source feature/hotfix --target release/1.2 --non-interactive
```

**Undoing something:**
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

**Branch cleanup:**
```bash
# Dry-run preview (safe default — shows what would be deleted):
./scripts/git/branch_cleanup.sh

# Execute: delete merged branches + prune stale remote-tracking refs:
./scripts/git/branch_cleanup.sh --execute

# Also clean up old backup tags:
./scripts/git/branch_cleanup.sh --tags --execute
```

**Safe rebase:**
```bash
# Rebase current branch onto target:
./scripts/git/rebase_safe.sh --onto main

# Rebase with auto-stash (stash dirty tree before, restore after):
./scripts/git/rebase_safe.sh --onto main --autostash

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

**Bisecting a bug:**
```bash
# Automated: provide a test command
./scripts/git/bisect_helper.sh --good v1.0.0 --run "bash tests/smoke_test.sh"

# Manual: mark commits good/bad interactively
./scripts/git/bisect_helper.sh --good v1.0.0

# Abort stuck session:
./scripts/git/bisect_helper.sh --abort
```

**Generating a changelog:**
```bash
./scripts/git/changelog_generate.sh --from v1.0.0           # since tag → stdout
./scripts/git/changelog_generate.sh --from v1.0.0 --output CHANGELOG.md
```

**Stashing work in progress:**
```bash
./scripts/git/stash_work.sh push "wip: description"
./scripts/git/stash_work.sh pop
./scripts/git/stash_work.sh list
```

**Creating a release:**
```bash
./scripts/git/create_release.sh v1.2.3 --push   # tag + push (triggers GitHub Release)
./scripts/git/create_release.sh v1.2.3 --dry-run
```

**Project setup & hygiene:**
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
```
