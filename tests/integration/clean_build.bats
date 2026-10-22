#!/usr/bin/env bats
# tests/integration/clean_build.bats - Integration tests for clean_build.sh
# Runs: bats tests/integration/clean_build.bats
#
# clean_build.sh deletes whatever its find patterns match. A tracked file or
# directory that happens to match (crash.py, Backup/, build/, a fixture named
# *.bak) is source, not an artifact, so it must be skipped and reported.

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo
  setup_mock_bin
  git -C "${TEST_REPO_DIR}" checkout --quiet development

  # Tracked paths that match a cleanup pattern but are real source.
  mkdir -p "${TEST_REPO_DIR}/Backup" "${TEST_REPO_DIR}/build" "${TEST_REPO_DIR}/fixtures" "${TEST_REPO_DIR}/pkg.egg-info"
  echo "print('x')" >"${TEST_REPO_DIR}/crash.py"
  echo "keep" >"${TEST_REPO_DIR}/Backup/notes.txt"
  echo "keep" >"${TEST_REPO_DIR}/build/keep.txt"
  echo "keep" >"${TEST_REPO_DIR}/fixtures/sample.bak"
  echo "keep" >"${TEST_REPO_DIR}/fixtures/a[1].tmp"
  echo "keep" >"${TEST_REPO_DIR}/pkg.egg-info/PKG-INFO"
  git -C "${TEST_REPO_DIR}" add -A
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: add tracked lookalikes"
}

teardown() {
  cleanup_test_repo
}

# make_artifacts - untracked files and directories the script is meant to clean
make_artifacts() {
  mkdir -p "${TEST_REPO_DIR}/src/__pycache__" "${TEST_REPO_DIR}/shaders"
  echo "x" >"${TEST_REPO_DIR}/src/__pycache__/mod.cpython-312.pyc"
  echo "x" >"${TEST_REPO_DIR}/scratch.tmp"
  echo "x" >"${TEST_REPO_DIR}/project.toe.bak"
  echo "x" >"${TEST_REPO_DIR}/shaders/frag.spv"
}

@test "unknown flag exits 1" {
  run run_script clean_build.sh --bogus
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Unknown flag"* ]]
}

@test "default run is a dry run: lists artifacts, deletes nothing" {
  make_artifacts
  run run_script clean_build.sh --all
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DRY RUN"* ]]
  [[ "${output}" == *"scratch.tmp"* ]]
  [ -f "${TEST_REPO_DIR}/scratch.tmp" ]
  [ -d "${TEST_REPO_DIR}/src/__pycache__" ]
  [ -f "${TEST_REPO_DIR}/project.toe.bak" ]
  [ -f "${TEST_REPO_DIR}/shaders/frag.spv" ]
}

@test "--execute removes untracked artifacts" {
  make_artifacts
  run run_script clean_build.sh --all --execute
  [ "${status}" -eq 0 ]
  [ ! -e "${TEST_REPO_DIR}/scratch.tmp" ]
  [ ! -e "${TEST_REPO_DIR}/src/__pycache__" ]
  [ ! -e "${TEST_REPO_DIR}/project.toe.bak" ]
  [ ! -e "${TEST_REPO_DIR}/shaders/frag.spv" ]
  [[ "${output}" == *"Cleaned 4 item(s)"* ]]
}

@test "--execute keeps tracked files and directories that match a pattern" {
  run run_script clean_build.sh --all --execute
  [ "${status}" -eq 0 ]
  [ -f "${TEST_REPO_DIR}/crash.py" ]
  [ -f "${TEST_REPO_DIR}/Backup/notes.txt" ]
  [ -f "${TEST_REPO_DIR}/build/keep.txt" ]
  [ -f "${TEST_REPO_DIR}/fixtures/sample.bak" ]
  [ -f "${TEST_REPO_DIR}/pkg.egg-info/PKG-INFO" ]
}

@test "tracked paths are reported as [SKIP] tracked, in dry-run and execute" {
  run run_script clean_build.sh --all
  [[ "${output}" == *"[SKIP] tracked: ./crash.py"* ]]
  [[ "${output}" == *"[SKIP] tracked: ./fixtures/sample.bak"* ]]
  [[ "${output}" == *"[SKIP] tracked: ./Backup"* ]]
  [[ "${output}" == *"[SKIP] tracked: build"* ]]

  run run_script clean_build.sh --all --execute
  [[ "${output}" == *"[SKIP] tracked: ./crash.py"* ]]
}

@test "skipped tracked paths are not counted as cleaned" {
  run run_script clean_build.sh --all --execute
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Nothing to clean"* ]]
}

@test "a directory with tracked content is skipped whole, untracked files inside survive" {
  echo "obj" >"${TEST_REPO_DIR}/build/out.o"
  run run_script clean_build.sh --all --execute
  [ "${status}" -eq 0 ]
  [ -f "${TEST_REPO_DIR}/build/out.o" ]
  [ -f "${TEST_REPO_DIR}/build/keep.txt" ]
}

@test "glob characters in a tracked file name are matched literally" {
  # a[1].tmp is tracked; a1.tmp (untracked) must not be mistaken for it and vice versa
  echo "x" >"${TEST_REPO_DIR}/a1.tmp"
  run run_script clean_build.sh --all --execute
  [ "${status}" -eq 0 ]
  [ -f "${TEST_REPO_DIR}/fixtures/a[1].tmp" ]
  [ ! -e "${TEST_REPO_DIR}/a1.tmp" ]
}

@test "a file that becomes untracked is cleaned on the next run" {
  git -C "${TEST_REPO_DIR}" rm -q --cached fixtures/sample.bak
  run run_script clean_build.sh --all --execute
  [ "${status}" -eq 0 ]
  [ ! -e "${TEST_REPO_DIR}/fixtures/sample.bak" ]
  [ -f "${TEST_REPO_DIR}/crash.py" ]
}
