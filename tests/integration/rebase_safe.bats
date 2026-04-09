#!/usr/bin/env bats
# tests/integration/rebase_safe.bats - Integration tests for rebase_safe.sh
# Runs: bats tests/integration/rebase_safe.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo
  setup_mock_bin
  install_mock_lint
  # Ensure development has commits not on main, and main has no divergence
  git -C "${TEST_REPO_DIR}" checkout --quiet main
}

teardown() {
  cleanup_test_repo
}

# ── validation ────────────────────────────────────────────────────────────────

@test "no operation flag exits 1 with helpful message" {
  run run_script rebase_safe.sh --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"--onto"* ]] || [[ "${output}" == *"Specify"* ]]
}

@test "--onto and --squash-last together exits 1" {
  run run_script rebase_safe.sh --onto main --squash-last 2 --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not both"* ]] || [[ "${output}" == *"either"* ]]
}

@test "--abort when no rebase in progress exits 0 with informational message" {
  run run_script rebase_safe.sh --abort
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No rebase"* ]] || [[ "${output}" == *"not in progress"* ]] || [[ "${output}" == *"in progress"* ]]
}

# ── --onto ────────────────────────────────────────────────────────────────────

@test "--onto main when development is already up to date exits 0" {
  # Create a fresh repo where development == main (no extra commits on development)
  local already_repo="${TEST_TMPDIR}/aligned"
  mkdir -p "${already_repo}"
  git -C "${already_repo}" init --quiet
  git -C "${already_repo}" config user.email "test@example.com"
  git -C "${already_repo}" config user.name "Test User"
  git -C "${already_repo}" config core.autocrlf false
  echo "x" > "${already_repo}/x.txt"
  git -C "${already_repo}" add x.txt
  git -C "${already_repo}" commit --quiet -m "chore: init"
  git -C "${already_repo}" checkout --quiet -b main 2>/dev/null || \
    git -C "${already_repo}" branch -m main 2>/dev/null || true
  git -C "${already_repo}" checkout --quiet -b development
  # development has no extra commits beyond main, so rebase is a no-op
  run bash -c "
    cd '${already_repo}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${already_repo}'
    bash '${CGW_PROJECT_ROOT}/scripts/git/rebase_safe.sh' --onto main --non-interactive
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"up to date"* ]] || [[ "${output}" == *"nothing to rebase"* ]]
}

@test "--onto main rebases development commits and creates backup tag" {
  # development has one extra commit over main (from create_test_repo)
  git -C "${TEST_REPO_DIR}" checkout --quiet development

  run run_script rebase_safe.sh --onto main --non-interactive
  [ "${status}" -eq 0 ]

  # Backup tag created
  git -C "${TEST_REPO_DIR}" tag | grep -q "^pre-rebase-"
}

@test "--dry-run --onto main shows plan without rebasing" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  local head_before
  head_before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  run run_script rebase_safe.sh --onto main --dry-run --non-interactive
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ry run"* ]] || [[ "${output}" == *"Would run"* ]]

  # HEAD unchanged
  local head_after
  head_after=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)
  [ "${head_before}" = "${head_after}" ]
}

@test "dirty tree without --autostash exits 1" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  echo "dirty" >> "${TEST_REPO_DIR}/DEV.md"

  run run_script rebase_safe.sh --onto main --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"dirty"* ]] || [[ "${output}" == *"uncommitted"* ]] || [[ "${output}" == *"stash"* ]]
}

@test "invalid --onto ref exits 1" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development

  run run_script rebase_safe.sh --onto nonexistent-branch-xyz --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Invalid"* ]] || [[ "${output}" == *"invalid"* ]]
}
