#!/usr/bin/env bats
# tests/integration/branch_cleanup.bats - Integration tests for branch_cleanup.sh
# Runs: bats tests/integration/branch_cleanup.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo_with_remote
  setup_mock_bin
  install_mock_lint
}

teardown() {
  cleanup_test_repo
}

# ── default dry-run ───────────────────────────────────────────────────────────

@test "default mode is dry-run and exits 0" {
  run run_script branch_cleanup.sh
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DRY RUN"* ]] || [[ "${output}" == *"dry run"* ]]
}

@test "dry-run does not delete any branches" {
  # Create a merged feature branch
  git -C "${TEST_REPO_DIR}" checkout --quiet main
  git -C "${TEST_REPO_DIR}" checkout --quiet -b feature/merged
  echo "x" > "${TEST_REPO_DIR}/feat.txt"
  git -C "${TEST_REPO_DIR}" add feat.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: feature work"
  git -C "${TEST_REPO_DIR}" checkout --quiet main
  git -C "${TEST_REPO_DIR}" merge --quiet --no-ff feature/merged -m "Merge feature/merged"

  run run_script branch_cleanup.sh
  [ "${status}" -eq 0 ]
  # Branch still exists
  git -C "${TEST_REPO_DIR}" branch | grep -q "feature/merged"
}

# ── --execute mode ────────────────────────────────────────────────────────────

@test "--execute --non-interactive deletes merged branches" {
  # Create and merge a feature branch
  git -C "${TEST_REPO_DIR}" checkout --quiet main
  git -C "${TEST_REPO_DIR}" checkout --quiet -b feature/to-delete
  echo "x" > "${TEST_REPO_DIR}/feat2.txt"
  git -C "${TEST_REPO_DIR}" add feat2.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: to delete"
  git -C "${TEST_REPO_DIR}" checkout --quiet main
  git -C "${TEST_REPO_DIR}" merge --quiet --no-ff feature/to-delete -m "Merge feature/to-delete"

  run run_script branch_cleanup.sh --execute --non-interactive
  [ "${status}" -eq 0 ]
  # Branch is gone
  ! git -C "${TEST_REPO_DIR}" branch | grep -q "feature/to-delete"
}

# ── protected branches ────────────────────────────────────────────────────────

@test "protected branch 'main' is never deleted" {
  run run_script branch_cleanup.sh --execute --non-interactive
  [ "${status}" -eq 0 ]
  git -C "${TEST_REPO_DIR}" branch | grep -q "main"
}

@test "protected branch 'development' is never deleted" {
  run run_script branch_cleanup.sh --execute --non-interactive
  [ "${status}" -eq 0 ]
  git -C "${TEST_REPO_DIR}" branch | grep -q "development"
}

# ── backup tag cleanup ────────────────────────────────────────────────────────

@test "--tags dry-run shows old backup tags without deleting" {
  # Create a fake backup tag
  git -C "${TEST_REPO_DIR}" tag "pre-merge-backup-20200101_000000" HEAD

  run run_script branch_cleanup.sh --tags
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DRY RUN"* ]] || [[ "${output}" == *"dry run"* ]]
  # Tag still exists
  git -C "${TEST_REPO_DIR}" tag | grep -q "pre-merge-backup-20200101_000000"
}

@test "--tags --execute --older-than 0 deletes old backup tags" {
  # Create a fake backup tag (will be treated as very old)
  git -C "${TEST_REPO_DIR}" tag "pre-merge-backup-20200101_000000" HEAD

  run run_script branch_cleanup.sh --tags --execute --older-than 0 --non-interactive
  [ "${status}" -eq 0 ]
  # Tag is deleted
  ! git -C "${TEST_REPO_DIR}" tag | grep -q "pre-merge-backup-20200101_000000"
}
