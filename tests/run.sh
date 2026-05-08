#!/usr/bin/env bash
# tests/run.sh — run the CGW bats suite in parallel
# Usage: tests/run.sh [extra bats args...]
#   CGW_TEST_JOBS=N tests/run.sh   # override parallelism (default: half logical cores)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

_cores="$(nproc 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")"
jobs="${CGW_TEST_JOBS:-$(( _cores / 2 ))}"
(( jobs < 1 )) && jobs=1

# bats --jobs requires flock/shlock, which Git Bash on Windows does not provide.
# Fall back to per-file parallelism via xargs -P when flock is unavailable.
if command -v flock >/dev/null 2>&1 || command -v shlock >/dev/null 2>&1; then
  exec bats --jobs "${jobs}" "$@" tests/unit/ tests/integration/
fi

# ── xargs -P fallback (Windows Git Bash) ──────────────────────────────────────
_tmpdir="$(mktemp -d)"
trap 'rm -rf "${_tmpdir}"' EXIT

mapfile -t _files < <(find tests/unit/ tests/integration/ -name "*.bats" | sort)

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
