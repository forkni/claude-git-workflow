#!/usr/bin/env bats
# tests/integration/commit_enhanced_gates.bats - Integration tests for commit_enhanced.sh (lint/markdown gate scoping, commit message and subject rules)
# Runs: bats tests/integration/commit_enhanced_gates.bats

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
  run ! grep -q "dirty_unrelated.py" "${MOCK_BIN_DIR}/ruff.log"
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

# ── Typecheck is deliberately NOT part of the commit-time gate ────────────────
# Pins the design decision recorded at commit_enhanced.sh's "[3] Code quality
# check" comment: typecheck is whole-project (no honest staged-scoped form)
# and stays advisory-only via hooks/pre-commit; it must never block or even
# run from commit_enhanced.sh itself. No pre-commit hook is installed by this
# file's setup(), so a plain `git commit` here cannot invoke it either.

@test "a failing typecheck tool never blocks or runs during commit_enhanced.sh" {
  MOCK_TYPECHECK_EXIT=1 install_mock_typecheck
  echo "feature content" > "${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_TYPECHECK_CMD=mock-typecheck
    export CGW_TYPECHECK_CHECK_ARGS=''
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' \"feat: add feature file\"
  "
  [ "${status}" -eq 0 ]
  [ ! -f "${MOCK_BIN_DIR}/typecheck.log" ]
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

@test "markdownlint infrastructure crash bypasses auto-fix and succeeds in non-interactive mode" {
  install_mock_markdownlint_crash
  echo "content" > "${TEST_REPO_DIR}/sample.md"
  git -C "${TEST_REPO_DIR}" add sample.md
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD='markdownlint-cli2'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' 'docs: test crash bypass'
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Markdown lint tool failed to execute"* ]]
  [[ "${output}" == *"COMMIT SUCCESSFUL"* ]]
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
  run ! grep -q "dirty_unrelated.md" "${MOCK_BIN_DIR}/mdlint.log"
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

@test "freeform branch: a protected/target branch is never exempted even with a wildcard glob (guard)" {
  # main is CGW_TARGET_BRANCH (and thus CGW_PROTECTED_BRANCHES) here -- a
  # careless CGW_FREEFORM_MESSAGE_BRANCHES="*" must not silently switch off
  # the conventional-format check on the branch the policy exists to protect.
  git -C "${TEST_REPO_DIR}" checkout --quiet main
  echo "content" > "${TEST_REPO_DIR}/freeform_guard.txt"
  git -C "${TEST_REPO_DIR}" add freeform_guard.txt
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    export CGW_FREEFORM_MESSAGE_BRANCHES='*'
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' --skip-lint \"Present track_anything count as a one-channel CHOP\"
  "
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"ignored"* ]]
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

