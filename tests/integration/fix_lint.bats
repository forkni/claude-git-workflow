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
    export CGW_MARKDOWNLINT_CMD=''
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
    export CGW_MARKDOWNLINT_CMD=''
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
    export CGW_MARKDOWNLINT_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/fix_lint.sh'
  "
  [[ "${output}" == *"issues"* ]] || [[ "${output}" == *"FAILED"* ]] || \
    [[ "${output}" == *"error"* ]]
}

# ── Markdown auto-fix (regression + scoping) ──────────────────────────────────
# These tests pin CGW_MARKDOWNLINT_CMD to an installed mock rather than relying
# on runtime auto-detection, so they run identically whether or not the host
# machine happens to have a real markdownlint binary on PATH.

@test "regression: markdown fix runs when CGW_MARKDOWNLINT_CMD is set and CGW_LINT_CMD is empty" {
  # Prior to the markdown-fix feature this was a silent no-op: fix_lint.sh bailed
  # at the "all three CMDs empty" gate check without ever invoking markdownlint,
  # exit 0, tree untouched -- even with CGW_MARKDOWNLINT_CMD configured.
  install_mock_markdownlint
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD='markdownlint-cli2'
    export CGW_MARKDOWNLINT_ARGS=''
    export CGW_MARKDOWNLINT_FIX_ARGS='--fix'
    bash '${CGW_PROJECT_ROOT}/scripts/git/fix_lint.sh'
  "
  [ "${status}" -eq 0 ]
  [ -f "${MOCK_BIN_DIR}/mdlint.log" ]
  grep -q "FIX_FLAG_SEEN" "${MOCK_BIN_DIR}/mdlint.log"
}

@test "--skip-md-lint: code lint fix runs, markdown fix does not" {
  # fix_lint.sh always re-verifies with check_lint.sh at the end (a separate,
  # unflagged invocation), so mdlint.log still gets a CHECK entry -- the
  # distinguishing signal is that no FIX (--fix) invocation was ever logged.
  install_mock_lint
  install_mock_markdownlint
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD='markdownlint-cli2'
    bash '${CGW_PROJECT_ROOT}/scripts/git/fix_lint.sh' --skip-md-lint
  "
  [ "${status}" -eq 0 ]
  [ -f "${MOCK_BIN_DIR}/ruff.log" ]
  grep -q -- "--fix" "${MOCK_BIN_DIR}/ruff.log"
  if [ -f "${MOCK_BIN_DIR}/mdlint.log" ]; then
    ! grep -q "FIX_FLAG_SEEN" "${MOCK_BIN_DIR}/mdlint.log"
  fi
}

@test "--md-only: markdown fix runs, code lint fix does not" {
  # Same caveat as above: check_lint.sh's final verification always re-checks
  # code lint too, so ruff.log exists either way -- assert it was never
  # invoked with the FIX args (--fix), only the CHECK args.
  install_mock_lint
  install_mock_markdownlint
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD='markdownlint-cli2'
    export CGW_MARKDOWNLINT_ARGS=''
    export CGW_MARKDOWNLINT_FIX_ARGS='--fix'
    bash '${CGW_PROJECT_ROOT}/scripts/git/fix_lint.sh' --md-only
  "
  [ "${status}" -eq 0 ]
  if [ -f "${MOCK_BIN_DIR}/ruff.log" ]; then
    ! grep -q -- "--fix" "${MOCK_BIN_DIR}/ruff.log"
  fi
  [ -f "${MOCK_BIN_DIR}/mdlint.log" ]
  grep -q "FIX_FLAG_SEEN" "${MOCK_BIN_DIR}/mdlint.log"
}

@test "--skip-md-lint and --md-only together is an error" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    bash '${CGW_PROJECT_ROOT}/scripts/git/fix_lint.sh' --skip-md-lint --md-only
  "
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"mutually exclusive"* ]]
}

@test "--modified-only: markdown fix rewrites only the modified .md file on disk" {
  install_mock_markdownlint_fixable
  printf '%s\n' "MDLINT-BAD" >> "${TEST_REPO_DIR}/README.md"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD='markdownlint-cli2'
    export CGW_MARKDOWNLINT_ARGS=''
    export CGW_MARKDOWNLINT_FIX_ARGS='--fix'
    bash '${CGW_PROJECT_ROOT}/scripts/git/fix_lint.sh' --modified-only
  "
  [ "${status}" -eq 0 ]
  run grep -x "MDLINT-BAD" "${TEST_REPO_DIR}/README.md"
  [ "${status}" -ne 0 ]
}

# ── Unfixable-remainder listing ───────────────────────────────────────────────
# When auto-fix can't clear everything, the final verification must distill the
# surviving file:line diagnostics into an actionable list instead of ending on
# a bare "manual fixes may be required".

@test "unfixable errors are listed as remaining issues after verification" {
  cat > "${MOCK_BIN_DIR}/markdownlint-cli2" << 'MOCK'
#!/usr/bin/env bash
echo "README.md:3 MD041/first-line-heading First line in a file should be a top-level heading"
exit 1
MOCK
  chmod +x "${MOCK_BIN_DIR}/markdownlint-cli2"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD='markdownlint-cli2'
    export CGW_MARKDOWNLINT_ARGS=''
    export CGW_MARKDOWNLINT_FIX_ARGS='--fix'
    bash '${CGW_PROJECT_ROOT}/scripts/git/fix_lint.sh'
  "
  [[ "${output}" == *"Remaining issues needing manual fixes:"* ]]
  [[ "${output}" == *"README.md:3 MD041"* ]]
}
