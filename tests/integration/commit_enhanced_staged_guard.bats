#!/usr/bin/env bats
# tests/integration/commit_enhanced_staged_guard.bats - Integration tests for commit_enhanced.sh (staged-blob congruence guard [3.5] and partial staging)
# Runs: bats tests/integration/commit_enhanced_staged_guard.bats

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

