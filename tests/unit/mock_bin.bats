#!/usr/bin/env bats
# tests/unit/mock_bin.bats - setup_mock_bin lets a shim written mid-test win
# Runs: bats tests/unit/mock_bin.bats

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

# Linux-only failure mode: bash remembers the real git's path after the first
# call, so the shim below is skipped unless setup_mock_bin turned hashing off.
@test "a shim installed after the real command ran is the one that runs" {
  git --version >/dev/null
  printf '#!/usr/bin/env bash\necho mock-git\n' >"${MOCK_BIN_DIR}/git"
  chmod +x "${MOCK_BIN_DIR}/git"
  run git --version
  [ "${status}" -eq 0 ]
  [ "${output}" = "mock-git" ]
}
