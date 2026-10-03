#!/usr/bin/env bats
# tests/integration/cherry_pick_conflict_resume.bats - a cherry-pick that halts on a conflict
# needing manual resolution must stay paused on the target branch. The script prints
# "git add ... / git cherry-pick --continue"; its EXIT trap must not abort that pick.
# Runs: bats tests/integration/cherry_pick_conflict_resume.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo_with_remote
  setup_mock_bin
  install_mock_lint
  local r="${TEST_REPO_DIR}"
  # main deletes gone.txt; development modifies it -> DU (modify/delete) on cherry-pick.
  git -C "${r}" checkout --quiet main
  echo "base" >"${r}/gone.txt"
  git -C "${r}" add gone.txt
  git -C "${r}" commit --quiet -m "chore: add gone.txt"
  git -C "${r}" checkout --quiet development
  git -C "${r}" merge --quiet main -m "merge main" >/dev/null 2>&1
  echo "dev change" >"${r}/gone.txt"
  git -C "${r}" commit --quiet -am "feat: modify gone.txt"
  DEV_COMMIT="$(git -C "${r}" rev-parse HEAD)"
  git -C "${r}" checkout --quiet main
  git -C "${r}" rm --quiet gone.txt
  git -C "${r}" commit --quiet -m "chore: delete gone.txt"
  git -C "${r}" checkout --quiet development
}

teardown() {
  cleanup_test_repo
}

@test "DU conflict halts with the pick still paused on the target branch" {
  run run_script cherry_pick_commits.sh --commit "${DEV_COMMIT}" --non-interactive
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Modify/delete"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" branch --show-current)" = "main" ]
  git -C "${TEST_REPO_DIR}" rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null
}

@test "DU conflict: the printed manual-resolution steps work (git rm, --continue)" {
  run run_script cherry_pick_commits.sh --commit "${DEV_COMMIT}" --non-interactive
  [ "${status}" -ne 0 ]
  git -C "${TEST_REPO_DIR}" rm --quiet gone.txt
  GIT_EDITOR=true run git -C "${TEST_REPO_DIR}" cherry-pick --continue
  [ "${status}" -eq 0 ] || [[ "${output}" == *"empty"* ]]
}
