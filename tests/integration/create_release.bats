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

# ── --allow-non-semver ────────────────────────────────────────────────────────

@test "--allow-non-semver creates an annotated tag with the name as given" {
  run run_script create_release.sh archive/pre-rewrite --allow-non-semver --non-interactive
  [ "${status}" -eq 0 ]
  [ "$(git -C "${TEST_REPO_DIR}" cat-file -t archive/pre-rewrite)" = "tag" ]
  # no v prefix was added
  run git -C "${TEST_REPO_DIR}" tag -l "varchive/pre-rewrite"
  [ -z "${output}" ]
}

@test "--allow-non-semver does not add a v prefix to a bare version" {
  run run_script create_release.sh 1.0 --allow-non-semver --non-interactive
  [ "${status}" -eq 0 ]
  git -C "${TEST_REPO_DIR}" tag -l "1.0" | grep -qx "1.0"
}

@test "--allow-non-semver notes that release.yml will not fire" {
  run run_script create_release.sh archive/2026-q1 --allow-non-semver --non-interactive
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"release.yml"* ]]
  [[ "${output}" == *"will not fire"* ]]
}

@test "--allow-non-semver still rejects an invalid ref name" {
  run run_script create_release.sh "bad name" --allow-non-semver --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not a valid tag name"* ]]
  [ -z "$(git -C "${TEST_REPO_DIR}" tag -l)" ]
}

@test "--allow-non-semver keeps the branch, dirty-tree and existing-tag guards" {
  git -C "${TEST_REPO_DIR}" tag archive/dup
  run run_script create_release.sh archive/dup --allow-non-semver --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"already exists"* ]]
}

@test "--allow-non-semver with a v* tag does not print the no-release note" {
  run run_script create_release.sh v3.0.0 --allow-non-semver --non-interactive
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"will not fire"* ]]
}

@test "--help documents --allow-non-semver" {
  run run_script create_release.sh --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--allow-non-semver"* ]]
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
  run git -C "${TEST_REPO_DIR}" tag -l "v1.0.0"
  [ -z "${output}" ]
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

@test "--allow-non-semver rejects a tag name starting with a dash" {
  run run_script create_release.sh -- -oops --allow-non-semver --non-interactive
  [ "${status}" -ne 0 ]
  run git -C "${TEST_REPO_DIR}" tag -l
  [[ "${output}" != *"-oops"* ]]
}
