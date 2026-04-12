#!/usr/bin/env bats
# tests/integration/sync_branches.bats - Integration tests for sync_branches.sh
# Runs: bats tests/integration/sync_branches.bats

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

_run_sync() {
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_NON_INTERACTIVE=1
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    bash '${CGW_PROJECT_ROOT}/scripts/git/sync_branches.sh' $*
  "
}

# Push a commit to the remote from a temporary clone, making local behind.
# Arguments:
#   $1 - branch name (default: development)
#   $2 - filename for the new commit (default: remote_change.txt)
_push_remote_commit() {
  local branch="${1:-development}"
  local filename="${2:-remote_change.txt}"
  local clone_dir="${TEST_TMPDIR}/clone_${branch}"
  git clone --quiet "${TEST_REMOTE_DIR}" "${clone_dir}"
  git -C "${clone_dir}" config user.email "test@example.com"
  git -C "${clone_dir}" config user.name "Test User"
  git -C "${clone_dir}" checkout "${branch}"
  echo "remote change" > "${clone_dir}/${filename}"
  git -C "${clone_dir}" add "${filename}"
  git -C "${clone_dir}" commit --quiet -m "feat: remote commit on ${branch}"
  git -C "${clone_dir}" push --quiet origin "${branch}"
}

# ── --help ────────────────────────────────────────────────────────────────────

@test "--help exits 0" {
  run _run_sync "--help"
  [ "${status}" -eq 0 ]
}

@test "--help output mentions new flags" {
  run _run_sync "--help"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--dry-run"* ]]
  [[ "${output}" == *"--branch"* ]]
  [[ "${output}" == *"--prune"* ]]
}

# ── --dry-run ─────────────────────────────────────────────────────────────────

@test "--dry-run exits 0" {
  run _run_sync "--dry-run"
  [ "${status}" -eq 0 ]
}

@test "--dry-run output mentions DRY RUN" {
  run _run_sync "--dry-run"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DRY RUN"* ]]
}

@test "--dry-run does not advance local branch when behind" {
  _push_remote_commit "development" "remote_dry.txt"

  local before
  before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  _run_sync "--dry-run" || true

  local after
  after=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)
  [ "${before}" = "${after}" ]
}

@test "--dry-run reports commit counts" {
  _push_remote_commit "development" "remote_count.txt"

  run _run_sync "--dry-run"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"behind"* ]]
}

# ── Up-to-date ────────────────────────────────────────────────────────────────

@test "up-to-date branch reports OK" {
  run _run_sync ""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"up-to-date"* ]] || [[ "${output}" == *"Already"* ]]
}

# ── Behind branch gets synced ─────────────────────────────────────────────────

@test "behind branch gets synced" {
  _push_remote_commit "development" "new_feature.txt"

  run _run_sync ""
  [ "${status}" -eq 0 ]
  [ -f "${TEST_REPO_DIR}/new_feature.txt" ]
}

@test "sync reports success after pulling" {
  _push_remote_commit "development" "sync_check.txt"

  run _run_sync ""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"SYNC SUCCESSFUL"* ]] || [[ "${output}" == *"synced successfully"* ]]
}

# ── --all ─────────────────────────────────────────────────────────────────────

@test "--all syncs both branches and mentions both in output" {
  run _run_sync "--all"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"development"* ]]
  [[ "${output}" == *"main"* ]]
}

@test "--all returns to original branch after syncing" {
  git -C "${TEST_REPO_DIR}" checkout development

  _run_sync "--all"

  local current
  current=$(git -C "${TEST_REPO_DIR}" branch --show-current)
  [ "${current}" = "development" ]
}

# ── --branch <name> ───────────────────────────────────────────────────────────

@test "--branch main syncs only main" {
  run _run_sync "--branch main"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"main"* ]]
}

@test "--branch nonexistent-branch is skipped gracefully" {
  run _run_sync "--branch nonexistent-branch"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"skipping"* ]] || [[ "${output}" == *"does not exist"* ]]
}

@test "--branch local-only skips when no remote tracking" {
  git -C "${TEST_REPO_DIR}" checkout -b local-only
  git -C "${TEST_REPO_DIR}" checkout development

  run _run_sync "--branch local-only"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"skipping"* ]] || [[ "${output}" == *"No remote"* ]]
}

@test "--branch returns to original branch" {
  git -C "${TEST_REPO_DIR}" checkout development

  _run_sync "--branch main"

  local current
  current=$(git -C "${TEST_REPO_DIR}" branch --show-current)
  [ "${current}" = "development" ]
}

# ── --prune ───────────────────────────────────────────────────────────────────

@test "--prune flag is accepted and exits 0" {
  run _run_sync "--prune"
  [ "${status}" -eq 0 ]
}

# ── Uncommitted changes ───────────────────────────────────────────────────────

@test "uncommitted changes trigger autostash in non-interactive" {
  echo "dirty" > "${TEST_REPO_DIR}/dirty.txt"
  git -C "${TEST_REPO_DIR}" add dirty.txt

  run _run_sync ""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"auto-stash"* ]] || [[ "${output}" == *"Auto-stash"* ]] || [[ "${output}" == *"autostash"* ]]
}

# ── Unknown flag ──────────────────────────────────────────────────────────────

@test "unknown flag exits non-zero" {
  run _run_sync "--unknown-flag"
  [ "${status}" -ne 0 ]
}
