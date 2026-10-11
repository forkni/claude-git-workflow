#!/usr/bin/env bats
# tests/integration/run_tests_gate.bats - scope selection of scripts/test/run_tests.sh
# Runs: bats tests/integration/run_tests_gate.bats
#
# The pre-push shell-quality gate checks only the shell files that differ from the
# branch's upstream (uncommitted edits and untracked files included), or every file CI
# checks with --all or without an upstream. Each test runs a copy of the script inside a
# throwaway repo with its own remote, so the counts it reports and its verdict follow
# that repo's state alone. Skipped when shellcheck is not runnable (the gate itself
# then warns and exits 0, which dogfood.bats covers).

bats_require_minimum_version 1.5.0
load '../helpers/setup'

setup() {
  shellcheck --version >/dev/null 2>&1 || skip "shellcheck not runnable"
  create_test_repo_with_remote
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  mkdir -p "${TEST_REPO_DIR}/scripts/test" "${TEST_REPO_DIR}/hooks" \
    "${TEST_REPO_DIR}/tests/unit" "${TEST_REPO_DIR}/tests/integration"
  cp "${CGW_PROJECT_ROOT}/scripts/test/run_tests.sh" "${TEST_REPO_DIR}/scripts/test/run_tests.sh"
  # One clean file per group CI checks, committed and pushed: the baseline is "nothing changed".
  printf '#!/usr/bin/env bash\necho ok\n' >"${TEST_REPO_DIR}/scripts/git/clean.sh"
  printf '#!/usr/bin/env bash\necho hook\n' >"${TEST_REPO_DIR}/hooks/pre-commit"
  printf '@test "a" {\n  true\n}\n' >"${TEST_REPO_DIR}/tests/unit/a.bats"
  git -C "${TEST_REPO_DIR}" add -A
  git -C "${TEST_REPO_DIR}" commit --quiet --no-verify -m "chore: seed shell files"
  git -C "${TEST_REPO_DIR}" push --quiet origin development
}

teardown() {
  cleanup_test_repo
}

_gate() {
  bash "${TEST_REPO_DIR}/scripts/test/run_tests.sh" "$@"
}

@test "gate: nothing changed since the upstream checks no file and is clean" {
  run --separate-stderr _gate
  [ "${status}" -eq 0 ]
  [[ "${stderr}" == *"files changed since"*"(0 scripts, 0 hooks, 0 tests)"* ]]
  [[ "${stderr}" == *"shellcheck clean"* ]]
}

@test "gate: an uncommitted edit to a tracked script puts only that file in scope" {
  printf '#!/usr/bin/env bash\necho changed\n' >"${TEST_REPO_DIR}/scripts/git/clean.sh"
  run --separate-stderr _gate
  [ "${status}" -eq 0 ]
  [[ "${stderr}" == *"(1 scripts, 0 hooks, 0 tests)"* ]]
  [[ "${stderr}" == *"shellcheck clean"* ]]
}

@test "gate: a committed but unpushed change is in scope" {
  printf '#!/usr/bin/env bash\necho hook2\n' >"${TEST_REPO_DIR}/hooks/pre-commit"
  git -C "${TEST_REPO_DIR}" commit --quiet --no-verify -am "chore: touch hook"
  run --separate-stderr _gate
  [ "${status}" -eq 0 ]
  [[ "${stderr}" == *"(0 scripts, 1 hooks, 0 tests)"* ]]
}

@test "gate: an untracked bats file counts as changed and its findings fail the gate" {
  # Literal carriage returns are SC1017 at error severity: the finding CI's tests pass
  # would report, and the one the gate exists to catch before the push.
  printf '@test "b" {\r\n  true\r\n}\r\n' >"${TEST_REPO_DIR}/tests/integration/new.bats"
  run --separate-stderr _gate
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"(0 scripts, 0 hooks, 1 tests)"* ]]
  [[ "${stderr}" == *"shellcheck tests FAILED"* ]]
  [[ "${stderr}" == *"SKIP_TESTS=1"* ]]
}

@test "gate: --all checks every file CI checks" {
  run --separate-stderr _gate --all
  [ "${status}" -eq 0 ]
  [[ "${stderr}" == *"every file CI checks (1 scripts, 1 hooks, 1 tests)"* ]]
  [[ "${stderr}" == *"shellcheck clean"* ]]
}

@test "gate: without an upstream every file is checked" {
  git -C "${TEST_REPO_DIR}" checkout --quiet -b topic development
  git -C "${TEST_REPO_DIR}" remote remove origin
  run --separate-stderr _gate
  [ "${status}" -eq 0 ]
  [[ "${stderr}" == *"no upstream to diff against; checking every file"* ]]
  [[ "${stderr}" == *"(1 scripts, 1 hooks, 1 tests)"* ]]
}

@test "gate: an unknown argument is a usage error: exit 2" {
  run --separate-stderr _gate --bogus
  [ "${status}" -eq 2 ]
  [[ "${stderr}" == *"unknown argument: --bogus"* ]]
}
