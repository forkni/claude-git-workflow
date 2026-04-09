#!/usr/bin/env bats
# tests/integration/undo_last.bats - Integration tests for undo_last.sh
# Runs: bats tests/integration/undo_last.bats

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

# ── no subcommand / help ──────────────────────────────────────────────────────

@test "no subcommand shows help and exits 0" {
  run run_script undo_last.sh
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]] || [[ "${output}" == *"subcommand"* ]]
}

@test "unknown subcommand exits 1" {
  run run_script undo_last.sh bogus
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Unknown subcommand"* ]] || [[ "${output}" == *"unknown"* ]]
}

# ── commit subcommand ─────────────────────────────────────────────────────────

@test "commit: soft-resets HEAD~1 and keeps changes staged" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  # Add a second commit to undo
  echo "extra" > "${TEST_REPO_DIR}/extra.txt"
  git -C "${TEST_REPO_DIR}" add extra.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: extra commit"
  local commit_before
  commit_before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  run run_script undo_last.sh commit --non-interactive
  [ "${status}" -eq 0 ]

  local commit_after
  commit_after=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)
  # HEAD moved back
  [ "${commit_before}" != "${commit_after}" ]
  # File still staged
  git -C "${TEST_REPO_DIR}" diff --cached --name-only | grep -q "extra.txt"
}

@test "commit: creates pre-undo-commit backup tag" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  echo "extra" > "${TEST_REPO_DIR}/extra.txt"
  git -C "${TEST_REPO_DIR}" add extra.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: extra commit"

  run_script undo_last.sh commit --non-interactive || true

  git -C "${TEST_REPO_DIR}" tag | grep -q "^pre-undo-commit-"
}

@test "commit: refuses to undo initial commit" {
  # Create a repo with only one commit
  local single_commit_repo="${TEST_TMPDIR}/single"
  mkdir -p "${single_commit_repo}"
  git -C "${single_commit_repo}" init --quiet
  git -C "${single_commit_repo}" config user.email "test@example.com"
  git -C "${single_commit_repo}" config user.name "Test User"
  echo "init" > "${single_commit_repo}/README.md"
  git -C "${single_commit_repo}" add README.md
  git -C "${single_commit_repo}" commit --quiet -m "chore: initial"

  (
    cd "${single_commit_repo}" || exit 1
    export SCRIPT_DIR="${CGW_PROJECT_ROOT}/scripts/git"
    export PROJECT_ROOT="${single_commit_repo}"
    run bash "${CGW_PROJECT_ROOT}/scripts/git/undo_last.sh" commit --non-interactive
    [ "${status}" -eq 1 ]
  )
}

@test "commit: --dry-run shows plan without resetting" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  echo "extra" > "${TEST_REPO_DIR}/extra.txt"
  git -C "${TEST_REPO_DIR}" add extra.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: extra commit"
  local commit_before
  commit_before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  run run_script undo_last.sh commit --dry-run --non-interactive
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ry run"* ]] || [[ "${output}" == *"Would run"* ]]

  local commit_after
  commit_after=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)
  [ "${commit_before}" = "${commit_after}" ]
}

# ── unstage subcommand ────────────────────────────────────────────────────────

@test "unstage: removes a file from staging area" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  echo "staged" > "${TEST_REPO_DIR}/staged.txt"
  git -C "${TEST_REPO_DIR}" add staged.txt

  run run_script undo_last.sh unstage staged.txt --non-interactive
  [ "${status}" -eq 0 ]

  # File no longer staged
  ! git -C "${TEST_REPO_DIR}" diff --cached --name-only | grep -q "staged.txt"
}

@test "unstage: no files specified exits 1" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  # Stage a file so the "nothing staged → exit 0" early return is not hit
  echo "staged2" > "${TEST_REPO_DIR}/staged2.txt"
  git -C "${TEST_REPO_DIR}" add staged2.txt

  run run_script undo_last.sh unstage --non-interactive
  [ "${status}" -eq 1 ]
}

@test "unstage: non-staged file is skipped gracefully" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development

  run run_script undo_last.sh unstage nonexistent.txt --non-interactive
  # Exits 0 with "Nothing to unstage" or similar
  [ "${status}" -eq 0 ]
}

# ── discard subcommand ────────────────────────────────────────────────────────

@test "discard: refuses in non-interactive mode" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  echo "modified" >> "${TEST_REPO_DIR}/DEV.md"

  run run_script undo_last.sh discard DEV.md --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"non-interactive"* ]] || [[ "${output}" == *"Refusing"* ]]
}

# ── amend-message subcommand ──────────────────────────────────────────────────

@test "amend-message: updates last commit message" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  # Create a new unpushed commit (development was already pushed in setup)
  echo "new" > "${TEST_REPO_DIR}/new.txt"
  git -C "${TEST_REPO_DIR}" add new.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: original message"

  run run_script undo_last.sh amend-message "fix: corrected message" --non-interactive
  [ "${status}" -eq 0 ]

  git -C "${TEST_REPO_DIR}" log -1 --format="%s" | grep -q "fix: corrected message"
}

@test "amend-message: no message argument exits 1" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development

  run run_script undo_last.sh amend-message --non-interactive
  [ "${status}" -eq 1 ]
}
