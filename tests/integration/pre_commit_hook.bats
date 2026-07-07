#!/usr/bin/env bats
# tests/integration/pre_commit_hook.bats - Integration tests for the pre-commit hook
# Verifies hooks read CGW_LOCAL_FILES from .cgw.conf at runtime (no install-time pattern compile).
# Runs: bats tests/integration/pre_commit_hook.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'

setup() {
  create_test_repo
  # Install the hook templates by copying them in (no configure.sh needed since
  # there is no longer any substitution).
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

@test "pre-commit blocks staged CLAUDE.md (default config)" {
  echo "# Claude" > "${TEST_REPO_DIR}/CLAUDE.md"
  git -C "${TEST_REPO_DIR}" add CLAUDE.md
  run git -C "${TEST_REPO_DIR}" commit -m "docs: leak CLAUDE.md"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"CLAUDE.md"* ]] || [[ "${output}" == *"local-only"* ]]
}

@test "pre-commit picks up .cgw.conf edits at runtime (no re-render)" {
  # Bug being fixed: previously the hook had its match pattern baked in by
  # configure.sh. Editing .cgw.conf afterward had no effect until re-render.
  # Now the hook reads CGW_LOCAL_FILES live from .cgw.conf each invocation.
  echo 'CGW_LOCAL_FILES="notes.md"' > "${TEST_REPO_DIR}/.cgw.conf"
  echo "scratch" > "${TEST_REPO_DIR}/notes.md"
  git -C "${TEST_REPO_DIR}" add notes.md
  run git -C "${TEST_REPO_DIR}" commit -m "docs: leak notes.md"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"notes.md"* ]] || [[ "${output}" == *"local-only"* ]]
}

@test "pre-commit allows files NOT in CGW_LOCAL_FILES" {
  echo 'CGW_LOCAL_FILES="CLAUDE.md"' > "${TEST_REPO_DIR}/.cgw.conf"
  echo "real content" > "${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  run git -C "${TEST_REPO_DIR}" commit -m "feat: add feature.txt"
  [ "${status}" -eq 0 ]
}

@test "pre-commit anchoring: logs.md is not blocked when CGW_LOCAL_FILES='logs/' (bug #6 regression)" {
  echo 'CGW_LOCAL_FILES="logs/"' > "${TEST_REPO_DIR}/.cgw.conf"
  echo "# Logs" > "${TEST_REPO_DIR}/logs.md"
  git -C "${TEST_REPO_DIR}" add logs.md
  run git -C "${TEST_REPO_DIR}" commit -m "docs: add logs.md"
  [ "${status}" -eq 0 ]
}

@test "pre-commit exempt: CGW_LOCAL_FILES_EXEMPT lets a plain-file entry through (bug #4 regression)" {
  cat > "${TEST_REPO_DIR}/.cgw.conf" <<'EOF'
CGW_LOCAL_FILES="CLAUDE.md"
CGW_LOCAL_FILES_EXEMPT="CLAUDE.md"
EOF
  echo "# Claude" > "${TEST_REPO_DIR}/CLAUDE.md"
  git -C "${TEST_REPO_DIR}" add CLAUDE.md
  run git -C "${TEST_REPO_DIR}" commit -m "docs: intentional CLAUDE.md"
  [ "${status}" -eq 0 ]
}

@test "pre-commit allows deletion of a tracked local-only file" {
  # The hook's diff-filter is AM (Added or Modified). Deletions go through
  # so users can untrack a file that was previously committed by mistake.
  echo "# Claude" > "${TEST_REPO_DIR}/CLAUDE.md"
  git -C "${TEST_REPO_DIR}" -c core.hooksPath=/dev/null add CLAUDE.md
  git -C "${TEST_REPO_DIR}" -c core.hooksPath=/dev/null commit --quiet -m "chore: leaked file"
  git -C "${TEST_REPO_DIR}" rm CLAUDE.md
  run git -C "${TEST_REPO_DIR}" commit -m "chore: untrack CLAUDE.md"
  [ "${status}" -eq 0 ]
}

@test "pre-commit hook: CGW_LINT_CMD empty skips lint silently" {
  echo 'CGW_LINT_CMD=""' > "${TEST_REPO_DIR}/.cgw.conf"
  echo "print('hello')" > "${TEST_REPO_DIR}/foo.py"
  git -C "${TEST_REPO_DIR}" add foo.py
  run git -C "${TEST_REPO_DIR}" commit -m "feat: add foo.py"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"Checking lint"* ]]
  [[ "${output}" != *"[WARN]"* ]]
}

@test "pre-commit hook: lint failure surfaces WARN but exits 0 (non-blocking)" {
  local fake_lint
  fake_lint="$(mktemp)"
  printf '#!/usr/bin/env bash\necho "foo.py:1:1: E501 line too long"\nexit 1\n' > "${fake_lint}"
  chmod +x "${fake_lint}"
  printf 'CGW_LINT_CMD="%s"\n' "${fake_lint}" > "${TEST_REPO_DIR}/.cgw.conf"
  echo "print('hello')" > "${TEST_REPO_DIR}/foo.py"
  git -C "${TEST_REPO_DIR}" add foo.py
  run git -C "${TEST_REPO_DIR}" commit -m "feat: add foo.py"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[WARN]"* ]]
  rm -f "${fake_lint}"
}

@test "pre-commit hook: non-Python staged file does not trigger lint" {
  # Regression: the hook used to pass ALL staged files to the linter, so ruff
  # parsed .h/.cpp/.md as Python and emitted false-positive syntax errors.
  local fake_lint
  fake_lint="$(mktemp)"
  printf '#!/usr/bin/env bash\necho "should not run"\nexit 1\n' > "${fake_lint}"
  chmod +x "${fake_lint}"
  printf 'CGW_LINT_CMD="%s"\n' "${fake_lint}" > "${TEST_REPO_DIR}/.cgw.conf"
  printf 'int main(){return 0;}\n' > "${TEST_REPO_DIR}/main.cpp"
  git -C "${TEST_REPO_DIR}" add main.cpp
  run git -C "${TEST_REPO_DIR}" commit -m "feat: add main.cpp"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"Checking lint"* ]]
  [[ "${output}" != *"[WARN]"* ]]
  rm -f "${fake_lint}"
}
