#!/usr/bin/env bash
# install_hooks.sh - Install git hooks from .githooks/ to the active hooks dir
# Purpose: Install pre-commit, pre-push, and pre-rebase hooks
# Usage: ./scripts/git/install_hooks.sh [OPTIONS]
#
# Globals:
#   SCRIPT_DIR     - Directory containing this script
#   PROJECT_ROOT   - Auto-detected git repo root (set by _config.sh)
#   logfile        - Set by init_logging
# Returns:
#   0 on success, 1 on failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"

init_logging "install_hooks"

main() {
  if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    echo "Usage: ./scripts/git/install_hooks.sh"
    echo ""
    echo "Install git hooks from .githooks/ into the active git hooks directory"
    echo "(core.hooksPath if set, otherwise the shared hooks dir resolved via"
    echo "'git rev-parse --git-common-dir' — worktree-safe, so this works the"
    echo "same from the main worktree or a linked one)."
    echo "Installs:"
    echo "  pre-commit  — blocks local-only files, optional lint/typecheck"
    echo "  pre-push    — validates conventional commit format on unpushed commits"
    echo "  pre-rebase  — refuses rebasing commits already pushed to remote"
    echo ""
    echo "The hook files must exist at: \$PROJECT_ROOT/.githooks/"
    echo "(from a linked worktree, falls back to the main worktree's .githooks/)"
    echo "Run configure.sh first to generate them from the templates."
    echo ""
    echo "Options:"
    echo "  -h, --help   Show this help"
    echo ""
    echo "To uninstall: rm <hooks-dir>/pre-commit <hooks-dir>/pre-push <hooks-dir>/pre-rebase"
    echo "  (run without --help to see the resolved <hooks-dir> for this worktree)"
    echo "To bypass temporarily (not recommended): git commit --no-verify / git push --no-verify"
    exit 0
  fi

  {
    echo "========================================="
    echo "Install Hooks Log"
    echo "========================================="
    echo "Start Time: $(date)"
    echo "Working Directory: ${PROJECT_ROOT}"
  } >"$logfile"

  echo "=== Git Hooks Installer ===" | tee -a "$logfile"
  echo "" | tee -a "$logfile"

  cd "${PROJECT_ROOT}" || {
    err "Cannot find project root"
    exit 1
  }

  # `-d ".git"` hard-fails in a linked worktree, where .git is a FILE (a
  # gitdir pointer), not a directory. Ask git itself instead.
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    err "Not a git repository. Run from repository root or a worktree of it."
    exit 1
  fi

  # .githooks/ is gitignored, so a linked worktree never gets it checked out.
  # Fall back to the main worktree's copy — same repo, just a different
  # checkout, same reasoning as the .cgw.conf fallback in _config.sh.
  local githooks_src=".githooks"
  if [[ ! -d "${githooks_src}" ]]; then
    local _main_root
    _main_root="$(cgw_main_worktree_root "${PROJECT_ROOT}" 2>/dev/null)" || _main_root=""
    if [[ -n "${_main_root}" ]] && [[ -d "${_main_root}/.githooks" ]]; then
      githooks_src="${_main_root}/.githooks"
    fi
  fi

  if [[ ! -d "${githooks_src}" ]]; then
    err ".githooks directory not found."
    echo "Run configure.sh first to generate hook files, or create .githooks/ manually." >&2
    echo "Or link it from the main worktree: ./scripts/git/worktree_manage.sh link" >&2
    exit 1
  fi

  log_section_start "INSTALL HOOKS" "$logfile"

  # Resolve the active hooks directory: honour core.hooksPath if configured,
  # otherwise fall back to the shared hooks dir git itself resolves. Using
  # `git rev-parse --git-common-dir` (not ".git/hooks") is what makes this
  # worktree-correct: .git is a FILE in a linked worktree (mkdir -p on it
  # would fail ENOTDIR), and hooks live in one location shared by every
  # worktree, resolved via the common dir. Same idiom as
  # ensure_no_stale_index_lock() in _common.sh.
  local hooks_dir
  hooks_dir="$(git config --get core.hooksPath 2>/dev/null || true)"
  if [[ -z "${hooks_dir}" ]]; then
    local common_dir
    common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
    # git < 2.5 doesn't know --git-common-dir: it either echoes the option
    # back verbatim or exits with empty output, and linked worktrees (the
    # only case where common-dir differs from git-dir) require 2.5+ anyway.
    # Fall back to --git-dir, which is correct for a non-worktree checkout.
    if [[ -z "${common_dir}" || "${common_dir}" == "--git-common-dir" ]]; then
      common_dir="$(git rev-parse --git-dir 2>/dev/null)"
    fi
    hooks_dir="${common_dir}/hooks"
    # Absolutise if relative. On Windows/MSYS an already-absolute path from
    # git is drive-letter form ("C:/…"), which a bare "/*" glob does not
    # match -- check both forms or this wrongly re-prefixes it with
    # PROJECT_ROOT (see the same fix in ensure_no_stale_index_lock, _common.sh).
    [[ "${hooks_dir}" != /* && "${hooks_dir}" != [A-Za-z]:/* ]] && hooks_dir="${PROJECT_ROOT}/${hooks_dir}"
  fi
  mkdir -p "${hooks_dir}"

  # Determine whether the resolved hooks dir is already githooks_src so we can
  # skip the copy and just ensure the files are executable.
  local githooks_abs hooks_dir_abs
  githooks_abs="$(cd "${githooks_src}" && pwd)"
  hooks_dir_abs="$(cd "${hooks_dir}" 2>/dev/null && pwd || true)"

  local hooks_ok=0

  if [[ -f "${githooks_src}/pre-commit" ]]; then
    echo "Installing pre-commit hook..." | tee -a "$logfile"
    if [[ "${hooks_dir_abs}" == "${githooks_abs}" ]]; then
      chmod +x "${githooks_src}/pre-commit" >>"$logfile" 2>&1
      echo "  [OK] core.hooksPath=${hooks_dir} — pre-commit already in place" | tee -a "$logfile"
    elif cp "${githooks_src}/pre-commit" "${hooks_dir}/pre-commit" >>"$logfile" 2>&1; then
      chmod +x "${hooks_dir}/pre-commit" >>"$logfile" 2>&1
      echo "  [OK] pre-commit installed at ${hooks_dir}/pre-commit" | tee -a "$logfile"
    else
      err_tee "  [FAIL] Failed to install pre-commit hook"
      hooks_ok=1
    fi
  else
    err "pre-commit template not found at ${githooks_src}/pre-commit"
    echo "Run configure.sh to generate the hook from your CGW_LOCAL_FILES config." >&2
    log_section_end "INSTALL HOOKS" "$logfile" "1"
    exit 1
  fi

  if [[ -f "${githooks_src}/pre-push" ]]; then
    echo "Installing pre-push hook..." | tee -a "$logfile"
    if [[ "${hooks_dir_abs}" == "${githooks_abs}" ]]; then
      chmod +x "${githooks_src}/pre-push" >>"$logfile" 2>&1
      echo "  [OK] core.hooksPath=${hooks_dir} — pre-push already in place" | tee -a "$logfile"
    elif cp "${githooks_src}/pre-push" "${hooks_dir}/pre-push" >>"$logfile" 2>&1; then
      chmod +x "${hooks_dir}/pre-push" >>"$logfile" 2>&1
      echo "  [OK] pre-push installed at ${hooks_dir}/pre-push" | tee -a "$logfile"
    else
      echo "  [!] Failed to install pre-push hook (non-fatal)" | tee -a "$logfile"
    fi
  fi

  if [[ -f "${githooks_src}/pre-rebase" ]]; then
    echo "Installing pre-rebase hook..." | tee -a "$logfile"
    if [[ "${hooks_dir_abs}" == "${githooks_abs}" ]]; then
      chmod +x "${githooks_src}/pre-rebase" >>"$logfile" 2>&1
      echo "  [OK] core.hooksPath=${hooks_dir} — pre-rebase already in place" | tee -a "$logfile"
    elif cp "${githooks_src}/pre-rebase" "${hooks_dir}/pre-rebase" >>"$logfile" 2>&1; then
      chmod +x "${hooks_dir}/pre-rebase" >>"$logfile" 2>&1
      echo "  [OK] pre-rebase installed at ${hooks_dir}/pre-rebase" | tee -a "$logfile"
    else
      echo "  [!] Failed to install pre-rebase hook (non-fatal)" | tee -a "$logfile"
    fi
  fi

  log_section_end "INSTALL HOOKS" "$logfile" "${hooks_ok}"
  [[ ${hooks_ok} -ne 0 ]] && exit 1

  echo "" | tee -a "$logfile"
  {
    echo "========================================"
    echo "[INSTALL SUMMARY]"
    echo "========================================"
  } | tee -a "$logfile"
  echo "HOOKS INSTALLED SUCCESSFULLY" | tee -a "$logfile"
  echo "" | tee -a "$logfile"

  echo "Active hooks:"
  echo "  - pre-commit:  Blocks local-only files, optional lint check"
  echo "  - pre-push:    Validates conventional commit format on unpushed commits"
  echo "  - pre-rebase:  Refuses rebasing commits already pushed to remote"
  echo ""
  echo "To bypass temporarily (not recommended):"
  echo "  git commit --no-verify / git push --no-verify / git rebase --no-verify"
  echo ""
  echo "To override the pre-rebase guard (controlled force-push workflows):"
  echo "  CGW_ALLOW_REBASE_PUBLISHED=1 in .cgw.conf"
  echo ""
  echo "To uninstall:"
  echo "  rm ${hooks_dir}/pre-commit ${hooks_dir}/pre-push ${hooks_dir}/pre-rebase"
  echo ""

  {
    echo ""
    echo "End Time: $(date)"
  } | tee -a "$logfile"

  echo "Full log: $logfile"
}

main "$@"
