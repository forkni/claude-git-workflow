#!/usr/bin/env bats
# tests/integration/help_flags.bats - --help/-h/unknown flag behavior for all CGW scripts
# Runs: bats tests/integration/help_flags.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

# Public-facing scripts (excludes _common.sh, _config.sh which are sourced, not run)
CGW_SCRIPTS=(
  validate_branches.sh
  fix_lint.sh
  sync_branches.sh
  rollback_merge.sh
  cherry_pick_commits.sh
  merge_with_validation.sh
  install_hooks.sh
  configure.sh
  merge_docs.sh
  commit_enhanced.sh
  check_lint.sh
  push_validated.sh
  create_pr.sh
  create_release.sh
  stash_work.sh
  clean_build.sh
  setup_attributes.sh
  repo_health.sh
  branch_cleanup.sh
  undo_last.sh
  changelog_generate.sh
  bisect_helper.sh
  rebase_safe.sh
)

setup() {
  create_test_repo_with_remote
  setup_mock_bin
  install_mock_gh
  # Provide stub lint tool so scripts that source _config.sh don't fail on missing ruff
  install_mock_lint
}

teardown() {
  cleanup_test_repo
}

# ── --help exits 0 for all scripts ───────────────────────────────────────────

@test "validate_branches.sh --help exits 0" {
  run run_script validate_branches.sh --help
  [ "${status}" -eq 0 ]
}

@test "fix_lint.sh --help exits 0" {
  run run_script fix_lint.sh --help
  [ "${status}" -eq 0 ]
}

@test "sync_branches.sh --help exits 0" {
  run run_script sync_branches.sh --help
  [ "${status}" -eq 0 ]
}

@test "rollback_merge.sh --help exits 0" {
  run run_script rollback_merge.sh --help
  [ "${status}" -eq 0 ]
}

@test "cherry_pick_commits.sh --help exits 0" {
  run run_script cherry_pick_commits.sh --help
  [ "${status}" -eq 0 ]
}

@test "merge_with_validation.sh --help exits 0" {
  run run_script merge_with_validation.sh --help
  [ "${status}" -eq 0 ]
}

@test "install_hooks.sh --help exits 0" {
  run run_script install_hooks.sh --help
  [ "${status}" -eq 0 ]
}

@test "configure.sh --help exits 0" {
  run run_script configure.sh --help
  [ "${status}" -eq 0 ]
}

@test "merge_docs.sh --help exits 0" {
  run run_script merge_docs.sh --help
  [ "${status}" -eq 0 ]
}

@test "commit_enhanced.sh --help exits 0" {
  run run_script commit_enhanced.sh --help
  [ "${status}" -eq 0 ]
}

@test "check_lint.sh --help exits 0" {
  run run_script check_lint.sh --help
  [ "${status}" -eq 0 ]
}

@test "push_validated.sh --help exits 0" {
  run run_script push_validated.sh --help
  [ "${status}" -eq 0 ]
}

@test "create_pr.sh --help exits 0" {
  run run_script create_pr.sh --help
  [ "${status}" -eq 0 ]
}

# ── --help output contains "Usage:" ──────────────────────────────────────────

@test "validate_branches.sh --help prints Usage:" {
  run run_script validate_branches.sh --help
  [[ "${output}" == *"Usage:"* ]] || [[ "${output}" == *"usage:"* ]]
}

@test "commit_enhanced.sh --help prints Usage:" {
  run run_script commit_enhanced.sh --help
  [[ "${output}" == *"Usage:"* ]] || [[ "${output}" == *"usage:"* ]]
}

@test "check_lint.sh --help prints Usage:" {
  run run_script check_lint.sh --help
  [[ "${output}" == *"Usage:"* ]] || [[ "${output}" == *"usage:"* ]]
}

@test "create_pr.sh --help prints Usage:" {
  run run_script create_pr.sh --help
  [[ "${output}" == *"Usage:"* ]] || [[ "${output}" == *"usage:"* ]]
}

@test "push_validated.sh --help prints Usage:" {
  run run_script push_validated.sh --help
  [[ "${output}" == *"Usage:"* ]] || [[ "${output}" == *"usage:"* ]]
}

# ── -h alias works like --help ────────────────────────────────────────────────

@test "commit_enhanced.sh -h exits 0" {
  run run_script commit_enhanced.sh -h
  [ "${status}" -eq 0 ]
}

@test "check_lint.sh -h exits 0" {
  run run_script check_lint.sh -h
  [ "${status}" -eq 0 ]
}

@test "create_pr.sh -h exits 0" {
  run run_script create_pr.sh -h
  [ "${status}" -eq 0 ]
}

@test "push_validated.sh -h exits 0" {
  run run_script push_validated.sh -h
  [ "${status}" -eq 0 ]
}

@test "merge_with_validation.sh -h exits 0" {
  run run_script merge_with_validation.sh -h
  [ "${status}" -eq 0 ]
}

# ── Unknown flag exits 1 ──────────────────────────────────────────────────────

@test "commit_enhanced.sh unknown flag exits 1" {
  run run_script commit_enhanced.sh --foobar
  [ "${status}" -eq 1 ]
}

@test "check_lint.sh unknown flag exits 1" {
  run run_script check_lint.sh --foobar
  [ "${status}" -eq 1 ]
}

@test "create_pr.sh unknown flag exits 1" {
  run run_script create_pr.sh --foobar
  [ "${status}" -eq 1 ]
}

@test "push_validated.sh unknown flag exits 1" {
  run run_script push_validated.sh --foobar
  [ "${status}" -eq 1 ]
}

@test "merge_with_validation.sh unknown flag exits 1" {
  run run_script merge_with_validation.sh --foobar
  [ "${status}" -eq 1 ]
}

@test "rollback_merge.sh unknown flag exits 1" {
  run run_script rollback_merge.sh --foobar
  [ "${status}" -eq 1 ]
}

# ── Unknown flag output contains ERROR ────────────────────────────────────────

@test "commit_enhanced.sh unknown flag prints ERROR" {
  run run_script commit_enhanced.sh --foobar
  [[ "${output}" == *"ERROR"* ]] || [[ "${output}" == *"Unknown"* ]] || [[ "${output}" == *"unknown"* ]]
}

@test "create_pr.sh unknown flag prints ERROR" {
  run run_script create_pr.sh --foobar
  [[ "${output}" == *"ERROR"* ]] || [[ "${output}" == *"Unknown"* ]] || [[ "${output}" == *"unknown"* ]]
}

# ── Newer scripts: --help exits 0 ─────────────────────────────────────────────

@test "create_release.sh --help exits 0" {
  run run_script create_release.sh --help
  [ "${status}" -eq 0 ]
}

@test "stash_work.sh --help exits 0" {
  run run_script stash_work.sh --help
  [ "${status}" -eq 0 ]
}

@test "clean_build.sh --help exits 0" {
  run run_script clean_build.sh --help
  [ "${status}" -eq 0 ]
}

@test "setup_attributes.sh --help exits 0" {
  run run_script setup_attributes.sh --help
  [ "${status}" -eq 0 ]
}

@test "repo_health.sh --help exits 0" {
  run run_script repo_health.sh --help
  [ "${status}" -eq 0 ]
}

@test "branch_cleanup.sh --help exits 0" {
  run run_script branch_cleanup.sh --help
  [ "${status}" -eq 0 ]
}

@test "undo_last.sh --help exits 0" {
  run run_script undo_last.sh --help
  [ "${status}" -eq 0 ]
}

@test "changelog_generate.sh --help exits 0" {
  run run_script changelog_generate.sh --help
  [ "${status}" -eq 0 ]
}

@test "bisect_helper.sh --help exits 0" {
  run run_script bisect_helper.sh --help
  [ "${status}" -eq 0 ]
}

@test "rebase_safe.sh --help exits 0" {
  run run_script rebase_safe.sh --help
  [ "${status}" -eq 0 ]
}

# ── Newer scripts: unknown flag exits 1 ───────────────────────────────────────

@test "create_release.sh unknown flag exits 1" {
  run run_script create_release.sh --foobar
  [ "${status}" -eq 1 ]
}

@test "stash_work.sh unknown flag exits 1" {
  run run_script stash_work.sh --foobar
  [ "${status}" -eq 1 ]
}

@test "clean_build.sh unknown flag exits 1" {
  run run_script clean_build.sh --foobar
  [ "${status}" -eq 1 ]
}

@test "setup_attributes.sh unknown flag exits 1" {
  run run_script setup_attributes.sh --foobar
  [ "${status}" -eq 1 ]
}

@test "repo_health.sh unknown flag exits 1" {
  run run_script repo_health.sh --foobar
  [ "${status}" -eq 1 ]
}

@test "branch_cleanup.sh unknown flag exits 1" {
  run run_script branch_cleanup.sh --foobar
  [ "${status}" -eq 1 ]
}

@test "undo_last.sh unknown flag exits 1" {
  run run_script undo_last.sh --foobar
  [ "${status}" -eq 1 ]
}

@test "changelog_generate.sh unknown flag exits 1" {
  run run_script changelog_generate.sh --foobar
  [ "${status}" -eq 1 ]
}

@test "bisect_helper.sh unknown flag exits 1" {
  run run_script bisect_helper.sh --foobar
  [ "${status}" -eq 1 ]
}

@test "rebase_safe.sh unknown flag exits 1" {
  run run_script rebase_safe.sh --foobar
  [ "${status}" -eq 1 ]
}
