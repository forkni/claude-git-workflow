#!/usr/bin/env bats
# tests/integration/fix_lint.bats - Integration tests for fix_lint.sh
# Runs: bats tests/integration/fix_lint.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo
  setup_mock_bin
}

teardown() {
  cleanup_test_repo
}

# ── CGW_LINT_CMD="" disables fix ──────────────────────────────────────────────

@test "CGW_LINT_CMD='' exits 0 and skips fix" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/fix_lint.sh'
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"skip"* ]] || [[ "${output}" == *"Skip"* ]] || \
    [[ "${output}" == *"not set"* ]]
}

# ── --help ────────────────────────────────────────────────────────────────────

@test "--help exits 0" {
  run run_script fix_lint.sh --help
  [ "${status}" -eq 0 ]
}

# ── Mock lint fix passing ─────────────────────────────────────────────────────

@test "with lint tool returning 0: fix_lint exits 0" {
  install_mock_lint
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/fix_lint.sh'
  "
  [ "${status}" -eq 0 ]
}

# ── Mock lint fix failing ─────────────────────────────────────────────────────

@test "with lint tool returning 1: fix_lint reports issues in output" {
  install_mock_lint_with_errors
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/fix_lint.sh'
  "
  [[ "${output}" == *"issues"* ]] || [[ "${output}" == *"FAILED"* ]] || \
    [[ "${output}" == *"error"* ]]
}
