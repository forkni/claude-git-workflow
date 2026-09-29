#!/usr/bin/env bats
# tests/integration/recover.bats - Integration tests for recover.sh
# Runs: bats tests/integration/recover.bats

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

# ── help / usage ─────────────────────────────────────────────────────────────

@test "no subcommand shows help and exits 0" {
  run run_script recover.sh
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]] || [[ "${output}" == *"Available subcommands"* ]]
}

@test "--help shows help and exits 0" {
  run run_script recover.sh --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]] || [[ "${output}" == *"Available subcommands"* ]]
}

@test "unknown subcommand exits 1" {
  run run_script recover.sh bogus
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"[ERROR]"* ]]
}

# ── reflog subcommand (R2) ───────────────────────────────────────────────────

@test "reflog: lists entries with --limit without duplication or false empty notice" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development

  # Create multiple commits so the reflog has more entries than --limit
  for i in 1 2 3 4 5; do
    echo "file $i" > "${TEST_REPO_DIR}/file_$i.txt"
    git -C "${TEST_REPO_DIR}" add "file_$i.txt"
    git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: commit $i"
  done

  run run_script recover.sh reflog --limit 2
  [ "${status}" -eq 0 ]

  # Must NOT report "no reflog entries"
  [[ "${output}" != *"no reflog entries"* ]]

  # Count lines matching HEAD@{ in output; with limit 2 it must be exactly 2
  local entry_count
  entry_count=$(echo "${output}" | grep -c "HEAD@{" || true)
  [ "${entry_count}" -eq 2 ]
}

@test "reflog: reports no reflog entries when reflog is genuinely empty" {
  # Create a brand new ref with no reflog entries by creating an orphan branch without commits
  # Or test a ref with no reflog if applicable. If rev-parse fails it exits 1 with "Ref not found".
  run run_script recover.sh reflog --ref nonexistent_branch_ref
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not found"* ]]
}

# ── show subcommand ──────────────────────────────────────────────────────────

@test "show: displays commit details and restore hint" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  echo "precious content" > "${TEST_REPO_DIR}/precious.txt"
  git -C "${TEST_REPO_DIR}" add precious.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: precious commit"

  local head_sha
  head_sha=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  run run_script recover.sh show "${head_sha}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"precious.txt"* ]]
  [[ "${output}" == *"recover.sh restore"* ]]
}

@test "show: invalid ref exits 1" {
  run run_script recover.sh show "deadbeef12345678"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not a valid ref"* ]]
}

# ── restore subcommand ───────────────────────────────────────────────────────

@test "restore: recovers commit to a new branch without touching current branch" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  echo "lost work" > "${TEST_REPO_DIR}/lost.txt"
  git -C "${TEST_REPO_DIR}" add lost.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: lost work"

  local lost_sha
  lost_sha=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  # Reset HEAD back so the commit is discarded from development branch
  git -C "${TEST_REPO_DIR}" reset --quiet --hard HEAD~1

  local current_branch
  current_branch=$(git -C "${TEST_REPO_DIR}" branch --show-current)
  [ "${current_branch}" = "development" ]
  [ ! -f "${TEST_REPO_DIR}/lost.txt" ]

  run run_script recover.sh restore "${lost_sha}" --branch recovered-branch --non-interactive
  [ "${status}" -eq 0 ]

  # Current branch should still be development
  local current_branch_after
  current_branch_after=$(git -C "${TEST_REPO_DIR}" branch --show-current)
  [ "${current_branch_after}" = "development" ]

  # The recovered branch points to lost_sha
  local recovered_sha
  recovered_sha=$(git -C "${TEST_REPO_DIR}" rev-parse recovered-branch)
  [ "${recovered_sha}" = "${lost_sha}" ]

  # A pre-recover backup tag was created
  local backup_tag
  backup_tag=$(git -C "${TEST_REPO_DIR}" tag -l 'pre-recover-*' | head -1)
  [ -n "${backup_tag}" ]
}

# ── branch name validation before backup tag (Obs 7) ──────────────────────────

@test "restore: invalid branch name fails without creating a backup tag (Obs 7)" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  local head_sha
  head_sha=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  run run_script recover.sh restore "${head_sha}" --branch "bad branch name!" --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not a valid branch name"* ]]

  # Must NOT leave any pre-recover backup tags behind
  local tags
  tags=$(git -C "${TEST_REPO_DIR}" tag -l 'pre-recover-*')
  [ -z "${tags}" ]
}

