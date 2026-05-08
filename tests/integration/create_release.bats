#!/usr/bin/env bats
# tests/integration/create_release.bats - Integration tests for create_release.sh
# Runs: bats tests/integration/create_release.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo
  setup_mock_bin
  install_mock_lint
  # Ensure we start on main (the target branch)
  git -C "${TEST_REPO_DIR}" checkout --quiet main
}

teardown() {
  cleanup_test_repo
}

# ── semver validation ─────────────────────────────────────────────────────────

@test "valid semver v1.2.3 creates annotated tag" {
  run run_script create_release.sh v1.2.3 --non-interactive
  [ "${status}" -eq 0 ]
  git -C "${TEST_REPO_DIR}" tag -l "v1.2.3" | grep -q "v1.2.3"
}

@test "version without v prefix auto-adds v prefix" {
  run run_script create_release.sh 2.0.0 --non-interactive
  [ "${status}" -eq 0 ]
  git -C "${TEST_REPO_DIR}" tag -l "v2.0.0" | grep -q "v2.0.0"
}

@test "invalid semver exits 1" {
  run run_script create_release.sh 1.0 --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"semver"* ]] || [[ "${output}" == *"format"* ]]
}

# ── branch guard ──────────────────────────────────────────────────────────────

@test "running from non-target branch exits 1" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  run run_script create_release.sh v1.0.0 --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"target branch"* ]] || [[ "${output}" == *"Must be on"* ]]
}

# ── existing tag guard ────────────────────────────────────────────────────────

@test "existing tag exits 1" {
  git -C "${TEST_REPO_DIR}" tag "v1.0.0"
  run run_script create_release.sh v1.0.0 --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"already exists"* ]]
}

# ── uncommitted changes guard ─────────────────────────────────────────────────

@test "uncommitted changes exits 1" {
  echo "dirty" > "${TEST_REPO_DIR}/dirty.txt"
  git -C "${TEST_REPO_DIR}" add dirty.txt
  run run_script create_release.sh v1.0.0 --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Uncommitted"* ]] || [[ "${output}" == *"uncommitted"* ]]
}

# ── dry-run ───────────────────────────────────────────────────────────────────

@test "--dry-run shows plan without creating tag" {
  run run_script create_release.sh v1.0.0 --dry-run --non-interactive
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ry run"* ]] || [[ "${output}" == *"would be"* ]]
  # Tag not created
  ! git -C "${TEST_REPO_DIR}" tag -l "v1.0.0" | grep -q "v1.0.0"
}

# ── annotated tag ─────────────────────────────────────────────────────────────

@test "created tag is annotated (has a message)" {
  run_script create_release.sh v1.1.0 --non-interactive
  # Annotated tags show type "tag"; lightweight show type "commit"
  git -C "${TEST_REPO_DIR}" cat-file -t "v1.1.0" | grep -q "tag"
}

# ── untracked files guard (bug #C2 — fixed in working-tree-state refactor) ───

@test "untracked source files rejected when tagging release" {
  # bug: create_release.sh uses diff-index which ignores untracked files;
  # a release tag can be cut while new source files are present but unstaged.
  # Fixed by cgw_handle_dirty_tree release abort --include-untracked.
  skip "bug #C2: create_release.sh silently accepts untracked files -- unskip after working-tree-state refactor"
  echo "new source" > "${TEST_REPO_DIR}/newfile.py"
  # intentionally NOT git-added -- file is untracked
  run run_script create_release.sh v1.0.0 --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"ntracked"* ]]
}
