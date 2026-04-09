#!/usr/bin/env bats
# tests/integration/cherry_pick.bats - Integration tests for cherry_pick_commits.sh
# Runs: bats tests/integration/cherry_pick.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo_with_remote
  setup_mock_bin
  install_mock_lint
  # Start on development — which has one unique commit ("feat: dev commit") over main
  git -C "${TEST_REPO_DIR}" checkout --quiet development
}

teardown() {
  cleanup_test_repo
}

# ── --non-interactive requires --commit ───────────────────────────────────────

@test "--non-interactive without --commit exits 1" {
  run run_script cherry_pick_commits.sh --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"--commit"* ]] || [[ "${output}" == *"required"* ]]
}

# ── --dry-run ─────────────────────────────────────────────────────────────────

@test "--dry-run shows commit details without cherry-picking" {
  local dev_commit
  dev_commit=$(git -C "${TEST_REPO_DIR}" log development --oneline -1 | awk '{print $1}')

  run run_script cherry_pick_commits.sh --commit "${dev_commit}" --dry-run --non-interactive
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ry run"* ]] || [[ "${output}" == *"DRY"* ]] || [[ "${output}" == *"Dry"* ]]
  # We should still be on development (or main — no actual cherry-pick)
}

# ── successful cherry-pick ────────────────────────────────────────────────────

@test "--commit <hash> --non-interactive cherry-picks commit to target branch" {
  # Get the unique dev commit hash
  local dev_commit
  dev_commit=$(git -C "${TEST_REPO_DIR}" log development --oneline --no-merges \
    | grep -v "$(git -C "${TEST_REPO_DIR}" log main --oneline | head -1 | awk '{print $1}')" \
    | head -1 | awk '{print $1}')

  run run_script cherry_pick_commits.sh --commit "${dev_commit}" --non-interactive
  [ "${status}" -eq 0 ]

  # Commit should now be on main
  git -C "${TEST_REPO_DIR}" log main --oneline | grep -q "dev commit"
}

@test "cherry-pick creates a backup tag" {
  local dev_commit
  dev_commit=$(git -C "${TEST_REPO_DIR}" log development --oneline -1 | awk '{print $1}')

  run_script cherry_pick_commits.sh --commit "${dev_commit}" --non-interactive || true

  git -C "${TEST_REPO_DIR}" tag | grep -q "^pre-cherry-pick-"
}

# ── invalid commit hash ───────────────────────────────────────────────────────

@test "invalid commit hash exits 1" {
  run run_script cherry_pick_commits.sh --commit "deadbeef1234567890" --non-interactive
  [ "${status}" -eq 1 ]
}
