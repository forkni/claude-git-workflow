#!/usr/bin/env bats
# tests/integration/check_lint.bats - Integration tests for check_lint.sh
# Runs: bats tests/integration/check_lint.bats

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

# ── --skip-lint ────────────────────────────────────────────────────────────────

@test "--skip-lint exits 0" {
  run run_script check_lint.sh --skip-lint
  [ "${status}" -eq 0 ]
}

@test "--skip-lint output mentions skip" {
  run run_script check_lint.sh --skip-lint
  [[ "${output}" == *"skip"* ]] || [[ "${output}" == *"Skip"* ]] || [[ "${output}" == *"SKIP"* ]]
}

# ── CGW_LINT_CMD="" disables lint ─────────────────────────────────────────────

@test "CGW_LINT_CMD='' exits 0" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [ "${status}" -eq 0 ]
}

# ── CGW_SKIP_LINT=1 ────────────────────────────────────────────────────────────

@test "CGW_SKIP_LINT=1 exits 0" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export CGW_SKIP_LINT=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [ "${status}" -eq 0 ]
}

# ── Mock lint passing ─────────────────────────────────────────────────────────

@test "with lint tool returning 0: check_lint exits 0" {
  install_mock_lint
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PATH='${MOCK_BIN_DIR}:\${PATH}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [ "${status}" -eq 0 ]
}

@test "with lint tool returning 0: output contains PASSED" {
  install_mock_lint
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PATH='${MOCK_BIN_DIR}:\${PATH}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [[ "${output}" == *"PASSED"* ]]
}

# ── Mock lint failing ─────────────────────────────────────────────────────────

@test "with lint tool returning 1: check_lint exits non-zero" {
  MOCK_LINT_EXIT=1 install_mock_lint
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PATH='${MOCK_BIN_DIR}:\${PATH}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [ "${status}" -ne 0 ]
}

@test "with lint tool returning 1: output contains FAILED" {
  MOCK_LINT_EXIT=1 install_mock_lint
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PATH='${MOCK_BIN_DIR}:\${PATH}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [[ "${output}" == *"FAILED"* ]]
}

# ── --skip-md-lint ────────────────────────────────────────────────────────────

@test "--skip-md-lint skips markdown lint step" {
  install_mock_lint
  install_mock_markdownlint
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PATH='${MOCK_BIN_DIR}:\${PATH}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=markdownlint-cli2
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --skip-md-lint
  "
  # markdownlint mock log should NOT have been called
  [ ! -f "${MOCK_BIN_DIR}/mdlint.log" ] || \
    ! grep -q "markdownlint" "${MOCK_BIN_DIR}/mdlint.log" 2>/dev/null
}

# ── --modified-only ────────────────────────────────────────────────────────────

@test "--modified-only with no modified files exits 0" {
  install_mock_lint
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PATH='${MOCK_BIN_DIR}:\${PATH}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --modified-only
  "
  [ "${status}" -eq 0 ]
}
