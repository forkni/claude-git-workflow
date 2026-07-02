#!/usr/bin/env bash
# pr_checkout.sh - Check out a GitHub PR locally for review
# Purpose: Wraps `gh pr checkout` so reviewing a PR follows the same guarded,
#          logged pattern as other CGW scripts -- the modern replacement for
#          the refs/pull/*/head refspec recipe documented in stas00/git-tools.
# Usage: ./scripts/git/pr_checkout.sh <PR-number> [OPTIONS]
#
# Globals:
#   SCRIPT_DIR   - Directory containing this script
#   PROJECT_ROOT - Auto-detected git repo root (set by _config.sh)
#   logfile      - Set by init_logging
# Arguments:
#   <PR-number>        PR number to check out (or use --pr <N>)
#   --pr <N>           Same as positional PR number
#   --branch <name>    Local branch name to check out into (gh pr checkout -b)
#   --force            Allow checkout even with a dirty working tree
#   --detach           Check out in detached-HEAD state (gh pr checkout --detach)
#   --dry-run          Print the resolved `gh pr checkout` command without running it
#   --non-interactive  Accept all defaults, no prompts
#   -h, --help         Show help
# Returns:
#   0 on successful checkout (or dry-run preview), 1 on failure
#
# Prerequisites:
#   gh CLI installed and authenticated (gh auth login)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"
ensure_no_stale_index_lock || exit 1

main() {
  local pr_number=""
  local branch_name=""
  local force=0
  local detach=0
  local dry_run=0
  local non_interactive=0

  # Auto-detect non-interactive mode when no TTY (matches create_pr.sh)
  [[ ! -t 0 ]] && CGW_NON_INTERACTIVE=1
  [[ "${CGW_NON_INTERACTIVE:-0}" == "1" ]] && non_interactive=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help | -h)
        echo "Usage: ./scripts/git/pr_checkout.sh <PR-number> [OPTIONS]"
        echo ""
        echo "Check out a GitHub PR locally for review (wraps 'gh pr checkout')."
        echo ""
        echo "Options:"
        echo "  --pr <N>           PR number to check out (or pass it positionally)"
        echo "  --branch <name>    Local branch name to check out into"
        echo "  --force            Allow checkout even with a dirty working tree"
        echo "  --detach           Check out in detached-HEAD state"
        echo "  --dry-run          Print the resolved command without running it"
        echo "  --non-interactive  Accept all defaults, no prompts"
        echo "  -h, --help         Show this help"
        echo ""
        echo "Examples:"
        echo "  ./scripts/git/pr_checkout.sh 42"
        echo "  ./scripts/git/pr_checkout.sh --pr 42 --branch review/pr-42"
        echo "  ./scripts/git/pr_checkout.sh 42 --dry-run"
        echo ""
        echo "Prerequisites:"
        echo "  gh CLI installed and authenticated (gh auth login)"
        exit 0
        ;;
      --pr)
        pr_number="${2:-}"
        if [[ -z "${pr_number}" ]]; then
          err "--pr requires a PR number"
          exit 1
        fi
        shift
        ;;
      --branch)
        branch_name="${2:-}"
        if [[ -z "${branch_name}" ]]; then
          err "--branch requires a name"
          exit 1
        fi
        shift
        ;;
      --force) force=1 ;;
      --detach) detach=1 ;;
      --dry-run) dry_run=1 ;;
      --non-interactive)
        non_interactive=1
        CGW_NON_INTERACTIVE=1
        ;;
      -*)
        err "Unknown flag: $1"
        exit 1
        ;;
      *)
        if [[ -z "${pr_number}" ]]; then
          pr_number="$1"
        else
          err "Unexpected argument: $1"
          exit 1
        fi
        ;;
    esac
    shift
  done

  if [[ -z "${pr_number}" ]]; then
    err "PR number required (positional or --pr <N>)"
    exit 1
  fi

  if ! [[ "${pr_number}" =~ ^[0-9]+$ ]]; then
    err "Invalid PR number: ${pr_number}"
    exit 1
  fi

  init_logging "pr_checkout"

  {
    echo "========================================="
    echo "PR Checkout Log"
    echo "========================================="
    echo "Start Time: $(date)"
    echo "PR: #${pr_number}"
  } >"$logfile"

  cd "${PROJECT_ROOT}" || {
    err "Cannot find project root"
    exit 1
  }

  echo "=== PR Checkout ===" | tee -a "$logfile"
  echo "" | tee -a "$logfile"

  # [1/2] Prerequisites
  log_section_start "PREREQUISITES" "$logfile"
  if ! cgw_require_gh; then
    log_section_end "PREREQUISITES" "$logfile" "1"
    exit 1
  fi
  echo "[OK] gh CLI installed and authenticated" | tee -a "$logfile"
  log_section_end "PREREQUISITES" "$logfile" "0"
  echo "" | tee -a "$logfile"

  local gh_args=("${pr_number}")
  [[ -n "${branch_name}" ]] && gh_args+=(--branch "${branch_name}")
  [[ ${force} -eq 1 ]] && gh_args+=(--force)
  [[ ${detach} -eq 1 ]] && gh_args+=(--detach)

  if [[ ${dry_run} -eq 1 ]]; then
    echo "=== DRY RUN -- checkout not performed ===" | tee -a "$logfile"
    echo "" | tee -a "$logfile"
    echo "Would run: gh pr checkout ${gh_args[*]}" | tee -a "$logfile"
    exit 0
  fi

  # Dirty-tree guard: gh pr checkout switches branches; refuse unless --force.
  # Mirrors the dirty-tree check used in sync_branches.sh.
  if [[ ${force} -eq 0 ]] && ! git diff-index --quiet HEAD -- 2>/dev/null; then
    err "Working tree has uncommitted changes -- commit, stash, or pass --force"
    echo "  Stash first: ./scripts/git/stash_work.sh push" | tee -a "$logfile"
    exit 1
  fi

  # Interactive confirmation before switching branches (skipped in non-interactive/CI mode).
  if [[ ${non_interactive} -eq 0 ]]; then
    echo "About to check out PR #${pr_number} (gh pr checkout ${gh_args[*]})."
    if ! cgw_confirm "Continue?" --default yes; then
      echo "Cancelled"
      exit 0
    fi
  fi

  # [2/2] Checkout
  log_section_start "GH PR CHECKOUT" "$logfile"
  if gh pr checkout "${gh_args[@]}" 2>&1 | tee -a "$logfile"; then
    log_section_end "GH PR CHECKOUT" "$logfile" "0"
    echo "" | tee -a "$logfile"
    echo "[OK] Checked out PR #${pr_number}" | tee -a "$logfile"
    echo "Full log: $logfile"
  else
    log_section_end "GH PR CHECKOUT" "$logfile" "1"
    err "PR checkout failed -- check log: ${logfile}"
    exit 1
  fi
}

main "$@"
