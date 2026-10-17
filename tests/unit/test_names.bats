#!/usr/bin/env bats
# Guards the names of the tests themselves.

# Bats finds a test again by its encoded name, and under the non-UTF-8 locale of the Windows CI runner
# it cannot resolve a name holding non-ASCII bytes ("unknown test name"), so those tests are dropped
# from the run with only a warning. Keep @test names ASCII.

@test "every @test name under tests/ is ASCII" {
  run bash -c "grep -rh --include='*.bats' '^@test ' \"${BATS_TEST_DIRNAME}/..\" | LC_ALL=C tr -d '\\11\\12\\15\\40-\\176'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
