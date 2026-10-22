#!/usr/bin/env bats
# tests/integration/repo_health.bats - Integration tests for repo_health.sh
# Runs: bats tests/integration/repo_health.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo
  setup_mock_bin
  git -C "${TEST_REPO_DIR}" checkout --quiet development
}

teardown() {
  cleanup_test_repo
}

@test "a clean repo reports healthy and exits 0" {
  run run_script repo_health.sh
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[OK] No integrity issues found"* ]]
  [[ "${output}" == *"[OK] Repository is healthy"* ]]
}

@test "runs all seven checks" {
  run run_script repo_health.sh
  [ "${status}" -eq 0 ]
  local i
  for i in 1 2 3 4 5 6 7; do
    [[ "${output}" == *"--- [${i}/7]"* ]]
  done
}

@test "--gc runs garbage collection and still exits 0" {
  run run_script repo_health.sh --gc
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--- Garbage Collection ---"* ]]
  [[ "${output}" == *"Running git gc --auto..."* ]]
}

@test "garbage collection only runs with --gc" {
  run run_script repo_health.sh
  [[ "${output}" != *"Garbage Collection"* ]]
}

@test "--full runs fsck --full and exits 0" {
  run run_script repo_health.sh --full
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[OK] No integrity issues found"* ]]
}

@test "a blob over the --large threshold is reported and exits 1" {
  head -c 2097152 /dev/zero >"${TEST_REPO_DIR}/big.bin"
  git -C "${TEST_REPO_DIR}" add big.bin
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: add big blob"

  run run_script repo_health.sh --large 1
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"1 large file(s) found in git history"* ]]
  [[ "${output}" == *"[!] Issues found"* ]]
}

@test "the same blob passes under the default 10 MB threshold" {
  head -c 2097152 /dev/zero >"${TEST_REPO_DIR}/big.bin"
  git -C "${TEST_REPO_DIR}" add big.bin
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: add big blob"

  run run_script repo_health.sh
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No files exceed 10MB threshold"* ]]
}

@test "backup tags are counted" {
  git -C "${TEST_REPO_DIR}" tag "pre-merge-20260101_000000-1"
  git -C "${TEST_REPO_DIR}" tag "pre-merge-20260102_000000-2"

  run run_script repo_health.sh
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Backup tags: 2"* ]]
  [[ "${output}" == *"Most recent: pre-merge-20260102_000000-2"* ]]
}

@test "a tracked hook that is not installed is flagged, advisory only" {
  mkdir -p "${TEST_REPO_DIR}/.githooks"
  echo '#!/bin/sh' >"${TEST_REPO_DIR}/.githooks/pre-commit"
  rm -f "${TEST_REPO_DIR}/.git/hooks/pre-commit"

  run run_script repo_health.sh
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"pre-commit: tracked in .githooks/ but not installed"* ]]
}
