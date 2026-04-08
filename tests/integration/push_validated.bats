#!/usr/bin/env bats
# tests/integration/push_validated.bats - Integration tests for push_validated.sh
# Runs: bats tests/integration/push_validated.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo_with_remote
  setup_mock_bin
  install_mock_lint
  git -C "${TEST_REPO_DIR}" checkout development
}

teardown() {
  cleanup_test_repo
}

_run_push() {
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PATH='${MOCK_BIN_DIR}:\${PATH}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/push_validated.sh' $*
  "
}

# ── --dry-run ─────────────────────────────────────────────────────────────────

@test "--dry-run exits 0 without pushing" {
  run _run_push "--dry-run --skip-lint"
  [ "${status}" -eq 0 ]
}

@test "--dry-run output mentions dry run" {
  run _run_push "--dry-run --skip-lint"
  [[ "${output}" == *"dry"* ]] || [[ "${output}" == *"DRY"* ]] || [[ "${output}" == *"preview"* ]]
}

@test "--dry-run does not advance remote ref" {
  # Add a commit before dry-run
  echo "new" > "${TEST_REPO_DIR}/new.txt"
  git -C "${TEST_REPO_DIR}" add new.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: new file"
  local before_remote
  before_remote=$(git -C "${TEST_REPO_DIR}" ls-remote origin refs/heads/development | cut -f1)

  _run_push "--dry-run --skip-lint" || true

  local after_remote
  after_remote=$(git -C "${TEST_REPO_DIR}" ls-remote origin refs/heads/development | cut -f1)
  [ "${before_remote}" = "${after_remote}" ]
}

# ── --skip-lint passthrough ───────────────────────────────────────────────────

@test "--skip-lint exits 0 without calling ruff" {
  run _run_push "--skip-lint --dry-run"
  [ "${status}" -eq 0 ]
  # ruff mock log should not exist or be empty
  if [ -f "${MOCK_BIN_DIR}/ruff.log" ]; then
    [ ! -s "${MOCK_BIN_DIR}/ruff.log" ]
  fi
}

# ── --skip-md-lint passthrough ────────────────────────────────────────────────

@test "--skip-md-lint is accepted and exits 0 in dry-run" {
  run _run_push "--skip-lint --skip-md-lint --dry-run"
  [ "${status}" -eq 0 ]
}

# ── Protected branch force-push protection ────────────────────────────────────

@test "force-push to protected main branch aborts in non-interactive" {
  git -C "${TEST_REPO_DIR}" checkout main
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PATH='${MOCK_BIN_DIR}:\${PATH}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    export CGW_PROTECTED_BRANCHES=main
    bash '${CGW_PROJECT_ROOT}/scripts/git/push_validated.sh' --force --skip-lint
  "
  [ "${status}" -ne 0 ]
}
