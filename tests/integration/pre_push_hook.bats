#!/usr/bin/env bats
# tests/integration/pre_push_hook.bats - Integration tests for the pre-push hook
# Verifies hooks read CGW_LOCAL_FILES from .cgw.conf at runtime and bug #5
# (unanchored regex causing substring matches) is fixed.
# Runs: bats tests/integration/pre_push_hook.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'

setup() {
  create_test_repo_with_remote
  mkdir -p "${TEST_REPO_DIR}/scripts/git"
  cp "${CGW_PROJECT_ROOT}/scripts/git/_common.sh" "${TEST_REPO_DIR}/scripts/git/_common.sh"
  cp "${CGW_PROJECT_ROOT}/scripts/git/_config.sh" "${TEST_REPO_DIR}/scripts/git/_config.sh"
  cp "${CGW_PROJECT_ROOT}/hooks/pre-push" "${TEST_REPO_DIR}/.git/hooks/pre-push"
  chmod +x "${TEST_REPO_DIR}/.git/hooks/pre-push"
  git -C "${TEST_REPO_DIR}" checkout development
}

teardown() {
  cleanup_test_repo
}

# Helper: bypass pre-commit by using --no-verify so we can craft a "bad" commit
# and let the pre-push hook be the one to catch it.
_bypass_commit() {
  local msg="$1"
  git -C "${TEST_REPO_DIR}" commit --quiet --no-verify -m "${msg}"
}

@test "pre-push blocks a commit containing CLAUDE.md (default config)" {
  echo "# Claude" > "${TEST_REPO_DIR}/CLAUDE.md"
  git -C "${TEST_REPO_DIR}" add CLAUDE.md
  _bypass_commit "docs: leak CLAUDE.md"

  run git -C "${TEST_REPO_DIR}" push origin development
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"local-only"* ]] || [[ "${output}" == *"CLAUDE.md"* ]]
}

@test "pre-push picks up .cgw.conf edits at runtime" {
  echo 'CGW_LOCAL_FILES="notes.md"' > "${TEST_REPO_DIR}/.cgw.conf"
  echo "scratch" > "${TEST_REPO_DIR}/notes.md"
  git -C "${TEST_REPO_DIR}" add notes.md .cgw.conf
  _bypass_commit "docs: leak notes.md (per .cgw.conf)"

  run git -C "${TEST_REPO_DIR}" push origin development
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"notes.md"* ]] || [[ "${output}" == *"local-only"* ]]
}

@test "pre-push anchoring: a path containing 'logs' as substring is NOT blocked (bug #5 regression)" {
  # Bug #5: the old `grep -E "${LOCAL_FILES_PATTERN}"` was unanchored, so
  # "logs/" matched any path containing "logs" (e.g. "src/logs_helper.py").
  echo 'CGW_LOCAL_FILES="logs/"' > "${TEST_REPO_DIR}/.cgw.conf"
  mkdir -p "${TEST_REPO_DIR}/src"
  echo "def helper(): pass" > "${TEST_REPO_DIR}/src/logs_helper.py"
  git -C "${TEST_REPO_DIR}" add .cgw.conf src/logs_helper.py
  _bypass_commit "feat: add logs_helper.py"

  run git -C "${TEST_REPO_DIR}" push origin development
  [ "${status}" -eq 0 ]
}

@test "pre-push allows a clean conventional commit" {
  echo "feature" > "${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  _bypass_commit "feat: add feature.txt"

  run git -C "${TEST_REPO_DIR}" push origin development
  [ "${status}" -eq 0 ]
}

@test "pre-push blocks non-conventional commit message" {
  echo "feature" > "${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  _bypass_commit "wip: bad prefix"

  run git -C "${TEST_REPO_DIR}" push origin development
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"non-conventional"* ]] || [[ "${output}" == *"format"* ]]
}

@test "pre-push allows pushing a commit that only deletes a tracked local-only file (bug #7 regression)" {
  # Reproduce: user adds file to CGW_LOCAL_FILES, git rm --cached, commits via core.hooksPath=/dev/null,
  # then pushes. pre-push was using git diff-tree --name-only with no --diff-filter, so it saw the
  # deletion as "CLAUDE.md present in commit" and blocked the push.
  echo "# Claude" > "${TEST_REPO_DIR}/CLAUDE.md"
  git -C "${TEST_REPO_DIR}" -c core.hooksPath=/dev/null add CLAUDE.md
  git -C "${TEST_REPO_DIR}" -c core.hooksPath=/dev/null commit --quiet -m "chore: leak CLAUDE.md"
  # Bypass hook to seed remote with the leak commit (testing push of the *removal*, not the add)
  git -C "${TEST_REPO_DIR}" push --no-verify --quiet origin development
  git -C "${TEST_REPO_DIR}" rm --cached CLAUDE.md
  git -C "${TEST_REPO_DIR}" -c core.hooksPath=/dev/null commit --quiet -m "chore: untrack CLAUDE.md"

  run git -C "${TEST_REPO_DIR}" push origin development
  [ "${status}" -eq 0 ]
}

@test "pre-push CGW_EXTRA_PREFIXES from .cgw.conf is honored at runtime" {
  echo 'CGW_EXTRA_PREFIXES="cuda"' > "${TEST_REPO_DIR}/.cgw.conf"
  echo "feature" > "${TEST_REPO_DIR}/cuda_feat.txt"
  git -C "${TEST_REPO_DIR}" add cuda_feat.txt .cgw.conf
  _bypass_commit "cuda: enable runtime extra prefix"

  run git -C "${TEST_REPO_DIR}" push origin development
  [ "${status}" -eq 0 ]
}
