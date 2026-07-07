#!/usr/bin/env bash
# branch_diff.sh - Diff the current branch against the repository's default branch
# Purpose: Answer "what did I change on this branch?" without hardcoding main/master.
#          Inspired by the brdiff/brfiles aliases in stas00/git-tools, but uses
#          cgw_default_branch() so it works with any default-branch name.
# Usage: ./scripts/git/branch_diff.sh [OPTIONS]
#
# Globals:
#   SCRIPT_DIR         - Directory containing this script
#   PROJECT_ROOT       - Auto-detected git repo root (set by _config.sh)
#   CGW_REMOTE         - Remote name (default: origin)
#   CGW_TARGET_BRANCH  - Fallback default branch when origin/HEAD is unset (default: main)
# Arguments:
#   --files            List changed file names only (git diff --name-only)
#   --stat             Show a diffstat summary (git diff --stat)
#   --no-ws, -w        Ignore whitespace-only differences
#   --base <ref>       Compare against an explicit ref instead of the auto-detected default branch
#   --refresh          Run `git remote set-head <remote> --auto` first (needs network access)
#   -h, --help         Show help
# Returns:
#   0 on success, 1 if the base ref cannot be resolved or an unknown flag is passed
#
# Notes:
#   Read-only -- does not require a clean working tree. Uses triple-dot diff
#   (<base>...HEAD), i.e. merge-base-relative: only changes made on the current
#   branch are shown, excluding changes already present on the default branch.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"

main() {
  local mode="patch"
  local ignore_ws=0
  local base_override=""
  local refresh=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help | -h)
        echo "Usage: ./scripts/git/branch_diff.sh [OPTIONS]"
        echo ""
        echo "Diff the current branch against the repository's default branch"
        echo "(auto-detected via \${CGW_REMOTE}/HEAD, falling back to CGW_TARGET_BRANCH)."
        echo ""
        echo "Options:"
        echo "  --files          List changed file names only (like 'brfiles')"
        echo "  --stat           Show a diffstat summary"
        echo "  --no-ws, -w      Ignore whitespace-only differences"
        echo "  --base <ref>     Compare against an explicit ref instead of auto-detecting"
        echo "  --refresh        Refresh \${CGW_REMOTE}/HEAD first (needs network access)"
        echo "  -h, --help       Show this help"
        echo ""
        echo "Behavior:"
        echo "  Uses triple-dot diff (<base>...HEAD) -- merge-base relative, so only"
        echo "  changes made on this branch are shown (matches 'brdiff' from git-tools)."
        echo "  Read-only: safe to run with a dirty working tree."
        echo ""
        echo "Examples:"
        echo "  ./scripts/git/branch_diff.sh                 # full patch vs default branch"
        echo "  ./scripts/git/branch_diff.sh --files         # changed file names only"
        echo "  ./scripts/git/branch_diff.sh --stat --no-ws  # diffstat, ignoring whitespace"
        echo "  ./scripts/git/branch_diff.sh --base release/1.2"
        exit 0
        ;;
      --files) mode="files" ;;
      --stat) mode="stat" ;;
      --no-ws | -w) ignore_ws=1 ;;
      --base)
        base_override="${2:-}"
        if [[ -z "${base_override}" ]]; then
          err "--base requires a ref"
          exit 1
        fi
        shift
        ;;
      --refresh) refresh=1 ;;
      *)
        err "Unknown flag: $1"
        exit 1
        ;;
    esac
    shift
  done

  cd "${PROJECT_ROOT}" || {
    err "Cannot find project root"
    exit 1
  }

  local base
  if [[ -n "${base_override}" ]]; then
    base="${base_override}"
  else
    local default_branch
    if [[ ${refresh} -eq 1 ]]; then
      default_branch=$(cgw_default_branch --refresh)
    else
      default_branch=$(cgw_default_branch)
    fi
    if git show-ref --verify --quiet "refs/remotes/${CGW_REMOTE}/${default_branch}"; then
      base="${CGW_REMOTE}/${default_branch}"
    else
      base="${default_branch}"
    fi
  fi

  if ! git rev-parse --verify --quiet "${base}" >/dev/null 2>&1; then
    err "Cannot resolve base ref: ${base}"
    exit 1
  fi

  local diff_args=()
  [[ ${ignore_ws} -eq 1 ]] && diff_args+=("-w")

  case "${mode}" in
    files) diff_args+=("--name-only") ;;
    stat) diff_args+=("--stat") ;;
  esac

  git diff "${diff_args[@]}" "${base}...HEAD"
}

main "$@"
