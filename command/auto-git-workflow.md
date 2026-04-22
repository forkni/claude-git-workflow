# Automated Git Workflow

Execute automated commit→push→merge→push workflow using project scripts (token-efficient).

**Invocation**: `/auto-git-workflow`

**Key**: Suppress all output except errors. Show brief summary at end.

---

## Environment Detection

**Check execution environment first**:

```bash
echo $OSTYPE
# Git Bash / WSL: "msys" or "linux-gnu"
# macOS: "darwin"
# If variable empty: Windows cmd.exe
```

**Use appropriate workflow**:

- Git Bash / Linux / macOS → **Section A** (uses .sh scripts + direct git)
- Windows cmd.exe → **Section B** (uses direct git commands)

**Why this matters**: Git Bash cannot execute .bat files directly.

---

## Section A: Git Bash / Linux / macOS (Primary)

**Token-efficient execution**: All commands suppress output unless errors occur.

### ⚠️ CRITICAL - Bash Tool Compatibility

Due to Claude Code's Bash tool command parsing limitations:

- **Execute each numbered step as a SEPARATE Bash call**
- **DO NOT combine steps** with `&&` or `;` operators
- **Check exit codes** between steps

---

### Phase 1: Pre-commit Validation

**Step 1.1: Switch to source branch**

```bash
git checkout "${CGW_SOURCE_BRANCH:-development}" >/dev/null 2>&1
```

**Step 1.2: Check for changes**

```bash
git diff --quiet && git diff --cached --quiet
```

- If exit code 0: No changes, display "No changes to commit", stop workflow
- If exit code 1: Changes exist, continue

**Step 1.3: Run lint check (suppress output)**

```bash
./scripts/git/check_lint.sh >/dev/null 2>&1
```

- If exit code 0: Lint passed, skip to Phase 2
- If exit code ≠ 0: Continue to step 1.4

**Step 1.4: Auto-fix lint issues**

```bash
./scripts/git/fix_lint.sh
```

**Step 1.5: Re-verify lint**

```bash
./scripts/git/check_lint.sh
```

- Ignore errors in local-only files (CLAUDE.md, MEMORY.md, etc.) — never committed
- If still fails: Stop workflow
- If passes: Continue to Phase 2

---

### Phase 2: Commit to Source Branch

**Step 2.1: Stage changes**

*Full workflow (commit everything):*
```bash
git add .
```

*Selective commit (specific files only) — skip Step 2.1 and use `--only` in Step 2.2:*
```bash
# No git add needed — --only resets index and stages listed paths only
# See Step 2.2 alternate form below
```

**Step 2.2: Create commit**

*Full workflow:*
```bash
./scripts/git/commit_enhanced.sh --non-interactive "feat: descriptive commit message"
```

*Selective commit (no prior `git add`):*
```bash
./scripts/git/commit_enhanced.sh --non-interactive \
  --only src/file_a.py \
  --only src/file_b.py \
  "feat: descriptive commit message"
```

Replace message with appropriate conventional commit (feat:, fix:, docs:, chore:, test:).

`commit_enhanced.sh` automatically:
- Unstages local-only files (configured via `CGW_LOCAL_FILES`)
- Validates commit message format
- Runs lint check
- Respects pre-staged files: if you staged specific files and have other unstaged changes, commits pre-staged only (use `--all` to override)

**Step 2.3: Capture commit info for final report**

```bash
git log -1 --format="%h %s"
```

---

### Phase 3: Push Source Branch

**Step 3.1: Push source branch (suppress output)**

```bash
./scripts/git/push_validated.sh --non-interactive --skip-lint >/dev/null 2>&1
```

- If exit code 0: Continue to Phase 4
- If exit code ≠ 0: Run without suppression to show error, stop workflow

---

### Phase 4: Merge or PR

Check `CGW_MERGE_MODE` (or ask user preference):

```bash
echo "${CGW_MERGE_MODE:-direct}"
```

**If `CGW_MERGE_MODE=direct` (default):** → Follow Phase 4A (direct merge)

**If `CGW_MERGE_MODE=pr`:** → Follow Phase 4B (create PR, stop — CI takes over)

---

#### Phase 4A: Direct Merge to Target Branch

**Step 4A.1: Run merge with validation**

```bash
./scripts/git/merge_with_validation.sh --non-interactive
```

`merge_with_validation.sh` automatically:
- Creates backup tag
- Handles modify/delete conflicts (auto-resolved)
- Stops on content conflicts (requires manual resolution)
- Validates docs CI policy (if configured)

- If exit code 0: Continue to Phase 5
- If exit code ≠ 0: Check output for conflict type, stop workflow

---

#### Phase 4B: Create PR (triggers Charlie CI + GitHub Actions)

**Step 4B.1: Create pull request**

```bash
./scripts/git/create_pr.sh --non-interactive
```

- If exit code 0: PR created — workflow ends here (CI + Charlie review the PR)
- If exit code ≠ 0: Run without `--non-interactive` to see error

**Step 4B.2: Return to source branch**

```bash
git checkout "${CGW_SOURCE_BRANCH:-development}" >/dev/null 2>&1
```

**Final Report (PR mode):**
```
Workflow complete (PR mode)

Source branch: [hash] "[message]" pushed
PR: [url] — awaiting Charlie CI review
```

---

### Phase 5: Push Target Branch (direct mode only)

**Step 5.1: Push target branch (suppress output)**

```bash
./scripts/git/push_validated.sh --non-interactive --skip-lint >/dev/null 2>&1
```

- If exit code 0: Continue to final report
- If exit code ≠ 0: Run without suppression to show error, stop workflow

**Step 5.2: Return to source branch**

```bash
git checkout "${CGW_SOURCE_BRANCH:-development}" >/dev/null 2>&1
```

---

### Final Report (direct mode)

```bash
git log "${CGW_SOURCE_BRANCH:-development}" -1 --format="%h %s"
git log "${CGW_TARGET_BRANCH:-main}" -1 --format="%h"
```

Display:
```
Workflow complete

Source branch: [hash] "[message]"
Target branch: [hash] merged & pushed
```

---

## Section B: Windows cmd.exe (Fallback)

CGW scripts require Git Bash. Use raw git commands only when Git Bash is unavailable:

```batch
git checkout development
git add .
git commit -m "feat: descriptive commit message"
git push origin development
git checkout main
git merge development --no-ff -m "Merge development into main"
git push origin main
git checkout development
```

**Caution**: Raw `git commit` bypasses lint validation and local-only file protection. Use Section A (Git Bash) whenever possible.

---

## Error Handling

### Lint Failures

```bash
./scripts/git/fix_lint.sh
./scripts/git/check_lint.sh
```

### Local-Only Files Staged

`commit_enhanced.sh` auto-unstages these. If using raw git:
```bash
git reset HEAD CLAUDE.md MEMORY.md
```

### Modify/Delete Conflicts

**Status**: EXPECTED — auto-resolved by `merge_with_validation.sh`

### Content Conflicts (UU)

Manual resolution required:
```bash
# Edit files to resolve
git add <resolved-files>
git commit

# Or abort
git merge --abort
git checkout "${CGW_SOURCE_BRANCH:-development}"
```

### Push Failures

```bash
./scripts/git/sync_branches.sh    # sync with remote first
./scripts/git/push_validated.sh   # retry push
```

---

## Token Efficiency

- All successful commands: `>/dev/null 2>&1`
- Only show errors: remove suppression on retry
- Final summary: 4 lines maximum
