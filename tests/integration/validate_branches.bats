#!/usr/bin/env bats
# tests/integration/validate_branches.bats - Integration tests for validate_branches.sh
# Runs: bats tests/integration/validate_branches.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo_with_remote
  setup_mock_bin
}

teardown() {
  cleanup_test_repo
}

_run_validate() {
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PATH='${MOCK_BIN_DIR}:\${PATH}'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/validate_branches.sh' $*
  "
}

# ── Clean source branch ───────────────────────────────────────────────────────

@test "on source branch with clean state exits 0" {
  git -C "${TEST_REPO_DIR}" checkout development
  run _run_validate ""
  [ "${status}" -eq 0 ]
}

# ── Uncommitted changes ───────────────────────────────────────────────────────

@test "uncommitted tracked changes exits 1" {
  git -C "${TEST_REPO_DIR}" checkout development
  # Modify a tracked file without committing
  echo "dirty" >> "${TEST_REPO_DIR}/DEV.md"
  run _run_validate ""
  [ "${status}" -eq 1 ]
}

@test "uncommitted changes output mentions dirty or uncommitted" {
  git -C "${TEST_REPO_DIR}" checkout development
  echo "dirty" >> "${TEST_REPO_DIR}/DEV.md"
  run _run_validate ""
  [[ "${output}" == *"uncommitted"* ]] || [[ "${output}" == *"dirty"* ]] || \
    [[ "${output}" == *"changes"* ]] || [[ "${output}" == *"modified"* ]]
}

# ── Untracked files ───────────────────────────────────────────────────────────

@test "untracked files exits 0 (warning only)" {
  git -C "${TEST_REPO_DIR}" checkout development
  echo "untracked" > "${TEST_REPO_DIR}/untracked_file.txt"
  run _run_validate ""
  # Untracked files = warning but not failure
  [ "${status}" -eq 0 ]
}

# ── Ahead/behind reporting ────────────────────────────────────────────────────

@test "output reports branch state information" {
  git -C "${TEST_REPO_DIR}" checkout development
  run _run_validate ""
  # Should print something about branch state — ahead, behind, or up to date
  [ -n "${output}" ]
}

# ── Branch existence check ────────────────────────────────────────────────────

@test "non-existent source branch exits non-zero" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export CGW_SOURCE_BRANCH=nonexistent-branch
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/validate_branches.sh'
  "
  [ "${status}" -ne 0 ]
}
