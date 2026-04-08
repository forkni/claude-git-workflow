#!/usr/bin/env bash
# tests/helpers/setup.bash - Shared test repo setup/teardown helpers
# Usage: load '../helpers/setup'  (from within a .bats file)

# Absolute path to the real project scripts (tests run real scripts against fake repos)
export CGW_PROJECT_ROOT
CGW_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ── Temp directory management ─────────────────────────────────────────────────

# create_temp_dir — set BATS_TEST_TMPDIR to an isolated temp dir
create_temp_dir() {
  # GNU mktemp needs no template; BSD mktemp requires -t. Try GNU first.
  TEST_TMPDIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'cgw.XXXXXX')"
  export TEST_TMPDIR
}

cleanup_temp_dir() {
  [[ -n "${TEST_TMPDIR:-}" ]] && rm -rf "${TEST_TMPDIR}"
}

# ── Bare remote repo helper ───────────────────────────────────────────────────

# create_bare_remote <dir>
# Creates a bare git repo at <dir>, used as the `origin` remote.
create_bare_remote() {
  local remote_dir="$1"
  git init --bare "${remote_dir}" --quiet
}

# ── Full test repo ─────────────────────────────────────────────────────────────

# create_test_repo
# Creates a git repo at $TEST_TMPDIR/repo with:
#   - Configured user identity
#   - Initial commit on `main`
#   - `development` branch with one extra commit
#   - Sets TEST_REPO_DIR
create_test_repo() {
  create_temp_dir

  TEST_REPO_DIR="${TEST_TMPDIR}/repo"
  export TEST_REPO_DIR
  mkdir -p "${TEST_REPO_DIR}/scripts/git"

  git -C "${TEST_REPO_DIR}" init --quiet
  git -C "${TEST_REPO_DIR}" config user.email "test@example.com"
  git -C "${TEST_REPO_DIR}" config user.name "Test User"
  git -C "${TEST_REPO_DIR}" config core.autocrlf false

  # Initial commit on main
  echo "# Test Repo" > "${TEST_REPO_DIR}/README.md"
  git -C "${TEST_REPO_DIR}" add README.md
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: initial commit"
  git -C "${TEST_REPO_DIR}" checkout --quiet -b main 2>/dev/null || \
    git -C "${TEST_REPO_DIR}" branch -m main 2>/dev/null || true

  # development branch with extra commit
  git -C "${TEST_REPO_DIR}" checkout --quiet -b development
  echo "# Dev note" > "${TEST_REPO_DIR}/DEV.md"
  git -C "${TEST_REPO_DIR}" add DEV.md
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: dev commit"

  git -C "${TEST_REPO_DIR}" checkout --quiet main
}

# create_test_repo_with_remote
# Same as create_test_repo but adds a local bare repo as `origin`
# and pushes both branches, so remote tracking refs exist.
create_test_repo_with_remote() {
  create_test_repo

  TEST_REMOTE_DIR="${TEST_TMPDIR}/remote.git"
  export TEST_REMOTE_DIR
  create_bare_remote "${TEST_REMOTE_DIR}"

  git -C "${TEST_REPO_DIR}" remote add origin "${TEST_REMOTE_DIR}"
  git -C "${TEST_REPO_DIR}" push --quiet --all origin
  git -C "${TEST_REPO_DIR}" push --quiet --set-upstream origin main
  git -C "${TEST_REPO_DIR}" push --quiet --set-upstream origin development
}

# cleanup_test_repo — remove all temp dirs
cleanup_test_repo() {
  cleanup_temp_dir
}

# ── Script path helpers ────────────────────────────────────────────────────────

# script_path <name>  — returns absolute path to scripts/git/<name>
script_path() {
  echo "${CGW_PROJECT_ROOT}/scripts/git/$1"
}

# run_script <name> [args...]
# Runs a CGW script with SCRIPT_DIR pointing at the real scripts/git/ directory.
# The current directory is TEST_REPO_DIR (if set), or the temp dir.
run_script() {
  local script_name="$1"
  shift
  local script_file
  script_file="$(script_path "${script_name}")"

  local work_dir="${TEST_REPO_DIR:-${TEST_TMPDIR:-$(pwd)}}"

  (
    cd "${work_dir}" || exit 1
    export SCRIPT_DIR="${CGW_PROJECT_ROOT}/scripts/git"
    bash "${script_file}" "$@"
  )
}
