#!/usr/bin/env bats
# tests/integration/staged_checks.bats - CGW_STAGED_CHECKS in commit_enhanced.sh
# Runs: bats tests/integration/staged_checks.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo
  setup_mock_bin
  install_mock_lint
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  mkdir -p "${TEST_REPO_DIR}/src" "${TEST_REPO_DIR}/docs"
  # Real projects gitignore .cgw.conf; without this the untracked-files notice
  # ([WARN]) fires on the config these tests write and trips the no-WARN asserts.
  echo ".cgw.conf" >>"${TEST_REPO_DIR}/.git/info/exclude"
  CHECK_LOG="${BATS_TEST_TMPDIR}/check.log"
  export CHECK_LOG
}

teardown() {
  cleanup_test_repo
}

# Run commit_enhanced.sh with CGW_STAGED_CHECKS taken from the caller's env.
_run_commit() {
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

_stage() {
  echo "$2" > "${TEST_REPO_DIR}/$1"
  git -C "${TEST_REPO_DIR}" add "$1"
}

@test "staged check runs from the project root with the matching paths" {
  _stage src/a.txt one
  _stage docs/b.txt two
  export CGW_STAGED_CHECKS='src/* :: pwd > "${CHECK_LOG}"; printf "%s" "${CGW_CHECK_FILES}" >> "${CHECK_LOG}"'
  run _run_commit "\"feat: add a and b\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[OK] Staged check passed"* ]]
  [ "$(sed -n 2p "${CHECK_LOG}")" = "src/a.txt" ]
  [ "$(wc -l < "${CHECK_LOG}")" -eq 1 ]
}

@test "a failing staged check blocks the commit" {
  _stage src/a.txt one
  local before
  before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)
  export CGW_STAGED_CHECKS='src/* :: exit 3'
  run _run_commit "\"feat: add a\""
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Staged check failed"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "${before}" ]
}

@test "a check whose globs match no staged file does not run" {
  _stage docs/b.txt two
  export CGW_STAGED_CHECKS='src/* :: touch "${CHECK_LOG}"; exit 1'
  run _run_commit "\"docs: add b\""
  [ "${status}" -eq 0 ]
  [ ! -e "${CHECK_LOG}" ]
}

@test "every matching entry runs; comments and blank lines are skipped" {
  _stage src/a.txt one
  export CGW_STAGED_CHECKS='# a comment

src/* :: echo first >> "${CHECK_LOG}"
docs/* src/* :: echo second >> "${CHECK_LOG}"'
  run _run_commit "\"feat: add a\""
  [ "${status}" -eq 0 ]
  [ "$(cat "${CHECK_LOG}")" = "$(printf 'first\nsecond')" ]
}

@test "an entry without the ' :: ' separator fails closed" {
  _stage src/a.txt one
  export CGW_STAGED_CHECKS='src/* exit 0'
  run _run_commit "\"feat: add a\""
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"has no ' :: ' separator"* ]]
}

@test "--skip-lint skips staged checks" {
  _stage src/a.txt one
  export CGW_STAGED_CHECKS='src/* :: exit 1'
  run _run_commit "--skip-lint \"feat: add a\""
  [ "${status}" -eq 0 ]
}

@test "staged checks read CGW_STAGED_CHECKS from .cgw.conf" {
  _stage src/a.txt one
  cat >"${TEST_REPO_DIR}/.cgw.conf" <<'EOF'
CGW_STAGED_CHECKS="src/* :: exit 4"
EOF
  run _run_commit "\"feat: add a\""
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Staged check failed: exit 4"* ]]
}

@test "a multi-line .cgw.conf value runs every entry and loads without warnings" {
  # Regression: the multi-line form loaded as a lone '"', which failed closed on
  # every commit and printed one [WARN] per entry line.
  _stage src/a.txt one
  cat >"${TEST_REPO_DIR}/.cgw.conf" <<'EOF'
CGW_STAGED_CHECKS="
src/* :: echo first >> ${CHECK_LOG}
src/* :: [ ! -f missing.py ] || exit 9; echo second >> ${CHECK_LOG}
"
EOF
  run _run_commit "\"feat: add a\""
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"WARN"* ]]
  [ "$(cat "${CHECK_LOG}")" = "$(printf 'first\nsecond')" ]
}

@test "a failing entry of a multi-line .cgw.conf value blocks the commit" {
  _stage src/a.txt one
  local before
  before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)
  cat >"${TEST_REPO_DIR}/.cgw.conf" <<'EOF'
CGW_STAGED_CHECKS="
src/* :: true
src/* :: exit 5
"
EOF
  run _run_commit "\"feat: add a\""
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Staged check failed: exit 5"* ]]
  [[ "${output}" != *"WARN"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "${before}" ]
}
