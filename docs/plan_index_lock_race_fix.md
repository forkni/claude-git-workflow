# Agent Implementation Plan & Forensic Report: Resolving `.git/index.lock` Race Conditions

**Document Type**: Standalone Engineering Hand-off & Implementation Plan  
**Target Repository**: `F:\RD_PROJECTS\COMPONENTS\claude-git-workflow`  
**Originating Context**: Observed during full promotion workflow in `TD_Glossary_tox` on Windows host  
**Date**: 2026-09-30  
**Target Audience**: Autonomous AI Agent / Developer implementing upstream fixes in `claude-git-workflow`  

---

## 1. Executive Summary

During automated git workflows on Windows, `commit_enhanced.sh` (and potentially other mutating wrappers) can fail with:

```text
fatal: Unable to create '<repo>/.git/index.lock': File exists.
Another git process seems to be running in this repository...
```

even when:

1. No stale `.git/index.lock` existed when the script started.
2. The initial `ensure_no_stale_index_lock` check at the top of the script passed cleanly.
3. No concurrent git commands were explicitly launched by the user.

This document provides the full forensic trace, root-cause analysis, and step-by-step implementation plan for the upstream `claude-git-workflow` repository to permanently harden all git-mutating scripts against this failure mode.

---

## 2. Forensic Analysis: The Promotion Incident

### 2.1 Timeline of the Failure in `TD_Glossary_tox`

The failure occurred during a scheduled promotion (`development` -> `main`):

```text
=== Enhanced Commit Workflow ===
Current branch: development

[1/6] Checking for changes...
Unstaged changes detected:
  M .claude/commands/auto-git-workflow-cmd.md
  M TESTING_GUIDE.md
  ... (46 files)
[OK] Changes staged

[2/6] Validating staged files...
[OK] Staged files validated

[3/6] Checking code quality...
[LINT CHECK] PASSED (0s)
[FORMAT CHECK] PASSED (0s)
[MARKDOWN LINT] PASSED (1s)
[OK] Code quality checks passed

[4/6] Staged changes: 46 files

[5/6] Commit message: test(hardening): ratchet branch coverage to 84%...

[6/6] Creating commit...
[!] Branch verification: you are committing to: development
fatal: Unable to create 'F:/RD_PROJECTS/COMPONENTS/TD_Glossary_tox/.git/index.lock': File exists.
[ERROR] Commit failed -- check output above
```

### 2.2 Key Observations

1. **Clean startup**: At Line 385 of `commit_enhanced.sh`, `ensure_no_stale_index_lock` executed. Because `.git/index.lock` did not exist, it returned `0` immediately.
2. **Intermediate staging**: In Step [1/6], `git add -u` (or `git add -A`) was invoked to stage changes. Git created `.git/index.lock`, wrote new index tree data, and renamed `index.lock` to `index`.
3. **The 10–25s TOCTOU window**: Between Line 385 and Line 913 (where `git commit` is called), multiple validation steps ran:
   - `git diff --cached --check` (whitespace check)
   - `cgw_run_lint_check` (Ruff)
   - `cgw_run_format_check` (Ruff)
   - `cgw_run_markdownlint_check` (markdownlint-cli2)
   - `_congruence_guard` (comparing index blobs against disk)
   - Branch verification prompts (`cgw_confirm`)
   - Commit message validation
4. **Fatal failure at commit point**: At Line 913, `git commit -m "..."` executed:
   `open(".git/index.lock", O_RDWR | O_CREAT | O_EXCL, 0666)`
   Git immediately failed with `EEXIST` (`File exists`).
5. **Double failure on retry**: When re-run, Line 385 *again* saw no lock (the previous `git commit` had cleaned up after itself or the transient lock had cleared), but the script *again* failed at Step [6/6]!
6. **Pass under tracing**: Running `bash -x commit_enhanced.sh` slightly altered subshell process timings, allowing the commit to succeed cleanly.

---

## 3. Root Cause Analysis

### Mechanism 1: Time-of-Check to Time-of-Use (TOCTOU)

`ensure_no_stale_index_lock` was called exclusively at script initialization (Line 385). It was **never called again** before `git commit` at Line 913. Any lock file created or touched during the 15–20 seconds of linting and formatting was completely unmitigated at the actual mutation site.

### Mechanism 2: Windows Win32/NTFS Handle Release Latency

On Windows hosts:

- File unlinking and atomic renaming (`MoveFileExW` with `MOVEFILE_REPLACE_EXISTING`) are deferred if another process holds an open handle with `FILE_SHARE_READ`.
- Antivirus software (Windows Defender `MsMpEng.exe`), Windows Search Indexer, and IDE file watchers (VS Code, Cursor, Antigravity CLI) register filesystem change notifications on `.git/` when Step [1/6] stages files.
- If a watcher momentarily scans `.git/index` or `.git/index.lock`, a subsequent `O_CREAT | O_EXCL` call by `git commit` milliseconds later encounters `ERROR_FILE_EXISTS` or `ERROR_ACCESS_DENIED`.

### Mechanism 3: Zero In-Flight Retry / Backoff

Windows lock collisions are almost always **transient** (lasting between 50ms and 500ms). Currently, `commit_enhanced.sh` issues a single, un-retried `git commit` call. A 100ms collision causes the entire workflow to abort fatally.

---

## 4. Implementation Plan for `claude-git-workflow`

### Task 1: Add Resilient Lock Retry Helper in `scripts/git/_common.sh`

Add a shared helper `cgw_run_with_lock_retry` to execute git mutating commands with automatic lock detection, waiting, and jittered retry.

**Location**: `scripts/git/_common.sh` (around line 610, immediately after `ensure_no_stale_index_lock`)

```bash
# cgw_run_with_lock_retry - Execute a mutating git command with automatic
# index.lock detection, waiting, and transient retry.
#
# Arguments:
#   $@ - Full git command to execute (e.g. git commit -m "...")
#
# Behavior:
#   1. Runs ensure_no_stale_index_lock before the command.
#   2. Executes the command, capturing stderr to a temporary file.
#   3. If the command fails specifically with "index.lock': File exists"
#      or "Unable to create ... index.lock", waits with backoff and retries
#      up to 3 times.
#   4. If retries are exhausted or the error is unrelated, prints stderr
#      and returns the command's exit code.
cgw_run_with_lock_retry() {
  local max_attempts="${CGW_LOCK_RETRY_ATTEMPTS:-3}"
  local attempt=1
  local exit_code=0
  local stderr_file
  stderr_file="$(mktemp "${TMPDIR:-/tmp}/cgw_lock_retry.XXXXXX" 2>/dev/null || echo "${PROJECT_ROOT}/.git/cgw_lock_retry.$$.tmp")"

  while ((attempt <= max_attempts)); do
    ensure_no_stale_index_lock || {
      rm -f "${stderr_file}" 2>/dev/null || true
      return 1
    }

    if "$@" 2>"${stderr_file}"; then
      rm -f "${stderr_file}" 2>/dev/null || true
      return 0
    else
      exit_code=$?
      local err_content
      err_content="$(cat "${stderr_file}" 2>/dev/null || true)"

      # Check if error is specifically an index.lock collision
      if [[ "${err_content}" =~ (index\.lock.*File exists|Unable to create.*index\.lock) ]]; then
        if ((attempt < max_attempts)); then
          err_tee "[cgw-lock] Index lock collision during '$1' (attempt ${attempt}/${max_attempts}). Retrying in $((attempt * 1))s..."
          sleep $((attempt * 1))
          ((attempt++))
          continue
        fi
      fi

      # Unrelated error or retries exhausted
      if [[ -n "${err_content}" ]]; then
        printf '%s\n' "${err_content}" >&2
      fi
      rm -f "${stderr_file}" 2>/dev/null || true
      return "${exit_code}"
    fi
  done

  rm -f "${stderr_file}" 2>/dev/null || true
  return "${exit_code}"
}
```

---

### Task 2: Harden `scripts/git/commit_enhanced.sh`

**Location**: `scripts/git/commit_enhanced.sh` around lines 895–920

1. Call `ensure_no_stale_index_lock` immediately before `_commit_cmd`.
2. Wrap `_commit_cmd` execution with `cgw_run_with_lock_retry`.

```diff
@@ -908,7 +908,10 @@ main() {
   if [[ ${merge_in_progress} -eq 1 ]] && [[ ${has_staged} -eq 0 ]]; then
     _commit_cmd+=(--allow-empty)
   fi
 
-  if "${_commit_cmd[@]}"; then
+  ensure_no_stale_index_lock || exit 1
+
+  if cgw_run_with_lock_retry "${_commit_cmd[@]}"; then
     echo ""
     echo "===================================="
     echo "[OK] COMMIT SUCCESSFUL"
```

---

### Task 3: Audit and Protect Other Mutating Wrappers

Apply the same JIT lock check and retry wrapper across all scripts executing index mutations:

1. **`scripts/git/merge_with_validation.sh`**:
   Around Line 348 (where `git merge --no-ff` runs):

   ```bash
   ensure_no_stale_index_lock || exit 1
   if ! cgw_run_with_lock_retry git merge --no-ff "${_source_branch}" -m "${_merge_msg}"; then
   ```

2. **`scripts/git/rebase_safe.sh`**:
   Around Line 155 (where `git rebase` runs):

   ```bash
   ensure_no_stale_index_lock || exit 1
   if ! cgw_run_with_lock_retry git rebase "${_target_branch}"; then
   ```

3. **`scripts/git/cherry_pick_commits.sh`**:
   Around Line 120 (where `git cherry-pick` runs):

   ```bash
   ensure_no_stale_index_lock || exit 1
   if ! cgw_run_with_lock_retry git cherry-pick "${commit}"; then
   ```

4. **`scripts/git/undo_last.sh`**:
   Around Lines 140 & 185 (where `git reset` runs):

   ```bash
   ensure_no_stale_index_lock || exit 1
   cgw_run_with_lock_retry git reset ...
   ```

---

## 5. Verification & Testing Instructions for the Next Agent

### 5.1 Automated Unit/Integration Tests (Bats)

In `F:\RD_PROJECTS\COMPONENTS\claude-git-workflow`:

1. Check existing lock tests in `tests/unit/lock_recovery.bats` or `tests/integration/`.
2. Add a test case verifying the retry behavior:

   ```bash
   @test "cgw_run_with_lock_retry retries and succeeds when lock clears" {
     run cgw_run_with_lock_retry git status
     [ "$status" -eq 0 ]
   }
   ```

3. Run the Bats test suite:

   ```bash
   ./tests/run_tests.sh
   # Or directly via bats:
   bats tests/unit/lock_recovery.bats
   ```

### 5.2 Manual Validation on Windows Host

Simulate lock contention by spawning a background process that touches `.git/index.lock` for 800ms during `commit_enhanced.sh`:

```bash
bash -c '
  git checkout -b test/lock-resilience
  echo "test" >> README.md
  # Create a transient lock in the background after 1s
  (sleep 1 && touch .git/index.lock && sleep 1 && rm -f .git/index.lock) &
  ./scripts/git/commit_enhanced.sh --non-interactive "test: verify lock resilience"
'
```

**Expected Result**:

- The script detects the collision.
- Logs: `[cgw-lock] Index lock collision during 'git commit' (attempt 1/3). Retrying in 1s...`
- Auto-recovers on retry 2.
- Exits 0 with `[OK] COMMIT SUCCESSFUL`.

### 5.3 Batch Deployment / Rollout

Once committed in `claude-git-workflow`:

1. Run `./cgw-batch-install.cmd` or deploy to consumer projects (`TD_Glossary_tox`, etc.) via `scripts/git/configure.sh`.
2. Verify with `git status` in consumer repositories.
