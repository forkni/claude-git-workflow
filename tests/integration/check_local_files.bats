#!/usr/bin/env bats
# tests/integration/check_local_files.bats - Integration tests for check_local_files.sh
# Runs: bats tests/integration/check_local_files.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'

setup() {
  create_test_repo
}

teardown() {
  cleanup_test_repo
}

# Helper: run check_local_files.sh inside the test repo with optional env vars
_run_check() {
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    $*
    bash '${CGW_PROJECT_ROOT}/scripts/git/check_local_files.sh'
  "
}

# ── Clean repo passes ─────────────────────────────────────────────────────────

@test "clean repo with no local-only files exits 0" {
  run _run_check
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"OK"* ]] || [[ "${output}" == *"No local-only"* ]]
}

# ── Tracked local-only file fails ─────────────────────────────────────────────

@test "repo with tracked CLAUDE.md exits 1 and lists the path" {
  echo "# Claude" > "${TEST_REPO_DIR}/CLAUDE.md"
  git -C "${TEST_REPO_DIR}" add CLAUDE.md
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: leak CLAUDE.md (bypassing wrapper)"

  run _run_check 'export CGW_LOCAL_FILES="CLAUDE.md"'
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"CLAUDE.md"* ]]
}

# ── Untracked file does not trigger ───────────────────────────────────────────

@test "untracked CLAUDE.md does not trigger (only tracked files matter)" {
  echo "# Claude" > "${TEST_REPO_DIR}/CLAUDE.md"
  # NOT added to git
  run _run_check 'export CGW_LOCAL_FILES="CLAUDE.md"'
  [ "${status}" -eq 0 ]
}

# ── Exempt entry suppresses match ─────────────────────────────────────────────

@test "tracked CLAUDE.md with matching CGW_LOCAL_FILES_EXEMPT exits 0" {
  echo "# Claude" > "${TEST_REPO_DIR}/CLAUDE.md"
  git -C "${TEST_REPO_DIR}" add CLAUDE.md
  git -C "${TEST_REPO_DIR}" commit --quiet -m "docs: intentional CLAUDE.md"

  run _run_check 'export CGW_LOCAL_FILES="CLAUDE.md"' 'export CGW_LOCAL_FILES_EXEMPT="CLAUDE.md"'
  [ "${status}" -eq 0 ]
}

# ── Directory entry catches files within it ───────────────────────────────────

@test "tracked file inside .claude/ is caught when CGW_LOCAL_FILES='.claude/'" {
  mkdir -p "${TEST_REPO_DIR}/.claude"
  echo "settings" > "${TEST_REPO_DIR}/.claude/settings.local.json"
  git -C "${TEST_REPO_DIR}" add -f .claude/settings.local.json
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: leak .claude/"

  run _run_check 'export CGW_LOCAL_FILES=".claude/"'
  [ "${status}" -eq 1 ]
  [[ "${output}" == *".claude/settings.local.json"* ]]
}

# ── Anchoring: similar-prefix names do not match (bug #6 regression) ──────────

@test "logs.md is not flagged when CGW_LOCAL_FILES='logs/' (anchoring)" {
  echo "# Logs" > "${TEST_REPO_DIR}/logs.md"
  git -C "${TEST_REPO_DIR}" add logs.md
  git -C "${TEST_REPO_DIR}" commit --quiet -m "docs: add logs.md"

  run _run_check 'export CGW_LOCAL_FILES="logs/"'
  [ "${status}" -eq 0 ]
}
