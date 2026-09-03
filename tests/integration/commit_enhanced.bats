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

@test "--only stages a tracked file that later became gitignored" {
  # Track the file first, commit, THEN gitignore its directory.
  mkdir -p "${TEST_REPO_DIR}/docs"
  echo "note v1" > "${TEST_REPO_DIR}/docs/note.md"
  git -C "${TEST_REPO_DIR}" add docs/note.md
  git -C "${TEST_REPO_DIR}" commit -q -m "chore: add note"
  echo "docs/" > "${TEST_REPO_DIR}/.gitignore"
  echo "note v2" > "${TEST_REPO_DIR}/docs/note.md"

  run _run_commit "--skip-lint --only docs/note.md \"docs: update note\""
  [ "${status}" -eq 0 ]
  # The updated content is actually in the new commit.
  run git -C "${TEST_REPO_DIR}" show HEAD:docs/note.md
  [[ "${output}" == *"note v2"* ]]
}

@test "--only <dir> does not force-add ignored untracked files alongside a tracked one" {
  mkdir -p "${TEST_REPO_DIR}/docs"
  echo "note v1" > "${TEST_REPO_DIR}/docs/note.md"
  git -C "${TEST_REPO_DIR}" add docs/note.md
  git -C "${TEST_REPO_DIR}" commit -q -m "chore: add note"
  echo "docs/" > "${TEST_REPO_DIR}/.gitignore"      # dir ignored AFTER note.md tracked
  echo "note v2" > "${TEST_REPO_DIR}/docs/note.md"
  echo "junk"   > "${TEST_REPO_DIR}/docs/artifact.log"  # ignored + untracked

  run _run_commit "--skip-lint --only docs/ \"docs: update note\""
  [ "${status}" -eq 0 ]
  run git -C "${TEST_REPO_DIR}" show HEAD:docs/note.md
  [[ "${output}" == *"note v2"* ]]
  run git -C "${TEST_REPO_DIR}" ls-tree -r --name-only HEAD
  [[ "${output}" != *"docs/artifact.log"* ]]   # ensure ignored, untracked artifacts aren't staged
}

@test "--only surfaces git's error text when staging genuinely fails" {
  run _run_commit "--skip-lint --only does-not-exist.txt \"feat: nope\""
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Failed to stage: does-not-exist.txt"* ]]   # generic message kept
  [[ "${output}" == *"did not match"* ]]                          # git's actionable text now surfaced
}

# ── Lint failure / auto-fix ───────────────────────────────────────────────────

@test "lint failure in NI mode exits 1 when errors remain after auto-fix" {
  install_mock_lint_with_errors
  # Must be .py: the gate scopes to staged files matching CGW_LINT_EXTENSIONS
  echo "bad python" > "${TEST_REPO_DIR}/lint_test.py"
  git -C "${TEST_REPO_DIR}" add lint_test.py
  run _run_commit "\"feat: lint failure test\""
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"quality"* ]] || [[ "${output}" == *"lint"* ]] || \
    [[ "${output}" == *"error"* ]]
}

@test "lint auto-fix succeeds: exits 0 and creates commit" {
  install_mock_lint_fixable
  echo "fixable content" > "${TEST_REPO_DIR}/fixable.py"
  git -C "${TEST_REPO_DIR}" add fixable.py
  run _run_commit "\"feat: auto-fix succeeds\""
  [ "${status}" -eq 0 ]
  last_msg=$(git -C "${TEST_REPO_DIR}" log -1 --format="%s")
  [ "${last_msg}" = "feat: auto-fix succeeds" ]
}

# ── Format check ──────────────────────────────────────────────────────────────

@test "format check failure surfaces FORMAT ERRORS message" {
  install_mock_format_with_errors
  echo "unformatted" > "${TEST_REPO_DIR}/fmt_test.py"
  git -C "${TEST_REPO_DIR}" add fmt_test.py
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

# ── Staged-blob congruence guard [3.5] ────────────────────────────────────────
# [3] validates the WORKING TREE, but `git commit` records the INDEX. These
# tests exercise the [3.5] guard that closes the gap: it must never let a
# staged blob CGW never validated silently reach HEAD. All cases need the
# format path enabled, so they use the inline `bash -c` pattern above (the
# `_run_commit` helper hard-codes CGW_FORMAT_CMD='').

@test "Mode 1: unformatted staged blob + clean working tree aborts the commit (fails closed)" {
  install_mock_ruff_reformatter
  printf 'x = 1\n#UNFORMATTED#\n' > "${TEST_REPO_DIR}/mode1.py"
  git -C "${TEST_REPO_DIR}" add mode1.py
  # Working tree is already "clean" WITHOUT re-staging -- index still holds
  # the unformatted blob. [3]'s format check reads disk (clean) and passes;
  # only [3.5]'s index-vs-disk hash comparison can catch this.
  printf 'x = 1\n' > "${TEST_REPO_DIR}/mode1.py"

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD='ruff'
    export CGW_FORMAT_CHECK_ARGS='format --check'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'feat: mode1 divergence'
  "
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"would commit a different staged blob"* ]]
  # No commit landed -- the branch tip is still the pre-existing dev commit.
  last_msg=$(git -C "${TEST_REPO_DIR}" log -1 --format="%s")
  [ "${last_msg}" = "feat: dev commit" ]
}

@test "Mode 1: CGW_ALLOW_STAGED_DIVERGENCE=1 opts out and commits the staged blob as-is" {
  install_mock_ruff_reformatter
  printf 'x = 1\n#UNFORMATTED#\n' > "${TEST_REPO_DIR}/mode1.py"
  git -C "${TEST_REPO_DIR}" add mode1.py
  printf 'x = 1\n' > "${TEST_REPO_DIR}/mode1.py"

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD='ruff'
    export CGW_FORMAT_CHECK_ARGS='format --check'
    export CGW_NON_INTERACTIVE=1
    export CGW_ALLOW_STAGED_DIVERGENCE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'feat: mode1 override'
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"CGW_ALLOW_STAGED_DIVERGENCE=1"* ]]
  run git -C "${TEST_REPO_DIR}" show HEAD:mode1.py
  [[ "${output}" == *"#UNFORMATTED#"* ]]
}

@test "Mode 2 (natural): auto-fix reformats disk and the committed blob is formatted" {
  install_mock_ruff_reformatter
  printf 'x = 1\n#UNFORMATTED#\n' > "${TEST_REPO_DIR}/mode2.py"
  git -C "${TEST_REPO_DIR}" add mode2.py    # staged == disk == unformatted

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD='ruff'
    export CGW_FORMAT_CHECK_ARGS='format --check'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'feat: mode2 autofix'
  "
  [ "${status}" -eq 0 ]
  run git -C "${TEST_REPO_DIR}" show HEAD:mode2.py
  [[ "${output}" != *"#UNFORMATTED#"* ]]
  run cat "${TEST_REPO_DIR}/mode2.py"
  [[ "${output}" != *"#UNFORMATTED#"* ]]
}

@test "Mode 2 (latent): a re-stage silently defeated by assume-unchanged aborts instead of committing stale content" {
  install_mock_ruff_reformatter
  printf 'x = 1\n#UNFORMATTED#\n' > "${TEST_REPO_DIR}/mode2b.py"
  git -C "${TEST_REPO_DIR}" add mode2b.py
  # Model a real restage no-op: assume-unchanged makes `git add -u`/`git add -f`
  # skip this path even when explicitly named (verified: assume-unchanged
  # survives an explicit `git add -f -- <path>`, not just bulk `git add -u`).
  git -C "${TEST_REPO_DIR}" update-index --assume-unchanged mode2b.py

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD='ruff'
    export CGW_FORMAT_CHECK_ARGS='format --check'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'feat: mode2 latent'
  "
  # The guard attempts the re-stage (bulk mode, effective_staged_only==0)...
  [[ "${output}" == *"re-staging: mode2b.py"* ]]
  # ...it silently fails (assume-unchanged), the re-verify catches it, and the
  # commit aborts rather than landing the still-stale blob.
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"still diverges from the validated working tree; aborting"* ]]
  last_msg=$(git -C "${TEST_REPO_DIR}" log -1 --format="%s")
  [ "${last_msg}" = "feat: dev commit" ]
}

@test "Mode 3: staged file deleted from working tree aborts instead of committing an unvalidated blob" {
  install_mock_ruff_reformatter
  printf 'x = 1\n#UNFORMATTED#\n' > "${TEST_REPO_DIR}/mode3.py"
  git -C "${TEST_REPO_DIR}" add mode3.py
  # Delete from disk without re-staging: index still holds the unformatted
  # blob, but there's no working-tree file left for [3]'s format check to
  # read -- the mock (like real ruff) skips missing paths and reports clean,
  # so only [3.5]'s divergence guard can catch the stale staged blob.
  rm "${TEST_REPO_DIR}/mode3.py"

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD='ruff'
    export CGW_FORMAT_CHECK_ARGS='format --check'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'feat: mode3 deleted divergence'
  "
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"would commit a different staged blob"* ]]
  last_msg=$(git -C "${TEST_REPO_DIR}" log -1 --format="%s")
  [ "${last_msg}" = "feat: dev commit" ]
}

@test "Mode 4: a CRLF-in-index file commits cleanly under autocrlf=true (no phantom divergence)" {
  install_mock_ruff_reformatter
  # Stage CRLF content while autocrlf=false (create_test_repo's default) so the
  # index blob holds CRLF verbatim -- the same shape a file committed before
  # autocrlf was enabled, or added with -f, ends up in.
  printf 'x = 1\r\n' > "${TEST_REPO_DIR}/mode4.py"
  git -C "${TEST_REPO_DIR}" add mode4.py
  # Capture the staged (pre-commit) blob hash directly -- bats' `run` output
  # capture normalizes CRLF on this platform, so asserting on captured file
  # *content* for an embedded \r is unreliable; comparing blob hashes sidesteps
  # that and is a stronger assertion anyway (proves the exact bytes, not just
  # "some CR survived somewhere").
  staged_blob=$(git -C "${TEST_REPO_DIR}" rev-parse :mode4.py)
  # Now flip to autocrlf=true without touching the file. `git add` would keep
  # preserving CRLF forever (has_crlf_in_index), and git itself reports the
  # path clean -- only `git hash-object` (no index access) disagrees.
  git -C "${TEST_REPO_DIR}" config core.autocrlf true

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD='ruff'
    export CGW_FORMAT_CHECK_ARGS='format --check'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'feat: mode4 crlf-in-index'
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"diverges"* ]]
  last_msg=$(git -C "${TEST_REPO_DIR}" log -1 --format="%s")
  [ "${last_msg}" = "feat: mode4 crlf-in-index" ]
  # CGW must not have silently renormalized the user's line endings: the
  # committed blob must be byte-identical to what was staged pre-commit.
  head_blob=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD:mode4.py)
  [ "${head_blob}" = "${staged_blob}" ]
}

@test "guard: clean staged .py commits normally and the fixer never runs" {
  install_mock_ruff_reformatter
  printf 'x = 1\n' > "${TEST_REPO_DIR}/clean.py"   # no marker -- already formatted
  git -C "${TEST_REPO_DIR}" add clean.py

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD='ruff'
    export CGW_FORMAT_CHECK_ARGS='format --check'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'feat: clean commit'
  "
  [ "${status}" -eq 0 ]
  run git -C "${TEST_REPO_DIR}" show HEAD:clean.py
  [[ "${output}" == *"x = 1"* ]]
  [[ "${output}" != *"#UNFORMATTED#"* ]]
  # The format FIX (bare `ruff format <file>`) must never have run -- only the check.
  run cat "${MOCK_BIN_DIR}/ruff.log"
  [[ "${output}" == *"format --check clean.py"* ]]
  [[ "${output}" != *"mock ruff format clean.py"* ]]
}

# ── Partial staging (hunk-level) survives auto-fix ────────────────────────────
# Regression coverage for the incident where a concurrent session's unstaged
# hunks were silently absorbed by the lint-autofix re-stage. Construct the
# partial stage without `git add -p` (agent/CI-friendly): write hunk A, stage
# it, then write hunk B on top -- index holds hunk A only, worktree holds A+B.

@test "partially-staged .py + lint auto-fix: unstaged hunk stays out; commit aborts with the new guidance" {
  install_mock_lint_fixable
  printf 'x = 1\n' > "${TEST_REPO_DIR}/partial.py"
  git -C "${TEST_REPO_DIR}" add partial.py
  printf 'x = 1\ny = 2  # concurrent unstaged hunk\n' > "${TEST_REPO_DIR}/partial.py"

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'feat: partial py'
  "
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Auto-fix touched a partially-staged file; leaving it as-is"* ]]
  [[ "${output}" == *"Staged content differs from the validated working tree for: partial.py"* ]]
  [[ "${output}" == *"CGW_ALLOW_STAGED_DIVERGENCE=1"* ]]
  [[ "${output}" == *"--skip-lint"* ]]
  [[ "${output}" == *"DISCARDS your hunk selection"* ]]
  # No commit landed -- the branch tip is still the pre-existing dev commit.
  last_msg=$(git -C "${TEST_REPO_DIR}" log -1 --format="%s")
  [ "${last_msg}" = "feat: dev commit" ]
  # The unstaged hunk is still sitting in the working tree, untouched.
  run cat "${TEST_REPO_DIR}/partial.py"
  [[ "${output}" == *"concurrent unstaged hunk"* ]]
}

@test "partially-staged .py + CGW_ALLOW_STAGED_DIVERGENCE=1 commits exactly the staged hunk" {
  install_mock_lint_fixable
  printf 'x = 1\n' > "${TEST_REPO_DIR}/partial.py"
  git -C "${TEST_REPO_DIR}" add partial.py
  printf 'x = 1\ny = 2  # concurrent unstaged hunk\n' > "${TEST_REPO_DIR}/partial.py"

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    export CGW_ALLOW_STAGED_DIVERGENCE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'feat: partial py override'
  "
  [ "${status}" -eq 0 ]
  run git -C "${TEST_REPO_DIR}" show HEAD:partial.py
  [[ "${output}" != *"concurrent unstaged hunk"* ]]
  # The unstaged hunk is still only on disk, never committed.
  run cat "${TEST_REPO_DIR}/partial.py"
  [[ "${output}" == *"concurrent unstaged hunk"* ]]
}

@test "partially-staged .py + --skip-lint commits exactly the staged hunk" {
  MOCK_LINT_EXIT=1 install_mock_lint
  printf 'x = 1\n' > "${TEST_REPO_DIR}/partial.py"
  git -C "${TEST_REPO_DIR}" add partial.py
  printf 'x = 1\ny = 2  # concurrent unstaged hunk\n' > "${TEST_REPO_DIR}/partial.py"

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' --skip-lint 'feat: partial py skip-lint'
  "
  [ "${status}" -eq 0 ]
  # --skip-lint bypasses the checks entirely -- the always-failing mock must
  # never have been invoked (proves this commits without touching the guard).
  [ ! -f "${MOCK_BIN_DIR}/ruff.log" ]
  run git -C "${TEST_REPO_DIR}" show HEAD:partial.py
  [[ "${output}" != *"concurrent unstaged hunk"* ]]
}

@test "partially-staged .md + markdown auto-fix: no silent collapse (previously zero coverage)" {
  install_mock_markdownlint_fixable
  printf 'title\n\nMDLINT-BAD\n' > "${TEST_REPO_DIR}/partial.md"
  git -C "${TEST_REPO_DIR}" add partial.md
  printf 'title\n\nMDLINT-BAD\nconcurrent unstaged line\n' > "${TEST_REPO_DIR}/partial.md"

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD='markdownlint-cli2'
    export CGW_MARKDOWNLINT_FIX_ARGS='--fix'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'docs: partial md'
  "
  # Before this guard covered markdown too, this exact scenario is the
  # "zero coverage" gap: the fix-then-restage collapse would have silently
  # committed the concurrent unstaged line. It must abort instead.
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Staged content differs from the validated working tree for: partial.md"* ]]
  last_msg=$(git -C "${TEST_REPO_DIR}" log -1 --format="%s")
  [ "${last_msg}" = "feat: dev commit" ]
  run cat "${TEST_REPO_DIR}/partial.md"
  [[ "${output}" == *"concurrent unstaged line"* ]]
}

# ── [3.5] validated-set narrowing: --skip-md-lint / no code checker configured ─
# PR #18 review (Charlie + Copilot): cgw_validated_path_set read CGW_SKIP_MD_LINT
# from the environment, but --skip-md-lint only ever sets a main() local. A
# partially-staged .md was therefore counted as "validated" (and the guard
# aborted) even though markdownlint never ran for this invocation. Same bug
# class on the code-checker side: with both CGW_LINT_CMD and CGW_FORMAT_CMD
# empty (the documented "no linter configured yet" disable), a staged
# lint-extension file was still counted as validated by extension match alone.

@test "partially-staged .md + --skip-md-lint commits exactly the staged hunk (skipped md is not 'validated')" {
  install_mock_markdownlint
  printf 'title\n' > "${TEST_REPO_DIR}/partial.md"
  git -C "${TEST_REPO_DIR}" add partial.md
  printf 'title\nconcurrent unstaged line\n' > "${TEST_REPO_DIR}/partial.md"

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD='markdownlint-cli2'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' --skip-md-lint 'docs: partial md skip-md-lint'
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"(markdown lint skipped -- --skip-md-lint)"* ]]
  [[ "${output}" != *"Staged content differs from the validated working tree"* ]]
  # markdownlint genuinely never ran -- the mock logs only when invoked.
  [ ! -f "${MOCK_BIN_DIR}/mdlint.log" ]
  run git -C "${TEST_REPO_DIR}" show HEAD:partial.md
  [[ "${output}" != *"concurrent unstaged line"* ]]
  run cat "${TEST_REPO_DIR}/partial.md"
  [[ "${output}" == *"concurrent unstaged line"* ]]
}

@test "--skip-md-lint does not disarm the [3.5] guard for a partially-staged lint-eligible file" {
  printf 'x = 1\n' > "${TEST_REPO_DIR}/partial.py"
  git -C "${TEST_REPO_DIR}" add partial.py
  printf 'x = 1\ny = 2  # concurrent unstaged hunk\n' > "${TEST_REPO_DIR}/partial.py"

  run _run_commit "--skip-md-lint \"feat: partial py skip-md-lint\""
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Staged content differs from the validated working tree for: partial.py"* ]]
  last_msg=$(git -C "${TEST_REPO_DIR}" log -1 --format="%s")
  [ "${last_msg}" = "feat: dev commit" ]
}

@test "--skip-md-lint narrows the validated set per file: partial .py still aborts, partial .md is not named" {
  printf 'x = 1\n' > "${TEST_REPO_DIR}/partial.py"
  printf 'title\n' > "${TEST_REPO_DIR}/partial.md"
  git -C "${TEST_REPO_DIR}" add partial.py partial.md
  printf 'x = 1\ny = 2  # concurrent unstaged hunk\n' > "${TEST_REPO_DIR}/partial.py"
  printf 'title\nconcurrent unstaged line\n' > "${TEST_REPO_DIR}/partial.md"

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD='markdownlint-cli2'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' --skip-md-lint 'feat: mixed partial stage'
  "
  [ "${status}" -eq 1 ]
  # Scope the assertion to the error line: the "PRE-STAGED FILES DETECTED"
  # banner prints `git diff --name-status`, which lists partial.md too -- a
  # bare [[ "${output}" != *"partial.md"* ]] would be vacuously false.
  err_line=$(printf '%s\n' "${output}" | grep 'Staged content differs from the validated working tree for:')
  [[ "${err_line}" == *"partial.py"* ]]
  [[ "${err_line}" != *"partial.md"* ]]
}

@test "--skip-md-lint + a .md the guard cannot re-stage: excluded from validated scope, no false abort" {
  install_mock_markdownlint
  printf 'title\n' > "${TEST_REPO_DIR}/latent.md"
  git -C "${TEST_REPO_DIR}" add latent.md
  # Model a real restage no-op: assume-unchanged makes `git add -u`/`git add -f`
  # skip this path even when explicitly named (same trick as "Mode 2 (latent)").
  git -C "${TEST_REPO_DIR}" update-index --assume-unchanged latent.md
  printf 'title\nnever staged\n' > "${TEST_REPO_DIR}/latent.md"

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD='markdownlint-cli2'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' --skip-md-lint 'docs: latent md skip-md-lint'
  "
  # Bulk mode (effective_staged_only==0) is the only path that reaches the
  # :642 re-verify call site -- this is the drift catcher for that site.
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"re-staging: latent.md"* ]]
  [[ "${output}" != *"still diverges from the validated working tree"* ]]
  last_msg=$(git -C "${TEST_REPO_DIR}" log -1 --format="%s")
  [ "${last_msg}" = "docs: latent md skip-md-lint" ]
}

@test "partially-staged .py with no linter configured: commits exactly the staged hunk (no linter is not 'validated')" {
  printf 'x = 1\n' > "${TEST_REPO_DIR}/partial.py"
  git -C "${TEST_REPO_DIR}" add partial.py
  printf 'x = 1\ny = 2  # concurrent unstaged hunk\n' > "${TEST_REPO_DIR}/partial.py"

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'feat: partial py no linter configured'
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[OK] Code quality checks passed"* ]]
  [[ "${output}" != *"Staged content differs from the validated working tree"* ]]
  run git -C "${TEST_REPO_DIR}" show HEAD:partial.py
  [[ "${output}" != *"concurrent unstaged hunk"* ]]
  run cat "${TEST_REPO_DIR}/partial.py"
  [[ "${output}" == *"concurrent unstaged hunk"* ]]
}

@test "partially-staged .json alongside a .py autofix: json not collapsed, commits staged blob, no abort" {
  install_mock_lint_fixable
  printf 'x = 1\n#LINTDIRTY#\n' > "${TEST_REPO_DIR}/needs_fix.py"
  git -C "${TEST_REPO_DIR}" add needs_fix.py
  printf '{"a": 1}\n' > "${TEST_REPO_DIR}/config.json"
  git -C "${TEST_REPO_DIR}" add config.json
  printf '{"a": 1, "b": "concurrent unstaged key"}\n' > "${TEST_REPO_DIR}/config.json"

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'feat: py fix plus partial json'
  "
  # .json is not a CGW_LINT_EXTENSIONS file and markdownlint never ran, so it
  # is outside cgw_validated_path_set -- the guard must not even look at it,
  # and the partial-stage-aware re-stage must leave it exactly as staged.
  [ "${status}" -eq 0 ]
  run git -C "${TEST_REPO_DIR}" show HEAD:config.json
  [[ "${output}" == *'"a": 1'* ]]
  [[ "${output}" != *"concurrent unstaged key"* ]]
  run cat "${TEST_REPO_DIR}/config.json"
  [[ "${output}" == *"concurrent unstaged key"* ]]
}

@test "fully-staged .py + lint auto-fix still gets re-staged (guards against over-correcting the partial-stage fix)" {
  install_mock_ruff_lint_reformatter
  printf 'x = 1\n#LINTDIRTY#\n' > "${TEST_REPO_DIR}/dirty.py"
  git -C "${TEST_REPO_DIR}" add dirty.py    # staged == disk == lint-dirty, no partial stage

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'feat: fully staged autofix'
  "
  [ "${status}" -eq 0 ]
  run git -C "${TEST_REPO_DIR}" show HEAD:dirty.py
  [[ "${output}" != *"#LINTDIRTY#"* ]]
  run cat "${TEST_REPO_DIR}/dirty.py"
  [[ "${output}" != *"#LINTDIRTY#"* ]]
}

@test "--only prints the staged paths it is about to discard" {
  echo "one" > "${TEST_REPO_DIR}/only_a.txt"
  echo "two" > "${TEST_REPO_DIR}/only_b.txt"
  git -C "${TEST_REPO_DIR}" add only_a.txt only_b.txt
  echo "three" > "${TEST_REPO_DIR}/only_c.txt"

  run _run_commit "--only only_c.txt \"feat: only c\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Currently staged but not matched by --only (will be unstaged): only_a.txt only_b.txt"* ]]
  # Behavior unchanged: exactly the --only path is committed.
  run git -C "${TEST_REPO_DIR}" ls-tree -r --name-only HEAD
  [[ "${output}" == *"only_c.txt"* ]]
  [[ "${output}" != *"only_a.txt"* ]]
  [[ "${output}" != *"only_b.txt"* ]]
  # a.txt/b.txt are unstaged (discarded from the index), not deleted.
  [ -f "${TEST_REPO_DIR}/only_a.txt" ]
  [ -f "${TEST_REPO_DIR}/only_b.txt" ]
}

@test "guard: auto-fix re-stage never pulls in a dirty local-only file" {
  install_mock_ruff_reformatter
  printf 'x = 1\n#UNFORMATTED#\n' > "${TEST_REPO_DIR}/needs_fmt.py"
  git -C "${TEST_REPO_DIR}" add needs_fmt.py
  # A local-only file dirty in the working tree at the same time.
  echo "# secret local notes" > "${TEST_REPO_DIR}/CLAUDE.md"

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD='ruff'
    export CGW_FORMAT_CHECK_ARGS='format --check'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'feat: fix and protect local'
  "
  [ "${status}" -eq 0 ]
  run git -C "${TEST_REPO_DIR}" show HEAD:needs_fmt.py
  [[ "${output}" != *"#UNFORMATTED#"* ]]
  # CLAUDE.md never tracked / never in the commit.
  tracked=$(git -C "${TEST_REPO_DIR}" ls-files CLAUDE.md)
  [ -z "${tracked}" ]
}

# ── Code-quality gate scoping (G1) ────────────────────────────────────────────

@test "lint gate is scoped to staged .py (unrelated dirty .py does not block)" {
  install_mock_lint_content_aware
  # Dirty python elsewhere in the tree, but NOT staged for this commit.
  printf 'LINT-BAD\n' > "${TEST_REPO_DIR}/dirty_unrelated.py"
  # Clean python, staged.
  printf 'x = 1\n' > "${TEST_REPO_DIR}/clean_code.py"
  git -C "${TEST_REPO_DIR}" add clean_code.py
  run _run_commit "--staged-only \"feat: clean code\""
  [ "${status}" -eq 0 ]
  # The dirty unrelated file must never have been handed to the linter.
  ! grep -q "dirty_unrelated.py" "${MOCK_BIN_DIR}/ruff.log"
}

@test "lint gate fails when a staged .py has a violation (content-aware)" {
  install_mock_lint_content_aware
  printf 'LINT-BAD\n' > "${TEST_REPO_DIR}/bad_code.py"
  git -C "${TEST_REPO_DIR}" add bad_code.py
  run _run_commit "--staged-only \"feat: bad staged code\""
  [ "${status}" -eq 1 ]
}

@test "code-quality step is skipped when no staged files match CGW_LINT_EXTENSIONS" {
  install_mock_lint
  printf 'LINT-BAD\n' > "${TEST_REPO_DIR}/unstaged_dirty.py"  # dirty but unstaged
  echo "notes" > "${TEST_REPO_DIR}/notes.txt"
  git -C "${TEST_REPO_DIR}" add notes.txt
  run _run_commit "--staged-only \"chore: non-python commit\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no staged files matching"* ]]
  # Linter never invoked → no log file created.
  [ ! -f "${MOCK_BIN_DIR}/ruff.log" ]
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

# ── markdown lint scoping (A1) ────────────────────────────────────────────────

@test "markdown lint is scoped to staged .md (unrelated dirty .md does not block)" {
  install_mock_markdownlint_content_aware
  # Dirty markdown elsewhere in the tree, but NOT staged for this commit.
  printf 'MDLINT-BAD\n' > "${TEST_REPO_DIR}/dirty_unrelated.md"
  # Clean markdown, staged.
  printf 'clean\n' > "${TEST_REPO_DIR}/clean_doc.md"
  git -C "${TEST_REPO_DIR}" add clean_doc.md
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD='markdownlint-cli2'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'docs: add clean doc'
  "
  [ "${status}" -eq 0 ]
  # The dirty unrelated file must never have been handed to the linter.
  ! grep -q "dirty_unrelated.md" "${MOCK_BIN_DIR}/mdlint.log"
}

@test "markdown lint fails when a staged .md has a violation (content-aware)" {
  install_mock_markdownlint_content_aware
  printf 'MDLINT-BAD\n' > "${TEST_REPO_DIR}/bad_doc.md"
  git -C "${TEST_REPO_DIR}" add bad_doc.md
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD='markdownlint-cli2'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'docs: bad staged md'
  "
  [ "${status}" -eq 1 ]
}

@test "markdown lint step is skipped when no .md files are staged" {
  install_mock_markdownlint_content_aware
  printf 'MDLINT-BAD\n' > "${TEST_REPO_DIR}/unstaged.md"  # dirty but unstaged
  echo "code" > "${TEST_REPO_DIR}/code.txt"
  git -C "${TEST_REPO_DIR}" add code.txt
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD='markdownlint-cli2'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'feat: code only'
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no staged .md files"* ]]
  # Linter never invoked → no log file created.
  [ ! -f "${MOCK_BIN_DIR}/mdlint.log" ]
}

@test "non-interactive markdown auto-fix rewrites the file and re-stages it before committing" {
  install_mock_markdownlint_fixable
  printf 'title\n\nMDLINT-BAD\n' > "${TEST_REPO_DIR}/fixme.md"
  git -C "${TEST_REPO_DIR}" add fixme.md
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD='markdownlint-cli2'
    export CGW_MARKDOWNLINT_ARGS=''
    export CGW_MARKDOWNLINT_FIX_ARGS='--fix'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'docs: fix markdown'
  "
  [ "${status}" -eq 0 ]
  # Working tree file was rewritten by the fix.
  run grep -x "MDLINT-BAD" "${TEST_REPO_DIR}/fixme.md"
  [ "${status}" -ne 0 ]
  # The commit picked up the fixed content -- re-staging worked, not the stale
  # pre-fix blob (which would still trip the congruence guard or ship the bug).
  run bash -c "cd '${TEST_REPO_DIR}' && git show HEAD:fixme.md"
  [[ "${output}" != *"MDLINT-BAD"* ]]
  # No divergence between index and worktree left behind for the fixed file
  # (a leftover "logs/" dir from run_tool_with_logging is expected and unrelated).
  run bash -c "cd '${TEST_REPO_DIR}' && git status --porcelain -- fixme.md"
  [ -z "${output}" ]
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

# ── Commit subject length (Pro Git recommendation) ────────────────────────────

@test "subject 51-72 chars prints advisory tip and still commits" {
  echo "content" > "${TEST_REPO_DIR}/subject_soft.txt"
  git -C "${TEST_REPO_DIR}" add subject_soft.txt
  local subject
  subject="$(printf 'a%.0s' {1..60})"
  run _run_commit "\"feat: ${subject}\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Tip: subject after prefix is 60 chars"* ]]
  [[ "${output}" == *"COMMIT SUCCESSFUL"* ]]
}

@test "subject over 72 chars blocks commit in non-interactive mode" {
  echo "content" > "${TEST_REPO_DIR}/subject_hard.txt"
  git -C "${TEST_REPO_DIR}" add subject_hard.txt
  local subject
  subject="$(printf 'a%.0s' {1..80})"
  run _run_commit "\"feat: ${subject}\""
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"over the 72-char hard cap"* ]]
  [[ "${output}" != *"COMMIT SUCCESSFUL"* ]]
}

@test "subject over 72 chars with CGW_ENFORCE_SUBJECT_LENGTH=0 warns but commits" {
  echo "content" > "${TEST_REPO_DIR}/subject_hard_bypass.txt"
  git -C "${TEST_REPO_DIR}" add subject_hard_bypass.txt
  local subject
  subject="$(printf 'a%.0s' {1..80})"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    export CGW_ENFORCE_SUBJECT_LENGTH=0
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' \"feat: ${subject}\"
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"over the 72-char hard cap"* ]]
  [[ "${output}" == *"COMMIT SUCCESSFUL"* ]]
}

# ── CGW_FREEFORM_MESSAGE_BRANCHES ───────────────────────────────────────────

@test "freeform branch: non-conventional message succeeds and skips the format check" {
  git -C "${TEST_REPO_DIR}" checkout --quiet -b up/x
  echo "content" > "${TEST_REPO_DIR}/freeform_file.txt"
  git -C "${TEST_REPO_DIR}" add freeform_file.txt
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    export CGW_FREEFORM_MESSAGE_BRANCHES='up/*'
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' --skip-lint \"Present track_anything count as a one-channel CHOP\"
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"matches CGW_FREEFORM_MESSAGE_BRANCHES"* ]]
  [[ "${output}" == *"COMMIT SUCCESSFUL"* ]]
}

@test "same non-conventional message still blocked on a non-freeform branch (regression)" {
  # Stays on 'development' (per setup()) -- up/* does not match it.
  echo "content" > "${TEST_REPO_DIR}/freeform_regress.txt"
  git -C "${TEST_REPO_DIR}" add freeform_regress.txt
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    export CGW_FREEFORM_MESSAGE_BRANCHES='up/*'
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' --skip-lint \"Present track_anything count as a one-channel CHOP\"
  "
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"conventional format"* ]] || [[ "${output}" == *"conventional"* ]]
}

@test "freeform branch: 120-char subject containing a colon is not blocked by the hard cap" {
  # Regression for the mis-measure bug: stripping at the first colon (the
  # non-freeform "type:" strip) would cut this subject down to whatever
  # follows "Detail:", silently under-counting it. On a freeform branch the
  # WHOLE line must be measured instead, so the tip reports the true length.
  git -C "${TEST_REPO_DIR}" checkout --quiet -b up/y
  echo "content" > "${TEST_REPO_DIR}/freeform_long_subject.txt"
  git -C "${TEST_REPO_DIR}" add freeform_long_subject.txt
  local subject
  subject="Detail: $(printf 'a%.0s' {1..112})"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    export CGW_FREEFORM_MESSAGE_BRANCHES='up/*'
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' --skip-lint \"${subject}\"
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Tip: subject is 120 chars"* ]]
  [[ "${output}" != *"over the 72-char hard cap"* ]]
  [[ "${output}" == *"COMMIT SUCCESSFUL"* ]]
}

@test "same 120-char subject still blocked on a non-freeform branch (regression)" {
  # Stays on 'development' -- the freeform exemption (format skip AND the
  # advisory-only hard cap) must not leak to a branch that doesn't match
  # CGW_FREEFORM_MESSAGE_BRANCHES, even with the setting configured.
  echo "content" > "${TEST_REPO_DIR}/regress_long_subject.txt"
  git -C "${TEST_REPO_DIR}" add regress_long_subject.txt
  local subject
  subject="Detail: $(printf 'a%.0s' {1..112})"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    export CGW_FREEFORM_MESSAGE_BRANCHES='up/*'
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' --skip-lint \"${subject}\"
  "
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"conventional format"* ]] || [[ "${output}" == *"conventional"* ]]
}

# Regression: length must be measured from the subject LINE only, not the
# whole multi-line message. commit_msg is "subject\n\nbody...trailers", and
# stripping "*: " against the full string previously swallowed the body into
# the "summary" length, false-positiving the hard cap on any commit with a
# normal-length body (see Error_log.md / commit history for the real-world
# repro: a 61-char subject measured as 595 chars and blocked the commit).

@test "short subject with long multi-line body is not measured against the body" {
  echo "content" > "${TEST_REPO_DIR}/subject_short_long_body.txt"
  git -C "${TEST_REPO_DIR}" add subject_short_long_body.txt
  local body_filler msg
  body_filler="$(printf 'b%.0s' {1..120})"
  msg=$'fix: short subject\n\nDetail: '"${body_filler}"$'\n\nCo-Authored-By: Test <test@example.com>'
  run _run_commit "\"${msg}\""
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"hard cap"* ]]
  [[ "${output}" != *"Tip: subject after prefix"* ]]
  [[ "${output}" == *"COMMIT SUCCESSFUL"* ]]
}

@test "60-char subject with long body still reports 60 chars, not body length" {
  echo "content" > "${TEST_REPO_DIR}/subject_soft_long_body.txt"
  git -C "${TEST_REPO_DIR}" add subject_soft_long_body.txt
  local subject body_filler msg
  subject="$(printf 'a%.0s' {1..60})"
  body_filler="$(printf 'b%.0s' {1..120})"
  msg=$'feat: '"${subject}"$'\n\nDetail: '"${body_filler}"
  run _run_commit "\"${msg}\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Tip: subject after prefix is 60 chars"* ]]
  [[ "${output}" != *"hard cap"* ]]
  [[ "${output}" == *"COMMIT SUCCESSFUL"* ]]
}

# Regression: cgw_validate_commit_message only requires "type:" (colon, no
# mandatory space), so "type:subject" is a valid prefix. The old
# "${_subject_line#*: }" strip only matched on colon+space, leaving the
# 5-char "feat:" prefix attached to the measured summary on a no-space
# subject and inflating the count past the soft cap for subjects that should
# pass silently.
@test "subject with no space after colon is measured without the prefix" {
  echo "content" > "${TEST_REPO_DIR}/subject_no_space_colon.txt"
  git -C "${TEST_REPO_DIR}" add subject_no_space_colon.txt
  local subject msg
  subject="$(printf 'a%.0s' {1..48})"
  msg="feat:${subject}"
  run _run_commit "\"${msg}\""
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"Tip: subject after prefix"* ]]
  [[ "${output}" != *"hard cap"* ]]
  [[ "${output}" == *"COMMIT SUCCESSFUL"* ]]
}

# ── Extra positional arguments ────────────────────────────────────────────────
# A second bare positional used to silently replace the commit message (the
# classic shape: `--only path1 path2 "msg"`, where path2 became the message
# and the real message overwrote it unnoticed). It must be a hard error with
# per-path guidance instead.

@test "second bare positional errors instead of silently replacing the message" {
  echo "content" > "${TEST_REPO_DIR}/extra_pos.txt"
  git -C "${TEST_REPO_DIR}" add extra_pos.txt
  run _run_commit "--only extra_pos.txt stray_path.txt \"feat: message\""
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Unexpected extra positional argument"* ]]
  [[ "${output}" == *"repeat --only per path"* ]]
}

# ── --skip-lint visibility ────────────────────────────────────────────────────

@test "--skip-lint prints a prominent bypass notice at gate and in summary" {
  echo "content" > "${TEST_REPO_DIR}/skip_notice.txt"
  git -C "${TEST_REPO_DIR}" add skip_notice.txt
  run _run_commit "--skip-lint \"feat: bypass notice check\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[skip-lint] Lint gate BYPASSED for this commit"* ]]
  [[ "${output}" == *"[skip-lint] Lint gate was bypassed for this commit"* ]]
  [[ "${output}" == *"COMMIT SUCCESSFUL"* ]]
}
