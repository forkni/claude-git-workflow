#!/usr/bin/env bats
# tests/integration/merge_pr.bats - Integration tests for merge_pr.sh
# Runs: bats tests/integration/merge_pr.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo_with_remote
  setup_mock_bin
  # merge_pr.sh passes gh an explicit --repo and fails closed when origin isn't a
  # resolvable github.com URL; redirect the fake URL to the local bare remote.
  local fake_url="https://github.com/forkni/claude-git-workflow.git"
  git -C "${TEST_REPO_DIR}" config remote.origin.url "${fake_url}"
  git -C "${TEST_REPO_DIR}" config "url.${TEST_REMOTE_DIR}.insteadOf" "${fake_url}"
  git -C "${TEST_REPO_DIR}" checkout development
  GH_LOG="${MOCK_BIN_DIR}/gh.log"
}

teardown() {
  cleanup_test_repo
}

_run_merge_pr() {
  (
    cd "${TEST_REPO_DIR}" || exit 1
    export SCRIPT_DIR="${CGW_PROJECT_ROOT}/scripts/git"
    export PROJECT_ROOT="${TEST_REPO_DIR}"
    export CGW_NON_INTERACTIVE=1
    bash "${CGW_PROJECT_ROOT}/scripts/git/merge_pr.sh" "$@"
  ) 2>&1
}

# ── Prerequisites ─────────────────────────────────────────────────────────────

@test "no gh CLI in PATH exits 1" {
  hide_gh
  run _run_merge_pr 42
  [ "${status}" -eq 1 ]
}

@test "gh not authenticated exits 1" {
  install_mock_gh_no_auth
  run _run_merge_pr 42
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"auth"* ]] || [[ "${output}" == *"login"* ]]
}

@test "origin that is not a github.com URL exits 1 without calling gh pr merge" {
  install_mock_gh
  git -C "${TEST_REPO_DIR}" config remote.origin.url "${TEST_REMOTE_DIR}"
  git -C "${TEST_REPO_DIR}" config --unset "url.${TEST_REMOTE_DIR}.insteadOf" || true
  run _run_merge_pr 42
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"explicit --repo"* ]]
  ! grep -q "pr merge" "${GH_LOG}"
}

# ── Argument validation ───────────────────────────────────────────────────────

@test "no PR number exits 1" {
  install_mock_gh
  run _run_merge_pr
  [ "${status}" -eq 1 ]
}

@test "non-numeric PR number exits 1" {
  install_mock_gh
  run _run_merge_pr abc
  [ "${status}" -eq 1 ]
}

@test "--squash and --rebase together exits 1" {
  install_mock_gh
  run _run_merge_pr 42 --squash --rebase
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"mutually exclusive"* ]]
}

@test "--retarget of the PR being merged exits 1" {
  install_mock_gh
  run _run_merge_pr 42 --retarget 42
  [ "${status}" -eq 1 ]
}

# ── Merge method ──────────────────────────────────────────────────────────────

@test "default merges with a merge commit and an explicit --repo" {
  install_mock_gh
  run _run_merge_pr 42
  [ "${status}" -eq 0 ]
  grep -q -- "pr merge 42 --repo forkni/claude-git-workflow --merge" "${GH_LOG}"
  ! grep -q -- "--delete-branch" "${GH_LOG}"
}

@test "success prints the merge SHA and the revert hint" {
  install_mock_gh
  run _run_merge_pr 42
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"abc1234def5678"* ]]
  [[ "${output}" == *"rollback_merge.sh --revert --target abc1234def5678"* ]]
}

@test "--squash non-interactive without --allow-non-merge exits 1 and does not merge" {
  install_mock_gh
  run _run_merge_pr 42 --squash
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"--allow-non-merge"* ]]
  ! grep -q "pr merge" "${GH_LOG}"
}

@test "--squash with --allow-non-merge merges with --squash and warns" {
  install_mock_gh
  run _run_merge_pr 42 --squash --allow-non-merge
  [ "${status}" -eq 0 ]
  grep -q -- "pr merge 42 --repo forkni/claude-git-workflow --squash" "${GH_LOG}"
  [[ "${output}" == *"can't be reverted as one unit"* ]]
}

@test "--rebase with --allow-non-merge merges with --rebase" {
  install_mock_gh
  run _run_merge_pr 42 --rebase --allow-non-merge
  [ "${status}" -eq 0 ]
  grep -q -- "pr merge 42 --repo forkni/claude-git-workflow --rebase" "${GH_LOG}"
}

# ── PR state ──────────────────────────────────────────────────────────────────

@test "a PR that is not OPEN exits 1 and does not merge" {
  install_mock_gh
  MOCK_GH_PR_STATE=MERGED run _run_merge_pr 42
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"MERGED"* ]]
  ! grep -q "pr merge" "${GH_LOG}"
}

@test "gh pr merge failure exits 1" {
  install_mock_gh
  MOCK_GH_MERGE_EXIT=1 run _run_merge_pr 42
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"gh pr merge failed"* ]]
}

# ── --retarget (stacked PRs) ──────────────────────────────────────────────────

@test "--retarget edits the stacked PR's base to this PR's base after the merge" {
  install_mock_gh
  export MOCK_GH_PR_42_HEADREFNAME=feature-a
  export MOCK_GH_PR_42_BASEREFNAME=main
  export MOCK_GH_PR_43_BASEREFNAME=feature-a
  run _run_merge_pr 42 --retarget 43
  [ "${status}" -eq 0 ]
  grep -q -- "pr edit 43 --repo forkni/claude-git-workflow --base main" "${GH_LOG}"
  # merge happens before the retarget
  local merge_line edit_line
  merge_line=$(grep -n "pr merge 42" "${GH_LOG}" | head -1 | cut -d: -f1)
  edit_line=$(grep -n "pr edit 43" "${GH_LOG}" | head -1 | cut -d: -f1)
  [ "${merge_line}" -lt "${edit_line}" ]
}

@test "--retarget accepts several PRs" {
  install_mock_gh
  export MOCK_GH_PR_42_HEADREFNAME=feature-a
  export MOCK_GH_PR_43_BASEREFNAME=feature-a
  export MOCK_GH_PR_44_BASEREFNAME=feature-a
  run _run_merge_pr 42 --retarget 43 --retarget 44
  [ "${status}" -eq 0 ]
  grep -q -- "pr edit 43 " "${GH_LOG}"
  grep -q -- "pr edit 44 " "${GH_LOG}"
}

@test "--retarget of a PR not based on this PR's head exits 1 before merging" {
  install_mock_gh
  export MOCK_GH_PR_42_HEADREFNAME=feature-a
  export MOCK_GH_PR_43_BASEREFNAME=something-else
  run _run_merge_pr 42 --retarget 43
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not stacked"* ]]
  ! grep -q "pr merge" "${GH_LOG}"
  ! grep -q "pr edit" "${GH_LOG}"
}

@test "--retarget of a PR that is not OPEN exits 1 before merging" {
  install_mock_gh
  export MOCK_GH_PR_42_HEADREFNAME=feature-a
  export MOCK_GH_PR_43_BASEREFNAME=feature-a
  export MOCK_GH_PR_43_STATE=CLOSED
  run _run_merge_pr 42 --retarget 43
  [ "${status}" -eq 1 ]
  ! grep -q "pr merge" "${GH_LOG}"
}

# ── --delete-branch ───────────────────────────────────────────────────────────

@test "the head branch is never deleted by default" {
  install_mock_gh
  run _run_merge_pr 42
  [ "${status}" -eq 0 ]
  ! grep -q "^gh api" "${GH_LOG}"
}

@test "--delete-branch deletes the head branch after merge and retarget" {
  install_mock_gh
  export MOCK_GH_PR_42_HEADREFNAME=feature-a
  export MOCK_GH_PR_43_BASEREFNAME=feature-a
  run _run_merge_pr 42 --retarget 43 --delete-branch
  [ "${status}" -eq 0 ]
  grep -q -- "api --method DELETE repos/forkni/claude-git-workflow/git/refs/heads/feature-a" "${GH_LOG}"
  local edit_line del_line
  edit_line=$(grep -n "pr edit 43" "${GH_LOG}" | head -1 | cut -d: -f1)
  del_line=$(grep -n "^gh api" "${GH_LOG}" | head -1 | cut -d: -f1)
  [ "${edit_line}" -lt "${del_line}" ]
}

@test "--delete-branch deletes in the PR's head repository, not the base repository" {
  install_mock_gh
  export MOCK_GH_PR_42_HEADREFNAME=feature-a
  export MOCK_GH_PR_HEADREPOSITORY_HEADREPOSITORYOWNER=contributor/claude-git-workflow
  run _run_merge_pr 42 --delete-branch
  [ "${status}" -eq 0 ]
  grep -q -- "api --method DELETE repos/contributor/claude-git-workflow/git/refs/heads/feature-a" "${GH_LOG}"
  ! grep -q -- "repos/forkni/claude-git-workflow/git/refs/heads" "${GH_LOG}"
}

@test "--delete-branch failure makes the script exit non-zero" {
  install_mock_gh
  export MOCK_GH_API_EXIT=1
  run _run_merge_pr 42 --delete-branch
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Could not delete remote branch"* ]]
  # the merge itself still happened and is reported
  grep -q "pr merge 42" "${GH_LOG}"
}

# ── pre-merge recovery point ──────────────────────────────────────────────────

@test "a pre-merge backup tag is created at the base branch tip before merging" {
  install_mock_gh
  local base_tip
  base_tip=$(git -C "${TEST_REPO_DIR}" rev-parse origin/main)
  run _run_merge_pr 42
  [ "${status}" -eq 0 ]
  local tag
  tag=$(git -C "${TEST_REPO_DIR}" tag --list 'pre-merge-*' | head -1)
  [ -n "${tag}" ]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse "${tag}")" = "${base_tip}" ]
}

@test "--dry-run creates no backup tag" {
  install_mock_gh
  run _run_merge_pr 42 --dry-run
  [ "${status}" -eq 0 ]
  [ -z "$(git -C "${TEST_REPO_DIR}" tag --list 'pre-merge-*')" ]
}

# ── --dry-run ─────────────────────────────────────────────────────────────────

@test "--dry-run validates and prints the commands but mutates nothing" {
  install_mock_gh
  export MOCK_GH_PR_42_HEADREFNAME=feature-a
  export MOCK_GH_PR_43_BASEREFNAME=feature-a
  run _run_merge_pr 42 --retarget 43 --delete-branch --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DRY RUN"* ]]
  [[ "${output}" == *"Would run: gh pr merge 42"* ]]
  [[ "${output}" == *"Would run: gh pr edit 43"* ]]
  ! grep -q "pr merge" "${GH_LOG}"
  ! grep -q "pr edit" "${GH_LOG}"
  ! grep -q "^gh api" "${GH_LOG}"
}

@test "--dry-run still refuses a non-OPEN PR" {
  install_mock_gh
  MOCK_GH_PR_STATE=CLOSED run _run_merge_pr 42 --dry-run
  [ "${status}" -eq 1 ]
}

# ── merge queue / auto-merge: gh returns 0 but the PR is not MERGED yet ───────

@test "a PR still not MERGED after gh pr merge is reported as pending and skips retarget/delete" {
  install_mock_gh
  export MOCK_GH_PR_42_HEADREFNAME=feature-a
  export MOCK_GH_PR_43_BASEREFNAME=feature-a
  export MOCK_GH_POSTMERGE_STATE=OPEN
  run _run_merge_pr 42 --retarget 43 --delete-branch
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"[OK] Merged PR #42"* ]]
  [[ "${output}" == *"not merged yet"* ]]
  ! grep -q -- "pr edit 43" "${GH_LOG}"
  ! grep -q -- "api --method DELETE" "${GH_LOG}"
}

@test "an unfetchable base branch refuses the merge: no recovery point, no gh pr merge" {
  install_mock_gh
  git -C "${TEST_REPO_DIR}" config "url.${TEST_TMPDIR}/no-such-remote.insteadOf" "https://github.com/forkni/claude-git-workflow.git"
  git -C "${TEST_REPO_DIR}" config --unset-all "url.${TEST_REMOTE_DIR}.insteadOf"
  run _run_merge_pr 42
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"refusing to merge without a recovery point"* ]]
  ! grep -q -- "pr merge" "${GH_LOG}"
}

# ── PR checks gate ────────────────────────────────────────────────────────────

@test "failing PR checks refuse the merge: no recovery point, no gh pr merge" {
  install_mock_gh
  export MOCK_GH_CHECKS_EXIT=1
  run _run_merge_pr 42
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"checks are not green"* ]]
  ! grep -q -- "pr merge" "${GH_LOG}"
}

@test "pending PR checks refuse the merge without --wait-checks" {
  install_mock_gh
  export MOCK_GH_CHECKS_EXIT=8
  run _run_merge_pr 42
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"still pending"* ]]
  ! grep -q -- "pr merge" "${GH_LOG}"
}

@test "--wait-checks watches pending checks and merges when they go green" {
  install_mock_gh
  export MOCK_GH_CHECKS_EXIT=8
  run _run_merge_pr 42 --wait-checks
  [ "${status}" -eq 0 ]
  grep -q -- "pr checks 42 .*--watch" "${GH_LOG}"
  grep -q -- "pr merge 42" "${GH_LOG}"
}

@test "--wait-checks refuses when the watched checks fail" {
  install_mock_gh
  export MOCK_GH_CHECKS_EXIT=8
  export MOCK_GH_CHECKS_WATCH_EXIT=1
  run _run_merge_pr 42 --wait-checks
  [ "${status}" -eq 1 ]
  ! grep -q -- "pr merge" "${GH_LOG}"
}

@test "--skip-checks merges despite failing checks and warns" {
  install_mock_gh
  export MOCK_GH_CHECKS_EXIT=1
  run _run_merge_pr 42 --skip-checks
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--skip-checks"* ]]
  grep -q -- "pr merge 42" "${GH_LOG}"
}

@test "--dry-run still refuses failing checks" {
  install_mock_gh
  export MOCK_GH_CHECKS_EXIT=1
  run _run_merge_pr 42 --dry-run
  [ "${status}" -eq 1 ]
}
