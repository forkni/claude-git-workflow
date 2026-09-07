#!/usr/bin/env bats
# tests/integration/create_pr.bats - Integration tests for create_pr.sh
# Runs: bats tests/integration/create_pr.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo_with_remote
  setup_mock_bin
  # Start on development which is already 1 commit ahead of main
  git -C "${TEST_REPO_DIR}" checkout development
}

teardown() {
  cleanup_test_repo
}

_run_create_pr() {
  # PATH is already set correctly by setup_mock_bin (MOCK_BIN_DIR prepended and exported).
  # Merge stderr into stdout (2>&1) so that err() messages appear in $output for assertions.
  # PROJECT_ROOT must be pinned to TEST_REPO_DIR so scripts don't auto-detect the real CGW repo.
  (
    cd "${TEST_REPO_DIR}" || exit 1
    export SCRIPT_DIR="${CGW_PROJECT_ROOT}/scripts/git"
    export PROJECT_ROOT="${TEST_REPO_DIR}"
    export CGW_SOURCE_BRANCH=development
    export CGW_TARGET_BRANCH=main
    export CGW_NON_INTERACTIVE=1
    bash "${CGW_PROJECT_ROOT}/scripts/git/create_pr.sh" "$@"
  ) 2>&1
}

# ── No gh in PATH ─────────────────────────────────────────────────────────────

@test "no gh CLI in PATH exits 1" {
  hide_gh
  run _run_create_pr
  [ "${status}" -eq 1 ]
}

@test "no gh CLI output mentions install" {
  hide_gh
  run _run_create_pr
  [[ "${output}" == *"gh"* ]] || [[ "${output}" == *"CLI"* ]] || [[ "${output}" == *"install"* ]]
}

# ── gh CLI not authenticated ──────────────────────────────────────────────────

@test "gh not authenticated exits 1" {
  install_mock_gh_no_auth
  run _run_create_pr
  [ "${status}" -eq 1 ]
}

@test "gh not authenticated output mentions auth" {
  install_mock_gh_no_auth
  run _run_create_pr
  [[ "${output}" == *"auth"* ]] || [[ "${output}" == *"login"* ]]
}

# ── Source == target branch ───────────────────────────────────────────────────

@test "source == target branch exits 1" {
  install_mock_gh
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_SOURCE_BRANCH=main
    export CGW_TARGET_BRANCH=main
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/create_pr.sh'
  "
  [ "${status}" -eq 1 ]
}

# ── Source branch not pushed to remote ───────────────────────────────────────

@test "source branch not pushed exits 1" {
  install_mock_gh
  # Create a local-only branch that is not on remote
  git -C "${TEST_REPO_DIR}" checkout -b local-only-branch
  echo "x" > "${TEST_REPO_DIR}/x.txt"
  git -C "${TEST_REPO_DIR}" add x.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: local only"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_SOURCE_BRANCH=local-only-branch
    export CGW_TARGET_BRANCH=main
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/create_pr.sh'
  "
  [ "${status}" -eq 1 ]
}

# ── No commits ahead ─────────────────────────────────────────────────────────

@test "no commits ahead of target exits 1" {
  install_mock_gh
  # Reset development to match main so 0 commits ahead (distinct branches, no divergence)
  git -C "${TEST_REPO_DIR}" checkout development
  git -C "${TEST_REPO_DIR}" reset --hard main
  git -C "${TEST_REPO_DIR}" push --quiet --force origin development
  git -C "${TEST_REPO_DIR}" checkout main
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_SOURCE_BRANCH=development
    export CGW_TARGET_BRANCH=main
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/create_pr.sh'
  "
  [ "${status}" -eq 1 ]
}

# ── --dry-run ─────────────────────────────────────────────────────────────────

@test "--dry-run exits 0 and shows preview" {
  install_mock_gh
  run _run_create_pr "--dry-run"
  [ "${status}" -eq 0 ]
}

@test "--dry-run output contains DRY RUN" {
  install_mock_gh
  run _run_create_pr "--dry-run"
  [[ "${output}" == *"DRY"* ]] || [[ "${output}" == *"dry"* ]] || [[ "${output}" == *"preview"* ]]
}

@test "--dry-run does not call gh pr create" {
  install_mock_gh
  _run_create_pr "--dry-run" || true
  # gh mock log should not contain "pr create"
  if [ -f "${MOCK_BIN_DIR}/gh.log" ]; then
    ! grep -q "pr create" "${MOCK_BIN_DIR}/gh.log"
  fi
}

# ── Title auto-generation ─────────────────────────────────────────────────────

@test "single commit: PR title equals commit subject" {
  install_mock_gh
  # Repo fixture has exactly 1 commit ahead (feat: dev commit)
  run _run_create_pr "--dry-run"
  [[ "${output}" == *"dev commit"* ]] || [[ "${output}" == *"feat:"* ]]
}

@test "multiple commits: PR title is generic merge title" {
  install_mock_gh
  # Add a second commit ahead
  echo "extra" > "${TEST_REPO_DIR}/extra.txt"
  git -C "${TEST_REPO_DIR}" add extra.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "fix: extra file"
  git -C "${TEST_REPO_DIR}" push --quiet origin development
  run _run_create_pr "--dry-run"
  [[ "${output}" == *"merge:"* ]] || [[ "${output}" == *"development"* ]]
}

# ── --draft flag ──────────────────────────────────────────────────────────────

@test "--draft passes --draft to gh pr create" {
  install_mock_gh
  _run_create_pr "--draft" || true
  if [ -f "${MOCK_BIN_DIR}/gh.log" ]; then
    grep -q "\-\-draft" "${MOCK_BIN_DIR}/gh.log"
  fi
}

# ── Successful PR creation ────────────────────────────────────────────────────

@test "successful PR creation exits 0" {
  install_mock_gh
  run _run_create_pr
  [ "${status}" -eq 0 ]
}

@test "successful PR output contains PR URL" {
  install_mock_gh
  run _run_create_pr
  [[ "${output}" == *"github.com"* ]] || [[ "${output}" == *"pull/"* ]]
}

# ── Explicit --repo (fork/upstream default-resolution bug) ──────────────────
# Reproduces the fork/upstream repo shape offline: origin's *configured* URL
# is rewritten to a fake github.com URL, but `url.<bare-dir>.insteadOf` sends
# all real git transport (fetch/push/ls-remote) transparently to the local
# bare remote already set up by create_test_repo_with_remote. This lets
# cgw_remote_owner_repo "see" a github.com URL and parse it, while the rest of
# the script still runs fully offline against the local bare repo.
#
# Without --repo, `gh pr create` resolves its own target repo and -- when the
# remote is a fork -- defaults to the fork's parent/upstream repo instead of
# origin itself. Asserting the exact --repo value in gh.log is red-capable:
# before the fix, create_pr.sh never passed --repo at all.

_use_fake_github_origin() {
  local fake_url="https://github.com/forkni/claude-git-workflow.git"
  git -C "${TEST_REPO_DIR}" config remote.origin.url "${fake_url}"
  git -C "${TEST_REPO_DIR}" config "url.${TEST_REMOTE_DIR}.insteadOf" "${fake_url}"
}

@test "fork-shaped origin: passes explicit --repo resolved from origin's URL" {
  install_mock_gh
  _use_fake_github_origin
  run _run_create_pr
  [ "${status}" -eq 0 ]
  grep -q -- "--repo forkni/claude-git-workflow" "${MOCK_BIN_DIR}/gh.log"
}

@test "fork-shaped origin: --dry-run preview shows the resolved repo" {
  install_mock_gh
  _use_fake_github_origin
  run _run_create_pr "--dry-run"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"forkni/claude-git-workflow"* ]]
}

@test "non-github origin: falls back to no --repo (gh's own resolution)" {
  install_mock_gh
  # Default fixture remote is a local bare path, not a github.com URL.
  run _run_create_pr
  [ "${status}" -eq 0 ]
  ! grep -q -- "--repo" "${MOCK_BIN_DIR}/gh.log"
}
