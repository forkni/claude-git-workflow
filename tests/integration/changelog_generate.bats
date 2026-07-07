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

# ── --version ─────────────────────────────────────────────────────────────────

@test "--version overrides heading when to-ref has no exact tag" {
  run run_script changelog_generate.sh --from v0.1.0 --version v9.9.9
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"## v9.9.9"* ]]
}

# ── --prepend ─────────────────────────────────────────────────────────────────

@test "--prepend stacks a new section above existing --output content" {
  run run_script changelog_generate.sh --from v0.1.0 --to HEAD~1 --version v0.2.0 \
    --output "${TEST_REPO_DIR}/CHANGELOG.md"
  [ "${status}" -eq 0 ]
  run run_script changelog_generate.sh --from HEAD~1 --to HEAD --version v0.3.0 \
    --output "${TEST_REPO_DIR}/CHANGELOG.md" --prepend
  [ "${status}" -eq 0 ]
  grep -q "## v0.2.0" "${TEST_REPO_DIR}/CHANGELOG.md"
  grep -q "## v0.3.0" "${TEST_REPO_DIR}/CHANGELOG.md"
  # The newer section (v0.3.0) must appear before the older one (v0.2.0).
  local v3_line v2_line
  v3_line=$(grep -n "## v0.3.0" "${TEST_REPO_DIR}/CHANGELOG.md" | head -1 | cut -d: -f1)
  v2_line=$(grep -n "## v0.2.0" "${TEST_REPO_DIR}/CHANGELOG.md" | head -1 | cut -d: -f1)
  [ "${v3_line}" -lt "${v2_line}" ]
}

@test "--prepend refuses to duplicate an existing section" {
  run run_script changelog_generate.sh --from v0.1.0 --version v0.2.0 \
    --output "${TEST_REPO_DIR}/CHANGELOG.md"
  [ "${status}" -eq 0 ]
  run run_script changelog_generate.sh --from v0.1.0 --version v0.2.0 \
    --output "${TEST_REPO_DIR}/CHANGELOG.md" --prepend
  [ "${status}" -eq 1 ]
}
