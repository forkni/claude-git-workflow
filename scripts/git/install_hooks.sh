#!/usr/bin/env bash
# install_hooks.sh - Install git hooks from .githooks/ to .git/hooks/
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
    echo "Install git hooks from .githooks/ to .git/hooks/."
    echo "Installs:"
    echo "  pre-commit  — blocks local-only files, optional lint/typecheck"
    echo "  pre-push    — validates conventional commit format on unpushed commits"
    echo "  pre-rebase  — refuses rebasing commits already pushed to remote"
    echo ""
    echo "The hook files must exist at: \$PROJECT_ROOT/.githooks/"
    echo "Run configure.sh first to generate them from the templates."
    echo ""
    echo "Options:"
    echo "  -h, --help   Show this help"
    echo ""
    echo "To uninstall: rm .git/hooks/pre-commit .git/hooks/pre-push .git/hooks/pre-rebase"
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

  if [[ ! -d ".git" ]]; then
    err ".git directory not found. Run from repository root."
    exit 1
  fi

  if [[ ! -d ".githooks" ]]; then
    err ".githooks directory not found."
    echo "Run configure.sh first to generate hook files, or create .githooks/ manually." >&2
    exit 1
  fi

  log_section_start "INSTALL HOOKS" "$logfile"

  # Resolve the active hooks directory: honour core.hooksPath if configured,
  # otherwise fall back to the standard .git/hooks/ location.
  local hooks_dir
  hooks_dir="$(git config --get core.hooksPath 2>/dev/null || true)"
  [[ -z "${hooks_dir}" ]] && hooks_dir=".git/hooks"
  mkdir -p "${hooks_dir}"

  # Determine whether the resolved hooks dir is already .githooks/ so we can
  # skip the copy and just ensure the files are executable.
  local githooks_abs hooks_dir_abs
  githooks_abs="$(cd .githooks && pwd)"
  hooks_dir_abs="$(cd "${hooks_dir}" 2>/dev/null && pwd || true)"

  local hooks_ok=0

  if [[ -f ".githooks/pre-commit" ]]; then
    echo "Installing pre-commit hook..." | tee -a "$logfile"
    if [[ "${hooks_dir_abs}" == "${githooks_abs}" ]]; then
      chmod +x ".githooks/pre-commit" >>"$logfile" 2>&1
      echo "  [OK] core.hooksPath=${hooks_dir} — pre-commit already in place" | tee -a "$logfile"
    elif cp ".githooks/pre-commit" "${hooks_dir}/pre-commit" >>"$logfile" 2>&1; then
      chmod +x "${hooks_dir}/pre-commit" >>"$logfile" 2>&1
      echo "  [OK] pre-commit installed at ${hooks_dir}/pre-commit" | tee -a "$logfile"
    else
      err_tee "  [FAIL] Failed to install pre-commit hook"
      hooks_ok=1
    fi
  else
    err "pre-commit template not found at .githooks/pre-commit"
    echo "Run configure.sh to generate the hook from your CGW_LOCAL_FILES config." >&2
    log_section_end "INSTALL HOOKS" "$logfile" "1"
    exit 1
  fi

  if [[ -f ".githooks/pre-push" ]]; then
    echo "Installing pre-push hook..." | tee -a "$logfile"
    if [[ "${hooks_dir_abs}" == "${githooks_abs}" ]]; then
      chmod +x ".githooks/pre-push" >>"$logfile" 2>&1
      echo "  [OK] core.hooksPath=${hooks_dir} — pre-push already in place" | tee -a "$logfile"
    elif cp ".githooks/pre-push" "${hooks_dir}/pre-push" >>"$logfile" 2>&1; then
      chmod +x "${hooks_dir}/pre-push" >>"$logfile" 2>&1
      echo "  [OK] pre-push installed at ${hooks_dir}/pre-push" | tee -a "$logfile"
    else
      echo "  [!] Failed to install pre-push hook (non-fatal)" | tee -a "$logfile"
    fi
  fi

  if [[ -f ".githooks/pre-rebase" ]]; then
    echo "Installing pre-rebase hook..." | tee -a "$logfile"
    if [[ "${hooks_dir_abs}" == "${githooks_abs}" ]]; then
      chmod +x ".githooks/pre-rebase" >>"$logfile" 2>&1
      echo "  [OK] core.hooksPath=${hooks_dir} — pre-rebase already in place" | tee -a "$logfile"
    elif cp ".githooks/pre-rebase" "${hooks_dir}/pre-rebase" >>"$logfile" 2>&1; then
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
