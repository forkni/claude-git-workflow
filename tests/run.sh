#!/usr/bin/env bash
# tests/run.sh — run the CGW bats suite in parallel
# Usage:
#   tests/run.sh                          # core + fast: tests/unit/ and tests/integration/ minus the slow files (default)
#   tests/run.sh --fast [paths]           # same, for the given paths; the slow files are dropped even on CI
#   tests/run.sh --slow                   # slow batch only (the files in CGW_SLOW_FILES; the monthly workflow)
#   tests/run.sh --slow-changed           # slow files whose file or covered script is in CGW_CHANGED_FILES (PR gate)
#   tests/run.sh --all                    # core + fast + slow; same as a bare run with CGW_RUN_SLOW=1
#   CGW_CHANGED_FILES=<paths> ...         # newline-separated repo paths for --slow-changed (empty = nothing changed)
#   CGW_TEST_LIST=1 tests/run.sh ...      # print the selected files, one per line, and exit without running bats
#   CGW_TEST_TIMINGS=1 tests/run.sh ...   # print the slowest files afterwards (to retune CGW_SLOW_FILES)
#   CGW_TEST_VERBOSE=1 tests/run.sh ...   # print the full TAP of each failed file (default: failures only)
#   tests/run.sh tests/unit/              # unit tests only  (~25s)
#   tests/run.sh tests/unit/config.bats   # single file
#   CGW_TEST_JOBS=N tests/run.sh          # override parallelism (default: half logical cores)
#   CGW_RUN_SLOW=1 tests/run.sh           # a bare run includes the slow files (same as --all; an explicit mode flag wins)
#   tests/run.sh --help                   # print this usage
#   tests/run.sh --version                # print the bats version and CGW revision this run would use
set -uo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_self="${_dir}/$(basename "${BASH_SOURCE[0]}")"
cd "${_dir}/.." || exit 1

_usage() {
  sed -n '2,/^set -uo/p' "${_self}" | sed '$d; s/^# \{0,1\}//'
}

case "${1:-}" in
  -h | --help)
    _usage
    exit 0
    ;;
  -V | --version)
    echo "CGW tests/run.sh @ $(git describe --tags --always --dirty 2>/dev/null || echo unknown)"
    bats --version
    exit 0
    ;;
esac

# Mode flags are only consumed in the first position (below); any other
# dash-argument would otherwise be handed to find/bats as a "path".
_pos=0
for _arg in "$@"; do
  _pos=$((_pos + 1))
  case "${_arg}" in
    --slow | --slow-changed | --all | --fast)
      if ((_pos > 1)); then
        echo "[run.sh] ${_arg} must be the first argument (see --help)" >&2
        exit 2
      fi
      ;;
    -*)
      echo "[run.sh] Unknown option: ${_arg} (see --help)" >&2
      exit 2
      ;;
  esac
done

_cores="$(nproc 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")"
jobs="${CGW_TEST_JOBS:-$((_cores / 2))}"
((jobs < 1)) && jobs=1

# Core (tests/unit/) and fast (the other integration files) run on every push and PR. The slow
# files below run monthly (nightly.yml --slow) and, on a PR, only when the file or a script it
# covers changed (--slow-changed). These are the files with the most tests that each build their
# own git repos: 257 of the ~1500 tests. dogfood.bats also checks the whole tree on CI (no
# upstream there, ~170 s) and repeats the ShellCheck job. CI runs native `bats --jobs`, which
# parallelises inside a file; the xargs path (CGW_TEST_TIMINGS=1, Windows) does not, so its
# file-seconds do not predict a CI leg. Retune from the test count and a CI leg time.
CGW_SLOW_FILES=(
  "tests/integration/dogfood.bats"
  "tests/integration/merge_pr.bats"
  "tests/integration/configure.bats"
  "tests/integration/cc_guardrail.bats"
  "tests/integration/repo_state.bats"
)

# Does a change in CGW_CHANGED_FILES select the slow file $1? A trigger ending in / names a
# directory (prefix match); any other trigger must equal the changed path exactly, so
# scripts/git/configure.sh does not match configure.sh.bak. The file itself and the runner or
# helpers always select it. The per-file triggers are the scripts and hooks that the .bats file
# runs; re-check them with a grep of the file when it starts to use another script. Shared
# libraries (_common.sh, _config.sh, _lib_*.sh) are not triggers: core covers them on every push
# and the monthly run covers the rest.
_slow_file_changed() {
  local file="${1#./}" changed trigger
  local -a triggers=("${file}" "tests/run.sh" "tests/helpers/")
  case "${file}" in
    *dogfood.bats) triggers+=("scripts/test/run_tests.sh" "scripts/git/configure.sh" "hooks/") ;;
    *merge_pr.bats) triggers+=("scripts/git/merge_pr.sh" "scripts/git/rollback_merge.sh") ;;
    *configure.bats) triggers+=("scripts/git/configure.sh" "scripts/git/setup_attributes.sh" "hooks/") ;;
    *cc_guardrail.bats)
      triggers+=("hooks/cc-block-dangerous-git.sh" "hooks/_guardrail_core.sh" "hooks/agy-block-dangerous-git.sh"
        "scripts/git/commit_enhanced.sh" "scripts/git/configure.sh" "scripts/git/worktree_manage.sh"
        "scripts/git/push_validated.sh" "scripts/git/branch_cleanup.sh")
      ;;
    *repo_state.bats) triggers+=("scripts/git/repo_state.sh") ;;
  esac
  while IFS= read -r changed; do
    [[ -z "${changed}" ]] && continue
    for trigger in "${triggers[@]}"; do
      if [[ "${trigger}" == */ ]]; then
        [[ "${changed}" == "${trigger}"* ]] && return 0
      else
        [[ "${changed}" == "${trigger}" ]] && return 0
      fi
    done
  done <<<"${CGW_CHANGED_FILES}"
  return 1
}

# Batch selection: --fast = core + fast, --slow = only the slow files, --slow-changed = the
# slow files a change touches, --all = everything. A bare run is --fast; CGW_RUN_SLOW=1 makes a
# bare run --all. An explicit mode flag always wins, and CI is no longer a reason to widen it.
_mode=fast
_explicit_mode=0
case "${1:-}" in
  --slow | --slow-changed | --all | --fast)
    _mode="${1#--}"
    _explicit_mode=1
    shift
    ;;
esac
[[ "${CGW_RUN_SLOW:-0}" == "1" && "${_explicit_mode}" -eq 0 ]] && _mode=all
if [[ "${_mode}" == "slow-changed" && -z "${CGW_CHANGED_FILES+x}" ]]; then
  echo "[run.sh] --slow-changed needs CGW_CHANGED_FILES (newline-separated repo paths; empty = none)" >&2
  exit 2
fi

# Default target: core + fast. Callers can pass specific paths to narrow the run.
# Note: "${@:-fallback}" produces a single string when $@ is empty and fallback
# contains spaces — use an explicit branch so each path is a separate array element.
_default_run=0
if [[ $# -eq 0 ]]; then
  _default_run=1
  _targets=("tests/unit/" "tests/integration/")
else
  _targets=("$@")
fi

mapfile -t _files < <(find "${_targets[@]}" -name "*.bats" | sort)

# The slow-file gate applies to a bare run and to any run with an explicit mode flag. A named
# target without a mode flag (file or dir) always runs regardless. _filtered tracks whether
# anything was actually dropped: when nothing is filtered we hand bats its
# original directory targets unchanged (see native-jobs branch below) rather
# than an expanded flat file list, since bats schedules a flat list of files
# across --jobs workers differently than it does directory args, which was
# observed to change concurrent-file timing enough to trip an unrelated race
# in merge_docs.bats on CI.
_filtered=0
if [[ ("${_default_run}" -eq 1 || "${_explicit_mode}" -eq 1) && "${_mode}" != "all" ]]; then
  _kept=() _skipped_files=()
  for f in "${_files[@]}"; do
    _is_slow=0
    for slow in "${CGW_SLOW_FILES[@]}"; do
      [[ "${f}" == *"${slow}" ]] && {
        _is_slow=1
        break
      }
    done
    if [[ "${_mode}" == "slow" ]]; then
      ((_is_slow == 1)) && _kept+=("${f}") || _skipped_files+=("${f}")
    elif [[ "${_mode}" == "slow-changed" ]]; then
      if ((_is_slow == 1)) && _slow_file_changed "${f}"; then _kept+=("${f}"); else _skipped_files+=("${f}"); fi
    else
      ((_is_slow == 1)) && _skipped_files+=("${f}") || _kept+=("${f}")
    fi
  done
  _files=("${_kept[@]}")
  if [[ ${#_skipped_files[@]} -gt 0 ]]; then
    _filtered=1
    printf '[run.sh] %s batch: skipping %d file(s); use --all (or CGW_RUN_SLOW=1) for everything, --slow for the other batch.\n' "${_mode}" "${#_skipped_files[@]}" >&2
  fi
fi

if [[ "${_mode}" == "slow-changed" && ${#_files[@]} -eq 0 ]]; then
  echo "[run.sh] no changed slow files — nothing to run."
  exit 0
fi

if [[ ${#_files[@]} -eq 0 ]]; then
  echo "[run.sh] No test files matched — nothing to run." >&2
  exit 1
fi

if [[ "${CGW_TEST_LIST:-0}" == "1" ]]; then
  printf '%s\n' "${_files[@]}"
  exit 0
fi

# bats --jobs requires flock/shlock, which Git Bash on Windows does not provide.
# Fall back to per-file parallelism via xargs -P when flock is unavailable.
# CGW_TEST_TIMINGS=1 also takes the xargs path: it times each file, which native --jobs can't report.
if [[ "${CGW_TEST_TIMINGS:-0}" != "1" ]] && { command -v flock >/dev/null 2>&1 || command -v shlock >/dev/null 2>&1; }; then
  if [[ "${_filtered}" -eq 1 ]]; then
    exec bats --jobs "${jobs}" "${_files[@]}"
  fi
  exec bats --jobs "${jobs}" "${_targets[@]}"
fi

# ── xargs -P fallback (Windows Git Bash) ──────────────────────────────────────
_tmpdir="$(mktemp -d)"
trap 'rm -rf "${_tmpdir}"' EXIT

_run_bats_file() {
  local f="$1" out="$2"
  local slug
  slug="$(basename "${f}" .bats)"
  local t0="${SECONDS}" rc
  bats --tap "${f}" >"${out}/${slug}.tap" 2>&1
  rc="$?"
  printf '%s' "${rc}" >"${out}/${slug}.exit"
  printf '%s' "$((SECONDS - t0))" >"${out}/${slug}.secs"
  # One line per finished file so a background run shows progress (stderr, to keep stdout summary clean).
  local done_n status=ok
  done_n="$(find "${out}" -name '*.exit' | wc -l)"
  ((rc == 0)) || status=FAIL
  printf '[run.sh] [%d/%d] %s %s (%ss)\n' "${done_n}" "${_total_files}" "${f}" "${status}" "$((SECONDS - t0))" >&2
}
_total_files=${#_files[@]}
export _total_files
export -f _run_bats_file

printf '%s\n' "${_files[@]}" |
  xargs -P "${jobs}" -I{} bash -c '_run_bats_file "$@"' _ {} "${_tmpdir}"

# ── Aggregate TAP results ──────────────────────────────────────────────────────
_passed=0 _failed=0 _skipped=0 _overall=0
declare -a _fail_slugs=()

for f in "${_files[@]}"; do
  slug="$(basename "${f}" .bats)"
  tap="${_tmpdir}/${slug}.tap"
  exit_code="$(cat "${_tmpdir}/${slug}.exit" 2>/dev/null || echo 1)"
  [[ "${exit_code}" != "0" ]] && {
    _overall=1
    _fail_slugs+=("${slug}")
  }

  while IFS= read -r line; do
    if [[ "${line}" =~ ^ok\ [0-9]+ ]]; then
      [[ "${line}" == *"# skip"* ]] && ((_skipped++)) || ((_passed++)) || true
    elif [[ "${line}" =~ ^not\ ok\ [0-9]+ ]]; then
      [[ "${line}" == *"# skip"* ]] && ((_skipped++)) || ((_failed++)) || true
    fi
  done <"${tap}"
done

# Per failed file: the full TAP with CGW_TEST_VERBOSE=1, otherwise a digest that drops the
# `ok N` and plan lines so the `not ok` line and its `#` diagnostics survive the output cap.
for slug in "${_fail_slugs[@]}"; do
  printf '\n=== FAILURES: %s ===\n' "${slug}"
  if [[ "${CGW_TEST_VERBOSE:-0}" == "1" ]]; then
    cat "${_tmpdir}/${slug}.tap"
  else
    # bats can fail without running a test (a file with no @test, a killed process);
    # then there is no `not ok` line to show and the digest would look empty.
    if ! grep -qE '^not ok [0-9]+' "${_tmpdir}/${slug}.tap"; then
      echo "(no 'not ok' line: bats failed before running this file's tests; re-run with CGW_TEST_VERBOSE=1 for its full output)"
    fi
    grep -vE '^(ok [0-9]+|[0-9]+\.\.[0-9]+)' "${_tmpdir}/${slug}.tap"
  fi
done

# One line per failing test (or per failed file without one), so the summary reads
# even when the digest above is truncated
for slug in "${_fail_slugs[@]}"; do
  if grep -qE '^not ok [0-9]+' "${_tmpdir}/${slug}.tap"; then
    grep -E '^not ok [0-9]+' "${_tmpdir}/${slug}.tap" | grep -v '# skip' |
      sed -E "s/^not ok ([0-9]+) (.*)$/failed: ${slug}:\1 \2/"
  else
    echo "failed: ${slug} (bats exit $(cat "${_tmpdir}/${slug}.exit" 2>/dev/null || echo '?'), no not-ok line)"
  fi
done

# Slowest files, so CGW_SLOW_FILES can be tuned from data (wall time under parallel load)
if [[ "${CGW_TEST_TIMINGS:-0}" == "1" ]]; then
  printf '
[run.sh] slowest files (seconds):
' >&2
  for f in "${_files[@]}"; do
    slug="$(basename "${f}" .bats)"
    printf '%5s  %s
' "$(cat "${_tmpdir}/${slug}.secs" 2>/dev/null || echo 0)" "${f}"
  done | sort -rn | head -12 >&2
fi

# Final summary line (mirrors bats native format)
_total=$((_passed + _failed + _skipped))
if [[ "${_overall}" -eq 0 ]]; then
  printf '\n%d tests, %d skipped\n' "${_total}" "${_skipped}"
else
  printf '\n%d tests, %d failures, %d skipped\n' "${_total}" "${_failed}" "${_skipped}"
fi
exit "${_overall}"
