# Testing Guide & Hardening Campaign

This document records the structural testing architecture, baseline metrics, and phased hardening campaign for **claude-git-workflow (CGW)**.

---

## 1. Test Architecture Overview

CGW is a bash script toolkit that wraps git operations with safety rails. Its test suite is implemented using **Bats (Bash Automated Testing System)** and structured into two primary tiers:

- **Unit Tier (`tests/unit/`)**: 4 files, 332 tests. Exercises pure logic and deterministic helpers in `scripts/git/_common.sh` and `scripts/git/_config.sh` (tag parsing, branch naming, local-file regex matching, lock retry logic).
- **Integration Tier (`tests/integration/`)**: 42 files, 875 tests. Exercises script CLI workflows, git worktrees, safety guardrails (`cc_guardrail`, `agy_guardrail`), hooks, and external tool integration.
- **Fixtures & Helpers (`tests/helpers/`)**:
  - `setup.bash`: Hermetic git environment isolation (`GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CEILING_DIRECTORIES`, isolated `$HOME`, auto-cleanup tempdirs). Provides both per-test (`create_test_repo`) and file-scoped (`setup_file_create_test_repo`) fixtures.
  - `mocks.bash`: Classicist boundary test doubles for external executables (`ruff`, `markdownlint`, `gh`, typecheckers). Real git operations are executed against isolated temporary repositories.

### Test Runner (`tests/run.sh`)

Because Windows Git Bash does not provide `flock`/`shlock`, `tests/run.sh` uses `xargs -P` for per-file process parallelism.

- `bash tests/run.sh` — Runs the fast batch (local default; historically intended to skip slow files).
- `bash tests/run.sh --slow` — Runs the slow batch (`CGW_SLOW_FILES`).
- `bash tests/run.sh --all` (or `CGW_RUN_SLOW=1`) — Runs the full suite (CI default).
- `CGW_TEST_TIMINGS=1 bash tests/run.sh` — Profiles execution time per test file.

---

## 2. Test Suite Baseline — 2026-10-09

The following baseline was measured prior to any code modifications:

| Metric | Value | Notes |
|--------|-------|-------|
| **Total Tests** | 1,207 | 1,204 passing, 3 skipped, 0 failing |
| **Unit Tier Tests** | 332 | 331 passing, 1 skipped (`tests/unit/common.bats:1279` ruff check) |
| **Integration Tier Tests** | 875 | 873 passing, 2 skipped (bugs #C2, #C3 documented in test files) |
| **Fast-Loop Time (`tests/unit/`)** | 5m 40s | Dominated by `common.bats` (260 tests, serial execution) |
| **Default Batch Wall-Clock (`tests/run.sh`)** | ~8m 00s | 676 tests across 40 files |
| **Slow Batch Wall-Clock (`tests/run.sh --slow`)** | ~4m 45s | 531 tests across 6 files |
| **Full Suite Wall-Clock (estimated)** | ~12m 45s | Combined run under parallel load |
| **Ineffective Negations (SC2314)** | 60 | Across 18 test files; `! cmd` does not trigger Bats test failure |
| **Production Code ShellCheck Errors** | 0 | Clean pass across `scripts/git/*.sh` and `hooks/*` |
| **High-Churn Hotspots (Production)** | `configure.sh` (73), `_common.sh` (73), `commit_enhanced.sh` (57), `_config.sh` (44) | Commit count in last 12 months |
| **High-Churn Hotspots (Tests)** | `common.bats` (45), `commit_enhanced.bats` (37), `configure.bats` (20), `cc_guardrail.bats` (20), `check_lint.bats` (19) | Commit count in last 12 months |

---

## 3. Key Findings & Diagnostic Analysis

### A. Ineffective Negation Assertions (SC2314)

In Bats test files running under `set -e`, lines such as:

```bash
! grep -q "unexpected_text" "$LOG"
grep -q "expected_text" "$LOG"
```

do **not** fail the test when `unexpected_text` is found, because `! <cmd>` clears the exit code unless it is the final statement in the `@test` block.

- **Identified**: 60 occurrences across 18 test files (`merge_pr.bats`: 18, `check_lint.bats`: 8, `configure.bats`: 6, `branch_cleanup.bats`: 5, `common.bats`: 4, `create_release.bats`: 3, `push_validated.bats`: 1, etc.).
- **Impact**: These tests can pass silently even when an unexpected action (e.g., unintended PR edit or merge) occurred.

### B. Batch Tuning Inversion

The hardcoded `CGW_SLOW_FILES` list in `tests/run.sh` contains:

```bash
CGW_SLOW_FILES=(
  "tests/unit/common.bats"                  # 282s
  "tests/integration/commit_enhanced.bats"  # 243s
  "tests/integration/configure.bats"        # 220s
  "tests/integration/merge_validation.bats" # 185s
  "tests/integration/cc_guardrail.bats"     # 189s
  "tests/integration/cherry_pick.bats"      # 111s
)
```

However, recent additions to other test files have shifted runtime drastically:

- `tests/integration/check_lint.bats` now takes **489s** (slower than every file in the slow batch!).
- `tests/integration/merge_pr.bats` takes **382s**.
- `tests/integration/hook_preservation.bats` takes **377s**.
- `tests/integration/push_validated.bats` takes **345s**.
- `tests/integration/agy_guardrail.bats` takes **299s**.

As a result, the default "fast batch" runs for 8 minutes, while the "slow batch" completes in under 5 minutes.

### C. Fixture Creation Overhead on Windows

Files such as `check_lint.bats` (73 tests) and `merge_pr.bats` (34 tests) execute `create_test_repo` inside `setup()`, re-running `git init`, `git config`, multiple commits, and branch creation on every test case.
For tests that merely verify command flags (e.g. `--skip-lint`, `--dry-run`, invalid arguments, missing binaries), this induces substantial unnecessary process creation overhead. Migrating read-only tests to `setup_file_create_test_repo` or scoping fixtures preserves isolation while reducing runtime.

---

## 4. Phased Hardening Campaign

```mermaid
flowchart LR
    P1["Phase 1: Assertion Integrity (SC2314)"] --> P2["Phase 2: Fixture Optimization (check_lint / merge_pr)"]
    P2 --> P3["Phase 3: Runner Retuning (CGW_SLOW_FILES)"]
    P3 --> P4["Phase 4: Test Lint Gate in CI"]
```

### Phase 1: Test Assertion Integrity (Fix SC2314) — [COMPLETED]

- **Objective**: Eliminate all 60 instances of ineffective negation assertions across all `.bats` files.
- **Pattern**: Replaced `! <command>` with `run ! <command>` (supported in Bats >= 1.5.0) or `run <command>; [ "$status" -ne 0 ]` / `[[ "${output}" != *pattern* ]]`.
- **Target Files**:
  - `tests/integration/merge_pr.bats` (18 fixed)
  - `tests/integration/check_lint.bats` (8 fixed)
  - `tests/integration/configure.bats` (6 fixed)
  - `tests/integration/branch_cleanup.bats` (5 fixed)
  - `tests/unit/common.bats` (4 fixed)
  - `tests/integration/create_release.bats` (3 fixed)
  - `tests/integration/worktree.bats` (2 fixed)
  - `tests/integration/merge_docs.bats` (2 fixed)
  - `tests/integration/cherry_pick.bats` (2 fixed)
  - `tests/integration/commit_enhanced.bats` (2 fixed)
  - `tests/integration/push_validated.bats` (1 fixed)
  - `tests/integration/rebase_safe.bats` (1 fixed)
  - `tests/integration/undo_last.bats` (1 fixed)
  - `tests/integration/bisect_helper.bats` (1 fixed)
  - `tests/integration/cc_guardrail.bats` (1 fixed)
  - `tests/integration/fix_lint.bats` (1 fixed)

#### Phase 1 Before/After Table

| Metric | Before Phase 1 | After Phase 1 | Status |
|--------|----------------|---------------|--------|
| Ineffective Negation Assertions (SC2314) | 60 | **0** | **100% Resolved** |
| Files with Assertion Integrity Bugs | 18 | **0** | **100% Resolved** |
| Modified Test Files Passing | 15 / 15 | **15 / 15** | **100% Green** |
| Masked Failures Uncovered | - | 1 caught & fixed (`branch_cleanup.bats` multiline regex) | **Resolved** |

### Phase 2: Fixture Optimization & Fast-Feedback Acceleration

- **Objective**: Address the 489-second wall-clock bottleneck in `check_lint.bats` and 382-second bottleneck in `merge_pr.bats`.
- **Method**:
  - For read-only parameter checks, help/version flags, and static config rejections that do not write commits or mutate branches, share a file-level fixture (`setup_file_create_test_repo`) or omit full repo scaffolding.
- **Verification**: Measure runtime reduction using `CGW_TEST_TIMINGS=1 tests/run.sh`.

### Phase 3: Runner Retuning & Tier Alignment

- **Objective**: Restore the "fast batch" to its design intent (< 3 minutes wall-clock).
- **Method**:
  - Update `CGW_SLOW_FILES` in `tests/run.sh` to reflect actual slowest files based on Phase 2 timing data.
- **Verification**: Verify `bash tests/run.sh` completes within target fast feedback threshold.

### Phase 4: Continuous Test Quality Ratchet in CI

- **Objective**: Ensure new test files cannot introduce SC2314 or invalid syntax.
- **Method**:
  - Add a Bats shellcheck step to `.github/workflows/branch-protection.yml`:

    ```yaml
    - name: Lint Bats Test Files
      run: shellcheck --shell=bash -e SC2034,SC2030,SC2031,SC2164 tests/unit/*.bats tests/integration/*.bats
    ```

- **Verification**: Green CI run on branch protection workflow.
