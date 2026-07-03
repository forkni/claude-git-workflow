#!/usr/bin/env bats
# tests/integration/branch_diff.bats - Integration tests for branch_diff.sh
# Runs: bats tests/integration/branch_diff.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo_with_remote
  # Start on development, which is 1 commit ahead of main (see setup.bash fixture)
  git -C "${TEST_REPO_DIR}" checkout development
}

teardown() {
  cleanup_test_repo
}

_run_branch_diff() {
  (
    cd "${TEST_REPO_DIR}" || exit 1
    export SCRIPT_DIR="${CGW_PROJECT_ROOT}/scripts/git"
    export PROJECT_ROOT="${TEST_REPO_DIR}"
    export CGW_TARGET_BRANCH=main
    bash "${CGW_PROJECT_ROOT}/scripts/git/branch_diff.sh" "$@"
  ) 2>&1
}

# ── Default mode (full patch) ─────────────────────────────────────────────────

@test "default mode shows the branch-local commit's file content" {
  run _run_branch_diff
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DEV.md"* ]]
}

@test "default mode does not require a clean working tree" {
  echo "dirty" >"${TEST_REPO_DIR}/dirty.txt"
  run _run_branch_diff
  [ "${status}" -eq 0 ]
}

# ── --files ────────────────────────────────────────────────────────────────

@test "--files lists only the changed file name" {
  run _run_branch_diff --files
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DEV.md"* ]]
  [[ "${output}" != *"README.md"* ]]
}

# ── --stat ─────────────────────────────────────────────────────────────────

@test "--stat shows a diffstat summary" {
  run _run_branch_diff --stat
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"1 insertion"* ]] || [[ "${output}" == *"changed"* ]]
}

# ── --no-ws / -w ───────────────────────────────────────────────────────────

@test "--no-ws is accepted and still shows the changed file" {
  run _run_branch_diff --files --no-ws
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DEV.md"* ]]
}

@test "-w is accepted as an alias for --no-ws" {
  run _run_branch_diff --files -w
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DEV.md"* ]]
}

# ── --base override ────────────────────────────────────────────────────────

@test "--base overrides auto-detection with an explicit ref" {
  run _run_branch_diff --files --base main
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DEV.md"* ]]
}

@test "--base with an unresolvable ref exits 1" {
  run _run_branch_diff --base nonexistent-ref-xyz
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"ERROR"* ]] || [[ "${output}" == *"resolve"* ]]
}

# ── Default-branch auto-detection ─────────────────────────────────────────────

@test "auto-detects origin/main as base even when origin/HEAD is unset" {
  # setup.bash uses `remote add` + `push` -- origin/HEAD is never populated.
  run _run_branch_diff --files
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DEV.md"* ]]
}

@test "prefers origin/HEAD target branch when set, overriding CGW_TARGET_BRANCH" {
  git -C "${TEST_REPO_DIR}" remote set-head origin main
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_TARGET_BRANCH=bogus-default
    bash '${CGW_PROJECT_ROOT}/scripts/git/branch_diff.sh' --files
  " 2>&1
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DEV.md"* ]]
}

# ── No changes ──────────────────────────────────────────────────────────────

@test "no changes ahead of default branch produces empty diff" {
  git -C "${TEST_REPO_DIR}" checkout main
  run _run_branch_diff --files
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

# ── --help / unknown flag ─────────────────────────────────────────────────────

@test "--help exits 0 and prints Usage:" {
  run _run_branch_diff --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "unknown flag exits 1" {
  run _run_branch_diff --bogus-flag
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Unknown"* ]] || [[ "${output}" == *"ERROR"* ]]
}
