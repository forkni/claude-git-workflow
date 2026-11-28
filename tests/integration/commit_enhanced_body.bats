#!/usr/bin/env bats
# tests/integration/commit_enhanced_body.bats - Integration tests for commit_enhanced.sh --body / --body-file
# Runs: bats tests/integration/commit_enhanced_body.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'
load '_commit_common'

# Run commit_enhanced.sh with each argument passed through as one word, so a
# multi-line body needs no inner quoting (unlike _run_commit, which joins its
# arguments into one bash -c string).
_run_commit_args() {
  (
    cd "${TEST_REPO_DIR}" || exit 1
    export SCRIPT_DIR="${CGW_PROJECT_ROOT}/scripts/git"
    export PROJECT_ROOT="${TEST_REPO_DIR}"
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    bash "${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh" "$@"
  )
}

# Stage one new file for the next commit.
_stage() {
  echo "content" >"${TEST_REPO_DIR}/$1"
  git -C "${TEST_REPO_DIR}" add "$1"
}

_last_message() {
  git -C "${TEST_REPO_DIR}" log -1 --format=%B
}

@test "--body adds a paragraph after one blank line" {
  _stage body_one.txt
  run _run_commit_args --only body_one.txt "feat: add body" --body "Why this change is needed."
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"COMMIT SUCCESSFUL"* ]]
  [ "$(_last_message)" = $'feat: add body\n\nWhy this change is needed.' ]
}

@test "repeated --body keeps the order, and a last Co-Authored-By paragraph is a git trailer" {
  _stage body_trailer.txt
  run _run_commit_args --only body_trailer.txt "fix: guard nil response" \
    --body "First paragraph." \
    --body "Second paragraph." \
    --body "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
  [ "${status}" -eq 0 ]
  [ "$(_last_message)" = $'fix: guard nil response\n\nFirst paragraph.\n\nSecond paragraph.\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>' ]
  [ "$(git -C "${TEST_REPO_DIR}" log -1 --format='%(trailers:key=Co-Authored-By,valueonly)')" = "Claude Opus 5.5 <noreply@anthropic.com>" ]
  # The subject line stays the subject.
  [ "$(git -C "${TEST_REPO_DIR}" log -1 --format=%s)" = "fix: guard nil response" ]
}

@test "a --body that is only a trailer is still separated from the subject" {
  _stage body_only_trailer.txt
  run _run_commit_args --only body_only_trailer.txt "chore: bump" --body "Co-Authored-By: A <a@example.com>"
  [ "${status}" -eq 0 ]
  [ "$(_last_message)" = $'chore: bump\n\nCo-Authored-By: A <a@example.com>' ]
  [ "$(git -C "${TEST_REPO_DIR}" log -1 --format='%(trailers:key=Co-Authored-By,valueonly)')" = "A <a@example.com>" ]
}

@test "--body keeps the line breaks inside its text" {
  _stage body_lines.txt
  run _run_commit_args --only body_lines.txt "docs: list steps" --body $'- step one\n- step two'
  [ "${status}" -eq 0 ]
  [ "$(_last_message)" = $'docs: list steps\n\n- step one\n- step two' ]
}

@test "--body-file keeps line breaks and blank lines between paragraphs" {
  _stage body_file.txt
  printf 'Line one\nline two\n\nCo-Authored-By: B <b@example.com>\n\n' >"${BATS_TEST_TMPDIR}/body.txt"
  run _run_commit_args --only body_file.txt "feat: from file" --body-file "${BATS_TEST_TMPDIR}/body.txt"
  [ "${status}" -eq 0 ]
  [ "$(_last_message)" = $'feat: from file\n\nLine one\nline two\n\nCo-Authored-By: B <b@example.com>' ]
  [ "$(git -C "${TEST_REPO_DIR}" log -1 --format='%(trailers:key=Co-Authored-By,valueonly)')" = "B <b@example.com>" ]
}

@test "--body-file - reads the body from stdin" {
  _stage body_stdin.txt
  run _run_commit_args --only body_stdin.txt "feat: from stdin" --body-file - <<<$'Read from stdin.\n\nCo-Authored-By: C <c@example.com>'
  [ "${status}" -eq 0 ]
  [ "$(_last_message)" = $'feat: from stdin\n\nRead from stdin.\n\nCo-Authored-By: C <c@example.com>' ]
}

# The pipe held the body, not answers: the no-TTY prompts must not report a piped
# answer as ignored (the flag here comes from the no-TTY rule, not the env).
@test "--body-file - with no TTY prints no piped-answer notice" {
  _stage body_stdin_notice.txt
  run bash -c '
    unset CGW_NON_INTERACTIVE CLAUDE_GIT_NON_INTERACTIVE
    cd "$1" || exit 1
    export SCRIPT_DIR="$2/scripts/git" PROJECT_ROOT="$1" CGW_LINT_CMD=ruff CGW_FORMAT_CMD=""
    printf "Body.\n" | bash "$2/scripts/git/commit_enhanced.sh" --only body_stdin_notice.txt "feat: notice" --body-file -
  ' _ "${TEST_REPO_DIR}" "${CGW_PROJECT_ROOT}"
  [ "${status}" -eq 0 ]
  [ "$(_last_message)" = $'feat: notice\n\nBody.' ]
  [[ "${output}" != *"piped answer ignored"* ]]
}

@test "--body and --body-file mix in the order given" {
  _stage body_mixed.txt
  printf 'Middle\n' >"${BATS_TEST_TMPDIR}/middle.txt"
  run _run_commit_args --body "First" --only body_mixed.txt --body-file "${BATS_TEST_TMPDIR}/middle.txt" "feat: mixed" --body "Last"
  [ "${status}" -eq 0 ]
  [ "$(_last_message)" = $'feat: mixed\n\nFirst\n\nMiddle\n\nLast' ]
}

@test "a subject-only call still commits the subject alone" {
  _stage subject_only.txt
  run _run_commit_args --only subject_only.txt "feat: plain subject"
  [ "${status}" -eq 0 ]
  [ "$(_last_message)" = "feat: plain subject" ]
}

@test "a long body line is not measured against the subject caps" {
  _stage body_long_line.txt
  run _run_commit_args --only body_long_line.txt "fix: short" --body "$(printf 'b%.0s' {1..200})"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"hard cap"* ]]
  [[ "${output}" != *"Tip: subject after prefix"* ]]
}

@test "a conventional body line does not let a non-conventional subject through" {
  _stage body_no_rescue.txt
  run _run_commit_args --only body_no_rescue.txt "Add a thing" --body "fix: this line is in the body"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"conventional"* ]]
  [[ "${output}" != *"COMMIT SUCCESSFUL"* ]]
}

@test "an over-cap subject with a body is refused with an [ERROR] on stderr" {
  _stage body_long_subject.txt
  local subject
  subject="feat: $(printf 'a%.0s' {1..78})"
  [ "${#subject}" -eq 84 ]
  run --separate-stderr _run_commit_args --only body_long_subject.txt "${subject}" --body "Detail."
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"[ERROR] No commit made: the subject after the prefix is 78 chars, over the 72-char hard cap"* ]]
  [[ "${stderr}" == *"--body"* ]]
  [[ "${output}" != *"COMMIT SUCCESSFUL"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" log -1 --format=%s)" != "${subject}" ]
}

@test "CGW_FREEFORM_MESSAGE_CHECK sees the body (a commit-msg style trailer check passes)" {
  git -C "${TEST_REPO_DIR}" checkout --quiet -b up/body
  _stage body_freeform.txt
  local check="${BATS_TEST_TMPDIR}/require_signoff.sh"
  # shellcheck disable=SC2016 # $1 belongs to the written check script
  printf '#!/usr/bin/env bash\ngrep -q "^Signed-off-by: " "$1"\n' >"${check}"
  chmod +x "${check}"
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    export CGW_FREEFORM_MESSAGE_BRANCHES='up/*'
    export CGW_FREEFORM_MESSAGE_CHECK='${check}'
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' --skip-lint --only body_freeform.txt \
      'Upstream style subject' --body 'Signed-off-by: D <d@example.com>'
  "
  [ "${status}" -eq 0 ]
  [ "$(_last_message)" = $'Upstream style subject\n\nSigned-off-by: D <d@example.com>' ]
}

# ── argument errors ────────────────────────────────────────────────────────────

@test "--body with no text exits 1" {
  run _run_commit_args "feat: x" --body
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"--body requires a text argument"* ]]
}

@test "--body followed by a flag exits 1 instead of eating the flag" {
  run _run_commit_args --body --only x.txt "feat: x"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"--body requires a text argument"* ]]
}

@test "--body with blank text exits 1" {
  run _run_commit_args "feat: x" --body "   "
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"--body text is empty"* ]]
}

@test "--body-file with a missing file exits 1" {
  run _run_commit_args "feat: x" --body-file "${BATS_TEST_TMPDIR}/nope.txt"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"--body-file: cannot read"* ]]
}

@test "--body-file with an empty file exits 1" {
  : >"${BATS_TEST_TMPDIR}/empty.txt"
  run _run_commit_args "feat: x" --body-file "${BATS_TEST_TMPDIR}/empty.txt"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"the body is empty"* ]]
}

@test "--body without a subject exits 1 before the lint step and names the positional subject" {
  _stage body_no_subject.txt
  run _run_commit_args --only body_no_subject.txt --body "Only a body"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"the subject is still the positional message"* ]]
  [[ "${output}" != *"[5/6]"* ]]
}

@test "--body-file - given twice exits 1 and names stdin" {
  run _run_commit_args "feat: x" --body-file - --body-file - <<<"text"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"given twice: stdin is read one time only"* ]]
}

@test "--body-file - with --interactive exits 1 instead of starving the prompts" {
  run _run_commit_args --interactive "feat: x" --body-file - <<<"text"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"an interactive run needs for its prompts"* ]]
}

@test "a CRLF --body-file commits LF lines and keeps the trailer" {
  _stage body_crlf.txt
  printf 'Line one\r\n\r\nCo-Authored-By: E <e@example.com>\r\n' >"${BATS_TEST_TMPDIR}/crlf.txt"
  run _run_commit_args --only body_crlf.txt "feat: crlf body" --body-file "${BATS_TEST_TMPDIR}/crlf.txt"
  [ "${status}" -eq 0 ]
  [ "$(_last_message)" = $'feat: crlf body\n\nLine one\n\nCo-Authored-By: E <e@example.com>' ]
  [[ "${output}" != *$'e@example.com>\r'* ]]
}
