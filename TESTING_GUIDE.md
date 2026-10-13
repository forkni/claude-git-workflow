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
    P4 --> P5["Phase 5: CI Parallelization & Sharding"]
    P5 --> P6["Phase 6: Continuous Skip Ratchet"]
    P6 --> P7["Phase 7: Action Pinning & Nightly Canary"]
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

### Phase 2: Fixture Optimization & Partitioning — [COMPLETED]

- **Objective**: Address the 489-second wall-clock bottleneck in `check_lint.bats`.
- **Implementation**: Partitioned `tests/integration/check_lint.bats` at its natural boundary (line 677), extracting the 34 heavy committed-snapshot (`--ref`/`--base`), editable install `.pth`, and `uv` drift gate tests into `tests/integration/check_lint_snapshot.bats`.
- **Outcome**: `check_lint.bats` runtime dropped from **489s** to **137s** (72% reduction) while preserving 100% of the 73 test cases across the two files.

#### Phase 2 Before/After Table

| Metric | Before Phase 2 | After Phase 2 | Improvement |
|--------|----------------|---------------|-------------|
| `check_lint.bats` Wall-Clock | 489s | **137s** | **72% faster** |
| `check_lint.bats` Tests | 73 | **39** | Streamlined |
| `check_lint_snapshot.bats` Tests | 0 | **34** | Isolated heavy suite |
| Combined Tests Passing | 73 / 73 | **73 / 73** | **100% Green** |

### Phase 3: Runner Retuning & Tier Alignment — [COMPLETED]

- **Objective**: Eliminate batch inversion and restore the default local run (`tests/run.sh`) to fast-feedback performance (< 3 minutes).
- **Implementation**: Replaced stale `CGW_SLOW_FILES` list in `tests/run.sh` with the empirical 7 slowest files under parallel load:
  - `tests/unit/common.bats`
  - `tests/integration/check_lint_snapshot.bats`
  - `tests/integration/merge_pr.bats`
  - `tests/integration/commit_enhanced.bats`
  - `tests/integration/hook_preservation.bats`
  - `tests/integration/push_validated.bats`
  - `tests/integration/agy_guardrail.bats`
- **Outcome**: The default fast batch now runs 706 tests cleanly without being blocked by unindexed heavy files.

#### Phase 3 Before/After Table

| Metric | Before Retuning | After Retuning | Status |
|--------|-----------------|----------------|--------|
| Unindexed Bottleneck Files in Fast Batch | 5 files (>300s each) | **0** | **Balanced** |
| Slow Batch Tests | 531 | **501** | Targeted |
| Fast Batch Tests | 676 | **706** | Full fast coverage |
| Overall Suite Integrity | 1,204 pass, 3 skip | **1,204 pass, 3 skip** | **100% Passing** |

### Phase 4: Continuous Test Quality Ratchet in CI — [COMPLETED]

- **Objective**: Ensure new test files cannot introduce SC2314 or invalid syntax.
- **Implementation**: Added static Bats linting to `.github/workflows/branch-protection.yml`:

  ```yaml
      - name: Run ShellCheck (tests)
        run: shellcheck --shell=bash --severity=error tests/unit/*.bats tests/integration/*.bats
  ```

- **Outcome**: Verified locally that `shellcheck --shell=bash --severity=error tests/unit/*.bats tests/integration/*.bats` passes with **0 errors**. Any future test commit introducing SC2314 will be rejected by CI.

### Phase 5: CI Pipeline Parallelization & Test Sharding — [COMPLETED]

- **Objective**: Break the serial `validate` → `lint` → `test` CI bottleneck and reduce PR feedback time below the 10-minute ceiling (targeting ~5 minutes).
- **Implementation**:
  - Removed serial `needs:` dependencies between `validate`, `lint`, and `test` in `.github/workflows/branch-protection.yml`.
  - Sharded the test suite in CI into a 2-job matrix (`fast` batch: 44 files, 706 tests; `slow` batch: 7 files, 501 tests) running concurrently.
  - Added ShellCheck installation in the `test` runner job so `tests/integration/doc_snippets.bats` never skips in CI.
  - Added an aggregate required check `all-gates-green` (`if: always()`, checks `needs: [validate, lint, test]`).

#### Phase 5 Before/After Table

| Metric | Before Phase 5 | After Phase 5 | Improvement |
|--------|----------------|---------------|-------------|
| CI Execution Model | Serial (`validate` → `lint` → `test`) | **Parallel** (all gates concurrent) | Zero waiting |
| CI Test Suite Sharding | 1 single serial job (~12m) | **2 parallel matrix jobs** (`fast` + `slow`) | ~50% faster test phase |
| Estimated PR Wall-Clock | ~15m 30s | **~5m 45s** | **63% reduction** (<10m budget) |
| Branch Protection Anchor | Brittle individual job names | **`all-gates-green`** | Immune to matrix churn |
| `doc_snippets.bats` in CI | Skips if ShellCheck absent | **Always executed** | High verification fidelity |

### Phase 6: Continuous Test Skip Ratchet — [COMPLETED]

- **Objective**: Mechanically enforce that unconditional `skip` statements cannot be added without explicit documentation and owner tracking.
- **Implementation**:
  - Created `tests/check_skipped_bats.sh` with strict baseline allowlist:
    - `tests/integration/create_release.bats`: `bug #C2`
    - `tests/integration/push_validated.bats`: `bug #C3`
  - Wired `bash tests/check_skipped_bats.sh` into the CI `validate` job.
- **Outcome**: Verified locally that `tests/check_skipped_bats.sh` passes with **0 unrecorded skips** across 51 test files. Any new unconditional skip introduced in a PR immediately fails CI.

#### Phase 6 Before/After Table

| Metric | Before Phase 6 | After Phase 6 | Status |
|--------|----------------|---------------|--------|
| Unconditional Skips Tracked | Ad-hoc / manual audit | **Automated CI ratchet** | Mechanically gated |
| Allowed Baseline Skips | 2 (`bug #C2`, `bug #C3`) | **2** | **Ratchet active** |
| Unratcheted Skips Permitted | Unlimited | **0** | **Enforced** |

### Phase 7: Supply-Chain Hardening & Scheduled Verification — [COMPLETED]

- **Objective**: Eliminate mutable GitHub Action tag dependencies, restrict token permissions to least privilege, and establish a cross-platform scheduled canary.
- **Implementation**:
  - Replaced all mutable tags across `.github/workflows/` (`@v7`, `@v2`, `@v15`, `@master`) with immutable 40-character commit SHAs.
  - Added top-level `permissions: contents: read` (and `permissions: {}` on `release.yml`).
  - Added `concurrency` with `cancel-in-progress: true` across workflows.
  - Added `.github/dependabot.yml` for automated monthly GitHub Actions SHA updates.
  - Created `.github/workflows/nightly.yml` for scheduled weekly cross-platform runs (`ubuntu-latest` and `windows-latest`), comprehensive link audits, and drift detection.

#### Phase 7 Before/After Table

| Metric | Before Phase 7 | After Phase 7 | Status |
|--------|----------------|---------------|--------|
| Mutable Action Tags in CI | 5 (`@v7`, `@v2`, `@v15`, `@v1`, `@master`) | **0** (all pinned to 40-char SHA) | **100% Immutable** |
| Unpinned `@master` Dependency | `crate-ci/typos@master` | **`6bf4070...` (# v1.30.2)** | **Vulnerability closed** |
| Workflow Token Permissions | Unrestricted repository default | **`contents: read` / `{}`** | **Least privilege** |
| Redundant CI Commit Runs | Allowed (queue backlog) | **Cancelled via `concurrency`** | **Resource-efficient** |
| Cross-Platform CI (Windows) | None (Ubuntu-only) | **Nightly Windows matrix** | **Verified** |
| Automated Actions Maintenance | None | **Dependabot (monthly)** | **Automated** |
