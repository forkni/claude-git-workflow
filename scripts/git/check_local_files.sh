#!/usr/bin/env bash
# check_local_files.sh — verify no local-only files are tracked in git.
# Used by CI (branch-protection.yml) and can be run locally.
# Reads CGW_LOCAL_FILES from .cgw.conf (if present) or built-in defaults.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"

mapfile -t hits < <(git ls-files | cgw_filter_local_files || true)
if (( ${#hits[@]} > 0 )); then
  err "Local-only files are tracked in git:"
  printf '  - %s\n' "${hits[@]}" >&2
  echo "" >&2
  echo "Fix: git rm --cached <file>" >&2
  exit 1
fi
echo "[OK] No local-only files tracked"
