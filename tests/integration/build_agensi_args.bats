#!/usr/bin/env bats
# tests/integration/build_agensi_args.bats - scripts/dev/build_agensi.sh skill-name validation
# A skill name must never reach a delete unless it is one of `--list`. A stub `zip` is put on
# PATH so the check runs on hosts without zip (Git for Windows) and reaches the same code as CI.
# Runs: bats tests/integration/build_agensi_args.bats

bats_require_minimum_version 1.5.0

setup() {
  export CGW_ROOT="${BATS_TEST_DIRNAME}/../.."
  mkdir -p "${BATS_TEST_TMPDIR}/bin" "${BATS_TEST_TMPDIR}/sandbox/out"
  printf '#!/bin/sh\nexit 0\n' >"${BATS_TEST_TMPDIR}/bin/zip"
  chmod 755 "${BATS_TEST_TMPDIR}/bin/zip"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  SANDBOX="${BATS_TEST_TMPDIR}/sandbox"
  echo keep >"${SANDBOX}/keep.txt"
  echo keep >"${SANDBOX}/out/inside.txt"
}

_build() {
  run --separate-stderr bash "${CGW_ROOT}/scripts/dev/build_agensi.sh" --out "$@"
}

# Survival is asserted before the message so a failing run names the deleted file first.
@test "build_agensi args: a '..' skill name is refused and deletes nothing" {
  _build "${SANDBOX}/out" ..
  [ -f "${SANDBOX}/keep.txt" ]
  [ -f "${SANDBOX}/out/inside.txt" ]
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"unknown skill"* ]]
}

@test "build_agensi args: a '.' skill name is refused and the output directory survives" {
  _build "${SANDBOX}/out" .
  [ -f "${SANDBOX}/out/inside.txt" ]
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"unknown skill"* ]]
}

@test "build_agensi args: an empty skill name is refused and the output directory survives" {
  _build "${SANDBOX}/out" ""
  [ -f "${SANDBOX}/out/inside.txt" ]
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"unknown skill"* ]]
}

@test "build_agensi args: a path that resolves to a known skill's parent is refused" {
  _build "${SANDBOX}/out" safe-git-workflow/..
  [ -f "${SANDBOX}/keep.txt" ]
  [ -f "${SANDBOX}/out/inside.txt" ]
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"unknown skill"* ]]
}

@test "build_agensi args: a traversal name that names a sibling of the output directory deletes nothing" {
  # agensi/../scripts exists in the repo, so the old directory check let it through and the
  # delete then hit <out>/../scripts, a sibling of the output directory.
  mkdir -p "${SANDBOX}/scripts"
  echo keep >"${SANDBOX}/scripts/inside.txt"
  _build "${SANDBOX}/out" ../scripts
  [ -f "${SANDBOX}/scripts/inside.txt" ]
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"unknown skill"* ]]
}

@test "build_agensi args: a bad name beside a valid one builds nothing and creates no output directory" {
  _build "${SANDBOX}/fresh" safe-git-workflow ..
  [ ! -e "${SANDBOX}/fresh" ]
  [ -f "${SANDBOX}/keep.txt" ]
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"unknown skill"* ]]
}
