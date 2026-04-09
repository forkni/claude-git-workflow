#!/usr/bin/env bats
# tests/integration/rollback_merge.bats - Integration tests for rollback_merge.sh
# Runs: bats tests/integration/rollback_merge.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo
  setup_mock_bin
  install_mock_lint
  git -C "${TEST_REPO_DIR}" checkout --quiet main
}

teardown() {
  cleanup_test_repo
}

# ── branch guard ──────────────────────────────────────────────────────────────

@test "running from non-target branch exits 1" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  run run_script rollback_merge.sh --non-interactive --target HEAD~1
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"target branch"* ]] || [[ "${output}" == *"Not on"* ]]
}

# ── uncommitted changes guard ─────────────────────────────────────────────────

@test "uncommitted changes in non-interactive mode exits 1" {
  echo "dirty" > "${TEST_REPO_DIR}/dirty.txt"
  git -C "${TEST_REPO_DIR}" add dirty.txt
  run run_script rollback_merge.sh --non-interactive --target HEAD~1
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Aborting"* ]] || [[ "${output}" == *"uncommitted"* ]] || [[ "${output}" == *"Uncommitted"* ]]
}

# ── --dry-run ─────────────────────────────────────────────────────────────────

@test "--dry-run shows rollback target without resetting" {
  # Need at least two commits for HEAD~1 to be valid
  echo "extra" > "${TEST_REPO_DIR}/extra.txt"
  git -C "${TEST_REPO_DIR}" add extra.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: second commit"

  local head_before
  head_before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  run run_script rollback_merge.sh --non-interactive --dry-run --target HEAD~1
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ry run"* ]] || [[ "${output}" == *"DRY"* ]] || [[ "${output}" == *"Dry"* ]]

  local head_after
  head_after=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)
  [ "${head_before}" = "${head_after}" ]
}

# ── --target with explicit ref ─────────────────────────────────────────────────

@test "--non-interactive with no backup tag falls back to HEAD~1" {
  # Create a second commit so HEAD~1 exists
  echo "extra" > "${TEST_REPO_DIR}/extra.txt"
  git -C "${TEST_REPO_DIR}" add extra.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: second commit"

  run run_script rollback_merge.sh --non-interactive --target HEAD~1
  [ "${status}" -eq 0 ]
}

# ── --target with explicit backup tag ─────────────────────────────────────────

@test "--target with explicit backup tag rolls back to that tag" {
  # Create a backup tag at HEAD, then add one commit
  local before_sha
  before_sha=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)
  git -C "${TEST_REPO_DIR}" tag "pre-merge-backup-20250101_000000" HEAD
  echo "after" > "${TEST_REPO_DIR}/after.txt"
  git -C "${TEST_REPO_DIR}" add after.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: after tag commit"

  run run_script rollback_merge.sh --non-interactive --target pre-merge-backup-20250101_000000
  [ "${status}" -eq 0 ]

  # HEAD should be back to before_sha
  local current_sha
  current_sha=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)
  [ "${current_sha}" = "${before_sha}" ]
}
