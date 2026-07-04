#!/usr/bin/env bash
# tests/run.sh — run the CGW bats suite in parallel
# Usage:
#   tests/run.sh                          # full suite; skips slow files locally (common.bats)
#   tests/run.sh tests/unit/              # unit tests only  (~25s)
#   tests/run.sh tests/unit/config.bats   # single file
#   CGW_TEST_JOBS=N tests/run.sh          # override parallelism (default: half logical cores)
#   CGW_RUN_SLOW=1 tests/run.sh           # include slow files locally (always run on CI)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

_cores="$(nproc 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")"
jobs="${CGW_TEST_JOBS:-$(( _cores / 2 ))}"
(( jobs < 1 )) && jobs=1

# Files that dominate local wall-clock (e.g. common.bats disables within-file
# parallelization to avoid a bats --jobs index.lock race, so its ~126 tests
# run serially and become the parallel wall-clock floor). Skipped on a default
# full-suite run unless CI is set or CGW_RUN_SLOW=1; always run on CI.
CGW_SLOW_FILES=("tests/unit/common.bats")

# Default target: full suite. Callers can pass specific paths to narrow the run.
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

# Slow-file gate only applies to the default full-suite run — an explicitly
# named target (file or dir) always runs regardless.
if [[ "${_default_run}" -eq 1 ]]; then
  _run_slow="${CGW_RUN_SLOW:-0}"
  [[ -n "${CI:-}" ]] && _run_slow=1
  if [[ "${_run_slow}" != "1" ]]; then
    _kept=() _skipped_files=()
    for f in "${_files[@]}"; do
      _is_slow=0
      for slow in "${CGW_SLOW_FILES[@]}"; do
        [[ "${f}" == *"${slow}" ]] && { _is_slow=1; break; }
      done
      if [[ "${_is_slow}" -eq 1 ]]; then
        _skipped_files+=("${f}")
      else
        _kept+=("${f}")
      fi
    done
    _files=("${_kept[@]}")
    if [[ ${#_skipped_files[@]} -gt 0 ]]; then
      printf '[run.sh] Skipping %d slow file(s) locally: %s\n' \
        "${#_skipped_files[@]}" "${_skipped_files[*]}" >&2
      printf '[run.sh]   Run with CGW_RUN_SLOW=1 to include them (always run on CI).\n' >&2
    fi
  fi
fi

if [[ ${#_files[@]} -eq 0 ]]; then
  echo "[run.sh] No test files matched — nothing to run." >&2
  exit 1
fi

# bats --jobs requires flock/shlock, which Git Bash on Windows does not provide.
# Fall back to per-file parallelism via xargs -P when flock is unavailable.
if command -v flock >/dev/null 2>&1 || command -v shlock >/dev/null 2>&1; then
  exec bats --jobs "${jobs}" "${_files[@]}"
fi

# ── xargs -P fallback (Windows Git Bash) ──────────────────────────────────────
_tmpdir="$(mktemp -d)"
trap 'rm -rf "${_tmpdir}"' EXIT

_run_bats_file() {
  local f="$1" out="$2"
  local slug; slug="$(basename "${f}" .bats)"
  bats --tap "${f}" > "${out}/${slug}.tap" 2>&1
  printf '%s' "$?" > "${out}/${slug}.exit"
}
export -f _run_bats_file

printf '%s\n' "${_files[@]}" \
  | xargs -P "${jobs}" -I{} bash -c '_run_bats_file "$@"' _ {} "${_tmpdir}"

# ── Aggregate TAP results ──────────────────────────────────────────────────────
_passed=0 _failed=0 _skipped=0 _overall=0
declare -a _fail_slugs=()

for f in "${_files[@]}"; do
  slug="$(basename "${f}" .bats)"
  tap="${_tmpdir}/${slug}.tap"
  exit_code="$(cat "${_tmpdir}/${slug}.exit" 2>/dev/null || echo 1)"
  [[ "${exit_code}" != "0" ]] && { _overall=1; _fail_slugs+=("${slug}"); }

  while IFS= read -r line; do
    if [[ "${line}" =~ ^ok\ [0-9]+ ]]; then
      [[ "${line}" == *"# skip"* ]] && (( _skipped++ )) || (( _passed++ )) || true
    elif [[ "${line}" =~ ^not\ ok\ [0-9]+ ]]; then
      [[ "${line}" == *"# skip"* ]] && (( _skipped++ )) || (( _failed++ )) || true
    fi
  done < "${tap}"
done

# Print full output for each failed file
for slug in "${_fail_slugs[@]}"; do
  printf '\n=== FAILURES: %s ===\n' "${slug}"
  cat "${_tmpdir}/${slug}.tap"
done

# Final summary line (mirrors bats native format)
_total=$(( _passed + _failed + _skipped ))
if [[ "${_overall}" -eq 0 ]]; then
  printf '\n%d tests, %d skipped\n' "${_total}" "${_skipped}"
else
  printf '\n%d tests, %d failures, %d skipped\n' "${_total}" "${_failed}" "${_skipped}"
fi
exit "${_overall}"
