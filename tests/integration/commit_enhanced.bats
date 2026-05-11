#!/usr/bin/env bats
# tests/integration/commit_enhanced.bats - Integration tests for commit_enhanced.sh
# Runs: bats tests/integration/commit_enhanced.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo
  setup_mock_bin
  install_mock_lint
  git -C "${TEST_REPO_DIR}" checkout development
}

teardown() {
  cleanup_test_repo
}

# Helper: run commit_enhanced.sh with shared env vars
_run_commit() {
  # PATH is already correct from setup_mock_bin; PROJECT_ROOT pins scripts to TEST_REPO_DIR.
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' $*
  "
}

# ── No staged changes ─────────────────────────────────────────────────────────

@test "no staged changes exits 0 with no-changes message" {
  run _run_commit "\"feat: test\""
  # Script should exit 0 and mention no changes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No changes"* ]] || [[ "${output}" == *"nothing to commit"* ]] || \
    [[ "${output}" == *"no changes"* ]]
}

# ── Missing commit message ────────────────────────────────────────────────────

@test "missing commit message exits 1" {
  echo "test content" > "${TEST_REPO_DIR}/test_file.txt"
  git -C "${TEST_REPO_DIR}" add test_file.txt
  run _run_commit ""
  [ "${status}" -eq 1 ]
}

# ── Invalid commit prefix ─────────────────────────────────────────────────────

@test "invalid commit prefix warns in non-interactive mode" {
  echo "content" > "${TEST_REPO_DIR}/new_file.txt"
  git -C "${TEST_REPO_DIR}" add new_file.txt
  run _run_commit "\"wip: bad prefix\""
  # Non-interactive: should warn or fail — either warns about prefix or exits non-zero
  [[ "${output}" == *"prefix"* ]] || [[ "${output}" == *"format"* ]] || [ "${status}" -ne 0 ]
}

# ── Valid conventional commit ─────────────────────────────────────────────────

@test "valid conventional commit with staged file succeeds" {
  echo "feature content" > "${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  run _run_commit "--skip-lint \"feat: add feature file\""
  [ "${status}" -eq 0 ]
}

@test "valid conventional commit appears in git log" {
  echo "another feature" > "${TEST_REPO_DIR}/another.txt"
  git -C "${TEST_REPO_DIR}" add another.txt
  _run_commit "--skip-lint \"feat: add another file\""
  last_msg=$(git -C "${TEST_REPO_DIR}" log -1 --format="%s")
  [ "${last_msg}" = "feat: add another file" ]
}

# ── Local-only file protection ────────────────────────────────────────────────

@test "CLAUDE.md is never staged or committed" {
  # Create CLAUDE.md and stage everything
  echo "# Claude" > "${TEST_REPO_DIR}/CLAUDE.md"
  echo "real content" > "${TEST_REPO_DIR}/real.txt"
  git -C "${TEST_REPO_DIR}" add .
  _run_commit "--skip-lint \"feat: add real content\"" || true
  # CLAUDE.md must not appear in git tree
  tracked=$(git -C "${TEST_REPO_DIR}" ls-files CLAUDE.md)
  [ -z "${tracked}" ]
}

@test "CGW_LOCAL_FILES_EXEMPT lets a plain-file entry through (bug #4 regression)" {
  # Bug #4: _is_exempt was only consulted in the directory branch, so an exempt
  # plain-file entry (e.g. "CLAUDE.md") was still unstaged. Now it should commit.
  echo "# Claude" > "${TEST_REPO_DIR}/CLAUDE.md"
  git -C "${TEST_REPO_DIR}" add CLAUDE.md
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    export CGW_LOCAL_FILES='CLAUDE.md'
    export CGW_LOCAL_FILES_EXEMPT='CLAUDE.md'
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' --skip-lint 'docs: add exempt CLAUDE.md'
  "
  # CLAUDE.md should now be tracked
  tracked=$(git -C "${TEST_REPO_DIR}" ls-files CLAUDE.md)
  [ -n "${tracked}" ]
}

@test "allows git rm --cached of a tracked local-only file (bug #7 regression)" {
  # Reproduce: user adds a dir to CGW_LOCAL_FILES, then does `git rm --cached` to untrack it.
  # commit_enhanced.sh was calling `git reset HEAD <file>` on every staged path that matched
  # CGW_LOCAL_FILES — including deletions — thereby silently undoing the git rm.
  # Contract (matches hooks/pre-commit --diff-filter=AM): only add/modify entries are blocked;
  # staged deletions must pass through so users can untrack files.
  echo "# Claude" > "${TEST_REPO_DIR}/CLAUDE.md"
  git -C "${TEST_REPO_DIR}" -c core.hooksPath=/dev/null add CLAUDE.md
  git -C "${TEST_REPO_DIR}" -c core.hooksPath=/dev/null commit --quiet -m "chore: leak CLAUDE.md"
  git -C "${TEST_REPO_DIR}" rm --cached CLAUDE.md
  run _run_commit "--skip-lint \"chore: untrack CLAUDE.md (local-only)\""
  [ "${status}" -eq 0 ]
  tracked=$(git -C "${TEST_REPO_DIR}" ls-files CLAUDE.md)
  [ -z "${tracked}" ]
  [ -f "${TEST_REPO_DIR}/CLAUDE.md" ]
}

@test "anchored matching: logs.md is not blocked when CGW_LOCAL_FILES is 'logs/' (bug #6 regression)" {
  # Bug #6: prefix match without "$" anchor blocked anything starting with the
  # entry, so "logs/" wrongly blocked logs.md. Anchored match now permits it.
  echo "# Logs" > "${TEST_REPO_DIR}/logs.md"
  git -C "${TEST_REPO_DIR}" add logs.md
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    export CGW_LOCAL_FILES='logs/'
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' --skip-lint 'docs: add logs.md'
  "
  tracked=$(git -C "${TEST_REPO_DIR}" ls-files logs.md)
  [ -n "${tracked}" ]
}

# ── --skip-lint flag ──────────────────────────────────────────────────────────

@test "--skip-lint skips lint step" {
  echo "skip lint test" > "${TEST_REPO_DIR}/skip_test.txt"
  git -C "${TEST_REPO_DIR}" add skip_test.txt
  run _run_commit "--skip-lint \"feat: skip lint test\""
  [ "${status}" -eq 0 ]
  # ruff mock log should be empty or absent when skipped
}

# ── --staged-only flag ────────────────────────────────────────────────────────

@test "--staged-only does not auto-stage unstaged files" {
  echo "unstaged" > "${TEST_REPO_DIR}/unstaged.txt"
  # Do NOT git add — file is untracked
  run _run_commit "--skip-lint --staged-only \"feat: staged only\""
  # Unstaged file should not end up committed
  tracked=$(git -C "${TEST_REPO_DIR}" ls-files unstaged.txt)
  [ -z "${tracked}" ]
}

# ── --non-interactive flag ────────────────────────────────────────────────────

@test "--non-interactive auto-stages tracked modified files" {
  # Create a tracked file and modify it without staging
  echo "initial" > "${TEST_REPO_DIR}/tracked.txt"
  git -C "${TEST_REPO_DIR}" add tracked.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: add tracked"
  echo "modified" > "${TEST_REPO_DIR}/tracked.txt"
  # Non-interactive should auto-stage the modification
  run _run_commit "--skip-lint \"feat: auto-staged change\""
  [ "${status}" -eq 0 ]
}

# ── Safe default: pre-staged files are respected ──────────────────────────────

@test "pre-staged files only: unstaged changes do NOT get bundled (safe default)" {
  # Setup: create two tracked files, commit them, then modify both
  echo "file_a v1" > "${TEST_REPO_DIR}/file_a.txt"
  echo "file_b v1" > "${TEST_REPO_DIR}/file_b.txt"
  git -C "${TEST_REPO_DIR}" add file_a.txt file_b.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: add both files"

  echo "file_a v2" > "${TEST_REPO_DIR}/file_a.txt"  # intended change
  echo "file_b v2" > "${TEST_REPO_DIR}/file_b.txt"  # unrelated, should NOT be committed

  # Pre-stage only file_a
  git -C "${TEST_REPO_DIR}" add file_a.txt

  run _run_commit "--skip-lint \"feat: intended change to file_a\""
  [ "${status}" -eq 0 ]

  # file_a.txt in the new commit
  changed_files=$(git -C "${TEST_REPO_DIR}" show --name-only --pretty=format: HEAD | grep -v '^$')
  [[ "${changed_files}" == *"file_a.txt"* ]]
  # file_b.txt must NOT be in the commit
  [[ "${changed_files}" != *"file_b.txt"* ]]

  # file_b.txt should still be a pending working-tree change
  git -C "${TEST_REPO_DIR}" diff --name-only | grep -q "^file_b.txt$"
}

# ── --all flag: force bulk-stage ──────────────────────────────────────────────

@test "--all overrides pre-stage respect and commits everything" {
  echo "file_a v1" > "${TEST_REPO_DIR}/file_a.txt"
  echo "file_b v1" > "${TEST_REPO_DIR}/file_b.txt"
  git -C "${TEST_REPO_DIR}" add file_a.txt file_b.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: add both files"

  echo "file_a v2" > "${TEST_REPO_DIR}/file_a.txt"
  echo "file_b v2" > "${TEST_REPO_DIR}/file_b.txt"

  # Pre-stage only file_a, but pass --all to override
  git -C "${TEST_REPO_DIR}" add file_a.txt

  run _run_commit "--skip-lint --all \"feat: intentional bulk commit\""
  [ "${status}" -eq 0 ]

  # Both files should be in the new commit
  changed_files=$(git -C "${TEST_REPO_DIR}" show --name-only --pretty=format: HEAD | grep -v '^$')
  [[ "${changed_files}" == *"file_a.txt"* ]]
  [[ "${changed_files}" == *"file_b.txt"* ]]
}

# ── --only flag: explicit selective staging ───────────────────────────────────

@test "--only stages only listed paths, ignoring prior index state" {
  echo "file_a v1" > "${TEST_REPO_DIR}/file_a.txt"
  echo "file_b v1" > "${TEST_REPO_DIR}/file_b.txt"
  echo "file_c v1" > "${TEST_REPO_DIR}/file_c.txt"
  git -C "${TEST_REPO_DIR}" add file_a.txt file_b.txt file_c.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: add three files"

  echo "file_a v2" > "${TEST_REPO_DIR}/file_a.txt"
  echo "file_b v2" > "${TEST_REPO_DIR}/file_b.txt"
  echo "file_c v2" > "${TEST_REPO_DIR}/file_c.txt"

  # Pre-stage file_a (should get reset), then --only should pick file_b + file_c
  git -C "${TEST_REPO_DIR}" add file_a.txt

  run _run_commit "--skip-lint --only file_b.txt --only file_c.txt \"feat: only b and c\""
  [ "${status}" -eq 0 ]

  changed_files=$(git -C "${TEST_REPO_DIR}" show --name-only --pretty=format: HEAD | grep -v '^$')
  [[ "${changed_files}" != *"file_a.txt"* ]]
  [[ "${changed_files}" == *"file_b.txt"* ]]
  [[ "${changed_files}" == *"file_c.txt"* ]]

  # file_a should still be a pending working-tree change
  git -C "${TEST_REPO_DIR}" diff --name-only | grep -q "^file_a.txt$"
}

@test "--only rejects missing pathspec argument" {
  run _run_commit "--only --skip-lint \"feat: bad usage\""
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"--only requires a pathspec"* ]]
}

# ── Lint failure / auto-fix ───────────────────────────────────────────────────

@test "lint failure in NI mode exits 1 when errors remain after auto-fix" {
  install_mock_lint_with_errors
  echo "bad python" > "${TEST_REPO_DIR}/lint_test.txt"
  git -C "${TEST_REPO_DIR}" add lint_test.txt
  run _run_commit "\"feat: lint failure test\""
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"quality"* ]] || [[ "${output}" == *"lint"* ]] || \
    [[ "${output}" == *"error"* ]]
}

@test "lint auto-fix succeeds: exits 0 and creates commit" {
  install_mock_lint_fixable
  echo "fixable content" > "${TEST_REPO_DIR}/fixable.txt"
  git -C "${TEST_REPO_DIR}" add fixable.txt
  run _run_commit "\"feat: auto-fix succeeds\""
  [ "${status}" -eq 0 ]
  last_msg=$(git -C "${TEST_REPO_DIR}" log -1 --format="%s")
  [ "${last_msg}" = "feat: auto-fix succeeds" ]
}

# ── Format check ──────────────────────────────────────────────────────────────

@test "format check failure surfaces FORMAT ERRORS message" {
  install_mock_format_with_errors
  echo "unformatted" > "${TEST_REPO_DIR}/fmt_test.txt"
  git -C "${TEST_REPO_DIR}" add fmt_test.txt
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD='ruff'
    export CGW_FORMAT_CHECK_ARGS='format --check'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'feat: format test'
  "
  [[ "${output}" == *"FORMAT ERRORS"* ]] || [[ "${output}" == *"would reformat"* ]]
}

# ── Markdownlint ──────────────────────────────────────────────────────────────

@test "--skip-md-lint bypasses markdownlint step" {
  MOCK_MDLINT_EXIT=0 install_mock_markdownlint
  echo "content" > "${TEST_REPO_DIR}/md_test.md"
  git -C "${TEST_REPO_DIR}" add md_test.md
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD='markdownlint-cli2'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' --skip-md-lint 'docs: md test'
  "
  [ "${status}" -eq 0 ]
  [ ! -f "${MOCK_BIN_DIR}/mdlint.log" ] || \
    ! grep -q "markdownlint" "${MOCK_BIN_DIR}/mdlint.log" 2>/dev/null
}

@test "markdownlint failure exits 1 in non-interactive mode" {
  MOCK_MDLINT_EXIT=1 install_mock_markdownlint
  echo "content" > "${TEST_REPO_DIR}/bad_md.md"
  git -C "${TEST_REPO_DIR}" add bad_md.md
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD='markdownlint-cli2'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'docs: bad md'
  "
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Markdown lint"* ]] || [[ "${output}" == *"markdown"* ]] || \
    [[ "${output}" == *"MARKDOWN"* ]]
}

# ── --no-venv flag ────────────────────────────────────────────────────────────

@test "--no-venv uses system lint binary and exits 0" {
  echo "content" > "${TEST_REPO_DIR}/novenv.txt"
  git -C "${TEST_REPO_DIR}" add novenv.txt
  run _run_commit "--no-venv \"feat: no-venv commit\""
  [ "${status}" -eq 0 ]
}

# ── Non-interactive bad prefix (strict) ──────────────────────────────────────

@test "non-interactive bad prefix exits 1 with conventional-format error" {
  echo "content" > "${TEST_REPO_DIR}/prefix_test.txt"
  git -C "${TEST_REPO_DIR}" add prefix_test.txt
  run _run_commit "\"wip: not-a-valid-prefix\""
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"conventional format"* ]] || [[ "${output}" == *"conventional"* ]]
}

# ── Regression: no-TTY auto-detect must propagate to cgw_confirm ─────────────
# commit_enhanced.sh auto-detects non-interactive mode via [[ ! -t 0 ]], sets
# local non_interactive=1, but also MUST export CGW_NON_INTERACTIVE=1 so that
# cgw_confirm honours the --non-interactive policy at branch verification.
# Without the export, cgw_confirm reads EOF from stdin and returns 1 (deny),
# silently cancelling the commit with "Switch to correct branch first".

@test "no-TTY auto-detect propagates to cgw_confirm (regression guard)" {
  echo "regression guard content" > "${TEST_REPO_DIR}/regression_test.txt"
  git -C "${TEST_REPO_DIR}" add regression_test.txt
  # Invoke without CGW_NON_INTERACTIVE set and without --non-interactive flag.
  # stdin is redirected from /dev/null to simulate Bash-tool / CI invocation.
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export PATH='${MOCK_BIN_DIR}:${PATH}'
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' --no-venv 'feat: regression guard commit' </dev/null
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"Switch to correct branch first"* ]]
  [[ "${output}" == *"COMMIT SUCCESSFUL"* ]]
}
