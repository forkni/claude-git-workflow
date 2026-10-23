#!/usr/bin/env bats
# Guards the SPDX license headers on the files CGW ships into other repos.

# scripts/git/*.sh and hooks/* are copied into consumer repos by configure.sh and
# sync_cgw_tooling.sh, so each carries its own license notice. Tests and CI files are
# not shipped and need none.

@test "every shipped script and hook carries the SPDX MIT header" {
  local root="${BATS_TEST_DIRNAME}/../.."
  run bash -c "grep -L 'SPDX-License-Identifier: MIT' \"${root}\"/scripts/git/*.sh \"${root}\"/hooks/*"
  [ -z "$output" ]
}

@test "every shipped script and hook names the copyright holder" {
  local root="${BATS_TEST_DIRNAME}/../.."
  run bash -c "grep -L 'SPDX-FileCopyrightText: 2026 Alexander Korneev' \"${root}\"/scripts/git/*.sh \"${root}\"/hooks/*"
  [ -z "$output" ]
}
