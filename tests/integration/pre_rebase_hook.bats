#!/usr/bin/env bats
# tests/integration/pre_rebase_hook.bats - Integration tests for the pre-rebase
# hook's actual BEHAVIOR (not its bootstrap).
#
# hook_bootstrap.bats already covers pre-rebase's fail-closed source when CGW
# is unreachable, and the "inert when CGW is present" case for an unpublished
# rebase. Neither exercises the hook's real purpose: refusing to rebase
# commits that have already been pushed to the remote (Pro Git's "Hook
# Examples" §pre-rebase), or the CGW_ALLOW_REBASE_PUBLISHED=1 escape hatch.
#
# Runs: bats tests/integration/pre_rebase_hook.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'

setup() {
  create_test_repo_with_remote
  git -C "${TEST_REPO_DIR}" checkout --quiet development

  mkdir -p "${TEST_REPO_DIR}/scripts/git"
  cp "${CGW_PROJECT_ROOT}/scripts/git/_common.sh" "${TEST_REPO_DIR}/scripts/git/_common.sh"
  cp "${CGW_PROJECT_ROOT}/scripts/git/_config.sh" "${TEST_REPO_DIR}/scripts/git/_config.sh"
  cp "${CGW_PROJECT_ROOT}/hooks/pre-rebase" "${TEST_REPO_DIR}/.git/hooks/pre-rebase"
  chmod +x "${TEST_REPO_DIR}/.git/hooks/pre-rebase"
}

teardown() {
  cleanup_test_repo
}

# Publishes feature/topic to origin (so its one commit counts as "already
# pushed"), then diverges development locally so there's a real upstream to
# rebase onto — a rebase that's already up to date never invokes the hook at
# all, which would make these tests pass for the wrong reason.
_diverge_with_published_topic() {
  git -C "${TEST_REPO_DIR}" checkout -b feature/topic
  echo "topic" > "${TEST_REPO_DIR}/topic.txt"
  git -C "${TEST_REPO_DIR}" add topic.txt
  git -C "${TEST_REPO_DIR}" commit --quiet --no-verify -m "feat: add topic.txt"
  git -C "${TEST_REPO_DIR}" push --quiet origin feature/topic

  git -C "${TEST_REPO_DIR}" checkout --quiet development
  echo "upstream" > "${TEST_REPO_DIR}/upstream.txt"
  git -C "${TEST_REPO_DIR}" add upstream.txt
  git -C "${TEST_REPO_DIR}" commit --quiet --no-verify -m "feat: add upstream.txt"
  git -C "${TEST_REPO_DIR}" checkout --quiet feature/topic
}

@test "pre-rebase blocks rebasing a commit already pushed to the remote" {
  _diverge_with_published_topic
  run git -C "${TEST_REPO_DIR}" rebase development
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ERROR [pre-rebase]: Refusing to rebase commits already pushed to origin."* ]]
  [[ "${output}" == *"add topic.txt"* ]]
  [[ "${output}" == *"CGW_ALLOW_REBASE_PUBLISHED=1"* ]]
}

@test "CGW_ALLOW_REBASE_PUBLISHED=1 bypasses the published-commit guard" {
  _diverge_with_published_topic
  echo 'CGW_ALLOW_REBASE_PUBLISHED=1' > "${TEST_REPO_DIR}/.cgw.conf"
  run git -C "${TEST_REPO_DIR}" rebase development
  [ "${status}" -eq 0 ]
}

@test "pre-rebase does not block a rebase of commits that were never published" {
  git -C "${TEST_REPO_DIR}" checkout -b feature/unpublished
  echo "local only" > "${TEST_REPO_DIR}/local.txt"
  git -C "${TEST_REPO_DIR}" add local.txt
  git -C "${TEST_REPO_DIR}" commit --quiet --no-verify -m "feat: add local.txt"

  git -C "${TEST_REPO_DIR}" checkout --quiet development
  echo "upstream" > "${TEST_REPO_DIR}/upstream.txt"
  git -C "${TEST_REPO_DIR}" add upstream.txt
  git -C "${TEST_REPO_DIR}" commit --quiet --no-verify -m "feat: add upstream.txt"
  git -C "${TEST_REPO_DIR}" checkout --quiet feature/unpublished

  run git -C "${TEST_REPO_DIR}" rebase development
  [ "${status}" -eq 0 ]
}
