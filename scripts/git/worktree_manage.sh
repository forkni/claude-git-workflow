#!/usr/bin/env bash
# worktree_manage.sh - Git worktree management wrapper
# Purpose: Add, list, remove, and prune git linked worktrees in a safe, consistent
#          way that matches the CGW toolkit conventions (dry-run default for
#          destructive ops, --non-interactive for CI, confirmation gate).
#          Linked worktrees let you check out multiple branches simultaneously
#          without stashing — useful for parallel feature work or hot-fixes.
# Usage: ./scripts/git/worktree_manage.sh <subcommand> [OPTIONS]
#
# Subcommands:
#   list              List all worktrees (main + linked)
#   add  <path> [<branch>]   Add a linked worktree (creates branch if needed)
#   remove <path>            Remove a linked worktree (dry-run default)
#   prune                    Remove stale administrative files (dry-run default)
#
# Globals:
#   SCRIPT_DIR     - Directory containing this script
#   PROJECT_ROOT   - Auto-detected git repo root (set by _config.sh)
#   logfile        - Set by init_logging
# Returns:
#   0 on success, 1 on failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"

init_logging "worktree_manage"

# ---------------------------------------------------------------------------
# Subcommand: list
# ---------------------------------------------------------------------------
_cmd_list() {
  echo "=== Git Worktrees ==="
  echo ""

  local raw
  raw="$(git worktree list --porcelain 2>/dev/null)"

  if [[ -z "${raw}" ]]; then
    echo "  (no worktrees found)"
    return 0
  fi

  local path="" head="" branch="" bare=0
  while IFS= read -r line; do
    if [[ "${line}" == worktree* ]]; then
      # Print previous entry if any
      if [[ -n "${path}" ]]; then
        local _br_label="${branch:-<detached>}"
        [[ "${bare}" -eq 1 ]] && _br_label="<bare>"
        printf "  %-40s  %-24s  %s\n" "${path}" "${_br_label}" "${head:0:12}"
        path="" head="" branch="" bare=0
      fi
      path="${line#worktree }"
    elif [[ "${line}" == HEAD\ * ]]; then
      head="${line#HEAD }"
    elif [[ "${line}" == branch\ * ]]; then
      branch="${line#branch refs/heads/}"
    elif [[ "${line}" == "bare" ]]; then
      bare=1
    fi
  done <<<"${raw}"
  # Print last entry
  if [[ -n "${path}" ]]; then
    local _br_label="${branch:-<detached>}"
    [[ "${bare}" -eq 1 ]] && _br_label="<bare>"
    printf "  %-40s  %-24s  %s\n" "${path}" "${_br_label}" "${head:0:12}"
  fi
  echo ""

  # Prune hint if any worktrees have missing paths
  local stale
  stale="$(git worktree prune --dry-run 2>&1 | grep -c "Removing" || true)"
  if [[ "${stale}" -gt 0 ]]; then
    echo "  [!] ${stale} stale administrative file(s) detected."
    echo "      Run: ./scripts/git/worktree_manage.sh prune"
  fi
}

# ---------------------------------------------------------------------------
# Subcommand: add
# ---------------------------------------------------------------------------
_cmd_add() {
  local path="" branch="" dry_run=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --non-interactive)
        CGW_NON_INTERACTIVE=1
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -*)
        echo "[ERROR] Unknown option: $1" >&2
        exit 1
        ;;
      *)
        if [[ -z "${path}" ]]; then
          path="$1"
        elif [[ -z "${branch}" ]]; then
          branch="$1"
        else
          echo "[ERROR] Unexpected argument: $1" >&2
          exit 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "${path}" ]]; then
    echo "[ERROR] Usage: worktree_manage.sh add <path> [<branch>]" >&2
    exit 1
  fi

  echo "=== Add Worktree ==="
  echo ""
  echo "  Path:   ${path}"

  local -a git_args=()
  if [[ -z "${branch}" ]]; then
    # No branch given: git worktree add will create a detached worktree at HEAD.
    # Suggest the user specify one.
    echo "  Branch: (none — detached HEAD)"
    echo "  Tip: provide a branch name to check it out: worktree_manage.sh add ${path} <branch>"
    git_args=("${path}")
  else
    # If the branch doesn't exist, pass -b to create it.
    if ! git rev-parse --verify --quiet "refs/heads/${branch}" >/dev/null 2>&1; then
      echo "  Branch: ${branch} (new — will be created from HEAD)"
      git_args=(-b "${branch}" "${path}")
    else
      echo "  Branch: ${branch}"
      git_args=("${path}" "${branch}")
    fi
  fi
  echo ""

  if [[ "${dry_run}" -eq 1 ]]; then
    echo "--- Dry run: no changes made ---"
    echo "Would run: git worktree add ${git_args[*]}"
    exit 0
  fi

  if ! cgw_confirm "Add worktree at '${path}'?" --non-interactive accept; then
    echo "Cancelled"
    exit 0
  fi

  if git worktree add "${git_args[@]}" 2>&1 | tee -a "${logfile}"; then
    echo ""
    echo "[OK] Worktree added: ${path}"
    echo "  cd ${path} to work in this worktree"
  else
    echo "[ERROR] Failed to add worktree" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Subcommand: remove
# ---------------------------------------------------------------------------
_cmd_remove() {
  local path="" dry_run=1 # default dry-run like branch_cleanup.sh

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --execute)
        dry_run=0
        shift
        ;;
      --non-interactive)
        CGW_NON_INTERACTIVE=1
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -*)
        echo "[ERROR] Unknown option: $1" >&2
        exit 1
        ;;
      *)
        path="$1"
        shift
        ;;
    esac
  done

  if [[ -z "${path}" ]]; then
    echo "[ERROR] Usage: worktree_manage.sh remove [--execute] <path>" >&2
    exit 1
  fi

  echo "=== Remove Worktree ==="
  echo ""
  echo "  Path: ${path}"
  echo ""

  if [[ "${dry_run}" -eq 1 ]]; then
    echo "--- Dry run: no changes made (use --execute to proceed) ---"
    echo "Would run: git worktree remove '${path}'"
    echo ""
    echo "Note: the working directory at '${path}' and its branch will be preserved."
    echo "      Only the worktree administrative link is removed."
    exit 0
  fi

  if ! cgw_confirm "Remove worktree '${path}'?" --non-interactive accept; then
    echo "Cancelled"
    exit 0
  fi

  if git worktree remove "${path}" 2>&1 | tee -a "${logfile}"; then
    echo ""
    echo "[OK] Worktree removed: ${path}"
  else
    echo "[ERROR] Failed to remove worktree." >&2
    echo "  If the worktree has uncommitted changes, use: git worktree remove --force '${path}'" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Subcommand: prune
# ---------------------------------------------------------------------------
_cmd_prune() {
  local dry_run=1 # default dry-run

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --execute)
        dry_run=0
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      *)
        echo "[ERROR] Unknown option: $1" >&2
        exit 1
        ;;
    esac
  done

  echo "=== Prune Stale Worktree Admin Files ==="
  echo ""
  echo "  This removes stale worktree administrative files for worktrees whose"
  echo "  working-directory paths no longer exist (e.g., manually deleted)."
  echo ""

  local prune_dry
  prune_dry="$(git worktree prune --dry-run 2>&1 || true)"

  if [[ -z "${prune_dry}" ]] || ! echo "${prune_dry}" | grep -q "Removing"; then
    echo "  Nothing to prune."
    exit 0
  fi

  echo "  Would prune:"
  while IFS= read -r _prune_line; do
    printf '    %s\n' "${_prune_line}"
  done <<<"${prune_dry}"
  echo ""

  if [[ "${dry_run}" -eq 1 ]]; then
    echo "--- Dry run: no changes made (use --execute to proceed) ---"
    exit 0
  fi

  if git worktree prune --verbose 2>&1 | tee -a "${logfile}"; then
    echo ""
    echo "[OK] Pruned stale worktree administrative files."
  else
    echo "[ERROR] Prune failed" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
_show_help() {
  echo "Usage: ./scripts/git/worktree_manage.sh <subcommand> [OPTIONS]"
  echo ""
  echo "Git linked-worktree management."
  echo "Allows multiple branches to be checked out simultaneously in separate directories."
  echo ""
  echo "Subcommands:"
  echo "  list                      List all worktrees (main + linked)"
  echo "  add  <path> [<branch>]    Add a linked worktree; creates branch if needed"
  echo "  remove [--execute] <path> Remove a linked worktree (dry-run by default)"
  echo "  prune  [--execute]        Remove stale admin files (dry-run by default)"
  echo ""
  echo "Options (add):"
  echo "  --dry-run           Preview without adding"
  echo "  --non-interactive   Skip confirmation prompt"
  echo ""
  echo "Options (remove / prune):"
  echo "  --execute           Actually remove (default is dry-run preview)"
  echo "  --dry-run           Explicit dry-run (the default)"
  echo "  --non-interactive   Skip confirmation (remove only)"
  echo ""
  echo "Examples:"
  echo "  ./scripts/git/worktree_manage.sh list"
  echo "  ./scripts/git/worktree_manage.sh add ../hotfix hotfix/urgent-fix"
  echo "  ./scripts/git/worktree_manage.sh remove --execute ../hotfix"
  echo "  ./scripts/git/worktree_manage.sh prune --execute"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  local subcmd="${1:-}"
  shift || true

  case "${subcmd}" in
    list) _cmd_list "$@" ;;
    add) _cmd_add "$@" ;;
    remove) _cmd_remove "$@" ;;
    prune) _cmd_prune "$@" ;;
    --help | -h | help | "") _show_help ;;
    *)
      echo "[ERROR] Unknown subcommand: ${subcmd}" >&2
      echo ""
      _show_help
      exit 1
      ;;
  esac
}

main "$@"
