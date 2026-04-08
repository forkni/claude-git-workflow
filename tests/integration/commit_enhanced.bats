#!/usr/bin/env bats
# tests/integration/commit_enhanced.bats - Integration tests for commit_enhanced.sh
# Runs: bats tests/integration/commit_enhanced.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo
  setup_mock_bin
  install_mock_lint
  git -C "${TEST_REPO_DIR}" checkout development
}

teardown() {
  cleanup_test_repo
}

# Helper: run commit_enhanced.sh with shared env vars
_run_commit() {
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PATH='${MOCK_BIN_DIR}:\${PATH}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' $*
  "
}

# ── No staged changes ─────────────────────────────────────────────────────────

@test "no staged changes exits 0 with no-changes message" {
  run _run_commit "\"feat: test\""
  # Script should exit 0 and mention no changes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No changes"* ]] || [[ "${output}" == *"nothing to commit"* ]] || \
    [[ "${output}" == *"no changes"* ]]
}

# ── Missing commit message ────────────────────────────────────────────────────

@test "missing commit message exits 1" {
  echo "test content" > "${TEST_REPO_DIR}/test_file.txt"
  git -C "${TEST_REPO_DIR}" add test_file.txt
  run _run_commit ""
  [ "${status}" -eq 1 ]
}

# ── Invalid commit prefix ─────────────────────────────────────────────────────

@test "invalid commit prefix warns in non-interactive mode" {
  echo "content" > "${TEST_REPO_DIR}/new_file.txt"
  git -C "${TEST_REPO_DIR}" add new_file.txt
  run _run_commit "\"wip: bad prefix\""
  # Non-interactive: should warn or fail — either warns about prefix or exits non-zero
  [[ "${output}" == *"prefix"* ]] || [[ "${output}" == *"format"* ]] || [ "${status}" -ne 0 ]
}

# ── Valid conventional commit ─────────────────────────────────────────────────

@test "valid conventional commit with staged file succeeds" {
  echo "feature content" > "${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  run _run_commit "--skip-lint \"feat: add feature file\""
  [ "${status}" -eq 0 ]
}

@test "valid conventional commit appears in git log" {
  echo "another feature" > "${TEST_REPO_DIR}/another.txt"
  git -C "${TEST_REPO_DIR}" add another.txt
  _run_commit "--skip-lint \"feat: add another file\""
  last_msg=$(git -C "${TEST_REPO_DIR}" log -1 --format="%s")
  [ "${last_msg}" = "feat: add another file" ]
}

# ── Local-only file protection ────────────────────────────────────────────────

@test "CLAUDE.md is never staged or committed" {
  # Create CLAUDE.md and stage everything
  echo "# Claude" > "${TEST_REPO_DIR}/CLAUDE.md"
  echo "real content" > "${TEST_REPO_DIR}/real.txt"
  git -C "${TEST_REPO_DIR}" add .
  _run_commit "--skip-lint \"feat: add real content\"" || true
  # CLAUDE.md must not appear in git tree
  tracked=$(git -C "${TEST_REPO_DIR}" ls-files CLAUDE.md)
  [ -z "${tracked}" ]
}

# ── --skip-lint flag ──────────────────────────────────────────────────────────

@test "--skip-lint skips lint step" {
  echo "skip lint test" > "${TEST_REPO_DIR}/skip_test.txt"
  git -C "${TEST_REPO_DIR}" add skip_test.txt
  run _run_commit "--skip-lint \"feat: skip lint test\""
  [ "${status}" -eq 0 ]
  # ruff mock log should be empty or absent when skipped
}

# ── --staged-only flag ────────────────────────────────────────────────────────

@test "--staged-only does not auto-stage unstaged files" {
  echo "unstaged" > "${TEST_REPO_DIR}/unstaged.txt"
  # Do NOT git add — file is untracked
  run _run_commit "--skip-lint --staged-only \"feat: staged only\""
  # Unstaged file should not end up committed
  tracked=$(git -C "${TEST_REPO_DIR}" ls-files unstaged.txt)
  [ -z "${tracked}" ]
}

# ── --non-interactive flag ────────────────────────────────────────────────────

@test "--non-interactive auto-stages tracked modified files" {
  # Create a tracked file and modify it without staging
  echo "initial" > "${TEST_REPO_DIR}/tracked.txt"
  git -C "${TEST_REPO_DIR}" add tracked.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: add tracked"
  echo "modified" > "${TEST_REPO_DIR}/tracked.txt"
  # Non-interactive should auto-stage the modification
  run _run_commit "--skip-lint \"feat: auto-staged change\""
  [ "${status}" -eq 0 ]
}
