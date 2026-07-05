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
    export PROJECT_ROOT='${TEST_REPO_DIR}'
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
    export PROJECT_ROOT='${TEST_REPO_DIR}'
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
    export PROJECT_ROOT='${TEST_REPO_DIR}'
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
    export PROJECT_ROOT='${TEST_REPO_DIR}'
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
    export PROJECT_ROOT='${TEST_REPO_DIR}'
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
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [[ "${output}" == *"FAILED"* ]]
}

# ── format check is non-blocking (mirrors CI's shfmt continue-on-error) ───────
# .github/workflows/branch-protection.yml has marked the shfmt step
# `continue-on-error: true` since that workflow's introduction; a format-only
# failure here must not flip overall STATUS/exit code, only lint/markdown do.

# ruff mock that discriminates by subcommand: passes "check" (lint), fails
# "format" (format check) -- isolates the format-only failure path.
_install_mock_ruff_format_fails() {
  cat > "${MOCK_BIN_DIR}/ruff" << 'EOF'
#!/usr/bin/env bash
echo "mock ruff $*" >> "${0%/*}/ruff.log"
[[ "$1" == "format" ]] && { echo "1 file would be reformatted"; exit 1; }
exit 0
EOF
  chmod +x "${MOCK_BIN_DIR}/ruff"
}

@test "format check failure alone does not fail overall exit code" {
  _install_mock_ruff_format_fails
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_MARKDOWNLINT_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [ "${status}" -eq 0 ]
}

@test "format check failure alone reports WARN, not FAILED, and overall PASSED" {
  _install_mock_ruff_format_fails
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_MARKDOWNLINT_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [[ "${output}" =~ Format[[:space:]]+WARN ]]
  [[ "${output}" == *"STATUS: PASSED"* ]]
}

# The test above only proves the SUMMARY TABLE says WARN -- that wording comes
# from check_lint.sh's own aggregation and would pass even without the
# CGW_SECTION_FAIL_LABEL fix. These two tests exercise the per-step log-section
# footer (printed by log_section_end via run_tool_with_logging), which is what
# CGW_SECTION_FAIL_LABEL / CGW_FORMAT_CHECK_NONBLOCKING actually control.

@test "format check failure: per-step FORMAT CHECK line says WARN, not FAILED" {
  _install_mock_ruff_format_fails
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_MARKDOWNLINT_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  local warn_re='\[FORMAT CHECK\] Ended:.*WARN'
  local fail_re='\[FORMAT CHECK\] Ended:.*FAILED'
  [[ "${output}" =~ $warn_re ]]
  [[ ! "${output}" =~ $fail_re ]]
}

@test "lint failure: per-step LINT CHECK line still says FAILED (label not globalized)" {
  MOCK_LINT_EXIT=1 install_mock_lint
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  local fail_re='\[LINT CHECK\] Ended:.*FAILED'
  [[ "${output}" =~ $fail_re ]]
}

# ── --skip-md-lint ────────────────────────────────────────────────────────────

@test "--skip-md-lint skips markdown lint step" {
  install_mock_lint
  install_mock_markdownlint
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
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
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --modified-only
  "
  [ "${status}" -eq 0 ]
}

@test "--modified-only scopes to the modified file under a non-default arg shape (A3)" {
  install_mock_lint
  echo "x = 1" > "${TEST_REPO_DIR}/mod.py"
  git -C "${TEST_REPO_DIR}" add mod.py
  git -C "${TEST_REPO_DIR}" -c core.hooksPath=/dev/null commit --quiet -m "chore: add mod.py"
  echo "x = 2" > "${TEST_REPO_DIR}/mod.py"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_LINT_CHECK_ARGS='check {files} --no-cache'
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --modified-only
  "
  [ "${status}" -eq 0 ]
  # The linter received the modified file; the {files} placeholder was resolved
  # (not leaked literally) and did not revert to a whole-repo scan.
  grep -q "mod.py" "${MOCK_BIN_DIR}/ruff.log"
  ! grep -q "{files}" "${MOCK_BIN_DIR}/ruff.log"
}

@test "--modified-only format-only failure is non-blocking (exit 0), mirrors full mode" {
  _install_mock_ruff_format_fails
  echo "x = 1" > "${TEST_REPO_DIR}/mod.py"
  git -C "${TEST_REPO_DIR}" add mod.py
  git -C "${TEST_REPO_DIR}" -c core.hooksPath=/dev/null commit --quiet -m "chore: add mod.py"
  echo "x = 2" > "${TEST_REPO_DIR}/mod.py"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=ruff
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --modified-only
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[FORMAT CHECK]"* ]]
  [[ "${output}" == *"non-blocking"* ]]
}
