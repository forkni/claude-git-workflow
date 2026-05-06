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

# ── Conflict resolution: UU (drift-parity with merge) ────────────────────────

@test "UU conflict: cherry-pick exits 1 with same content-conflict message as merge" {
  # development modifies conflict.txt; main also independently changed the same line
  git -C "${TEST_REPO_DIR}" checkout main
  printf 'original line\n' > "${TEST_REPO_DIR}/conflict.txt"
  git -C "${TEST_REPO_DIR}" add conflict.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: add conflict.txt"

  git -C "${TEST_REPO_DIR}" checkout development
  git -C "${TEST_REPO_DIR}" merge main --quiet --no-ff -m "chore: sync conflict.txt"
  printf 'dev modified line\n' > "${TEST_REPO_DIR}/conflict.txt"
  git -C "${TEST_REPO_DIR}" add conflict.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: dev modifies conflict.txt"
  local pick_commit
  pick_commit=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  git -C "${TEST_REPO_DIR}" checkout main
  printf 'main modified line\n' > "${TEST_REPO_DIR}/conflict.txt"
  git -C "${TEST_REPO_DIR}" add conflict.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "fix: main modifies conflict.txt"

  git -C "${TEST_REPO_DIR}" checkout development
  run run_script cherry_pick_commits.sh --commit "${pick_commit}" --non-interactive
  [ "${status}" -eq 1 ]
  # Must use the same per-category message as merge_with_validation.sh (drift fix)
  [[ "${output}" == *"Content conflicts require manual resolution"* ]]
}

# ── Conflict resolution: DU (auto-resolve, user must --continue) ─────────────

@test "DU conflict: cherry-pick auto-resolves and exits 1 with --continue hint" {
  # main deleted shared.txt; cherry-picked commit modifies it (DU: deleted by us)
  git -C "${TEST_REPO_DIR}" checkout main
  printf 'shared content\n' > "${TEST_REPO_DIR}/shared.txt"
  git -C "${TEST_REPO_DIR}" add shared.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: add shared.txt"

  git -C "${TEST_REPO_DIR}" checkout development
  git -C "${TEST_REPO_DIR}" merge main --quiet --no-ff -m "chore: sync shared.txt"
  printf 'shared content\ndev added\n' > "${TEST_REPO_DIR}/shared.txt"
  git -C "${TEST_REPO_DIR}" add shared.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: dev modifies shared.txt"
  local pick_commit
  pick_commit=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  git -C "${TEST_REPO_DIR}" checkout main
  git -C "${TEST_REPO_DIR}" rm shared.txt --quiet
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: main deletes shared.txt"

  git -C "${TEST_REPO_DIR}" checkout development
  run run_script cherry_pick_commits.sh --commit "${pick_commit}" --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"--continue"* ]]
  [[ "${output}" == *"Auto-resolved"* ]] || [[ "${output}" == *"auto-resolved"* ]]
}
