#!/usr/bin/env bats
# tests/unit/common.bats - Unit tests for _common.sh utility functions
# Runs: bats tests/unit/common.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'

# ── Test setup/teardown ────────────────────────────────────────────────────────

setup() {
  create_test_repo
  # Source _common.sh inside the test repo so PROJECT_ROOT resolves to it
  cd "${TEST_REPO_DIR}"
  export SCRIPT_DIR="${CGW_PROJECT_ROOT}/scripts/git"
  # shellcheck source=scripts/git/_common.sh
  source "${CGW_PROJECT_ROOT}/scripts/git/_common.sh"
}

teardown() {
  cleanup_test_repo
}

# ── err() ──────────────────────────────────────────────────────────────────────

@test "err() writes [ERROR] prefix to stderr" {
  run bash -c "
    SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    err 'something went wrong'
  "
  [ "${status}" -eq 0 ]
  # Nothing on stdout
  [ -z "${output}" ]
}

@test "err() message appears on stderr" {
  result=$(bash -c "
    SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    err 'test error message'
  " 2>&1)
  [[ "${result}" == *"[ERROR] test error message"* ]]
}

@test "err() supports multiple arguments" {
  result=$(bash -c "
    SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    err 'part1' 'part2' 'part3'
  " 2>&1)
  [[ "${result}" == *"[ERROR]"* ]]
  [[ "${result}" == *"part1"* ]]
}

# ── get_timestamp() ────────────────────────────────────────────────────────────

@test "get_timestamp() sets \$timestamp variable" {
  get_timestamp
  [ -n "${timestamp}" ]
}

@test "get_timestamp() format matches YYYYMMDD_HHMMSS" {
  get_timestamp
  [[ "${timestamp}" =~ ^[0-9]{8}_[0-9]{6}$ ]]
}

# ── init_logging() ────────────────────────────────────────────────────────────

@test "init_logging() creates logs/ directory" {
  cd "${TEST_REPO_DIR}"
  init_logging "test_script"
  [ -d "logs" ]
}

@test "init_logging() sets \$logfile path" {
  cd "${TEST_REPO_DIR}"
  init_logging "test_script"
  [ -n "${logfile}" ]
  [[ "${logfile}" == logs/test_script_*.log ]]
}

@test "init_logging() sets \$reportfile path" {
  cd "${TEST_REPO_DIR}"
  init_logging "test_script"
  [ -n "${reportfile}" ]
  [[ "${reportfile}" == logs/test_script_analysis_*.log ]]
}

@test "init_logging() logfile path includes timestamp" {
  cd "${TEST_REPO_DIR}"
  init_logging "myscript"
  [[ "${logfile}" =~ myscript_[0-9]{8}_[0-9]{6}\.log$ ]]
}

# ── get_lint_exclusions() ─────────────────────────────────────────────────────

@test "get_lint_exclusions() copies CGW_LINT_EXCLUDES to RUFF_CHECK_EXCLUDE" {
  CGW_LINT_EXCLUDES="--extend-exclude logs"
  get_lint_exclusions
  [ "${RUFF_CHECK_EXCLUDE}" = "--extend-exclude logs" ]
}

@test "get_lint_exclusions() copies CGW_FORMAT_EXCLUDES to RUFF_FORMAT_EXCLUDE" {
  CGW_FORMAT_EXCLUDES="--exclude .venv"
  get_lint_exclusions
  [ "${RUFF_FORMAT_EXCLUDE}" = "--exclude .venv" ]
}

# ── get_python_path() ─────────────────────────────────────────────────────────

@test "get_python_path() with CGW_NO_VENV=1 sets PYTHON_BIN empty" {
  CGW_NO_VENV=1 get_python_path
  [ "${PYTHON_BIN}" = "" ]
}

@test "get_python_path() with CGW_NO_VENV=1 sets PYTHON_EXT empty" {
  CGW_NO_VENV=1 get_python_path
  [ "${PYTHON_EXT}" = "" ]
}

@test "get_python_path() with SKIP_VENV=1 returns 0" {
  run bash -c "
    SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    SKIP_VENV=1 get_python_path
  "
  [ "${status}" -eq 0 ]
}

@test "get_python_path() detects .venv/bin on Unix-like layout" {
  cd "${TEST_REPO_DIR}"
  mkdir -p ".venv/bin"
  get_python_path
  [ "${PYTHON_BIN}" = ".venv/bin" ]
  [ "${PYTHON_EXT}" = "" ]
  rm -rf .venv
}

@test "get_python_path() without .venv and no ruff returns error" {
  # Run in a dir that has no .venv and PATH with no ruff
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PATH='/usr/bin:/bin'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    get_python_path
  "
  # Either exits 1 or prints ERROR
  [[ "${status}" -ne 0 ]] || [[ "${output}" == *"ERROR"* ]]
}

# ── log_section_start/end() ───────────────────────────────────────────────────

@test "log_section_start() outputs section header" {
  cd "${TEST_REPO_DIR}"
  init_logging "test"
  run log_section_start "MY-SECTION" "${logfile}"
  [[ "${output}" == *"MY-SECTION"* ]]
}

@test "log_section_start() outputs Started" {
  cd "${TEST_REPO_DIR}"
  init_logging "test"
  run log_section_start "MY-SECTION" "${logfile}"
  [[ "${output}" == *"Started"* ]]
}

@test "log_section_end() with exit_code=0 outputs PASSED" {
  cd "${TEST_REPO_DIR}"
  init_logging "test"
  log_section_start "MYSEC" "${logfile}"
  run log_section_end "MYSEC" "${logfile}" "0"
  [[ "${output}" == *"PASSED"* ]]
}

@test "log_section_end() with exit_code=1 outputs FAILED" {
  cd "${TEST_REPO_DIR}"
  init_logging "test"
  log_section_start "MYSEC" "${logfile}"
  run log_section_end "MYSEC" "${logfile}" "1"
  [[ "${output}" == *"FAILED"* ]]
}

# ── run_tool_with_logging() ───────────────────────────────────────────────────

@test "run_tool_with_logging() captures exit code from command" {
  cd "${TEST_REPO_DIR}"
  init_logging "test"
  run run_tool_with_logging "MOCK" "${logfile}" bash -c "exit 0"
  [ "${status}" -eq 0 ]
}

@test "run_tool_with_logging() propagates non-zero exit" {
  cd "${TEST_REPO_DIR}"
  init_logging "test"
  run run_tool_with_logging "MOCK" "${logfile}" bash -c "exit 2"
  [ "${status}" -eq 2 ]
}

@test "run_tool_with_logging() sets TOOL_ERROR_COUNT for diagnostic output" {
  cd "${TEST_REPO_DIR}"
  init_logging "test"
  run_tool_with_logging "MOCK" "${logfile}" bash -c "
    echo 'src/foo.py:10:5: E501 line too long'
    echo 'src/bar.py:22:1: F401 unused import'
    exit 1
  " || true
  [ "${TOOL_ERROR_COUNT}" -eq 2 ]
}

@test "run_tool_with_logging() TOOL_ERROR_COUNT=0 for clean output" {
  cd "${TEST_REPO_DIR}"
  init_logging "test"
  run_tool_with_logging "MOCK" "${logfile}" bash -c "echo 'All good'; exit 0"
  [ "${TOOL_ERROR_COUNT}" -eq 0 ]
}
