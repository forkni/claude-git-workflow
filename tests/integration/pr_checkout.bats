#!/usr/bin/env bats
# tests/integration/pr_checkout.bats - Integration tests for pr_checkout.sh
# Runs: bats tests/integration/pr_checkout.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo_with_remote
  setup_mock_bin
  git -C "${TEST_REPO_DIR}" checkout development
}

teardown() {
  cleanup_test_repo
}

# install_mock_gh's "pr create" branch is irrelevant here; we only need
# `gh auth status` to succeed and `gh pr checkout ...` to be logged/succeed.
# Reuse install_mock_gh (its catch-all `exit 0` covers "pr checkout" too).

_run_pr_checkout() {
  (
    cd "${TEST_REPO_DIR}" || exit 1
    export SCRIPT_DIR="${CGW_PROJECT_ROOT}/scripts/git"
    export PROJECT_ROOT="${TEST_REPO_DIR}"
    export CGW_NON_INTERACTIVE=1
    bash "${CGW_PROJECT_ROOT}/scripts/git/pr_checkout.sh" "$@"
  ) 2>&1
}

# ── No gh in PATH ─────────────────────────────────────────────────────────────

@test "no gh CLI in PATH exits 1" {
  hide_gh
  run _run_pr_checkout 42
  [ "${status}" -eq 1 ]
}

# ── gh CLI not authenticated ──────────────────────────────────────────────────

@test "gh not authenticated exits 1" {
  install_mock_gh_no_auth
  run _run_pr_checkout 42
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"auth"* ]] || [[ "${output}" == *"login"* ]]
}

# ── Missing / invalid PR number ───────────────────────────────────────────────

@test "no PR number given exits 1" {
  install_mock_gh
  run _run_pr_checkout
  [ "${status}" -eq 1 ]
}

@test "non-numeric PR number exits 1" {
  install_mock_gh
  run _run_pr_checkout abc
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Invalid"* ]]
}

# ── --dry-run ─────────────────────────────────────────────────────────────────

@test "--dry-run exits 0 and shows preview without calling gh pr checkout" {
  install_mock_gh
  run _run_pr_checkout 42 --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DRY"* ]] || [[ "${output}" == *"dry"* ]]
  if [ -f "${MOCK_BIN_DIR}/gh.log" ]; then
    ! grep -q "pr checkout" "${MOCK_BIN_DIR}/gh.log"
  fi
}

@test "--dry-run prints the resolved gh pr checkout command including --branch" {
  install_mock_gh
  run _run_pr_checkout --pr 42 --branch review/pr-42 --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"42"* ]]
  [[ "${output}" == *"review/pr-42"* ]]
}

# ── Positional vs --pr ────────────────────────────────────────────────────────

@test "positional PR number is accepted" {
  install_mock_gh
  run _run_pr_checkout 42 --dry-run
  [ "${status}" -eq 0 ]
}

@test "--pr flag is accepted" {
  install_mock_gh
  run _run_pr_checkout --pr 42 --dry-run
  [ "${status}" -eq 0 ]
}

# ── Dirty working tree guard ──────────────────────────────────────────────────

@test "dirty working tree exits 1 without --force" {
  install_mock_gh
  # Modify a *tracked* file -- the guard (git diff-index --quiet HEAD --)
  # only detects tracked changes, matching git's own branch-switch semantics
  # (an untracked file alone would not block a real `git checkout`/gh checkout).
  echo "modified" >>"${TEST_REPO_DIR}/DEV.md"
  run _run_pr_checkout 42
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"uncommitted"* ]]
}

@test "dirty working tree with --force proceeds to checkout" {
  install_mock_gh
  echo "modified" >>"${TEST_REPO_DIR}/DEV.md"
  run _run_pr_checkout 42 --force
  [ "${status}" -eq 0 ]
  if [ -f "${MOCK_BIN_DIR}/gh.log" ]; then
    grep -q "pr checkout" "${MOCK_BIN_DIR}/gh.log"
  fi
}

# ── Successful checkout ────────────────────────────────────────────────────────

@test "successful checkout exits 0" {
  install_mock_gh
  run _run_pr_checkout 42
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Checked out PR #42"* ]]
}

@test "checkout passes --detach through to gh" {
  install_mock_gh
  _run_pr_checkout 42 --detach || true
  if [ -f "${MOCK_BIN_DIR}/gh.log" ]; then
    grep -q -- "--detach" "${MOCK_BIN_DIR}/gh.log"
  fi
}

# ── --help / unknown flag ─────────────────────────────────────────────────────

@test "--help exits 0 and prints Usage:" {
  run _run_pr_checkout --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "unknown flag exits 1" {
  install_mock_gh
  run _run_pr_checkout --bogus-flag
  [ "${status}" -eq 1 ]
}
