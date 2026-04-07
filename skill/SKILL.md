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

Are local-only files staged?
├─ Yes → commit_enhanced.sh unstages them automatically
└─ No  → Proceed

Did lint checks fail?
├─ Yes → Run ./scripts/git/fix_lint.sh then retry commit
└─ No  → Commit proceeds

After commit: verify with git log --oneline -1
```

**Merging to target branch:**
```bash
# Preview first (no changes):
./scripts/git/merge_with_validation.sh --dry-run

# Execute merge:
./scripts/git/merge_with_validation.sh --non-interactive
```
Handles: pre-merge validation, backup tag, modify/delete/both-deleted conflict auto-resolution, content conflict detection (stops for manual review).

**Pushing to remote:**
```bash
./scripts/git/push_validated.sh               # with lint check
./scripts/git/push_validated.sh --dry-run     # preview
./scripts/git/push_validated.sh --skip-lint   # skip lint check
```

**Syncing with remote:**
```bash
./scripts/git/sync_branches.sh           # sync current branch
./scripts/git/sync_branches.sh --all     # sync both branches
```

**Rollback a merge:**
```bash
./scripts/git/rollback_merge.sh                          # interactive
./scripts/git/rollback_merge.sh --dry-run
./scripts/git/rollback_merge.sh --non-interactive --target pre-merge-backup-20260101_120000
```

**Cherry-picking a commit:**
```bash
./scripts/git/cherry_pick_commits.sh                       # interactive
./scripts/git/cherry_pick_commits.sh --commit abc1234      # non-interactive
./scripts/git/cherry_pick_commits.sh --dry-run --commit abc1234
```

**Merging docs only:**
```bash
./scripts/git/merge_docs.sh
./scripts/git/merge_docs.sh --non-interactive
```
