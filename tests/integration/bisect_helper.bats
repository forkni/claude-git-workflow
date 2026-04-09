#!/usr/bin/env bats
# tests/integration/bisect_helper.bats - Integration tests for bisect_helper.sh
# Runs: bats tests/integration/bisect_helper.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo
  setup_mock_bin
  install_mock_lint
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  # Add several commits to make a meaningful bisect range
  for i in 1 2 3 4 5; do
    echo "v${i}" > "${TEST_REPO_DIR}/v${i}.txt"
    git -C "${TEST_REPO_DIR}" add "v${i}.txt"
    git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: commit ${i}"
  done
  # Tag the first commit in the range as a known good baseline
  git -C "${TEST_REPO_DIR}" tag "v0.1.0" HEAD~5
}

teardown() {
  cleanup_test_repo
}

# ── validation ────────────────────────────────────────────────────────────────

@test "--non-interactive without --run exits 1" {
  run run_script bisect_helper.sh --good HEAD~3 --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"--run"* ]] || [[ "${output}" == *"requires"* ]]
}

@test "invalid --good ref exits 1" {
  run run_script bisect_helper.sh --good nonexistent-ref-xyz --non-interactive --run "true"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Invalid"* ]] || [[ "${output}" == *"invalid"* ]]
}

# ── --abort ───────────────────────────────────────────────────────────────────

@test "--abort when no bisect in progress exits 0" {
  run run_script bisect_helper.sh --abort
  [ "${status}" -eq 0 ]
}

# ── --dry-run ─────────────────────────────────────────────────────────────────

@test "--dry-run shows plan without starting bisect" {
  run run_script bisect_helper.sh --good v0.1.0 --dry-run --non-interactive --run "true"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ry run"* ]] || [[ "${output}" == *"Would run"* ]]
  # No bisect session started
  ! git -C "${TEST_REPO_DIR}" bisect log >/dev/null 2>&1
}

# ── auto-detect good ref ──────────────────────────────────────────────────────

@test "auto-detects semver tag as good ref when --good omitted" {
  run run_script bisect_helper.sh --dry-run --non-interactive --run "true"
  [ "${status}" -eq 0 ]
  # The auto-detected ref (v0.1.0) should appear in output
  [[ "${output}" == *"v0.1.0"* ]] || [[ "${output}" == *"Auto-detected"* ]]
}

# ── backup tag ────────────────────────────────────────────────────────────────

@test "automated bisect with --run creates backup tag" {
  # Use 'true' as run command so bisect immediately finds no "bad" commit
  # and terminates (all commits "pass" the test)
  run run_script bisect_helper.sh --good v0.1.0 --non-interactive --run "true"
  # The script may exit 0 or non-zero depending on bisect result, but backup tag must exist
  git -C "${TEST_REPO_DIR}" tag | grep -q "^pre-bisect-"
}

# ── --continue ────────────────────────────────────────────────────────────────

@test "--continue when no bisect in progress shows status and exits 0" {
  run run_script bisect_helper.sh --continue
  [ "${status}" -eq 0 ]
}
