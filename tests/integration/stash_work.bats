#!/usr/bin/env bats
# tests/integration/stash_work.bats - Integration tests for stash_work.sh
# Runs: bats tests/integration/stash_work.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo
  setup_mock_bin
  install_mock_lint
  git -C "${TEST_REPO_DIR}" checkout --quiet development
}

teardown() {
  cleanup_test_repo
}

# ── no command ────────────────────────────────────────────────────────────────

@test "no command shows usage and exits 0" {
  run run_script stash_work.sh
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]] || [[ "${output}" == *"push"* ]]
}

@test "unknown command exits 1" {
  run run_script stash_work.sh frobnicate
  [ "${status}" -eq 1 ]
}

# ── push ──────────────────────────────────────────────────────────────────────

@test "push stashes uncommitted changes" {
  echo "wip" > "${TEST_REPO_DIR}/wip.txt"
  git -C "${TEST_REPO_DIR}" add wip.txt

  run run_script stash_work.sh push "wip: test stash"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Stash created"* ]] || [[ "${output}" == *"created"* ]]
  # Working tree is clean
  git -C "${TEST_REPO_DIR}" diff --quiet
  git -C "${TEST_REPO_DIR}" diff --cached --quiet
}

@test "push stashes untracked files by default" {
  echo "untracked" > "${TEST_REPO_DIR}/untracked.txt"

  run run_script stash_work.sh push "wip: untracked"
  [ "${status}" -eq 0 ]
  # Untracked file is gone from working tree (stashed)
  [ ! -f "${TEST_REPO_DIR}/untracked.txt" ]
}

@test "push on clean tree exits 0 with informational message" {
  run run_script stash_work.sh push
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]] || [[ "${output}" == *"Nothing to stash"* ]]
}

# ── pop ───────────────────────────────────────────────────────────────────────

@test "pop restores stashed changes" {
  echo "popped" > "${TEST_REPO_DIR}/popped.txt"
  git -C "${TEST_REPO_DIR}" add popped.txt
  run_script stash_work.sh push "wip: to pop"

  run run_script stash_work.sh pop
  [ "${status}" -eq 0 ]
  [ -f "${TEST_REPO_DIR}/popped.txt" ]
}

@test "pop with no stashes exits 0 gracefully" {
  run run_script stash_work.sh pop
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No stashes"* ]] || [[ "${output}" == *"no stash"* ]]
}

# ── list ──────────────────────────────────────────────────────────────────────

@test "list shows stashes when present" {
  echo "listed" > "${TEST_REPO_DIR}/listed.txt"
  git -C "${TEST_REPO_DIR}" add listed.txt
  run_script stash_work.sh push "wip: listed"

  run run_script stash_work.sh list
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"stash"* ]]
}

@test "list exits 0 when no stashes" {
  run run_script stash_work.sh list
  [ "${status}" -eq 0 ]
}

# ── drop ──────────────────────────────────────────────────────────────────────

@test "drop removes a specific stash non-interactively" {
  echo "drop-me" > "${TEST_REPO_DIR}/drop.txt"
  git -C "${TEST_REPO_DIR}" add drop.txt
  run_script stash_work.sh push "wip: to drop"

  # Verify stash exists
  stash_ref="$(git -C "${TEST_REPO_DIR}" stash list | head -1 | cut -d: -f1)"
  run run_script stash_work.sh drop "${stash_ref}" --yes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"dropped"* ]] || [[ "${output}" == *"Dropped"* ]]
  # Stash list should now be empty
  [[ -z "$(git -C "${TEST_REPO_DIR}" stash list)" ]]
}

@test "drop exits 0 when no stashes" {
  run run_script stash_work.sh drop "stash@{0}" --yes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No stashes"* ]] || [[ "${output}" == *"no stash"* ]]
}

# ── clear ─────────────────────────────────────────────────────────────────────

@test "clear removes all stashes non-interactively" {
  # Create two stashes
  for i in 1 2; do
    echo "clear-${i}" > "${TEST_REPO_DIR}/clear${i}.txt"
    git -C "${TEST_REPO_DIR}" add "clear${i}.txt"
    run_script stash_work.sh push "wip: clear test ${i}"
  done

  run run_script stash_work.sh clear --yes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"cleared"* ]] || [[ "${output}" == *"Cleared"* ]]
  [[ -z "$(git -C "${TEST_REPO_DIR}" stash list)" ]]
}

@test "clear exits 0 when no stashes" {
  run run_script stash_work.sh clear --yes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No stashes"* ]] || [[ "${output}" == *"no stash"* ]]
}
