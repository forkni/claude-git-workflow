#!/usr/bin/env bats
# tests/integration/dogfood.bats - this repo's own CGW installation tracks its sources
# Runs: bats tests/integration/dogfood.bats
#
# The hooks in .git/hooks/ and the git-ignored Claude Code copies under .claude/ are
# installed from hooks/, skill/ and command/. When they drift, the repo dogfoods a
# stale toolkit (the agent loads an old skill, commits run an old pre-commit). Every
# test skips when the installed artefact is absent (CI checkouts have none), so the
# suite only enforces freshness where something is actually installed.

bats_require_minimum_version 1.5.0
load '../helpers/setup'

# Compare two files after stripping CRs: configure.sh may write CRLF on Windows, and
# process substitution is not available on Git Bash.
_assert_same_lf() {
  local src="$1" inst="$2"
  tr -d '\r' <"${src}" >"${BATS_TEST_TMPDIR}/src"
  tr -d '\r' <"${inst}" >"${BATS_TEST_TMPDIR}/inst"
  cmp "${BATS_TEST_TMPDIR}/src" "${BATS_TEST_TMPDIR}/inst"
}

_installed_hook_or_skip() {
  local hook="${CGW_PROJECT_ROOT}/.git/hooks/$1"
  [[ -f "${hook}" ]] || skip "no installed $1 hook"
  grep -q 'claude-git-workflow' "${hook}" || skip "installed $1 hook is not a CGW hook"
}

@test "dogfood: installed pre-commit hook matches hooks/pre-commit" {
  _installed_hook_or_skip pre-commit
  _assert_same_lf "${CGW_PROJECT_ROOT}/hooks/pre-commit" "${CGW_PROJECT_ROOT}/.git/hooks/pre-commit"
}

@test "dogfood: installed pre-push hook matches hooks/pre-push" {
  _installed_hook_or_skip pre-push
  _assert_same_lf "${CGW_PROJECT_ROOT}/hooks/pre-push" "${CGW_PROJECT_ROOT}/.git/hooks/pre-push"
}

@test "dogfood: installed pre-rebase hook matches hooks/pre-rebase" {
  _installed_hook_or_skip pre-rebase
  _assert_same_lf "${CGW_PROJECT_ROOT}/hooks/pre-rebase" "${CGW_PROJECT_ROOT}/.git/hooks/pre-rebase"
}

@test "dogfood: local skill copy matches skill/" {
  local copy="${CGW_PROJECT_ROOT}/.claude/skills/auto-git-workflow"
  [[ -d "${copy}" ]] || skip "no local skill copy"
  run diff -r "${CGW_PROJECT_ROOT}/skill" "${copy}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "dogfood: local command copy matches command/auto-git-workflow-cmd.md" {
  local copy="${CGW_PROJECT_ROOT}/.claude/commands/auto-git-workflow-cmd.md"
  [[ -f "${copy}" ]] || skip "no local command copy"
  cmp "${CGW_PROJECT_ROOT}/command/auto-git-workflow-cmd.md" "${copy}"
}

@test "dogfood: scripts/test/run_tests.sh (the pre-push shell-quality gate) is clean over the whole tree" {
  [[ -x "${CGW_PROJECT_ROOT}/scripts/test/run_tests.sh" ]] || skip "no pre-push gate script"
  run --separate-stderr "${CGW_PROJECT_ROOT}/scripts/test/run_tests.sh" --all
  [ "${status}" -eq 0 ]
  [[ "${stderr}" == *"shellcheck clean"* || "${stderr}" == *"shellcheck is not runnable"* ]]
}
