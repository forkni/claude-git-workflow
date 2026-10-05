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

# ── --md-only ─────────────────────────────────────────────────────────────────

@test "--md-only checks markdown only, code lint does not run" {
  install_mock_lint
  install_mock_markdownlint
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=markdownlint-cli2
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --md-only
  "
  [ "${status}" -eq 0 ]
  [ ! -f "${MOCK_BIN_DIR}/ruff.log" ]
  [ -f "${MOCK_BIN_DIR}/mdlint.log" ]
}

@test "--md-only with empty CGW_MARKDOWNLINT_CMD exits 0 and skips" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --md-only
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"skip"* ]] || [[ "${output}" == *"Skip"* ]]
}

@test "--md-only and --skip-md-lint together is an error" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --md-only --skip-md-lint
  "
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"mutually exclusive"* ]]
}

@test "--md-only and --modified-only together is an error" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --md-only --modified-only
  "
  [ "${status}" -ne 0 ]
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

# ── Error-count / status consistency ──────────────────────────────────────────
# The summary's Errors column comes from a diagnostic regex while Status comes
# from the tool's exit code. markdownlint-cli2 output (file:line[:col] MDxxx)
# previously matched nothing, producing "FAILED ... 0 errors" contradictions.

@test "markdownlint diagnostics are counted in the error summary" {
  cat > "${MOCK_BIN_DIR}/markdownlint-cli2" << 'MOCK'
#!/usr/bin/env bash
echo "README.md:3 MD013/line-length Line length [Expected: 80; Actual: 200]"
exit 1
MOCK
  chmod +x "${MOCK_BIN_DIR}/markdownlint-cli2"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=markdownlint-cli2
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Total: 1 errors"* ]]
  [[ "${output}" != *"no diagnostics were parsed"* ]]
}

@test "FAILED step with zero parsed diagnostics is named a tool/config failure" {
  cat > "${MOCK_BIN_DIR}/markdownlint-cli2" << 'MOCK'
#!/usr/bin/env bash
echo "Cannot find configuration file .markdownlint-cli2.jsonc" >&2
exit 2
MOCK
  chmod +x "${MOCK_BIN_DIR}/markdownlint-cli2"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=markdownlint-cli2
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Total: 0 errors"* ]]
  [[ "${output}" == *"tool exited non-zero but no diagnostics were parsed"* ]]
}

# ── Typecheck (blocking) ───────────────────────────────────────────────────────
# Unlike Format, a failing typecheck joins overall_status: it must gate the
# exit code the same way Lint and Markdown do.

@test "typecheck-only config, failing typecheck: check_lint exits 2 and reports Typecheck" {
  install_mock_typecheck_with_errors mypy
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=mock-typecheck
    export CGW_TYPECHECK_CHECK_ARGS=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  # Exit 2 (not the generic 1) specifically marks a typecheck failure --
  # push_validated.sh uses this to refuse the interactive override.
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"Typecheck"* ]]
  [[ "${output}" == *"FAILED"* ]]
}

@test "typecheck-only config, passing typecheck: check_lint exits 0 and reports PASSED" {
  install_mock_typecheck
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=mock-typecheck
    export CGW_TYPECHECK_CHECK_ARGS=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Typecheck"* ]]
  [[ "${output}" == *"PASSED"* ]]
}

@test "--skip-typecheck bypasses a failing typechecker entirely" {
  MOCK_TYPECHECK_EXIT=1 install_mock_typecheck
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=mock-typecheck
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --skip-typecheck
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"typecheck skipped -- --skip-typecheck"* ]]
  [ ! -f "${MOCK_BIN_DIR}/typecheck.log" ]
}

@test "CGW_SKIP_TYPECHECK=1 bypasses a failing typechecker entirely" {
  MOCK_TYPECHECK_EXIT=1 install_mock_typecheck
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=mock-typecheck
    export CGW_SKIP_TYPECHECK=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [ "${status}" -eq 0 ]
  [ ! -f "${MOCK_BIN_DIR}/typecheck.log" ]
}

@test "--skip-lint implies --skip-typecheck" {
  MOCK_TYPECHECK_EXIT=1 install_mock_typecheck
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_TYPECHECK_CMD=mock-typecheck
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --skip-lint
  "
  [ "${status}" -eq 0 ]
  [ ! -f "${MOCK_BIN_DIR}/typecheck.log" ]
}

@test "--md-only does not run typecheck" {
  install_mock_markdownlint
  MOCK_TYPECHECK_EXIT=1 install_mock_typecheck
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=markdownlint-cli2
    export CGW_TYPECHECK_CMD=mock-typecheck
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --md-only
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"Typecheck"* ]]
  [ ! -f "${MOCK_BIN_DIR}/typecheck.log" ]
}

@test "--modified-only does not run typecheck" {
  install_mock_lint
  MOCK_TYPECHECK_EXIT=1 install_mock_typecheck
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
    export CGW_TYPECHECK_CMD=mock-typecheck
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --modified-only
  "
  [ "${status}" -eq 0 ]
  [ ! -f "${MOCK_BIN_DIR}/typecheck.log" ]
}

@test "empty CGW_TYPECHECK_CMD produces no Typecheck row and does not fail" {
  install_mock_lint
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"Typecheck"* ]]
}

@test "typecheck-only project is not silently skipped by the all-empty early exit" {
  MOCK_TYPECHECK_EXIT=1 install_mock_typecheck
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=mock-typecheck
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [ "${status}" -eq 2 ]
  [[ "${output}" != *"All lint checks skipped"* ]]
}

@test "configured-but-missing typechecker is skipped with a warning, not a failure" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=definitely-not-installed-typechecker
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"configured but not found on PATH or in .venv"* ]]
}

@test "typecheck diagnostics in mypy shape are counted in the error summary" {
  install_mock_typecheck_with_errors mypy
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=mock-typecheck
    export CGW_TYPECHECK_CHECK_ARGS=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [[ "${output}" == *"Total: 1 errors"* ]]
  [[ "${output}" != *"no diagnostics were parsed"* ]]
}

@test "typecheck diagnostics in pyright shape are counted in the error summary" {
  install_mock_typecheck_with_errors pyright
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=mock-typecheck
    export CGW_TYPECHECK_CHECK_ARGS=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [[ "${output}" == *"Total: 1 errors"* ]]
  [[ "${output}" != *"no diagnostics were parsed"* ]]
}

@test "typecheck diagnostics in tsc shape are counted in the error summary" {
  install_mock_typecheck_with_errors tsc
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=mock-typecheck
    export CGW_TYPECHECK_CHECK_ARGS=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [[ "${output}" == *"Total: 1 errors"* ]]
  [[ "${output}" != *"no diagnostics were parsed"* ]]
}

@test "typecheck diagnostics in pyrefly shape are counted in the error summary" {
  install_mock_typecheck_with_errors pyrefly
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=mock-typecheck
    export CGW_TYPECHECK_CHECK_ARGS=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [[ "${output}" == *"Total: 1 errors"* ]]
  [[ "${output}" != *"no diagnostics were parsed"* ]]
}

@test "format-check failure alone does not block even when typecheck passes" {
  _install_mock_ruff_format_fails
  install_mock_typecheck
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=mock-typecheck
    export CGW_TYPECHECK_CHECK_ARGS=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh'
  "
  [ "${status}" -eq 0 ]
}

# ── Regression: --modified-only resolves CGW_FORMAT_CMD through the venv ─────
# The lint binary in the --modified-only branch was venv-resolved via
# cgw_resolve_lint_binary, but the format binary was invoked bare -- a
# formatter installed only in .venv was "command not found" in this mode while
# full mode (cgw_run_format_*) found it.

@test "--modified-only runs a .venv-only CGW_FORMAT_CMD (check_lint.sh)" {
  install_mock_lint
  mkdir -p "${TEST_REPO_DIR}/.venv/bin"
  cat > "${TEST_REPO_DIR}/.venv/bin/venvfmt" << VENV_EOF
#!/usr/bin/env bash
touch "${TEST_REPO_DIR}/venv_fmt_called"
exit 0
VENV_EOF
  chmod +x "${TEST_REPO_DIR}/.venv/bin/venvfmt"
  echo "x = 1" > "${TEST_REPO_DIR}/mod.py"
  git -C "${TEST_REPO_DIR}" add mod.py
  git -C "${TEST_REPO_DIR}" -c core.hooksPath=/dev/null commit --quiet -m "chore: add mod.py"
  echo "x = 2" > "${TEST_REPO_DIR}/mod.py"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=venvfmt
    export CGW_MARKDOWNLINT_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --modified-only
  "
  [ -f "${TEST_REPO_DIR}/venv_fmt_called" ]
}

@test "--modified-only runs the format check when only a formatter is configured" {
  # Format-only configs used to exit early ("No code lint tool configured")
  # without checking anything; full mode and commit_enhanced.sh already ran
  # the formatter with no linter configured.
  _install_mock_ruff_format_fails
  echo "x = 1" > "${TEST_REPO_DIR}/mod.py"
  git -C "${TEST_REPO_DIR}" add mod.py
  git -C "${TEST_REPO_DIR}" -c core.hooksPath=/dev/null commit --quiet -m "chore: add mod.py"
  echo "x = 2" > "${TEST_REPO_DIR}/mod.py"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=ruff
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --modified-only
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"non-blocking"* ]]
  grep -q "mock ruff format" "${MOCK_BIN_DIR}/ruff.log"
}

# ── --ref / --base: committed-snapshot mode (pushed-only gate) ────────────────
# --ref <rev> checks the COMMITTED tree of <rev> in a throwaway directory, so
# uncommitted work can never fail the check. Typecheck stays whole-snapshot;
# lint/format/markdown narrow to the files changed in <base>...<rev>.

_commit_file() {
  printf '%s\n' "$2" > "${TEST_REPO_DIR}/$1"
  git -C "${TEST_REPO_DIR}" add "$1"
  git -C "${TEST_REPO_DIR}" -c core.hooksPath=/dev/null commit --quiet -m "chore: add $1"
}

# _run_check_lint <args...>: typecheck-only config against the content-aware mock
_run_check_lint_tc() {
  mkdir -p "${TEST_TMPDIR}/snap-tmp"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export TMPDIR='${TEST_TMPDIR}/snap-tmp'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=mock-typecheck
    export CGW_TYPECHECK_CHECK_ARGS=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' $*
  "
}

@test "--ref: uncommitted type error blocks the worktree check but not the snapshot check" {
  install_mock_typecheck_content_aware
  _commit_file ok.py "x = 1"
  echo "y = 1  # TYPE_ERR" > "${TEST_REPO_DIR}/ok.py"

  _run_check_lint_tc
  [ "${status}" -eq 2 ]

  _run_check_lint_tc --ref HEAD
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"PASSED"* ]]
}

@test "--ref: uncommitted untracked file with a type error is not seen" {
  install_mock_typecheck_content_aware
  _commit_file ok.py "x = 1"
  echo "y = 1  # TYPE_ERR" > "${TEST_REPO_DIR}/scratch.py"

  _run_check_lint_tc --ref HEAD
  [ "${status}" -eq 0 ]
}

@test "--ref: committed type error still fails with exit 2" {
  install_mock_typecheck_content_aware
  _commit_file bad.py "y = 1  # TYPE_ERR"

  _run_check_lint_tc --ref HEAD
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"Typecheck"* ]]
  [[ "${output}" == *"FAILED"* ]]
}

@test "--ref: typecheck runs whole-snapshot (no file args) inside a temp dir, not the repo" {
  install_mock_typecheck_content_aware
  _commit_file ok.py "x = 1"

  _run_check_lint_tc --ref HEAD
  [ "${status}" -eq 0 ]
  run grep -c "mock cwd=" "${MOCK_BIN_DIR}/typecheck.log"
  [ "${output}" = "1" ]
  run grep "cwd=${TEST_REPO_DIR} " "${MOCK_BIN_DIR}/typecheck.log"
  [ "${status}" -ne 0 ]
  run grep -E "args=$" "${MOCK_BIN_DIR}/typecheck.log"
  [ "${status}" -eq 0 ]
}

@test "--ref: snapshot directory is removed after a passing and a failing run" {
  install_mock_typecheck_content_aware
  _commit_file ok.py "x = 1"
  _run_check_lint_tc --ref HEAD
  [ "${status}" -eq 0 ]
  [ -z "$(ls -A "${TEST_TMPDIR}/snap-tmp")" ]

  _commit_file bad.py "y = 1  # TYPE_ERR"
  _run_check_lint_tc --ref HEAD
  [ "${status}" -eq 2 ]
  [ -z "$(ls -A "${TEST_TMPDIR}/snap-tmp")" ]
}

@test "--ref: leaves the real index and working tree untouched" {
  install_mock_typecheck_content_aware
  _commit_file ok.py "x = 1"
  echo "dirty" >> "${TEST_REPO_DIR}/ok.py"
  echo "staged" > "${TEST_REPO_DIR}/staged.py"
  git -C "${TEST_REPO_DIR}" add staged.py
  # logs/ is the script's own (git-ignored in real installs) output dir
  local before
  before="$(git -C "${TEST_REPO_DIR}" status --porcelain -- . ':!logs')"

  _run_check_lint_tc --ref HEAD
  [ "${status}" -eq 0 ]
  [ "$(git -C "${TEST_REPO_DIR}" status --porcelain -- . ':!logs')" = "${before}" ]
}

@test "--ref --base: lint receives only files changed in base...ref" {
  install_mock_lint
  _commit_file dirty.py "a = 1"
  _commit_file old.py "b = 1"
  _commit_file new.py "c = 1"
  echo "a = 2" > "${TEST_REPO_DIR}/dirty.py"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --ref HEAD --base HEAD~1
  "
  [ "${status}" -eq 0 ]
  grep -q "new.py" "${MOCK_BIN_DIR}/ruff.log"
  ! grep -q "old.py" "${MOCK_BIN_DIR}/ruff.log"
  ! grep -q "dirty.py" "${MOCK_BIN_DIR}/ruff.log"
}

@test "--ref --base: no pushed files matching the extensions skips lint cleanly" {
  install_mock_lint
  _commit_file notes.txt "hello"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --ref HEAD --base HEAD~1
  "
  [ "${status}" -eq 0 ]
  [ ! -f "${MOCK_BIN_DIR}/ruff.log" ]
}

@test "--ref --base: markdown lint receives only pushed .md files" {
  install_mock_markdownlint_content_aware
  _commit_file old.md "# old MDLINT-BAD"
  _commit_file new.md "# new"
  echo "# changed MDLINT-BAD" > "${TEST_REPO_DIR}/old.md"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=markdownlint-cli2
    export CGW_TYPECHECK_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --ref HEAD --base HEAD~1
  "
  [ "${status}" -eq 0 ]
  grep -q "new.md" "${MOCK_BIN_DIR}/mdlint.log"
  ! grep -q "old.md" "${MOCK_BIN_DIR}/mdlint.log"
}

@test "--ref: typechecker resolves from the main repo's .venv while cwd is the snapshot" {
  mkdir -p "${TEST_REPO_DIR}/.venv/Scripts" "${TEST_REPO_DIR}/.venv/bin"
  local d
  for d in Scripts bin; do
    printf '#!/usr/bin/env bash\necho "venv tc cwd=$PWD" >> "%s/venv_tc.log"\nexit 0\n' "${TEST_TMPDIR}" \
      > "${TEST_REPO_DIR}/.venv/${d}/venv-typecheck"
    chmod +x "${TEST_REPO_DIR}/.venv/${d}/venv-typecheck"
    cp "${TEST_REPO_DIR}/.venv/${d}/venv-typecheck" "${TEST_REPO_DIR}/.venv/${d}/venv-typecheck.exe"
  done
  _commit_file ok.py "x = 1"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=venv-typecheck
    export CGW_TYPECHECK_CHECK_ARGS=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --ref HEAD
  "
  [ "${status}" -eq 0 ]
  [ -f "${TEST_TMPDIR}/venv_tc.log" ]
  ! grep -q "cwd=${TEST_REPO_DIR}\$" "${TEST_TMPDIR}/venv_tc.log"
}

@test "--ref and --modified-only together is an error" {
  _commit_file ok.py "x = 1"
  _run_check_lint_tc --ref HEAD --modified-only
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"--ref"* ]]
}

@test "--ref and --md-only together is an error" {
  _commit_file ok.py "x = 1"
  _run_check_lint_tc --ref HEAD --md-only
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"--ref"* ]]
}

@test "--base without --ref is an error" {
  _run_check_lint_tc --base HEAD~1
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"require --ref"* ]]
}

@test "--ref with an unresolvable revision exits 3 (setup failure) with a clear message" {
  _run_check_lint_tc --ref no-such-branch
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"no-such-branch"* ]]
}

@test "--ref without a value is an error" {
  _run_check_lint_tc --ref
  [ "${status}" -eq 1 ]
}

@test "--ref --unpushed: lint receives files from commits no remote has" {
  install_mock_lint
  _commit_file pushed.py "a = 1"
  git -C "${TEST_REPO_DIR}" update-ref refs/remotes/origin/development HEAD
  _commit_file unpushed.py "b = 1"
  echo "a = 2" > "${TEST_REPO_DIR}/pushed.py"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --ref HEAD --unpushed
  "
  [ "${status}" -eq 0 ]
  grep -q "unpushed.py" "${MOCK_BIN_DIR}/ruff.log"
  ! grep -qE '(^|[ /])pushed\.py' "${MOCK_BIN_DIR}/ruff.log"
}

@test "--ref --base: preserves CGW_LINT_EXCLUDES in snapshot mode" {
  install_mock_lint
  _commit_file base.py "a = 1"
  git -C "${TEST_REPO_DIR}" tag base-tag
  _commit_file changed.py "b = 1"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=''
    export CGW_LINT_EXCLUDES='--extend-exclude gen'
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --ref HEAD --base base-tag
  "
  [ "${status}" -eq 0 ]
  grep -q "changed.py" "${MOCK_BIN_DIR}/ruff.log"
  grep -q "\-\-extend-exclude gen" "${MOCK_BIN_DIR}/ruff.log"
}

@test "--ref --unpushed: fails closed when file resolution fails" {
  install_mock_lint
  _commit_file base.py "a = 1"
  local real_git bin_dir
  real_git="$(which git)"
  bin_dir="$(mktemp -d)"
  cat <<EOF > "${bin_dir}/git"
#!/usr/bin/env bash
if [[ "\$*" == *"log "* ]]; then
  echo "mock git log failure" >&2
  exit 1
fi
exec "${real_git}" "\$@"
EOF
  chmod +x "${bin_dir}/git"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export PATH=\"${bin_dir}:\${PATH}\"
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --ref HEAD --unpushed
  "
  rm -rf "${bin_dir}"
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"Failed to resolve pushed code files"* ]]
}

@test "--ref --base: non-ASCII pushed file names reach lint unquoted" {
  install_mock_lint
  _commit_file "données.py" "a = 1"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --ref HEAD --base HEAD~1
  "
  [ "${status}" -eq 0 ]
  grep -q "données.py" "${MOCK_BIN_DIR}/ruff.log"
  ! grep -q '\303' "${MOCK_BIN_DIR}/ruff.log"
}

@test "--ref --unpushed: non-ASCII pushed file names are linted, not dropped" {
  install_mock_lint
  _commit_file "données.py" "a = 1"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --ref HEAD --unpushed
  "
  [ "${status}" -eq 0 ]
  grep -q "données.py" "${MOCK_BIN_DIR}/ruff.log"
}

@test "--ref --base: markdown scope follows CGW_MARKDOWNLINT_PATHS (root files excluded when not listed)" {
  install_mock_markdownlint_content_aware
  mkdir -p "${TEST_REPO_DIR}/docs"
  _commit_file CHANGELOG.md "# changelog MDLINT-BAD"
  _commit_file docs/guide.md "# guide"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=markdownlint-cli2
    export CGW_MARKDOWNLINT_PATHS='docs/**/*.md'
    export CGW_TYPECHECK_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --ref HEAD --base HEAD~2
  "
  [ "${status}" -eq 0 ]
  grep -q "guide.md" "${MOCK_BIN_DIR}/mdlint.log"
  ! grep -q "CHANGELOG.md" "${MOCK_BIN_DIR}/mdlint.log"
}

@test "--ref --base: default markdown scope still includes root-level .md files" {
  install_mock_markdownlint_content_aware
  _commit_file README.md "# readme"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=markdownlint-cli2
    unset CGW_MARKDOWNLINT_PATHS
    export CGW_TYPECHECK_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_lint.sh' --ref HEAD --base HEAD~1
  "
  [ "${status}" -eq 0 ]
  grep -q "README.md" "${MOCK_BIN_DIR}/mdlint.log"
}
