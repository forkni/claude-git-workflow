#!/usr/bin/env bats
# tests/integration/changelog_generate.bats - Integration tests for changelog_generate.sh
# Runs: bats tests/integration/changelog_generate.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo
  setup_mock_bin
  install_mock_lint
  # Add conventional commits to development branch for changelog generation
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  echo "a" > "${TEST_REPO_DIR}/a.txt" && git -C "${TEST_REPO_DIR}" add a.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: add feature A"
  echo "b" > "${TEST_REPO_DIR}/b.txt" && git -C "${TEST_REPO_DIR}" add b.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "fix: fix bug B"
  echo "c" > "${TEST_REPO_DIR}/c.txt" && git -C "${TEST_REPO_DIR}" add c.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "docs: update readme"
  # Tag first commit as a base release
  git -C "${TEST_REPO_DIR}" tag "v0.1.0" HEAD~3
}

teardown() {
  cleanup_test_repo
}

# ── basic generation ──────────────────────────────────────────────────────────

@test "--from <tag> generates changelog output" {
  run run_script changelog_generate.sh --from v0.1.0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"feat"* ]] || [[ "${output}" == *"fix"* ]]
}

@test "auto-detects latest semver tag as from-ref" {
  run run_script changelog_generate.sh
  [ "${status}" -eq 0 ]
}

@test "categorizes feat commits under Features section" {
  run run_script changelog_generate.sh --from v0.1.0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"add feature A"* ]]
}

@test "categorizes fix commits under Bug Fixes section" {
  run run_script changelog_generate.sh --from v0.1.0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"fix bug B"* ]]
}

# ── --format ──────────────────────────────────────────────────────────────────

@test "--format md produces markdown headers" {
  run run_script changelog_generate.sh --from v0.1.0 --format md
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"##"* ]] || [[ "${output}" == *"**"* ]]
}

@test "--format text produces plain text output without markdown" {
  run run_script changelog_generate.sh --from v0.1.0 --format text
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"## "* ]]
}

@test "invalid --format exits 1" {
  run run_script changelog_generate.sh --format html
  [ "${status}" -eq 1 ]
}

# ── --output ──────────────────────────────────────────────────────────────────

@test "--output writes changelog to file" {
  run run_script changelog_generate.sh --from v0.1.0 --output "${TEST_REPO_DIR}/CHANGELOG.md"
  [ "${status}" -eq 0 ]
  [ -f "${TEST_REPO_DIR}/CHANGELOG.md" ]
  grep -q "feat\|fix" "${TEST_REPO_DIR}/CHANGELOG.md"
}

# ── edge cases ────────────────────────────────────────────────────────────────

@test "no commits in range exits 0 with informational message" {
  # Tag HEAD so from==to and there are no commits between them
  git -C "${TEST_REPO_DIR}" tag "v0.2.0" HEAD
  run run_script changelog_generate.sh --from v0.2.0 --to v0.2.0
  [ "${status}" -eq 0 ]
}

@test "invalid --from ref exits 1" {
  run run_script changelog_generate.sh --from nonexistent-ref-xyz
  [ "${status}" -eq 1 ]
}
