# shellcheck shell=bash
# tests/integration/_commit_common.bash - shared harness for the commit_enhanced.sh test files
#
# Loaded with `load '_commit_common'` AFTER `load '../helpers/setup'` and `load '../helpers/mocks'`
# (it calls create_test_repo, setup_mock_bin, install_mock_lint and cleanup_test_repo from them).
# Kept outside tests/helpers/ on purpose: tests/run.sh treats that directory as a trigger for every
# slow file, and no slow file uses this harness.
#
# Provides:
#   _commit_setup  fresh repo on `development` with the mock bin and the mock linter
#   setup/teardown defaults; a file with extra setup defines its own setup() after the load and
#                  calls _commit_setup first
#   _run_commit    run commit_enhanced.sh inside TEST_REPO_DIR; the arguments are joined into one
#                  bash -c string, so a message needs inner quotes: _run_commit "\"feat: x\""

_commit_setup() {
  create_test_repo
  setup_mock_bin
  install_mock_lint
  git -C "${TEST_REPO_DIR}" checkout development
}

setup() {
  _commit_setup
}

teardown() {
  cleanup_test_repo
}

# Run commit_enhanced.sh with the shared env vars.
_run_commit() {
  # PATH is already correct from setup_mock_bin; PROJECT_ROOT pins scripts to TEST_REPO_DIR.
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' $*
  "
}
