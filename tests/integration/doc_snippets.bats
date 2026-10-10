#!/usr/bin/env bats
# tests/integration/doc_snippets.bats - Doc-snippet checks run as part of the suite
# Runs: bats tests/integration/doc_snippets.bats
#
# The skill and command docs hold bash snippets that agents run verbatim. Two checkers
# keep them honest: lint_doc_snippets.sh (syntax, shellcheck, unbounded loops) and
# verify_skill_commands.sh (documented scripts and flags exist). Running both here wires
# them into tests/run.sh and CI without a separate workflow step.

bats_require_minimum_version 1.5.0
load '../helpers/setup'

LINTER="${BATS_TEST_DIRNAME}/../lint_doc_snippets.sh"

setup() {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  DOC="${BATS_TEST_TMPDIR}/doc.md"
}

# _write_doc <snippet...>: write a one-block markdown doc whose bash fence holds the arguments, one per line
_write_doc() {
  {
    printf '# Doc\n\n```bash\n'
    printf '%s\n' "$@"
    printf '```\n'
  } >"${DOC}"
}

@test "shipped skill and command docs have no snippet findings" {
  run bash "${LINTER}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"0 finding(s)"* ]]
}

@test "documented scripts and flags match the real scripts" {
  run bash "${BATS_TEST_DIRNAME}/../verify_skill_commands.sh"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Failed: 0"* ]]
}

@test "lint_doc_snippets accepts a well-formed snippet" {
  _write_doc 'for _ in $(seq 3); do' '  echo "try"' 'done'
  run bash "${LINTER}" "${DOC}"
  [ "${status}" -eq 0 ]
}

@test "lint_doc_snippets rejects a syntax error" {
  _write_doc 'if true; then' '  echo "no fi"'
  run bash "${LINTER}" "${DOC}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"bash -n"* ]]
}

@test "lint_doc_snippets rejects a variable used but never assigned" {
  _write_doc 'gh pr checks "$pr_number" --repo "$repo"'
  run bash "${LINTER}" "${DOC}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"SC2154"* ]]
}

@test "lint_doc_snippets rejects an unbounded wait loop" {
  _write_doc 'until gh pr checks 1 >/dev/null 2>&1; do' '  sleep 5' 'done'
  run bash "${LINTER}" "${DOC}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"unbounded wait loop"* ]]
}

@test "lint_doc_snippets accepts a bounded wait loop" {
  _write_doc 'for _ in $(seq 12); do' '  gh pr checks 1 >/dev/null 2>&1 && break' '  sleep 5' 'done'
  run bash "${LINTER}" "${DOC}"
  [ "${status}" -eq 0 ]
}

@test "lint_doc_snippets replaces <placeholder> tokens before linting" {
  _write_doc 'git checkout <branch>' 'git merge {source}'
  run bash "${LINTER}" "${DOC}"
  [ "${status}" -eq 0 ]
}

@test "lint_doc_snippets skips a block marked snippet-lint: skip" {
  {
    printf '<!-- snippet-lint: skip -->\n```bash\nif true; then\n```\n'
  } >"${DOC}"
  run bash "${LINTER}" "${DOC}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "0 snippet(s) checked"* ]]
}

@test "lint_doc_snippets ignores fences that are not bash" {
  printf '```text\nif true; then\n```\n' >"${DOC}"
  run bash "${LINTER}" "${DOC}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "0 snippet(s) checked"* ]]
}
