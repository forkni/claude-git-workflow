#!/usr/bin/env bash
# undo_last.sh - Safe undo wrapper for common git operations
# Purpose: Provide safe, guided undo operations: undo last commit (keep changes
#          staged), unstage specific files, discard file changes. Creates backup
#          tags before any destructive operation. See Pro Git Ch2 p.52-55 and
#          Ch7 Reset Demystified p.257-276.
# Usage: ./scripts/git/undo_last.sh [SUBCOMMAND] [OPTIONS]
#
# Globals:
#   SCRIPT_DIR   - Directory containing this script
#   PROJECT_ROOT - Auto-detected git repo root (set by _config.sh)
#   logfile      - Set by init_logging
# Subcommands:
#   commit               Undo last commit -- keeps all changes staged (git reset --soft HEAD~1)
#   unstage <file>...    Remove file(s) from staging area (git reset HEAD <file>)
#   discard <file>...    Discard working-tree changes to file(s) (git checkout -- <file>)
#   amend-message <msg>  Change the message of the last commit (git commit --amend -m)
# Options (all subcommands):
#   --non-interactive    Skip confirmation prompts
#   --dry-run            Show what would happen without changing anything
#   -h, --help           Show help
# Returns:
#   0 on success, 1 on failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"

_show_help() {
  echo "Usage: ./scripts/git/undo_last.sh <subcommand> [OPTIONS]"
  echo ""
  echo "Safe undo operations with backup tags."
  echo ""
  echo "Subcommands:"
  echo "  commit               Undo the last commit, keeping all changes staged"
  echo "                       (git reset --soft HEAD~1 -- history-rewriting, local only)"
  echo "  unstage <file>...    Remove file(s) from staging area"
  echo "  discard <file>...    Discard working-tree changes to file(s)"
  echo "                       WARNING: This cannot be undone!"
  echo "  amend-message <msg>  Replace the last commit message"
  echo "                       (local only -- do not use after pushing)"
  echo ""
  echo "Options:"
  echo "  --non-interactive    Skip confirmation prompts"
  echo "  --dry-run            Preview without making changes"
  echo "  -h, --help           Show this help"
  echo ""
  echo "Examples:"
  echo "  ./scripts/git/undo_last.sh commit"
  echo "  ./scripts/git/undo_last.sh unstage src/file.py"
  echo "  ./scripts/git/undo_last.sh discard src/file.py"
  echo "  ./scripts/git/undo_last.sh amend-message 'fix: correct typo in header'"
  echo ""
  echo "Environment:"
  echo "  CGW_REMOTE   Remote name (default: origin)"
}

main() {
  if [[ $# -eq 0 ]] || [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    _show_help
    exit 0
  fi

  local subcommand="$1"
  shift

  local non_interactive=0
  local dry_run=0

  [[ "${CGW_NON_INTERACTIVE:-0}" == "1" ]] && non_interactive=1

  # Pre-scan remaining args for global flags
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --non-interactive)
        non_interactive=1
        CGW_NON_INTERACTIVE=1
        ;;
      --dry-run) dry_run=1 ;;
      --help | -h)
        _show_help
        exit 0
        ;;
      --*)
        echo "[ERROR] Unknown flag: $1" >&2
        exit 1
        ;;
      *) positional+=("$1") ;;
    esac
    shift
  done

  cd "${PROJECT_ROOT}" || {
    err "Cannot find project root"
    exit 1
  }

  init_logging "undo_last"
  ensure_no_stale_index_lock || exit 1

  {
    echo "========================================="
    echo "Undo Last Log"
    echo "========================================="
    echo "Start Time: $(date)"
    echo "Branch: $(git branch --show-current)"
  } >"$logfile"

  case "${subcommand}" in
    commit) _cmd_undo_commit "${non_interactive}" "${dry_run}" ;;
    unstage) _cmd_unstage "${non_interactive}" "${dry_run}" "${positional[@]+"${positional[@]}"}" ;;
    discard) _cmd_discard "${non_interactive}" "${dry_run}" "${positional[@]+"${positional[@]}"}" ;;
    amend-message) _cmd_amend_message "${non_interactive}" "${dry_run}" "${positional[@]+"${positional[@]}"}" ;;
    *)
      echo "[ERROR] Unknown subcommand: ${subcommand}" >&2
      echo "Run with --help to see available subcommands" >&2
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Subcommand: commit
# ---------------------------------------------------------------------------
_cmd_undo_commit() {
  local non_interactive="$1" dry_run="$2"

  echo "=== Undo Last Commit ==="
  echo ""

  # Must have at least one commit to undo
  if ! git rev-parse HEAD >/dev/null 2>&1; then
    err "Repository has no commits to undo"
    exit 1
  fi

  local commit_count
  commit_count=$(git rev-list --count HEAD 2>/dev/null || echo "0")
  if [[ "${commit_count}" -le 1 ]]; then
    err "Cannot undo the initial commit (no parent to reset to)"
    exit 1
  fi

  # Warn if commit appears to have been pushed
  local current_branch upstream_ref
  current_branch=$(git branch --show-current)
  upstream_ref="refs/remotes/${CGW_REMOTE}/${current_branch}"
  if git show-ref --verify --quiet "${upstream_ref}" 2>/dev/null; then
    local ahead
    ahead=$(cgw_rev_count "${CGW_REMOTE}/${current_branch}" "HEAD" || echo "0")
    if [[ "${ahead}" -eq 0 ]]; then
      echo "[!] WARNING: The last commit appears to have been pushed to ${CGW_REMOTE}."
      echo "  Undoing it locally will create a diverged state requiring force-push."
      if ! cgw_confirm "Continue anyway?" --non-interactive abort; then
        echo "Cancelled"
        exit 0
      fi
    fi
  fi

  echo "Last commit to undo:"
  git log -1 --oneline
  echo ""
  echo "After undo: all changes will be staged (git reset --soft HEAD~1)"
  echo ""

  if [[ "${dry_run}" -eq 1 ]]; then
    echo "--- Dry run: no changes made ---"
    echo "Would run: git reset --soft HEAD~1"
    exit 0
  fi

  if ! cgw_confirm "Undo this commit?" --non-interactive accept; then
    echo "Cancelled"
    exit 0
  fi

  # Create backup tag before reset
  cgw_create_backup_tag undo-commit
  local backup_tag="${CGW_BACKUP_TAG}"

  if git reset --soft HEAD~1; then
    echo ""
    echo "[OK] COMMIT UNDONE"
    echo "  All changes are now staged."
    echo "  Backup: git reset --hard ${backup_tag}  (to restore)"
    echo "  Next:   review staged files, edit if needed, then re-commit"
  else
    err "Reset failed"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Subcommand: unstage
# ---------------------------------------------------------------------------
_cmd_unstage() {
  local non_interactive="$1" dry_run="$2"
  shift 2
  local files=("$@")

  echo "=== Unstage Files ==="
  echo ""

  if [[ ${#files[@]} -eq 0 ]]; then
    # No files specified: show all staged and let user pick
    local staged
    staged=$(git diff --cached --name-only)
    if [[ -z "${staged}" ]]; then
      echo "  Nothing is staged."
      exit 0
    fi
    echo "  Staged files:"
    while IFS= read -r line; do printf '    %s\n' "${line}"; done <<<"${staged}"
    echo ""
    err "Specify file(s) to unstage. Example: ./scripts/git/undo_last.sh unstage <file>"
    exit 1
  fi

  # Validate each file is actually staged.
  # Use pathspec-scoped diff to get an exact match rather than grepping the full
  # list (grep -F would match 'src/app' inside 'src/app.bak' — substring bug).
  local -a to_unstage=()
  for f in "${files[@]}"; do
    if [[ -n "$(git diff --cached --name-only -- "${f}" 2>/dev/null)" ]]; then
      to_unstage+=("${f}")
    else
      echo "  [!] Not staged: ${f} (skipping)"
    fi
  done

  if [[ ${#to_unstage[@]} -eq 0 ]]; then
    echo "  Nothing to unstage."
    exit 0
  fi

  echo "  Files to unstage:"
  for f in "${to_unstage[@]}"; do echo "    ${f}"; done
  echo ""

  if [[ "${dry_run}" -eq 1 ]]; then
    echo "--- Dry run: no changes made ---"
    echo "Would run: git reset HEAD ${to_unstage[*]}"
    exit 0
  fi

  if ! cgw_confirm "Unstage ${#to_unstage[@]} file(s)?" --non-interactive accept; then
    echo "Cancelled"
    exit 0
  fi

  for f in "${to_unstage[@]}"; do
    if git reset HEAD "${f}" 2>/dev/null; then
      echo "  [OK] Unstaged: ${f}"
    else
      echo "  [FAIL] Failed: ${f}" >&2
    fi
  done
}

# ---------------------------------------------------------------------------
# Subcommand: discard
# ---------------------------------------------------------------------------
_cmd_discard() {
  local non_interactive="$1" dry_run="$2"
  shift 2
  local files=("$@")

  echo "=== Discard Working-Tree Changes ==="
  echo ""
  echo "  [!] WARNING: This permanently discards uncommitted changes."
  echo "  Changes cannot be recovered after this operation."
  echo ""

  if [[ ${#files[@]} -eq 0 ]]; then
    err "Specify file(s) to discard. Example: ./scripts/git/undo_last.sh discard <file>"
    exit 1
  fi

  # Validate each file has modifications
  local -a to_discard=()
  for f in "${files[@]}"; do
    if [[ ! -f "${f}" ]] && [[ ! -d "${f}" ]]; then
      echo "  [!] Not found: ${f} (skipping)"
      continue
    fi
    # Pathspec-scoped diff gives an exact match; no risk of 'src/app' matching 'src/app.bak'.
    if [[ -n "$(git diff --name-only -- "${f}" 2>/dev/null)" ]]; then
      to_discard+=("${f}")
    else
      echo "  [!] No unstaged changes: ${f} (skipping)"
    fi
  done

  if [[ ${#to_discard[@]} -eq 0 ]]; then
    echo "  Nothing to discard."
    exit 0
  fi

  echo "  Files to discard changes in:"
  for f in "${to_discard[@]}"; do
    git diff --stat -- "${f}" | head -3 | while IFS= read -r line; do printf '    %s\n' "${line}"; done
  done
  echo ""

  if [[ "${dry_run}" -eq 1 ]]; then
    echo "--- Dry run: no changes made ---"
    echo "Would run: git checkout -- ${to_discard[*]}"
    exit 0
  fi

  if ! cgw_confirm "PERMANENTLY discard changes in ${#to_discard[@]} file(s)?" --non-interactive abort; then
    echo "Cancelled"
    exit 0
  fi

  for f in "${to_discard[@]}"; do
    if git checkout -- "${f}" 2>/dev/null; then
      echo "  [OK] Discarded: ${f}"
    else
      echo "  [FAIL] Failed: ${f}" >&2
    fi
  done
}

# ---------------------------------------------------------------------------
# Subcommand: amend-message
# ---------------------------------------------------------------------------
_cmd_amend_message() {
  local non_interactive="$1" dry_run="$2"
  shift 2
  local new_msg="${1:-}"

  echo "=== Amend Last Commit Message ==="
  echo ""

  if ! git rev-parse HEAD >/dev/null 2>&1; then
    err "Repository has no commits"
    exit 1
  fi

  if [[ -z "${new_msg}" ]]; then
    err "New message required. Example: ./scripts/git/undo_last.sh amend-message 'fix: correct typo'"
    exit 1
  fi

  # Validate conventional format
  if ! cgw_validate_commit_message "${new_msg}"; then
    echo "  [!] Message does not follow conventional format: ${new_msg}"
    echo "  Expected: <type>: <description> (types: ${CGW_ALL_PREFIXES/|/, })"
    if ! cgw_confirm "Continue anyway?" --non-interactive accept; then
      echo "Cancelled"
      exit 0
    fi
  fi

  # Warn if commit has been pushed
  local current_branch upstream_ref
  current_branch=$(git branch --show-current)
  upstream_ref="refs/remotes/${CGW_REMOTE}/${current_branch}"
  if git show-ref --verify --quiet "${upstream_ref}" 2>/dev/null; then
    local ahead
    ahead=$(cgw_rev_count "${CGW_REMOTE}/${current_branch}" "HEAD" || echo "0")
    if [[ "${ahead}" -eq 0 ]]; then
      echo "  [!] WARNING: This commit appears to have been pushed. Amending will require force-push."
      if ! cgw_confirm "Amend anyway?" --non-interactive abort; then
        echo "Cancelled"
        exit 0
      fi
    fi
  fi

  echo "  Current message: $(git log -1 --format='%s')"
  echo "  New message:     ${new_msg}"
  echo ""

  if [[ "${dry_run}" -eq 1 ]]; then
    echo "--- Dry run: no changes made ---"
    echo "Would run: git commit --amend -m '${new_msg}'"
    exit 0
  fi

  if ! cgw_confirm "Amend commit message?" --non-interactive accept; then
    echo "Cancelled"
    exit 0
  fi

  if git commit --amend --no-edit -m "${new_msg}"; then
    echo ""
    echo "[OK] Message updated: $(git log -1 --oneline)"
  else
    err "Amend failed"
    exit 1
  fi
}

main "$@"
