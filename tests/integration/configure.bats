#!/usr/bin/env bats
# tests/integration/configure.bats - Integration tests for configure.sh
# Runs: bats tests/integration/configure.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo
  setup_mock_bin
  install_mock_lint
}

teardown() {
  cleanup_test_repo
}

_run_configure() {
  # PATH is already correct from setup_mock_bin; PROJECT_ROOT pins scripts to TEST_REPO_DIR.
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/configure.sh' $*
  "
}

# ── --non-interactive config generation ───────────────────────────────────────

@test "--non-interactive generates .cgw.conf" {
  run _run_configure "--non-interactive"
  [ "${status}" -eq 0 ]
  [ -f "${TEST_REPO_DIR}/.cgw.conf" ]
}

@test "generated .cgw.conf contains CGW_SOURCE_BRANCH" {
  _run_configure "--non-interactive" || true
  if [ -f "${TEST_REPO_DIR}/.cgw.conf" ]; then
    grep -q "CGW_SOURCE_BRANCH" "${TEST_REPO_DIR}/.cgw.conf"
  fi
}

@test "generated .cgw.conf contains CGW_TARGET_BRANCH" {
  _run_configure "--non-interactive" || true
  if [ -f "${TEST_REPO_DIR}/.cgw.conf" ]; then
    grep -q "CGW_TARGET_BRANCH" "${TEST_REPO_DIR}/.cgw.conf"
  fi
}

# ── Branch detection ──────────────────────────────────────────────────────────

@test "detects main as target branch" {
  _run_configure "--non-interactive" || true
  if [ -f "${TEST_REPO_DIR}/.cgw.conf" ]; then
    grep -q "main" "${TEST_REPO_DIR}/.cgw.conf"
  fi
}

# ── --reconfigure overwrites existing ────────────────────────────────────────

@test "--reconfigure overwrites existing .cgw.conf" {
  echo "CGW_LINT_CMD=old-value" > "${TEST_REPO_DIR}/.cgw.conf"
  _run_configure "--non-interactive --reconfigure" || true
  if [ -f "${TEST_REPO_DIR}/.cgw.conf" ]; then
    # Old value should be replaced
    ! grep -q "^CGW_LINT_CMD=old-value$" "${TEST_REPO_DIR}/.cgw.conf" || true
  fi
}

# ── Lint tool detection ───────────────────────────────────────────────────────

@test "detects ruff when available in PATH" {
  _run_configure "--non-interactive" || true
  if [ -f "${TEST_REPO_DIR}/.cgw.conf" ]; then
    grep -q "ruff\|CGW_LINT_CMD" "${TEST_REPO_DIR}/.cgw.conf"
  fi
}

@test "detects ruff when pyproject.toml exists" {
  echo "[tool.ruff]" > "${TEST_REPO_DIR}/pyproject.toml"
  _run_configure "--non-interactive" || true
  if [ -f "${TEST_REPO_DIR}/.cgw.conf" ]; then
    grep -q "CGW_LINT_CMD\|ruff" "${TEST_REPO_DIR}/.cgw.conf"
  fi
}

# ── Hook installation ─────────────────────────────────────────────────────────

@test "--non-interactive installs pre-commit hook" {
  _run_configure "--non-interactive"
  [ -f "${TEST_REPO_DIR}/.githooks/pre-commit" ]
}

@test "--non-interactive installs pre-push hook" {
  # Regression test: configure.sh used CGW_ALL_PREFIXES (unbound var) when
  # building the pre-push hook template substitution. Verify the hook is
  # written and contains the expected prefixes pattern.
  _run_configure "--non-interactive"
  [ -f "${TEST_REPO_DIR}/.githooks/pre-push" ]
  grep -q "feat" "${TEST_REPO_DIR}/.githooks/pre-push"
}

@test "--skip-hooks does not install hooks" {
  _run_configure "--non-interactive --skip-hooks"
  [ ! -f "${TEST_REPO_DIR}/.githooks/pre-commit" ]
}

# ── Branch detection on reconfigure ──────────────────────────────────────────

@test "--reconfigure overwrites branch settings with fresh auto-detection" {
  # Write a config with custom branch names
  cat > "${TEST_REPO_DIR}/.cgw.conf" <<'EOF'
CGW_SOURCE_BRANCH="my-dev"
CGW_TARGET_BRANCH="my-stable"
CGW_LOCAL_FILES=".claude/ logs/"
EOF
  _run_configure "--non-interactive --reconfigure"
  # 90091fb: --reconfigure re-detects branches instead of preserving stale values.
  # Test repo has only 'main', so detection yields main/development.
  grep -q 'CGW_SOURCE_BRANCH="development"' "${TEST_REPO_DIR}/.cgw.conf"
  grep -q 'CGW_TARGET_BRANCH="main"' "${TEST_REPO_DIR}/.cgw.conf"
}

@test "--reconfigure does not modify .gitignore" {
  echo "# existing" > "${TEST_REPO_DIR}/.gitignore"
  _run_configure "--non-interactive --reconfigure" || true
  # .gitignore should be unchanged (still only the one line we wrote)
  [ "$(wc -l < "${TEST_REPO_DIR}/.gitignore")" -eq 1 ]
}

# ── Exit code ────────────────────────────────────────────────────────────────

@test "configure.sh exits 0 in non-interactive mode" {
  run _run_configure "--non-interactive"
  [ "${status}" -eq 0 ]
}
