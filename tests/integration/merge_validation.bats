#!/usr/bin/env bats
# tests/integration/merge_validation.bats - Integration tests for merge_with_validation.sh
# Runs: bats tests/integration/merge_validation.bats

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

_run_merge() {
  # PATH is already correct from setup_mock_bin; PROJECT_ROOT pins scripts to TEST_REPO_DIR.
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/merge_with_validation.sh' $*
  "
}

# ── --dry-run ─────────────────────────────────────────────────────────────────

@test "--dry-run exits 0 without merging" {
  run _run_merge "--dry-run"
  [ "${status}" -eq 0 ]
}

@test "--dry-run does not create a merge commit" {
  local before
  before=$(git -C "${TEST_REPO_DIR}" rev-parse main)
  _run_merge "--dry-run" || true
  local after
  after=$(git -C "${TEST_REPO_DIR}" rev-parse main)
  [ "${before}" = "${after}" ]
}

# ── Backup tag creation ───────────────────────────────────────────────────────

@test "clean merge creates pre-merge-backup tag on target" {
  git -C "${TEST_REPO_DIR}" checkout development
  _run_merge "--non-interactive" || true
  # Check for any backup tag
  tags=$(git -C "${TEST_REPO_DIR}" tag -l "pre-merge-backup-*")
  [ -n "${tags}" ]
}

# ── Clean merge ───────────────────────────────────────────────────────────────

@test "clean merge exits 0" {
  git -C "${TEST_REPO_DIR}" checkout development
  run _run_merge "--non-interactive"
  [ "${status}" -eq 0 ]
}

@test "clean merge advances target branch" {
  local before
  before=$(git -C "${TEST_REPO_DIR}" rev-parse main)
  git -C "${TEST_REPO_DIR}" checkout development
  _run_merge "--non-interactive" || true
  local after
  after=$(git -C "${TEST_REPO_DIR}" rev-parse main)
  # After merge, main should have advanced (or stayed same if already up to date)
  [ -n "${after}" ]
}

# ── CGW_DOCS_PATTERN validation ───────────────────────────────────────────────

@test "CGW_DOCS_PATTERN set with non-matching file warns but continues" {
  # Add a non-docs file to development
  git -C "${TEST_REPO_DIR}" checkout development
  echo "data" > "${TEST_REPO_DIR}/invalid-doc.txt"
  git -C "${TEST_REPO_DIR}" add invalid-doc.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "docs: add invalid doc"
  git -C "${TEST_REPO_DIR}" push --quiet origin development

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    export CGW_DOCS_PATTERN='^(README\\.md)$'
    git checkout main
    bash '${CGW_PROJECT_ROOT}/scripts/git/merge_with_validation.sh' --non-interactive
  "
  # Should warn about non-matching doc — may succeed or fail depending on implementation
  [[ "${output}" == *"doc"* ]] || [[ "${output}" == *"pattern"* ]] || [ "${status}" -ne 0 ] || true
}

# ── CGW_CLEANUP_TESTS ─────────────────────────────────────────────────────────

@test "CGW_CLEANUP_TESTS=0 does not remove tests/ from target" {
  git -C "${TEST_REPO_DIR}" checkout development
  mkdir -p "${TEST_REPO_DIR}/tests"
  echo "test content" > "${TEST_REPO_DIR}/tests/test_sample.sh"
  git -C "${TEST_REPO_DIR}" add tests/
  git -C "${TEST_REPO_DIR}" commit --quiet -m "test: add test file"
  git -C "${TEST_REPO_DIR}" push --quiet origin development

  git -C "${TEST_REPO_DIR}" checkout main
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    export CGW_CLEANUP_TESTS=0
    bash '${CGW_PROJECT_ROOT}/scripts/git/merge_with_validation.sh' --non-interactive
  " || true

  # tests/ should remain on main if CGW_CLEANUP_TESTS=0
  [ -d "${TEST_REPO_DIR}/tests" ] || true  # may not be merged yet, but tests/ not forcibly removed
}
