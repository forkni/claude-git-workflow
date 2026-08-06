#!/usr/bin/env bash
# fix_lint.sh - Auto-fix lint issues
# Purpose: Run lint auto-fix and formatting
# Usage: ./scripts/git/fix_lint.sh [OPTIONS]
#
# Globals:
#   SCRIPT_DIR     - Directory containing this script
#   PROJECT_ROOT   - Auto-detected git repo root (set by _config.sh)
#   logfile        - Set by init_logging
#   CGW_LINT_CMD   - Lint tool to use (default: ruff; empty = skip)
#   CGW_MARKDOWNLINT_CMD - Markdown lint tool; auto-detected if unset (see _config.sh)
# Returns:
#   0 on success, 1 if issues remain after fix

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"

main() {
  local non_interactive=0
  local modified_only=0
  local skip_md_lint=0
  local md_only=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help | -h)
        echo "Usage: ./scripts/git/fix_lint.sh [OPTIONS]"
        echo ""
        echo "Auto-fix lint issues using configured lint tool(s)."
        echo ""
        echo "Options:"
        echo "  --modified-only     Only fix files modified vs HEAD"
        echo "  --skip-md-lint      Skip markdown auto-fix"
        echo "  --md-only           Only run markdown auto-fix (skip code lint)"
        echo "  --non-interactive   Skip prompts"
        echo "  --no-venv           Use system lint tool instead of .venv"
        echo "  -h, --help          Show this help"
        echo ""
        echo "Environment:"
        echo "  CGW_NON_INTERACTIVE=1   Same as --non-interactive"
        echo "  CGW_NO_VENV=1           Same as --no-venv"
        echo "  CGW_SKIP_MD_LINT=1      Same as --skip-md-lint"
        echo "  CGW_MARKDOWNLINT_CMD    Markdown tool; auto-detected if unset"
        echo "  (Also: CLAUDE_GIT_NON_INTERACTIVE, CLAUDE_GIT_NO_VENV)"
        exit 0
        ;;
      --non-interactive)
        non_interactive=1
        CGW_NON_INTERACTIVE=1
        shift
        ;;
      --no-venv)
        CGW_NO_VENV=1
        SKIP_VENV=1
        shift
        ;;
      --modified-only)
        modified_only=1
        shift
        ;;
      --skip-md-lint)
        skip_md_lint=1
        shift
        ;;
      --md-only)
        md_only=1
        shift
        ;;
      *)
        echo "[ERROR] Unknown flag: $1" >&2
        exit 1
        ;;
    esac
  done

  [[ "${CGW_NON_INTERACTIVE:-0}" == "1" ]] && non_interactive=1
  [[ "${CGW_SKIP_MD_LINT:-0}" == "1" ]] && skip_md_lint=1

  if [[ "${skip_md_lint}" -eq 1 ]] && [[ "${md_only}" -eq 1 ]]; then
    echo "[ERROR] --skip-md-lint and --md-only are mutually exclusive" >&2
    exit 1
  fi

  if [[ -z "${CGW_LINT_CMD}" ]] && [[ -z "${CGW_FORMAT_CMD}" ]] && [[ -z "${CGW_MARKDOWNLINT_CMD}" ]]; then
    echo "[OK] Lint fix skipped (CGW_LINT_CMD, CGW_FORMAT_CMD, and CGW_MARKDOWNLINT_CMD not set)"
    exit 0
  fi

  cd "${PROJECT_ROOT}" || {
    err "Cannot find project root"
    exit 1
  }

  get_lint_exclusions

  # Handle --modified-only mode (direct output, no section logging)
  if [[ "${modified_only}" -eq 1 ]]; then
    local EXIT_CODE=0
    local ran_something=0

    if [[ "${md_only}" -eq 0 ]]; then
      local modified_files
      modified_files=$(cgw_modified_files_for_lint)
      if [[ -n "$modified_files" ]]; then
        ran_something=1
        echo "=== Modified-Only Lint Fix ==="
        echo "Files: $modified_files"
        echo ""

        get_python_path 2>/dev/null || true
        local lint_bin
        lint_bin=$(cgw_resolve_lint_binary "${CGW_LINT_CMD}")

        echo "[LINT FIX]"
        local lint_fix_cmd_args
        lint_fix_cmd_args=$(cgw_strip_path_arg "${CGW_LINT_FIX_ARGS}")
        # shellcheck disable=SC2086
        "${lint_bin}" ${lint_fix_cmd_args} $modified_files || EXIT_CODE=1

        if [[ -n "${CGW_FORMAT_CMD}" ]]; then
          echo ""
          echo "[FORMAT FIX]"
          local fmt_fix_cmd_args
          fmt_fix_cmd_args=$(cgw_strip_path_arg "${CGW_FORMAT_FIX_ARGS}")
          # shellcheck disable=SC2086
          "${CGW_FORMAT_CMD}" ${fmt_fix_cmd_args} $modified_files || EXIT_CODE=1
        fi
      fi
    fi

    if [[ "${skip_md_lint}" -eq 0 ]]; then
      local modified_md
      modified_md=$(cgw_modified_files_for_md)
      if [[ -n "$modified_md" ]]; then
        ran_something=1
        local -a modified_md_arr=()
        local md_f
        while IFS= read -r md_f; do
          [[ -n "${md_f}" ]] && modified_md_arr+=("${md_f}")
        done <<<"$modified_md"

        echo ""
        echo "=== Modified-Only Markdown Fix ==="
        echo "Files: $modified_md"
        echo ""
        echo "[MARKDOWN FIX]"
        # No section logging in --modified-only mode; discard cgw_run_markdownlint_fix's
        # internal log-file append target ($logfile is unset here -- init_logging hasn't run).
        local logfile="/dev/null"
        cgw_run_markdownlint_fix "${modified_md_arr[@]}" || EXIT_CODE=1
      fi
    fi

    if [[ "${ran_something}" -eq 0 ]]; then
      echo "[OK] No modified files to fix"
    fi

    exit $EXIT_CODE
  fi

  # Full fix with logging
  init_logging "fix_lint"

  local script_start
  script_start=$(date +%s)

  {
    echo "========================================="
    echo "Lint Auto-Fix Log"
    echo "========================================="
    echo "Start Time: $(date)"
    echo "Working Directory: ${PROJECT_ROOT}"
    echo "Lint tool: ${CGW_LINT_CMD}"
    echo "Markdown tool: ${CGW_MARKDOWNLINT_CMD}"
    echo "Mode: $([ $non_interactive -eq 1 ] && echo 'Non-interactive' || echo 'Interactive')"
  } >"$logfile"

  local fix_failed=0

  if [[ "${md_only}" -eq 0 ]]; then
    cgw_run_lint_fix || {
      echo "[!] Lint tool: some issues may not be auto-fixable" | tee -a "$logfile"
      fix_failed=1
    }
  fi

  if [[ "${skip_md_lint}" -eq 0 ]]; then
    cgw_run_markdownlint_fix || {
      echo "[!] Markdown lint: some issues may not be auto-fixable" | tee -a "$logfile"
      fix_failed=1
    }
  fi

  {
    echo ""
    echo "========================================"
    echo "[FIX SUMMARY]"
    echo "========================================"
  } | tee -a "$logfile"

  if ((fix_failed == 0)); then
    echo "[OK] All lint fixes applied successfully!" | tee -a "$logfile"
  else
    echo "[!] Some issues remain -- check output above" | tee -a "$logfile"
  fi

  # Run final verification
  echo "" | tee -a "$logfile"
  echo "Running final verification..." | tee -a "$logfile"

  local verify_output verify_status
  verify_output=$(bash "${SCRIPT_DIR}/check_lint.sh" 2>&1)
  verify_status=$?
  echo "${verify_output}" | tee -a "$logfile"

  if [[ ${verify_status} -eq 0 ]]; then
    echo "[OK] All lint checks pass!" | tee -a "$logfile"
  else
    echo "[!] Some issues remain -- manual fixes may be required" | tee -a "$logfile"
    # Surface the unfixable diagnostics (file:line[:col] rule) as a distilled
    # list so the next manual step is visible without digging through the
    # full log -- "cannot auto-fix" with no target list is a dead end.
    local remaining
    remaining=$(echo "${verify_output}" | grep -E "^[^:]+:[0-9]+(:[0-9]+)?[: ]" | head -20)
    if [[ -n "${remaining}" ]]; then
      {
        echo ""
        echo "Remaining issues needing manual fixes:"
        echo "${remaining}" | sed 's/^/  /'
      } | tee -a "$logfile"
    fi
  fi

  local script_end total_duration
  script_end=$(date +%s)
  total_duration=$((script_end - script_start))

  {
    echo ""
    echo "End Time: $(date)"
    echo "Total Duration: ${total_duration}s"
  } | tee -a "$logfile"

  echo ""
  echo "Full log: $logfile"
}

main "$@"
