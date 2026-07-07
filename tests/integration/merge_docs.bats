#!/usr/bin/env bats
# tests/integration/merge_docs.bats - Integration tests for merge_docs.sh
# Runs: bats tests/integration/merge_docs.bats

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

_run_merge_docs() {
  # SOURCE has no built-in default (an explicit per-invocation choice -- see _config.sh);
  # create_test_repo always produces a real 'development' branch, so default to it here
  # the same way a real configure.sh run would (mirrors _run_merge in merge_validation.bats).
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_SOURCE_BRANCH='development'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    $2
    bash '${CGW_PROJECT_ROOT}/scripts/git/merge_docs.sh' $1
  "
}

# Commit docs on development: one shared doc + one local-only doc.
_seed_docs_on_dev() {
  mkdir -p "${TEST_REPO_DIR}/docs"
  echo "guide v2" > "${TEST_REPO_DIR}/docs/guide.md"
  echo "secret notes" > "${TEST_REPO_DIR}/docs/private.md"
  git -C "${TEST_REPO_DIR}" -c core.hooksPath=/dev/null add docs/
  git -C "${TEST_REPO_DIR}" -c core.hooksPath=/dev/null commit --quiet -m "docs: add guide and private notes"
}

# ── clean docs-only merge (regression) ────────────────────────────────────────

@test "docs-only merge commits docs/ changes to target" {
  _seed_docs_on_dev
  run _run_merge_docs "--non-interactive" ""
  [ "${status}" -eq 0 ]
  git -C "${TEST_REPO_DIR}" cat-file -e "main:docs/guide.md"
}

# ── local-only file guard (G2) ────────────────────────────────────────────────

@test "docs merge excludes a local-only file under docs/ (new on target)" {
  _seed_docs_on_dev
  run _run_merge_docs "--non-interactive" "export CGW_LOCAL_FILES='docs/private.md'"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Excluding local-only file"* ]]
  # Shared doc merged; local-only doc NOT in target history.
  git -C "${TEST_REPO_DIR}" cat-file -e "main:docs/guide.md"
  ! git -C "${TEST_REPO_DIR}" cat-file -e "main:docs/private.md" 2>/dev/null
}

@test "docs merge with ONLY local-only changes exits 0 without a commit" {
  mkdir -p "${TEST_REPO_DIR}/docs"
  echo "secret" > "${TEST_REPO_DIR}/docs/private.md"
  git -C "${TEST_REPO_DIR}" -c core.hooksPath=/dev/null add docs/
  git -C "${TEST_REPO_DIR}" -c core.hooksPath=/dev/null commit --quiet -m "docs: private only"

  local main_before
  main_before=$(git -C "${TEST_REPO_DIR}" rev-parse main)

  run _run_merge_docs "--non-interactive" "export CGW_LOCAL_FILES='docs/private.md'"
  [ "${status}" -eq 0 ]
  # Target must not have advanced (nothing left to commit after exclusion).
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse main)" = "${main_before}" ]
  ! git -C "${TEST_REPO_DIR}" cat-file -e "main:docs/private.md" 2>/dev/null
}

@test "docs merge excludes a local-only file that the target tracks (restores HEAD version)" {
  # Target tracks docs/private.md with v1; source updates it to v2.
  git -C "${TEST_REPO_DIR}" checkout --quiet main
  mkdir -p "${TEST_REPO_DIR}/docs"
  echo "private v1" > "${TEST_REPO_DIR}/docs/private.md"
  git -C "${TEST_REPO_DIR}" -c core.hooksPath=/dev/null add docs/private.md
  git -C "${TEST_REPO_DIR}" -c core.hooksPath=/dev/null commit --quiet -m "docs: private v1 on target"
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  git -C "${TEST_REPO_DIR}" merge --quiet main >/dev/null 2>&1 || true
  mkdir -p "${TEST_REPO_DIR}/docs"
  echo "private v2" > "${TEST_REPO_DIR}/docs/private.md"
  echo "guide v2" > "${TEST_REPO_DIR}/docs/guide.md"
  git -C "${TEST_REPO_DIR}" -c core.hooksPath=/dev/null add docs/
  git -C "${TEST_REPO_DIR}" -c core.hooksPath=/dev/null commit --quiet -m "docs: update private and guide"

  run _run_merge_docs "--non-interactive" "export CGW_LOCAL_FILES='docs/private.md'"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Excluding local-only file"* ]]
  # Target keeps v1 of the local-only file; guide merged.
  [ "$(git -C "${TEST_REPO_DIR}" show main:docs/private.md)" = "private v1" ]
  git -C "${TEST_REPO_DIR}" cat-file -e "main:docs/guide.md"
}
