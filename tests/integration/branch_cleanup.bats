#!/usr/bin/env bats
# tests/integration/branch_cleanup.bats - Integration tests for branch_cleanup.sh
# Runs: bats tests/integration/branch_cleanup.bats

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

# ── default dry-run ───────────────────────────────────────────────────────────

@test "default mode is dry-run and exits 0" {
  run run_script branch_cleanup.sh
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DRY RUN"* ]] || [[ "${output}" == *"dry run"* ]]
}

@test "dry-run does not delete any branches" {
  # Create a merged feature branch
  git -C "${TEST_REPO_DIR}" checkout --quiet main
  git -C "${TEST_REPO_DIR}" checkout --quiet -b feature/merged
  echo "x" > "${TEST_REPO_DIR}/feat.txt"
  git -C "${TEST_REPO_DIR}" add feat.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: feature work"
  git -C "${TEST_REPO_DIR}" checkout --quiet main
  git -C "${TEST_REPO_DIR}" merge --quiet --no-ff feature/merged -m "Merge feature/merged"

  run run_script branch_cleanup.sh
  [ "${status}" -eq 0 ]
  # Branch still exists
  git -C "${TEST_REPO_DIR}" branch | grep -q "feature/merged"
}

@test "explicit --dry-run is accepted and does not delete merged branches" {
  # Documented in the header comment and --help as the (already-default) preview
  # mode; the parser must accept it explicitly, not just treat it as unknown.
  git -C "${TEST_REPO_DIR}" checkout --quiet main
  git -C "${TEST_REPO_DIR}" checkout --quiet -b feature/merged
  echo "x" > "${TEST_REPO_DIR}/feat.txt"
  git -C "${TEST_REPO_DIR}" add feat.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: feature work"
  git -C "${TEST_REPO_DIR}" checkout --quiet main
  git -C "${TEST_REPO_DIR}" merge --quiet --no-ff feature/merged -m "Merge feature/merged"

  run run_script branch_cleanup.sh --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DRY RUN"* ]] || [[ "${output}" == *"dry run"* ]]
  git -C "${TEST_REPO_DIR}" branch | grep -q "feature/merged"
}

# ── --execute mode ────────────────────────────────────────────────────────────

@test "--execute --non-interactive deletes merged branches" {
  # Create and merge a feature branch
  git -C "${TEST_REPO_DIR}" checkout --quiet main
  git -C "${TEST_REPO_DIR}" checkout --quiet -b feature/to-delete
  echo "x" > "${TEST_REPO_DIR}/feat2.txt"
  git -C "${TEST_REPO_DIR}" add feat2.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: to delete"
  git -C "${TEST_REPO_DIR}" checkout --quiet main
  git -C "${TEST_REPO_DIR}" merge --quiet --no-ff feature/to-delete -m "Merge feature/to-delete"

  run run_script branch_cleanup.sh --execute --non-interactive
  [ "${status}" -eq 0 ]
  # Branch is gone
  ! git -C "${TEST_REPO_DIR}" branch | grep -q "feature/to-delete"
}

# ── protected branches ────────────────────────────────────────────────────────

@test "protected branch 'main' is never deleted" {
  run run_script branch_cleanup.sh --execute --non-interactive
  [ "${status}" -eq 0 ]
  git -C "${TEST_REPO_DIR}" branch | grep -q "main"
}

@test "protected branch 'development' is never deleted" {
  run run_script branch_cleanup.sh --execute --non-interactive
  [ "${status}" -eq 0 ]
  git -C "${TEST_REPO_DIR}" branch | grep -q "development"
}

@test "main and master survive when CGW_TARGET_BRANCH is overridden to a non-stable branch" {
  # master and a throwaway control branch both descend from main, so from
  # development's perspective (the overridden target) they all look "merged".
  # Without hardcoded protection, main/master would be deleted here too --
  # they're not CGW_TARGET_BRANCH/CGW_SOURCE_BRANCH once TARGET=development.
  # -f: some environments' init.defaultBranch=master already leaves a stray
  # 'master' branch in the fixture repo (create_test_repo renames it to main
  # but the original ref lingers) -- force it to a known, merged position.
  git -C "${TEST_REPO_DIR}" branch -f master main
  git -C "${TEST_REPO_DIR}" branch feature/stale main
  git -C "${TEST_REPO_DIR}" checkout --quiet development

  export CGW_TARGET_BRANCH=development
  run run_script branch_cleanup.sh --execute --non-interactive
  [ "${status}" -eq 0 ]
  git -C "${TEST_REPO_DIR}" branch | grep -q "master"
  git -C "${TEST_REPO_DIR}" branch | grep -qE '(^|[[:space:]])main$'
  # Control branch proves --execute actually processed the merged set.
  ! git -C "${TEST_REPO_DIR}" branch | grep -q "feature/stale"
}

@test "remote default branch survives when CGW_TARGET_BRANCH is overridden" {
  git -C "${TEST_REPO_DIR}" branch stable main
  git -C "${TEST_REPO_DIR}" push --quiet origin stable
  git -C "${TEST_REPO_DIR}" remote set-head origin stable
  git -C "${TEST_REPO_DIR}" branch feature/stale main
  git -C "${TEST_REPO_DIR}" checkout --quiet development

  export CGW_TARGET_BRANCH=development
  run run_script branch_cleanup.sh --execute --non-interactive
  [ "${status}" -eq 0 ]
  git -C "${TEST_REPO_DIR}" branch | grep -q "stable"
  ! git -C "${TEST_REPO_DIR}" branch | grep -q "feature/stale"
}

@test "branch checked out in a linked worktree is not listed for deletion" {
  git -C "${TEST_REPO_DIR}" branch feature/wt main
  git -C "${TEST_REPO_DIR}" worktree add --quiet "${TEST_TMPDIR}/wt" feature/wt

  run run_script branch_cleanup.sh
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"feature/wt"* ]]
}

# ── backup tag cleanup ────────────────────────────────────────────────────────

@test "--tags dry-run shows old backup tags without deleting" {
  # Create a fake backup tag
  git -C "${TEST_REPO_DIR}" tag "pre-merge-backup-20200101_000000" HEAD

  run run_script branch_cleanup.sh --tags
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DRY RUN"* ]] || [[ "${output}" == *"dry run"* ]]
  # Tag still exists
  git -C "${TEST_REPO_DIR}" tag | grep -q "pre-merge-backup-20200101_000000"
}

@test "--tags --execute --older-than 0 deletes old backup tags" {
  # Create a fake backup tag (will be treated as very old)
  git -C "${TEST_REPO_DIR}" tag "pre-merge-backup-20200101_000000" HEAD

  run run_script branch_cleanup.sh --tags --execute --older-than 0 --non-interactive
  [ "${status}" -eq 0 ]
  # Tag is deleted
  ! git -C "${TEST_REPO_DIR}" tag | grep -q "pre-merge-backup-20200101_000000"
}

@test "--tags cleans up new-format pre-merge tags (no -backup- infix)" {
  git -C "${TEST_REPO_DIR}" tag "pre-merge-20200101_000000-12345" HEAD

  run run_script branch_cleanup.sh --tags --execute --older-than 0 --non-interactive
  [ "${status}" -eq 0 ]
  ! git -C "${TEST_REPO_DIR}" tag | grep -q "pre-merge-20200101_000000-12345"
}
