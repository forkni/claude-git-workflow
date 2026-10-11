#!/usr/bin/env bash
# scripts/test/run_tests.sh - local pre-push gate: CI's shell-quality checks
#
# hooks/pre-push runs this file once per push (when it exists and is executable),
# before anything leaves the machine; SKIP_TESTS=1 bypasses it for one push. It
# mirrors the three ShellCheck steps of the "Shell Script Quality" job in
# .github/workflows/branch-protection.yml, so a push cannot reach CI with a
# ShellCheck verdict the author has not already seen -- including the tests pass
# over tests/**/*.bats, which no other local gate covers.
#
# Scope: by default only the shell files that differ from the branch's upstream
# (merge-base of HEAD and @{upstream}, falling back to origin/HEAD) are checked,
# which keeps a typical push under a few seconds; the full tree takes ~50s on
# Windows because -x re-parses the shared sources for every script. With no
# upstream at all, or with --all, every file CI checks is checked.
#
# The Bats suite is deliberately not run here (10+ minutes); run tests/run.sh
# before pushing, or rely on CI's "Run Test Suite" job.
#
# Usage: scripts/test/run_tests.sh [--all]
# Exit:  0 clean (also when shellcheck is not runnable: warns, never blocks)
#        1 findings
#        2 usage error
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}" || exit 2

scope="changed"
case "${1:-}" in
  "") ;;
  --all) scope="all" ;;
  -h | --help)
    sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "ERROR: unknown argument: $1 (usage: $0 [--all])" >&2
    exit 2
    ;;
esac

if ! shellcheck --version >/dev/null 2>&1; then
  echo "pre-push gate: shellcheck is not runnable; skipping the shell-quality pass (CI still runs it)" >&2
  exit 0
fi

# ── Scope ───────────────────────────────────────────────────────────────
# Every file CI checks, grouped by the flags CI uses for that group.
scripts_all=(scripts/git/*.sh)
hooks_all=(hooks/pre-commit hooks/pre-push hooks/*.sh)
tests_all=(tests/unit/*.bats tests/integration/*.bats)

base=""
if [[ "${scope}" == "changed" ]]; then
  upstream="$(git rev-parse --verify --quiet '@{upstream}' 2>/dev/null || true)"
  [[ -z "${upstream}" ]] && upstream="$(git rev-parse --verify --quiet 'origin/HEAD' 2>/dev/null || true)"
  [[ -n "${upstream}" ]] && base="$(git merge-base HEAD "${upstream}" 2>/dev/null || true)"
  if [[ -z "${base}" ]]; then
    echo "pre-push gate: no upstream to diff against; checking every file" >&2
    scope="all"
  fi
fi

# The changed set: files that differ from the base (working tree vs base, so
# uncommitted edits count too) plus untracked files, which git diff never lists.
# Read once; each candidate group is then filtered against it.
declare -A changed=()
if [[ "${scope}" == "changed" ]]; then
  while IFS= read -r f; do
    [[ -n "${f}" ]] && changed["${f}"]=1
  done <<<"$(
    git diff --name-only "${base}" -- scripts/git hooks tests
    git ls-files --others --exclude-standard -- scripts/git hooks tests
  )"
fi

# _select <out-array-name> <candidates...>: keep the candidates in scope.
_select() {
  local -n _out="$1"
  shift
  _out=()
  local f
  for f in "$@"; do
    [[ -f "${f}" ]] || continue
    if [[ "${scope}" == "all" || -n "${changed[${f}]:-}" ]]; then
      _out+=("${f}")
    fi
  done
}
scripts_sel=() hooks_sel=() tests_sel=()
_select scripts_sel "${scripts_all[@]}"
_select hooks_sel "${hooks_all[@]}"
_select tests_sel "${tests_all[@]}"

if [[ "${scope}" == "changed" ]]; then
  echo "pre-push gate: shellcheck over files changed since ${base:0:7} (${#scripts_sel[@]} scripts, ${#hooks_sel[@]} hooks, ${#tests_sel[@]} tests)" >&2
else
  echo "pre-push gate: shellcheck over every file CI checks (${#scripts_sel[@]} scripts, ${#hooks_sel[@]} hooks, ${#tests_sel[@]} tests)" >&2
fi

# ── Passes (flags identical to branch-protection.yml) ───────────────────
rc=0
_pass() {
  local label="$1"
  shift
  [[ $# -eq 0 ]] && return 0
  if ! "$@"; then
    echo "pre-push gate: shellcheck ${label} FAILED" >&2
    rc=1
  fi
}
[[ ${#scripts_sel[@]} -gt 0 ]] && _pass "scripts/git" shellcheck -x --severity=error --source-path=scripts/git "${scripts_sel[@]}"
[[ ${#hooks_sel[@]} -gt 0 ]] && _pass "hooks" shellcheck -x --severity=error --source-path=hooks "${hooks_sel[@]}"
[[ ${#tests_sel[@]} -gt 0 ]] && _pass "tests" shellcheck --shell=bash --severity=error "${tests_sel[@]}"

if [[ ${rc} -ne 0 ]]; then
  echo "pre-push gate: fix the findings above, or bypass once with SKIP_TESTS=1 git push" >&2
else
  echo "pre-push gate: shellcheck clean" >&2
fi
exit "${rc}"
