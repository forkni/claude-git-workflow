#!/usr/bin/env bats
# tests/integration/run_sh.bats - argument handling of tests/run.sh itself
# Runs: bats tests/integration/run_sh.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'

@test "run.sh --help prints usage and exits 0" {
  run bash "${CGW_PROJECT_ROOT}/tests/run.sh" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"tests/run.sh --all"* ]]
}

@test "run.sh --help works via a relative path from outside the repo root" {
  run bash -c "cd '${CGW_PROJECT_ROOT}/scripts' && bash ../tests/run.sh --help"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"tests/run.sh --all"* ]]
}

@test "run.sh rejects an unknown option with exit 2" {
  run bash "${CGW_PROJECT_ROOT}/tests/run.sh" --bogus
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"Unknown option"* ]]
}

@test "run.sh rejects a mode flag that is not the first argument" {
  run bash "${CGW_PROJECT_ROOT}/tests/run.sh" tests/unit --slow
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"must be the first argument"* ]]
}

# A fixture suite with one passing and one failing test, run through the xargs path
# (CGW_TEST_TIMINGS=1 forces it on every OS) so the failure report is what run.sh prints.
_write_failing_fixture() {
  mkdir -p "${BATS_TEST_TMPDIR}/suite"
  cat >"${BATS_TEST_TMPDIR}/suite/fixture.bats" <<'FIXTURE'
@test "first test passes" {
  true
}
@test "second test fails" {
  echo "diagnostic line"
  false
}
FIXTURE
}

@test "run.sh prints a failure digest with the not-ok line and a failed: summary" {
  _write_failing_fixture
  run env CGW_TEST_TIMINGS=1 bash "${CGW_PROJECT_ROOT}/tests/run.sh" "${BATS_TEST_TMPDIR}/suite"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"=== FAILURES: fixture ==="* ]]
  [[ "${output}" == *"not ok 2 second test fails"* ]]
  [[ "${output}" == *"failed: fixture:2 second test fails"* ]]
  [[ "${output}" != *"ok 1 first test passes"* ]]
  [[ "${output}" == *"2 tests, 1 failures, 0 skipped"* ]]
}

# bats can fail a file without printing a `not ok` line (bats 1.14 does so for a file
# with no @test: "Found no tests", exit 1; a killed bats process looks the same). What
# that takes differs between bats versions, so a bats shim on PATH produces the shape
# directly: the behaviour under test is run.sh's digest, not bats.
@test "run.sh names a failed file whose TAP has no not-ok line and hints at CGW_TEST_VERBOSE=1" {
  mkdir -p "${BATS_TEST_TMPDIR}/suite" "${BATS_TEST_TMPDIR}/bin"
  printf '# helpers only, no @test\n_helper() {\n  true\n}\n' >"${BATS_TEST_TMPDIR}/suite/notests.bats"
  printf '#!/usr/bin/env bash\necho "ERROR: Found no tests."\necho "1..0"\nexit 1\n' >"${BATS_TEST_TMPDIR}/bin/bats"
  chmod +x "${BATS_TEST_TMPDIR}/bin/bats"
  run env PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" CGW_TEST_TIMINGS=1 bash "${CGW_PROJECT_ROOT}/tests/run.sh" "${BATS_TEST_TMPDIR}/suite"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"=== FAILURES: notests ==="* ]]
  [[ "${output}" == *"no 'not ok' line"*"CGW_TEST_VERBOSE=1"* ]]
  [[ "${output}" == *"failed: notests (bats exit 1, no not-ok line)"* ]]
}

# Batch selection, observed through CGW_TEST_LIST=1 (prints the chosen files and exits before bats).
_list() {
  run env CGW_TEST_LIST=1 "$@" bash "${CGW_PROJECT_ROOT}/tests/run.sh"
}
_slow_names='dogfood|merge_pr|configure|cc_guardrail|repo_state'
_slow_listing="^tests/integration/(${_slow_names})\.bats\$"

@test "run.sh bare run selects core and fast files and none of the slow files" {
  _list
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"tests/unit/common.bats"* ]]
  [[ "${output}" == *"tests/integration/push_validated.bats"* ]]
  run grep -cE "${_slow_names}" <<<"${output}"
  [ "${output}" = "0" ]
}

@test "run.sh on CI keeps an explicit --fast to the fast files" {
  run env CGW_TEST_LIST=1 CI=true bash "${CGW_PROJECT_ROOT}/tests/run.sh" --fast tests/integration/
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"tests/integration/push_validated.bats"* ]]
  [[ "${output}" != *"tests/unit/"* ]]
  [[ "${output}" != *"tests/integration/merge_pr.bats"* ]]
}

@test "run.sh on CI with no mode flag still selects only core and fast" {
  _list CI=true
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"tests/integration/configure.bats"* ]]
}

@test "run.sh --slow selects exactly the five slow files" {
  run env CGW_TEST_LIST=1 bash "${CGW_PROJECT_ROOT}/tests/run.sh" --slow
  [ "${status}" -eq 0 ]
  run grep -cE "${_slow_listing}" <<<"${output}"
  [ "${output}" = "5" ]
}

@test "run.sh --all and a bare run with CGW_RUN_SLOW=1 select the slow files too" {
  run env CGW_TEST_LIST=1 bash "${CGW_PROJECT_ROOT}/tests/run.sh" --all
  [[ "${output}" == *"tests/integration/merge_pr.bats"* ]]
  [[ "${output}" == *"tests/unit/common.bats"* ]]
  _list CGW_RUN_SLOW=1
  [[ "${output}" == *"tests/integration/merge_pr.bats"* ]]
}

@test "run.sh --slow-changed selects the slow file whose script changed" {
  run env CGW_TEST_LIST=1 CGW_CHANGED_FILES=scripts/git/merge_pr.sh bash "${CGW_PROJECT_ROOT}/tests/run.sh" --slow-changed
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"tests/integration/merge_pr.bats"* ]]
  [[ "${output}" != *"tests/integration/repo_state.bats"* ]]
}

@test "run.sh --slow-changed maps a hook change to dogfood and configure" {
  run env CGW_TEST_LIST=1 CGW_CHANGED_FILES=hooks/pre-push bash "${CGW_PROJECT_ROOT}/tests/run.sh" --slow-changed
  [[ "${output}" == *"tests/integration/dogfood.bats"* ]]
  [[ "${output}" == *"tests/integration/configure.bats"* ]]
  [[ "${output}" != *"tests/integration/merge_pr.bats"* ]]
}

@test "run.sh --slow-changed maps every script a slow file runs to that file" {
  local pair path file
  for pair in \
    "hooks/agy-block-dangerous-git.sh:cc_guardrail" \
    "scripts/git/commit_enhanced.sh:cc_guardrail" \
    "scripts/git/worktree_manage.sh:cc_guardrail" \
    "scripts/git/push_validated.sh:cc_guardrail" \
    "scripts/git/branch_cleanup.sh:cc_guardrail" \
    "scripts/git/rollback_merge.sh:merge_pr" \
    "scripts/git/setup_attributes.sh:configure"; do
    path="${pair%%:*}"
    file="${pair##*:}"
    run env CGW_TEST_LIST=1 CGW_CHANGED_FILES="${path}" bash "${CGW_PROJECT_ROOT}/tests/run.sh" --slow-changed
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"tests/integration/${file}.bats"* ]] || {
      echo "${path} did not select ${file}.bats: ${output}"
      return 1
    }
  done
}

@test "run.sh --slow-changed matches a file trigger exactly, not as a name prefix" {
  run env CGW_TEST_LIST=1 CGW_CHANGED_FILES=$'scripts/git/configure.sh.bak\nscripts/git/merge_pr.shim' bash "${CGW_PROJECT_ROOT}/tests/run.sh" --slow-changed
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no changed slow files"* ]]
}

@test "run.sh --slow-changed selects all slow files when the runner or helpers change" {
  run env CGW_TEST_LIST=1 CGW_CHANGED_FILES=$'README.md\ntests/helpers/setup.bash' bash "${CGW_PROJECT_ROOT}/tests/run.sh" --slow-changed
  run grep -cE "${_slow_listing}" <<<"${output}"
  [ "${output}" = "5" ]
}

@test "run.sh --slow-changed with an unrelated change runs nothing and exits 0" {
  run env CGW_TEST_LIST=1 CGW_CHANGED_FILES=README.md bash "${CGW_PROJECT_ROOT}/tests/run.sh" --slow-changed
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no changed slow files"* ]]
}

@test "run.sh --slow-changed without CGW_CHANGED_FILES exits 2" {
  run env -u CGW_CHANGED_FILES bash "${CGW_PROJECT_ROOT}/tests/run.sh" --slow-changed
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"needs CGW_CHANGED_FILES"* ]]
}

@test "run.sh prints the full TAP of a failed file with CGW_TEST_VERBOSE=1" {
  _write_failing_fixture
  run env CGW_TEST_TIMINGS=1 CGW_TEST_VERBOSE=1 bash "${CGW_PROJECT_ROOT}/tests/run.sh" "${BATS_TEST_TMPDIR}/suite"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"ok 1 first test passes"* ]]
  [[ "${output}" == *"not ok 2 second test fails"* ]]
  [[ "${output}" == *"failed: fixture:2 second test fails"* ]]
}
