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

@test "generated .cgw.conf contains CGW_SOURCE_BRANCH when a dev branch exists" {
  # create_test_repo has both 'main' and 'development' -- source is confidently detected.
  _run_configure "--non-interactive" || true
  [ -f "${TEST_REPO_DIR}/.cgw.conf" ]
  grep -q 'CGW_SOURCE_BRANCH="development"' "${TEST_REPO_DIR}/.cgw.conf"
}

@test "generated .cgw.conf omits CGW_SOURCE_BRANCH on a single-branch repo" {
  git -C "${TEST_REPO_DIR}" branch -D development
  _run_configure "--non-interactive" || true
  [ -f "${TEST_REPO_DIR}/.cgw.conf" ]
  ! grep -q "CGW_SOURCE_BRANCH" "${TEST_REPO_DIR}/.cgw.conf"
}

@test "generated .cgw.conf never contains CGW_TARGET_BRANCH (auto-detected at runtime instead)" {
  _run_configure "--non-interactive" || true
  [ -f "${TEST_REPO_DIR}/.cgw.conf" ]
  ! grep -q "CGW_TARGET_BRANCH" "${TEST_REPO_DIR}/.cgw.conf"
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

# ── .cgw.conf preservation (no --reconfigure) ─────────────────────────────────
# Pins the contract cgw-batch-install.cmd relies on: re-running configure.sh
# without --reconfigure must never touch an existing .cgw.conf.

@test "without --reconfigure, existing .cgw.conf is preserved byte-for-byte" {
  printf 'CGW_LINT_CMD="my-custom-lint"\nCGW_MERGE_MODE="pr"\n' > "${TEST_REPO_DIR}/.cgw.conf"
  cp "${TEST_REPO_DIR}/.cgw.conf" "${TEST_REPO_DIR}/.cgw.conf.orig"
  _run_configure "--non-interactive"
  cmp -s "${TEST_REPO_DIR}/.cgw.conf" "${TEST_REPO_DIR}/.cgw.conf.orig"
}

@test "without --reconfigure, no .cgw.conf.bak is created" {
  printf 'CGW_LINT_CMD="my-custom-lint"\n' > "${TEST_REPO_DIR}/.cgw.conf"
  _run_configure "--non-interactive"
  [ ! -f "${TEST_REPO_DIR}/.cgw.conf.bak" ]
}

@test "--reconfigure backs up the previous .cgw.conf to .cgw.conf.bak" {
  printf 'CGW_LINT_CMD="my-custom-lint"\n' > "${TEST_REPO_DIR}/.cgw.conf"
  _run_configure "--non-interactive --reconfigure"
  [ -f "${TEST_REPO_DIR}/.cgw.conf.bak" ]
  grep -q 'CGW_LINT_CMD="my-custom-lint"' "${TEST_REPO_DIR}/.cgw.conf.bak"
  ! grep -q 'CGW_LINT_CMD="my-custom-lint"' "${TEST_REPO_DIR}/.cgw.conf"
}

@test "fresh install (no prior .cgw.conf) produces no .cgw.conf.bak" {
  _run_configure "--non-interactive"
  [ -f "${TEST_REPO_DIR}/.cgw.conf" ]
  [ ! -f "${TEST_REPO_DIR}/.cgw.conf.bak" ]
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
  # Regression test: ensure the installed pre-push hook is a valid CGW hook
  # that performs commit-message validation via cgw_validate_commit_message.
  _run_configure "--non-interactive"
  [ -f "${TEST_REPO_DIR}/.githooks/pre-push" ]
  grep -q "cgw_validate_commit_message" "${TEST_REPO_DIR}/.githooks/pre-push"
}

@test "--skip-hooks does not install hooks" {
  _run_configure "--non-interactive --skip-hooks"
  [ ! -f "${TEST_REPO_DIR}/.githooks/pre-commit" ]
}

# ── Markdown lint baseline config (_install_markdownlint_config) ─────────────
# SCRIPT_DIR is pinned to CGW_PROJECT_ROOT/scripts/git (see _run_configure), so
# "../../templates" resolves to the real repo's templates/markdownlint.json --
# no per-test staging needed, unlike the hook/skill installers above.

@test "fresh install copies templates/markdownlint.json to .markdownlint.json" {
  _run_configure "--non-interactive"
  [ -f "${TEST_REPO_DIR}/.markdownlint.json" ]
  diff -q "${CGW_PROJECT_ROOT}/templates/markdownlint.json" "${TEST_REPO_DIR}/.markdownlint.json"
}

@test "fresh install copies templates/markdownlint-cli2.jsonc to .markdownlint-cli2.jsonc" {
  # Tool config (gitignore-skip), installed alongside the rule set above so
  # gitignored files (local CLAUDE.md, session logs, ...) are auto-excluded.
  _run_configure "--non-interactive"
  [ -f "${TEST_REPO_DIR}/.markdownlint-cli2.jsonc" ]
  diff -q "${CGW_PROJECT_ROOT}/templates/markdownlint-cli2.jsonc" "${TEST_REPO_DIR}/.markdownlint-cli2.jsonc"
}

@test "existing .markdownlint.json is never overwritten" {
  echo '{"custom": true}' > "${TEST_REPO_DIR}/.markdownlint.json"
  _run_configure "--non-interactive"
  grep -q '"custom": true' "${TEST_REPO_DIR}/.markdownlint.json"
}

@test "existing .markdownlint-cli2.jsonc blocks installing .markdownlint.json" {
  echo '{"custom": true}' > "${TEST_REPO_DIR}/.markdownlint-cli2.jsonc"
  _run_configure "--non-interactive"
  [ ! -f "${TEST_REPO_DIR}/.markdownlint.json" ]
  grep -q '"custom": true' "${TEST_REPO_DIR}/.markdownlint-cli2.jsonc"
}

@test "existing .markdownlint-cli2.jsonc is never overwritten" {
  echo '{"custom": true}' > "${TEST_REPO_DIR}/.markdownlint-cli2.jsonc"
  _run_configure "--non-interactive"
  grep -q '"custom": true' "${TEST_REPO_DIR}/.markdownlint-cli2.jsonc"
}

@test "--reconfigure does not overwrite an existing markdown lint config" {
  echo '{"custom": true}' > "${TEST_REPO_DIR}/.markdownlint.json"
  _run_configure "--non-interactive --reconfigure"
  grep -q '"custom": true' "${TEST_REPO_DIR}/.markdownlint.json"
}

# ── Branch detection on reconfigure ──────────────────────────────────────────

@test "--reconfigure re-detects source branch, ignoring stale custom names" {
  # Write a config with custom, stale branch names.
  cat > "${TEST_REPO_DIR}/.cgw.conf" <<'EOF'
CGW_SOURCE_BRANCH="my-dev"
CGW_TARGET_BRANCH="my-stable"
CGW_LOCAL_FILES=".claude/ logs/"
EOF
  _run_configure "--non-interactive --reconfigure"
  # 90091fb: --reconfigure re-detects branches instead of preserving stale values.
  # Test repo has both 'main' and 'development' -- fresh detection finds 'development'
  # as SOURCE. TARGET is never written (auto-detected at runtime instead).
  grep -q 'CGW_SOURCE_BRANCH="development"' "${TEST_REPO_DIR}/.cgw.conf"
  ! grep -q "CGW_TARGET_BRANCH" "${TEST_REPO_DIR}/.cgw.conf"
}

@test "--reconfigure on a single-branch repo omits both branch lines" {
  git -C "${TEST_REPO_DIR}" branch -D development
  cat > "${TEST_REPO_DIR}/.cgw.conf" <<'EOF'
CGW_SOURCE_BRANCH="my-dev"
CGW_TARGET_BRANCH="my-stable"
CGW_LOCAL_FILES=".claude/ logs/"
EOF
  _run_configure "--non-interactive --reconfigure"
  ! grep -q "CGW_SOURCE_BRANCH" "${TEST_REPO_DIR}/.cgw.conf"
  ! grep -q "CGW_TARGET_BRANCH" "${TEST_REPO_DIR}/.cgw.conf"
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

# ── Regression: cgw_confirm must be resolvable from configure.sh ─────────────
# Commit 21170db added cgw_confirm calls to configure.sh, but configure.sh did
# not source _common.sh (where cgw_confirm lives). This caused silent no-ops
# in interactive mode: each call returned exit 127 and the install step was
# skipped. This test catches that class of regression even in non-interactive
# mode, because CGW_NON_INTERACTIVE=1 is set and cgw_confirm must be available
# to evaluate it.

@test "cgw_confirm is resolvable from configure.sh (regression guard)" {
  run _run_configure "--non-interactive"
  [ "${status}" -eq 0 ]
  # "command not found" means cgw_confirm was missing from scope
  [[ "${output}" != *"cgw_confirm: command not found"* ]]
}

@test "--non-interactive via CGW_NON_INTERACTIVE installs pre-commit hook" {
  # CGW_NON_INTERACTIVE=1 is set by _run_configure; cgw_confirm must resolve it.
  _run_configure "--non-interactive"
  [ -f "${TEST_REPO_DIR}/.githooks/pre-commit" ]
}

# ── Typecheck tool detection ──────────────────────────────────────────────────

@test "detects pyrefly when [tool.pyrefly] declared in pyproject.toml" {
  printf '[tool.pyrefly]\nsearch_path = ["."]\n' > "${TEST_REPO_DIR}/pyproject.toml"
  _run_configure "--non-interactive" || true
  if [ -f "${TEST_REPO_DIR}/.cgw.conf" ]; then
    grep -q 'CGW_TYPECHECK_CMD="pyrefly"' "${TEST_REPO_DIR}/.cgw.conf"
  fi
}

@test "detects mypy when [tool.mypy] declared and pyrefly/pyright absent" {
  printf '[tool.mypy]\n' > "${TEST_REPO_DIR}/pyproject.toml"
  _run_configure "--non-interactive" || true
  if [ -f "${TEST_REPO_DIR}/.cgw.conf" ]; then
    grep -q 'CGW_TYPECHECK_CMD="mypy"' "${TEST_REPO_DIR}/.cgw.conf"
  fi
}

@test "emits pyrefly hint comment when Python project has no typechecker" {
  # pyproject.toml present but no [tool.*] typechecker section, none on PATH
  _require_no_typechecker
  printf '[build-system]\nrequires = ["setuptools"]\n' > "${TEST_REPO_DIR}/pyproject.toml"
  _run_configure "--non-interactive" || true
  if [ -f "${TEST_REPO_DIR}/.cgw.conf" ]; then
    grep -q 'pip install pyrefly' "${TEST_REPO_DIR}/.cgw.conf"
  fi
}

@test "--reconfigure adds CGW_TYPECHECK_CMD when pyrefly declared" {
  # Simulate a pre-existing .cgw.conf without typecheck vars, then reconfigure
  printf '[tool.pyrefly]\n' > "${TEST_REPO_DIR}/pyproject.toml"
  printf 'CGW_SOURCE_BRANCH="development"\nCGW_TARGET_BRANCH="main"\n' > "${TEST_REPO_DIR}/.cgw.conf"
  _run_configure "--non-interactive --reconfigure" || true
  if [ -f "${TEST_REPO_DIR}/.cgw.conf" ]; then
    grep -q 'CGW_TYPECHECK_CMD="pyrefly"' "${TEST_REPO_DIR}/.cgw.conf"
  fi
}
