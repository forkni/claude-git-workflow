#!/usr/bin/env bats
# tests/integration/typecheck.bats - Integration tests for CGW_TYPECHECK_CMD pre-commit step
# Verifies: (a) no-op when disabled, (b) [PASS] on clean, (c) [WARN] on errors (non-blocking),
#           (d) CGW_SKIP_TYPECHECK=1 skip path.
# Runs: bats tests/integration/typecheck.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'

setup() {
  create_test_repo
  mkdir -p "${TEST_REPO_DIR}/scripts/git"
  cp "${CGW_PROJECT_ROOT}/scripts/git/_common.sh" "${TEST_REPO_DIR}/scripts/git/_common.sh"
  cp "${CGW_PROJECT_ROOT}/scripts/git/_config.sh" "${TEST_REPO_DIR}/scripts/git/_config.sh"
  cp "${CGW_PROJECT_ROOT}/hooks/pre-commit" "${TEST_REPO_DIR}/.git/hooks/pre-commit"
  chmod +x "${TEST_REPO_DIR}/.git/hooks/pre-commit"
  git -C "${TEST_REPO_DIR}" checkout development
}

teardown() {
  cleanup_test_repo
}

@test "pre-commit hook: CGW_TYPECHECK_CMD empty skips typecheck silently" {
  printf 'CGW_TYPECHECK_CMD=""\n' > "${TEST_REPO_DIR}/.cgw.conf"
  echo "x = 1" > "${TEST_REPO_DIR}/foo.py"
  git -C "${TEST_REPO_DIR}" add foo.py
  run git -C "${TEST_REPO_DIR}" commit -m "feat: add foo.py"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"Checking types"* ]]
  [[ "${output}" != *"[WARN]"* ]]
}

@test "pre-commit hook: typecheck passes — exits 0 and prints [PASS]" {
  local fake_tc
  fake_tc="$(mktemp)"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${fake_tc}"
  chmod +x "${fake_tc}"
  printf 'CGW_TYPECHECK_CMD="%s"\nCGW_TYPECHECK_CHECK_ARGS=""\n' "${fake_tc}" > "${TEST_REPO_DIR}/.cgw.conf"
  echo "x = 1" > "${TEST_REPO_DIR}/foo.py"
  git -C "${TEST_REPO_DIR}" add foo.py
  run git -C "${TEST_REPO_DIR}" commit -m "feat: add foo.py"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[PASS] Typecheck passed"* ]]
  rm -f "${fake_tc}"
}

@test "pre-commit hook: typecheck fails — prints [WARN] but exits 0 (non-blocking)" {
  local fake_tc
  fake_tc="$(mktemp)"
  printf '#!/usr/bin/env bash\necho "foo.py:1:1: error: missing return type"\nexit 1\n' > "${fake_tc}"
  chmod +x "${fake_tc}"
  printf 'CGW_LINT_CMD=""\nCGW_TYPECHECK_CMD="%s"\nCGW_TYPECHECK_CHECK_ARGS=""\n' "${fake_tc}" > "${TEST_REPO_DIR}/.cgw.conf"
  echo "x = 1" > "${TEST_REPO_DIR}/foo.py"
  git -C "${TEST_REPO_DIR}" add foo.py
  run git -C "${TEST_REPO_DIR}" commit -m "feat: add foo.py"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[WARN] Type errors found"* ]]
  [[ "${output}" != *"[PASS]"* ]]
  rm -f "${fake_tc}"
}

@test "pre-commit hook: CGW_SKIP_TYPECHECK=1 skips typecheck even when CGW_TYPECHECK_CMD is set" {
  local fake_tc
  fake_tc="$(mktemp)"
  printf '#!/usr/bin/env bash\nexit 1\n' > "${fake_tc}"
  chmod +x "${fake_tc}"
  printf 'CGW_LINT_CMD=""\nCGW_TYPECHECK_CMD="%s"\nCGW_TYPECHECK_CHECK_ARGS=""\nCGW_SKIP_TYPECHECK=1\n' "${fake_tc}" > "${TEST_REPO_DIR}/.cgw.conf"
  echo "x = 1" > "${TEST_REPO_DIR}/foo.py"
  git -C "${TEST_REPO_DIR}" add foo.py
  run git -C "${TEST_REPO_DIR}" commit -m "feat: add foo.py"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"[WARN]"* ]]
  [[ "${output}" != *"[PASS]"* ]]
  rm -f "${fake_tc}"
}
