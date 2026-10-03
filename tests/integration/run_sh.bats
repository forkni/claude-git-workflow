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
