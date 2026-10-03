#!/usr/bin/env bats
# tests/integration/stash_pop_lock.bats - `stash_work.sh pop` must only advise `git stash drop`
# when git actually ran and left conflicts. If an index.lock stopped the pop, the stash was
# never applied, and dropping it would destroy the only copy of the work.
# Runs: bats tests/integration/stash_pop_lock.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo_with_remote
  setup_mock_bin
  echo "work in progress" >"${TEST_REPO_DIR}/wip.txt"
  git -C "${TEST_REPO_DIR}" add wip.txt
  git -C "${TEST_REPO_DIR}" stash push --quiet -m "wip"
}

teardown() {
  cleanup_test_repo
}

# _install_colliding_git <sub> <action>: fail `git <sub> <action>` with the index.lock collision message,
# pass everything else through to the real git.
_install_colliding_git() {
  local sub="$1" action="$2" real
  real="$(command -v git)"
  cat >"${MOCK_BIN_DIR}/git" <<SHIM
#!/usr/bin/env bash
if [[ "\$1" == "${sub}" && "\$2" == "${action}" ]]; then
  echo "fatal: Unable to create '${TEST_REPO_DIR}/.git/index.lock': File exists." >&2
  exit 128
fi
exec "${real}" "\$@"
SHIM
  chmod +x "${MOCK_BIN_DIR}/git"
}

_run_stash() {
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git' PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_NON_INTERACTIVE=1 CGW_LOCK_RETRY_ATTEMPTS=1 CGW_LOCK_RETRY_DELAY=0
    bash '${CGW_PROJECT_ROOT}/scripts/git/stash_work.sh' $*
  " 2>&1
}

@test "stash pop: a lock that stopped the pop is not reported as conflicts and never advises drop" {
  _install_colliding_git stash pop
  run _run_stash pop
  [ "${status}" -ne 0 ]
  [[ "${output}" != *"git stash drop"* ]]
  [[ "${output}" != *"conflicts"* ]]
  [[ "${output}" == *"not applied"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" stash list | wc -l)" -eq 1 ]
}

@test "stash pop: a real conflict still advises resolving then dropping" {
  echo "different" >"${TEST_REPO_DIR}/wip.txt"
  git -C "${TEST_REPO_DIR}" add wip.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "conflicting wip.txt"
  run _run_stash pop
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"git stash drop"* ]]
}
