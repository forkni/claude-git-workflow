#!/usr/bin/env bash
# tests/check_skipped_bats.sh
# Ratchet check for Bats tests: ensures no new unconditional `skip` statements
# are added to test files. Unconditional skips indicate disabled tests (suite rot)
# rather than legitimate platform/tool guards.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Baseline allowed unconditional skips (documented bugs awaiting refactor)
ALLOWED_SKIPS=(
  "tests/integration/create_release.bats:bug #C2"
  "tests/integration/push_validated.bats:bug #C3"
)

fail=0
checked=0
found_skips=0

mapfile -t files < <(find "${REPO_ROOT}/tests" -name "*.bats" | sort)

for f in "${files[@]}"; do
  rel="${f#"${REPO_ROOT}/"}"
  ((checked++)) || true

  while IFS=: read -r lnum content; do
    [[ -n "${lnum}" ]] || continue
    ((found_skips++)) || true

    # Check if this skip is in the allowlist
    allowed=0
    for entry in "${ALLOWED_SKIPS[@]}"; do
      allowed_file="${entry%%:*}"
      allowed_token="${entry##*:}"
      if [[ "${rel}" == "${allowed_file}" && "${content}" == *"${allowed_token}"* ]]; then
        allowed=1
        break
      fi
    done

    if ((allowed == 0)); then
      echo "::error file=${rel},line=${lnum}::Unratcheted unconditional skip in ${rel}:${lnum}: ${content}" >&2
      ((fail++)) || true
    fi
  done < <(grep -nE '^[[:space:]]*skip[[:space:]]' "${f}" 2>/dev/null || true)
done

echo "[check_skipped_bats] Checked ${checked} test files, found ${found_skips} unconditional skip(s) (${#ALLOWED_SKIPS[@]} allowed baseline)."

if ((fail > 0)); then
  echo "[check_skipped_bats] ERROR: ${fail} unrecorded unconditional skip(s) detected. Fix the test or update the ratchet with an owner and expiration issue." >&2
  exit 1
fi

echo "[check_skipped_bats] PASS: All skips match baseline ratchet."
exit 0
