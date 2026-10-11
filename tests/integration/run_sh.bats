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

@test "run.sh prints the full TAP of a failed file with CGW_TEST_VERBOSE=1" {
  _write_failing_fixture
  run env CGW_TEST_TIMINGS=1 CGW_TEST_VERBOSE=1 bash "${CGW_PROJECT_ROOT}/tests/run.sh" "${BATS_TEST_TMPDIR}/suite"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"ok 1 first test passes"* ]]
  [[ "${output}" == *"not ok 2 second test fails"* ]]
  [[ "${output}" == *"failed: fixture:2 second test fails"* ]]
}
